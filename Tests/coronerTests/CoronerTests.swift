import XCTest
@testable import CoronerCore

final class CoronerTests: XCTestCase {

    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    func tempStore() -> Store {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-test-\(UUID().uuidString)", isDirectory: true)
        return Store(baseDir: dir)
    }

    func ingest(_ store: Store, _ fixtureName: String, searchPaths: [String] = []) {
        let parser = TelemetryParser()
        let symbolicator = Symbolicator(locator: SearchPathLocator(paths: searchPaths))
        let reports = try! parser.parseFile(at: fixture(fixtureName).path)
        XCTAssertFalse(reports.isEmpty, "fixture \(fixtureName) must parse")
        for r in reports {
            store.ingest(symbolicator.symbolicate(report: r))
        }
    }

    // MARK: - .ips parsing

    func testIPSTwoPartParsing() throws {
        let reports = try TelemetryParser().parseFile(at: fixture("crash-new-142.ips").path)
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.kind, .crash)
        XCTAssertEqual(r.buildVersion, "142")
        XCTAssertEqual(r.appVersion, "2.1.0")
        XCTAssertEqual(r.osVersion, "iOS 19.1")
        XCTAssertEqual(r.deviceModel, "iPhone15,3")
        XCTAssertEqual(r.exceptionSummary, "EXC_CRASH SIGABRT")
        XCTAssertEqual(r.images.count, 2)
        XCTAssertEqual(r.images[0].uuid, "11111111222233334444555555555555")
        XCTAssertEqual(r.frames.count, 3)
        XCTAssertEqual(r.frames[0].binary, "DemoApp")
        XCTAssertEqual(r.frames[0].offset, 4112)
        XCTAssertNotNil(r.timestamp)
    }

    func testIPSMissingFaultingThreadFallsBack() throws {
        // body without faultingThread → first triggered thread
        let body = """
        {"threads":[{"frames":[{"imageIndex":0,"imageOffset":1}]},{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":2}]}],"usedImages":[{"name":"A","base":0}]}
        """
        let reports = try TelemetryParser().parse(data: Data(body.utf8), sourcePath: "inline")
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].frames.count, 1)
        XCTAssertEqual(reports[0].frames[0].offset, 2)
    }

    // MARK: - MetricKit parsing

    func testMetricKitJSONLinesAndNestedFlattening() throws {
        let reports = try TelemetryParser().parseFile(at: fixture("metrickit-hang.json").path)
        XCTAssertEqual(reports.count, 2, "JSON Lines → two hang payloads")
        for r in reports {
            XCTAssertEqual(r.kind, .hang)
            XCTAssertEqual(r.buildVersion, "142")
            XCTAssertEqual(r.deviceModel, "iPhone12,1")
        }
        // depth-first: parent 2048 first, then nested 4112
        XCTAssertEqual(reports[0].frames.map { $0.offset }, [2048, 4112])
        XCTAssertEqual(reports[0].frames[0].sampleCount, 120)
    }

    func testMetricKitCPUAndDiskKinds() throws {
        let reports = try TelemetryParser().parseFile(at: fixture("metrickit-cpu-disk.json").path)
        XCTAssertEqual(reports.map { $0.kind }, [.cpu, .disk])
        XCTAssertEqual(reports[0].buildVersion, "143")
        XCTAssertNotNil(reports[0].exceptionSummary)
    }

    func testTolerantOfUnknownAndMissingFields() throws {
        let payload = """
        {"crashDiagnostics":[{"brandNewFutureField":123,"diagnosticMetaData":{"appBuildVersion":"7"},"timeStampBegin":"2026-09-05T00:00:00Z","callStackTree":{"callStacks":[{"threadAttributed":true,"frames":[{"binaryName":"A","offsetIntoBinaryTextSegment":10,"somethingNew":true}]}]}}]}
        """
        let reports = try TelemetryParser().parse(data: Data(payload.utf8), sourcePath: "inline")
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].kind, .crash)
        XCTAssertEqual(reports[0].frames[0].offset, 10)
        XCTAssertNil(reports[0].deviceModel)
    }

    func testUnrecognizedFormatThrows() {
        XCTAssertThrowsError(try TelemetryParser().parse(data: Data("not json at all".utf8), sourcePath: "x"))
    }

    func testUTF8BOMIsTolerated() throws {
        let base = try Data(contentsOf: fixture("crash-new-142.ips"))
        let bom = Data([0xEF, 0xBB, 0xBF])
        let reports = try TelemetryParser().parse(data: bom + base, sourcePath: "bom")
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].buildVersion, "142")
    }

    func testUUIDNormalizationIsHexOnly() {
        XCTAssertEqual(TelemetryParser.normalizeUUID("ab-cd-ef"), "ABCDEF")
        XCTAssertEqual(TelemetryParser.normalizeUUID("not-a-uuid!"), "AD", "only hex characters survive")
        XCTAssertNil(TelemetryParser.normalizeUUID("!!!"))
        XCTAssertNil(TelemetryParser.normalizeUUID(nil))
    }

    // MARK: - Signature & clustering

    func testSignatureUnsymbolicatedUsesBinaryOffset() {
        let f = RawFrame(binary: "DemoApp", offset: 0x1010)
        XCTAssertEqual(Signature.normalizedFrame(f), "DemoApp+0x1010")
    }

    func testSignaturePrefersSymbol() {
        let f = RawFrame(binary: "DemoApp", offset: 0x1010, symbol: "SessionStore.dequeue")
        XCTAssertEqual(Signature.normalizedFrame(f), "SessionStore.dequeue")
    }

    func testClusterIDFormat() {
        let id = Signature.clusterID(signature: "DemoApp+0x1010", firstSeen: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(id.hasPrefix("c-19700101-"))
        let hexPart = id.dropFirst("c-19700101-".count)
        XCTAssertEqual(hexPart.count, 8)
        XCTAssertTrue(hexPart.allSatisfy { $0.isHexDigit })
    }

    func testSameSignatureMergesIntoOneCluster() {
        let store = tempStore()
        ingest(store, "crash-new-142.ips")
        ingest(store, "crash-new2-142.ips")
        ingest(store, "crash-new-143.ips")
        XCTAssertEqual(store.clusters.count, 1)
        let c = try! store.detail(id: store.clusters.values.first!.id)
        XCTAssertEqual(c.occurrences, ["142": 2, "143": 1])
        XCTAssertEqual(c.totalOccurrences, 3)
        XCTAssertEqual(c.firstSeenBuild, "142")
        XCTAssertEqual(c.lastSeenBuild, "143")
        XCTAssertEqual(c.devices, ["iPhone15,3": 2, "iPhone14,2": 1])
        XCTAssertEqual(c.osVersions, ["iOS 19.1": 3])
    }

    func testDifferentSignatureSeparatesClusters() {
        let store = tempStore()
        ingest(store, "crash-new-142.ips")
        ingest(store, "crash-old-141.ips")
        XCTAssertEqual(store.clusters.count, 2)
    }

    // MARK: - Journal queries

    func testNewSinceUsesNumericCompare() {
        let store = tempStore()
        ingest(store, "crash-old-141.ips")
        ingest(store, "crash-new-142.ips")
        ingest(store, "crash-new-143.ips")
        XCTAssertEqual(store.newSince(build: "141").count, 1)
        XCTAssertEqual(store.newSince(build: "142").count, 0)
        XCTAssertEqual(store.newSince(build: "140").count, 2)
    }

    func testTopSortsByOccurrences() {
        let store = tempStore()
        ingest(store, "crash-old-141.ips")
        ingest(store, "crash-new-142.ips")
        ingest(store, "crash-new2-142.ips")
        let top = store.all()
        XCTAssertEqual(top.first?.totalOccurrences, 2)
    }

    func testIsKnownMatchesSignatureAndFrames() {
        let store = tempStore()
        ingest(store, "crash-new-142.ips")
        XCTAssertEqual(store.isKnown(signatureSubstring: "demoapp+0x1010").count, 1, "case-insensitive match")
        XCTAssertEqual(store.isKnown(signatureSubstring: "libsystem").count, 1, "top-frame match")
        XCTAssertTrue(store.isKnown(signatureSubstring: "no such thing").isEmpty)
    }

    func testHangReportPeriodFilter() {
        let store = tempStore()
        ingest(store, "metrickit-hang.json")
        XCTAssertEqual(store.hangReport(period: .all).count, 1, "same signature merges the two hang payloads")
        // inject `now` so the test is wall-clock independent
        let last = try! store.detail(id: store.clusters.values.first!.id).lastSeenAt!
        XCTAssertEqual(store.hangReport(period: .today, now: last.addingTimeInterval(3600)).count, 1)
        XCTAssertEqual(store.hangReport(period: .week, now: last.addingTimeInterval(3 * 24 * 3600)).count, 1)
        XCTAssertEqual(store.hangReport(period: .week, now: last.addingTimeInterval(30 * 24 * 3600)).count, 0)
    }

    func testPersistenceAcrossStoreInstances() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-test-\(UUID().uuidString)", isDirectory: true)
        do {
            let a = Store(baseDir: dir)
            ingest(a, "crash-new-142.ips")
        }
        let b = Store(baseDir: dir)
        XCTAssertEqual(b.clusters.count, 1)
    }

    func testFirstSeenBackfillsOnOutOfOrderIngest() {
        let store = tempStore()
        ingest(store, "crash-new-143.ips")   // newer build first
        ingest(store, "crash-new-142.ips")   // older report of the same signature
        XCTAssertEqual(store.clusters.count, 1)
        let c = store.clusters.values.first!
        XCTAssertEqual(c.firstSeenBuild, "142", "older report must backfill first_seen")
        XCTAssertEqual(c.lastSeenBuild, "143")
        XCTAssertEqual(c.occurrences, ["142": 1, "143": 1])
    }

    func testMarkStatus() {
        let store = tempStore()
        ingest(store, "crash-new-142.ips")
        let id = store.clusters.values.first!.id
        XCTAssertEqual(try! store.setStatus(id: id, status: "known").status, "known")
        // persisted
        XCTAssertEqual(try! Store(baseDir: store.baseDir).detail(id: id).status, "known")
        XCTAssertThrowsError(try store.setStatus(id: id, status: "bogus"))
    }

    func testWithinPeriodUsesInjectedNow() {
        let store = tempStore()
        ingest(store, "crash-old-141.ips")            // last seen 2026-09-01
        ingest(store, "crash-new-142.ips")            // last seen 2026-09-04
        let crash142 = store.clusters.values.first { $0.firstSeenBuild == "142" }!
        let crash141 = store.clusters.values.first { $0.firstSeenBuild == "141" }!
        let sep4 = crash142.lastSeenAt!.addingTimeInterval(3600)   // 09-04T22:15
        XCTAssertEqual(store.within(period: .today, now: sep4).map { $0.id }, [crash142.id])
        XCTAssertEqual(Set(store.within(period: .week, now: sep4).map { $0.id }), [crash142.id, crash141.id])
        XCTAssertEqual(store.within(period: .all, now: sep4).count, 2)
        let sep12 = crash142.lastSeenAt!.addingTimeInterval(8 * 24 * 3600)  // 09-12: both stale
        XCTAssertEqual(store.within(period: .week, now: sep12).count, 0)
        XCTAssertEqual(store.within(period: .all, now: sep12).count, 2)
    }

    func testDigestPeriodFiltering() {
        let store = tempStore()
        ingest(store, "crash-old-141.ips")
        ingest(store, "metrickit-hang.json")
        let hang = store.clusters.values.first { $0.kind == .hang }!
        let now = hang.lastSeenAt!.addingTimeInterval(3600)
        let today = Digest.markdown(clusters: store.within(period: .today, now: now), period: .today)
        XCTAssertTrue(today.contains(hang.id))
        XCTAssertFalse(today.contains("DemoApp+0x3030"), "the 2026-09-01 cluster is outside 'today'")
    }

    func testDiscoverySkipsExcludedDirsAndNonTelemetry() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-disc-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for rel in ["a.ips", "sub/b.json", "notes.txt", ".coroner/reports/x.json", ".build/y.ips",
                    ".git/z.json", "DerivedData/w.ips", ".hidden/v.ips", ".secret.json"] {
            let f = root.appendingPathComponent(rel)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: f.path, contents: Data("{}".utf8))
        }
        let found = FileDiscovery.telemetryFiles([root.path])
        XCTAssertEqual(found.count, 2, "only a.ips and sub/b.json — hidden/excluded dirs skipped")
        XCTAssertTrue(found[0].hasSuffix("a.ips"))
        XCTAssertTrue(found[1].hasSuffix("sub/b.json"))
        // single explicit file passes through
        XCTAssertEqual(FileDiscovery.telemetryFiles([root.appendingPathComponent("a.ips").path]).count, 1)
        // missing path is skipped, not fatal
        XCTAssertEqual(FileDiscovery.telemetryFiles(["/no/such/path"]).count, 0)
    }

    // MARK: - Build numbers

    func testBuildNumberParsing() {
        XCTAssertEqual(BuildNumber.of("142"), 142)
        XCTAssertEqual(BuildNumber.of("v143"), 143)
        XCTAssertNil(BuildNumber.of("beta"))
        XCTAssertTrue(BuildNumber.isNewer("142", than: "141"))
        XCTAssertFalse(BuildNumber.isNewer("142", than: "142"))
        XCTAssertTrue(BuildNumber.isNewerOrEqual("142", than: "142"))
    }

    // MARK: - Address math & atos

    func testCrashAddressMathUsesImageBase() {
        let image = BinaryImage(name: "DemoApp", base: 0x100_0000_0000)
        let inv = AddressMath.invocation(binaryName: "DemoApp", dwarfPath: "/x.dSYM",
                                         frames: [RawFrame(binary: "DemoApp", offset: 0x1010)], image: image)
        XCTAssertEqual(inv?.loadAddress, "0x10000000000")
        XCTAssertEqual(inv?.addresses, ["0x10000001010"])
    }

    func testMetricKitAddressMathDefaultsToZeroLoad() {
        let inv = AddressMath.invocation(binaryName: "DemoApp", dwarfPath: "/x.dSYM",
                                         frames: [RawFrame(binary: "DemoApp", offset: 2048)], image: nil)
        XCTAssertEqual(inv?.loadAddress, "0x0")
        XCTAssertEqual(inv?.addresses, ["0x800"])
    }

    func testAtosLineParsing() {
        let a = Symbolicator.parseAtosLine("SessionStore.dequeue (in DemoApp) (sessionStore.swift:88)")
        XCTAssertEqual(a.symbol, "SessionStore.dequeue")
        XCTAssertEqual(a.file, "sessionStore.swift")
        XCTAssertEqual(a.line, 88)
        let b = Symbolicator.parseAtosLine("main (in DemoApp)")
        XCTAssertEqual(b.symbol, "main")
        XCTAssertNil(b.file)
        let c = Symbolicator.parseAtosLine("0x100001010 (in DemoApp)")
        XCTAssertEqual(c.symbol, "0x100001010")
    }

    func testSymbolicationWithStubbedAtos() {
        // fake dSYM layout: <tmp>/DemoApp.dSYM/Contents/Resources/DWARF/DemoApp
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-dsym-\(UUID().uuidString)", isDirectory: true)
        let dwarf = tmp.appendingPathComponent("DemoApp.dSYM/Contents/Resources/DWARF/DemoApp")
        try! FileManager.default.createDirectory(at: dwarf.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dwarf.path, contents: Data())

        struct StubRunner: ProcessRunning {
            func run(_ launchPath: String, _ args: [String]) -> String {
                "SessionStore.dequeue (in DemoApp) (sessionStore.swift:88)\nSessionStore.flush (in DemoApp)"
            }
        }

        var report = try! TelemetryParser().parseFile(at: fixture("crash-new-142.ips").path)[0]
        let symbolicator = Symbolicator(locator: SearchPathLocator(paths: [tmp.path]), runner: StubRunner())
        report = symbolicator.symbolicate(report: report)
        XCTAssertEqual(report.frames[0].symbol, "SessionStore.dequeue")
        XCTAssertEqual(report.frames[0].sourceFile, "sessionStore.swift")
        XCTAssertEqual(report.frames[0].line, 88)
        XCTAssertEqual(report.frames[1].symbol, "SessionStore.flush")
        // third frame is libsystem_c — no dSYM on purpose → stays raw
        XCTAssertNil(report.frames[2].symbol)

        // symbolicated signature replaces binary+offset
        let sig = Signature.of(frames: report.frames)
        XCTAssertTrue(sig.hasPrefix("SessionStore.dequeue → SessionStore.flush"))
    }

    func testMissingDSYMStaysUnsymbolicated() {
        var report = try! TelemetryParser().parseFile(at: fixture("crash-new-142.ips").path)[0]
        let symbolicator = Symbolicator(locator: SearchPathLocator(paths: []))
        report = symbolicator.symbolicate(report: report)
        XCTAssertNil(report.frames[0].symbol)
    }

    // MARK: - MCP

    func testMCPInitializeToolsListAndCalls() {
        let store = tempStore()
        ingest(store, "crash-old-141.ips")
        ingest(store, "crash-new-142.ips")
        let engine = CoronerMCP.engine(store: store, version: "0.1.0")

        let initResponse = engine.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        XCTAssertNotNil(initResponse)
        XCTAssertTrue(initResponse!.contains("\"protocolVersion\""))
        XCTAssertTrue(initResponse!.contains("coroner"))

        XCTAssertNil(engine.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#),
                     "notification produces no response")

        let list = engine.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(list.contains("new_since"))
        XCTAssertTrue(list.contains("top_crashes"))
        XCTAssertTrue(list.contains("crash_detail"))
        XCTAssertTrue(list.contains("is_known"))
        XCTAssertTrue(list.contains("hang_report"))
        XCTAssertTrue(list.contains("digest"))

        let call = engine.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"new_since","arguments":{"build":"141"}}}"#)!
        XCTAssertTrue(call.contains("DemoApp"), "new_since must surface the 142 cluster")
        XCTAssertFalse(call.contains("DemoApp+0x3030"), "the 141 cluster must not appear")

        let known = engine.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"is_known","arguments":{"signature":"demoapp+0x1010"}}}"#)!
        XCTAssertTrue(known.contains("KNOWN"))

        let unknown = engine.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"bogus"}"#)!
        XCTAssertTrue(unknown.contains("-32601"))

        let unknownTool = engine.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#)!
        XCTAssertTrue(unknownTool.contains("isError"), "tool-level failures must set isError")
        XCTAssertTrue(unknownTool.contains("unknown tool"))

        let malformed = engine.handle(line: "{not json")!
        XCTAssertTrue(malformed.contains("-32700"))
    }

    func testMCPSpawnIntegration() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bin = packageRoot.appendingPathComponent(".build/debug/coroner")
        guard FileManager.default.fileExists(atPath: bin.path) else {
            throw XCTSkip("debug executable not built yet")
        }
        let storeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-mcp-\(UUID().uuidString)", isDirectory: true)
        let store = Store(baseDir: storeDir)
        ingest(store, "crash-new-142.ips")

        let p = Process()
        p.executableURL = bin
        p.arguments = ["mcp", "--store", storeDir.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        try p.run()
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        for l in lines {
            inPipe.fileHandleForWriting.write(Data((l + "\n").utf8))
        }
        inPipe.fileHandleForWriting.closeFile()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        let responses = out.split(separator: "\n")
        XCTAssertEqual(responses.count, 2, "notification must be silent")
        XCTAssertTrue(responses[0].contains("\"protocolVersion\""))
        XCTAssertTrue(responses[1].contains("new_since"))
    }

    // MARK: - Digest & rendering

    func testDigestMarkdown() {
        let store = tempStore()
        ingest(store, "crash-old-141.ips")
        ingest(store, "crash-new-142.ips")
        let md = Digest.markdown(clusters: store.all(), period: .all)
        XCTAssertTrue(md.contains("# coroner"))
        XCTAssertTrue(md.contains("| id | kind | signature | first | last | total | builds | status |"))
        XCTAssertTrue(md.contains("DemoApp+0x1010"))
    }

    func testDigestWritesFile() throws {
        let store = tempStore()
        ingest(store, "crash-new-142.ips")
        let url = try Digest.write(clusters: store.all(), period: .all, baseDir: store.baseDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(url.path.contains("/digest/"))
    }

    func testPathMasking() {
        let home = NSHomeDirectory()
        XCTAssertEqual(Renderer.maskPath("\(home)/secret/x.ips"), "~/secret/x.ips")
        XCTAssertEqual(Renderer.maskPath("/opt/data/x.ips"), "/opt/data/x.ips")
    }
}
