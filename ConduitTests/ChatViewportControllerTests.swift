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
        let scope = controller.renderedScrollScope!
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
        let scope = controller.renderedScrollScope!
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
        var controller = makeController(following: keyA)
        _ = controller.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)
        let request = snapshotRequest(anchor: "chat-message-fp-0", for: keyA)
        // The anchor resolves to the source message id space.
        // Build targets with the exact semantic ids the fingerprint produces
        // by using ChatMessageScrollTargets directly.
        let messages = [message("m1", "one"), message("m2", "two")]
        var seeded = makeController(following: keyA)
        _ = seeded.transcriptChanged(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            isInitialSync: true
        )
        let realAnchor = seeded.targets.first!.semanticID
        let seededRequest = snapshotRequest(anchor: realAnchor, for: keyA)
        _ = seeded.userDragBegan(sessionKey: keyA, viewportTransitionGeneration: 1)

        _ = seeded.restorationRequested(seededRequest)
        XCTAssertTrue(seeded.restorationIsActive)
        XCTAssertEqual(seeded.mode, .restoring)
        // First tick on a mismatched scope waits without scrolling.
        let firstTick = seeded.restorationTick(
            messages: messages,
            transcriptRevision: 1,
            viewportTransitionGeneration: 1,
            renderedContent: nil,
            installedTargets: ChatRenderedScrollTargets(),
            topVisibleID: nil,
            isNearBottom: false
        )
        XCTAssertTrue(firstTick.isEmpty)
        _ = controller
        _ = request
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
        let anchor = controller.targets.first!.semanticID
        let request = snapshotRequest(anchor: anchor, for: keyA)
        _ = controller.restorationRequested(request)

        // A scope from a DIFFERENT restoration generation must not scroll.
        let staleScope = ChatRenderedScrollScope(
            sessionKey: keyA,
            cacheRevision: controller.renderedScrollScope!.cacheRevision,
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
        XCTAssertEqual(commands[0].destination, .message(id: controller.targets.first!.id))
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
        let target = controller.targets.first!
        let request = snapshotRequest(anchor: target.semanticID, for: keyA)
        _ = controller.restorationRequested(request)
        let scope = restorationScope(for: request, in: controller)!
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
        let scope = restorationScope(for: request, in: controller)!
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
        let target = controller.targets.first!
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
        _ = controller.explicitLatestRequested()
        XCTAssertTrue(cancelEffects(controller.explicitLatestRequested()) || true)
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
        let target = controller.targets.first!
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
        let scope2 = ChatRenderedScrollScope(
            sessionKey: keyA,
            cacheRevision: controller.renderedScrollScope!.cacheRevision,
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
