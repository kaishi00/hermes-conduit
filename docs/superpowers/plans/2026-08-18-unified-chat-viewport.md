# Unified Chat Viewport Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the chat viewport's overlapping scroll-control paths with one pure state machine (`ChatViewportController`) plus one `ScrollViewProxy.scrollTo` execution boundary in `ChatView`.

**Architecture:** A pure, deterministic `ChatViewportController` struct owns viewport mode, a single ownership generation, drag lifecycle, notification-handoff state, and restoration progress. `ChatView` feeds it events (session changes, layout facts, drags, explicit commands, restoration requests) and executes the returned effects through a single `performViewportEffect` function — the only place that touches `ScrollViewProxy`. Stable-row observation replaces the writable `.scrollPosition` binding; rendered-layout growth (not `streamingText` deltas) drives follow-latest.

**Tech Stack:** Swift 5.9, SwiftUI (iOS 17 deployment target), XCTest. Project generated with xcodegen (`xcodegen generate`).

**Spec:** The full rewrite spec (pasted 2026-08-18) is appended verbatim at the bottom of this plan as **Appendix A**. The plan argues from the spec; executors read both. Non-negotiable scope boundaries in the spec's "Global Constraints" below apply to every task.

## Global Constraints (from the spec — apply to every task)

- One PR from current main (`unified-chat-viewport` branch off `origin/main` @ 9a06e33), incremental commits, no stacked/merged intermediate versions.
- Do NOT modify: HermesClient/WebSocket lifecycle/reconnection, DashboardTicketBridge, dashboard ticket/reload/recovery state machines, reconnect scheduling or scene-gated recovery, ConnectionURLPolicy, notification runtime-ID→stored-ID routing, PushNotificationService, StreamingText reveal pacing, Markdown parsing/render caching/table layout, SelectableTextView / MarkdownSelectionCoordinator, composer behavior.
- AppState.swift changes restricted to viewport-facing adapter/plumbing. Preserve `.automaticReturn` (may honor user Continue/Latest preference) vs `.preserveCurrent` (must preserve current conversation). A reconnect must never navigate to the newest conversation.
- Do not change the persisted ChatResumeStore schema. Existing saved positions and preferences must survive.
- Existing tests initially remain unchanged. When an old implementation-specific test becomes obsolete, replace with an equivalent-or-stronger controller test and document the old→new mapping in the PR description.
- No new global gesture recognizer or touch-consuming overlay; preserve gesture fixes from PRs #58/#63 (table/code horizontal scrolling, native + cross-block selection).
- No "cleaned up while here" changes to connection/reconnection code.
- All delayed scroll commands carry and validate a controller-issued token (generation + session scope). No naked delayed scroll tasks in the final state.
- Ephemeral `"streaming"`/`"typing"`/top-marker/bottom-marker IDs must never become persisted viewport anchors.

## Repository facts an executor needs

- Worktree: `/Users/agrias/Documents/Conduit/.worktrees/unified-chat-viewport`, branch `unified-chat-viewport`. All paths below are relative to the worktree root.
- Generate the Xcode project after adding/removing files: `xcodegen generate` (repo has no checked-in .xcodeproj).
- Build/test commands (isolated derived data; iPhone 17 sim UDID `124B405C-07CF-44F4-A024-9AD87B9992B0` is already booted; if it wedges, reboot via `xcrun simctl shutdown/boot`):
  ```bash
  xcodebuild build-for-testing -project Conduit.xcodeproj -scheme Conduit \
    -destination 'platform=iOS Simulator,id=124B405C-07CF-44F4-A024-9AD87B9992B0' \
    -derivedDataPath .dd 2>&1 | tail -3

  xcodebuild test-without-building -project Conduit.xcodeproj -scheme Conduit \
    -destination 'platform=iOS Simulator,id=124B405C-07CF-44F4-A024-9AD87B9992B0' \
    -derivedDataPath .dd \
    -only-testing:ConduitTests/<SuiteName> 2>&1 | grep -E "Test Suite|Executed|failed" | tail -10
  ```
- Focused suites that must stay green (baseline verified green on this branch): `ChatScrollStateTests` (47), `ChatResumeCoordinatorTests`, `ChatResumePolicyTests`, `ChatResumeStoreTests`, `ChatTitleScrollTests` (7), `AppStateChatResumeTests` (82). Selection/table suites (`ChatTextSelectionTests`, `MarkdownSelectionCoordinatorTests`, `MarkdownTableLayoutTests`) must stay green once Tasks 2 and 8 are done.
- Key existing types (do not rewrite semantics, only relocate/fold):
  - `ChatScrollState.swift`: `ChatMessageScrollTarget/Cache`, `ChatRenderedScrollScope/Content/Targets`, `ChatDragCompletionToken`, `ChatDragLifecycleState`, `ChatFollowLatestRelatchPolicy`, `ChatResumeRenderRestorationState`, `ChatScrollSessionKey/Identity/Resolver`, `ChatScrollSnapshot`, `ChatRenderedViewportSnapshot`, `ChatSessionPersistenceIdentity`, `ChatScrollTargetAvailability`.
  - `ChatView.swift` (bottom, lines ~837–1015): `ChatTitleScrollAnchor`, `ChatScrollOwner/OwnerToken/OwnerState`, `ChatHandoffCompletionAction`, `ChatTitleScrollViewportSnapshot`, preference keys.
  - `ChatResumeCoordinator.swift`: freeze/restore generations (untouched).
  - `AppState.swift`: adapter surface at lines 1024–1170 (`installChatViewportSnapshotProvider`, `beginExplicitChatViewportTransition`, `chatViewportLayoutDidSettle`, `completeChatResumeRestoration`, `abandonChatResumeRestoration`, `recordChatViewport`, `flushChatResumeViewport`, `cancelChatResumeRestoration`), published viewport state at lines 364–388.
- Current scroll-control call sites in ChatView (the "scatter" this rewrite deletes): `.onChange(of: appState.messages)` (:265), `.onChange(of: chatScrollRequest)` (:307), `.onChange(of: chatScrollToTopRequest)` (:313), `.onChange(of: activeSessionId)` (:319), `.onChange(of: activeProfile)` (:358), `.onChange(of: streamingText)` (:417), `.onChange(of: isBusy)` (:422), `scrollToLatest` + retry Task (:694), `scrollToTop` + retry Task (:720), `applyChatResumeRestoration` loop (:561), `finishNotificationHandoffIfReady` (:758), latest-button overlay (:428). Plus the writable `.scrollPosition(id: $topVisibleChatID)` (:176).

---

## Task 0 (Phase 0): Characterize current behavior — trace + analysis + characterization tests

**Files:**
- Create: `Conduit/Services/ChatViewportTrace.swift`
- Create: `ConduitTests/ChatViewportCharacterizationTests.swift`
- Create: `docs/viewport-rewrite-analysis.md`

**Interfaces:**
- Produces: `ChatViewportTrace.shared` (`@MainActor`, DEBUG-only) with `log(_:)` / `dump() -> String`; usable by every later task's ChatView wiring.

- [ ] **Step 1: Write the DEBUG-only trace recorder**

```swift
// Conduit/Services/ChatViewportTrace.swift
import Foundation
import os

#if DEBUG
/// Ring-buffer recorder for viewport decisions. ChatView logs every event
/// sent to ChatViewportController and every effect executed; the dump is the
/// Phase-0/Phase-8 evidence trail for "never more than one current scroll
/// owner/command generation".
@MainActor
final class ChatViewportTrace {
    struct Entry: Equatable {
        let time: CFAbsoluteTime
        let text: String
    }

    static let shared = ChatViewportTrace()

    private(set) var entries: [Entry] = []
    private let limit = 600
    private let logger = Logger(subsystem: "com.milim.relay", category: "viewport")

    func log(_ text: String) {
        entries.append(Entry(time: CFAbsoluteTimeGetCurrent(), text: text))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        logger.debug("\(text, privacy: .public)")
    }

    func dump() -> String {
        entries.map { String(format: "%.3f %@", $0.time, $1) }.joined(separator: "\n")
    }

    func reset() { entries.removeAll() }
}
#endif
```

- [ ] **Step 2: Wire trace logging into the CURRENT ChatView** at each existing decision point (temporary; some lines are deleted in later tasks — keep the logging with the code as it moves): `beginChatDragIfNeeded`, `completeChatDrag`, `relatchFollowsLatestIfSettled`, `scrollToLatest` (+retry), `scrollToTop` (+retry), `applyChatResumeRestoration` (scroll/complete/abandon), `finishNotificationHandoffIfReady`, both `onChange(of: streamingText)` and `onChange(of: isBusy)` scroll branches, and the messages reassert branch. Log: mode facts (`followsLatest`, `topVisibleChatID`, `hasPendingRestoration`, `notificationHandoffPending`), session keys (`renderedScrollSessionKey`, `activeScrollSessionKey`), geometry (`bottomMarkerMaxY`, `scrollViewportMaxY`), generations (`appState.chatViewportTransitionGeneration`, `scrollOwnerState.generation`, drag generation), and every requested scroll with reason + destination. No behavior change — logging only.

- [ ] **Step 3: Write the characterization tests** that pin today's *composed* policy decisions for the spec's Phase-0 scenarios. These are logic-level (no view rendering); they drive the existing pure policies in the same order ChatView's onChange cascade does. They are intentionally implementation-coupled and will be rewritten against the controller in Task 7 (mapping documented in the PR).

```swift
// ConduitTests/ChatViewportCharacterizationTests.swift
import XCTest
@testable import Conduit

/// Phase-0 characterization of the CURRENT viewport decision pipeline.
/// Each test documents the composed decision for one spec repro scenario.
/// These are expected to be REPLACED by ChatViewportControllerTests in the
/// rewrite (see plan Task 7) — they exist to capture today's behavior first.
final class ChatViewportCharacterizationTests: XCTestCase {

    private func assistant(_ id: String, _ content: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: content)
    }

    // Scenario: long growing response, untouched. Today every streamingText
    // delta issues an unconditional bottom scroll while following.
    func testCharacterizeStreamingDeltaFollowWhileFollowing() {
        var followsLatest = true
        let hasPendingRestoration = false
        // mirrors ChatView.onChange(of: streamingText)
        func streamingDelta() -> Bool {
            followsLatest && !hasPendingRestoration // -> proxy.scrollTo(bottom)
        }
        for _ in 0..<30 { XCTAssertTrue(streamingDelta()) }
        followsLatest = false
        XCTAssertFalse(streamingDelta())
    }

    // Scenario: drag upward during stream. Deliberate drag disables follow
    // immediately; geometry ticks while finger-down must not re-latch.
    func testCharacterizeDragDuringStreamDisablesFollowAndGeometryCannotRelatch() {
        var followsLatest = false
        let isDragging = true
        let isNearBottom = false
        // mirrors relatchFollowsLatestIfSettled() on a layout tick
        let relatch = ChatFollowLatestRelatchPolicy.shouldRelatch(
            isNearBottom: isNearBottom,
            hasPendingRestoration: false,
            hasNotificationHandoff: false,
            isDragging: isDragging
        )
        XCTAssertFalse(relatch)
        XCTAssertTrue(followsLatest == false)
        // even if the finger ends far from bottom, no relatch
        XCTAssertFalse(ChatFollowLatestRelatchPolicy.shouldRelatch(
            isNearBottom: false, hasPendingRestoration: false,
            hasNotificationHandoff: false, isDragging: false))
    }

    // Scenario: transcript-size change during an active drag must not
    // re-enable follow (already pinned by ChatScrollStateTests — reference it
    // here so the ledger scenario list is complete in one file).
    func testCharacterizeTranscriptTransitionKeepsFollowDisabledForActiveDrag() {
        XCTAssertFalse(ChatFollowLatestRelatchPolicy.shouldFollowLatestAfterTransition(isDragging: true))
    }

    // Scenario: messages change while following (no restoration/handoff)
    // reasserts latest — today via claimLatest + animated scroll + 150ms retry.
    func testCharacterizeMessageChangeReassertsLatestOnlyWhenFollowing() {
        let update: ChatMessageScrollTargetCacheUpdate = .renderingChanged
        XCTAssertTrue(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update, followsLatest: true,
            hasPendingRestoration: false, hasNotificationHandoff: false))
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update, followsLatest: false,
            hasPendingRestoration: false, hasNotificationHandoff: false))
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: .unchanged, followsLatest: true,
            hasPendingRestoration: false, hasNotificationHandoff: false))
    }

    // Scenario: rendering-only message-ID replacement while following
    // reasserts latest; while browsing it must not move the viewport.
    func testCharacterizeRenderingOnlyReplacementRespectsBrowsing() {
        var cache = ChatMessageScrollTargetCache()
        cache.update(for: [assistant("a", "hello")])
        let rotated = [ChatMessage(id: "a2", role: .assistant, content: "hello")]
        let update = cache.update(for: rotated)
        XCTAssertEqual(update, .renderingChanged)
        // browsing: reassert policy says no
        XCTAssertFalse(ChatMessageScrollUpdatePolicy.shouldReassertLatest(
            after: update, followsLatest: false,
            hasPendingRestoration: false, hasNotificationHandoff: false))
    }

    // Scenario: title-to-top during stream. Explicit top claims ownership;
    // streamed deltas must not yank back while top owner is active.
    // DOCUMENTED GAP: the "top owner suppresses geometry relatch away from
    // bottom" guard lives in the view (relatchFollowsLatestIfSettled), NOT in
    // any pure policy — which is exactly the bug class this rewrite fixes.
    // The controller tests testLayoutTickNearBottomWhileBrowsingRelatchesWithoutScrolling
    // and testLayoutTickNearBottomReturnsExplicitTopToFollowingLatest close
    // this gap; this characterization pins only what is pure today.
    func testCharacterizeTitleTopOwnerSurvivesUntilNearBottomOrNewerClaim() {
        var owner = ChatScrollOwnerState()
        let request = 3
        _ = owner.claimTop(request: request)
        XCTAssertTrue(owner.hasActiveTopOwner(currentRequest: request))
        // a newer top request supersedes the old owner's retry
        _ = owner.claimTop(request: 4)
        XCTAssertFalse(owner.hasActiveTopOwner(currentRequest: request))
        XCTAssertTrue(owner.hasActiveTopOwner(currentRequest: 4))
        // relatch near the bottom is allowed by the pure policy...
        XCTAssertTrue(ChatFollowLatestRelatchPolicy.shouldRelatch(
            isNearBottom: true, hasPendingRestoration: false,
            hasNotificationHandoff: false, isDragging: false))
        // ...but the view's top-owner branch requires near-bottom first and
        // then claims latest — untestable here (see gap note above).
        _ = owner.claimLatest()
        XCTAssertFalse(owner.hasActiveTopOwner(currentRequest: 4))
    }

    // Scenario: notification handoff completion picks top owner if claimed
    // during handoff, else latest-if-following, else none.
    func testCharacterizeHandoffCompletionActions() {
        var owner = ChatScrollOwnerState()
        XCTAssertEqual(
            owner.handoffCompletionAction(currentTopRequest: 0, currentTopAnchor: "t", shouldFollowLatest: true),
            .latest)
        XCTAssertEqual(
            owner.handoffCompletionAction(currentTopRequest: 0, currentTopAnchor: "t", shouldFollowLatest: false),
            .none)
        _ = owner.claimTop(request: 5)
        XCTAssertEqual(
            owner.handoffCompletionAction(currentTopRequest: 5, currentTopAnchor: "chat-top-p-s", shouldFollowLatest: false),
            .top(anchorID: "chat-top-p-s"))
    }

    // Scenario: streaming completion (isBusy false) scrolls only while
    // following and not restoring. The condition lives inline in the view's
    // onChange — characterize its truth table directly.
    func testCharacterizeBusyEndScrollConditionTruthTable() {
        func scrolls(followsLatest: Bool, hasPendingRestoration: Bool) -> Bool {
            followsLatest && !hasPendingRestoration
        }
        XCTAssertTrue(scrolls(followsLatest: true, hasPendingRestoration: false))
        XCTAssertFalse(scrolls(followsLatest: false, hasPendingRestoration: false))
        XCTAssertFalse(scrolls(followsLatest: true, hasPendingRestoration: true))
        XCTAssertFalse(scrolls(followsLatest: false, hasPendingRestoration: true))
    }

    // Scenario: session switch adopts follow-latest unless dragging
    // (ChatFollowLatestRelatchPolicy.shouldFollowLatestAfterTransition).
    func testCharacterizeSessionSwitchFollowDecision() {
        XCTAssertTrue(ChatFollowLatestRelatchPolicy.shouldFollowLatestAfterTransition(isDragging: false))
        XCTAssertFalse(ChatFollowLatestRelatchPolicy.shouldFollowLatestAfterTransition(isDragging: true))
    }
}
```

  NOTE for the executor: two of the scenarios above hit the documented gap — the top-owner guard lives in view code (`relatchFollowsLatestIfSettled`), not in a pure policy, which is exactly the class of bug this rewrite fixes. Keep those tests' comments; the controller tests in Task 1 close the gap.

- [ ] **Step 4: Write `docs/viewport-rewrite-analysis.md`** — the behavior ledger + failure analysis. Structure: (1) inventory of every current control path (the call-site list above with line numbers and what each guards on); (2) the overlapping-authority problems (`.scrollPosition` vs `ScrollViewReader`; `scrollOwnerState` vs `followsLatest` vs drag lifecycle vs handoff booleans; network-delta-driven streaming scroll vs reveal pacing); (3) the eleven preserved-behavior groups from the spec mapped to the existing tests that pin them (use the behavior-ledger summary: ChatScrollStateTests rows for drag/relatch/restoration/identity; ChatResumeCoordinatorTests for freeze/selection; ChatResumePolicyTests for preference semantics; AppStateChatResumeTests for transitions/stale exclusion; ChatTitleScrollTests for top owner/handoff/synthetic-anchor persistence); (4) scenario → where covered table for the spec's Phase-0 repro list.

- [ ] **Step 5: Build + run characterization suite**

Run: `xcodegen generate` then build-for-testing, then `-only-testing:ConduitTests/ChatViewportCharacterizationTests`.
Expected: PASS (all new tests pin current behavior).

- [ ] **Step 6: Commit**

```bash
git add Conduit/Services/ChatViewportTrace.swift ConduitTests/ChatViewportCharacterizationTests.swift Conduit/Views/ChatView.swift docs/viewport-rewrite-analysis.md project.yml 2>/dev/null || git add Conduit/Services/ChatViewportTrace.swift ConduitTests/ChatViewportCharacterizationTests.swift Conduit/Views/ChatView.swift docs/viewport-rewrite-analysis.md
git commit -m "viewport: add Phase-0 trace instrumentation and behavior characterization"
```

---

## Task 1 (Phase 1): `ChatViewportController` — core state machine, tests first

**Files:**
- Create: `Conduit/Services/ChatViewportController.swift`
- Create: `ConduitTests/ChatViewportControllerTests.swift`

**Interfaces:**
- Consumes: `ChatScrollSessionKey/Identity`, `ChatMessageScrollTarget/Cache` + `ChatMessageScrollTargetCacheUpdate`, `ChatRenderedScrollScope/Content/Targets`, `ChatResumeRestorationRequest`, `ChatResumeViewportResolver` + `ChatScrollTargetAvailability`, `ChatScrollSnapshot`, `ChatRenderedViewportSnapshot` (all existing).
- Produces (used by Tasks 3–7):
  - `struct ChatViewportController: Equatable` with `private(set) var mode: ChatViewportMode`, `private(set) var generation: UInt64`, plus the event methods and accessors listed below.
  - `enum ChatViewportMode: Equatable { case followingLatest, browsing, restoring, explicitTop(request: Int), transitioning }`
  - `struct ChatViewportCommand: Equatable` — `{ generation: UInt64, sessionKey: ChatScrollSessionKey?, destination: Destination, animated: Bool, retry: Retry? }`, `enum Destination { case bottom(anchorID: String), top(anchorID: String, request: Int), message(id: String) }`, `enum Retry { case delayed(milliseconds: Int) }`.
  - `enum ChatViewportEffect: Equatable` — `scroll(ChatViewportCommand)`, `cancelAutomaticRestoration`, `persistViewportSnapshot(for: ChatScrollSessionKey?)`, `flushViewportPersistence`, `completeRestoration(generation: UInt64)`, `abandonRestoration(generation: UInt64)`, `scheduleDragEvaluation(ChatDragCompletionToken)`.
  - Event methods (all `mutating`, all return `[ChatViewportEffect]`): `renderedSessionChanged(to:identity:viaNotification:)`, `activeIdentityRefreshed(identity:key:)`, `transcriptChanged(messages:transcriptRevision:)`, `layoutMetricsChanged(facts:)`, `userDragBegan(sessionKey:viewportTransitionGeneration:)`, `userDragGestureEnded()`, `evaluateDragCompletion(ChatDragCompletionToken)`, `invalidateDrag(hasActiveGesture:)`, `abandonDrag()`, `explicitLatestRequested()`, `explicitTopRequested(request:)`, `restorationRequested(ChatResumeRestorationRequest)`, `restorationSystemCancelled()`, `restorationTick(...)` (Task 5 fills its logic; Task 1 ships the mode/generation core), `notificationHandoffBegan(destination:)`, `notificationHandoffLayoutMeasured()`, `notificationHandoffDestinationReady()`, `viewDisappeared()`.
  - Accessors: `var isFollowingLatest: Bool`, `var isNearBottom: Bool`, `var stableTopMessageID: String?`, `var renderedSessionKey: ChatScrollSessionKey?`, `var renderedScrollScope: ChatRenderedScrollScope?`, `var targets: [ChatMessageScrollTarget]`, `var pendingDragEvaluation: ChatDragCompletionToken?`, `func isCommandCurrent(_ command: ChatViewportCommand) -> Bool`, `func renderedViewportSnapshot(pendingRestorationGeneration: UInt64?) -> ChatRenderedViewportSnapshot?`.
  - `struct ChatViewportLayoutFacts: Equatable { var bottomMarkerMaxY: CGFloat?; var viewportMinY: CGFloat?; var viewportMaxY: CGFloat?; var rowFrames: [ChatRenderedRowFrame]; var renderedScope: ChatRenderedScrollScope? }` — `ChatRenderedRowFrame` is added in Task 2; until then declare `rowFrames` as `[ChatRenderedRowFrame]` with Task 2 providing the type in ChatScrollState.swift (Task 1 may compile with the type already added — see Task 2 Step 1; simplest: implement Task 2's `ChatRenderedRowFrame` + `ChatRenderedScrollTargets` frame extension FIRST inside Task 1 as a shared Step 0 so both tasks compile).

- [ ] **Step 0: Add the `ChatRenderedRowFrame` support type first** (Task 2 needs it in ChatScrollState.swift, the controller needs it now):

```swift
// Append to Conduit/Services/ChatScrollState.swift

/// Global-space frame of one rendered stable message row, scoped to the
/// rendered scroll scope that produced it. Only rows SwiftUI actually laid
/// out report frames; this is how the controller learns which stable row
/// intersects the viewport without .scrollPosition.
struct ChatRenderedRowFrame: Equatable {
    let id: String        // ChatMessageScrollTarget.id == message.id
    let minY: CGFloat
    let maxY: CGFloat
    let scope: ChatRenderedScrollScope
}
```

  Extend `ChatRenderedScrollTargets` with frame storage (additive; `contains` semantics untouched):

```swift
// Inside ChatRenderedScrollTargets (extend the existing struct):
    private(set) var framesByScope: [ChatRenderedScrollScope: [String: CGRect]] = [:]

    static func row(
        semanticID: String,
        scope: ChatRenderedScrollScope,
        frame: CGRect? = nil
    ) -> ChatRenderedScrollTargets {
        var targets = ChatRenderedScrollTargets(rowsByScope: [scope: [semanticID]])
        if let frame {
            targets.framesByScope = [scope: [semanticID: frame]]
        }
        return targets
    }

    // reduce(_:): additionally merge framesByScope the same way rowsByScope
    // merges, and retainLatestScopes(from:) prunes framesByScope too.

    /// Global frames of rendered stable rows for a scope (rows that reported
    /// geometry this pass; offscreen lazy rows are absent).
    func rowFrames(in scope: ChatRenderedScrollScope) -> [String: CGRect] {
        framesByScope[scope] ?? [:]
    }
```

  (Update the existing `reduce` and `retainLatestScopes` bodies to include `framesByScope` mirroring the `rowsByScope` treatment — merge with `formUnion`-style dictionary merge per key, then prune. Existing ChatScrollStateTests must stay green: `ChatRenderedScrollTargets` gains a field, so its memberwise-ish usage compiles because tests only use `row(_:scope:)`/`bottom(_:scope:)`/`contains`.)

- [ ] **Step 1: Write the failing controller tests.** Encode the behavior ledger as pure state-machine tests. Minimum required test set (names must exist; each asserts observable `mode`/`generation`/effects, never private counters):

Core ownership & generation:
```swift
final class ChatViewportControllerTests: XCTestCase {
    private func makeIdentity(_ key: ChatScrollSessionKey?) -> ChatScrollSessionIdentity {
        ChatScrollSessionIdentity(
            profile: key?.profile, canonicalSessionID: key?.sessionID,
            equivalentSessionIDs: key.map { [$0.sessionID] } ?? [],
            isReconciling: false, settledRevision: 0)
    }

    private func controller(
        following key: ChatScrollSessionKey?
    ) -> ChatViewportController {
        var c = ChatViewportController()
        _ = c.renderedSessionChanged(to: key, identity: makeIdentity(key), viaNotification: false)
        return c
    }

    func testInitialModeFollowsLatestAndFirstSessionAdoptionDoesNotScroll() {
        var c = ChatViewportController()
        XCTAssertEqual(c.mode, .followingLatest)
        let key = ChatScrollSessionKey(profile: "p", sessionID: "s1")
        let effects = c.renderedSessionChanged(to: key, identity: makeIdentity(key), viaNotification: false)
        // adopting the first session key is not a conversation switch
        XCTAssertTrue(effects.isEmpty, "first adoption must not scroll: \(effects)")
        XCTAssertEqual(c.renderedSessionKey, key)
    }
```
  plus these tests (write real bodies for each; assertions target `mode`, `effects`, `isCommandCurrent`):
  - `testExplicitLatestClaimsFollowingLatestCancelsRestorationAndScrollsAnimated` — from `.browsing` with a pending restoration request installed via `restorationRequested`, `explicitLatestRequested()` returns `[.cancelAutomaticRestoration, .scroll(command animated: true, retry .delayed(150))]`-shaped effects (exact ordering flexible; assert kinds + animated flag), mode becomes `.followingLatest`, generation advanced.
  - `testExplicitTopClaimsTopOwnershipNonAnimated` — `explicitTopRequested(request: 3)` → mode `.explicitTop(request: 3)`, one `.scroll` with `destination == .top(anchorID: ChatTitleScrollAnchor.id(for: key), request: 3)`, `animated == false`, retry 150ms.
  - `testExplicitTopThenExplicitLatestSupersedesTop` — generation strictly increases; mode `.followingLatest`; old top command no longer current (`isCommandCurrent` false).
  - `testUserDragBeginsSwitchesToBrowsingCancelsRestorationAndBumpsGeneration` — from `.followingLatest` + pending restoration: `userDragBegan` → mode `.browsing`, `.cancelAutomaticRestoration` effect, bottom-follow commands from before are stale.
  - `testDuplicateDragChangedCallbacksBeginOnlyOnce` — two `userDragBegan` calls → single generation bump; second returns no cancel effect (port of `testDragLifecycleIgnoresDuplicateChangedCallbacks`).
  - `testDragInvalidateWithActiveGestureSuppressesNextBeginUntilFinish` (port of `testDragLifecycleCapturesStartAndSuppressesInvalidatedGestureUntilFinish`).
  - `testInvalidateWithoutGestureCancelsPendingCompletion` (port of `testDragLifecycleInvalidatesPendingCompletionAfterGestureStateReset`).
  - `testAbandonDragAllowsFreshGestureAfterViewReappears` (port of `testDragLifecycleAbandonAllowsFreshGestureAfterViewReappears`).
  - `testUserDragGestureEndedSchedulesEvaluation` — returns `.scheduleDragEvaluation(token)`; `pendingDragEvaluation == token`.
  - `testEvaluateDragCompletionRelatchesNearBottomThenPersistsInOrder` — with facts near bottom: effects ordered `.persistViewportSnapshot` before... : relatch (mode `.followingLatest`) + `.persistViewportSnapshot` + `.flushViewportPersistence`, in that order.
  - `testEvaluateDragCompletionAwayFromBottomStaysBrowsingAndPersists` — mode stays `.browsing`, persist+flush present.
  - `testEvaluateStaleDragCompletionDoesNothing` — token from older generation/session/handoff/restoration: no effects (port the truth table of `testDragCompletionRequiresCurrentGestureViewportAndSession`: runtime↔canonical alias matches, unrelated session doesn't, nil-session matches nil).
  - `testEvaluateDragCompletionWhileStillDraggingDoesNothing`.
  - `testLayoutGrowthWhileFollowingIssuesNonAnimatedBottomScrollBeyondTolerance` — `layoutMetricsChanged` with `bottomMarkerMaxY = viewportMaxY + 6`, follow drift tolerance 0.5 → exactly one `.scroll(.bottom, animated: false, retry: nil)` command, current.
  - `testLayoutGrowthWithinFollowToleranceIssuesNothing`.
  - `testLayoutGrowthWhileBrowsingExplicitTopOrRestoringIssuesNothing` (3-in-1: content growth alone never moves a non-following viewport).
  - `testLayoutTickNearBottomWhileBrowsingRelatchesWithoutScrolling` (ports `shouldRelatch` truth table; no scroll effect on relatch).
  - `testLayoutTickRelatchSuppressedByPendingRestorationHandoffOrDrag` (truth-table port of `testFollowLatestRelatchRequiresSettledNearBottomViewport`).
  - `testLayoutTickNearBottomReturnsExplicitTopToFollowingLatest` (ports the `hasActiveTopOwner` branch of `relatchFollowsLatestIfSettled`).
  - `testTranscriptChangeWhileFollowingReassertsLatestAnimated` — `.renderingChanged`/`.semanticsChanged` + following → one animated bottom scroll with retry; `.unchanged` → nothing (ports `ChatMessageScrollUpdatePolicy`).
  - `testTranscriptChangeWhileBrowsingOrRestoringOrHandoffNeverScrolls`.
  - `testSessionSwitchToUnrelatedKeyClaimsFollowingLatestAndScrollsUnlessDragging` — `renderedSessionChanged` non-notification, non-equivalent key: invalidates drag, cancels stale restoration (`.cancelAutomaticRestoration` when a request for the OLD key is pending), mode `.followingLatest` + animated bottom scroll; with `isDragging` drag state active → stays `.browsing`, no scroll (ports onChange(activeSessionId) + `shouldFollowLatestAfterTransition`).
  - `testEquivalentSessionKeyRotationDoesNotBumpGenerationOrScroll` — runtime→canonical alias rotation via `renderedSessionChanged` with equivalent identity: rendered key updates, generation unchanged, no effects (ports the `keysAreEquivalent` early return + onChange(activeChatScrollSessionIdentity)).
  - `testStaleRestorationRequestForDifferentSessionCancelledOnSessionChange`.
  - `testNotificationHandoffBeganEntersTransitioningCancelsRestorationAndSuppressesEverything` — mode `.transitioning`; layout growth, transcript reassert, and latest-retry commands all dead while handoff pending.
  - `testNotificationHandoffDestinationReadyWithoutTopOwnerFollowsLatestNonAnimated` — measured + ready: mode `.followingLatest`, one non-animated bottom scroll, no retry.
  - `testNotificationHandoffDestinationReadyWithActiveTopOwnerScrollsToTop` — top requested during handoff: ready → `.top` scroll, mode `.explicitTop(request:)`.
  - `testNotificationHandoffDestinationReadyWhileDraggingStaysBrowsingNoScroll`.
  - `testCommandCurrencyValidatesGenerationSessionAndMode` — bottom command current only while `.followingLatest` with no restoration/handoff; top command current only while `.explicitTop(request:)` matches; message command current only while `.restoring`; generation/session mismatch → stale (aggressive stale-token rejection).
  - `testViewDisappearedAbandonsDrag`.
  - `testRenderedSnapshotMapsFollowingTopAndSyntheticTopAnchor` — `renderedViewportSnapshot` with mode following → `followsLatest: true`; browsing at stable row → semantic anchor + metadata + source id; stable top == nil above first row → first target's anchor (never the synthetic top marker id).

- [ ] **Step 2: Run tests to verify they fail** — `ConduitTests/ChatViewportControllerTests` fails to build (type doesn't exist). Expected.

- [ ] **Step 3: Implement `ChatViewportController`.** Full skeleton with the folded policies; the design (keep faithful — the tests above are its contract):

```swift
// Conduit/Services/ChatViewportController.swift
import Foundation

enum ChatViewportMode: Equatable {
    case followingLatest
    case browsing
    case restoring
    case explicitTop(request: Int)
    case transitioning
}

struct ChatViewportCommand: Equatable {
    enum Destination: Equatable {
        case bottom(anchorID: String)
        case top(anchorID: String, request: Int)
        case message(id: String)
    }

    enum Retry: Equatable {
        case delayed(milliseconds: Int)
    }

    let generation: UInt64
    let sessionKey: ChatScrollSessionKey?
    let destination: Destination
    let animated: Bool
    let retry: Retry?
}

enum ChatViewportEffect: Equatable {
    case scroll(ChatViewportCommand)
    case cancelAutomaticRestoration
    case persistViewportSnapshot(for: ChatScrollSessionKey?)
    case flushViewportPersistence
    case completeRestoration(generation: UInt64)
    case abandonRestoration(generation: UInt64)
    case scheduleDragEvaluation(ChatDragCompletionToken)
}

struct ChatViewportLayoutFacts: Equatable {
    var bottomMarkerMaxY: CGFloat?
    var viewportMinY: CGFloat?
    var viewportMaxY: CGFloat?
    var rowFrames: [ChatRenderedRowFrame]
    var renderedScope: ChatRenderedScrollScope?
}

/// The single authority over the chat viewport. Pure and deterministic:
/// consumes facts/events, emits effects for the view's single scroll
/// executor. Folds the semantics of ChatScrollOwnerState,
/// ChatDragLifecycleState, ChatFollowLatestRelatchPolicy,
/// ChatMessageScrollUpdatePolicy, and the notification-handoff booleans
/// under ONE ownership generation.
struct ChatViewportController: Equatable {
    private(set) var mode: ChatViewportMode = .followingLatest
    private(set) var generation: UInt64 = 1

    // Identity facts
    private(set) var identity: ChatScrollSessionIdentity = .none
    private(set) var renderedSessionKey: ChatScrollSessionKey?
    private var mirroredViewportTransitionGeneration: UInt64 = 0
    private(set) var renderedTranscriptRevision: UInt64 = 0

    // Transcript
    private(set) var targetCache = ChatMessageScrollTargetCache()
    var targets: [ChatMessageScrollTarget] { targetCache.targets }

    // Layout facts
    private(set) var bottomMarkerMaxY: CGFloat?
    private(set) var viewportMinY: CGFloat?
    private(set) var viewportMaxY: CGFloat?
    private(set) var stableTopMessageID: String?

    // Sub-states (folded)
    private var drag = DragLifecycle()            // folded ChatDragLifecycleState
    private var dragGestureActive = false
    private(set) var pendingDragEvaluation: ChatDragCompletionToken?
    private var handoff: HandoffState?
    private var restoration: RestorationState?    // Task 5 activates

    let nearBottomTolerance: CGFloat    // default 40
    let followDriftTolerance: CGFloat   // default 0.5

    init(nearBottomTolerance: CGFloat = 40, followDriftTolerance: CGFloat = 0.5) { ... }
```

  Implementation notes (each is a decision the tests pin):
  - **`advanceGeneration()`** — `generation &+= 1` on every ownership-changing action: explicit latest, explicit top, drag begin, drag invalidate/abandon, non-equivalent session change, handoff began, restoration requested, handoff completion, relatch via top-owner-return (any mode transition except pure fact updates).
  - **`renderedSessionChanged(to:identity:viaNotification:)`** — port ChatView's onChange(activeSessionId)/(activeProfile) combined:
    - notification path: `handoff = .init(destination: key, hasMeasuredLayout: false)`, `mode = .transitioning`, advance generation, invalidate drag (no completion), cancel restoration effect, update `renderedSessionKey = to`, mirror transition generation (unconditional in the notification branch — matches current line 327-330 behavior where the key updates and generation mirrors only if following; keep exact parity: mirror `if mode-was-following`).
    - non-notification: compute `oldKey = renderedSessionKey`, `keysAreEquivalent = identity.areEquivalent(oldKey, newKey)`; cancel restoration when a pending restoration's key is not equivalent to the new key; if `!keysAreEquivalent`: invalidate drag, advance generation, `renderedSessionKey = newKey`, `stableTopMessageID = nil`, mode = followingLatest if no active drag else stays `.browsing`, emit animated `.scroll(.bottom(...), retry: .delayed(150))` when following; if equivalent: just update `renderedSessionKey = newKey` (alias adoption), zero effects. First-ever adoption (`oldKey == nil && newKey != nil` and no prior rendered content) → adoption only, no scroll (matches onAppear assignment which never scrolls).
  - **`activeIdentityRefreshed(identity:key:)`** — port onChange(activeChatScrollSessionIdentity): adopt canonical key when equivalent; no effects.
  - **`transcriptChanged(messages:transcriptRevision:)`** — update `targetCache` (keeping its `.unchanged/.renderingChanged/.semanticsChanged` classification), update `renderedTranscriptRevision`; reassert-latest effect iff `update != .unchanged && mode == .followingLatest && restoration == nil && handoff == nil` — one animated bottom command with 150ms retry. (The old `DispatchQueue.main.async` double-check is subsumed: the executor executes synchronously under the same conditions, and the retry validates `isCommandCurrent`.)
  - **`layoutMetricsChanged(facts:)`** — store facts; derive `stableTopMessageID` = first target-order row whose `[minY, maxY)` intersects `[viewportMinY, viewportMaxY)` (rows report via `facts.rowFrames`; intersect test `row.maxY > viewportMinY && row.minY < viewportMaxY`); persist effect when stableTopMessageID changed (for rendered key); then, in order: (a) top-owner return: if mode == .explicitTop && isNearBottom → advance generation, mode = .followingLatest (ports `relatchFollowsLatestIfSettled`'s owner branch — NO scroll); (b) relatch: if mode == .browsing && isNearBottom && restoration == nil && handoff == nil && !dragGestureActive → mode = .followingLatest (no scroll, no generation bump needed — same owner); (c) follow growth: if mode == .followingLatest && restoration == nil && handoff == nil && bottomGap = bottomMarkerMaxY - viewportMaxY > followDriftTolerance → one `.scroll(.bottom, animated: false, retry: nil)` stamped with CURRENT generation. `isNearBottom` = `bottomMarkerMaxY <= viewportMaxY + nearBottomTolerance` (default true when facts missing, matching today).
  - **Drag** — `DragLifecycle` is the folded `ChatDragLifecycleState` (copy its fields/logic verbatim: `begin(sessionKey:viewportTransitionGeneration:) -> Bool`, `invalidate(hasActiveGesture:)`, `abandon()`, `finish() -> ChatDragCompletionToken?`, `currentToken(...)`). `userDragBegan` calls `drag.begin`; on first begin: advance generation, mode = .browsing, emit `.cancelAutomaticRestoration`. `userDragGestureEnded` calls `drag.finish()`; non-nil token → `pendingDragEvaluation = token`, emit `.scheduleDragEvaluation(token)`. `evaluateDragCompletion(token)`: folded `ChatFollowLatestRelatchPolicy.isCompletionCurrent` (dragGeneration + viewportTransitionGeneration + session equivalence + !dragging + !restoration + !handoff) then relatch-if-near-bottom (no scroll), then `.persistViewportSnapshot(for: token.sessionKey)`, then `.flushViewportPersistence`; clear `pendingDragEvaluation` either way. `invalidateDrag(hasActiveGesture:)`/`abandonDrag()` wrap the lifecycle's same-named methods + generation advance.
  - **`explicitLatestRequested()`** — advance generation; invalidate drag; emit `.cancelAutomaticRestoration`; mode = .followingLatest; emit animated bottom command (anchor from rendered-or-active key, retry 150ms).
  - **`explicitTopRequested(request:)`** — advance generation; invalidate drag; emit `.cancelAutomaticRestoration`; mode = .explicitTop(request:); emit non-animated top command (`ChatTitleScrollAnchor.id(for: renderedKey ?? activeFallback)`, retry 150ms).
  - **Handoff** — `notificationHandoffBegan(destination:)`: advance generation, invalidate drag, cancel restoration effect, `handoff = (key: destination, hasMeasuredLayout: false)`, mode = .transitioning (ports isOpeningNotificationSession==true branch). `notificationHandoffLayoutMeasured()`: set flag (no effects). `notificationHandoffDestinationReady()` (view calls when `!isOpeningNotificationSession && measured && key equivalent`): clear handoff; advance generation; then port `handoffCompletionAction`: active explicitTop → mode stays `.explicitTop(request:)` + emit `.scroll(.top(...), retry 150ms)` (the retry-capable path); else if `!dragGestureActive` → mode = .followingLatest + non-animated `.scroll(.bottom, retry: nil)`; else mode = .browsing, no effects.
  - **`isCommandCurrent(_:)`** — `.bottom`: generation matches && mode == .followingLatest && restoration == nil && handoff == nil && sessionKeyEquivalent(command.sessionKey, renderedSessionKey). `.top`: generation matches && mode == .explicitTop(request:) with matching request && session equivalent. `.message`: generation matches && mode == .restoring && restoration != nil.
  - **`renderedViewportSnapshot(pendingRestorationGeneration:)`** — call `ChatTitleScrollViewportSnapshot.make(followsLatest: isFollowingLatest, topVisibleID: stableTopMessageID, topAnchorID: ChatTitleScrollAnchor.id(for: renderedSessionKey ?? fallback), targets: targetCache.targets)` and wrap in `ChatRenderedViewportSnapshot(sessionKey:snapshot:)`.
  - `renderedScrollScope` accessor composes `ChatRenderedScrollScope(sessionKey:cacheRevision:restorationGeneration:transcriptRevision:viewportTransitionGeneration:)` from stored mirrors (used by ChatView's preference payloads; keeps the AppState settle handshake unchanged).
  - `restorationRequested` / `restorationSystemCancelled` / `restorationTick` ship as stubs in this task (mode/generation bookkeeping only: `.restoring` + generation advance + drag invalidate + cancel of prior top/handoff-free path) — full port is Task 5. They must still compile and keep `ChatViewportControllerTests` green (no tests for them yet).

- [ ] **Step 4: Run controller tests — green**, and run `ChatScrollStateTests` (the `ChatRenderedScrollTargets` extension must not break it).

- [ ] **Step 5: Commit** — `viewport: add ChatViewportController core state machine with tests`

---

## Task 2 (Phase 2): Stable viewport observation in ChatView

**Files:**
- Modify: `Conduit/Views/ChatView.swift` (row frames preference, viewport bounds both edges, derived `stableTopMessageID`; snapshot provider reads derived value)
- Modify: `Conduit/Services/ChatScrollState.swift` (only if any frame plumbing remained)

**Interfaces:**
- Consumes: `ChatRenderedRowFrame`, `ChatRenderedScrollTargets.row(_:scope:frame:)` (Task 1 Step 0).
- Produces: ChatView-local `stableTopMessageID` observation replacing READS of `topVisibleChatID` (the `.scrollPosition` binding itself is removed in Task 7; in this task both exist, but all decisions/persistence switch to the new observation).

- [ ] **Step 1: Extend row reporting to carry frames.** In the `ForEach(chatMessageScrollTargetCache.targets)` row background, replace `GeometryReader { _ in` with:

```swift
.background {
    GeometryReader { geometry in
        Color.clear.preference(
            key: ChatRenderedScrollTargetsPreferenceKey.self,
            value: renderedScrollScope.map { scope in
                ChatRenderedScrollTargets.row(
                    semanticID: target.id,
                    scope: scope,
                    frame: geometry.frame(in: .global)
                )
            } ?? ChatRenderedScrollTargets()
        )
    }
}
```

- [ ] **Step 2: Report both viewport edges.** Change `ChatViewportBottomPreferenceKey` to carry `CGRect` (scroll view frame in `.global`); update `onPreferenceChange` to store `scrollViewportMinY/MaxY`. (Keep `ChatBottomMarkerPreferenceKey` as-is: content stack maxY.)

- [ ] **Step 3: Derive the stable top message.** Add `@State private var renderedRowFrames: [String: CGRect] = [:]` filled in the `ChatRenderedScrollTargetsPreferenceKey` change handler (from `renderedScrollTargets.rowFrames(in: currentScope)`), and compute:

```swift
private var stableTopMessageID: String? {
    guard let viewportMinY, let viewportMaxY else { return nil }
    for target in chatMessageScrollTargetCache.targets {
        guard let frame = renderedRowFrames[target.id] else { continue }
        if frame.maxY > viewportMinY && frame.minY < viewportMaxY {
            return target.id
        }
    }
    return nil
}
```

  Streaming/typing/markers never enter `renderedRowFrames` (only message rows report), so ephemeral IDs cannot leak into observation. Replace every READ of `topVisibleChatID` with `stableTopMessageID`: `currentChatViewportSnapshot()` (:482), the snapshot provider capture (:209-214), restoration confirmation (`applyChatResumeRestoration` `topVisibleID:` argument, :605). The `.onChange(of: topVisibleChatID)` persistence trigger becomes `.onChange(of: stableTopMessageID)` → `saveChatScrollPosition(for: renderedScrollSessionKey)`.

- [ ] **Step 4: Write the observation test** (in `ChatViewportControllerTests` — pure, drives `layoutMetricsChanged` facts):

```swift
func testStableTopMessagePicksFirstTargetOrderRowIntersectingViewport() {
    var c = controller(following: ChatScrollSessionKey(profile: "p", sessionID: "s1"))
    c.transcriptChanged(messages: [
        ChatMessage(id: "m1", role: .assistant, content: "one"),
        ChatMessage(id: "m2", role: .assistant, content: "two"),
        ChatMessage(id: "m3", role: .assistant, content: "three")
    ], transcriptRevision: 1)
    let scope = c.renderedScrollScope!
    // only m2 and m3 rendered (lazy); m2 intersects the top edge
    _ = c.layoutMetricsChanged(facts: .init(
        bottomMarkerMaxY: 900, viewportMinY: 100, viewportMaxY: 800,
        rowFrames: [
            ChatRenderedRowFrame(id: "m2", minY: 120, maxY: 300, scope: scope),
            ChatRenderedRowFrame(id: "m3", minY: 320, maxY: 500, scope: scope)
        ],
        renderedScope: scope))
    XCTAssertEqual(c.stableTopMessageID, "m2")
    // scroll up so m1's frame intersects even though it starts above the viewport
    _ = c.layoutMetricsChanged(facts: .init(
        bottomMarkerMaxY: 900, viewportMinY: 100, viewportMaxY: 800,
        rowFrames: [
            ChatRenderedRowFrame(id: "m1", minY: 40, maxY: 140, scope: scope),
            ChatRenderedRowFrame(id: "m2", minY: 160, maxY: 340, scope: scope)
        ],
        renderedScope: scope))
    XCTAssertEqual(c.stableTopMessageID, "m1")
}
```

  (Controller already implements this in Task 1; this test belongs to the Task-1 set if written there — the executor may have already included it. Ensure it exists and passes.)

- [ ] **Step 5: Run the focused suites** — `ChatScrollStateTests`, `ChatTitleScrollTests`, `AppStateChatResumeTests` must stay green (snapshot semantics unchanged). Run app in simulator briefly if practical; otherwise rely on suites.

- [ ] **Step 6: Commit** — `viewport: observe stable top message via row geometry`

---

## Task 3 (Phase 3): Single scroll executor + controller ownership of latest/top/drag

**Files:**
- Modify: `Conduit/Views/ChatView.swift`
- Modify: `ConduitTests/ChatTitleScrollTests.swift` (only if it referenced deleted members — it shouldn't yet; ChatScrollOwnerState survives until Task 7)

**Interfaces:**
- Consumes: full Task 1 controller API.
- Produces: `ChatView.performViewportEffects(_:using:)` / `performViewportEffect(_:using:)` — the ONLY `proxy.scrollTo` boundary from here on.

- [ ] **Step 1: Introduce controller state + executor in ChatView.**

```swift
@State private var viewport = ChatViewportController()
```

  Executor (replaces `scrollToLatest`, `scrollToTop`, and their naked retry Tasks):

```swift
@MainActor
private func performViewportEffects(_ effects: [ChatViewportEffect], using proxy: ScrollViewProxy) {
    for case let effect in effects { performViewportEffect(effect, using: proxy) }
}

@MainActor
private func performViewportEffect(_ effect: ChatViewportEffect, using proxy: ScrollViewProxy) {
    switch effect {
    case .scroll(let command):
        executeScrollCommand(command, using: proxy)
    case .cancelAutomaticRestoration:
        appState.cancelChatResumeRestoration()
    case .persistViewportSnapshot(let key):
        saveChatScrollPosition(for: key)
    case .flushViewportPersistence:
        appState.flushChatResumeViewport()
    case .completeRestoration(let generation):
        appState.completeChatResumeRestoration(generation: generation)
    case .abandonRestoration(let generation):
        appState.abandonChatResumeRestoration(generation: generation)
    case .scheduleDragEvaluation(let token):
        Task { @MainActor in
            await ChatFollowLatestRelatchPolicy.waitForNextMainActorTurn()
            guard !Task.isCancelled else { return }
            performViewportEffects(viewport.evaluateDragCompletion(token), using: proxy)
        }
    }
}

@MainActor
private func executeScrollCommand(_ command: ChatViewportCommand, using proxy: ScrollViewProxy) {
    // Immediate execution matches today's scrollToLatest/scrollToTop: the
    // command was issued by the controller this turn, so it is current by
    // construction. Only the delayed retry re-validates below.
    runScroll(command, using: proxy)
    if case .delayed(let milliseconds) = command.retry {
        let token = command
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled, viewport.isCommandCurrent(token) else { return }
            runScroll(token, using: proxy)
        }
    }
}

@MainActor
private func runScroll(_ command: ChatViewportCommand, using proxy: ScrollViewProxy) {
    ChatViewportTrace.shared.log("scroll \(command.destination) gen=\(command.generation) animated=\(command.animated)")
    var transaction = Transaction()
    transaction.animation = command.animated ? ConduitMotion.response : nil
    withTransaction(transaction) {
        switch command.destination {
        case .bottom(let anchorID): proxy.scrollTo(anchorID, anchor: .bottom)
        case .top(let anchorID, _): proxy.scrollTo(anchorID, anchor: .top)
        case .message(let id): proxy.scrollTo(id, anchor: .top)
        }
    }
}
```

  `runScroll` is as shown; delete the contradictory pre-guard idea — immediate commands execute unconditionally (they were issued this turn), only the 150ms retry validates `viewport.isCommandCurrent(token)`.

- [ ] **Step 2: Route the Phase-3 call sites through the controller.** For each, delete the old body and send events (trace-log each event):

  | Old site | New body |
  |---|---|
  | `.onChange(of: appState.chatScrollRequest)` (:307) | `performViewportEffects(viewport.explicitLatestRequested(), using: proxy)` |
  | `.onChange(of: appState.chatScrollToTopRequest)` (:313) | `performViewportEffects(viewport.explicitTopRequested(request: request), using: proxy)` |
  | drag gesture `beginChatDragIfNeeded` | `performViewportEffects(viewport.userDragBegan(sessionKey: viewport.renderedSessionKey ?? activeScrollSessionKey, viewportTransitionGeneration: appState.chatViewportTransitionGeneration), using: proxy)` |
  | `.onChange(of: isDraggingChat)` (:261) | `performViewportEffects(viewport.userDragGestureEnded(), using: proxy)` (controller emits `.scheduleDragEvaluation`; delete the `.task(id: chatDragCompletionToken)` block and `completeChatDrag`) |
  | latest-button overlay action (:431) | `performViewportEffects(viewport.explicitLatestRequested(), using: proxy)` |
  | `updateBottomMarker`/`updateViewportBottom` (:796-804) | replaced by a single facts event: `performViewportEffects(viewport.layoutMetricsChanged(facts: currentLayoutFacts()), using: proxy)` where `currentLayoutFacts()` assembles `bottomMarkerMaxY/viewportMinY/viewportMaxY/rowFrames/renderedScope`; delete `relatchFollowsLatestIfSettled` (its logic lives in the controller) |
  | `.onChange(of: appState.messages)` (:265) | `performViewportEffects(viewport.transcriptChanged(messages: newMessages, transcriptRevision: appState.chatTranscriptRevision), using: proxy)` — but ONLY the reassert part moves now; the target-cache update + rendered-revision mirroring inside the controller updates `viewport.renderedScrollScope` which the preference payloads read; ALSO keep `notificationHandoffPending` bookkeeping until Task 4 (leave those lines) |
  | `.onChange(of: appState.isBusy)` (:422) | interim: `if !isBusy, viewport.isFollowingLatest, !hasPendingRestoration { performViewportEffects(viewport.transcriptSettledAfterActivity(), using: proxy) }` — add a thin controller method emitting the animated bottom command only-when-following (deleted in Task 6) |

  Interim bridging rule (prevents dual authority): `followsLatest` @State is DELETED in this task; every remaining legacy read (streaming onChange :418, restoration loop :582/:619/:623, notification branches :328/:346/:372/:379/:385/:408/:432/:777/:784/:792 — until Tasks 4–6 take them) becomes `viewport.isFollowingLatest`, and every legacy WRITE (`followsLatest = x`) becomes a call to a transitional controller method `viewport.legacySetFollowingLatest(_:) -> [ChatViewportEffect]` that just sets mode (`.followingLatest` / `.browsing`) without generation bumps, returning `[]`. These transitional calls are deleted by Tasks 4–6 and must not survive Task 7. Grep-audit at the end of this task: `grep -n "legacySetFollowingLatest" Conduit/Views/ChatView.swift` — every hit must have a TODO(task-4/5/6) comment naming its removal task.

  The snapshot-provider capture closure (:202-222) now returns `viewport.renderedViewportSnapshot(pendingRestorationGeneration: appState.chatResumeRestorationRequest?.generation)` (it captures the `@State` box, so it reads live values exactly like the old bindings did).

- [ ] **Step 3: Delete replaced machinery** — `scrollToLatest`, `scrollToTop`, `scrollOwnerState` usage in these paths, `chatDragLifecycle`/`chatDragCompletionToken` @State (the controller owns them), `completeChatDrag`, `beginChatDragIfNeeded` body, `currentChatDragCompletionToken`, `invalidateChatDrag`/`abandonChatDrag` become thin wrappers sending `viewport.invalidateDrag(hasActiveGesture:)`/`viewport.abandonDrag()` effects. NOTE: `scrollOwnerState` @State and the type itself survive for the still-old paths (session-change :322/:343 etc., handoff :771) until Tasks 4/7 — those call sites keep working because the type is untouched; they just coexist temporarily (spec: "Do not yet delete old restoration logic until equivalent controller tests pass").

- [ ] **Step 4: Run all focused suites** (`ChatViewportControllerTests`, `ChatScrollStateTests`, `ChatTitleScrollTests`, `ChatResumeCoordinatorTests`, `ChatResumePolicyTests`, `ChatResumeStoreTests`, `AppStateChatResumeTests`). All green. Also `xcodegen generate` is NOT needed (no file adds beyond Task 1).

- [ ] **Step 5: Commit** — `viewport: route latest/top/drag through ChatViewportController with single executor`

---

## Task 4 (Phase 4): Session transitions + notification handoff through the controller

**Files:**
- Modify: `Conduit/Views/ChatView.swift`

**Interfaces:**
- Consumes: `renderedSessionChanged`, `activeIdentityRefreshed`, `notificationHandoffBegan/layoutMeasured/destinationReady`.

- [ ] **Step 1: Rewrite the transition onChange handlers:**
  - `.onChange(of: appState.activeSessionId)` (:319) → single event: `performViewportEffects(viewport.renderedSessionChanged(to: activeScrollSessionKey, identity: appState.activeChatScrollSessionIdentity, viaNotification: appState.isOpeningNotificationSession), using: proxy)`. The controller implements both branches (notification handoff bookkeeping inside `viaNotification: true`; the old inline `notificationHandoffPending = true` lines die here). The handoff destination-key capture (`notificationHandoffSessionKey = activeScrollSessionKey` at :325) and the measured-layout flag move into controller handoff state via `notificationHandoffBegan(destination:)` / `notificationHandoffLayoutMeasured()` — call `notificationHandoffLayoutMeasured()` from both geometry preferences' change handlers (replacing `recordNotificationHandoffLayout`), keyed on `viewport` handoff internals exposed read-only (`viewport.notificationHandoffAwaitingLayout`).
  - `.onChange(of: appState.activeProfile)` (:358) → same `renderedSessionChanged` event (controller treats profile change as key change; also reset target cache via `transcriptChanged` — the controller's `transcriptChanged` handles cache reset when message identity wholly changes; feed it `appState.messages` + revision right after).
  - `.onChange(of: appState.activeChatScrollSessionIdentity)` (:390) → `performViewportEffects(viewport.activeIdentityRefreshed(identity: appState.activeChatScrollSessionIdentity, key: activeScrollSessionKey), using: proxy)`.
  - `.onChange(of: appState.isOpeningNotificationSession)` (:400) → `isOpening == false`: `performViewportEffects(viewport.notificationHandoffDestinationReady(), using: proxy)` (the controller validates measured+equivalent internally — the old `finishNotificationHandoffIfReady` guard chain and its `ChatHandoffCompletionAction` switch die); `isOpening == true` handled by `renderedSessionChanged(viaNotification: true)` already; keep an event here too for the handoff-began-without-session-change case (notification for the CURRENT session): send `notificationHandoffBegan(destination: nil→activeScrollSessionKey resolution as today at :410-412)`.
  - Delete `finishNotificationHandoffIfReady`, `recordNotificationHandoffLayout`, `notificationHandoffPending/SessionKey/HasMeasuredLayout` @State, and the `scrollOwnerState.invalidateForSessionTransition()` calls (controller does it).
  - **Mirror-generation parity:** the controller's `renderedSessionChanged` must mirror `appState.chatViewportTransitionGeneration` exactly where the old code did — inside the controller this is the `mirroredViewportTransitionGeneration` updated (a) unconditionally when following-latest was the pre-change mode, (b) via `transcriptChanged`/`renderedSessionChanged` when messages/revision advance (old :268, :295). Pass the current `appState.chatViewportTransitionGeneration` into `renderedSessionChanged` and `transcriptChanged` as a parameter (`viewportTransitionGeneration: UInt64`) so the controller mirrors without reading AppState. Add a controller test: `testRenderedScopeMirrorsTransitionGenerationOnlyWhenFollowing` capturing this parity rule.

- [ ] **Step 2: Remove the interim `legacySetFollowingLatest` uses from all session/handoff sites** (they were replaced by real events). The only surviving legacy uses after this task: streaming onChange (:418) and the restoration loop — both consumed by Tasks 5/6.

- [ ] **Step 3: Run focused suites + the new controller handoff tests.** All green.

- [ ] **Step 4: Commit** — `viewport: move session transitions and notification handoff into controller`

---

## Task 5 (Phase 5): Automatic restoration → controller `.restoring`

**Files:**
- Modify: `Conduit/Services/ChatViewportController.swift` (activate `RestorationState`)
- Modify: `Conduit/Views/ChatView.swift` (delete `applyChatResumeRestoration` loop internals)
- Modify: `ConduitTests/ChatViewportControllerTests.swift` (restoration tests)

**Interfaces:**
- Consumes: `ChatResumeRestorationRequest`, `ChatResumeViewportResolver`, `ChatRenderedScrollContent/Targets`, folded `ChatResumeRenderRestorationState` semantics (maximumChecks 80, retryInterval 4, 25ms tick — the interval stays view-side).
- Produces: `mutating func restorationTick(messages:transcriptRevision:renderedContent:installedTargets:topVisibleID:isNearBottom:) -> [ChatViewportEffect]`.

- [ ] **Step 1: Write the failing restoration controller tests** (port each listed ChatScrollStateTests case into controller-level equivalents; keep the originals green until Task 7 deletes the old type):
  - `testRestorationRequestedEntersRestoringInvalidatesDragAndResolvesDestination` — snapshot with resolvable anchor → destination `.anchor(target.id)`; latest → `.latest`.
  - `testRestorationWaitsForMatchingRenderedScopeAndGeometryConfirmation` (port of `testRestorationWaitsForMatchingRenderedTargetAndGeometryConfirmation`: mismatched scope → no scroll on early ticks; matching container bootstraps offscreen lazy target via `.scroll`; a different rendered row must not confirm).
  - `testRestorationScrollRetriesOnIntervalAndCompletesOnlyWhenAnchorConfirmed` — topVisibleID == anchor + row registered in `ChatRenderedScrollTargets` → `.completeRestoration(generation:)`; completion for `.latest` also persists (`.persistViewportSnapshot(for: request.sessionKey)` after complete).
  - `testRestorationLatestConfirmsOnlyWhenNearBottom`.
  - `testRestorationAbandonsAfterBoundedChecks` (maximumChecks exhausted → `.abandonRestoration`).
  - `testRestorationCancelledBySystemClearsStateToBrowsing`.
  - `testRestorationYieldsToExplicitLatestTopDragAndSessionChange` — any of those events during `.restoring` clears restoration state, cancels via `.cancelAutomaticRestoration`, and the stale `.message` command is no longer current.
  - `testRestorationDestinationReResolutionSurvivesTargetRefresh` (updateDestination port: destination re-resolved each tick when targets change; duplicate-multiplicity fallback to `.latest` still applies — port `testRestorationFallsBackWhenDuplicateMultiplicityChanges` semantics through the tick).

- [ ] **Step 2: Implement `RestorationState`** inside the controller: fields `{ request: ChatResumeRestorationRequest, destination: ChatResumeViewportDestination, checkCount: Int = 0, lastScrollCheck: Int?, cancelled: Bool }` with the exact nextAction algorithm from `ChatResumeRenderRestorationState.nextAction` (same guards in the same order: scope match incl. `restorationGeneration == request.generation` && sessionKey && cacheRevision && transcriptRevision; complete requires installed target + confirmed topVisible/near-bottom AND a prior scroll check; scroll on retry interval; abandon past maximumChecks=80; `.wait` otherwise). Destination resolution ports `restorationDestination(for:targets:)` (semantic→source-id mapping via `targets.first { $0.semanticID == semanticAnchor }?.id`). `restorationRequested` stores state, advances generation, invalidates drag, mode = .restoring. The request-currency check (`appState.chatResumeRestorationRequest?.generation == request.generation` + identity equivalence) stays VIEW-side (it reads AppState); the view's `.task(id: appState.chatResumeRestorationRequest?.generation)` loop becomes:

```swift
.task(id: appState.chatResumeRestorationRequest?.generation) {
    guard let request = appState.chatResumeRestorationRequest else { return }
    performViewportEffects(viewport.restorationRequested(request), using: proxy)
    while !Task.isCancelled && viewport.restorationIsActive {
        let effects = viewport.restorationTick(
            messages: appState.messages,
            transcriptRevision: appState.chatTranscriptRevision,
            renderedContent: renderedScrollContent,
            installedTargets: renderedScrollTargets,
            topVisibleID: stableTopMessageID,
            isNearBottom: viewport.isNearBottom)
        performViewportEffects(effects, using: proxy)
        guard viewport.restorationIsActive else { return }
        try? await Task.sleep(for: .milliseconds(25))
    }
}
```

  plus `.onChange(of: appState.chatResumeRestorationRequest) { old, new in if new == nil, old != nil { performViewportEffects(viewport.restorationSystemCancelled(), using: proxy) } }`. Delete `applyChatResumeRestoration`, `restorationDestination`, `restorationRequestIsCurrent` (currency folded: the task id + the system-cancelled event + controller generation). `viewport.restorationIsActive` is a read-only accessor (`restoration != nil && mode == .restoring`).

- [ ] **Step 3: Run restoration suites** — `ChatViewportControllerTests`, `ChatScrollStateTests`, `ChatResumeCoordinatorTests`, `ChatResumePolicyTests`, `AppStateChatResumeTests`. Green.

- [ ] **Step 4: Commit** — `viewport: port automatic restoration into controller restoring state`

---

## Task 6 (Phase 6): Follow rendered growth; delete streamingText scrolling

**Files:**
- Modify: `Conduit/Views/ChatView.swift`
- Modify: `Conduit/Services/ChatViewportController.swift` (nothing new needed if Task 1's follow-growth is complete; otherwise finish it)

**Interfaces:** none new.

- [ ] **Step 1: Delete `.onChange(of: appState.streamingText)` entirely (:417-421) and `.onChange(of: appState.isBusy)` (:422-426) plus the interim `transcriptSettledAfterActivity` controller method.** Following now happens exclusively via `layoutMetricsChanged` (bottom marker growth beyond `followDriftTolerance` while `.followingLatest`) and `transcriptChanged` reassert. Trace-log stays on the layout path.

- [ ] **Step 2: Verify the growth-follow path is fed.** The bottom-marker preference (`ChatBottomMarkerPreferenceKey`) fires on content growth (streaming bubble reveal, settled-message swap, tool-card expansion, table layout). Each firing reaches `viewport.layoutMetricsChanged` via the Task 3 wiring. Confirm no path updates `bottomMarkerMaxY` without sending facts to the controller (single funnel: the two `onPreferenceChange` handlers → `currentLayoutFacts()` → event).

- [ ] **Step 3: Add regression tests** (controller-level; names from the spec's required list):
  - `testThirtyHertzGrowthStaysPinnedWithoutUpwardJumps` — 30 successive growth ticks each beyond tolerance each return exactly one current non-animated bottom command (no top/anchor commands ever interleaved; generation never bumps from growth alone).
  - `testFollowGrowthNeverCommandsWhileBrowsingOrExplicitTopOrRestoringOrHandoff` (consolidates earlier suppression tests; keep both).
  - `testStreamingBubbleReplacementToSettledMessageDoesNotJumpBrowsing` — transcript change replacing ephemeral projection with settled message while browsing: no scroll effects, stable anchor preserved (targets rendering-changed, semanticID stable).
  - `testRenderingOnlyReplacementWhileFollowingReassertsLatestExactlyOnce` — one animated command per transcript change, not one per layout tick afterward (layout facts within tolerance after the reassert produce nothing).

- [ ] **Step 4: Run focused suites; manual smoke if simulator healthy.** Green.

- [ ] **Step 5: Commit** — `viewport: follow rendered layout growth instead of streaming deltas`

---

## Task 7 (Phase 7): Remove obsolete ownership machinery + replace obsolete tests

**Files:**
- Modify: `Conduit/Views/ChatView.swift`, `Conduit/Services/ChatScrollState.swift`
- Modify/Create tests: `ConduitTests/ChatTitleScrollTests.swift` (rewritten), `ConduitTests/ChatScrollStateTests.swift` (drag/restoration families removed with mapping), `ConduitTests/ChatViewportCharacterizationTests.swift` (deleted)

**Interfaces:** none new; deletions only.

- [ ] **Step 1: Delete `.scrollPosition(id: $topVisibleChatID, anchor: .top)` (:176), the `topVisibleChatID` @State, and `.scrollTargetLayout()` (:154).** Before deleting `.scrollTargetLayout`, confirm ScrollViewReader restoration still works: `ChatResumeRenderRestoration`-equivalent controller tests green + run the app on the simulator once (open a long conversation, background/foreground with Continue mode) — if anything regresses, keep `.scrollTargetLayout()` with a comment and note it in the PR (spec allows keeping only with confirmed purpose; default is removal).

- [ ] **Step 2: Delete the folded types** from ChatView.swift/ChatScrollState.swift: `ChatScrollOwner/OwnerToken/OwnerState`, `ChatHandoffCompletionAction`, `ChatDragLifecycleState` (the controller's `DragLifecycle` is now the only implementation), `ChatResumeRenderRestorationState`, `ChatFollowLatestRelatchPolicy` (folded: `shouldRelatch`/`shouldFollowLatestAfterTransition`/`isCompletionCurrent` logic lives in controller; KEEP `persistenceSessionKey` and `completeDragAfterNextTurn`/`waitForNextMainActorTurn` as standalone helpers — they are support/value functions the executor still uses; relocate them to ChatViewportController.swift as `enum ChatViewportPersistenceSupport`), `ChatMessageScrollUpdatePolicy` (folded into `transcriptChanged`). Keep: `ChatTitleScrollAnchor`, `ChatTitleScrollViewportSnapshot`, `ChatMessageScrollTargetCache`, `ChatRenderedScroll*`, identity types, `ChatScrollSnapshot`, `ChatDragCompletionToken` (still the token type).

- [ ] **Step 3: Replace the obsolete tests with controller equivalents and write the mapping table into the PR description (also append to `docs/viewport-rewrite-analysis.md`):**

  | Old test (deleted) | New controller test (added in Tasks 1/5) |
  |---|---|
  | ChatScrollStateTests `testFollowLatestRelatchRequiresSettledNearBottomViewport` | `testLayoutTickRelatchSuppressedByPendingRestorationHandoffOrDrag` |
  | ChatScrollStateTests `testDragCompletionRequiresCurrentGestureViewportAndSession` | `testEvaluateStaleDragCompletionDoesNothing` |
  | ChatScrollStateTests `testTranscriptTransitionKeepsFollowDisabledForActiveDrag` | `testSessionSwitchToUnrelatedKey...` + `testLayoutTickRelatchSuppressed...` |
  | ChatScrollStateTests `testDragCompletionPersistsUsingCanonicalSessionIdentity` | keep `persistenceSessionKey` helper test in place (helper survives) |
  | ChatScrollStateTests `testDragLifecycle*` (5 tests) | `testDuplicateDragChangedCallbacksBeginOnlyOnce`, `testDragInvalidateWithActiveGestureSuppressesNextBeginUntilFinish`, `testInvalidateWithoutGestureCancelsPendingCompletion`, `testAbandonDragAllowsFreshGestureAfterViewReappears`, `testUserDragGestureEndedSchedulesEvaluation` |
  | ChatScrollStateTests `testDragCompletion*` (4 async tests) | `testEvaluateDragCompletion*` family |
  | ChatScrollStateTests `testRestoration*`/`testMatchingScrollPosition*`/`testLatestRestoration*`/`testRenderRestorationTimesOut*` (5) | Task 5 restoration family |
  | ChatScrollStateTests `testEqualCountProjectionReplacementReassertsLatestAfterCacheUpdate` + `testLatestReassertionYieldsTo*` | `testTranscriptChangeWhileFollowingReassertsLatestAnimated` + `testTranscriptChangeWhileBrowsingOrRestoringOrHandoffNeverScrolls` |
  | ChatTitleScrollTests owner-token tests (4) | `testExplicitTopClaimsTopOwnershipNonAnimated`, `testNotificationHandoffDestinationReady*`, `testLayoutTickNearBottomReturnsExplicitTopToFollowingLatest` |
  | ChatTitleScrollTests `testTitleScrollRequestIsMonotonicAndObservableForRepeatedTaps` | KEEP as-is (AppState pulse counter unchanged) |
  | ChatTitleScrollTests `testSyntheticTopAnchorPersistsAsFirstMessageTarget` | KEEP as-is (`ChatTitleScrollViewportSnapshot.make` unchanged) |
  | ChatTitleScrollTests `testTopAnchorIsScopedToTheActiveChatSession` | KEEP (anchor id helper unchanged) |
  | ChatViewportCharacterizationTests (all) | deleted — superseded by ChatViewportControllerTests |

  No existing test may be weakened to make the rewrite pass; if a kept test needs a mechanical update (type moved), the assertion strength must be identical.

- [ ] **Step 4: Audit for leftovers.** `grep -rn "legacySetFollowingLatest\|scrollOwnerState\|ChatDragLifecycleState\|ChatResumeRenderRestorationState\|ChatScrollOwnerState\|topVisibleChatID\|scrollTargetLayout\|scrollPosition" Conduit ConduitTests` must return zero hits (except `.scrollPosition` if Step 1 kept it with justification). `grep -n "proxy.scrollTo\|proxy\.scrollTo" Conduit/Views/ChatView.swift` must show hits ONLY inside `runScroll`. `grep -n "onChange(of: appState.streamingText)" Conduit` must be empty.

- [ ] **Step 5: Run ALL focused suites + selection/table suites.** Green.

- [ ] **Step 6: Commit** — `viewport: remove superseded ownership machinery, finalize single authority`

---

## Task 8: Full validation + invariants + PR

**Files:** none new (except PR body).

- [ ] **Step 1: Run the full simulator suite** once (fresh boot first): `xcrun simctl shutdown 124B405C-07CF-44F4-A024-9AD87B9992B0; xcrun simctl boot 124B405C-07CF-44F4-A024-9AD87B9992B0; xcrun simctl bootstatus 124B405C-07CF-44F4-A024-9AD87B9992B0 -b` then `xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination '...' -derivedDataPath .dd`. If the local sim wedges (known issue), erase+reboot once, retry once, then fall back to pushing the branch and validating via CI per repo practice.
- [ ] **Step 2: Manual/simulator streaming stress checklist** (spec's 10 scenarios; use the real gateway if reachable, else the chaos harness at /tmp/conduit-chaos for transport; record `ChatViewportTrace.dump()` for each run and confirm: never more than one current command generation, no scroll command during active drag, no latest command while browsing):
  1. long normal answer untouched; 2. scroll up during stream; 3. manual return to bottom resumes follow; 4. title tap during stream; 5. latest button after title tap; 6. rapid conversation switching during streaming; 7. background/foreground in Continue and Latest modes; 8. large Markdown table/code response; 9. notification open while another transcript visible; 10. text selection + nested horizontal table scrolling afterwards.
- [ ] **Step 3: Final-review invariant sweep** (spec's list — verify each in the finished diff, note evidence in PR body): one viewport state machine; one scrollTo boundary; `onChange(streamingText)` does not scroll; geometry reports facts (no independent ownership booleans mutated in geometry callbacks); no ephemeral ID can become a persisted anchor; all delayed commands carry validated tokens; automatic restoration yields to every explicit action; reconnect never uses Latest preference to navigate; resume-store data compatible (schema untouched); no new global gesture; no connection-code cleanup; no weakened tests.
- [ ] **Step 4: Push + open PR** against `main` with: summary, phase-by-phase commit list, old-test→new-test mapping table, behavior-ledger reference (`docs/viewport-rewrite-analysis.md`), invariant checklist results, manual-run trace notes. Then dispatch the three local reviewers per the established pipeline (code-reviewer full diff, second-reviewer, local-reviewer on diff-only) BEFORE pushing to GitHub if the diff is ready — order: local reviewers → fix → single push → CI → bots.

---

## Appendix A — Spec

(The full pasted spec text from 2026-08-18 is the authoritative source; key headings: Non-negotiable scope boundaries; Existing behavior is the specification (11 groups); Target architecture (controller states/events/effects, one scroll executor, remove competing .scrollPosition authority, follow rendered growth); Preserve the durable resume subsystem; Implementation sequence Phases 0–7; Required regression tests; Validation; Final-review invariants. The executor should re-read the original spec message if any ambiguity arises — this plan defers to it.)
