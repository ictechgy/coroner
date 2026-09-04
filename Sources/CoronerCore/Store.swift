import Foundation

public enum StoreError: Error, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "no post-mortem record with id \(id)"
        }
    }
}

/// Directory-backed store: one JSON file per cluster report under `<base>/reports/`.
/// The journal (first_seen/last_seen, per-build occurrences) is derived at ingest time.
public final class Store {

    public let baseDir: URL
    public let reportsDir: URL
    public private(set) var clusters: [String: ClusterReport] = [:]

    public init(baseDir: URL) {
        self.baseDir = baseDir
        self.reportsDir = baseDir.appendingPathComponent("reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: - Persistence

    public func loadAll() {
        clusters = [:]
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: reportsDir.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for f in files where f.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: reportsDir.appendingPathComponent(f)),
                  let c = try? dec.decode(ClusterReport.self, from: data) else { continue }
            clusters[c.id] = c
        }
    }

    public func save(_ c: ClusterReport) {
        clusters[c.id] = c
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(c) {
            try? data.write(to: reportsDir.appendingPathComponent("\(c.id).json"), options: .atomic)
        }
    }

    // MARK: - Ingest

    /// Merge one symbolicated report into the journal. Returns the (possibly new) cluster.
    @discardableResult
    public func ingest(_ report: ParsedReport) -> ClusterReport {
        let sig = Signature.of(frames: report.frames)
        let first = clusters.values.first { $0.signature == sig }
        let build = report.buildVersion ?? "unknown"
        let date = report.timestamp ?? Date()
        let symbolicated = report.frames.contains { $0.symbol != nil }

        var c: ClusterReport
        if var existing = first {
            existing.occurrences[build, default: 0] += 1
            let shouldBumpBuild = existing.lastSeenBuild == "unknown"
                || BuildNumber.isNewerOrEqual(build, than: existing.lastSeenBuild)
            if shouldBumpBuild {
                existing.lastSeenBuild = build
            }
            existing.lastSeenAt = max(existing.lastSeenAt ?? date, date)
            if let d = report.deviceModel { existing.devices[d, default: 0] += 1 }
            if let o = report.osVersion { existing.osVersions[o, default: 0] += 1 }
            existing.symbolicated = existing.symbolicated || symbolicated
            c = existing
        } else {
            let id = Signature.clusterID(signature: sig, firstSeen: report.timestamp)
            var occ: [String: Int] = [:]
            occ[build, default: 0] += 1
            var devices: [String: Int] = [:]
            if let d = report.deviceModel { devices[d, default: 0] += 1 }
            var oses: [String: Int] = [:]
            if let o = report.osVersion { oses[o, default: 0] += 1 }
            c = ClusterReport(
                id: id,
                kind: report.kind,
                signature: sig,
                topFrames: report.frames.prefix(5).map { Signature.normalizedFrame($0) },
                exceptionSummary: report.exceptionSummary,
                appVersion: report.appVersion,
                firstSeenBuild: build,
                lastSeenBuild: build,
                firstSeenAt: report.timestamp,
                lastSeenAt: report.timestamp,
                occurrences: occ,
                devices: devices,
                osVersions: oses,
                status: "open",
                symbolicated: symbolicated
            )
        }
        save(c)
        return c
    }

    // MARK: - Queries

    public func all(kind: DiagnosticKind? = nil) -> [ClusterReport] {
        clusters.values
            .filter { kind == nil || $0.kind == kind }
            .sorted { $0.totalOccurrences > $1.totalOccurrences }
    }

    /// Clusters first seen strictly after `build` (numeric compare, lexicographic fallback).
    public func newSince(build: String, kind: DiagnosticKind? = nil) -> [ClusterReport] {
        all(kind: kind).filter { BuildNumber.isNewer($0.firstSeenBuild, than: build) }
    }

    public func isKnown(signatureSubstring: String) -> [ClusterReport] {
        let needle = signatureSubstring.lowercased()
        return clusters.values.filter { c in
            c.signature.lowercased().contains(needle) ||
            c.topFrames.contains { $0.lowercased().contains(needle) }
        }.sorted { $0.totalOccurrences > $1.totalOccurrences }
    }

    public func detail(id: String) throws -> ClusterReport {
        guard let c = clusters[id] else { throw StoreError.notFound(id) }
        return c
    }

    public enum Period: String {
        case today, week, all

        var seconds: TimeInterval? {
            switch self {
            case .today: return 24 * 3600
            case .week: return 7 * 24 * 3600
            case .all: return nil
            }
        }
    }

    public func hangReport(period: Period, now: Date = Date()) -> [ClusterReport] {
        let hangClusters = clusters.values.filter { $0.kind == .hang }
        guard let window = period.seconds else { return hangClusters.sorted { $0.totalOccurrences > $1.totalOccurrences } }
        return hangClusters
            .filter { c in
                guard let last = c.lastSeenAt else { return false }
                return now.timeIntervalSince(last) <= window
            }
            .sorted { $0.totalOccurrences > $1.totalOccurrences }
    }
}
