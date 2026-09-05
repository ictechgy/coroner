import CoronerCore
import Foundation

let version = "0.1.0"

let helpText = """
coroner \(version) — local post-mortem triage for AI agents
MetricKit/.ips telemetry → symbolicate → cluster → version journal → agent queries

USAGE:
    coroner [--store <dir>] [--dsym <path>...] ingest <file|dir>...
    coroner [--store <dir>] list [--kind crash|hang|cpu|disk] [--limit n]
    coroner [--store <dir>] show <cluster-id>
    coroner [--store <dir>] new-since <build>   # exit 1 when new records exist (CI gate)
    coroner [--store <dir>] top [n]
    coroner [--store <dir>] is-known "<signature substring>"
    coroner [--store <dir>] hang-report [--period today|week|all]
    coroner [--store <dir>] digest [--period today|week|all]
    coroner [--store <dir>] mark <cluster-id> --status open|known|fixed-in
    coroner [--store <dir>] suspect <cluster-id> [--repo <path>] [--window-days 14]
                                   # estimate suspect_commit (git × source anchors)
    coroner [--store <dir>] mcp        # MCP server over stdio (6 tools)

OPTIONS:
    --store <dir>    journal directory (default: .coroner)
    --dsym <path>    extra dSYM search path (repeatable; env CORONER_DSYM_PATHS also honored)
    --version, --help
"""

var storeBase = URL(fileURLWithPath: ".coroner")
var dsymPaths: [String] = []
if let env = ProcessInfo.processInfo.environment["CORONER_DSYM_PATHS"], !env.isEmpty {
    dsymPaths += env.split(separator: ":").map(String.init)
}

var argv = Array(CommandLine.arguments.dropFirst())
var maskedOutput = true

while let flag = argv.first, flag == "--store" || flag == "--dsym" || flag == "--no-mask" {
    argv.removeFirst()
    switch flag {
    case "--store":
        guard let v = argv.first else { fail("missing value for --store") }
        storeBase = URL(fileURLWithPath: v)
        argv.removeFirst()
    case "--dsym":
        guard let v = argv.first else { fail("missing value for --dsym") }
        dsymPaths.append(v)
        argv.removeFirst()
    case "--no-mask":
        maskedOutput = false
    default:
        break
    }
}

guard !argv.isEmpty else { print(helpText); exit(0) }

let command = argv[0]
let rest = Array(argv.dropFirst())

// Global options only parse before the command; a trailing one would otherwise
// be swallowed as a positional arg and silently change where output goes.
if let misplaced = rest.first(where: { ["--store", "--dsym", "--no-mask"].contains($0) }) {
    fail("\(misplaced) is a global option — put it before the command: coroner \(misplaced) <value> \(command) …")
}

switch command {
case "--help", "-h", "help":
    print(helpText)
case "--version", "-V":
    print("coroner \(version)")
case "ingest":
    ingest(rest)
case "list":
    list(rest)
case "show":
    show(rest)
case "new-since":
    newSince(rest)
case "top":
    top(rest)
case "is-known":
    isKnown(rest)
case "hang-report":
    hangReport(rest)
case "digest":
    digest(rest)
case "mark":
    mark(rest)
case "suspect":
    suspect(rest)
case "mcp":
    mcp()
default:
    fail("unknown command: \(command)\n\n\(helpText)")
}

// MARK: - Commands

func ingest(_ args: [String]) {
    guard !args.isEmpty else { fail("ingest needs at least one file or directory") }
    let parser = TelemetryParser()
    let symbolicator = Symbolicator(searchPaths: dsymPaths)
    let store = Store(baseDir: storeBase)

    let files = FileDiscovery.telemetryFiles(args)

    var reportCount = 0
    var byKind: [DiagnosticKind: Int] = [:]
    var newClusters = 0
    var updatedClusters = 0
    var unsymbolicated = 0
    var parseFailures = 0
    var alreadyIngested = 0

    for f in files {
        let contents: Data
        do {
            contents = try Data(contentsOf: URL(fileURLWithPath: f))
        } catch {
            parseFailures += 1
            print("skip (unreadable): \(masked(f))")
            continue
        }
        let fingerprint = Store.fingerprint(contents)
        if store.hasSeen(fingerprint) {
            alreadyIngested += 1
            continue
        }
        guard let reports = try? parser.parse(data: contents, sourcePath: f) else {
            parseFailures += 1
            print("skip (unrecognized): \(masked(f))")
            continue
        }
        guard !reports.isEmpty else { continue }
        for var report in reports {
            report = symbolicator.symbolicate(report: report)
            let existed = store.clusterID(forSignature: Signature.of(frames: report.frames)) != nil
            let cluster = store.ingest(report)
            reportCount += 1
            byKind[report.kind, default: 0] += 1
            if existed { updatedClusters += 1 } else { newClusters += 1 }
            if !cluster.symbolicated { unsymbolicated += 1 }
        }
        store.markSeen(fingerprint)
    }

    let kinds = DiagnosticKind.allCases.compactMap { k -> String? in
        byKind[k].map { "\($0) \(k.displayName)" }
    }.joined(separator: ", ")
    print("ingested \(files.count) file(s) → \(reportCount) report(s)\(kinds.isEmpty ? "" : " [\(kinds)]")")
    print("journal: \(newClusters) new, \(updatedClusters) updated cluster(s) → \(store.clusters.count) total")
    if unsymbolicated > 0 {
        print("note: \(unsymbolicated) report(s) stayed unsymbolicated (dSYM not found — pass --dsym or install via Spotlight)")
    }
    if alreadyIngested > 0 { print("note: \(alreadyIngested) file(s) skipped — identical content already in the journal") }
    if parseFailures > 0 { print("note: \(parseFailures) unrecognizable file(s)") }
}

func list(_ args: [String]) {
    let opts = flagValues(args, flags: ["--kind", "--limit"])
    let kind = opts["--kind"].flatMap { DiagnosticKind.parse($0) }
    let limit = opts["--limit"].flatMap(Int.init)
    let store = Store(baseDir: storeBase)
    var hits = store.all(kind: kind)
    if let l = limit { hits = Array(hits.prefix(l)) }
    if hits.isEmpty {
        print("journal empty\(kind.map { " for kind \($0.displayName)" } ?? "") — run: coroner ingest <file|dir>")
        return
    }
    print("id  [kind]  first→last  total  signature")
    print(Renderer.list(hits))
}

func show(_ args: [String]) {
    guard let id = args.first else { fail("show needs a cluster id (see: coroner list)") }
    let store = Store(baseDir: storeBase)
    do {
        print(Renderer.detail(try store.detail(id: id)))
    } catch {
        fail("\(error)")
    }
}

func newSince(_ args: [String]) {
    guard let build = args.first(where: { !$0.hasPrefix("--") }) else {
        fail("new-since needs a baseline build, e.g. coroner new-since 141")
    }
    let store = Store(baseDir: storeBase)
    let hits = store.newSince(build: build)
    if hits.isEmpty {
        print("no new post-mortem records after build \(build)")
    } else {
        print("NEW since build \(build): \(hits.count) cluster(s)")
        print(Renderer.list(hits))
    }
    // CI gate: a non-empty answer must fail the build (기획서 §CI 게이트).
    exit(hits.isEmpty ? 0 : 1)
}

func top(_ args: [String]) {
    let kind = flagValues(args, flags: ["--kind"])["--kind"].flatMap { DiagnosticKind.parse($0) }
    let n = args.first(where: { Int($0) != nil }).flatMap(Int.init) ?? 10
    let store = Store(baseDir: storeBase)
    let hits = Array(store.all(kind: kind).prefix(n))
    if hits.isEmpty { print("journal empty\(kind.map { " for kind \($0.displayName)" } ?? "") — run: coroner ingest <file|dir>"); return }
    print("top \(hits.count) of \(store.clusters.count) cluster(s) by occurrences")
    print(Renderer.list(hits))
}

func isKnown(_ args: [String]) {
    guard let needle = args.first else { fail("is-known needs a signature or frame substring") }
    let store = Store(baseDir: storeBase)
    let hits = store.isKnown(signatureSubstring: needle)
    if hits.isEmpty {
        print("UNKNOWN — no cluster matches \"\(needle)\". Treat as a new failure.")
    } else {
        print("KNOWN — \(hits.count) matching cluster(s):")
        print(Renderer.list(hits))
    }
}

func hangReport(_ args: [String]) {
    let periodRaw = flagValues(args, flags: ["--period"])["--period"] ?? "all"
    guard let period = Store.Period(rawValue: periodRaw) else {
        fail("--period must be today|week|all")
    }
    let store = Store(baseDir: storeBase)
    let hits = store.hangReport(period: period)
    if hits.isEmpty {
        print("no hang diagnostics in period \(period.rawValue)")
    } else {
        print("hang diagnostics (\(period.rawValue)): \(hits.count) cluster(s), \(hits.reduce(0) { $0 + $1.totalOccurrences }) event(s)")
        print(Renderer.list(hits))
    }
}

func digest(_ args: [String]) {
    let opts = flagValues(args, flags: ["--period", "--out"])
    let periodRaw = opts["--period"] ?? "all"
    guard let period = Store.Period(rawValue: periodRaw) else {
        fail("--period must be today|week|all")
    }
    let store = Store(baseDir: storeBase)
    let hits = store.within(period: period)
    do {
        let url = try Digest.write(clusters: hits, period: period, baseDir: storeBase)
        print("digest written: \(masked(url.path)) (\(hits.count) cluster(s) in period \(period.rawValue))")
    } catch {
        fail("digest failed: \(error)")
    }
}

func mark(_ args: [String]) {
    guard let id = args.first(where: { !$0.hasPrefix("--") }) else {
        fail("mark needs a cluster id (see: coroner list)")
    }
    let status = flagValues(args, flags: ["--status"])["--status"] ?? ""
    guard !status.isEmpty else { fail("mark needs --status open|known|fixed-in") }
    let store = Store(baseDir: storeBase)
    do {
        let c = try store.setStatus(id: id, status: status)
        print("\(c.id) → status: \(c.status)")
    } catch {
        fail("\(error)")
    }
}

func mcp() {
    let store = Store(baseDir: storeBase)
    CoronerMCP.engine(store: store, version: version).serve()
}

func suspect(_ args: [String]) {
    guard let id = args.first(where: { !$0.hasPrefix("--") }) else {
        fail("suspect needs a cluster id (see: coroner list)")
    }
    let opts = flagValues(args, flags: ["--repo", "--window-days"])
    let windowDays = opts["--window-days"].flatMap(Int.init) ?? 14
    let store = Store(baseDir: storeBase)
    let cluster: ClusterReport
    do {
        cluster = try store.detail(id: id)
    } catch {
        fail("\(error)")
    }
    let repo = Suspector.resolveRepoRoot(opts["repo"] ?? ".")
    let suspects = Suspector(repoPath: repo).suspects(for: cluster, windowDays: windowDays)
    guard !suspects.isEmpty else {
        print("no suspects — requires a symbolicated cluster (source anchors) and commits near first_seen")
        return
    }
    try? store.setSuspects(id: id, suspects: suspects)
    print("suspect commits for \(id) — estimates, not verdicts:")
    for s in suspects {
        print("  \(String(s.hash.prefix(7)))  \(s.subject)")
        print("    matched: \(s.files.joined(separator: ", "))")
    }
    print("recorded on the cluster (coroner show \(id))")
}

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func masked(_ path: String) -> String {
    maskedOutput ? Renderer.maskPath(path) : path
}

func flagValues(_ args: [String], flags: [String]) -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    while i < args.count {
        if let f = flags.first(where: { args[i] == $0 }), i + 1 < args.count {
            out[f] = args[i + 1]
            i += 2
        } else {
            i += 1
        }
    }
    return out
}
