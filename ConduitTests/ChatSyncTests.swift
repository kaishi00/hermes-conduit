//
//  ChatSyncTests.swift
//  Conduit
//
//  One chat used from two devices (ChatSync.swift). The Chats list reads
//  the catalog again when the live registry has a chat it doesn't, at most
//  every 10 s and twice per chat. The open chat settles a turn that went
//  quiet here once the registry shows it over, says when another device is
//  getting the reply, and reads the rows of a turn another device ran.
//

import XCTest
@testable import Conduit

@MainActor
final class ChatSyncTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ChatSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - When the list reads the catalog

    func testAnUnlistedChatAsksForOneReadThenWaits() {
        var freshness = ChatListCatalogFreshness()
        XCTAssertTrue(freshness.shouldRead(forUnlisted: ["new"], now: start))
        XCTAssertFalse(freshness.shouldRead(forUnlisted: ["new"], now: start.addingTimeInterval(4)), "Within 10 s")
        XCTAssertFalse(
            freshness.shouldRead(forUnlisted: ["other"], now: start.addingTimeInterval(9)),
            "The interval holds for every chat"
        )
        XCTAssertTrue(freshness.shouldRead(forUnlisted: ["new"], now: start.addingTimeInterval(10)))
    }

    func testAChatTheCatalogNeverListsStopsAsking() {
        var freshness = ChatListCatalogFreshness()
        XCTAssertTrue(freshness.shouldRead(forUnlisted: ["archived"], now: start))
        XCTAssertTrue(freshness.shouldRead(forUnlisted: ["archived"], now: start.addingTimeInterval(10)))
        XCTAssertFalse(freshness.shouldRead(forUnlisted: ["archived"], now: start.addingTimeInterval(60)))
        XCTAssertTrue(
            freshness.shouldRead(forUnlisted: ["archived", "new"], now: start.addingTimeInterval(61)),
            "A new chat still asks"
        )
    }

    func testNothingUnlistedReadsNothing() {
        var freshness = ChatListCatalogFreshness()
        XCTAssertFalse(freshness.shouldRead(forUnlisted: [], now: start))
    }

    func testTheFallbackWaitsForAFirstReadAndForItsInterval() {
        var freshness = ChatListCatalogFreshness()
        XCTAssertFalse(freshness.shouldRead(olderThan: 30, now: start), "The list's own first load owns that")
        freshness.noteLoaded(at: start)
        XCTAssertFalse(freshness.shouldRead(olderThan: 30, now: start.addingTimeInterval(29)))
        XCTAssertTrue(freshness.shouldRead(olderThan: 30, now: start.addingTimeInterval(30)))
        // That read failed (no new load): it doesn't repeat every tick.
        XCTAssertFalse(freshness.shouldRead(olderThan: 30, now: start.addingTimeInterval(34)))
        XCTAssertTrue(freshness.shouldRead(olderThan: 30, now: start.addingTimeInterval(60)))
    }

    // MARK: - The open chat's checks

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func turn(
        running: Bool,
        runningTool: Bool = false,
        texts: [String] = ["Overlap test A: write a 600-word essay"]
    ) -> OpenChatLocalTurn {
        OpenChatLocalTurn(
            sessionID: "chat",
            isRunning: running,
            hasRunningTool: runningTool,
            ownTexts: texts
        )
    }

    private let idle = OpenChatRegistryRow(isRunning: false, messageCount: 4)

    // MARK: A turn that went quiet here

    func testAQuietTurnSettlesOnceTwoSnapshotsShowItOver() {
        var sync = OpenChatSync()
        let local = turn(running: true)
        XCTAssertFalse(sync.checkDue(local, now: at(0)))
        XCTAssertFalse(sync.checkDue(local, now: at(19)), "Streaming normally: no reads")
        XCTAssertTrue(sync.checkDue(local, now: at(20)))
        XCTAssertEqual(sync.observe(nil, snapshotAt: at(20), local: local, now: at(20), chatVisible: true), .none,
                       "One snapshot can miss a live row")
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(24), local: local, now: at(24), chatVisible: true), .settleTurn)
    }

    func testTheSameSnapshotCountsOnce() {
        var sync = OpenChatSync()
        let local = turn(running: true)
        _ = sync.checkDue(local, now: at(0))
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(21), local: local, now: at(21), chatVisible: false), .none)
        // The list's poll and the chat's tick share one snapshot.
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(21), local: local, now: at(22), chatVisible: true), .none)
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(25), local: local, now: at(25), chatVisible: true), .settleTurn)
    }

    func testAStreamEventKeepsTheTurn() {
        var sync = OpenChatSync()
        let local = turn(running: true)
        _ = sync.checkDue(local, now: at(0))
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(21), local: local, now: at(21), chatVisible: true), .none)
        sync.noteStreamEvent(at: at(22))
        XCTAssertFalse(sync.checkDue(local, now: at(30)), "Not quiet any more")
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(30), local: local, now: at(30), chatVisible: true), .none)
    }

    func testARunningOrStartingTurnIsNeverSettled() {
        var sync = OpenChatSync()
        let local = turn(running: true, runningTool: true)
        _ = sync.checkDue(local, now: at(0))
        let working = OpenChatRegistryRow(isRunning: true, preview: "Overlap test A: write a 600-word essay")
        let starting = OpenChatRegistryRow(isRunning: false, isStarting: true)
        for (index, second) in stride(from: 21.0, through: 300, by: 8).enumerated() {
            let row = index.isMultiple(of: 2) ? working : starting
            XCTAssertEqual(
                sync.observe(row, snapshotAt: at(second), local: local, now: at(second), chatVisible: true), .none,
                "A long tool runs quiet; the stream is never asked back"
            )
        }
    }

    func testTheSettleWaitsTenSecondsAfterTheLastRead() {
        var sync = OpenChatSync()
        let local = turn(running: true)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observe(idle, snapshotAt: at(21), local: local, now: at(21), chatVisible: true)
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(22), local: local, now: at(22), chatVisible: true), .settleTurn)
        // The read didn't settle it (still running here).
        _ = sync.observe(idle, snapshotAt: at(25), local: local, now: at(25), chatVisible: true)
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(28), local: local, now: at(28), chatVisible: true), .none)
        _ = sync.observe(idle, snapshotAt: at(31), local: local, now: at(31), chatVisible: true)
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(33), local: local, now: at(33), chatVisible: true), .settleTurn)
    }

    // MARK: Another device getting the reply

    func testAForeignPreviewSaysAnotherDeviceIsReplying() {
        var sync = OpenChatSync()
        let local = turn(running: true)
        _ = sync.checkDue(local, now: at(0))
        let merged = OpenChatRegistryRow(
            isRunning: true,
            preview: "Overlap test A: write a 600-word essay\n\nOverlap test B: reply only with MANGO"
        )
        _ = sync.observe(merged, snapshotAt: at(21), local: local, now: at(21), chatVisible: true)
        XCTAssertFalse(sync.repliesElsewhere, "The prompt still reads as this device's")
        let reply = OpenChatRegistryRow(isRunning: true, preview: "MANGO **Rings of the Main: A History")
        _ = sync.observe(reply, snapshotAt: at(29), local: local, now: at(29), chatVisible: true)
        XCTAssertTrue(sync.repliesElsewhere)
        sync.noteStreamEvent(at: at(30))
        XCTAssertFalse(sync.repliesElsewhere, "The stream is back here")
    }

    func testAReplyStreamingHereIsNotForeign() {
        XCTAssertFalse(OpenChatSync.previewIsForeign(
            "In a glass jar on the counter",
            ownTexts: ["write a story", "In a glass jar on the counter of a farmhouse kitchen"]
        ))
        XCTAssertFalse(OpenChatSync.previewIsForeign("", ownTexts: []))
        XCTAssertTrue(OpenChatSync.previewIsForeign("PINEAPPLE", ownTexts: ["write a story", ""]))
        XCTAssertFalse(
            OpenChatSync.previewIsForeign("@file:report.pdf Summarize this report for the board", ownTexts: ["Summarize this report for the board"]),
            "A prompt sent with file references is still this device's"
        )
        XCTAssertFalse(OpenChatSync.previewIsForeign("a  b\n c", ownTexts: ["a b c d"]), "Whitespace collapses")
    }

    func testAnIdleChatShowsATurnRunningElsewhereThenReadsIt() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        XCTAssertTrue(sync.checkDue(local, now: at(0)))
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(0), local: local, now: at(0), chatVisible: true), .none)
        let working = OpenChatRegistryRow(isRunning: true, messageCount: 4, preview: "PINEAPPLE")
        _ = sync.observe(working, snapshotAt: at(15), local: local, now: at(15), chatVisible: true)
        XCTAssertTrue(sync.repliesElsewhere)
        // Hermes without message_count still reads it after the run.
        let over = OpenChatRegistryRow(isRunning: false)
        XCTAssertEqual(sync.observe(over, snapshotAt: at(30), local: local, now: at(30), chatVisible: true), .readNewRows)
        XCTAssertFalse(sync.repliesElsewhere)
        XCTAssertEqual(sync.observe(over, snapshotAt: at(45), local: local, now: at(45), chatVisible: true), .none)
    }

    func testThisDevicesOwnTurnEndingIsNotRunningElsewhere() {
        var sync = OpenChatSync()
        sync.noteSentHere()
        _ = sync.checkDue(turn(running: true), now: at(0))
        // The turn ended here; the registry still shows it for a moment.
        let local = turn(running: false)
        let working = OpenChatRegistryRow(isRunning: true, messageCount: 4)
        _ = sync.observe(working, snapshotAt: at(2), local: local, now: at(2), chatVisible: true)
        XCTAssertFalse(sync.repliesElsewhere)
        XCTAssertEqual(
            sync.observe(OpenChatRegistryRow(isRunning: false, messageCount: 6), snapshotAt: at(17), local: local, now: at(17), chatVisible: true),
            .none,
            "Its own rows are already here"
        )
    }

    func testATurnSentHereMovesTheCountWithoutARead() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observe(idle, snapshotAt: at(0), local: local, now: at(0), chatVisible: true)
        // A quick turn sent here, over between two checks.
        sync.noteSentHere()
        let moved = OpenChatRegistryRow(isRunning: false, messageCount: 6)
        XCTAssertEqual(sync.observe(moved, snapshotAt: at(15), local: local, now: at(15), chatVisible: true), .none)
        XCTAssertEqual(sync.observe(moved, snapshotAt: at(30), local: local, now: at(30), chatVisible: true), .none)
    }

    func testThisDevicesOwnTextRunningIsNotElsewhere() {
        var sync = OpenChatSync()
        let local = turn(running: false, texts: ["Plan my week", "Here is your week: Monday …"])
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observe(idle, snapshotAt: at(0), local: local, now: at(0), chatVisible: true)
        // /goal judging after this device's reply keeps the turn "working".
        let judging = OpenChatRegistryRow(isRunning: true, messageCount: 4, preview: "Here is your week: Monday …")
        _ = sync.observe(judging, snapshotAt: at(15), local: local, now: at(15), chatVisible: true)
        XCTAssertFalse(sync.repliesElsewhere)
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(30), local: local, now: at(30), chatVisible: true), .none)
    }

    func testACalledOffReadAsksAgain() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observe(idle, snapshotAt: at(0), local: local, now: at(0), chatVisible: true)
        let moved = OpenChatRegistryRow(isRunning: false, messageCount: 6)
        XCTAssertEqual(sync.observe(moved, snapshotAt: at(15), local: local, now: at(15), chatVisible: true), .readNewRows)
        sync.readCalledOff()
        XCTAssertEqual(sync.observe(moved, snapshotAt: at(30), local: local, now: at(30), chatVisible: true), .readNewRows)
    }

    func testARegistryThatKeepsFailingIsAskedAtTheSamePace() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        XCTAssertTrue(sync.checkDue(local, now: at(0)))
        // No snapshot came back.
        XCTAssertFalse(sync.checkDue(local, now: at(5)))
        XCTAssertFalse(sync.checkDue(local, now: at(10)))
        XCTAssertTrue(sync.checkDue(local, now: at(15)))
    }

    func testACountThatMovedReadsTheNewRowsOnceTheChatShows() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observe(idle, snapshotAt: at(0), local: local, now: at(0), chatVisible: true)
        let moved = OpenChatRegistryRow(isRunning: false, messageCount: 6)
        XCTAssertEqual(
            sync.observe(moved, snapshotAt: at(15), local: local, now: at(15), chatVisible: false), .none,
            "Behind the list it waits"
        )
        XCTAssertEqual(sync.observe(moved, snapshotAt: at(19), local: local, now: at(19), chatVisible: true), .readNewRows)
        XCTAssertEqual(sync.observe(moved, snapshotAt: at(34), local: local, now: at(34), chatVisible: true), .none)
    }

    func testTheChatsRowsReadAsOne() {
        let rows = [
            LiveSessionStatus(runtimeSessionId: "rt-voice", storedSessionId: "chat", status: "idle", messageCount: 4),
            LiveSessionStatus(runtimeSessionId: "rt-chat", storedSessionId: "chat", status: "working", messageCount: 2, preview: "MANGO"),
        ]
        XCTAssertEqual(
            AppState.openChatRegistryRow(rows),
            OpenChatRegistryRow(isRunning: true, messageCount: 4, preview: "MANGO")
        )
        XCTAssertNil(AppState.openChatRegistryRow([]))
        XCTAssertEqual(
            AppState.openChatRegistryRow([LiveSessionStatus(runtimeSessionId: "rt", storedSessionId: "chat", status: "starting")]),
            OpenChatRegistryRow(isRunning: false, isStarting: true)
        )
    }

    func testAnotherChatStartsOver() {
        var sync = OpenChatSync()
        let local = turn(running: true)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observe(idle, snapshotAt: at(21), local: local, now: at(21), chatVisible: true)
        var other = local
        other.sessionID = "other"
        XCTAssertFalse(sync.checkDue(other, now: at(22)), "Its own turn has just begun")
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(23), local: other, now: at(23), chatVisible: true), .none)
    }

    // MARK: A turn the registry never saw (#1026)

    /// A message sent from the TUI on the gateway's computer runs in
    /// another process: this gateway's registry row stays idle with its old
    /// count, and only the stored count says the chat moved.
    func testAStoredCountThatMovedWhileIdleReadsTheNewRows() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        XCTAssertEqual(sync.observeCatalog(messageCount: 211, local: local, now: at(10), chatVisible: true), .none,
                       "The first read sets the baseline")
        XCTAssertEqual(sync.observeCatalog(messageCount: 211, local: local, now: at(20), chatVisible: true), .none)
        XCTAssertEqual(sync.observeCatalog(messageCount: 213, local: local, now: at(30), chatVisible: true), .readNewRows)
        XCTAssertEqual(sync.observeCatalog(messageCount: 213, local: local, now: at(45), chatVisible: true), .none)
    }

    func testAStoredCountWithoutAValueReadsNothing() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        XCTAssertEqual(sync.observeCatalog(messageCount: nil, local: local, now: at(10), chatVisible: true), .none)
        XCTAssertEqual(sync.observeCatalog(messageCount: nil, local: local, now: at(30), chatVisible: true), .none)
    }

    func testThisDevicesOwnTurnMovesTheStoredCountWithoutARead() {
        var sync = OpenChatSync()
        _ = sync.checkDue(turn(running: false), now: at(0))
        XCTAssertEqual(sync.observeCatalog(messageCount: 4, local: turn(running: false), now: at(10), chatVisible: true), .none)
        sync.noteSentHere()
        XCTAssertEqual(sync.observeCatalog(messageCount: 5, local: turn(running: true), now: at(12), chatVisible: true), .none)
        // The turn ended here; its last rows land just after.
        XCTAssertEqual(sync.observeCatalog(messageCount: 6, local: turn(running: false), now: at(20), chatVisible: true), .none)
        XCTAssertEqual(sync.observeCatalog(messageCount: 6, local: turn(running: false), now: at(30), chatVisible: true), .none)
        // A command sent here that ran no turn.
        sync.noteSentHere()
        XCTAssertEqual(sync.observeCatalog(messageCount: 7, local: turn(running: false), now: at(40), chatVisible: true), .none)
        XCTAssertEqual(sync.observeCatalog(messageCount: 9, local: turn(running: false), now: at(60), chatVisible: true), .readNewRows,
                       "Then another device's turn reads")
    }

    func testAStoredCountThatMovedBehindTheListWaitsForTheChat() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observeCatalog(messageCount: 4, local: local, now: at(10), chatVisible: true)
        XCTAssertEqual(sync.observeCatalog(messageCount: 6, local: local, now: at(20), chatVisible: false), .none)
        XCTAssertEqual(sync.observeCatalog(messageCount: 6, local: local, now: at(30), chatVisible: true), .readNewRows)
    }

    func testStoredCountReadsKeepTheirTenSecondSpacing() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observeCatalog(messageCount: 4, local: local, now: at(10), chatVisible: true)
        XCTAssertEqual(sync.observeCatalog(messageCount: 6, local: local, now: at(20), chatVisible: true), .readNewRows)
        XCTAssertEqual(sync.observeCatalog(messageCount: 8, local: local, now: at(25), chatVisible: true), .none)
        XCTAssertEqual(sync.observeCatalog(messageCount: 8, local: local, now: at(30), chatVisible: true), .readNewRows)
    }

    /// A gateway that announces another client's message (`user.message`):
    /// the turn it starts is read once it is over, as one the registry saw.
    func testAUserMessageFromElsewhereReadsItsTurnOnceOver() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observe(idle, snapshotAt: at(0), local: local, now: at(0), chatVisible: true)
        sync.noteUserMessageElsewhere()
        let working = OpenChatRegistryRow(isRunning: true, messageCount: 5, preview: "From the TUI")
        XCTAssertEqual(sync.observe(working, snapshotAt: at(3), local: local, now: at(3), chatVisible: true), .none)
        XCTAssertEqual(sync.observe(idle, snapshotAt: at(15), local: local, now: at(15), chatVisible: true), .readNewRows,
                       "Read even with the count unchanged")
    }

    func testACalledOffStoredCountReadAsksAgain() {
        var sync = OpenChatSync()
        let local = turn(running: false)
        _ = sync.checkDue(local, now: at(0))
        _ = sync.observeCatalog(messageCount: 4, local: local, now: at(10), chatVisible: true)
        XCTAssertEqual(sync.observeCatalog(messageCount: 6, local: local, now: at(20), chatVisible: true), .readNewRows)
        sync.readCalledOff()
        XCTAssertEqual(sync.observeCatalog(messageCount: 6, local: local, now: at(25), chatVisible: true), .readNewRows,
                       "Same count, still unread")
        XCTAssertEqual(sync.observeCatalog(messageCount: 6, local: local, now: at(40), chatVisible: true), .none)
    }

    func testCatalogChangesAreReadFiveSecondsApartAndNotDuringATurnHere() {
        var signal = CatalogChangeSignal()
        XCTAssertNil(signal.delayUntilDue(now: at(0)))
        XCTAssertFalse(signal.takeRead(now: at(0), turnRunningHere: false), "Nothing changed")
        signal.noteChanged()
        XCTAssertTrue(signal.takeRead(now: at(0), turnRunningHere: false))
        XCTAssertFalse(signal.isPending)
        signal.noteChanged()
        XCTAssertEqual(signal.delayUntilDue(now: at(2)), 3)
        XCTAssertFalse(signal.takeRead(now: at(2), turnRunningHere: false))
        XCTAssertFalse(signal.takeRead(now: at(6), turnRunningHere: true), "A turn here moves it the whole time")
        XCTAssertTrue(signal.isPending, "Held for when the turn ends")
        XCTAssertTrue(signal.takeRead(now: at(40), turnRunningHere: false))
    }

    // MARK: - The Chats list reading the catalog

    private func row(_ id: String, profile: String, minutesAgo: Double = 60) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: [],
            title: id,
            model: "Hermes",
            updatedLabel: "",
            lastActivityAt: Date().timeIntervalSince1970 - minutesAgo * 60,
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false,
            messageCount: 2,
            lineageRootId: nil
        )
    }

    private final class Box {
        var live: [LiveSessionStatus] = []
        var catalog: [SessionSummary] = []
        var loads = 0
        var now = Date(timeIntervalSince1970: 2_000_000)
    }

    private func makeAppState(_ box: Box) -> AppState {
        let appState = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            sessionCatalogLoader: { _ in
                box.loads += 1
                return box.catalog
            },
            chatResumeLifecycleOperations: ChatResumeLifecycleOperations(
                probeActiveSessions: { _ in box.live }
            )
        )
        appState.client = HermesClient(
            connection: HermesConnection(baseUrl: "https://hermes.test", ticket: "ticket"),
            profile: "default"
        )
        appState.isConnected = true
        appState.chatSyncNow = { box.now }
        // Not this Mac's Low Power Mode or network.
        appState.deviceConditions = { DeviceConditions() }
        return appState
    }

    private func poll(_ appState: AppState) async {
        await appState.chatListPollTick()
        await appState.leaveCatalogRefreshTask?.value
    }

    /// Hermes says a stored session moved (`sessions.changed`): the list
    /// reads the catalog without a pull, at most every 5 s; one that came
    /// sooner is read at the next poll.
    func testSessionsChangedReadsTheCatalog() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        box.catalog = [row("a", profile: profile)]
        appState.handleStreamEvent(.sessionsChanged)
        await appState.leaveCatalogRefreshTask?.value
        XCTAssertEqual(box.loads, 1)
        XCTAssertEqual(appState.sessions.map(\.id), ["a"])

        box.catalog = [row("b", profile: profile, minutesAgo: 1), row("a", profile: profile)]
        box.now += 2
        appState.handleStreamEvent(.sessionsChanged)
        await appState.leaveCatalogRefreshTask?.value
        XCTAssertEqual(box.loads, 1, "Within 5 s of the last")
        box.now += 4
        await poll(appState)
        XCTAssertEqual(box.loads, 2)
        XCTAssertEqual(Set(appState.sessions.map(\.id)), ["a", "b"])
    }

    func testAChatStartedOnAnotherDeviceIsListedWithoutAPull() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        appState.sessions = [row("older", profile: profile)]
        box.catalog = [row("numbers", profile: profile, minutesAgo: 1), row("older", profile: profile)]
        box.live = [LiveSessionStatus(runtimeSessionId: "rt-numbers", storedSessionId: "numbers", status: "working")]

        await poll(appState)

        XCTAssertEqual(box.loads, 1)
        XCTAssertEqual(appState.activeProfileSessions.map(\.id), ["numbers", "older"])
        box.now += 4
        await poll(appState)
        XCTAssertEqual(box.loads, 1, "Listed now: nothing more to read")
    }

    func testAListedChatReadsNothing() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        let listed = row("listed", profile: profile)
        appState.sessions = [listed]
        box.catalog = [listed]
        box.live = [
            LiveSessionStatus(runtimeSessionId: "rt-listed", storedSessionId: "listed", status: "working"),
            // A runtime that never stored anything names no chat.
            LiveSessionStatus(runtimeSessionId: "rt-scratch", storedSessionId: "", status: "idle"),
        ]

        for _ in 0..<3 {
            await poll(appState)
            box.now += 4
        }

        XCTAssertEqual(box.loads, 0)
    }

    func testAChatTheCatalogLeavesOutIsReadTwiceTenSecondsApart() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        appState.sessions = [row("listed", profile: profile)]
        box.catalog = [row("listed", profile: profile)]
        box.live = [LiveSessionStatus(runtimeSessionId: "rt-hidden", storedSessionId: "hidden", status: "idle")]

        // The 4 s poll for a minute.
        for _ in 0..<15 {
            await poll(appState)
            box.now += 4
        }

        // Two reads for the hidden chat (t = 0 and t = 12), then the 30 s
        // fallback once (t = 44, 32 s after the last read).
        XCTAssertEqual(box.loads, 3)
    }

    /// The live repro: the other device's New Chat makes the chat live
    /// before its first message makes it listable. Those two reads come too
    /// early; the message (working, then a new count) asks again.
    func testAChatCreatedEmptyIsListedOnceItsFirstMessageIsSent() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        appState.sessions = [row("older", profile: profile)]
        box.catalog = [row("older", profile: profile)]
        box.live = [LiveSessionStatus(
            runtimeSessionId: "rt-new", storedSessionId: "new", status: "idle", messageCount: 0
        )]
        for _ in 0..<5 { // 0 … 16 s
            await poll(appState)
            box.now += 4
        }
        XCTAssertEqual(box.loads, 2)

        box.live = [LiveSessionStatus(
            runtimeSessionId: "rt-new", storedSessionId: "new", status: "working", messageCount: 0
        )]
        box.catalog = [row("new", profile: profile, minutesAgo: 0), row("older", profile: profile)]
        await poll(appState) // 20 s: 8 s after the last read
        XCTAssertEqual(box.loads, 2)
        box.now += 4
        await poll(appState) // 24 s
        XCTAssertEqual(box.loads, 3)
        XCTAssertEqual(appState.activeProfileSessions.map(\.id), ["new", "older"])
    }

    func testAListLeftOnScreenReadsAgainEveryThirtySeconds() async {
        let box = Box()
        let appState = makeAppState(box)
        let profile = appState.activeProfile
        box.catalog = [row("listed", profile: profile)]
        await appState.loadSessions()
        XCTAssertEqual(box.loads, 1)

        for _ in 0..<7 { // 0 … 24 s
            await poll(appState)
            box.now += 4
        }
        XCTAssertEqual(box.loads, 1)
        await poll(appState) // 28 s
        box.now += 4
        await poll(appState) // 32 s
        XCTAssertEqual(box.loads, 2, "A rename made elsewhere shows within 30 s")
    }

    func testBackInTheAppReadsAnOldList() async {
        let box = Box()
        let appState = makeAppState(box)
        box.catalog = [row("listed", profile: appState.activeProfile)]
        await appState.loadSessions()

        box.now += 5
        appState.chatListBecameActive()
        await appState.leaveCatalogRefreshTask?.value
        XCTAssertEqual(box.loads, 1, "A fresh read stands")

        box.now += 10
        appState.chatListBecameActive()
        await appState.leaveCatalogRefreshTask?.value
        XCTAssertEqual(box.loads, 2)
    }

    // MARK: - The list's poll pace (PowerPolicy.swift)

    private func pollWait(_ appState: AppState) async -> TimeInterval {
        let wait = await appState.chatListPollTick()
        await appState.leaveCatalogRefreshTask?.value
        return wait
    }

    func testAQuietListPollsLessOftenAndCatchesUpWhenAChatStartsElsewhere() async {
        let box = Box()
        let appState = makeAppState(box)
        appState.pollJitter = { 0 }
        let profile = appState.activeProfile
        appState.sessions = [row("listed", profile: profile)]
        box.catalog = [row("listed", profile: profile)]
        box.live = [LiveSessionStatus(runtimeSessionId: "rt-listed", storedSessionId: "listed", status: "idle", messageCount: 2)]

        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            let wait = await pollWait(appState)
            waits.append(wait)
            box.now += wait
        }
        XCTAssertEqual(waits, [4, 8, 15, 30, 60])

        // Another device starts a chat: the unknown live id reads the
        // catalog at once, and the poll is quick again.
        box.live.append(LiveSessionStatus(runtimeSessionId: "rt-new", storedSessionId: "new", status: "working"))
        box.catalog = [row("new", profile: profile, minutesAgo: 0), row("listed", profile: profile)]
        let loadsBefore = box.loads
        let wait = await pollWait(appState)
        XCTAssertEqual(wait, 4)
        XCTAssertEqual(box.loads, loadsBefore + 1, "The unknown live id is read on the same tick")
        XCTAssertEqual(appState.activeProfileSessions.map(\.id), ["new", "listed"])
    }

    func testAReturnToTheAppOrASearchBringsTheListPollBack() async {
        let box = Box()
        let appState = makeAppState(box)
        appState.pollJitter = { 0 }
        box.live = []
        for _ in 0..<5 {
            box.now += await pollWait(appState)
        }
        XCTAssertEqual(appState.chatListPollPacer.backoff.interval, 60)
        appState.noteChatListInteraction()
        let wait = await pollWait(appState)
        XCTAssertEqual(wait, 4)
    }

    func testLowPowerModeStretchesTheListPoll() async {
        let box = Box()
        let appState = makeAppState(box)
        appState.pollJitter = { 0 }
        appState.deviceConditions = { DeviceConditions(lowPowerMode: true) }
        box.live = []
        let first = await pollWait(appState)
        box.now += first
        let second = await pollWait(appState)
        XCTAssertEqual([first, second], [12, 24])
    }
}
