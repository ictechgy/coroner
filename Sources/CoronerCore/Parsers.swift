import Foundation

public enum ParseError: Error, CustomStringConvertible {
    case unrecognizedFormat(String)

    public var description: String {
        switch self {
        case .unrecognizedFormat(let path):
            return "unrecognized telemetry format: \(path)"
        }
    }
}

/// Parses .ips crash reports and MetricKit diagnostic payloads.
/// Tolerant by design: unknown keys are ignored, missing optional fields never fail the parse.
public struct TelemetryParser {

    public init() {}

    /// Parse one file into zero or more reports (MetricKit exports are often JSON Lines).
    public func parseFile(at path: String) throws -> [ParsedReport] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try parse(data: data, sourcePath: path)
    }

    public func parse(data: Data, sourcePath: String) throws -> [ParsedReport] {
        // Tolerate a UTF-8 BOM (some editors/exporters add one).
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data = Data(data.dropFirst(3))
        }
        if let reports = tryParseMetricKit(data: data, sourcePath: sourcePath) {
            return reports
        }
        if let report = tryParseIPS(data: data, sourcePath: sourcePath) {
            return [report]
        }
        throw ParseError.unrecognizedFormat(sourcePath)
    }

    // MARK: - Format sniffing

    private func tryParseMetricKit(data: Data, sourcePath: String) -> [ParsedReport]? {
        // Whole-document JSON first…
        if let obj = json(data), looksLikeMetricKit(obj) {
            return metricKitReports(from: obj, sourcePath: sourcePath)
        }
        // …then JSON Lines (Apple's mxdiag-style exports).
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var all: [ParsedReport] = []
        var sawPayload = false
        for line in text.split(separator: "\n") {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let obj = json(Data(line.utf8)) else { continue }
            if looksLikeMetricKit(obj) {
                all.append(contentsOf: metricKitReports(from: obj, sourcePath: sourcePath))
                sawPayload = true
            }
        }
        return sawPayload ? all : nil
    }

    private func looksLikeMetricKit(_ obj: [String: Any]) -> Bool {
        let keys = ["crashDiagnostics", "hangDiagnostics", "cpuExceptionDiagnostics",
                    "diskWriteExceptionDiagnostic", "diskWriteExceptionDiagnostics",
                    "metricPayload", "diagnostics"]
        return keys.contains { obj[$0] != nil }
    }

    private func tryParseIPS(data: Data, sourcePath: String) -> ParsedReport? {
        // Modern .ips = one JSON metadata line (app/build version, device, timestamp…),
        // then body JSON (threads/usedImages/exception). Merge both.
        if let report = ipsReport(fromBody: data, metadata: nil, sourcePath: sourcePath) {
            return report
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Prefer splitting at the first line: Apple pretty-prints the body JSON and
        // that output can itself contain blank lines (empty dicts like "x" : {\n\n}),
        // so a "\n\n" separator scan may cut into the middle of the body.
        if let firstNL = text.firstIndex(of: "\n"),
           json(Data(text[..<firstNL].utf8)) != nil,
           let report = ipsReport(fromBody: Data(text[firstNL...].utf8), metadata: Data(text[..<firstNL].utf8), sourcePath: sourcePath) {
            return report
        }
        guard let sep = text.range(of: "\n\n") else { return nil }
        let metadata = Data(String(text[..<sep.lowerBound]).utf8)
        let body = Data(String(text[sep.upperBound...]).utf8)
        return ipsReport(fromBody: body, metadata: metadata, sourcePath: sourcePath)
    }

    // MARK: - .ips

    private func ipsReport(fromBody data: Data, metadata: Data?, sourcePath: String) -> ParsedReport? {
        guard var body = json(data) else { return nil }
        guard body["threads"] != nil || body["usedImages"] != nil || body["exception"] != nil else { return nil }
        if let metadata, let m = json(metadata) {
            for (k, v) in m where body[k] == nil {
                body[k] = v
            }
        }

        var r = ParsedReport(kind: .crash, sourcePath: sourcePath)
        r.appVersion = body["app_version"] as? String
        r.buildVersion = body["build_version"] as? String
        r.timestamp = Self.date(any: body["timestamp"])
        r.deviceModel = body["deviceModel"] as? String ?? body["device_model"] as? String
        r.osVersion = body["os_version"] as? String

        if let exc = body["exception"] as? [String: Any] {
            let type = exc["type"] as? String
            let signal = exc["signal"] as? String
            let message = exc["message"] as? String
            let parts = [type, signal].compactMap { $0 }
            var summary = parts.joined(separator: " ")
            if let m = message { summary += " — \(m)" }
            r.exceptionSummary = summary.isEmpty ? nil : summary
        }
        if r.exceptionSummary == nil, let term = body["termination"] as? [String: Any] {
            r.exceptionSummary = term["indicator"] as? String ?? term["details"] as? String
        }

        var images: [BinaryImage] = []
        if let used = body["usedImages"] as? [[String: Any]] {
            for img in used {
                let name = (img["name"] as? String) ?? (img["path"] as? String)?.split(separator: "/").map(String.init).last ?? "unknown"
                let uuid = Self.normalizeUUID(img["uuid"] as? String)
                let base = (img["base"] as? NSNumber)?.uint64Value
                let size = (img["size"] as? NSNumber)?.uint64Value
                images.append(BinaryImage(name: name, uuid: uuid, base: base, size: size))
            }
        }
        r.images = images

        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = (body["faultingThread"] as? NSNumber)?.intValue ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? 0
        if threads.indices.contains(faulting), let frames = threads[faulting]["frames"] as? [[String: Any]] {
            r.frames = frames.compactMap { ipsFrame($0, images: images) }
        }
        return r
    }

    private func ipsFrame(_ f: [String: Any], images: [BinaryImage]) -> RawFrame? {
        let idx = (f["imageIndex"] as? NSNumber)?.intValue
        let binary = idx.flatMap { images.indices.contains($0) ? images[$0].name : nil }
        let offset = (f["imageOffset"] as? NSNumber)?.uint64Value
        return RawFrame(
            binary: binary,
            offset: offset,
            symbol: f["symbol"] as? String,
            symbolLocation: (f["symbolLocation"] as? NSNumber)?.intValue
        )
    }

    // MARK: - MetricKit

    private func metricKitReports(from obj: [String: Any], sourcePath: String) -> [ParsedReport] {
        var reports: [ParsedReport] = []
        let groups: [(key: String, kind: DiagnosticKind)] = [
            ("crashDiagnostics", .crash),
            ("hangDiagnostics", .hang),
            ("cpuExceptionDiagnostics", .cpu),
            // Singular per Apple docs, plural in real payloads.
            ("diskWriteExceptionDiagnostics", .disk),
            ("diskWriteExceptionDiagnostic", .disk),
        ]
        for group in groups {
            guard let diags = obj[group.key] as? [[String: Any]] else { continue }
            for diag in diags {
                reports.append(metricKitReport(diag: diag, kind: group.kind, sourcePath: sourcePath))
            }
        }
        // Real payloads put the collection window at payload level, not per-diagnostic.
        let payloadTS = Self.date(any: obj["timeStampBegin"]) ?? Self.date(any: obj["timeStampEnd"])
        for i in reports.indices where reports[i].timestamp == nil {
            reports[i].timestamp = payloadTS
        }
        return reports
    }

    private func metricKitReport(diag: [String: Any], kind: DiagnosticKind, sourcePath: String) -> ParsedReport {
        var r = ParsedReport(kind: kind, sourcePath: sourcePath)
        let meta = diag["diagnosticMetaData"] as? [String: Any]
        r.buildVersion = meta?["appBuildVersion"] as? String
        r.appVersion = meta?["appVersion"] as? String
        r.osVersion = meta?["osVersion"] as? String
        // Apple docs say deviceModel; real payloads say deviceType.
        r.deviceModel = (meta?["deviceModel"] ?? meta?["deviceType"]) as? String
        r.timestamp = Self.date(any: diag["timeStampBegin"]) ?? Self.date(any: diag["timeStampEnd"])

        // exceptionType is a string in docs but a number in real payloads.
        let excType = meta?["exceptionType"]
        if let s = excType as? String, !s.isEmpty {
            r.exceptionSummary = s
        } else if let n = excType as? NSNumber {
            r.exceptionSummary = n.stringValue
        }

        var images: [String: BinaryImage] = [:]
        // Some payloads carry a binary image table; uuids otherwise unknown.
        if let bins = (meta?["binaryImages"] ?? diag["binaryImages"]) as? [[String: Any]] {
            for b in bins {
                guard let name = b["binaryName"] as? String ?? b["name"] as? String else { continue }
                let img = BinaryImage(
                    name: name,
                    uuid: Self.normalizeUUID(b["binaryUUID"] as? String ?? b["uuid"] as? String),
                    base: (b["loadAddress"] as? NSNumber)?.uint64Value ?? (b["base"] as? NSNumber)?.uint64Value,
                    size: (b["size"] as? NSNumber)?.uint64Value,
                    textSegmentVMAddr: (b["vmaddr"] as? NSNumber)?.uint64Value
                )
                images[name] = img
            }
        }
        r.images = images.values.sorted { $0.name < $1.name }

        if let tree = diag["callStackTree"] as? [String: Any],
           let stacks = tree["callStacks"] as? [[String: Any]] {
            let attributed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
            if let attributed {
                // Docs/examples use "frames"; real payloads use "callStackRootFrames".
                let list = (attributed["frames"] ?? attributed["callStackRootFrames"]) as? [[String: Any]] ?? []
                r.frames = flatten(frames: list, images: images)
            }
        }
        return r
    }

    /// Depth-first flattening of MetricKit's nested subFrames, outermost first.
    private func flatten(frames: [[String: Any]], images: [String: BinaryImage]) -> [RawFrame] {
        var out: [RawFrame] = []
        func walk(_ list: [[String: Any]]) {
            for f in list {
                let name = f["binaryName"] as? String
                out.append(RawFrame(
                    binary: name,
                    offset: (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value,
                    symbol: f["symbolName"] as? String,
                    sampleCount: (f["sampleCount"] as? NSNumber)?.intValue
                ))
                if let sub = f["subFrames"] as? [[String: Any]], !sub.isEmpty {
                    walk(sub)
                }
            }
        }
        walk(frames)
        return out
    }

    // MARK: - Shared helpers

    private func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    static func normalizeUUID(_ s: String?) -> String? {
        guard var t = s, !t.isEmpty else { return nil }
        // Hex-only: feeds an mdfind query and dSYM matching, so drop everything
        // that is not a UUID character rather than merely stripping dashes.
        t = t.filter { $0.isHexDigit }.uppercased()
        return t.isEmpty ? nil : t
    }

    static func date(any: Any?) -> Date? {
        if let s = any as? String {
            if let d = isoFractional.date(from: s) { return d }
            if let d = iso.date(from: s) { return d }
            // Apple's own format in .ips metadata and MetricKit payloads:
            // "2022-09-18 15:28:37.00 +0900" / "2020-08-08 20:16:32 +0000".
            if let d = appleFractional.date(from: s) { return d }
            if let d = apple.date(from: s) { return d }
            return nil
        }
        if let n = any as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue)
        }
        return nil
    }

    private static let apple: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private static let appleFractional: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
