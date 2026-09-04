import Foundation

/// Deterministic Markdown digest — tables and counts only, no LLM.
public enum Digest {

    public static func markdown(clusters: [ClusterReport], period: Store.Period,
                                generatedAt: Date = Date()) -> String {
        var lines: [String] = []
        lines.append("# coroner 부검 일지 — \(period.rawValue) (\(Self.stamp.string(from: generatedAt)))")
        lines.append("")
        if clusters.isEmpty {
            lines.append("해당 기간의 부검 대상이 없습니다.")
            return lines.joined(separator: "\n") + "\n"
        }

        let byKind = Dictionary(grouping: clusters, by: { $0.kind })
        lines.append("클러스터 \(clusters.count)건 · 총 \(clusters.reduce(0) { $0 + $1.totalOccurrences })회")
        for k in DiagnosticKind.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let group = byKind[k] {
                lines.append("- \(k.displayName): \(group.count)건 / \(group.reduce(0) { $0 + $1.totalOccurrences })회")
            }
        }
        lines.append("")
        lines.append("| id | kind | signature | first | last | total | builds | status |")
        lines.append("|---|---|---|---|---|---|---|---|")
        for c in clusters.sorted(by: { $0.totalOccurrences > $1.totalOccurrences }) {
            let sig = c.signature.count > 72 ? String(c.signature.prefix(69)) + "…" : c.signature
            let builds = c.occurrences.keys.sorted().joined(separator: ",")
            lines.append("| \(c.id) | \(c.kind.displayName) | `\(sig)` | \(Self.day.string(from: c.firstSeenAt ?? generatedAt)) | \(Self.day.string(from: c.lastSeenAt ?? generatedAt)) | \(c.totalOccurrences) | \(builds) | \(c.status) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func write(clusters: [ClusterReport], period: Store.Period,
                             baseDir: URL, generatedAt: Date = Date()) throws -> URL {
        let dir = baseDir.appendingPathComponent("digest", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("digest-\(Self.fileStamp.string(from: generatedAt)).md")
        try markdown(clusters: clusters, period: period, generatedAt: generatedAt)
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
