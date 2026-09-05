import Foundation

/// Minimal MCP (Model Context Protocol) server over stdio, hand-rolled JSON-RPC 2.0.
/// No SDK dependency: `initialize` / `notifications/initialized` / `tools/list` / `tools/call`,
/// unknown method → -32601, malformed JSON → -32700, EOF → clean exit.
public struct MCPEngine {

    public typealias ToolCall = (_ name: String, _ arguments: [String: Any]) -> (text: String, isError: Bool)

    public let serverName: String
    public let serverVersion: String
    public let protocolVersion: String
    public let tools: [[String: Any]]
    public let handleTool: ToolCall

    public init(serverName: String, serverVersion: String, protocolVersion: String = "2024-11-05",
                tools: [[String: Any]], handleTool: @escaping ToolCall) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.tools = tools
        self.handleTool = handleTool
    }

    /// Process one JSON-RPC line. Returns the response line, or nil for notifications.
    public func handle(line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Self.json(["jsonrpc": "2.0", "id": NSNull(),
                              "error": ["code": -32700, "message": "parse error"]])
        }
        let method = obj["method"] as? String ?? ""
        let hasID = obj["id"] != nil && !(obj["id"] is NSNull)
        let id: Any = obj["id"] ?? NSNull()

        switch method {
        case "initialize":
            guard hasID else { return nil }
            return Self.json([
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": serverName, "version": serverVersion],
                ],
            ])
        case "notifications/initialized", "initialized":
            return nil
        case "tools/list":
            guard hasID else { return nil }
            return Self.json(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
        case "tools/call":
            guard hasID else { return nil }
            let params = obj["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let out = handleTool(name, args)
            var result: [String: Any] = ["content": [["type": "text", "text": out.text]]]
            if out.isError {
                result["isError"] = true
            }
            return Self.json([
                "jsonrpc": "2.0", "id": id,
                "result": result,
            ])
        default:
            guard hasID else { return nil }
            return Self.json(["jsonrpc": "2.0", "id": id,
                              "error": ["code": -32601, "message": "method not found: \(method)"]])
        }
    }

    /// stdio serve loop. Returns when stdin reaches EOF.
    public func serve() {
        while let line = readLine(strippingNewline: true) {
            if let out = handle(line: line) {
                FileHandle.standardOutput.write(Data((out + "\n").utf8))
            }
        }
    }

    static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"internal\"},\"id\":null}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func tool(name: String, description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        return [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
            ] as [String: Any],
        ]
    }
}

/// coroner's six agent-facing tools (기획서 §워크플로).
public enum CoronerMCP {

    public static func engine(store: Store, version: String) -> MCPEngine {
        let tools: [[String: Any]] = [
            MCPEngine.tool(
                name: "new_since",
                description: "Post-mortem records first seen strictly after the given build. Ask this first after a release.",
                properties: [
                    "build": ["type": "string", "description": "baseline build number, e.g. \"141\""],
                    "kind": ["type": "string", "enum": ["crash", "hang", "cpu", "disk"]],
                ],
                required: ["build"]),
            MCPEngine.tool(
                name: "top_crashes",
                description: "Top clusters by occurrences.",
                properties: [
                    "n": ["type": "number", "description": "how many (default 10)"],
                    "kind": ["type": "string", "enum": ["crash", "hang", "cpu", "disk"]],
                ]),
            MCPEngine.tool(
                name: "crash_detail",
                description: "Full post-mortem record for one cluster id (works for any kind).",
                properties: ["id": ["type": "string"]], required: ["id"]),
            MCPEngine.tool(
                name: "is_known",
                description: "Have I seen this failure before? Match by signature or top-frame substring.",
                properties: ["signature": ["type": "string"]], required: ["signature"]),
            MCPEngine.tool(
                name: "hang_report",
                description: "Hang diagnostics (main-thread unresponsiveness) within a period.",
                properties: ["period": ["type": "string", "enum": ["today", "week", "all"]]]),
            MCPEngine.tool(
                name: "digest",
                description: "Deterministic Markdown digest of the journal for a period.",
                properties: ["period": ["type": "string", "enum": ["today", "week", "all"]]]),
            MCPEngine.tool(
                name: "suspects",
                description: "Estimate suspect commits for a cluster: first-seen build/date crossed with git history and the cluster's source anchors (build tags preferred, date window fallback). Estimates, not verdicts.",
                properties: [
                    "id": ["type": "string", "description": "cluster id"],
                    "repo": ["type": "string", "description": "git repo path (default: cwd)"],
                    "window_days": ["type": "number", "description": "date-window fallback in days (default 14)"],
                ],
                required: ["id"]),
        ]

        return MCPEngine(serverName: "coroner", serverVersion: version, tools: tools) { name, args in
            func arg(_ key: String) -> String? { args[key] as? String }
            func intArg(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue }
            let kind = arg("kind").flatMap { DiagnosticKind.parse($0) }
            func ok(_ text: String) -> (text: String, isError: Bool) { (text, false) }
            func err(_ text: String) -> (text: String, isError: Bool) { (text, true) }

            switch name {
            case "new_since":
                guard let build = arg("build") else {
                    return err("error: `build` is required (baseline build number)")
                }
                let hits = store.newSince(build: build, kind: kind)
                return ok(hits.isEmpty
                    ? "No new post-mortem records after build \(build)."
                    : Renderer.list(hits))
            case "top_crashes":
                let n = intArg("n") ?? 10
                let hits = Array(store.all(kind: kind).prefix(n))
                return ok(hits.isEmpty ? "Journal is empty — ingest telemetry first." : Renderer.list(hits))
            case "crash_detail":
                guard let id = arg("id") else { return err("error: `id` is required") }
                guard let c = try? store.detail(id: id) else { return err("no record with id \(id)") }
                return ok(Renderer.detail(c))
            case "is_known":
                guard let sig = arg("signature") else { return err("error: `signature` is required") }
                let hits = store.isKnown(signatureSubstring: sig)
                return ok(hits.isEmpty
                    ? "UNKNOWN — no cluster matches \"\(sig)\". Treat as a new failure."
                    : "KNOWN — \(hits.count) matching cluster(s):\n" + Renderer.list(hits))
            case "hang_report":
                let period = arg("period").flatMap(Store.Period.init(rawValue:)) ?? .all
                let hits = store.hangReport(period: period)
                return ok(hits.isEmpty
                    ? "No hang diagnostics in period \(period.rawValue)."
                    : Renderer.list(hits))
            case "digest":
                let period = arg("period").flatMap(Store.Period.init(rawValue:)) ?? .all
                return ok(Digest.markdown(clusters: store.within(period: period), period: period))
            case "suspects":
                guard let id = arg("id") else { return err("error: `id` is required") }
                guard let c = try? store.detail(id: id) else { return err("no record with id \(id)") }
                let repo = Suspector.resolveRepoRoot(arg("repo") ?? ".")
                let hits = Suspector(repoPath: repo).suspects(for: c, windowDays: intArg("window_days") ?? 14)
                guard !hits.isEmpty else {
                    return ok("no suspects — requires a symbolicated cluster (source anchors) and commits near first_seen")
                }
                try? store.setSuspects(id: id, suspects: hits)
                return ok(hits.map {
                    "\(String($0.hash.prefix(7)))  \($0.subject)  [matched: \($0.files.joined(separator: ", "))]"
                }.joined(separator: "\n"))
            default:
                return err("unknown tool: \(name)")
            }
        }
    }
}
