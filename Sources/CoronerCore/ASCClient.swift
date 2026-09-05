import Foundation
import CryptoKit

public enum ASCError: Error, CustomStringConvertible {
    case invalidKey(String)

    public var description: String {
        switch self {
        case .invalidKey(let why): return "invalid App Store Connect key: \(why)"
        }
    }
}

/// App Store Connect API client pieces that stay pure (no network in Core):
/// ES256 JWT signing with .p8 key parsing, request construction, response
/// parsing. The actual HTTP fetch lives in the CLI.
public enum ASCJWT {

    /// Parses a `.p8` key (PEM, PKCS#8 EC; openssl's SEC1 two-block form also
    /// accepted) into a P-256 private key. Zero-dependency ASN.1 walk: PKCS#8
    /// and SEC1 both embed the 32-byte scalar in an OCTET STRING (04 20 …) —
    /// scan each PEM block for that marker and accept the first candidate that
    /// is a valid scalar.
    public static func privateKey(pem: String) throws -> P256.Signing.PrivateKey {
        var blocks: [Data] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            if let der = Data(base64Encoded: Data(current.joined().utf8)) {
                blocks.append(der)
            }
            current = []
        }
        for line in pem.split(separator: "\n") {
            if line.hasPrefix("-----") {
                flush()
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                current.append(String(line))
            }
        }
        flush()
        guard !blocks.isEmpty else { throw ASCError.invalidKey("no PEM block decoded") }
        for der in blocks where der.count >= 34 {
            for i in 0...(der.count - 34) {
                let start = der.startIndex + i
                guard der[start] == 0x04, der[der.index(after: start)] == 0x20 else { continue }
                let scalar = der[der.index(start, offsetBy: 2)..<der.index(start, offsetBy: 34)]
                if let key = try? P256.Signing.PrivateKey(rawRepresentation: scalar) {
                    return key
                }
            }
        }
        throw ASCError.invalidKey("no P-256 scalar found")
    }

    /// ES256 JWT for `Authorization: Bearer <token>` (Apple: ≤20 min lifetime).
    public static func token(issuer: String, keyID: String, key: P256.Signing.PrivateKey,
                             lifetime: TimeInterval = 1200, now: Date = Date()) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let iat = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = ["iss": issuer, "iat": iat,
                                      "exp": iat + Int(lifetime), "aud": "appstoreconnect-v1"]
        let h = b64url(try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let p = b64url(try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = h + "." + p
        // JWS ES256 uses the 64-byte raw signature form; CryptoKit hashes SHA-256 itself.
        let sig = try! key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + b64url(sig)
    }
}

public enum ASCRequests {

    public static let apiBase = URL(string: "https://api.appstoreconnect.apple.com")!

    /// The builds query fastlane's download_dsyms uses: app+build+platform
    /// filter, buildBundles included so dSYMUrl attributes ride along.
    public static func buildsURL(app: String, build: String, platform: String = "IOS",
                                 base: URL = apiBase) -> URL? {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
        c?.path = "/v1/builds"
        c?.queryItems = [
            URLQueryItem(name: "filter[app]", value: app),
            URLQueryItem(name: "filter[version]", value: build),
            URLQueryItem(name: "filter[preReleaseVersion.platform]", value: platform),
            URLQueryItem(name: "include", value: "preReleaseVersion,buildBundles"),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        return c?.url
    }

    /// dSYM zip URLs from a builds response — only bundles that include symbols.
    public static func dsymURLs(fromBuildsJSON data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let included = obj["included"] as? [[String: Any]] else { return [] }
        return included.compactMap { item in
            guard item["type"] as? String == "buildBundles",
                  let attrs = item["attributes"] as? [String: Any],
                  (attrs["includesSymbols"] as? Bool) == true,
                  let url = attrs["dSYMUrl"] as? String, !url.isEmpty else { return nil }
            return url
        }
    }
}
