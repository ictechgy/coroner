import Foundation

/// Shared text rendering for CLI and MCP outputs.
public enum Renderer {

    public static func oneLine(_ c: ClusterReport) -> String {
        let sig = c.signature.count > 72 ? String(c.signature.prefix(69)) + "…" : c.signature
        let first = c.firstSeenAt.map { Digest.day.string(from: $0) } ?? "?"
        let last = c.lastSeenAt.map { Digest.day.string(from: $0) } ?? "?"
        return "\(c.id)  [\(c.kind.displayName)]  \(first)→\(last)  \(c.totalOccurrences)x  \(sig)"
    }

    public static func list(_ clusters: [ClusterReport]) -> String {
        clusters.map(oneLine).joined(separator: "\n")
    }

    public static func detail(_ c: ClusterReport) -> String {
        var out: [String] = []
        out.append("id: \(c.id)")
        out.append("kind: \(c.kind.displayName)")
        out.append("status: \(c.status)  symbolicated: \(c.symbolicated ? "yes" : "no")")
        out.append("signature: \(c.signature)")
        if let exc = c.exceptionSummary { out.append("exception: \(exc)") }
        out.append("builds: first_seen \(c.firstSeenBuild), last_seen \(c.lastSeenBuild)")
        out.append("occurrences:")
        for b in c.occurrences.keys.sorted() {
            out.append("  - \(b): \(c.occurrences[b] ?? 0)")
        }
        out.append("devices: \(c.devices.sorted { $0.key < $1.key }.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))")
        out.append("os: \(c.osVersions.sorted { $0.key < $1.key }.map { "\($0.key)(\($0.value))" }.joined(separator: ", "))")
        out.append("top frames:")
        for (i, f) in c.topFrames.enumerated() {
            out.append("  \(i). \(f)")
        }
        if let anchors = c.sourceAnchors, !anchors.isEmpty {
            out.append("source anchors: \(anchors.joined(separator: ", "))")
        }
        if let suspects = c.suspects, !suspects.isEmpty {
            out.append("suspect commits (estimate — telemetry is evidence, not a verdict):")
            for s in suspects {
                out.append("  \(String(s.hash.prefix(7)))  \(s.subject)  [matched: \(s.files.joined(separator: ", "))]")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Mask the home directory prefix in any printed path (privacy default).
    public static func maskPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
