import Foundation

/// File discovery for ingest — lives in Core so it is unit-testable and
/// shared by any future host of `CoronerCore` (not just the CLI).
public enum FileDiscovery {

    /// Directories never worth walking: our own journal, VCS, build output.
    public static let excludedComponents: Set<String> = [".coroner", ".git", ".build", "DerivedData"]

    /// Expands files/directories into a sorted, de-duplicated list of telemetry files
    /// (.ips / .json). Missing paths are skipped silently (the caller reports counts).
    /// Each scanned directory honors its own `.coronerignore` (gitignore-style subset).
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
            let ignore = CoronerIgnore.load(root: p, fileManager: fileManager)
            guard let enumerator = fileManager.enumerator(atPath: p) else { continue }
            while let entry = enumerator.nextObject() as? String {
                let components = entry.split(separator: "/").map(String.init)
                // Hidden components (dot-prefixed) and known noise never hold telemetry.
                if components.contains(where: { $0.hasPrefix(".") || excludedComponents.contains($0) }) {
                    enumerator.skipDescendants()
                    continue
                }
                if CoronerIgnore.matches(ignore, path: entry) {
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

/// `.coronerignore` — gitignore-style subset, zero external dependencies:
/// `#` comments and blank lines; trailing `/` marks a directory pattern
/// (matches the directory and everything under it); a pattern containing `/`
/// is anchored at the scan root, otherwise it matches any path component;
/// `*`/`?` never cross `/`, `**` does.
public enum CoronerIgnore {

    public static func load(root: String, fileManager: FileManager = .default) -> [String] {
        let url = URL(fileURLWithPath: root).appendingPathComponent(".coronerignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { return nil }
            return t
        }
    }

    public static func matches(_ patterns: [String], path: String) -> Bool {
        let comps = path.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { return false }
        for raw in patterns {
            var p = raw
            let dirOnly = p.hasSuffix("/")
            if dirOnly { p = String(p.dropLast()) }
            // A leading "/" anchors too — check before stripping it.
            let anchored = p.contains("/")
            if p.hasPrefix("/") { p = String(p.dropFirst()) }
            guard !p.isEmpty else { continue }
            if anchored {
                if glob(p, path) { return true }
                if dirOnly, prefixes(of: comps).contains(where: { glob(p, $0) }) { return true }
            } else if comps.contains(where: { glob(p, $0) }) {
                return true
            }
        }
        return false
    }

    private static func prefixes(of comps: [String]) -> [String] {
        var out: [String] = []
        var acc = ""
        for c in comps {
            acc = acc.isEmpty ? c : acc + "/" + c
            out.append(acc)
        }
        return out
    }

    /// Glob match via regex translation: `**` → `.*`, `*` → `[^/]*`, `?` → `[^/]`.
    private static func glob(_ pattern: String, _ text: String) -> Bool {
        if let cached = cache[pattern] { return cached.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil }
        var out = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            if ch == "*" {
                var j = i
                while j < pattern.endIndex, pattern[j] == "*" { j = pattern.index(after: j) }
                let double = pattern.distance(from: i, to: j) >= 2
                out += double ? ".*" : "[^/]*"
                i = j
                continue
            }
            switch ch {
            case "?": out += "[^/]"
            case "\\", "^", "$", ".", "+", "|", "(", ")", "[", "]", "{", "}": out += "\\\(ch)"
            default: out.append(ch)
            }
            i = pattern.index(after: i)
        }
        out += "$"
        guard let re = try? NSRegularExpression(pattern: out) else { return false }
        cache[pattern] = re
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static var cache: [String: NSRegularExpression] = [:]
}
