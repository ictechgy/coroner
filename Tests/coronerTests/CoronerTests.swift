import XCTest
import CryptoKit
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

    // MARK: - Real-world corpus (Fixtures/real — see README "실데이터 검증")

    func testRealIPSIOS16PrettyPrintedBody() throws {
        // Real iOS 16 .ips (MacSymbolicator test corpus): Apple pretty-prints the
        // body JSON, which puts blank lines INSIDE the body (empty dicts like
        // "factorPackIds" : {\n\n}). The metadata/body split must survive them.
        let reports = try TelemetryParser().parseFile(at: fixture("real/ios16-pretty-printed.ips").path)
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.kind, .crash)
        XCTAssertEqual(r.buildVersion, "1")
        XCTAssertEqual(r.osVersion, "iPhone OS 16.0 (20A362)")
        XCTAssertTrue(r.exceptionSummary?.contains("EXC_BREAKPOINT") ?? false)
        XCTAssertFalse(r.frames.isEmpty, "faulting-thread frames must survive the split")
        XCTAssertNotNil(r.images.first { $0.name == "iOSCrashingTest" }?.uuid)
        XCTAssertNotNil(r.timestamp, "Apple '.ips' timestamp '2022-09-18 15:28:37.00 +0900' must parse")
    }

    func testRealMetricKitIOS14Payload() throws {
        // Real iOS 14 MXDiagnosticPayload (Sherlouk gist): frames live under
        // "callStackRootFrames" (not "frames"), device key is "deviceType",
        // and timestamps sit at payload level in Apple's own date format.
        let reports = try TelemetryParser().parseFile(at: fixture("real/metrickit-ios14-real.json").path)
        XCTAssertEqual(reports.map { $0.kind }, [.crash, .hang, .cpu, .disk])
        for r in reports {
            XCTAssertEqual(r.buildVersion, "1")
            XCTAssertEqual(r.appVersion, "1.0")
            XCTAssertEqual(r.deviceModel, "iPhone8,2")
            XCTAssertFalse(r.frames.isEmpty, "callStackRootFrames must be read")
            XCTAssertNotNil(r.timestamp, "payload-level timeStampBegin must apply")
        }
        XCTAssertEqual(reports[0].frames[0].binary, "testBinaryName")
        XCTAssertNotNil(reports[0].exceptionSummary)
        XCTAssertNil(reports[2].exceptionSummary, "cpuException diagnostics carry no exceptionType")
        // frame-level binaryUUIDs rebuild the missing image table → dSYM lookup possible
        let img = reports[0].images.first { $0.name == "testBinaryName" }
        XCTAssertNotNil(img?.uuid, "frame binaryUUID must survive into the image table")
    }

    func testRealIPSXcodeTranslatedExport() throws {
        // Xcode Organizer exports prepend a human-readable "Translated Report"
        // with the raw metadata+body JSON appended after it (real file from
        // flutter/flutter#148927). The split must find the JSON line, not line 0.
        let reports = try TelemetryParser().parseFile(at: fixture("real/xcode-translated-flutter-241.ips").path)
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.buildVersion, "241")
        XCTAssertEqual(r.appVersion, "2.0.0")
        XCTAssertTrue(r.exceptionSummary?.contains("EXC_CRASH") ?? false)
        XCTAssertFalse(r.frames.isEmpty)
        XCTAssertNotNil(r.timestamp, "'+0800' Apple timestamp must parse")
    }

    func testRealIPSDotNetMaui() throws {
        // Real .NET MAUI app crash (dotnet/maui#29641) — different toolchain,
        // same Apple .ips shape; guards against toolchain-specific assumptions.
        let reports = try TelemetryParser().parseFile(at: fixture("real/dotnet-maui-241.ips").path)
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.osVersion, "iPhone OS 15.8.4 (19H390)")
        XCTAssertTrue(r.exceptionSummary?.contains("EXC_BAD_ACCESS") ?? false)
        XCTAssertGreaterThan(r.frames.count, 10)
        XCTAssertFalse(r.images.isEmpty)
    }

    func testRealIPSMacOSMonterey() throws {
        // Real macOS 12 .ips (xsscx/srd research corpus): same body shape as iOS,
        // but export fields app_version/build_version arrive as EMPTY STRINGS —
        // they must land as nil (journal key "unknown"), not "".
        let reports = try TelemetryParser().parseFile(at: fixture("real/macos-monterey-309.ips").path)
        XCTAssertEqual(reports.count, 1)
        let r = reports[0]
        XCTAssertEqual(r.osVersion, "macOS 12.3.1 (21E258)")
        XCTAssertNil(r.buildVersion, "empty-string build must coalesce to nil")
        XCTAssertNil(r.appVersion)
        XCTAssertFalse(r.frames.isEmpty)
        let store = tempStore()
        _ = store.ingest(r)
        XCTAssertEqual(store.clusters.values.first?.occurrences.keys.sorted(), ["unknown"])
    }

    func testRealMetricKitIOS15Payload() throws {
        // Real iOS 15.1 crash diagnostic (transcribed from a plist-dump published
        // on 393698063.github.io): numeric exceptionType/signal, deviceType key,
        // callStackRootFrames — the iOS 15+ shape so far absent from the corpus.
        let reports = try TelemetryParser().parseFile(at: fixture("real/metrickit-ios15-real.json").path)
        XCTAssertEqual(reports.map { $0.kind }, [.crash])
        let r = reports[0]
        XCTAssertEqual(r.osVersion, "iPhone OS 15.1 (19B74)")
        XCTAssertEqual(r.deviceModel, "iPhone13,2")
        XCTAssertEqual(r.exceptionSummary, "1", "numeric exceptionType stays meaningful")
        XCTAssertEqual(r.frames.map { $0.binary }, ["ALALivePlayerFramework", "libsystem_pthread.dylib"])
        XCTAssertNotNil(r.images.first { $0.name == "ALALivePlayerFramework" }?.uuid)
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

    func testJetsamEventIsRecognizedNotParsed() throws {
        // Synthetic clone of the real local JetsamEvent shape (macOS bug_type 298,
        // iOS uses 288): memory-pressure tables, NO threads/usedImages/exception.
        // Correct behavior = recognized skip, never a fake empty cluster.
        let jetsam = """
        {"bug_type":"298","timestamp":"2026-09-03 00:05:22.00 +0000","os_version":"macOS 15.6 (build)"}
        {"bug_type":"298","largestProcess":"WindowServer","memoryStatus":{"compressor":1},"processes":[{"pid":1}]}
        """
        XCTAssertThrowsError(try TelemetryParser().parse(data: Data(jetsam.utf8), sourcePath: "j.ips")) { e in
            guard case ParseError.jetsamEvent = e else {
                return XCTFail("expected jetsamEvent, got \(e)")
            }
        }
        XCTAssertTrue(TelemetryParser.looksLikeJetsamEvent(data: Data(jetsam.utf8)))
        // and a normal crash is NOT jetsam
        let crash = try Data(contentsOf: fixture("crash-new-142.ips"))
        XCTAssertFalse(TelemetryParser.looksLikeJetsamEvent(data: crash))
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

    func testIngestLedgerDeduplicatesIdenticalFiles() throws {
        let store = tempStore()
        let data = try Data(contentsOf: fixture("crash-new-142.ips"))
        let fp = Store.fingerprint(data)
        XCTAssertFalse(store.hasSeen(fp))
        store.markSeen(fp)
        XCTAssertTrue(store.hasSeen(fp))
        // deterministic for identical bytes, distinct for different bytes
        XCTAssertEqual(Store.fingerprint(data), fp)
        XCTAssertNotEqual(Store.fingerprint(Data("different".utf8)), fp)
        // persists across instances — re-ingest of the same file is a no-op
        XCTAssertTrue(Store(baseDir: store.baseDir).hasSeen(fp))
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

    func testSignatureIndexResolvesMerges() {
        let store = tempStore()
        ingest(store, "crash-new-142.ips")
        let sig = store.clusters.values.first!.signature
        XCTAssertEqual(store.clusterID(forSignature: sig), store.clusters.values.first!.id)
        XCTAssertNil(store.clusterID(forSignature: "no such signature"))
        // index survives reload (legacy journals get it rebuilt on load)
        let reloaded = Store(baseDir: store.baseDir)
        XCTAssertEqual(reloaded.clusterID(forSignature: sig), store.clusters.values.first!.id)
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

    func testCoronerIgnorePatterns() {
        let patterns = ["# comment", "", "*.tmp.ips", "vendor/", "/rooted.ips", "a/**/deep.json", "note?.json"]
        func m(_ p: String) -> Bool { CoronerIgnore.matches(patterns, path: p) }
        XCTAssertTrue(m("x/y/report.tmp.ips"), "*.tmp.ips matches basename at any depth")
        XCTAssertTrue(m("vendor"), "directory pattern matches the directory itself")
        XCTAssertTrue(m("third/vendor/lib.json"), "directory pattern matches everything under it at any depth")
        XCTAssertFalse(m("vendorx/a.json"), "vendor/ must not bleed into vendorx/")
        XCTAssertTrue(m("rooted.ips"), "leading / anchors at the scan root")
        XCTAssertFalse(m("sub/rooted.ips"), "anchored pattern does not match deeper paths")
        XCTAssertTrue(m("a/b/c/deep.json"), "** spans components")
        XCTAssertFalse(m("x/b/c/deep.json"), "a/**/deep.json is anchored at a/")
        XCTAssertTrue(m("note1.json"))
        XCTAssertFalse(m("note12.json"), "? is a single character")
        XCTAssertFalse(m("plain.ips"))
    }

    func testDiscoveryHonorsCoronerIgnore() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-ignore-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for rel in ["keep.ips", "noise.tmp.ips", "vendor/skip.json", "sub/keep2.json"] {
            let f = root.appendingPathComponent(rel)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: f.path, contents: Data("{}".utf8))
        }
        try "# excluded from ingest\n*.tmp.ips\nvendor/\n".write(to: root.appendingPathComponent(".coronerignore"),
                                                              atomically: true, encoding: .utf8)
        let found = FileDiscovery.telemetryFiles([root.path])
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found[0].hasSuffix("keep.ips"))
        XCTAssertTrue(found[1].hasSuffix("sub/keep2.json"))
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

    func testAtosLineParsing() {        let a = Symbolicator.parseAtosLine("SessionStore.dequeue (in DemoApp) (sessionStore.swift:88)")
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
                // The locator verifies the dSYM UUID with dwarfdump before atos runs.
                launchPath.hasSuffix("dwarfdump")
                    ? "UUID: 11111111-2222-3333-4444-555555555555 (arm64) DemoApp"
                    : "SessionStore.dequeue (in DemoApp) (sessionStore.swift:88)\nSessionStore.flush (in DemoApp)"
            }
        }

        var report = try! TelemetryParser().parseFile(at: fixture("crash-new-142.ips").path)[0]
        let stub = StubRunner()
        let symbolicator = Symbolicator(locator: SearchPathLocator(paths: [tmp.path], runner: stub), runner: stub)
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

    func testSpotlightQueryUsesDashedUUID() {
        // Contract test (empirically verified against real Spotlight): the metadata
        // attribute only matches the canonical dashed form, so the query built from
        // a normalized (dash-stripped) UUID must restore 8-4-4-4-12 or find nothing.
        final class RecordingRunner: ProcessRunning {
            var queries: [[String]] = []
            func run(_ launchPath: String, _ args: [String]) -> String {
                queries.append(args)
                return ""
            }
        }
        let runner = RecordingRunner()
        let locator = SpotlightLocator(runner: runner)
        let uuid = "11111111222233334444555555555555"
        XCTAssertNil(locator.locate(binaryName: "App", uuid: uuid))
        XCTAssertEqual(runner.queries.count, 1)
        XCTAssertTrue(runner.queries[0][0].contains("11111111-2222-3333-4444-555555555555"),
                      "Spotlight never matches a dash-stripped UUID")
        // memoized: a second lookup for the same UUID must not re-run mdfind
        _ = locator.locate(binaryName: "App", uuid: uuid)
        XCTAssertEqual(runner.queries.count, 1)
        // non-32-hex input (already dashed or odd) is used as-is
        XCTAssertEqual(SpotlightLocator.dashed("abc"), "abc")
    }

    func testSearchPathLocatorVerifiesUUID() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-dsym-uuid-\(UUID().uuidString)", isDirectory: true)
        let dsym = tmp.appendingPathComponent("App.dSYM")
        try FileManager.default.createDirectory(at: dsym, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        struct UUIDStub: ProcessRunning {
            let line: String
            func run(_ launchPath: String, _ args: [String]) -> String { line }
        }

        let uuid = "11111111222233334444555555555555"
        let matching = SearchPathLocator(paths: [tmp.path],
                                         runner: UUIDStub(line: "UUID: 11111111-2222-3333-4444-555555555555 (arm64) App"))
        XCTAssertEqual(matching.locate(binaryName: "App", uuid: uuid), dsym.path)

        // same name, different build → rejected, not silently mis-symbolicated
        let stale = SearchPathLocator(paths: [tmp.path],
                                      runner: UUIDStub(line: "UUID: AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE (arm64) App"))
        XCTAssertNil(stale.locate(binaryName: "App", uuid: uuid))

        // no UUID in the report → nothing to verify against, candidate stays usable
        let unknown = SearchPathLocator(paths: [tmp.path], runner: UUIDStub(line: ""))
        XCTAssertEqual(unknown.locate(binaryName: "App", uuid: nil), dsym.path)
    }

    func testProcessRunnerTimesOutHungChild() {
        // /bin/sleep produces no output and never exits on its own here.
        let runner = ProcessRunner(timeout: 0.5)
        let start = Date()
        let out = runner.run("/bin/sleep", ["5"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "a wedged child must not wedge coroner")
        XCTAssertEqual(out, "")
    }

    func testDwarfBinaryFallbackIsDeterministic() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-dwarf-\(UUID().uuidString)", isDirectory: true)
        let dwarfDir = dir.appendingPathComponent("Contents/Resources/DWARF")
        try FileManager.default.createDirectory(at: dwarfDir, withIntermediateDirectories: true)
        for name in [".DS_Store", "Beta", "Alpha"] {
            FileManager.default.createFile(atPath: dwarfDir.appendingPathComponent(name).path, contents: Data())
        }
        // exact name wins when present
        XCTAssertEqual(Symbolicator.dwarfBinary(dsymPath: dir.path, binaryName: "Alpha")
            .hasSuffix("DWARF/Alpha"), true)
        // otherwise: sorted, hidden files never picked
        let pick = Symbolicator.dwarfBinary(dsymPath: dir.path, binaryName: "Missing")
        XCTAssertTrue(pick.hasSuffix("DWARF/Alpha"), "expected the first sorted non-hidden entry")
    }

    func testCLIRejectsTrailingGlobalFlagsAndSupportsTopKind() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bin = packageRoot.appendingPathComponent(".build/debug/coroner")
        guard FileManager.default.fileExists(atPath: bin.path) else {
            throw XCTSkip("debug executable not built yet")
        }
        func runCLI(_ args: [String]) -> (code: Int32, out: String) {
            let p = Process()
            p.executableURL = bin
            p.arguments = args
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = Pipe()
            try! p.run()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            return (p.terminationStatus, out)
        }
        // trailing --store used to be swallowed as a positional arg
        let bad = runCLI(["list", "--store", "/tmp/nowhere"])
        XCTAssertEqual(bad.code, 2, "misplaced global option must fail loudly, not silently")
        // top takes --kind like list
        let store = tempStore()
        ingest(store, "metrickit-hang.json")
        let top = runCLI(["--store", store.baseDir.path, "top", "--kind", "hang"])
        XCTAssertEqual(top.code, 0)
        XCTAssertTrue(top.out.contains("[hang]"))
        XCTAssertFalse(top.out.contains("[crash]"))
        // CI gate: new-since exits 1 exactly when new records exist
        let gate = runCLI(["--store", store.baseDir.path, "new-since", "141"])
        XCTAssertEqual(gate.code, 1, "new records must fail the gate")
        let clean = runCLI(["--store", store.baseDir.path, "new-since", "999"])
        XCTAssertEqual(clean.code, 0, "no new records must pass")
    }

    // MARK: - suspect_commit (estimate)

    func testBuildTagRangePrefersExactRefsOverDateWindow() {
        final class ScriptedRunner: ProcessRunning {
            var logArgs: [String]?
            func run(_ launchPath: String, _ args: [String]) -> String {
                if args.contains("tag") {
                    return "v1.2.0\nbuild/141\nbuild/142\nrel-140"
                }
                logArgs = args
                return ""
            }
        }
        let runner = ScriptedRunner()
        let s = Suspector(runner: runner, repoPath: "/repo")

        let tags = s.buildTags()
        XCTAssertEqual(tags.map { $0.build }, [141, 142, 140], "v1.2.0 must be rejected as a version, not a build")
        XCTAssertEqual(s.buildTagRange(for: "142")?.base, "build/141")
        XCTAssertEqual(s.buildTagRange(for: "142")?.tip, "build/142")
        XCTAssertNil(s.buildTagRange(for: "999"), "no tip tag → fall back to the date window")
        XCTAssertNil(s.buildTagRange(for: "140"), "no earlier tag → no base, fall back")

        var cluster = ClusterReport(id: "c", kind: .crash, signature: "s", topFrames: [],
                                    firstSeenBuild: "142", lastSeenBuild: "142",
                                    firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    occurrences: ["142": 1], sourceAnchors: ["A.swift"])
        _ = s.suspects(for: cluster)
        XCTAssertTrue(runner.logArgs?.contains("build/141..build/142") ?? false,
                      "tag range must drive the log query")
        XCTAssertFalse(runner.logArgs?.contains(where: { $0.hasPrefix("--since") }) ?? true)

        cluster.firstSeenBuild = "999"   // untagged build → date window
        _ = s.suspects(for: cluster)
        XCTAssertTrue(runner.logArgs?.contains(where: { $0.hasPrefix("--since") }) ?? false,
                      "date window is the fallback")
    }

    func testSuspectorRealGitTagRange() throws {
        let gitOK = !ProcessRunner().run("/usr/bin/git", ["--version"]).isEmpty
        guard gitOK else { throw XCTSkip("git not available") }
        let repo = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-git-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        var gitLog = ""
        func git(_ args: [String]) {
            // stderr is dropped by the runner; capture the log query for diagnosis
            let out = ProcessRunner().run("/usr/bin/git", ["-C", repo.path] + args)
            gitLog += "$ git \(args.joined(separator: " "))\n\(out)\n"
        }
        let fm = FileManager.default
        func commit(_ file: String, msg: String, tag: String? = nil) throws {
            let f = repo.appendingPathComponent(file)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(msg.utf8).write(to: f)
            git(["add", file])
            git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", msg])
            if let tag { git(["tag", tag]) }
        }
        // `git -C` chdirs — the directory must exist before init
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "--quiet"])
        try commit("Base.txt", msg: "base", tag: "build/141")
        try commit("Sources/B.swift", msg: "introduce B bug", tag: "build/142")

        let cluster = ClusterReport(id: "c", kind: .crash, signature: "s", topFrames: [],
                                    firstSeenBuild: "142", lastSeenBuild: "142",
                                    firstSeenAt: Date(), occurrences: ["142": 1],
                                    sourceAnchors: ["B.swift"])
        let suspects = Suspector(repoPath: repo.path).suspects(for: cluster)
        guard suspects.count == 1 else {
            XCTFail("expected exactly the tagged-range commit, got \(suspects)\n\(gitLog)")
            return
        }
        XCTAssertEqual(suspects[0].subject, "introduce B bug")
        XCTAssertEqual(suspects[0].files, ["Sources/B.swift"])
    }

    func testSuspectorCrossesGitHistoryWithAnchors() {
        let log = [
            "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678\u{1f}Fix session restore",
            "Sources/App/sessionStore.swift",
            "README.md",
            "99887766554433221100ffeeddccbbaa99887766\u{1f}Bump version",
            "README.md",
        ].joined(separator: "\n")
        struct GitStub: ProcessRunning {
            let out: String
            func run(_ launchPath: String, _ args: [String]) -> String { out }
        }
        let base = ClusterReport(id: "c-x", kind: .crash, signature: "s", topFrames: [],
                                 firstSeenBuild: "142", lastSeenBuild: "142",
                                 firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 occurrences: ["142": 1],
                                 sourceAnchors: ["SessionStore.swift"])
        let suspects = Suspector(runner: GitStub(out: log), repoPath: "/repo").suspects(for: base)
        XCTAssertEqual(suspects.count, 1, "only the commit touching the anchor file matches")
        XCTAssertEqual(suspects[0].hash, "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678")
        XCTAssertEqual(suspects[0].subject, "Fix session restore")
        XCTAssertEqual(suspects[0].files, ["Sources/App/sessionStore.swift"])

        // honest empties: no anchors, or no first_seen date
        var bare = base; bare.sourceAnchors = nil
        XCTAssertTrue(Suspector(runner: GitStub(out: log), repoPath: "/repo").suspects(for: bare).isEmpty)
        bare = base; bare.sourceAnchors = ["SessionStore.swift"]; bare.firstSeenAt = nil
        XCTAssertTrue(Suspector(runner: GitStub(out: log), repoPath: "/repo").suspects(for: bare).isEmpty)
    }

    func testSuspectsPersistAndRender() throws {
        let store = tempStore()
        ingest(store, "crash-new-142.ips")
        let id = store.clusters.values.first!.id
        let s = [SuspectCommit(hash: "abcdef1234567890", subject: "Fix thing", files: ["Sources/A.swift"])]
        _ = try store.setSuspects(id: id, suspects: s)
        let reloaded = Store(baseDir: store.baseDir)
        XCTAssertEqual(try reloaded.detail(id: id).suspects, s)
        let text = Renderer.detail(try reloaded.detail(id: id))
        XCTAssertTrue(text.contains("estimate"))
        XCTAssertTrue(text.contains("abcdef1"))
    }

    func testIngestRecordsSourceAnchorsFromSymbolicatedFrames() {
        // symbolication stub (same layout as testSymbolicationWithStubbedAtos)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("coroner-anchor-\(UUID().uuidString)", isDirectory: true)
        let dwarf = tmp.appendingPathComponent("DemoApp.dSYM/Contents/Resources/DWARF/DemoApp")
        try! FileManager.default.createDirectory(at: dwarf.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dwarf.path, contents: Data())
        struct Stub: ProcessRunning {
            func run(_ launchPath: String, _ args: [String]) -> String {
                launchPath.hasSuffix("dwarfdump")
                    ? "UUID: 11111111-2222-3333-4444-555555555555 (arm64) DemoApp"
                    : "SessionStore.dequeue (in DemoApp) (sessionStore.swift:88)\nSessionStore.flush (in DemoApp)"
            }
        }
        let stub = Stub()
        var report = try! TelemetryParser().parseFile(at: fixture("crash-new-142.ips").path)[0]
        report = Symbolicator(locator: SearchPathLocator(paths: [tmp.path], runner: stub), runner: stub)
            .symbolicate(report: report)
        let store = tempStore()
        _ = store.ingest(report)
        XCTAssertEqual(store.clusters.values.first?.sourceAnchors, ["sessionStore.swift"])
    }

    // MARK: - App Store Connect (pure parts; live HTTP is CLI-only)

    func testASCJWTSignsAndParsesP8Key() throws {
        let key = P256.Signing.PrivateKey()
        // minimal PKCS#8 EC structure wrapping the raw scalar
        var inner = Data([0x02, 0x01, 0x01, 0x04, 0x20]); inner += key.rawRepresentation
        let innerSeq = Data([0x30, UInt8(inner.count)]) + inner
        let octet = Data([0x04, UInt8(innerSeq.count)]) + innerSeq
        let alg = Data([0x30, 0x13,
                        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])
        let pkcs8 = Data([0x02, 0x01, 0x00]) + alg + octet
        let der = Data([0x30, UInt8(pkcs8.count)]) + pkcs8
        let pem = "-----BEGIN PRIVATE KEY-----\n\(der.base64EncodedString())\n-----END PRIVATE KEY-----\n"

        let parsed = try ASCJWT.privateKey(pem: pem)
        XCTAssertEqual(parsed.rawRepresentation, key.rawRepresentation)

        let token = ASCJWT.token(issuer: "iss-1", keyID: "KID123", key: key,
                                 lifetime: 60, now: Date(timeIntervalSince1970: 1_700_000_000))
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        func b64d(_ s: String) -> Data? {
            var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while t.count % 4 != 0 { t += "=" }
            return Data(base64Encoded: t)
        }
        let header = try JSONSerialization.jsonObject(with: b64d(parts[0])!) as! [String: String]
        XCTAssertEqual(header["alg"], "ES256")
        XCTAssertEqual(header["kid"], "KID123")
        let payload = try JSONSerialization.jsonObject(with: b64d(parts[1])!) as! [String: Any]
        XCTAssertEqual(payload["iss"] as? String, "iss-1")
        XCTAssertEqual(payload["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(payload["exp"] as? Int, 1_700_000_060)
        // signature verifies against the public key (JWS raw 64-byte form)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: b64d(parts[2])!)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: Data((parts[0] + "." + parts[1]).utf8)))
        // garbage PEM is rejected, not crashed on
        XCTAssertThrowsError(try ASCJWT.privateKey(pem: "-----BEGIN PRIVATE KEY-----\nYWJjZA==\n-----END PRIVATE KEY-----"))
    }

    func testASCBuildsURLAndDSYMExtraction() {
        let url = ASCRequests.buildsURL(app: "1234", build: "241")!
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://api.appstoreconnect.apple.com/v1/builds?"))
        XCTAssertTrue(s.contains("filter%5Bapp%5D=1234"))
        XCTAssertTrue(s.contains("filter%5Bversion%5D=241"))
        XCTAssertTrue(s.contains("include=preReleaseVersion,buildBundles"))
        let json = Data("""
        {"data":[{"id":"b1","relationships":{"buildBundles":{"data":[{"id":"bb1"},{"id":"bb2"}]}}}],
         "included":[{"id":"bb1","type":"buildBundles","attributes":{"includesSymbols":true,"dSYMUrl":"https://example.com/x.zip"}},
                     {"id":"bb2","type":"buildBundles","attributes":{"includesSymbols":false,"dSYMUrl":"https://example.com/y.zip"}}]}
        """.utf8)
        XCTAssertEqual(ASCRequests.dsymURLs(fromBuildsJSON: json), ["https://example.com/x.zip"],
                       "only bundles with includesSymbols contribute")
        XCTAssertEqual(ASCRequests.dsymURLs(fromBuildsJSON: Data("{}".utf8)), [])
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
        XCTAssertTrue(list.contains("suspects"))

        let call = engine.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"new_since","arguments":{"build":"141"}}}"#)!
        XCTAssertTrue(call.contains("DemoApp"), "new_since must surface the 142 cluster")
        XCTAssertFalse(call.contains("DemoApp+0x3030"), "the 141 cluster must not appear")

        let known = engine.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"is_known","arguments":{"signature":"demoapp+0x1010"}}}"#)!
        XCTAssertTrue(known.contains("KNOWN"))

        // unsymbolicated cluster → honest empty answer (no git involved: no anchors)
        let id = store.clusters.values.first { $0.firstSeenBuild == "142" }!.id
        let sus = engine.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"suspects","arguments":{"id":"\#(id)"}}}"#)!
        XCTAssertTrue(sus.contains("no suspects"))

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
        p.arguments = ["--store", storeDir.path, "mcp"]
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
        XCTAssertFalse(md.contains("suspect_commit"), "no estimates yet — section stays hidden")
        // with an estimate recorded, the digest surfaces it — labeled as an estimate
        let id = store.clusters.values.first!.id
        _ = try! store.setSuspects(id: id, suspects: [
            SuspectCommit(hash: "abcdef1234567890", subject: "Fix thing", files: ["Sources/A.swift"]),
        ])
        let md2 = Digest.markdown(clusters: store.all(), period: .all)
        XCTAssertTrue(md2.contains("suspect_commit 추정"))
        XCTAssertTrue(md2.contains("`abcdef1` Fix thing"))
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
