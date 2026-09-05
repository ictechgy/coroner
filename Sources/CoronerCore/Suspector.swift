import Foundation

/// Cross-references a cluster's first-seen window with git history
/// (기획서 §suspect_commit): commits between `firstSeenAt - windowDays` and
/// `firstSeenAt + 1d` whose changed files match the cluster's source anchors.
///
/// The result is an ESTIMATE, not a verdict — "수정 에이전트의 첫 페이지".
/// Without symbolicated source anchors there is nothing to anchor to, and the
/// honest answer is an empty list.
public struct Suspector {

    public let runner: ProcessRunning
    public let repoPath: String

    public init(runner: ProcessRunning = ProcessRunner(), repoPath: String) {
        self.runner = runner
        self.repoPath = repoPath
    }

    public func suspects(for cluster: ClusterReport, windowDays: Int = 14, limit: Int = 5) -> [SuspectCommit] {
        guard let first = cluster.firstSeenAt else { return [] }
        let anchors = Set((cluster.sourceAnchors ?? []).map { $0.lowercased() })
        guard !anchors.isEmpty else { return [] }

        let since = first.addingTimeInterval(-Double(windowDays) * 86400)
        let until = first.addingTimeInterval(86400)
        let out = runner.run("/usr/bin/git", [
            "-C", repoPath, "log", "--name-only", "--no-renames",
            "--since=\(Self.iso.string(from: since))",
            "--until=\(Self.iso.string(from: until))",
            "--pretty=format:%H\(recordSep)%s",
        ])

        var suspects: [SuspectCommit] = []
        var hash: String?, subject: String?
        var files: [String] = []
        func flush() {
            guard let h = hash, let s = subject else { return }
            let matched = files.filter { anchors.contains(($0 as NSString).lastPathComponent.lowercased()) }
            if !matched.isEmpty {
                suspects.append(SuspectCommit(hash: h, subject: s, files: matched))
            }
            files = []
        }
        for line in out.split(separator: "\n") {
            if let sep = line.firstIndex(of: recordSep) {
                flush()
                hash = String(line[..<sep])
                subject = String(line[line.index(after: sep)...])
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, hash != nil {
                files.append(String(line))
            }
        }
        flush()
        return Array(suspects.prefix(limit))
    }

    /// Resolves a repo-ish path to its work-tree root; returns the input on any git failure.
    public static func resolveRepoRoot(_ path: String, runner: ProcessRunning = ProcessRunner()) -> String {
        let out = runner.run("/usr/bin/git", ["-C", path, "rev-parse", "--show-toplevel"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? path : trimmed
    }

    private let recordSep: Character = "\u{1f}"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
