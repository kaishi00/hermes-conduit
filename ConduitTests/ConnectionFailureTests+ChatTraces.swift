//
//  ConnectionFailureTests+ChatTraces.swift
//  ConduitTests
//
//  The chat recorder (#1533): its ring and the characters a line keeps,
//  the watchers that save it as a trace, the five traces kept, the newest
//  stall trace riding with a freeze's report, and Diagnostics & logs' Send.
//  An extension of an existing diagnostics class, so the CI planner gains
//  no new class.
//

import XCTest
@testable import Conduit

extension ConnectionFailureTests {
    private func traceStore() -> ChatTraceStore {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ChatTraces-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return ChatTraceStore(
            directory: base.appendingPathComponent("traces", isDirectory: true),
            exportDirectory: base.appendingPathComponent("export", isDirectory: true)
        )
    }

    private func traceDefaults() -> UserDefaults {
        let name = "ChatTraces-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func traceSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatTraceStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// The relay's TRACE_LINE_PATTERN (notifier relay/src/crash-reports.mjs).
    private func takenByTheRelay(_ line: String) -> Bool {
        line.range(of: #"^[A-Za-z0-9 ()._,:;+=<>/#%\[\]-]{0,160}$"#, options: .regularExpression) != nil
    }

    func testChatTraceRingKeepsTheNewestLinesInTheRelaysCharacters() {
        let trace = ChatViewportTrace()
        for index in 0..<2_050 { trace.log("line \(index)") }
        let entries = trace.entries
        XCTAssertEqual(entries.count, ChatViewportTrace.limit)
        XCTAssertEqual(entries.first?.text, "line 50", "the oldest went first")
        XCTAssertEqual(entries.last?.text, "line 2049")
        let last = trace.lines(last: 3)
        XCTAssertEqual(last.count, 3)
        XCTAssertTrue(last[2].hasSuffix(" line 2049"), "the time, then the line")

        XCTAssertEqual(ChatViewportTrace.sanitized("café \"quote\" 😀 a+b=c [x] 50%"), "caf_ _quote_ _ a+b=c [x] 50%")
        XCTAssertEqual(ChatViewportTrace.sanitized(String(repeating: "x", count: 300)).count, 160)
        trace.log("title: \u{201C}Plans\u{201D}\nnext")
        trace.log(String(repeating: "y", count: 400))
        XCTAssertTrue(trace.lines().allSatisfy(takenByTheRelay), "every line is one the relay takes")
        trace.reset()
        XCTAssertTrue(trace.isEmpty)
        XCTAssertEqual(trace.dump(), "")
    }

    func testChatTraceStoreKeepsTheNewestFiveAndFindsAStallInASpan() throws {
        let store = traceStore()
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertNil(store.save(.jump, lines: [], now: start), "nothing recorded, nothing saved")
        let reasons: [ChatTraceReason] = [.stall, .jump, .storm, .stall, .rebuild, .manual, .jump]
        for (index, reason) in reasons.enumerated() {
            store.save(reason, lines: ["1.000 line \(index)"], now: start.addingTimeInterval(Double(index) * 60), appVersion: "2.2.1", build: "245", os: "Version 26.1 (Build 23B85)", device: "iPhone17,2")
        }
        let kept = store.traces()
        XCTAssertEqual(kept.map(\.reason), [.jump, .manual, .rebuild, .stall, .storm], "the newest five, newest first")
        XCTAssertEqual(kept.first?.appVersion, "2.2.1")
        XCTAssertEqual(kept.first?.build, "245")

        let lines = try XCTUnwrap(store.lines(of: kept[3]))
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("Conduit chat trace: stall, saved 2026-"), lines[0])
        XCTAssertEqual(lines[1], "Conduit 2.2.1 (245), Version 26.1 (Build 23B85), iPhone17,2")
        XCTAssertEqual(lines[2], "1.000 line 3")
        XCTAssertTrue(lines.allSatisfy(takenByTheRelay))

        // A stall in a diagnostic's span is the newest one there.
        let stall = try XCTUnwrap(store.stall(between: start, and: start.addingTimeInterval(3 * 60)))
        XCTAssertEqual(stall.fileName, kept[3].fileName)
        XCTAssertNil(store.stall(between: start.addingTimeInterval(4 * 60), and: start.addingTimeInterval(6 * 60)), "no stall in that span")

        store.append("stall ended: main thread back after 3.2 s", to: stall.fileName)
        XCTAssertEqual(store.lines(of: stall)?.last, "stall ended: main thread back after 3.2 s")

        // A full ring leaves room for the heading and a stall's last line.
        let full = try XCTUnwrap(store.save(.stall, lines: (0..<2_500).map { "1.000 line \($0)" }, now: start.addingTimeInterval(3_600)))
        let fullLines = try XCTUnwrap(ChatTraceStore.trace(named: full).flatMap { store.lines(of: $0) })
        XCTAssertEqual(fullLines.count, 2 + ChatTraceStore.maxRingLines)
        XCTAssertEqual(fullLines.last, "1.000 line 2499")

        let parsed = try XCTUnwrap(ChatTraceStore.trace(named: "1793404144357-jump-2.2.1-245.txt"))
        XCTAssertEqual(parsed.reason, .jump)
        XCTAssertEqual(parsed.savedAt.timeIntervalSince1970, 1_793_404_144.357, accuracy: 0.001)
        XCTAssertNil(ChatTraceStore.trace(named: "1793404144357-typed-2.2.1-245.txt"))
        XCTAssertNil(ChatTraceStore.trace(named: "notes.txt"))

        let export = try XCTUnwrap(store.writeExport(current: ["2.000 now"]))
        let text = try String(contentsOf: export, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Conduit chat trace: now, not saved\n2.000 now\n\nConduit chat trace: stall"), "what it holds now, then the newest saved")
        for trace in store.traces() { store.remove(trace.fileName) }
        XCTAssertNil(store.writeExport(current: []), "nothing to share")
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
    }

    @MainActor
    func testChatViewportWatchSavesAJumpNobodyAskedFor() {
        var time: CFAbsoluteTime = 1_000
        var saved: [ChatTraceReason] = []
        let watch = ChatViewportWatch(now: { time }, save: { saved.append($0) })

        watch.offsetMoved(from: 0, to: 500, viewportHeight: 800, byUser: false)
        XCTAssertEqual(saved, [], "less than a screen")
        watch.offsetMoved(from: 0, to: 4_000, viewportHeight: 800, byUser: true)
        XCTAssertEqual(saved, [], "a finger or momentum")
        watch.engineWrites(animated: false) {
            watch.offsetMoved(from: 4_000, to: 0, viewportHeight: 800, byUser: false)
        }
        XCTAssertEqual(saved, [], "the engine's own write")
        watch.offsetMoved(from: 4_000, to: 0, viewportHeight: 800, byUser: false)
        XCTAssertEqual(saved, [.jump], "a screen and more, nobody asking")
        time += 30
        watch.offsetMoved(from: 0, to: 4_000, viewportHeight: 800, byUser: false)
        XCTAssertEqual(saved, [.jump], "once a minute at most")

        time += 61
        watch.command("explicitTop")
        time += 0.5
        watch.offsetMoved(from: 4_000, to: 0, viewportHeight: 800, byUser: false)
        XCTAssertEqual(saved, [.jump], "a command's move")
        watch.engineWrites(animated: true) {}
        time += 0.3
        watch.offsetMoved(from: 0, to: 4_000, viewportHeight: 800, byUser: false)
        XCTAssertEqual(saved, [.jump], "an animated write still moving")
        watch.surfaceChanged()
        time += 0.9
        watch.offsetMoved(from: 4_000, to: 0, viewportHeight: 800, byUser: false)
        XCTAssertEqual(saved, [.jump], "a resize's layout")
        time += 0.2
        watch.offsetMoved(from: 0, to: 4_000, viewportHeight: 800, byUser: false)
        XCTAssertEqual(saved, [.jump, .jump])

        watch.blankViewportRebuilt()
        watch.blankViewportRebuilt()
        XCTAssertEqual(saved, [.jump, .jump, .rebuild])
    }

    @MainActor
    func testChatViewportWatchSavesALayoutStormButNotStreamingOrScrolling() {
        var time: CFAbsoluteTime = 1_000
        var saved: [ChatTraceReason] = []
        let watch = ChatViewportWatch(now: { time }, save: { saved.append($0) })
        func second(_ start: CFAbsoluteTime, passes: Int, also: (() -> Void)? = nil) {
            for index in 0..<passes {
                time = start + Double(index) / Double(passes + 1)
                watch.layoutPass()
            }
            also?()
        }

        second(1_000, passes: 40)
        second(1_001, passes: 40) { watch.transcriptChanged() }
        second(1_002, passes: 40)
        second(1_003, passes: 40)
        time = 1_004
        watch.layoutPass()
        XCTAssertEqual(saved, [], "a reply streaming in broke the run")

        // Each case starts after a quiet second, so none carries on the last.
        second(1_010, passes: 40)
        second(1_011, passes: 40) { watch.offsetMoved(from: 0, to: 10, viewportHeight: 800, byUser: true) }
        second(1_012, passes: 40)
        time = 1_013
        watch.layoutPass()
        XCTAssertEqual(saved, [], "the reader scrolling")

        second(1_020, passes: 40)
        second(1_021, passes: 20)
        second(1_022, passes: 40)
        time = 1_023
        watch.layoutPass()
        XCTAssertEqual(saved, [], "30 a second at most is layout at work")

        second(1_030, passes: 40)
        second(1_031, passes: 40)
        second(1_033, passes: 40)
        time = 1_034
        watch.layoutPass()
        XCTAssertEqual(saved, [], "a second without layout ended the run")

        second(1_040, passes: 40)
        second(1_041, passes: 40)
        second(1_042, passes: 40)
        time = 1_043
        watch.layoutPass()
        XCTAssertEqual(saved, [.storm], "three seconds of it, no row changing")
    }

    @MainActor
    func testAFreezeReportCarriesTheStallTraceFromItsSpan() async throws {
        ChatTraceStubProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatTraceReports-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let end = Int(Date().timeIntervalSince1970) - 60
        let name = "diagnostics-\(end - 3_540)-\(end)-abc.json"
        let hang: [String: Any] = ["hangDiagnostics": [["diagnosticMetaData": ["appBuildVersion": "245", "hangDuration": "4 sec"], "callStackTree": ["callStacks": []]]]]
        try JSONSerialization.data(withJSONObject: hang).write(to: directory.appendingPathComponent(name))
        let traces = traceStore()
        let inSpan = Date(timeIntervalSince1970: TimeInterval(end - 1_800))
        let stall = try XCTUnwrap(traces.save(.stall, lines: ["1.000 stall: main thread away 2.4 s"], now: inSpan))
        traces.save(.jump, lines: ["1.000 jump"], now: inSpan.addingTimeInterval(60))
        traces.save(.stall, lines: ["1.000 an older stall"], now: inSpan.addingTimeInterval(-86_400))
        let relay = URL(string: "https://relay.example")!

        func send() async {
            let defaults = traceDefaults()
            CrashReportQueue(defaults: defaults).add(name)
            let offer = CrashReportOffer(queue: CrashReportQueue(defaults: defaults), directory: directory, traces: traces, relayURL: relay, session: traceSession(), thanksFor: .zero)
            await offer.refresh()
            XCTAssertEqual(offer.state, .asking(crashed: false))
            await offer.send()
        }

        // A relay before 0.25 refuses the bigger post: sent again without.
        ChatTraceStubProtocol.answers = [(413, "{}"), (201, "{\"id\":\"1\"}")]
        await send()
        XCTAssertEqual(ChatTraceStubProtocol.bodies.count, 2)
        let carried = try XCTUnwrap(ChatTraceStubProtocol.bodies.first?["trace"] as? [String: Any])
        XCTAssertEqual(carried["reason"] as? String, "stall")
        XCTAssertEqual((carried["lines"] as? [String])?.last, "1.000 stall: main thread away 2.4 s", "the newest stall in the span")
        XCTAssertNil(ChatTraceStubProtocol.bodies.last?["trace"])
        XCTAssertNotNil(traces.traces().first { $0.fileName == stall }, "still here to send")

        // One that takes the report and drops what it doesn't know: kept.
        ChatTraceStubProtocol.reset()
        ChatTraceStubProtocol.answers = [(201, "{\"id\":\"2\"}")]
        await send()
        XCTAssertNotNil(ChatTraceStubProtocol.bodies.first?["trace"])
        XCTAssertNotNil(traces.traces().first { $0.fileName == stall })

        // One that says it kept it: the phone's copy goes.
        ChatTraceStubProtocol.reset()
        ChatTraceStubProtocol.answers = [(201, "{\"id\":\"3\",\"trace\":true}")]
        await send()
        XCTAssertNil(traces.traces().first { $0.fileName == stall })
        XCTAssertEqual(traces.traces().map(\.reason), [.jump, .stall], "the others stay")
    }

    @MainActor
    func testChatTracesSendPostsWhatTheRecorderHoldsAndEverySavedTrace() async throws {
        ChatTraceStubProtocol.reset()
        let store = traceStore()
        let relay = URL(string: "https://relay.example")!
        ChatViewportTrace.shared.reset()
        let empty = await ChatTraceUpload.sendAll(store: store, relayURL: relay, session: traceSession())
        XCTAssertEqual(empty, .nothing)

        ChatViewportTrace.shared.log("event explicitLatest (button)")
        let start = Date().addingTimeInterval(-600)
        store.save(.jump, lines: ["1.000 jump"], now: start, appVersion: "2.2.1", build: "244")
        store.save(.storm, lines: ["1.000 storm"], now: start.addingTimeInterval(60), appVersion: "2.2.1", build: "245")
        ChatTraceStubProtocol.answers = Array(repeating: (201, "{\"id\":\"1\",\"trace\":true}"), count: 3)
        let sent = await ChatTraceUpload.sendAll(store: store, relayURL: relay, session: traceSession())
        XCTAssertEqual(sent, .sent)
        let reasons = ChatTraceStubProtocol.bodies.compactMap { ($0["trace"] as? [String: Any])?["reason"] as? String }
        XCTAssertEqual(reasons, ["manual", "storm", "jump"], "what it holds now first, then the newest saved")
        XCTAssertEqual(Set(ChatTraceStubProtocol.bodies.compactMap { $0["kind"] as? String }), ["chat"])
        XCTAssertEqual(ChatTraceStubProtocol.bodies.last?["build"] as? String, "244", "the build that saved it")
        XCTAssertEqual(ChatTraceStubProtocol.paths, Array(repeating: "/v1/crash-reports", count: 3))
        XCTAssertTrue(store.traces().isEmpty, "each one the relay kept leaves the phone")

        // A relay before 0.25 refuses kind chat: kept for Try again.
        ChatTraceStubProtocol.reset()
        ChatTraceStubProtocol.answers = [(400, "{\"error\":\"invalid_kind\"}")]
        let refused = await ChatTraceUpload.sendAll(store: store, relayURL: relay, session: traceSession())
        XCTAssertEqual(refused, .failed)
        XCTAssertEqual(store.traces().map(\.reason), [.manual])

        ChatTraceStubProtocol.reset()
        ChatTraceStubProtocol.answers = [(404, "{}")]
        let unsupported = await ChatTraceUpload.sendAll(store: store, relayURL: relay, session: traceSession())
        XCTAssertEqual(unsupported, .unsupported)
        ChatViewportTrace.shared.reset()
    }
}

/// Answers each request with the next of `answers` (the last repeats) and
/// records its path and JSON body.
private final class ChatTraceStubProtocol: URLProtocol {
    static var answers: [(Int, String)] = [(201, "{}")]
    static var paths: [String] = []
    static var bodies: [[String: Any]] = []

    static func reset() {
        answers = [(201, "{}")]
        paths = []
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.paths.append(request.url?.path ?? "")
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.bodies.append((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        let (status, body) = Self.answers.count > 1 ? Self.answers.removeFirst() : (Self.answers.first ?? (201, "{}"))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
