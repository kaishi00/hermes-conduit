import XCTest
@testable import Conduit

/// Pure state-machine tests for ChatViewportController — the single
/// authority over the chat viewport. Every test asserts observable mode,
/// generation-advances, emitted effects, and command currency; never
/// internal counters.
final class ChatViewportControllerTests: XCTestCase {

    // MARK: - Helpers

    private let keyA = ChatScrollSessionKey(profile: "p", sessionID: "session-a")
    private let keyB = ChatScrollSessionKey(profile: "p", sessionID: "session-b")

    private func message(_ id: String, _ content: String) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            content: content,
            timestamp: "2026-01-01T00:00:00Z"
        )
    }

    private func identity(for key: ChatScrollSessionKey?) -> ChatScrollSessionIdentity {
        ChatScrollSessionIdentity(
            profile: key?.profile,
            canonicalSessionID: key?.sessionID,
            equivalentSessionIDs: key.map { [$0.sessionID] } ?? [],
            isReconciling: false,
            settledRevision: 0
        )
    }

    private func aliasedIdentity(
        _ keyA: ChatScrollSessionKey,
        _ keyB: ChatScrollSessionKey
    ) -> ChatScrollSessionIdentity {
        ChatScrollSessionIdentity(
            profile: keyA.profile,
            canonicalSessionID: keyA.sessionID,
            equivalentSessionIDs: [keyA.sessionID, keyB.sessionID],
            isReconciling: false,
            settledRevision: 0
        )
    }

    /// A controller that has adopted `key` while following-latest.
    private func makeController(following key: ChatScrollSessionKey?) -> ChatViewportController {
        var controller = ChatViewportController()
        _ = controller.renderedSessionChanged(
            to: key,
            identity: identity(for: key),
            viaNotification: false,
            viewportTransitionGeneration: 1
        )
        return controller
    }

    private func layoutFacts(
        bottomMarkerMaxY: CGFloat? = 800,
        viewportMinY: CGFloat? = 100,
        viewportMaxY: CGFloat? = 800,
        rowFrames: [ChatRenderedRowFrame] = [],
        scope: ChatRenderedScrollScope?
    ) -> ChatViewportLayoutFacts {
        ChatViewportLayoutFacts(
            bottomMarkerMaxY: bottomMarkerMaxY,
            viewportMinY: viewportMinY,
            viewportMaxY: viewportMaxY,
            rowFrames: rowFrames,
            renderedScope: scope
        )
    }

    private func scrollCommands(_ effects: [ChatViewportEffect]) -> [ChatViewportCommand] {
        effects.compactMap { effect in
            if case .scroll(let command) = effect { return command }
            return nil
        }
    }

    private func cancelEffects(_ effects: [ChatViewportEffect]) -> Bool {
        effects.contains(.cancelAutomaticRestoration)
    }

    private func dragBegan(
        _ controller: inout ChatViewportController,
        sessionKey: ChatScrollSessionKey? = nil,
        transitionGeneration: UInt64 = 1
    ) -> [ChatViewportEffect] {
        controller.userDragBegan(
            sessionKey: sessionKey,
            viewportTransitionGeneration: transitionGeneration
        )
    }

    private func restoreRequest(
        for key: ChatScrollSessionKey,
        snapshot: ChatScrollSnapshot = .latest
    ) -> ChatResumeRestorationRequest {
        ChatResumeRestorationRequest(
            generation: 9,
            sessionKey: key,
            destination: snapshot.followsLatest
                ? .latest
                : .snapshot(snapshot)
        )
    }

    // MARK: - Core ownership & generation

    func testInitialModeFollowsLatestAndFirstSessionAdoptionDoesNotScroll() {
        var controller = ChatViewportController()
        XCTAssertEqual(controller.mode, .followingLatest)
        let effects = controller.renderedSessionChanged(
            to: keyA,
            identity: identity(for: keyA),
            viaNotification: false,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(effects.isEmpty, "first adoption must not scroll: \(effects)")
        XCTAssertEqual(controller.renderedSessionKey, keyA)
    }

    func testExplicitLatestClaimsFollowingLatestCancelsRestorationAndScrollsAnimated() {
        var controller = makeController(following: keyA)
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        XCTAssertEqual(controller.mode, .browsing)
        _ = controller.restorationRequested(restoreRequest(for: keyA))
        XCTAssertEqual(controller.mode, .restoring)

        let before = controller.generation
        let effects = controller.explicitLatestRequested()
        XCTAssertTrue(cancelEffects(effects))
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .bottom(anchorID: "chat-latest-p-session-a"))
        XCTAssertEqual(commands[0].animated, true)
        XCTAssertEqual(commands[0].retry, .delayed(milliseconds: 150))
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertGreaterThan(controller.generation, before)
        XCTAssertTrue(controller.isCommandCurrent(commands[0]))
    }

    func testExplicitTopClaimsTopOwnershipNonAnimated() {
        var controller = makeController(following: keyA)
        let before = controller.generation
        let effects = controller.explicitTopRequested(request: 3)
        XCTAssertTrue(cancelEffects(effects))
        XCTAssertEqual(controller.mode, .explicitTop(request: 3))
        XCTAssertEqual(controller.generation, before + 1)
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(
            commands[0].destination,
            .top(anchorID: "chat-top-p-session-a", request: 3)
        )
        XCTAssertEqual(commands[0].animated, false)
        XCTAssertEqual(commands[0].retry, .delayed(milliseconds: 150))
    }

    func testExplicitTopThenExplicitLatestSupersedesTop() {
        var controller = makeController(following: keyA)
        let topEffects = controller.explicitTopRequested(request: 3)
        guard case .scroll(let topCommand) = topEffects.first(where: {
            if case .scroll = $0 { return true }
            return false
        }) else {
            return XCTFail("expected a scroll command")
        }
        XCTAssertEqual(controller.mode, .explicitTop(request: 3))

        _ = controller.explicitLatestRequested()
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertFalse(controller.isCommandCurrent(topCommand), "old top command must be stale")
    }

    func testUserDragBeginsSwitchesToBrowsingCancelsRestorationAndBumpsGeneration() {
        var controller = makeController(following: keyA)
        _ = controller.restorationRequested(restoreRequest(for: keyA))
        let before = controller.generation

        let effects = dragBegan(&controller, sessionKey: keyA)
        XCTAssertTrue(cancelEffects(effects))
        XCTAssertEqual(controller.mode, .browsing)
        XCTAssertEqual(controller.generation, before + 1)
    }

    func testDuplicateDragChangedCallbacksBeginOnlyOnce() {
        var controller = makeController(following: keyA)
        let first = dragBegan(&controller, sessionKey: keyA)
        let generationAfterFirst = controller.generation
        XCTAssertTrue(cancelEffects(first))

        // A duplicate onChanged callback for the same gesture must not
        // re-run the begin effects (single cancel, single bump).
        let second = dragBegan(&controller, sessionKey: keyA)
        XCTAssertFalse(cancelEffects(second))
        XCTAssertEqual(controller.generation, generationAfterFirst)
        XCTAssertEqual(controller.mode, .browsing)
    }

    func testDragInvalidateWithActiveGestureSuppressesNextBeginUntilFinish() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 4)
        let generationAfterBegin = controller.generation

        // Invalidate while the finger is down: the running gesture is dead,
        // and the NEXT begin must be suppressed exactly once.
        _ = controller.invalidateDrag(hasActiveGesture: true)
        let suppressed = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 4)
        XCTAssertFalse(cancelEffects(suppressed))
        XCTAssertEqual(controller.mode, .browsing)

        // Gesture ends: the invalidated gesture yields no completion.
        let ended = controller.userDragGestureEnded()
        XCTAssertTrue(ended.isEmpty)
        XCTAssertNil(controller.pendingDragEvaluation)

        // A fresh gesture begins cleanly and bumps the generation again.
        let fresh = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 4)
        XCTAssertTrue(cancelEffects(fresh))
        XCTAssertEqual(controller.generation, generationAfterBegin + 2)
    }

    func testInvalidateWithoutGestureCancelsPendingCompletion() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA)
        _ = controller.invalidateDrag(hasActiveGesture: false)
        let ended = controller.userDragGestureEnded()
        XCTAssertTrue(ended.isEmpty)
        XCTAssertNil(controller.pendingDragEvaluation)
    }

    func testAbandonDragAllowsFreshGestureAfterViewReappears() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA)
        _ = controller.invalidateDrag(hasActiveGesture: true)
        _ = controller.abandonDrag()

        let fresh = dragBegan(&controller, sessionKey: keyA)
        XCTAssertTrue(cancelEffects(fresh))
        XCTAssertEqual(controller.mode, .browsing)
    }

    func testUserDragGestureEndedSchedulesEvaluation() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 2)
        let effects = controller.userDragGestureEnded()
        guard case .scheduleDragEvaluation(let token) = effects.first else {
            return XCTFail("expected scheduleDragEvaluation, got \(effects)")
        }
        XCTAssertEqual(controller.pendingDragEvaluation, token)
        XCTAssertEqual(token.sessionKey, keyA)
    }

    func testEvaluateDragCompletionRelatchesNearBottomThenPersistsInOrder() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 2)
        _ = controller.userDragGestureEnded()
        guard let token = controller.pendingDragEvaluation else {
            return XCTFail("expected a pending evaluation")
        }
        // Finger is up; viewport settled near the bottom.
        _ = controller.layoutMetricsChanged(facts: layoutFacts(scope: controller.renderedScrollScope))
        XCTAssertTrue(controller.isNearBottom)

        let effects = controller.evaluateDragCompletion(
            token,
            viewportTransitionGeneration: 2
        )
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertEqual(effects, [
            .persistViewportSnapshot(for: keyA),
            .flushViewportPersistence,
        ])
        XCTAssertNil(controller.pendingDragEvaluation)
    }

    func testEvaluateDragCompletionAwayFromBottomStaysBrowsingAndPersists() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 2)
        _ = controller.userDragGestureEnded()
        guard let token = controller.pendingDragEvaluation else {
            return XCTFail("expected a pending evaluation")
        }
        // Far from the bottom.
        _ = controller.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 3000,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            )
        )
        XCTAssertFalse(controller.isNearBottom)

        let effects = controller.evaluateDragCompletion(
            token,
            viewportTransitionGeneration: 2
        )
        XCTAssertEqual(controller.mode, .browsing)
        XCTAssertEqual(effects, [
            .persistViewportSnapshot(for: keyA),
            .flushViewportPersistence,
        ])
    }

    func testEvaluateStaleDragCompletionDoesNothing() {
        // (a) Older drag generation.
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 2)
        _ = controller.userDragGestureEnded()
        guard let token = controller.pendingDragEvaluation else {
            return XCTFail("expected a pending evaluation")
        }
        _ = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 2)
        let effectsA = controller.evaluateDragCompletion(
            token,
            viewportTransitionGeneration: 2
        )
        XCTAssertTrue(effectsA.isEmpty)

        // (b) Unrelated session: token carries keyA, controller now renders
        // an unrelated keyB (not an alias).
        var controllerB = makeController(following: keyA)
        _ = controllerB.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 2)
        _ = controllerB.userDragGestureEnded()
        guard let tokenB = controllerB.pendingDragEvaluation else {
            return XCTFail("expected a pending evaluation")
        }
        _ = controllerB.renderedSessionChanged(
            to: keyB,
            identity: identity(for: keyB),
            viaNotification: false,
            viewportTransitionGeneration: 3
        )
        XCTAssertTrue(controllerB.evaluateDragCompletion(
            tokenB,
            viewportTransitionGeneration: 3
        ).isEmpty)

        // (c) Equivalent (alias) session: completion stays current.
        var controllerC = makeController(following: keyA)
        _ = controllerC.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 2)
        _ = controllerC.userDragGestureEnded()
        guard let tokenC = controllerC.pendingDragEvaluation else {
            return XCTFail("expected a pending evaluation")
        }
        let aliasKey = ChatScrollSessionKey(profile: "p", sessionID: "runtime-alias")
        _ = controllerC.renderedSessionChanged(
            to: aliasKey,
            identity: aliasedIdentity(keyA, aliasKey),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertFalse(controllerC.evaluateDragCompletion(
            tokenC,
            viewportTransitionGeneration: 2
        ).isEmpty)

        // (d) Pending restoration suppresses completion.
        var controllerD = makeController(following: keyA)
        _ = controllerD.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 2)
        _ = controllerD.userDragGestureEnded()
        guard let tokenD = controllerD.pendingDragEvaluation else {
            return XCTFail("expected a pending evaluation")
        }
        _ = controllerD.restorationRequested(restoreRequest(for: keyA))
        XCTAssertTrue(controllerD.evaluateDragCompletion(
            tokenD,
            viewportTransitionGeneration: 2
        ).isEmpty)

        // (e) Notification handoff suppresses completion.
        var controllerE = makeController(following: keyA)
        _ = controllerE.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 2)
        _ = controllerE.userDragGestureEnded()
        guard let tokenE = controllerE.pendingDragEvaluation else {
            return XCTFail("expected a pending evaluation")
        }
        _ = controllerE.notificationHandoffBegan(destination: keyB)
        XCTAssertTrue(controllerE.evaluateDragCompletion(
            tokenE,
            viewportTransitionGeneration: 2
        ).isEmpty)
    }

    func testEvaluateDragCompletionWhileStillDraggingDoesNothing() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA, transitionGeneration: 2)
        // No userDragGestureEnded: finger still down.
        XCTAssertNil(controller.pendingDragEvaluation)
        let token = ChatDragCompletionToken(
            dragGeneration: 1,
            sessionKey: keyA,
            viewportTransitionGeneration: 2
        )
        XCTAssertTrue(controller.evaluateDragCompletion(
            token,
            viewportTransitionGeneration: 2
        ).isEmpty)
    }

    // MARK: - Layout facts & following rendered growth

    func testLayoutGrowthWhileFollowingIssuesNonAnimatedBottomScrollBeyondTolerance() {
        var controller = makeController(following: keyA)
        let effects = controller.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 806,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            )
        )
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .bottom(anchorID: "chat-latest-p-session-a"))
        XCTAssertEqual(commands[0].animated, false)
        XCTAssertNil(commands[0].retry)
        XCTAssertTrue(controller.isCommandCurrent(commands[0]))
    }

    func testLayoutGrowthWithinFollowToleranceIssuesNothing() {
        var controller = makeController(following: keyA)
        let effects = controller.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 800.3,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            )
        )
        XCTAssertTrue(scrollCommands(effects).isEmpty)
        // Pinned exactly at the bottom also issues nothing.
        let pinned = controller.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 800,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            )
        )
        XCTAssertTrue(scrollCommands(pinned).isEmpty)
    }

    func testLayoutGrowthWhileBrowsingExplicitTopOrRestoringIssuesNothing() {
        // Browsing after a drag.
        var browsing = makeController(following: keyA)
        _ = dragBegan(&browsing, sessionKey: keyA)
        XCTAssertTrue(scrollCommands(browsing.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 1200,
                viewportMaxY: 800,
                scope: browsing.renderedScrollScope
            )
        )).isEmpty)

        // Explicit top ownership.
        var top = makeController(following: keyA)
        _ = top.explicitTopRequested(request: 1)
        XCTAssertTrue(scrollCommands(top.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 1200,
                viewportMaxY: 800,
                scope: top.renderedScrollScope
            )
        )).isEmpty)

        // Restoring.
        var restoring = makeController(following: keyA)
        _ = restoring.restorationRequested(restoreRequest(for: keyA))
        XCTAssertTrue(scrollCommands(restoring.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 1200,
                viewportMaxY: 800,
                scope: restoring.renderedScrollScope
            )
        )).isEmpty)

        // Handoff pending.
        var handing = makeController(following: keyA)
        _ = handing.notificationHandoffBegan(destination: keyB)
        XCTAssertTrue(scrollCommands(handing.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 1200,
                viewportMaxY: 800,
                scope: handing.renderedScrollScope
            )
        )).isEmpty)
    }

    func testLayoutTickNearBottomWhileBrowsingRelatchesWithoutScrolling() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA)
        XCTAssertEqual(controller.mode, .browsing)
        // Finger lifts (drag evaluation outcome is irrelevant here).
        _ = controller.userDragGestureEnded()

        // Scroll back down near the bottom (no finger): geometry tick with
        // the content bottom inside the near-bottom window.
        let effects = controller.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 830,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            )
        )
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertTrue(scrollCommands(effects).isEmpty, "relatch must not scroll")
    }

    func testLayoutTickRelatchSuppressedByPendingRestorationHandoffOrDrag() {
        // Pending restoration.
        var restoring = makeController(following: keyA)
        _ = dragBegan(&restoring, sessionKey: keyA)
        _ = restoring.restorationRequested(restoreRequest(for: keyA))
        _ = restoring.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 810,
                viewportMaxY: 800,
                scope: restoring.renderedScrollScope
            )
        )
        XCTAssertEqual(restoring.mode, .restoring)

        // Notification handoff.
        var handing = makeController(following: keyA)
        _ = dragBegan(&handing, sessionKey: keyA)
        _ = handing.notificationHandoffBegan(destination: keyB)
        _ = handing.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 810,
                viewportMaxY: 800,
                scope: handing.renderedScrollScope
            )
        )
        XCTAssertEqual(handing.mode, .transitioning)

        // Finger still down.
        var dragging = makeController(following: keyA)
        _ = dragBegan(&dragging, sessionKey: keyA)
        _ = dragging.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 810,
                viewportMaxY: 800,
                scope: dragging.renderedScrollScope
            )
        )
        XCTAssertEqual(dragging.mode, .browsing, "geometry must not relatch during a drag")
    }

    func testLayoutTickNearBottomReturnsExplicitTopToFollowingLatest() {
        var controller = makeController(following: keyA)
        _ = controller.explicitTopRequested(request: 2)
        XCTAssertEqual(controller.mode, .explicitTop(request: 2))

        // Away from bottom: stays pinned at top.
        _ = controller.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 2000,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            )
        )
        XCTAssertEqual(controller.mode, .explicitTop(request: 2))

        // Near bottom: ownership hands back to latest so auto-follow resumes.
        let effects = controller.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 810,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            )
        )
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertTrue(scrollCommands(effects).isEmpty, "hand-back must not scroll")
    }

    // MARK: - Transcript changes

    func testTranscriptChangeWhileFollowingReassertsLatestAnimated() {
        var controller = makeController(following: keyA)
        let effects = controller.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .bottom(anchorID: "chat-latest-p-session-a"))
        XCTAssertEqual(commands[0].animated, true)
        XCTAssertEqual(commands[0].retry, .delayed(milliseconds: 150))
        XCTAssertTrue(controller.isCommandCurrent(commands[0]))

        // Unchanged content reasserts nothing.
        let unchanged = controller.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(scrollCommands(unchanged).isEmpty)
    }

    func testTranscriptChangeWhileBrowsingOrRestoringOrHandoffNeverScrolls() {
        var browsing = makeController(following: keyA)
        _ = dragBegan(&browsing, sessionKey: keyA)
        XCTAssertTrue(scrollCommands(browsing.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )).isEmpty)

        var restoring = makeController(following: keyA)
        _ = restoring.restorationRequested(restoreRequest(for: keyA))
        XCTAssertTrue(scrollCommands(restoring.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )).isEmpty)

        var handing = makeController(following: keyA)
        _ = handing.notificationHandoffBegan(destination: keyB)
        XCTAssertTrue(scrollCommands(handing.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )).isEmpty)
    }

    func testThirtyHertzGrowthStaysPinnedWithoutUpwardJumps() {
        var controller = makeController(following: keyA)
        var nonBottomCommands = 0
        var generation = controller.generation
        for tick in 1...30 {
            let effects = controller.layoutMetricsChanged(
                facts: layoutFacts(
                    bottomMarkerMaxY: 800 + CGFloat(tick * 24),
                    viewportMaxY: 800,
                    scope: controller.renderedScrollScope
                )
            )
            let commands = scrollCommands(effects)
            XCTAssertEqual(commands.count, 1, "tick \(tick) must issue exactly one command")
            guard case .bottom = commands[0].destination else {
                nonBottomCommands += 1
                continue
            }
            XCTAssertTrue(controller.isCommandCurrent(commands[0]))
            // Growth alone never changes ownership.
            XCTAssertEqual(controller.mode, .followingLatest)
            XCTAssertEqual(controller.generation, generation, "growth must not bump generation")
        }
        XCTAssertEqual(nonBottomCommands, 0)
    }

    // MARK: - Session identity & transitions

    func testSessionSwitchToUnrelatedKeyClaimsFollowingLatestAndScrollsUnlessDragging() {
        var controller = makeController(following: keyA)
        let before = controller.generation
        let effects = controller.renderedSessionChanged(
            to: keyB,
            identity: identity(for: keyB),
            viaNotification: false,
            viewportTransitionGeneration: 3
        )
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertEqual(controller.generation, before + 1)
        XCTAssertEqual(controller.renderedSessionKey, keyB)
        XCTAssertEqual(controller.stableTopMessageID, nil)
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .bottom(anchorID: "chat-latest-p-session-b"))

        // While dragging: stays browsing, no scroll.
        var dragging = makeController(following: keyA)
        _ = dragBegan(&dragging, sessionKey: keyA)
        let draggingEffects = dragging.renderedSessionChanged(
            to: keyB,
            identity: identity(for: keyB),
            viaNotification: false,
            viewportTransitionGeneration: 3
        )
        XCTAssertEqual(dragging.mode, .browsing)
        XCTAssertTrue(scrollCommands(draggingEffects).isEmpty)
    }

    func testEquivalentSessionKeyRotationDoesNotBumpGenerationOrScroll() {
        var controller = makeController(following: keyA)
        let runtimeKey = ChatScrollSessionKey(profile: "p", sessionID: "runtime-alias")
        let before = controller.generation
        let effects = controller.renderedSessionChanged(
            to: runtimeKey,
            identity: aliasedIdentity(keyA, runtimeKey),
            viaNotification: false,
            viewportTransitionGeneration: 3
        )
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(controller.generation, before)
        XCTAssertEqual(controller.renderedSessionKey, runtimeKey)
    }

    func testStaleRestorationRequestForDifferentSessionCancelledOnSessionChange() {
        var controller = makeController(following: keyA)
        _ = controller.restorationRequested(restoreRequest(for: keyA))
        let effects = controller.renderedSessionChanged(
            to: keyB,
            identity: identity(for: keyB),
            viaNotification: false,
            viewportTransitionGeneration: 3
        )
        XCTAssertTrue(cancelEffects(effects))
        XCTAssertEqual(controller.mode, .followingLatest)
    }

    func testRenderedScopeMirrorsTransitionGenerationOnlyWhenFollowing() {
        // Adopt while following: mirror tracks.
        var controller = ChatViewportController()
        _ = controller.renderedSessionChanged(
            to: keyA,
            identity: identity(for: keyA),
            viaNotification: false,
            viewportTransitionGeneration: 5
        )
        XCTAssertEqual(controller.renderedScrollScope?.viewportTransitionGeneration, 5)

        // Browsing (after drag): a session change must NOT adopt the new
        // transition generation (old code only mirrored when following).
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 5)
        _ = controller.renderedSessionChanged(
            to: keyB,
            identity: identity(for: keyB),
            viaNotification: false,
            viewportTransitionGeneration: 7
        )
        XCTAssertEqual(
            controller.renderedScrollScope?.viewportTransitionGeneration,
            5,
            "session change while not following must keep the old mirror"
        )

        // transcriptChanged always mirrors (old messages/revision handlers).
        _ = controller.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 4,
            viewportTransitionGeneration: 7
        )
        XCTAssertEqual(controller.renderedScrollScope?.viewportTransitionGeneration, 7)
    }

    // MARK: - Notification handoff

    func testNotificationHandoffBeganEntersTransitioningCancelsRestorationAndSuppressesEverything() {
        var controller = makeController(following: keyA)
        _ = controller.restorationRequested(restoreRequest(for: keyA))
        let scrollBefore = controller.explicitLatestRequested()
        guard case .scroll(let latestCommand) = scrollBefore.first(where: {
            if case .scroll = $0 { return true }
            return false
        }) else {
            return XCTFail("expected a scroll command")
        }
        XCTAssertTrue(controller.isCommandCurrent(latestCommand))

        let before = controller.generation
        let effects = controller.notificationHandoffBegan(destination: keyB)
        XCTAssertTrue(cancelEffects(effects))
        XCTAssertEqual(controller.mode, .transitioning)
        XCTAssertEqual(controller.generation, before + 1)

        // The pre-handoff command is dead.
        XCTAssertFalse(controller.isCommandCurrent(latestCommand))

        // Automatic paths issue nothing while the handoff is pending.
        XCTAssertTrue(scrollCommands(controller.layoutMetricsChanged(
            facts: layoutFacts(
                bottomMarkerMaxY: 1200,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            )
        )).isEmpty)
        XCTAssertTrue(scrollCommands(controller.transcriptChanged(
            messages: [message("m1", "x")],
            transcriptRevision: 5,
            viewportTransitionGeneration: 1
        )).isEmpty)
    }

    func testNotificationHandoffDestinationReadyWithoutTopOwnerFollowsLatestNonAnimated() {
        var controller = makeController(following: keyA)
        _ = controller.notificationHandoffBegan(destination: keyB)
        _ = controller.notificationHandoffLayoutMeasured()
        let effects = controller.notificationHandoffDestinationReady(activeKey: keyB)
        XCTAssertEqual(controller.mode, .followingLatest)
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .bottom(anchorID: "chat-latest-p-session-b"))
        XCTAssertEqual(commands[0].animated, false)
        XCTAssertNil(commands[0].retry)
    }

    func testNotificationHandoffDestinationReadyWithActiveTopOwnerScrollsToTop() {
        var controller = makeController(following: keyA)
        _ = controller.notificationHandoffBegan(destination: keyB)
        // Title tap during the handoff.
        _ = controller.explicitTopRequested(request: 6)
        XCTAssertEqual(controller.mode, .explicitTop(request: 6))
        _ = controller.notificationHandoffLayoutMeasured()

        let effects = controller.notificationHandoffDestinationReady(activeKey: keyB)
        XCTAssertEqual(controller.mode, .explicitTop(request: 6))
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .top(anchorID: "chat-top-p-session-b", request: 6))
        XCTAssertEqual(commands[0].retry, .delayed(milliseconds: 150))
    }

    func testNotificationHandoffDestinationReadyWhileDraggingStaysBrowsingNoScroll() {
        var controller = makeController(following: keyA)
        _ = controller.notificationHandoffBegan(destination: keyB)
        _ = controller.notificationHandoffLayoutMeasured()
        // Finger down on the destination transcript.
        _ = controller.userDragBegan(sessionKey: keyB, viewportTransitionGeneration: 1)

        let effects = controller.notificationHandoffDestinationReady(activeKey: keyB)
        XCTAssertEqual(controller.mode, .browsing)
        XCTAssertTrue(scrollCommands(effects).isEmpty)
    }

    // MARK: - Command currency

    func testCommandCurrencyValidatesGenerationSessionAndMode() {
        var controller = makeController(following: keyA)
        let latest = controller.explicitLatestRequested()
        guard case .scroll(let bottomCommand) = latest.first(where: {
            if case .scroll = $0 { return true }
            return false
        }) else {
            return XCTFail("expected a scroll command")
        }
        XCTAssertTrue(controller.isCommandCurrent(bottomCommand))

        // Browsing invalidates bottom commands.
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        XCTAssertFalse(controller.isCommandCurrent(bottomCommand))

        // A top command is current only while its request owns the mode.
        let claim4 = controller.explicitTopRequested(request: 4)
        guard case .scroll(let topCommand4) = claim4.first(where: {
            if case .scroll = $0 { return true }
            return false
        }) else {
            return XCTFail("expected a scroll command")
        }
        XCTAssertTrue(controller.isCommandCurrent(topCommand4))
        _ = controller.explicitTopRequested(request: 5)
        XCTAssertFalse(controller.isCommandCurrent(topCommand4), "superseded by request 5")

        // A message command is current only while restoring.
        var restoring = makeController(following: keyA)
        _ = restoring.restorationRequested(restoreRequest(for: keyA))
        let messageCommand = ChatViewportCommand(
            generation: restoring.generation,
            sessionKey: keyA,
            destination: .message(id: "m1"),
            animated: false,
            retry: nil
        )
        XCTAssertTrue(restoring.isCommandCurrent(messageCommand))
        _ = restoring.explicitLatestRequested()
        XCTAssertFalse(restoring.isCommandCurrent(messageCommand))

        // Session mismatch invalidates.
        var switched = makeController(following: keyA)
        let switchedEffects = switched.explicitLatestRequested()
        guard case .scroll(let switchedCommand) = switchedEffects.first(where: {
            if case .scroll = $0 { return true }
            return false
        }) else {
            return XCTFail("expected a scroll command")
        }
        _ = switched.renderedSessionChanged(
            to: keyB,
            identity: identity(for: keyB),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertFalse(
            switched.isCommandCurrent(switchedCommand),
            "a command scoped to another session must die"
        )
    }

    // MARK: - View lifecycle

    func testViewDisappearedAbandonsDrag() {
        var controller = makeController(following: keyA)
        _ = dragBegan(&controller, sessionKey: keyA)
        _ = controller.invalidateDrag(hasActiveGesture: true)
        _ = controller.viewDisappeared()
        // A fresh gesture after reappear works.
        let fresh = dragBegan(&controller, sessionKey: keyA)
        XCTAssertTrue(cancelEffects(fresh))
    }

    // MARK: - Snapshots

    func testRenderedSnapshotMapsFollowingTopAndSyntheticTopAnchor() {
        var controller = makeController(following: keyA)
        XCTAssertEqual(controller.renderedViewportSnapshot()?.snapshot, .latest)

        // Browsing with a visible stable row persists that row's semantic
        // anchor — never the synthetic top marker.
        _ = dragBegan(&controller, sessionKey: keyA)
        _ = controller.transcriptChanged(
            messages: [message("m1", "one"), message("m2", "two")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        guard let scope = controller.renderedScrollScope else {
            return XCTFail("expected a scope")
        }
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 900,
            viewportMinY: 100,
            viewportMaxY: 800,
            rowFrames: [
                ChatRenderedRowFrame(id: "m1", minY: 40, maxY: 140, scope: scope),
                ChatRenderedRowFrame(id: "m2", minY: 160, maxY: 400, scope: scope),
            ],
            scope: scope
        ))
        XCTAssertEqual(controller.stableTopMessageID, "m1")
        let snapshot = controller.renderedViewportSnapshot()?.snapshot
        XCTAssertEqual(snapshot?.anchorMessageID, controller.targets.first?.semanticID)
        XCTAssertEqual(snapshot?.anchorSourceMessageID, "m1")
        XCTAssertEqual(snapshot?.followsLatest, false)

        // Browsing with nothing stable visible: no snapshot (old behavior).
        var empty = makeController(following: keyA)
        _ = dragBegan(&empty, sessionKey: keyA)
        XCTAssertNil(empty.renderedViewportSnapshot())
    }

    func testStableTopMessagePicksFirstTargetOrderRowIntersectingViewport() {
        var controller = makeController(following: keyA)
        _ = controller.transcriptChanged(
            messages: [message("m1", "one"), message("m2", "two"), message("m3", "three")],
            transcriptRevision: 1,
            viewportTransitionGeneration: 1
        )
        guard let scope = controller.renderedScrollScope else {
            return XCTFail("expected a scope")
        }
        // Only m2 and m3 rendered (lazy); m2 intersects the top edge.
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 900,
            viewportMinY: 100,
            viewportMaxY: 800,
            rowFrames: [
                ChatRenderedRowFrame(id: "m2", minY: 120, maxY: 300, scope: scope),
                ChatRenderedRowFrame(id: "m3", minY: 320, maxY: 500, scope: scope),
            ],
            scope: scope
        ))
        XCTAssertEqual(controller.stableTopMessageID, "m2")

        // Scroll up so m1's frame intersects even though it starts above the
        // viewport's top edge.
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 900,
            viewportMinY: 100,
            viewportMaxY: 800,
            rowFrames: [
                ChatRenderedRowFrame(id: "m1", minY: 40, maxY: 140, scope: scope),
                ChatRenderedRowFrame(id: "m2", minY: 160, maxY: 340, scope: scope),
            ],
            scope: scope
        ))
        XCTAssertEqual(controller.stableTopMessageID, "m1")
    }
}

// MARK: - Automatic restoration (Task 5)

extension ChatViewportControllerTests {

    private func snapshotRequest(
        anchor: String,
        for key: ChatScrollSessionKey
    ) -> ChatResumeRestorationRequest {
        let targets = [
            ChatMessageScrollTarget(
                message: message("m1", "one"),
                semanticID: anchor,
                restorationMetadata: ChatScrollAnchorMetadata(fingerprint: "fp", duplicateCount: 1)
            ),
            ChatMessageScrollTarget(
                message: message("m2", "two"),
                semanticID: "other",
                restorationMetadata: ChatScrollAnchorMetadata(fingerprint: "fp2", duplicateCount: 1)
            )
        ]
        var controller = ChatViewportController()
        _ = controller.renderedSessionChanged(
            to: key,
            identity: identity(for: key),
            viaNotification: false,
            viewportTransitionGeneration: 1
        )
        _ = controller.transcriptChanged(
            messages: targets.map(\.message),
            transcriptRevision: 3,
            viewportTransitionGeneration: 1,
            isInitialSync: true
        )
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: anchor,
            followsLatest: false,
            anchorMetadata: ChatScrollAnchorMetadata(fingerprint: "fp", duplicateCount: 1),
            anchorSourceMessageID: "m1"
        )
        return ChatResumeRestorationRequest(
            generation: 42,
            sessionKey: key,
            destination: .snapshot(snapshot)
        )
    }

    private func restorationScope(
        for request: ChatResumeRestorationRequest,
        in controller: ChatViewportController
    ) -> ChatRenderedScrollScope? {
        guard let base = controller.renderedScrollScope else { return nil }
        return ChatRenderedScrollScope(
            sessionKey: base.sessionKey,
            cacheRevision: base.cacheRevision,
            restorationGeneration: request.generation,
            transcriptRevision: base.transcriptRevision,
            viewportTransitionGeneration: base.viewportTransitionGeneration
        )
    }

    func testRestorationRequestedEntersRestoringInvalidatesDragAndResolvesDestination() {
        let messages = [message("m1", "one"), message("m2", "two")]
        var seeded = makeController(following: keyA)
        _ = seeded.transcriptChanged(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true
        )
        // Snapshot anchored at the semantic id resolves to the SOURCE
        // message id space inside the restoration state machine.
        guard let realTarget = seeded.targets.first else {
            return XCTFail("expected a target")
        }
        let realAnchor = realTarget.semanticID
        let request = snapshotRequest(anchor: realAnchor, for: keyA)
        _ = seeded.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)

        _ = seeded.restorationRequested(request)
        XCTAssertTrue(seeded.restorationIsActive)
        XCTAssertEqual(seeded.mode, .restoring)

        // A matching-scope tick scrolls to the SOURCE message id (m1), not
        // the semantic anchor string.
        let scope = restorationScope(for: request, in: seeded)!
        let effects = seeded.restorationTick(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            renderedContent: ChatRenderedScrollContent(scope: scope),
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil,
            isNearBottom: false
        )
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .message(id: "m1"))
    }

    func testRestorationWaitsForMatchingRenderedScopeBeforeScrolling() {
        var controller = makeController(following: keyA)
        let messages = [message("m1", "one")]
        _ = controller.transcriptChanged(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true
        )
        guard let target = controller.targets.first else {
            return XCTFail("expected a target")
        }
        let anchor = target.semanticID
        let request = snapshotRequest(anchor: anchor, for: keyA)
        _ = controller.restorationRequested(request)

        // A scope from a DIFFERENT restoration generation must not scroll.
        let staleScope = ChatRenderedScrollScope(
            sessionKey: keyA,
            cacheRevision: controller.renderedScrollScope?.cacheRevision ?? 0,
            restorationGeneration: 999,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1
        )
        let staleContent = ChatRenderedScrollContent(scope: staleScope)
        let staleTick = controller.restorationTick(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            renderedContent: staleContent,
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil,
            isNearBottom: false
        )
        XCTAssertTrue(staleTick.isEmpty)

        // Matching scope bootstraps the offscreen target: scroll issued.
        let scope = restorationScope(for: request, in: controller)!
        let content = ChatRenderedScrollContent(scope: scope)
        let scrollTick = controller.restorationTick(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil,
            isNearBottom: false
        )
        let commands = scrollCommands(scrollTick)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .message(id: controller.targets.first?.id ?? "missing"))
    }

    func testRestorationCompletesOnlyWhenAnchorConfirmedAndInstalled() {
        var controller = makeController(following: keyA)
        let messages = [message("m1", "one")]
        _ = controller.transcriptChanged(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true
        )
        guard let target = controller.targets.first else {
            return XCTFail("expected a target")
        }
        let request = snapshotRequest(anchor: target.semanticID, for: keyA)
        _ = controller.restorationRequested(request)
        guard let scope = restorationScope(for: request, in: controller) else {
            return XCTFail("expected a scope")
        }
        let content = ChatRenderedScrollContent(scope: scope)

        // Scroll first (previous tick), then a different rendered row must
        // NOT confirm, then the real row + topVisible confirm completes.
        _ = controller.restorationTick(
            messages: messages, transcriptRevision: 1, viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil, isNearBottom: false
        )
        var installed = ChatRenderedScrollTargets()
        ChatRenderedScrollTargets.reduce(
            value: &installed,
            nextValue: ChatRenderedScrollTargets.row(
                semanticID: "different-row", scope: scope
            )
        )
        let wrongRowTick = controller.restorationTick(
            messages: messages, transcriptRevision: 1, viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: installed,
            topVisibleID: target.id, isNearBottom: false
        )
        XCTAssertTrue(
            wrongRowTick.isEmpty,
            "a different rendered row must not confirm the cache target"
        )

        ChatRenderedScrollTargets.reduce(
            value: &installed,
            nextValue: ChatRenderedScrollTargets.row(semanticID: target.id, scope: scope)
        )
        let completeTick = controller.restorationTick(
            messages: messages, transcriptRevision: 1, viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: installed,
            topVisibleID: target.id, isNearBottom: false
        )
        XCTAssertEqual(completeTick, [.completeRestoration(generation: request.generation)])
        XCTAssertFalse(controller.restorationIsActive)
        XCTAssertEqual(controller.mode, .browsing)
    }

    func testRestorationLatestConfirmsOnlyWhenNearBottomAndPersistsAfterComplete() {
        var controller = makeController(following: keyA)
        let request = restoreRequest(for: keyA)  // .latest destination
        _ = controller.restorationRequested(request)
        guard let scope = restorationScope(for: request, in: controller) else {
            return XCTFail("expected a scope")
        }
        let content = ChatRenderedScrollContent(scope: scope)

        _ = controller.restorationTick(
            messages: [], transcriptRevision: 0, viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil, isNearBottom: false
        )
        var installed = ChatRenderedScrollTargets()
        ChatRenderedScrollTargets.reduce(
            value: &installed,
            nextValue: ChatRenderedScrollTargets.bottom(
                anchorID: "chat-latest-p-session-a", scope: scope
            )
        )
        let notNearBottom = controller.restorationTick(
            messages: [], transcriptRevision: 0, viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: installed,
            topVisibleID: nil, isNearBottom: false
        )
        XCTAssertTrue(notNearBottom.isEmpty, "latest must wait for near-bottom confirmation")

        let nearBottom = controller.restorationTick(
            messages: [], transcriptRevision: 0, viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: installed,
            topVisibleID: nil, isNearBottom: true
        )
        XCTAssertEqual(nearBottom, [
            .completeRestoration(generation: request.generation),
            .persistViewportSnapshot(for: request.sessionKey),
        ])
        XCTAssertEqual(controller.mode, .followingLatest)
    }

    func testRestorationAbandonsAfterBoundedChecks() {
        var controller = makeController(following: keyA)
        let request = restoreRequest(for: keyA)
        _ = controller.restorationRequested(request)
        // Mismatched scope forever: the budget exhausts and abandons.
        var lastEffects: [ChatViewportEffect] = []
        for _ in 0..<(RestorationState.maximumChecks + 2) {
            lastEffects = controller.restorationTick(
                messages: [], transcriptRevision: 0, viewportTransitionGeneration: 1,
                renderedContent: nil,
                installedTargets: ChatRenderedScrollTargets(),
                topVisibleID: nil, isNearBottom: false
            )
            guard controller.restorationIsActive else { break }
        }
        XCTAssertEqual(lastEffects, [.abandonRestoration(generation: request.generation)])
        XCTAssertFalse(controller.restorationIsActive)
        XCTAssertEqual(controller.mode, .browsing)
    }

    func testRestorationCancelledBySystemClearsStateToBrowsing() {
        var controller = makeController(following: keyA)
        _ = controller.restorationRequested(restoreRequest(for: keyA))
        XCTAssertEqual(controller.mode, .restoring)
        _ = controller.restorationSystemCancelled()
        XCTAssertFalse(controller.restorationIsActive)
        XCTAssertEqual(controller.mode, .browsing)
    }

    func testRestorationYieldsToExplicitCommandsAndStaleMessageCommandDies() {
        var controller = makeController(following: keyA)
        let messages = [message("m1", "one")]
        _ = controller.transcriptChanged(
            messages: messages, transcriptRevision: 1,
            viewportTransitionGeneration: 1, isInitialSync: true
        )
        guard let target = controller.targets.first else {
            return XCTFail("expected a target")
        }
        let request = snapshotRequest(anchor: target.semanticID, for: keyA)
        _ = controller.restorationRequested(request)
        let scope = restorationScope(for: request, in: controller)!
        let scrollEffects = controller.restorationTick(
            messages: messages, transcriptRevision: 1, viewportTransitionGeneration: 1,
            renderedContent: ChatRenderedScrollContent(scope: scope),
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil, isNearBottom: false
        )
        guard case .scroll(let messageCommand) = scrollEffects.first else {
            return XCTFail("expected a scroll command")
        }

        // Every explicit action wins and invalidates the message command.
        let explicitEffects = controller.explicitLatestRequested()
        XCTAssertTrue(cancelEffects(explicitEffects), "explicit latest cancels restoration")
        XCTAssertFalse(controller.restorationIsActive)
        XCTAssertFalse(controller.isCommandCurrent(messageCommand))
        XCTAssertEqual(controller.mode, .followingLatest)
    }

    func testRestorationDestinationReResolutionSurvivesTargetRefresh() {
        var controller = makeController(following: keyA)
        let messages = [message("m1", "one")]
        _ = controller.transcriptChanged(
            messages: messages, transcriptRevision: 1,
            viewportTransitionGeneration: 1, isInitialSync: true
        )
        guard let target = controller.targets.first else {
            return XCTFail("expected a target")
        }
        let request = snapshotRequest(anchor: target.semanticID, for: keyA)
        _ = controller.restorationRequested(request)

        // Content projection changes so the semantic anchor disappears; the
        // refreshed transcript only resolves to latest (duplicate-multiplicity
        // fallback through ChatResumeViewportResolver).
        let projected = [ChatMessage(
            id: "m1-new", role: .user, content: "different",
            timestamp: "2026-01-01T00:00:00Z"
        )]
        _ = controller.restorationTick(
            messages: projected, transcriptRevision: 2, viewportTransitionGeneration: 1,
            renderedContent: nil,
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil, isNearBottom: false
        )
        // The controller re-resolved against the refreshed targets; a
        // following tick (matching scope) scrolls to latest, not the dead
        // anchor.
        guard let currentCacheRevision = controller.renderedScrollScope?.cacheRevision else {
            return XCTFail("expected a scope")
        }
        let scope2 = ChatRenderedScrollScope(
            sessionKey: keyA,
            cacheRevision: currentCacheRevision,
            restorationGeneration: request.generation,
            transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        let effects = controller.restorationTick(
            messages: projected, transcriptRevision: 2, viewportTransitionGeneration: 1,
            renderedContent: ChatRenderedScrollContent(scope: scope2),
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil, isNearBottom: false
        )
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .bottom(anchorID: "chat-latest-p-session-a"))
    }
}

// MARK: - Streaming growth regression (Task 6)

extension ChatViewportControllerTests {

    // The ephemeral streaming bubble replacing a settled message row is a
    // rendering-identity change; a browsing viewport must not move.
    func testStreamingBubbleReplacementToSettledMessageDoesNotJumpBrowsing() {
        var controller = makeController(following: keyA)
        let original = [message("m1", "streamed answer")]
        _ = controller.transcriptChanged(
            messages: original, transcriptRevision: 1,
            viewportTransitionGeneration: 1, isInitialSync: true
        )
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        _ = controller.userDragGestureEnded()
        XCTAssertEqual(controller.mode, .browsing)
        let semanticBefore = controller.targets.first?.semanticID

        // Same content, new rendering identity (projection replacement).
        let replaced = [ChatMessage(
            id: "m1-settled",
            role: .assistant,
            content: "streamed answer",
            timestamp: "2026-01-01T00:00:00Z"
        )]
        let effects = controller.transcriptChanged(
            messages: replaced, transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(scrollCommands(effects).isEmpty, "browsing must not move")
        XCTAssertEqual(controller.targets.first?.semanticID, semanticBefore,
                       "semantic anchor survives the projection change")
    }

    // While following, a rendering-only replacement reasserts latest exactly
    // once (one animated command), and layout ticks within tolerance after
    // the reassert issue nothing further.
    func testRenderingOnlyReplacementWhileFollowingReassertsLatestExactlyOnce() {
        var controller = makeController(following: keyA)
        let original = [message("m1", "streamed answer")]
        _ = controller.transcriptChanged(
            messages: original, transcriptRevision: 1,
            viewportTransitionGeneration: 1, isInitialSync: true
        )
        let replaced = [ChatMessage(
            id: "m1-settled",
            role: .assistant,
            content: "streamed answer",
            timestamp: "2026-01-01T00:00:00Z"
        )]
        let effects = controller.transcriptChanged(
            messages: replaced, transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1, "exactly one reassert command")
        XCTAssertEqual(commands[0].animated, true)

        // Settled layout: pinned at the bottom, no drift, no further
        // commands from either layout ticks or repeated transcript syncs.
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 800,
            viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        let settled = controller.transcriptChanged(
            messages: replaced, transcriptRevision: 2,
            viewportTransitionGeneration: 1
        )
        XCTAssertTrue(scrollCommands(settled).isEmpty)
    }
}

// MARK: - Hardening pass regressions (PR #80 review round 2)

extension ChatViewportControllerTests {

    // Fix 1: a published restoration for A can be overtaken by a session
    // switch to B before the SwiftUI .task adopts it.
    func testStaleRestorationRequestAfterSessionSwitchIsRejectedImmediately() {
        var controller = makeController(following: keyB)
        let staleRequest = restoreRequest(for: keyA)

        let effects = controller.restorationRequested(staleRequest)

        // Abandoned through the existing AppState contract, immediately —
        // no 80-check wait, no adoption.
        XCTAssertEqual(effects, [.abandonRestoration(generation: staleRequest.generation)])
        XCTAssertFalse(controller.restorationIsActive)
        // B keeps normal follow-latest capability.
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertTrue(scrollCommands(effects).isEmpty)

        // The stale request can never issue a scroll afterwards: subsequent
        // ticks have no restoration state to act on, and a bottom command
        // issued for B remains current (B's follow is unimpaired).
        let followEffects = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 806,
            viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        XCTAssertEqual(scrollCommands(followEffects).count, 1)
        XCTAssertEqual(
            scrollCommands(followEffects)[0].destination,
            .bottom(anchorID: "chat-latest-p-session-b")
        )
    }

    func testFreshRestorationRequestForRenderedSessionStillAdopted() {
        var controller = makeController(following: keyA)
        _ = controller.restorationRequested(restoreRequest(for: keyA))
        XCTAssertTrue(controller.restorationIsActive)
        XCTAssertEqual(controller.mode, .restoring)
    }

    // Fix 2: abandoning a drag on view disappearance must clear the gesture
    // fact, or relatch/follow stays suppressed forever (no gesture-ended
    // event ever arrives for an abandoned gesture).
    func testViewDisappearanceDuringActiveDragDoesNotSuppressRelatchForever() {
        var controller = makeController(following: keyA)
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        XCTAssertEqual(controller.mode, .browsing)

        _ = controller.viewDisappeared()

        // Reappeared; a later geometry tick near the bottom relatches.
        let effects = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 810,
            viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertTrue(scrollCommands(effects).isEmpty, "relatch must not scroll")
    }

    // Fix 3: a layout tick cannot hand top ownership back to latest while a
    // drag is still active (title tapped mid-drag, finger never lifted).
    func testLayoutTickCannotReturnExplicitTopToLatestWhileDragging() {
        var controller = makeController(following: keyA)
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        XCTAssertEqual(controller.mode, .browsing)

        // Title tap claimed top while the finger stayed down.
        _ = controller.explicitTopRequested(request: 2)
        XCTAssertEqual(controller.mode, .explicitTop(request: 2))

        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 810,
            viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        XCTAssertEqual(
            controller.mode,
            .explicitTop(request: 2),
            "top ownership must not hand back to latest mid-drag"
        )

        // After the finger lifts (gesture invalidated by the explicit top,
        // so no completion) and a tick passes near the bottom, hand-back
        // proceeds normally.
        _ = controller.userDragGestureEnded()
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 810,
            viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        XCTAssertEqual(controller.mode, .followingLatest)
    }

    // Fix 4a: a transcript change that lands BEFORE the handoff observer
    // fires stays inert because suppression reads AppState synchronously.
    func testTranscriptChangeBeforeHandoffEventDoesNotEmitOldSessionScroll() {
        var controller = makeController(following: keyA)
        let effects = controller.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1,
            isOpeningNotificationSession: true
        )
        XCTAssertTrue(scrollCommands(effects).isEmpty)
        // Mirrors still updated (handoff path relies on fresh revisions).
        XCTAssertEqual(controller.renderedScrollScope?.transcriptRevision, 2)
    }

    // Fix 4b: the reassert anchor follows the session key supplied at event
    // time even when the controller's mirror lags the session observer.
    func testTranscriptReassertUsesCurrentSessionAnchorDespiteMirrorLag() {
        var controller = makeController(following: keyA)
        let effects = controller.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 1,
            activeSessionKey: keyB
        )
        let commands = scrollCommands(effects)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].destination, .bottom(anchorID: "chat-latest-p-session-b"))
        XCTAssertTrue(controller.isCommandCurrent(commands[0]))
    }

    // Fix 4c: profile-switch shape — mirror-only transcript sync followed by
    // the session-change event emits exactly ONE scroll, not two.
    func testProfileSwitchShapeEmitsExactlyOneLatestCommand() {
        var controller = makeController(following: keyA)
        let profileKey = ChatScrollSessionKey(profile: "other", sessionID: "session-a")

        let mirrorOnly = controller.transcriptChanged(
            messages: [message("m1", "hello")],
            transcriptRevision: 2,
            viewportTransitionGeneration: 3,
            isInitialSync: true,
            activeSessionKey: profileKey
        )
        XCTAssertTrue(scrollCommands(mirrorOnly).isEmpty)

        let switchEffects = controller.renderedSessionChanged(
            to: profileKey,
            identity: identity(for: profileKey),
            viaNotification: false,
            viewportTransitionGeneration: 3
        )
        XCTAssertEqual(scrollCommands(switchEffects).count, 1)
    }

    // Fix 5: an unloaded row stops reporting frames; the next facts event
    // must not keep it as the stable top / persisted anchor.
    func testUnloadedRowCannotRemainPersistedTopVisibleAnchor() {
        var controller = makeController(following: keyA)
        _ = controller.transcriptChanged(
            messages: [message("m1", "one"), message("m2", "two"), message("m3", "three")],
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true
        )
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)

        // All three rendered; m1 is the top stable row.
        guard let scope = controller.renderedScrollScope else {
            return XCTFail("expected a scope")
        }
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 900,
            viewportMinY: 100,
            viewportMaxY: 800,
            rowFrames: [
                ChatRenderedRowFrame(id: "m1", minY: 40, maxY: 140, scope: scope),
                ChatRenderedRowFrame(id: "m2", minY: 160, maxY: 400, scope: scope),
                ChatRenderedRowFrame(id: "m3", minY: 420, maxY: 700, scope: scope),
            ],
            scope: scope
        ))
        XCTAssertEqual(controller.stableTopMessageID, "m1")
        XCTAssertEqual(controller.renderedViewportSnapshot()?.snapshot.anchorSourceMessageID, "m1")

        // m1 scrolled far up and LazyVStack unloaded it: only m2/m3 report
        // frames this pass. The anchor must move to m2 — m1's frozen frame
        // cannot keep it pinned.
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 900,
            viewportMinY: 100,
            viewportMaxY: 800,
            rowFrames: [
                ChatRenderedRowFrame(id: "m2", minY: 120, maxY: 360, scope: scope),
                ChatRenderedRowFrame(id: "m3", minY: 380, maxY: 660, scope: scope),
            ],
            scope: scope
        ))
        XCTAssertEqual(controller.stableTopMessageID, "m2")
        XCTAssertEqual(controller.renderedViewportSnapshot()?.snapshot.anchorSourceMessageID, "m2")
    }
}

// MARK: - Viewport stress scenarios (hardening pass - deterministic, traceable)

extension ChatViewportControllerTests {

    // Helper: assert only bottom commands in effects, all current.
    private func assertOnlyCurrentBottomCommands(
        _ effects: [ChatViewportEffect],
        in controller: ChatViewportController,
        file: StaticString = #file, line: UInt = #line
    ) {
        for effect in effects {
            if case .scroll(let cmd) = effect {
                if case .bottom = cmd.destination {} else {
                    XCTFail("non-bottom command in effects: \(effect)", file: file, line: line)
                }
                XCTAssertTrue(controller.isCommandCurrent(cmd), "stale command: \(cmd)", file: file, line: line)
            }
        }
    }

    // Scenario 7: rapid A→B→C switching during active content growth.
    // No stale session A or B command may survive into C.
    func testStressRapidSwitchingKillsAllStaleCommands() {
        var controller = makeController(following: keyA)
        _ = controller.transcriptChanged(
            messages: [message("a1", "hello A")], transcriptRevision: 1,
            viewportTransitionGeneration: 1, isInitialSync: true
        )
        let keyC = ChatScrollSessionKey(profile: "p", sessionID: "session-c")

        // A→B: emits bottom for B, generation advanced.
        let ab = controller.renderedSessionChanged(
            to: keyB,
            identity: identity(for: keyB),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        guard case .scroll(let cmdAB) = ab.first(where: {
            if case .scroll = $0 { return true }; return false
        }) else { return XCTFail("expected A→B scroll") }
        XCTAssertTrue(controller.isCommandCurrent(cmdAB))
        XCTAssertEqual(cmdAB.destination, .bottom(anchorID: "chat-latest-p-session-b"))

        // B→C: all A-era and B-era commands die; only C's is current.
        let bc = controller.renderedSessionChanged(
            to: keyC,
            identity: identity(for: keyC),
            viaNotification: false,
            viewportTransitionGeneration: 3
        )
        XCTAssertFalse(controller.isCommandCurrent(cmdAB), "B-era command must be stale in C")
        guard case .scroll(let cmdBC) = bc.first(where: {
            if case .scroll = $0 { return true }; return false
        }) else { return XCTFail("expected B→C scroll") }
        XCTAssertEqual(cmdBC.destination, .bottom(anchorID: "chat-latest-p-session-c"))
        XCTAssertTrue(controller.isCommandCurrent(cmdBC))
        XCTAssertEqual(controller.renderedSessionKey, keyC)
        XCTAssertEqual(controller.mode, .followingLatest)
    }

    // Scenario 1: long continuously streaming response, untouched.
    // 120 layout ticks at 250ms-equivalent cadence (30 Hz block). Every
    // growth tick beyond tolerance emits exactly one current bottom command.
    // Generation never bumps from growth alone. No upward jump.
    func testStressLongContinuousStreamFollows() {
        var controller = makeController(following: keyA)
        let baseBottom: CGFloat = 1000
        let viewportBottom: CGFloat = 800
        var totalBottomCommands = 0

        for tick in 1...120 {
            let bottom = baseBottom + CGFloat(tick * 24)
            let effects = controller.layoutMetricsChanged(facts: layoutFacts(
                bottomMarkerMaxY: bottom,
                viewportMaxY: viewportBottom,
                scope: controller.renderedScrollScope
            ))
            assertOnlyCurrentBottomCommands(effects, in: controller)
            let commands = scrollCommands(effects)
            if !commands.isEmpty {
                totalBottomCommands += 1
                XCTAssertEqual(commands.count, 1, "tick \(tick): exactly one command")
                XCTAssertEqual(commands[0].animated, false, "follow-growth must be non-animated")
            }
            XCTAssertEqual(controller.mode, .followingLatest, "tick \(tick): must stay following")
        }
        XCTAssertTrue(totalBottomCommands > 100, "most growth ticks should produce a follow command")
    }

    // Scenario 2+3: drag up during stream → browsing (no commands); return
    // near bottom → relatch; further growth → following again.
    func testStressDragUpDuringStreamThenReturnToBottom() {
        var controller = makeController(following: keyA)
        // Fill layout facts so controller knows the viewport geometry.
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 1200, viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))

        // Drag up: deliberate user gesture.
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        XCTAssertEqual(controller.mode, .browsing)

        // Streaming continues (content grows): no command escapes.
        for tick in 1...10 {
            let effects = controller.layoutMetricsChanged(facts: layoutFacts(
                bottomMarkerMaxY: 1200 + CGFloat(tick * 24),
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            ))
            XCTAssertTrue(scrollCommands(effects).isEmpty, "tick \(tick): browsing ignores growth")
        }

        // End the drag (finger lifts).
        _ = controller.userDragGestureEnded()

        // Return near the bottom: relatch.
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 830,
            viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        XCTAssertEqual(controller.mode, .followingLatest, "relatched near bottom")

        // Resume following growth.
        let followEffects = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 880,
            viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        XCTAssertFalse(scrollCommands(followEffects).isEmpty, "growth after relatch produces follow commands")
    }

    // Scenario 4+5: title→top during stream; streaming cannot yank top-owned
    // viewport; latest button resumes following.
    func testStressTitleTopDuringStreamThenLatest() {
        var controller = makeController(following: keyA)
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 1500, viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))

        // Title → top: cancels restoration + scrolls to top.
        let topEffects = controller.explicitTopRequested(request: 7)
        XCTAssertEqual(controller.mode, .explicitTop(request: 7))
        XCTAssertTrue(cancelEffects(topEffects))
        let topCommands = scrollCommands(topEffects)
        XCTAssertEqual(topCommands.count, 1)
        XCTAssertEqual(topCommands[0].destination,
                       .top(anchorID: "chat-top-p-session-a", request: 7))
        XCTAssertEqual(topCommands[0].animated, false)

        // Streaming continues: no follow/latest command escapes.
        for tick in 1...10 {
            let effects = controller.layoutMetricsChanged(facts: layoutFacts(
                bottomMarkerMaxY: 1500 + CGFloat(tick * 20),
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            ))
            XCTAssertTrue(scrollCommands(effects).isEmpty, "tick \(tick): top-owned ignores growth")
        }

        // Latest button: forces follow-latest.
        let latestEffects = controller.explicitLatestRequested()
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertEqual(scrollCommands(latestEffects).count, 1)
        XCTAssertEqual(scrollCommands(latestEffects)[0].animated, true)
        XCTAssertTrue(controller.isCommandCurrent(scrollCommands(latestEffects)[0]))
    }

    // Scenario 6: rapid A→B→C switching during an active drag.
    // Drag lifecycle lives in controller so it follows the session; no stale
    // drag completion can fire for the wrong session.
    func testStressRapidSwitchingDuringDrag() {
        var controller = makeController(following: keyA)
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        XCTAssertEqual(controller.mode, .browsing)

        // A→B while dragging: non-equivalent key invalidates the drag
        // internally (port of the old handler's keysAreEquivalent guard).
        let keyC = ChatScrollSessionKey(profile: "p", sessionID: "session-c")
        let ab = controller.renderedSessionChanged(
            to: keyB,
            identity: identity(for: keyB),
            viaNotification: false,
            viewportTransitionGeneration: 2
        )
        XCTAssertEqual(controller.mode, .browsing, "drag continues through switch")
        XCTAssertFalse(cancelEffects(ab), "no restoration pending to cancel")

        // B→C: another non-equivalent switch; still browsing.
        let bc = controller.renderedSessionChanged(
            to: keyC,
            identity: identity(for: keyC),
            viaNotification: false,
            viewportTransitionGeneration: 3
        )
        XCTAssertEqual(controller.mode, .browsing)
        XCTAssertFalse(cancelEffects(bc))

        // End gesture near bottom: drag was invalidated by the switch, so
        // no drag completion fires — but the gesture-ended event sets
        // dragGestureActive = false, allowing geometry relatch.
        _ = controller.userDragGestureEnded()
        XCTAssertNil(controller.pendingDragEvaluation, "invalidated gesture has no evaluation")

        // Near-bottom tick: relatch to followingLatest on C.
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 810, viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        XCTAssertEqual(controller.mode, .followingLatest, "relatched on C after drag gesture ended")
        let followEffects = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 806, viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        assertOnlyCurrentBottomCommands(followEffects, in: controller)
    }

    // Scenario 8: large Markdown table/code response growth while following.
    // Height jumps of 120pt (table expansion) are within tolerance for follow.
    func testStressTableExpansionGrowthFollows() {
        var controller = makeController(following: keyA)
        let jumps: [CGFloat] = [200, 320, 440, 560, 680, 800]
        for (i, jump) in jumps.enumerated() {
            let effects = controller.layoutMetricsChanged(facts: layoutFacts(
                bottomMarkerMaxY: 800 + jump,
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            ))
            assertOnlyCurrentBottomCommands(effects, in: controller)
            let commands = scrollCommands(effects)
            XCTAssertEqual(commands.count, 1, "table jump \(i): follow command issued")
            XCTAssertEqual(commands[0].animated, false, "table follow non-animated")
        }
    }

    // Scenario 9: notification handoff while another transcript visible.
    // Destination arrives after a delay; nothing old leaks through.
    func testStressNotificationHandoffDuringActivity() {
        var controller = makeController(following: keyA)
        _ = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 1200, viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))

        // Notification arrives.
        let handoff = controller.notificationHandoffBegan(destination: keyB)
        XCTAssertEqual(controller.mode, .transitioning)
        XCTAssertTrue(cancelEffects(handoff))

        // Content growth while transitioning: inert.
        for tick in 1...5 {
            let effects = controller.layoutMetricsChanged(facts: layoutFacts(
                bottomMarkerMaxY: 1200 + CGFloat(tick * 20),
                viewportMaxY: 800,
                scope: controller.renderedScrollScope
            ))
            XCTAssertTrue(scrollCommands(effects).isEmpty, "tick \(tick): transitioning ignores growth")
        }

        // Measurement arrives.
        _ = controller.notificationHandoffLayoutMeasured()
        XCTAssertTrue(controller.notificationHandoffAwaitingLayout == false)

        // Destination ready.
        let ready = controller.notificationHandoffDestinationReady(activeKey: keyB)
        XCTAssertEqual(controller.mode, .followingLatest)
        XCTAssertEqual(scrollCommands(ready).count, 1)
        XCTAssertEqual(scrollCommands(ready)[0].destination, .bottom(anchorID: "chat-latest-p-session-b"))

        // Post-handoff growth follows B normally.
        let postEffects = controller.layoutMetricsChanged(facts: layoutFacts(
            bottomMarkerMaxY: 806,
            viewportMaxY: 800,
            scope: controller.renderedScrollScope
        ))
        assertOnlyCurrentBottomCommands(postEffects, in: controller)
    }

    // Scenario 10 + invariant: every mode transition always maintains
    // exactly one current generation — no two commands from different
    // generations can both validate.
    func testStressInvariantSingleCurrentGeneration() {
        var controller = makeController(following: keyA)
        var allCommands: [ChatViewportCommand] = []

        // Collect commands from a realistic scenario sequence.
        allCommands += scrollCommands(controller.layoutMetricsChanged(
            facts: layoutFacts(bottomMarkerMaxY: 806, viewportMaxY: 800,
                              scope: controller.renderedScrollScope)))
        allCommands += scrollCommands(controller.explicitTopRequested(request: 1))
        allCommands += scrollCommands(controller.explicitLatestRequested())
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        allCommands += scrollCommands(controller.explicitLatestRequested())
        _ = controller.renderedSessionChanged(
            to: keyB, identity: identity(for: keyB),
            viaNotification: false, viewportTransitionGeneration: 2)
        allCommands += scrollCommands(controller.explicitLatestRequested())

        // Exactly one command from the latest batch should be current.
        let currentCount = allCommands.filter { controller.isCommandCurrent($0) }.count
        XCTAssertEqual(currentCount, 1, "exactly one command must be current at any time")

        // Verify no stale command has the current generation.
        let generation = controller.generation
        for cmd in allCommands where cmd.generation != generation {
            XCTAssertFalse(controller.isCommandCurrent(cmd),
                           "command gen \(cmd.generation) must be stale (current: \(generation))")
        }
    }
}

// MARK: - Restoration session equivalence (identity contract consistency)

extension ChatViewportControllerTests {

    // The stored alias is the rendered key; the request carries the runtime
    // alias. identity.areEquivalent says they match. Admission must pass,
    // the scope gate must accept, and restoration must complete normally.
    func testRestorationAcceptsEquivalentRuntimeAliasAndCompletesNormally() {
        let storedKey = ChatScrollSessionKey(profile: "p", sessionID: "stored-a")
        let runtimeKey = ChatScrollSessionKey(profile: "p", sessionID: "runtime-a")
        let aliasIdentity = aliasedIdentity(storedKey, runtimeKey)

        // Controller rendered under stored-a.
        var controller = ChatViewportController()
        _ = controller.renderedSessionChanged(
            to: storedKey,
            identity: aliasIdentity,
            viaNotification: false,
            viewportTransitionGeneration: 1
        )
        let messages = [message("m1", "one")]
        _ = controller.transcriptChanged(
            messages: messages, transcriptRevision: 1,
            viewportTransitionGeneration: 1, isInitialSync: true
        )
        guard let target = controller.targets.first else {
            return XCTFail("expected a target")
        }

        // Request published under runtime-a (the equivalent alias).
        let request = ChatResumeRestorationRequest(
            generation: 42,
            sessionKey: runtimeKey,
            destination: .snapshot(ChatScrollSnapshot(
                anchorMessageID: target.semanticID,
                followsLatest: false,
                anchorMetadata: target.restorationMetadata,
                anchorSourceMessageID: "m1"
            ))
        )
        let adoptEffects = controller.restorationRequested(request)
        XCTAssertTrue(controller.restorationIsActive, "request adopted")
        XCTAssertEqual(controller.mode, .restoring)
        XCTAssertFalse(adoptEffects.contains(.abandonRestoration(generation: 42)))

        // Matching-scope tick: rendered scope is under stored-a, request
        // is runtime-a — equivalence makes the scope gate pass.
        guard let scope = controller.renderedScrollScope else {
            return XCTFail("expected a rendered scope")
        }
        let content = ChatRenderedScrollContent(scope: scope)
        let scrollTick = controller.restorationTick(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil,
            isNearBottom: false
        )
        let commands = scrollCommands(scrollTick)
        XCTAssertEqual(commands.count, 1, "equivalence must let the scope gate pass")
        XCTAssertEqual(commands[0].destination, .message(id: target.id))

        // Install the target and confirm: restoration completes normally.
        var installed = ChatRenderedScrollTargets()
        ChatRenderedScrollTargets.reduce(
            value: &installed,
            nextValue: ChatRenderedScrollTargets.row(semanticID: target.id, scope: scope)
        )
        let completeTick = controller.restorationTick(
            messages: messages, transcriptRevision: 1, viewportTransitionGeneration: 1,
            renderedContent: content,
            installedTargets: installed,
            topVisibleID: target.id, isNearBottom: false
        )
        XCTAssertEqual(completeTick, [.completeRestoration(generation: 42)])
        XCTAssertFalse(controller.restorationIsActive)
        XCTAssertEqual(controller.mode, .browsing,
                       "non-latest snapshot completion stays browsing")
    }

    // The inverse: rendered key and request key are NOT equivalent.
    // Admission must reject immediately; restoration cannot adopt or scroll.
    func testRestorationRejectsNonEquivalentKeyImmediately() {
        let storedB = ChatScrollSessionKey(profile: "p", sessionID: "stored-b")
        let runtimeA = ChatScrollSessionKey(profile: "p", sessionID: "runtime-a")

        // Controller rendered under stored-b with identity that only knows
        // stored-b (no alias overlap with runtime-a).
        var controller = ChatViewportController()
        _ = controller.renderedSessionChanged(
            to: storedB,
            identity: identity(for: storedB),
            viaNotification: false,
            viewportTransitionGeneration: 1
        )

        // Request published under runtime-a — not equivalent to stored-b.
        let request = ChatResumeRestorationRequest(
            generation: 99,
            sessionKey: runtimeA,
            destination: .latest
        )
        let effects = controller.restorationRequested(request)

        XCTAssertEqual(effects, [.abandonRestoration(generation: 99)])
        XCTAssertFalse(controller.restorationIsActive)
        XCTAssertEqual(controller.mode, .followingLatest,
                       "non-equivalent rejection must not change mode")

        // A subsequent tick must not issue any scroll — no restoration state.
        guard let scope = controller.renderedScrollScope else {
            return XCTFail("expected a rendered scope")
        }
        let tickEffects = controller.restorationTick(
            messages: [], transcriptRevision: 0, viewportTransitionGeneration: 1,
            renderedContent: ChatRenderedScrollContent(scope: scope),
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil, isNearBottom: false
        )
        XCTAssertTrue(tickEffects.isEmpty,
                      "no restoration state means the tick is a no-op")
    }

    // MARK: - Duplicate transcript-change regression

    func testSingleTranscriptMutationCausesOneTranscriptChangedCall() {
        var controller = makeController(following: keyA)
        let msgs = [message("m1", "hello")]

        TranscriptPerf.reset()
        _ = controller.transcriptChanged(
            messages: msgs,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1
        )
        XCTAssertEqual(TranscriptPerf.transcriptChangedCalls, 1,
                       "one mutation must cause exactly one transcriptChanged call")
    }

    func testDuplicateTranscriptChangedIsIdempotent() {
        var controller = makeController(following: keyA)
        let msgs = [message("m1", "hello")]

        // First call: semantic change
        let first = controller.transcriptChanged(
            messages: msgs,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1
        )
        // Second call with identical messages: should be .unchanged
        let second = controller.transcriptChanged(
            messages: msgs,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1
        )
        XCTAssertNotEqual(first, [], "first call should produce effects")
        XCTAssertEqual(second, [], "duplicate call with same messages must be no-op")
    }
}
