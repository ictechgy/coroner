import Foundation

public enum DiagnosticKind: String, Codable, CaseIterable, Sendable {
    case crash
    case hang
    case cpu
    case disk

    public var displayName: String {
        switch self {
        case .crash: return "crash"
        case .hang: return "hang"
        case .cpu: return "cpu-exception"
        case .disk: return "disk-write"
        }
    }

    public static func parse(_ s: String) -> DiagnosticKind? {
        switch s.lowercased() {
        case "crash": return .crash
        case "hang": return .hang
        case "cpu", "cpu-exception", "cpuexception": return .cpu
        case "disk", "disk-write", "diskwrite": return .disk
        default: return nil
        }
    }
}

/// One image (binary) referenced by a report.
public struct BinaryImage: Codable, Equatable, Sendable {
    public var name: String
    /// Normalized: dashes stripped, uppercase. nil when the source didn't provide one.
    public var uuid: String?
    /// Load address (ips `base`).
    public var base: UInt64?
    public var size: UInt64?
    /// MetricKit: vmaddr of __TEXT when known (rare); used as atos load address.
    public var textSegmentVMAddr: UInt64?

    public init(name: String, uuid: String? = nil, base: UInt64? = nil, size: UInt64? = nil, textSegmentVMAddr: UInt64? = nil) {
        self.name = name
        self.uuid = uuid
        self.base = base
        self.size = size
        self.textSegmentVMAddr = textSegmentVMAddr
    }
}

/// One stack frame, before or after symbolication.
public struct RawFrame: Codable, Equatable, Sendable {
    public var binary: String?
    /// ips: imageOffset. MetricKit: offsetIntoBinaryTextSegment.
    public var offset: UInt64?
    /// Pre-symbolicated name (ips sometimes carries `symbol`) or atos result.
    public var symbol: String?
    public var symbolLocation: Int?
    public var sampleCount: Int?
    public var sourceFile: String?
    public var line: Int?

    public init(binary: String? = nil, offset: UInt64? = nil, symbol: String? = nil,
                symbolLocation: Int? = nil, sampleCount: Int? = nil,
                sourceFile: String? = nil, line: Int? = nil) {
        self.binary = binary
        self.offset = offset
        self.symbol = symbol
        self.symbolLocation = symbolLocation
        self.sampleCount = sampleCount
        self.sourceFile = sourceFile
        self.line = line
    }
}

/// One diagnostic extracted from a .ips file or a MetricKit payload.
public struct ParsedReport: Sendable {
    public var kind: DiagnosticKind
    public var appVersion: String?
    public var buildVersion: String?
    public var timestamp: Date?
    public var deviceModel: String?
    public var osVersion: String?
    public var exceptionSummary: String?
    public var frames: [RawFrame]
    public var images: [BinaryImage]
    public var sourcePath: String

    public init(kind: DiagnosticKind, appVersion: String? = nil, buildVersion: String? = nil,
                timestamp: Date? = nil, deviceModel: String? = nil, osVersion: String? = nil,
                exceptionSummary: String? = nil, frames: [RawFrame] = [],
                images: [BinaryImage] = [], sourcePath: String = "") {
        self.kind = kind
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.timestamp = timestamp
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.exceptionSummary = exceptionSummary
        self.frames = frames
        self.images = images
        self.sourcePath = sourcePath
    }
}

/// Persisted post-mortem record — one file per cluster (기획서 §데이터 모델).
public struct ClusterReport: Codable, Equatable, Sendable {
    public var id: String
    public var kind: DiagnosticKind
    public var signature: String
    public var topFrames: [String]
    public var exceptionSummary: String?
    public var appVersion: String?
    public var firstSeenBuild: String
    public var lastSeenBuild: String
    public var firstSeenAt: Date?
    public var lastSeenAt: Date?
    public var occurrences: [String: Int]
    public var devices: [String: Int]
    public var osVersions: [String: Int]
    public var status: String   // open | known | fixed-in
    public var symbolicated: Bool

    public init(id: String, kind: DiagnosticKind, signature: String, topFrames: [String],
                exceptionSummary: String? = nil, appVersion: String? = nil,
                firstSeenBuild: String, lastSeenBuild: String,
                firstSeenAt: Date? = nil, lastSeenAt: Date? = nil,
                occurrences: [String: Int], devices: [String: Int] = [:],
                osVersions: [String: Int] = [:], status: String = "open",
                symbolicated: Bool = false) {
        self.id = id
        self.kind = kind
        self.signature = signature
        self.topFrames = topFrames
        self.exceptionSummary = exceptionSummary
        self.appVersion = appVersion
        self.firstSeenBuild = firstSeenBuild
        self.lastSeenBuild = lastSeenBuild
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.occurrences = occurrences
        self.devices = devices
        self.osVersions = osVersions
        self.status = status
        self.symbolicated = symbolicated
    }

    public var totalOccurrences: Int { occurrences.values.reduce(0, +) }

    public static func == (lhs: ClusterReport, rhs: ClusterReport) -> Bool { lhs.id == rhs.id }
}

public enum BuildNumber {
    /// Numeric build when possible ("142" → 142, "v143" → 143); nil otherwise.
    public static func of(_ s: String?) -> Int? {
        guard var t = s, !t.isEmpty else { return nil }
        while let f = t.first, !f.isNumber {
            t.removeFirst()
        }
        return Int(t)
    }

    /// first build strictly newer than `baseline`? Numeric compare when both numeric, lexicographic fallback.
    public static func isNewer(_ candidate: String?, than baseline: String) -> Bool {
        guard let c = candidate, !c.isEmpty else { return false }
        if let cn = of(c), let bn = of(baseline) {
            return cn > bn
        }
        return c > baseline
    }

    /// Not older than `baseline`? Numeric compare, lexicographic fallback.
    public static func isNewerOrEqual(_ candidate: String?, than baseline: String) -> Bool {
        guard let c = candidate, !c.isEmpty else { return false }
        if let cn = of(c), let bn = of(baseline) {
            return cn >= bn
        }
        return c >= baseline
    }
}
