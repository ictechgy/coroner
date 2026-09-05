import Foundation

/// File discovery for ingest — lives in Core so it is unit-testable and
/// shared by any future host of `CoronerCore` (not just the CLI).
public enum FileDiscovery {

    /// Directories never worth walking: our own journal, VCS, build output.
    public static let excludedComponents: Set<String> = [".coroner", ".git", ".build", "DerivedData"]

    /// Expands files/directories into a sorted, de-duplicated list of telemetry files
    /// (.ips / .json). Missing paths are skipped silently (the caller reports counts).
    public static func telemetryFiles(_ paths: [String], fileManager: FileManager = .default) -> [String] {
        var seen = Set<String>()
        var files: [String] = []

        for p in paths {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if isTelemetryFile(p), seen.insert(p).inserted {
                    files.append(p)
                }
                continue
            }
            guard let enumerator = fileManager.enumerator(atPath: p) else { continue }
            while let entry = enumerator.nextObject() as? String {
                let components = entry.split(separator: "/").map(String.init)
                // Hidden components (dot-prefixed) and known noise never hold telemetry.
                if components.contains(where: { $0.hasPrefix(".") || excludedComponents.contains($0) }) {
                    enumerator.skipDescendants()
                    continue
                }
                guard isTelemetryFile(entry) else { continue }
                let full = URL(fileURLWithPath: p).appendingPathComponent(entry).path
                if seen.insert(full).inserted {
                    files.append(full)
                }
            }
        }
        return files.sorted()
    }

    static func isTelemetryFile(_ path: String) -> Bool {
        path.hasSuffix(".ips") || path.hasSuffix(".json")
    }
}
