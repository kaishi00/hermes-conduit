//
//  ConnectionFailureTests+CrashReports.swift
//  ConduitTests
//
//  The "send this report?" card after a crash or freeze: which MetricKit
//  diagnostics it offers, what a report sends (no exception messages), and
//  how Send, Not now and a relay without the route end. An extension of an
//  existing diagnostics class, so the CI planner gains no new class.
//

import XCTest
@testable import Conduit

extension ConnectionFailureTests {
    private func crashDefaults() -> UserDefaults {
        let name = "CrashReports-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func crashDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReports-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// An MXDiagnosticPayload's JSON in MetricKit's shape.
    private func diagnosticJSON(crashes: Int = 1, hangs: Int = 0, cpu: Int = 0) -> Data {
        let crash: [String: Any] = [
            "version": "1.0.0",
            "diagnosticMetaData": [
                "appVersion": "2.2.1", "appBuildVersion": "236", "osVersion": "iPhone OS 27.2 (24C5)",
                "deviceType": "iPhone17,2", "exceptionType": 1, "signal": 11, "regionFormat": "NZ",
                "exceptionReason": [
                    "composedMessage": "*** -[NSString substringToIndex:]: Index 9 out of bounds; string length 3 (\"hi?\")",
                    "formatString": "*** -[NSString substringToIndex:]: Index %lu out of bounds; string length %lu",
                    "arguments": ["9", "hi?"],
                    "exceptionType": "NSRangeException",
                    "className": "NSString",
                ],
            ],
            "callStackTree": ["callStacks": [["threadAttributed": true, "callStackRootFrames": [["binaryName": "Conduit", "offsetIntoBinaryTextSegment": 1234, "subFrames": [["binaryName": "SwiftUI", "offsetIntoBinaryTextSegment": 99, "symbol": "x"]]]]]]]],
        ]
        let hang: [String: Any] = [
            "diagnosticMetaData": ["appBuildVersion": "236", "hangDuration": "8 sec"],
            "callStackTree": ["callStacks": []],
        ]
        let object: [String: Any] = [
            "timeStampBegin": "2026-10-28 20:00:00", "timeStampEnd": "2026-10-28 20:21:00",
            "crashDiagnostics": Array(repeating: crash, count: crashes),
            "hangDiagnostics": Array(repeating: hang, count: hangs),
            "cpuExceptionDiagnostics": Array(repeating: ["diagnosticMetaData": [:]], count: cpu),
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testCrashReportSendsStacksWithoutExceptionMessages() throws {
        let body = try XCTUnwrap(CrashReportUpload.body(fromPayloadJSON: diagnosticJSON(crashes: 1, hangs: 1)))
        XCTAssertEqual(body["kind"] as? String, "crash", "a crash wins over a hang")
        XCTAssertEqual(body["build"] as? String, "236", "the build that crashed")
        XCTAssertEqual(body["device"] as? String, "iPhone17,2")
        XCTAssertEqual(body["os"] as? String, "iPhone OS 27.2 (24C5)")
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertFalse(encoded.contains("hi?"), "an exception's message and arguments can quote anything")
        XCTAssertFalse(encoded.contains("composedMessage"))
        XCTAssertFalse(encoded.contains("formatString"), "a format string can be built from anything too")
        XCTAssertTrue(encoded.contains("NSRangeException"))
        XCTAssertTrue(encoded.contains("offsetIntoBinaryTextSegment"))
        XCTAssertNil((body["diagnostic"] as? [String: Any])?["cpuExceptionDiagnostics"], "only crashes and hangs go")
        XCTAssertTrue(encoded.contains("SwiftUI"), "nested frames go")
        XCTAssertFalse(encoded.contains("regionFormat"), "a key not named stays on the phone")
        XCTAssertFalse(encoded.contains("symbol"))

        let huge: [String: Any] = ["crashDiagnostics": [["callStackTree": ["callStacks": [["callStackRootFrames": [["binaryName": String(repeating: "x", count: 600_000)]]]]]]]]
        XCTAssertNil(CrashReportUpload.body(fromPayloadJSON: try JSONSerialization.data(withJSONObject: huge)), "too big even trimmed: not offered")

        XCTAssertEqual(CrashReportUpload.kind(ofPayloadJSON: diagnosticJSON(crashes: 0, hangs: 2)), .hang)
        XCTAssertNil(CrashReportUpload.kind(ofPayloadJSON: diagnosticJSON(crashes: 0, hangs: 0, cpu: 1)))
        XCTAssertNil(CrashReportUpload.body(fromPayloadJSON: diagnosticJSON(crashes: 0, hangs: 0, cpu: 1)))
    }

    func testCrashReportFieldsFallBackAndKeepToTheRelaysCharacters() throws {
        let object: [String: Any] = ["hangDiagnostics": [["diagnosticMetaData": ["osVersion": "iOS\n27 <beta>"]]]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let body = try XCTUnwrap(CrashReportUpload.body(fromPayloadJSON: data, appVersion: "2.2.1", build: "240", os: "26.0", device: "iPad16,3"))
        XCTAssertEqual(body["os"] as? String, "iOS27 beta")
        XCTAssertEqual(body["build"] as? String, "240", "no build in the diagnostic: the running one")
        XCTAssertEqual(body["device"] as? String, "iPad16,3")
        XCTAssertEqual(body["kind"] as? String, "hang")
    }

    func testCrashReportQueueAsksAboutTheNewestFewOnce() {
        let defaults = crashDefaults()
        let queue = CrashReportQueue(defaults: defaults, build: "240")
        for index in 0..<7 { queue.add("diagnostics-\(index).json") }
        queue.add("diagnostics-6.json")
        XCTAssertEqual(queue.pending, (2..<7).map { "diagnostics-\($0).json" })
        queue.remove(["diagnostics-2.json"])
        XCTAssertEqual(queue.pending.count, 4)
        queue.stopOffering()
        queue.add("diagnostics-9.json")
        XCTAssertTrue(queue.pending.isEmpty, "a relay without the route: this build offers nothing more")
        let next = CrashReportQueue(defaults: defaults, build: "241")
        next.add("diagnostics-9.json")
        XCTAssertEqual(next.pending, ["diagnostics-9.json"], "the next build asks again")
    }

    func testMetricKitQueuesOnlyARecentCrashOrHang() {
        let defaults = crashDefaults()
        let store = MetricKitReportStore(directory: crashDirectory())
        let reports = MetricKitReports(store: store, crashReports: CrashReportQueue(defaults: defaults))
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let end = now.addingTimeInterval(-3600)
        let begin = end.addingTimeInterval(-60)
        store.save(diagnosticJSON(), kind: .diagnostics, begin: begin, end: end)
        XCTAssertTrue(reports.queueCrashReport(diagnosticJSON(), begin: begin, end: end, now: now))
        XCTAssertEqual(CrashReportQueue(defaults: defaults).pending.count, 1)

        let old = now.addingTimeInterval(-8 * 86_400)
        store.save(diagnosticJSON(), kind: .diagnostics, begin: old.addingTimeInterval(-60), end: old)
        XCTAssertFalse(reports.queueCrashReport(diagnosticJSON(), begin: old.addingTimeInterval(-60), end: old, now: now), "a week old: not offered")

        let cpu = diagnosticJSON(crashes: 0, hangs: 0, cpu: 1)
        store.save(cpu, kind: .diagnostics, begin: begin.addingTimeInterval(1), end: end.addingTimeInterval(1))
        XCTAssertFalse(reports.queueCrashReport(cpu, begin: begin.addingTimeInterval(1), end: end.addingTimeInterval(1), now: now), "only crashes and hangs")
        XCTAssertEqual(CrashReportQueue(defaults: defaults).pending.count, 1)
    }

    func testStoredCrashReportsQueueOnceOnFirstLook() {
        let defaults = crashDefaults()
        let store = MetricKitReportStore(directory: crashDirectory())
        let reports = MetricKitReports(store: store, crashReports: CrashReportQueue(defaults: defaults))
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        store.save(diagnosticJSON(), kind: .diagnostics, begin: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        store.save(diagnosticJSON(crashes: 0, hangs: 1), kind: .diagnostics, begin: now.addingTimeInterval(-9 * 86_400), end: now.addingTimeInterval(-8 * 86_400))
        store.save(diagnosticJSON(crashes: 0, hangs: 0, cpu: 1), kind: .diagnostics, begin: now.addingTimeInterval(-600), end: now.addingTimeInterval(-60))
        XCTAssertTrue(reports.queueStoredCrashReports(now: now))
        XCTAssertEqual(CrashReportQueue(defaults: defaults).pending.count, 1, "the recent crash only")
        CrashReportQueue(defaults: defaults).clear()
        XCTAssertFalse(reports.queueStoredCrashReports(now: now), "once per device")
        XCTAssertTrue(CrashReportQueue(defaults: defaults).pending.isEmpty)
    }

    @MainActor
    func testCrashReportOfferSendsOrStopsAsking() async throws {
        CrashReportStubProtocol.status = 201
        CrashReportStubProtocol.paths = []
        let directory = crashDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recent = Int(Date().timeIntervalSince1970) - 3600
        let name = "diagnostics-\(recent - 60)-\(recent)-abc.json"
        try diagnosticJSON().write(to: directory.appendingPathComponent(name))
        let old = "diagnostics-1-2-abc.json"
        try diagnosticJSON().write(to: directory.appendingPathComponent(old))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrashReportStubProtocol.self]
        let session = URLSession(configuration: configuration)
        let relay = URL(string: "https://relay.example")!

        // A week old by the time it would show: dropped, not offered.
        var defaults = crashDefaults()
        CrashReportQueue(defaults: defaults).add(old)
        var offer = CrashReportOffer(queue: CrashReportQueue(defaults: defaults), directory: directory, relayURL: relay, session: session)
        await offer.refresh()
        XCTAssertEqual(offer.state, .hidden)
        XCTAssertTrue(CrashReportQueue(defaults: defaults).pending.isEmpty)

        // Not now: asked once.
        defaults = crashDefaults()
        CrashReportQueue(defaults: defaults).add(name)
        offer = CrashReportOffer(queue: CrashReportQueue(defaults: defaults), directory: directory, relayURL: relay, session: session)
        await offer.refresh()
        XCTAssertEqual(offer.state, .asking(crashed: true))
        offer.dismiss()
        XCTAssertEqual(offer.state, .hidden)
        await offer.refresh()
        XCTAssertEqual(offer.state, .hidden, "not offered again")

        // Send: posted to the relay's route, then thanked.
        defaults = crashDefaults()
        CrashReportQueue(defaults: defaults).add(name)
        offer = CrashReportOffer(queue: CrashReportQueue(defaults: defaults), directory: directory, relayURL: relay, session: session, thanksFor: .zero)
        await offer.refresh()
        CrashReportStubProtocol.status = 201
        CrashReportStubProtocol.paths = []
        await offer.send()
        XCTAssertEqual(offer.state, .hidden, "thanked, then gone")
        XCTAssertEqual(CrashReportStubProtocol.paths, ["/v1/crash-reports"])
        XCTAssertTrue(CrashReportQueue(defaults: defaults).pending.isEmpty)

        // A refused post keeps the report for Try Again.
        defaults = crashDefaults()
        CrashReportQueue(defaults: defaults).add(name)
        offer = CrashReportOffer(queue: CrashReportQueue(defaults: defaults), directory: directory, relayURL: relay, session: session)
        await offer.refresh()
        CrashReportStubProtocol.status = 503
        await offer.send()
        XCTAssertEqual(offer.state, .failed)
        XCTAssertEqual(CrashReportQueue(defaults: defaults).pending.count, 1)

        // A relay without the route: hidden, and nothing more is offered.
        CrashReportStubProtocol.status = 404
        await offer.send()
        XCTAssertEqual(offer.state, .hidden)
        XCTAssertTrue(CrashReportQueue(defaults: defaults).pending.isEmpty)
        XCTAssertTrue(CrashReportQueue(defaults: defaults).isUnsupported)
    }
}

/// Answers every request with `status` and records its path.
private final class CrashReportStubProtocol: URLProtocol {
    static var status = 201
    static var paths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url?.path ?? "")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
