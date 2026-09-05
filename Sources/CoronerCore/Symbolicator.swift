import Foundation
import CryptoKit

// MARK: - Signature & identity

public enum Signature {

    /// Display/cluster key for one frame: symbol when known, else binary+offset.
    public static func normalizedFrame(_ f: RawFrame) -> String {
        if let s = f.symbol, !s.isEmpty { return s }
        let b = f.binary ?? "?"
        if let o = f.offset {
            return String(format: "%@+0x%llx", b, o)
        }
        return b
    }

    /// Deterministic cluster key: normalized top `depth` frames joined.
    public static func of(frames: [RawFrame], depth: Int = 3) -> String {
        frames.prefix(depth).map(normalizedFrame).joined(separator: " → ")
    }

    /// Stable id: c-<first-seen day>-<8 hex of SHA256(signature)> (기획서 §데이터 모델).
    public static func clusterID(signature: String, firstSeen: Date?) -> String {
        let digest = SHA256.hash(data: Data(signature.utf8))
        let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let day: String
        if let d = firstSeen {
            day = Self.dayFormatter.string(from: d)
        } else {
            day = "nodate"
        }
        return "c-\(day)-\(hex)"
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Address math (pure, unit-tested)

public struct AtosInvocation: Equatable {
    public var dwarfPath: String
    public var loadAddress: String   // hex string, atos -l
    public var addresses: [String]   // hex strings
}

/// Computes atos arguments for one binary's frames.
/// - ips (crash): addr = base + imageOffset, load = base.
/// - MetricKit: addr = textSegmentVMAddr(→0) + offsetIntoBinaryTextSegment.
public enum AddressMath {

    public static func invocation(binaryName: String, dwarfPath: String, frames: [RawFrame], image: BinaryImage?) -> AtosInvocation? {
        let offsets = frames.compactMap { $0.offset }
        guard !offsets.isEmpty else { return nil }
        let load = loadAddress(image: image)
        let addrs = offsets.map { String(format: "0x%llx", load &+ $0) }
        return AtosInvocation(
            dwarfPath: dwarfPath,
            loadAddress: String(format: "0x%llx", load),
            addresses: addrs
        )
    }

    public static func loadAddress(image: BinaryImage?) -> UInt64 {
        // Crash logs: __TEXT vmaddr is the image base.
        // MetricKit offsets are relative to __TEXT; vmaddr defaults to 0 for arm64 executables.
        return image?.base ?? image?.textSegmentVMAddr ?? 0
    }

    /// MetricKit-only load when no base exists.
    public static func metricKitLoadAddress(image: BinaryImage?) -> UInt64 {
        return image?.textSegmentVMAddr ?? 0
    }
}

// MARK: - dSYM location

public protocol DSymLocating {
    /// Returns a path to a .dSYM bundle (or DWARF dir) for the binary, or nil.
    func locate(binaryName: String, uuid: String?) -> String?
}

/// Spotlight-based lookup: `mdfind 'com_apple_xcode_dsym_uuids == <UUID>'`.
/// Misses are memoized per UUID — ingest of many reports must not re-run mdfind for the same binary.
public final class SpotlightLocator: DSymLocating {
    private let runner: ProcessRunning
    private var cache: [String: String?] = [:]
    public init(runner: ProcessRunning = ProcessRunner()) { self.runner = runner }

    public func locate(binaryName: String, uuid: String?) -> String? {
        guard let uuid, !uuid.isEmpty else { return nil }
        if let cached = cache[uuid] { return cached }
        let output = runner.run("/usr/bin/mdfind", ["com_apple_xcode_dsym_uuids == \(uuid)"])
        var hit: String?
        for line in output.split(separator: "\n") {
            let p = String(line)
            if FileManager.default.fileExists(atPath: p) {
                hit = p
                break
            }
        }
        cache[uuid] = hit
        return hit
    }
}

/// Explicit `--dsym` search paths; matches `<binaryName>.dSYM` directories (UUID check left to the caller's atos result).
public final class SearchPathLocator: DSymLocating {
    private let paths: [String]
    public init(paths: [String]) { self.paths = paths }

    public func locate(binaryName: String, uuid: String?) -> String? {
        let fm = FileManager.default
        for root in paths {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent("\(binaryName).dSYM").path
            if fm.fileExists(atPath: candidate) { return candidate }
            if root.hasSuffix(".dSYM"), UUIDHolder.uuid(in: root) == uuid { return root }
        }
        return nil
    }
}

public final class ChainedLocator: DSymLocating {
    private let locators: [DSymLocating]
    public init(_ locators: [DSymLocating]) { self.locators = locators }
    public func locate(binaryName: String, uuid: String?) -> String? {
        for l in locators {
            if let hit = l.locate(binaryName: binaryName, uuid: uuid) { return hit }
        }
        return nil
    }
}

enum UUIDHolder {
    static func uuid(in dsymPath: String) -> String? {
        let runner = ProcessRunner()
        let out = runner.run("/usr/bin/dwarfdump", ["--uuid", dsymPath])
        // "UUID: XXXX-... (arm64) ..."
        guard let line = out.split(separator: "\n").first,
              let range = line.range(of: "UUID: "),
              let end = line.range(of: " (") else { return nil }
        return TelemetryParser.normalizeUUID(String(line[range.upperBound..<end.lowerBound]))
    }
}

// MARK: - Process plumbing (protocol so tests can stub)

public protocol ProcessRunning {
    func run(_ launchPath: String, _ args: [String]) -> String
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    @discardableResult
    public func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        // Never pipe stderr without draining it — a chatty child would fill the
        // 64KB pipe buffer and deadlock the read of stdout.
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Symbolicator

/// Symbolicates frames by locating dSYMs (UUID → Spotlight, then name → search paths)
/// and shelling out to `atos`. Missing dSYMs are a normal state: frames stay unsymbolicated.
public final class Symbolicator {

    private let locator: DSymLocating
    private let runner: ProcessRunning

    public init(locator: DSymLocating, runner: ProcessRunning = ProcessRunner()) {
        self.locator = locator
        self.runner = runner
    }

    /// Convenience: search paths first, Spotlight as fallback.
    public convenience init(searchPaths: [String]) {
        var locators: [DSymLocating] = []
        if !searchPaths.isEmpty { locators.append(SearchPathLocator(paths: searchPaths)) }
        locators.append(SpotlightLocator())
        self.init(locator: ChainedLocator(locators))
    }

    @discardableResult
    public func symbolicate(report: ParsedReport) -> ParsedReport {
        var r = report
        var byName: [String: BinaryImage] = [:]
        for img in r.images { byName[img.name] = img }

        // Group unsymbolicated frames by binary for batched atos calls.
        var order: [Int] = []
        var byBinary: [String: [Int]] = [:]
        for (i, f) in r.frames.enumerated() where f.symbol == nil {
            let name = f.binary ?? "unknown"
            order.append(i)
            byBinary[name, default: []].append(i)
        }

        for (name, idxs) in byBinary {
            let uuid = byName[name]?.uuid
            guard let dsym = locator.locate(binaryName: name, uuid: uuid) else { continue }
            let dwarf = Self.dwarfBinary(dsymPath: dsym, binaryName: name)
            let frames = idxs.map { r.frames[$0] }
            guard let inv = AddressMath.invocation(binaryName: name, dwarfPath: dwarf,
                                                   frames: frames, image: byName[name]) else { continue }
            let output = runner.run("/usr/bin/atos",
                                    ["-o", inv.dwarfPath, "-l", inv.loadAddress] + inv.addresses)
            let lines = output.split(separator: "\n").map(String.init)
            for (slot, text) in zip(idxs, lines) {
                let parsed = Self.parseAtosLine(text)
                if let sym = parsed.symbol {
                    r.frames[slot].symbol = sym
                    r.frames[slot].sourceFile = parsed.file
                    r.frames[slot].line = parsed.line
                }
            }
        }
        return r
    }

    public static func dwarfBinary(dsymPath: String, binaryName: String) -> String {
        let fm = FileManager.default
        let direct = URL(fileURLWithPath: dsymPath)
            .appendingPathComponent("Contents/Resources/DWARF/\(binaryName)").path
        if fm.fileExists(atPath: direct) { return direct }
        let dir = (direct as NSString).deletingLastPathComponent
        if let entries = try? fm.contentsOfDirectory(atPath: dir), let first = entries.first {
            return URL(fileURLWithPath: dir).appendingPathComponent(first).path
        }
        return direct
    }

    /// "foo(bar) (in DemoApp) (View.swift:12)" → (symbol, file, line)
    public static func parseAtosLine(_ line: String) -> (symbol: String?, file: String?, line: Int?) {
        var rest = line.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return (nil, nil, nil) }
        var file: String?
        var lineNo: Int?
        // trailing "(path:line)"
        if let open = rest.lastIndex(of: "("), rest.hasSuffix(")") {
            let inner = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
            if let colon = inner.lastIndex(of: ":"), let n = Int(inner[inner.index(after: colon)...]) {
                file = String(inner[..<colon])
                lineNo = n
                rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        // trailing "(in Binary)"
        if let open = rest.lastIndex(of: "("), rest.hasSuffix(")") {
            let inner = rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]
            if inner.hasPrefix("in ") {
                rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (rest.isEmpty ? nil : rest, file, lineNo)
    }
}
