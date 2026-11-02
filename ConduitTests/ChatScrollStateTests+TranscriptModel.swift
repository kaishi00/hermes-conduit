import XCTest
@testable import Conduit

/// TranscriptModel (#1533, the transcript rewrite): which rows the chat's
/// transcript draws, in order, and what each update changed by row id.
extension ChatScrollStateTests {
    @MainActor
    private func targets(_ messages: [ChatMessage]) -> [ChatMessageScrollTarget] {
        var cache = ChatMessageScrollTargetCache()
        cache.update(for: messages)
        return cache.targets
    }

    /// Its text names it: rows with the same text count as one row said
    /// twice (ChatScrollAnchorMetadata), which changes their targets.
    private func message(_ id: String, _ role: MessageRole, _ content: String? = nil) -> ChatMessage {
        ChatMessage(id: id, role: role, content: content ?? "Row \(id)", timestamp: "2026-10-31T09:00:00Z")
    }

    private func toolStep(_ id: String) -> ChatMessage {
        ChatMessage(
            id: id, role: .tool, content: "", timestamp: "2026-10-31T09:00:00Z",
            tool: ToolActivity(id: id, name: "web_search", input: nil, output: nil, status: .complete)
        )
    }

    private func pendingSend() -> PendingComposerSend {
        PendingComposerSend(
            draftText: "Are you there?",
            replyReference: nil,
            dashboardID: UUID(),
            profile: "default",
            sessionIDs: ["s1"],
            draftSessionID: "s1",
            isNewChat: false,
            title: "A chat"
        )
    }

    @MainActor
    private func rows(
        _ input: TranscriptModel.Input,
        _ targets: [ChatMessageScrollTarget] = [],
        disclosure: ChatRowDisclosure? = nil
    ) -> [TranscriptRow] {
        // A default argument can't make the main actor's disclosure.
        TranscriptModel.rows(for: input, targets: targets, disclosure: disclosure ?? ChatRowDisclosure())
    }

    @MainActor
    func testTheTranscriptDrawsTheChatsRowsThenTheLiveTurnThenTheWaitingSend() {
        // A finished run of steps folds into its first row.
        let chat = targets([
            message("u1", .user), message("r", .reasoning), toolStep("t"),
            message("a1", .assistant), message("u2", .user),
        ])
        let pending = pendingSend()
        var input = TranscriptModel.Input(targetsRevision: 1, isBusy: true, pendingSend: pending, loadsEarlier: true)
        input.live = TranscriptModel.LiveTurn(
            shape: LiveTurnShape(thinkingID: "seg", streams: false),
            isBusy: true,
            working: TranscriptWorkingLine(toolName: "web_search", startedAt: Date(timeIntervalSince1970: 100))
        )
        let drawn = rows(input, chat)
        XCTAssertEqual(
            drawn.map(\.id),
            [TranscriptRow.loadEarlierID, "u1", "r", "a1", "u2", "seg", TranscriptRow.workingID, TranscriptRow.pendingSendID]
        )
        XCTAssertEqual(drawn.first?.kind, .loadEarlier(isLoading: false))
        XCTAssertEqual(drawn[1].kind, .message(chat[0]), "the target itself, its run's placement included")
        XCTAssertEqual(drawn[5].kind, .thinking)
        XCTAssertEqual(
            drawn[6].kind,
            .working(TranscriptWorkingLine(
                toolName: "web_search", isThinking: true, startedAt: Date(timeIntervalSince1970: 100)
            )),
            "the working line says Thinking while the thinking card shows"
        )
        XCTAssertEqual(drawn.last?.kind, .pendingSend(pending))

        input.isLoadingEarlier = true
        XCTAssertEqual(rows(input, chat).first?.kind, .loadEarlier(isLoading: true))
    }

    @MainActor
    func testAChatWithNoRowsDrawsItsWelcomeOrTheSavedCopysStatus() {
        let pending = pendingSend()
        XCTAssertEqual(rows(TranscriptModel.Input()).map(\.kind), [.empty])
        XCTAssertEqual(
            rows(TranscriptModel.Input(pendingSend: pending)).map(\.kind), [.pendingSend(pending)],
            "a send waiting in it is what the empty chat shows"
        )
        XCTAssertTrue(
            rows(TranscriptModel.Input(hasSavedCopy: true)).isEmpty,
            "a saved copy that isn't the chat on screen never leaves a welcome under the live chat"
        )

        var copy = TranscriptModel.Input(showsSavedCopy: true, hasSavedCopy: true, savedCopyIsOpening: true)
        XCTAssertEqual(rows(copy).map(\.kind), [.savedCopyStatus(isOpening: true)])
        copy.pendingSend = pending
        XCTAssertEqual(rows(copy).map(\.kind), [.savedCopyStatus(isOpening: true), .pendingSend(pending)])
        copy.savedCopyIsOpening = false
        XCTAssertEqual(rows(copy).map(\.kind), [.pendingSend(pending)], "no copy, but the send waits")
        copy.pendingSend = nil
        XCTAssertEqual(rows(copy).map(\.kind), [.savedCopyStatus(isOpening: false)])

        let chat = targets([message("u1", .user)])
        XCTAssertEqual(rows(TranscriptModel.Input(), chat).map(\.id), ["u1"], "rows of its own: no welcome")
        XCTAssertEqual(rows(copy, chat).map(\.id), ["u1"], "nor the copy's status")

        // A new view's first pass, before the engine has the chat's rows.
        XCTAssertTrue(rows(TranscriptModel.Input(rowsOnTheirWay: true)).isEmpty, "rows on their way: no welcome")
        copy.rowsOnTheirWay = true
        XCTAssertTrue(rows(copy).isEmpty, "nor the copy's status")
    }

    @MainActor
    func testTheTranscriptLeavesOutRowsThatDrawNothing() {
        // A turn's trailing run of steps: open while the turn runs.
        let chat = targets([message("u1", .user), message("r", .reasoning), toolStep("t1"), toolStep("t2")])
        let disclosure = ChatRowDisclosure()
        var model = TranscriptModel()
        var input = TranscriptModel.Input(targetsRevision: 1, isBusy: true)
        XCTAssertNotNil(model.update(input, targets: chat, disclosure: disclosure))
        XCTAssertEqual(model.rows.map(\.id), ["u1", "r", "t1", "t2"])

        input.isBusy = false
        _ = model.update(input, targets: chat, disclosure: disclosure)
        XCTAssertEqual(model.rows.map(\.id), ["u1", "r"], "a finished run folds into its first row")

        // Opening the run bumps the toggles' revision, which the input
        // carries: the same input draws the same rows without asking.
        disclosure.willToggleGroup("r", to: true)
        XCTAssertNil(model.update(input, targets: chat, disclosure: disclosure))
        input.disclosureRevision = disclosure.groupToggles.revision
        let opened = model.update(input, targets: chat, disclosure: disclosure)
        XCTAssertEqual(opened?.inserted, ["t1", "t2"])
        XCTAssertEqual(model.rows.map(\.id), ["u1", "r", "t1", "t2"])

        input.displayPreferences.showToolProgress = false
        _ = model.update(input, targets: chat, disclosure: disclosure)
        XCTAssertEqual(model.rows.map(\.id), ["u1", "r"], "Tool cards off hides the tool rows")
    }

    func testTheLiveTurnsRowsFollowItsShape() {
        typealias Live = TranscriptModel.LiveTurn
        func kinds(_ live: Live) -> [TranscriptRow.Kind] { live.rows.map(\.kind) }
        XCTAssertTrue(Live().rows.isEmpty)

        XCTAssertEqual(kinds(Live(isBusy: true)), [.working(TranscriptWorkingLine())])
        XCTAssertEqual(
            Live(shape: LiveTurnShape(thinkingID: "seg"), isBusy: true).rows.map(\.id),
            ["seg", TranscriptRow.workingID]
        )
        XCTAssertEqual(
            kinds(Live(shape: LiveTurnShape(streams: true), isBusy: true)), [.streaming(isActive: true)],
            "the reply streaming takes the working line's place"
        )
        XCTAssertEqual(
            kinds(Live(shape: LiveTurnShape(streams: true))), [.streaming(isActive: false)],
            "finishing after the turn ended"
        )
        XCTAssertEqual(
            kinds(Live(repliesElsewhere: true)), [.working(TranscriptWorkingLine(repliesElsewhere: true))],
            "another device getting the reply"
        )
        XCTAssertEqual(
            Live(shape: LiveTurnShape(streams: true), repliesElsewhere: true).rows.map(\.id),
            [TranscriptRow.streamingID, TranscriptRow.workingID]
        )

        let hidden = Live(shape: LiveTurnShape(thinkingID: "seg", streams: true), isBusy: true, isShown: false)
        XCTAssertTrue(hidden.rows.isEmpty, "not under a saved copy of another chat: the turn is the live chat's")
    }

    @MainActor
    func testAnUpdateSaysWhatChangedByRowID() {
        let disclosure = ChatRowDisclosure()
        var model = TranscriptModel()
        var input = TranscriptModel.Input(targetsRevision: 1)
        let first = targets([message("u1", .user), message("a1", .assistant)])
        XCTAssertEqual(model.update(input, targets: first, disclosure: disclosure)?.inserted, ["u1", "a1"])
        XCTAssertNil(model.update(input, targets: first, disclosure: disclosure), "the same input changes nothing")

        input.targetsRevision = 2
        let sent = targets([message("u1", .user), message("a1", .assistant), message("u2", .user)])
        XCTAssertEqual(
            model.update(input, targets: sent, disclosure: disclosure),
            TranscriptChangeSet(inserted: ["u2"])
        )

        input.targetsRevision = 3
        let edited = targets([message("u1", .user), message("a1", .assistant, "better"), message("u2", .user)])
        XCTAssertEqual(
            model.update(input, targets: edited, disclosure: disclosure),
            TranscriptChangeSet(changed: ["a1"]),
            "a row whose content changed is changed in place"
        )

        input.live.isBusy = true
        XCTAssertEqual(
            model.update(input, targets: edited, disclosure: disclosure),
            TranscriptChangeSet(inserted: [TranscriptRow.workingID])
        )
        input.live.shape.streams = true
        XCTAssertEqual(
            model.update(input, targets: edited, disclosure: disclosure),
            TranscriptChangeSet(inserted: [TranscriptRow.streamingID], removed: [TranscriptRow.workingID])
        )

        input.loadsEarlier = true
        XCTAssertEqual(
            model.update(input, targets: edited, disclosure: disclosure),
            TranscriptChangeSet(inserted: [TranscriptRow.loadEarlierID])
        )
        input.isLoadingEarlier = true
        XCTAssertEqual(
            model.update(input, targets: edited, disclosure: disclosure),
            TranscriptChangeSet(changed: [TranscriptRow.loadEarlierID])
        )

        // Older rows land above while the page loads, and the control goes.
        // The rows below move down in the targets' order but draw the same,
        // so only the page's rows come.
        input.targetsRevision = 4
        input.loadsEarlier = false
        input.isLoadingEarlier = false
        let paged = targets([
            message("u0", .user), message("a0", .assistant),
            message("u1", .user), message("a1", .assistant, "better"), message("u2", .user),
        ])
        XCTAssertEqual(
            model.update(input, targets: paged, disclosure: disclosure),
            TranscriptChangeSet(inserted: ["u0", "a0"], removed: [TranscriptRow.loadEarlierID])
        )
        XCTAssertEqual(model.rows.map(\.id), ["u0", "a0", "u1", "a1", "u2", TranscriptRow.streamingID])

        XCTAssertEqual(
            TranscriptChangeSet(inserted: ["a", "b", "c", "d"], removed: ["e"]).traceLine(rowCount: 9),
            "rows n=9 +4 -1 ~0 +[a,b,c,...] -[e]",
            "the recorder's line names counts and the first few ids, never a row's text"
        )
    }

    /// A row that only changes place is a move, not nothing, and only the
    /// rows that moved are named.
    func testRowsThatOnlyChangePlaceAreMoved() {
        let three = ["a", "b", "c"].map { TranscriptRow(id: $0, kind: .empty) }
        let swapped = TranscriptChangeSet.between(three, [three[1], three[0], three[2]])
        XCTAssertEqual(swapped, TranscriptChangeSet(moved: ["b"]), "one of the two moved past the other")
        XCTAssertFalse(swapped.isEmpty)
        XCTAssertEqual(swapped.traceLine(rowCount: 3), "rows n=3 +0 -0 ~0 >1 >[b]")

        let landed = TranscriptChangeSet.between(three, [three[0], TranscriptRow(id: "x", kind: .empty), three[1], three[2]])
        XCTAssertEqual(landed, TranscriptChangeSet(inserted: ["x"]), "a row landing between others moves none of them")

        let four = ["a", "b", "c", "d"].map { TranscriptRow(id: $0, kind: .empty) }
        XCTAssertEqual(
            TranscriptChangeSet.between(four, [four[1], four[2], four[3], four[0]]),
            TranscriptChangeSet(moved: ["a"]),
            "one row moved past three is that row, not four"
        )
        let redrawn = TranscriptRow(id: "a", kind: .loadEarlier(isLoading: false))
        XCTAssertEqual(
            TranscriptChangeSet.between(four, [four[1], four[2], four[3], redrawn]),
            TranscriptChangeSet(changed: ["a"], moved: ["a"]),
            "a row that draws differently in another place is both"
        )
    }

    @MainActor
    func testTranscriptRowIDsAreUniqueTheChatsRowsWinning() {
        // The thinking card the moment after it settles: the live card's
        // id is the settled row's.
        let chat = targets([message("u1", .user), message("seg", .reasoning), message("seg", .reasoning, "again")])
        var input = TranscriptModel.Input(targetsRevision: 1, isBusy: true)
        input.live = TranscriptModel.LiveTurn(shape: LiveTurnShape(thinkingID: "seg"), isBusy: true)
        let drawn = rows(input, chat)
        XCTAssertEqual(drawn.map(\.id), ["u1", "seg", TranscriptRow.workingID])
        XCTAssertEqual(drawn[1].kind, .message(chat[1]), "the settled row, the first of its id")

        // A chat row left out for its id is named, for the trace.
        var model = TranscriptModel()
        _ = model.update(input, targets: chat, disclosure: ChatRowDisclosure())
        XCTAssertEqual(model.repeatedIDs, ["seg"])
        XCTAssertEqual(TranscriptChangeSet.repeatedLine(model.repeatedIDs), "rows repeated n=1 [seg]")
        input.targetsRevision = 2
        _ = model.update(input, targets: Array(chat.prefix(2)), disclosure: ChatRowDisclosure())
        XCTAssertEqual(model.repeatedIDs, [], "the live card's id isn't a chat row's repeat")
    }

    @MainActor
    func testTheRowsFactsFollowTheRowsDrawn() {
        let disclosure = ChatRowDisclosure()
        var model = TranscriptModel()
        var input = TranscriptModel.Input(targetsRevision: 1)
        _ = model.update(input, targets: targets([message("u1", .user), message("a1", .assistant)]), disclosure: disclosure)
        XCTAssertEqual(model.facts.latestAssistantMessageID, "a1")
        XCTAssertEqual(model.facts.retryableReplyID, "a1")

        input.targetsRevision = 2
        let sent = targets([message("u1", .user), message("a1", .assistant), message("u2", .user)])
        _ = model.update(input, targets: sent, disclosure: disclosure)
        XCTAssertEqual(model.facts.latestAssistantMessageID, "a1")
        XCTAssertNil(model.facts.retryableReplyID, "a message after the reply: Retry would answer another turn")
        XCTAssertEqual(model.facts, ChatRowFacts(rows: sent.map(\.message), isBusy: false))
    }
}
