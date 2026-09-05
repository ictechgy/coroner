import Foundation
import CryptoKit

public enum StoreError: Error, CustomStringConvertible {
    case notFound(String)
    case invalidStatus(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "no post-mortem record with id \(id)"
        case .invalidStatus(let s): return "invalid status '\(s)' — allowed: open|known|fixed-in"
        }
    }
}

/// Directory-backed store: one JSON file per cluster report under `<base>/reports/`,
/// plus an ingest ledger (`seen.json`) of file-content fingerprints so re-running
/// ingest on the same files cannot double-count occurrences.
public final class Store {

    public let baseDir: URL
    public let reportsDir: URL
    public private(set) var clusters: [String: ClusterReport] = [:]
    /// signature → cluster id; keeps ingest merges O(1) instead of a full scan
    /// per report, and makes the merge pick deterministic on legacy journals.
    public private(set) var clusterIDBySignature: [String: String] = [:]
    public private(set) var seenFingerprints: Set<String> = []
    private let seenFileURL: URL

    public init(baseDir: URL) {
        self.baseDir = baseDir
        self.reportsDir = baseDir.appendingPathComponent("reports", isDirectory: true)
        self.seenFileURL = baseDir.appendingPathComponent("seen.json")
        try? FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)
        loadAll()
        loadSeen()
    }

    // MARK: - Persistence

    public func loadAll() {
        clusters = [:]
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: reportsDir.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var unreadable = 0
        for f in files where f.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: reportsDir.appendingPathComponent(f)),
                  let c = try? dec.decode(ClusterReport.self, from: data) else {
                unreadable += 1
                continue
            }
            clusters[c.id] = c
            if clusterIDBySignature[c.signature] == nil {
                clusterIDBySignature[c.signature] = c.id
            }
        }
        if unreadable > 0 {
            warn("skipped \(unreadable) unreadable journal file(s) under \(reportsDir.path)")
        }
    }

    public func save(_ c: ClusterReport) {
        clusters[c.id] = c
        if clusterIDBySignature[c.signature] == nil {
            clusterIDBySignature[c.signature] = c.id
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(c)
            try data.write(to: reportsDir.appendingPathComponent("\(c.id).json"), options: .atomic)
        } catch {
            warn("failed to persist cluster \(c.id): \(error)")
        }
    }

    // MARK: - Ingest ledger (dedupe)

    /// Content fingerprint for one telemetry file. Deterministic and unsalted on
    /// purpose — the ledger only needs to recognize identical bytes, not hide them.
    public static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func hasSeen(_ fingerprint: String) -> Bool {
        seenFingerprints.contains(fingerprint)
    }

    public func markSeen(_ fingerprint: String) {
        guard seenFingerprints.insert(fingerprint).inserted else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(seenFingerprints.sorted())
            try data.write(to: seenFileURL, options: .atomic)
        } catch {
            warn("failed to persist ingest ledger: \(error)")
        }
    }

    private func loadSeen() {
        guard let data = try? Data(contentsOf: seenFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        seenFingerprints = Set(list)
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data(("coroner: warning: " + message + "\n").utf8))
    }

    // MARK: - Ingest

    /// Cluster id already carrying this signature, if any (O(1) via the index).
    public func clusterID(forSignature sig: String) -> String? {
        clusterIDBySignature[sig]
    }

    /// Merge one symbolicated report into the journal. Returns the (possibly new) cluster.
    @discardableResult
    public func ingest(_ report: ParsedReport) -> ClusterReport {
        let sig = Signature.of(frames: report.frames)
        let first = clusterIDBySignature[sig].flatMap { clusters[$0] }
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
            // Out-of-order ingest: an older report backfills first_seen (기획서: first_seen은 시간상 최초).
            if report.timestamp != nil, report.timestamp! < (existing.firstSeenAt ?? report.timestamp!) {
                existing.firstSeenAt = report.timestamp
                if !BuildNumber.isNewer(build, than: existing.firstSeenBuild) {
                    existing.firstSeenBuild = build
                }
            }
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

    /// Journal loop: humans/agents promote clusters to `known` (or back) once triaged.
    @discardableResult
    public func setStatus(id: String, status: String) throws -> ClusterReport {
        let allowed = ["open", "known", "fixed-in"]
        guard allowed.contains(status) else {
            throw StoreError.invalidStatus(status)
        }
        var c = try detail(id: id)
        c.status = status
        save(c)
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

    /// Clusters last seen within the period window (used by hang-report and period digests).
    public func within(period: Period, now: Date = Date()) -> [ClusterReport] {
        guard let window = period.seconds else { return all() }
        return clusters.values
            .filter { c in
                guard let last = c.lastSeenAt else { return false }
                return now.timeIntervalSince(last) <= window
            }
            .sorted { $0.totalOccurrences > $1.totalOccurrences }
    }

    public func hangReport(period: Period, now: Date = Date()) -> [ClusterReport] {
        within(period: period, now: now).filter { $0.kind == .hang }
    }
}
