# Chat Text Selection and Scroll Restoration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users copy arbitrary text from chat and restore their message-level reading position when the app returns from the background.

**Architecture:** Keep the existing native SwiftUI Markdown and chat-card rendering. Apply one explicit text-selection policy to message and streaming bubbles, and track semantic top-visible message IDs using SwiftUI's iOS 17 `scrollPosition(id:)` binding. Store scene-scoped snapshots in a small Foundation-only value type so restoration rules are unit-testable without UI dependencies.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, XcodeGen, iOS deployment target 17.0.

## Global Constraints

- Keep the deployment target at iOS 17.0 and use only APIs available from iOS 17.0 onward.
- Preserve existing whole-response and whole-code copy buttons.
- Keep buttons, images, diagrams, and non-text controls interactive.
- Preserve the existing latest-following behavior for users who are already at the bottom.
- Do not change iPhone portrait-only or iPad orientation behavior.
- Do not bump the marketing/build version or upload a binary in this feature branch until the user explicitly requests the next submission.
- Follow red-green-refactor: each new pure behavior gets a failing test before its production implementation.
- Run `xcodegen generate` before Xcode builds because `Conduit.xcodeproj` is generated and ignored.

---

### Task 1: Establish the chat interaction policy contract

**Files:**
- Create: `Conduit/Services/ChatTextSelectionPolicy.swift`
- Test: `ConduitTests/ChatTextSelectionTests.swift`

**Interfaces:**
- Produces `ChatTextSelectionPolicy.allowsTextSelection(for:) -> Bool` for every `MessageRole`.
- The policy is Foundation-only and does not depend on SwiftUI view types.

- [ ] **Step 1: Write the failing test**

Create `ConduitTests/ChatTextSelectionTests.swift` with an exhaustive list of current roles:

```swift
import XCTest
@testable import Conduit

final class ChatTextSelectionTests: XCTestCase {
    func testEveryCurrentMessageRoleAllowsPartialTextSelection() {
        let roles: [MessageRole] = [
            .user, .assistant, .reasoning, .system,
            .partial, .tool, .clarify, .approval
        ]

        XCTAssertTrue(
            roles.allSatisfy { ChatTextSelectionPolicy.allowsTextSelection(for: $0) }
        )
    }
}
```

- [ ] **Step 2: Run the targeted test and verify it fails for the missing production contract**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,id=E174DE05-4FA3-43F6-8135-38F8835E2313' \
  -only-testing:ConduitTests/ChatTextSelectionTests \
  -derivedDataPath /tmp/hermes-conduit-chat-selection-red-derived \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected result: compilation fails because `ChatTextSelectionPolicy` does not exist yet.

- [ ] **Step 3: Add the minimal exhaustive policy implementation**

Create `Conduit/Services/ChatTextSelectionPolicy.swift`:

```swift
import Foundation

enum ChatTextSelectionPolicy {
    static func allowsTextSelection(for role: MessageRole) -> Bool {
        switch role {
        case .user, .assistant, .reasoning, .system,
             .partial, .tool, .clarify, .approval:
            return true
        }
    }
}
```

The exhaustive switch makes adding a future message role fail compilation until its selection behavior is consciously chosen.

- [ ] **Step 4: Run the targeted test and verify it passes**

Run the same `xcodebuild test` command from Step 2. Expected result: one test passes with zero failures.

- [ ] **Step 5: Commit the policy contract**

```bash
git add Conduit/Services/ChatTextSelectionPolicy.swift ConduitTests/ChatTextSelectionTests.swift
git commit -m "test: define selectable chat message roles"
```

---

### Task 2: Enable partial selection in message and streaming bubbles

**Files:**
- Modify: `Conduit/Views/ChatView.swift:250-270` for `MessageBubble`
- Modify: `Conduit/Views/ChatView.swift:1140-1170` for `StreamingBubble`
- Test: `ConduitTests/ChatTextSelectionTests.swift` remains the policy regression test; simulator verification covers the SwiftUI gesture behavior.

**Interfaces:**
- Consumes `ChatTextSelectionPolicy.allowsTextSelection(for:)` from Task 1.
- Produces system text selection for all current message roles and the active streaming response.

- [ ] **Step 1: Add the smallest view change**

Wrap the existing `MessageBubble` role switch in a `Group` and apply the policy at the shared boundary:

```swift
var body: some View {
    Group {
        switch message.role {
        // existing role cases unchanged
        }
    }
    .textSelection(
        ChatTextSelectionPolicy.allowsTextSelection(for: message.role)
            ? .enabled
            : .disabled
    )
}
```

In `StreamingBubble`, remove `.textSelection(.disabled)` from `StreamingText` and apply `.textSelection(.enabled)` to the containing streaming `VStack`, so the live response has the same selection behavior as a completed message.

- [ ] **Step 2: Run the policy test and a compile-only simulator build**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,id=E174DE05-4FA3-43F6-8135-38F8835E2313' \
  -only-testing:ConduitTests/ChatTextSelectionTests \
  -derivedDataPath /tmp/hermes-conduit-chat-selection-selection-derived \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected result: the test passes and the target compiles with no new errors.

- [ ] **Step 3: Commit the selection behavior**

```bash
git add Conduit/Views/ChatView.swift
git commit -m "feat: allow partial text selection in chat"
```

---

### Task 3: Add the testable per-session scroll snapshot store

**Files:**
- Create: `Conduit/Services/ChatScrollState.swift`
- Create: `ConduitTests/ChatScrollStateTests.swift`

**Interfaces:**
- Produces `ChatScrollSnapshot(anchorMessageID:followsLatest:)`.
- Produces `ChatScrollStateStore.save(_:for:)`, `snapshot(for:)`, and `restoration(for:availableMessageIDs:)`.
- `restoration` returns the stored snapshot when its non-latest anchor exists, returns a latest-follow snapshot when the stored anchor is missing, and returns `nil` when no snapshot exists.

- [ ] **Step 1: Write failing store tests**

Create `ConduitTests/ChatScrollStateTests.swift`:

```swift
import XCTest
@testable import Conduit

final class ChatScrollStateTests: XCTestCase {
    func testSnapshotsAreIsolatedBySession() {
        var store = ChatScrollStateStore()
        store.save(
            ChatScrollSnapshot(anchorMessageID: "a-3", followsLatest: false),
            for: "session-a"
        )
        store.save(
            ChatScrollSnapshot(anchorMessageID: "b-1", followsLatest: false),
            for: "session-b"
        )

        XCTAssertEqual(store.snapshot(for: "session-a")?.anchorMessageID, "a-3")
        XCTAssertEqual(store.snapshot(for: "session-b")?.anchorMessageID, "b-1")
    }

    func testRestorationKeepsAnchorWhenMessageStillExists() {
        var store = ChatScrollStateStore()
        let expected = ChatScrollSnapshot(anchorMessageID: "message-4", followsLatest: false)
        store.save(expected, for: "session")

        XCTAssertEqual(
            store.restoration(
                for: "session",
                availableMessageIDs: ["message-3", "message-4", "message-5"]
            ),
            expected
        )
    }

    func testRestorationFallsBackToLatestWhenAnchorDisappears() {
        var store = ChatScrollStateStore()
        store.save(
            ChatScrollSnapshot(anchorMessageID: "deleted", followsLatest: false),
            for: "session"
        )

        XCTAssertEqual(
            store.restoration(for: "session", availableMessageIDs: ["message-1"]),
            .latest
        )
    }

    func testLatestSnapshotRemainsLatestRegardlessOfAvailableMessages() {
        var store = ChatScrollStateStore()
        store.save(ChatScrollSnapshot.latest, for: "session")

        XCTAssertEqual(
            store.restoration(for: "session", availableMessageIDs: []),
            .latest
        )
    }
}
```

- [ ] **Step 2: Run the targeted store tests and verify they fail for missing types**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,id=E174DE05-4FA3-43F6-8135-38F8835E2313' \
  -only-testing:ConduitTests/ChatScrollStateTests \
  -derivedDataPath /tmp/hermes-conduit-chat-scroll-red-derived \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected result: compilation fails because `ChatScrollStateStore` and `ChatScrollSnapshot` do not exist yet.

- [ ] **Step 3: Implement the minimal Foundation-only store**

Create `Conduit/Services/ChatScrollState.swift`:

```swift
import Foundation

struct ChatScrollSnapshot: Equatable {
    let anchorMessageID: String?
    let followsLatest: Bool

    static let latest = ChatScrollSnapshot(anchorMessageID: nil, followsLatest: true)
}

struct ChatScrollStateStore {
    private var snapshots: [String: ChatScrollSnapshot] = [:]

    mutating func save(_ snapshot: ChatScrollSnapshot, for sessionID: String) {
        let key = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        snapshots[key] = snapshot
    }

    func snapshot(for sessionID: String) -> ChatScrollSnapshot? {
        snapshots[sessionID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func restoration(
        for sessionID: String,
        availableMessageIDs: Set<String>
    ) -> ChatScrollSnapshot? {
        guard let snapshot = snapshot(for: sessionID) else { return nil }
        guard !snapshot.followsLatest else { return .latest }
        guard let anchor = snapshot.anchorMessageID,
              availableMessageIDs.contains(anchor) else {
            return .latest
        }
        return snapshot
    }
}
```

- [ ] **Step 4: Run the targeted store tests and verify they pass**

Run the same `xcodebuild test` command from Step 2. Expected result: four tests pass with zero failures.

- [ ] **Step 5: Commit the scroll store**

```bash
git add Conduit/Services/ChatScrollState.swift ConduitTests/ChatScrollStateTests.swift
git commit -m "test: add per-session chat scroll state"
```

---

### Task 4: Track and restore the semantic chat position

**Files:**
- Modify: `Conduit/Views/ChatView.swift` throughout `ChatView`

**Interfaces:**
- Consumes `ChatScrollStateStore` and `ChatScrollSnapshot` from Task 3.
- Produces scene-scoped restoration for the active session without changing `AppState` persistence or network reconciliation.

- [ ] **Step 1: Add view state and semantic scroll targets**

Add these properties to `ChatView`:

```swift
@Environment(\.scenePhase) private var scenePhase
@State private var topVisibleChatID: String?
@State private var chatScrollState = ChatScrollStateStore()
@State private var pendingScrollRestoration: PendingChatScrollRestoration?
```

Add a private equatable helper near the existing preference keys:

```swift
private struct PendingChatScrollRestoration: Equatable {
    let sessionID: String
    let snapshot: ChatScrollSnapshot
}
```

Add `.scrollTargetLayout()` to the existing `LazyVStack` and
`.scrollPosition(id: $topVisibleChatID, anchor: .top)` to the surrounding
`ScrollView`. Keep the existing `ScrollViewReader` and proxy-based explicit
scroll commands so the change does not rewrite the working latest-message
animation path.

- [ ] **Step 2: Write the scene lifecycle snapshot and restore hooks**

Add these methods to `ChatView`:

```swift
private func saveChatScrollPosition() {
    guard let sessionID = appState.activeSessionId else { return }
    let messageIDs = Set(appState.messages.map(\.id))
    let anchor = messageIDs.contains(topVisibleChatID ?? "")
        ? topVisibleChatID
        : nil
    chatScrollState.save(
        ChatScrollSnapshot(
            anchorMessageID: followsLatest ? nil : anchor,
            followsLatest: followsLatest
        ),
        for: sessionID
    )
}

private func beginChatScrollRestoration() {
    guard let sessionID = appState.activeSessionId,
          let snapshot = chatScrollState.snapshot(for: sessionID) else {
        pendingScrollRestoration = nil
        return
    }

    pendingScrollRestoration = PendingChatScrollRestoration(
        sessionID: sessionID,
        snapshot: snapshot
    )
    followsLatest = snapshot.followsLatest
}
```

Add an `onChange(of: scenePhase)` handler inside the `ScrollViewReader` content:

```swift
.onChange(of: scenePhase) { _, phase in
    switch phase {
    case .inactive, .background:
        saveChatScrollPosition()
    case .active:
        beginChatScrollRestoration()
    default:
        break
    }
}
```

- [ ] **Step 3: Restore only after the transcript has a usable layout**

Add `finishChatScrollRestorationIfReady(using:)` and call it from the existing
bottom-marker and viewport preference callbacks, alongside the notification
handoff checks:

```swift
private func finishChatScrollRestorationIfReady(using proxy: ScrollViewProxy) {
    guard let pending = pendingScrollRestoration,
          pending.sessionID == appState.activeSessionId else { return }

    if pending.snapshot.followsLatest {
        pendingScrollRestoration = nil
        followsLatest = true
        scrollToLatest(using: proxy)
        return
    }

    let availableIDs = Set(appState.messages.map(\.id))
    guard !availableIDs.isEmpty else { return }
    guard let resolved = chatScrollState.restoration(
        for: pending.sessionID,
        availableMessageIDs: availableIDs
    ) else {
        pendingScrollRestoration = nil
        return
    }

    pendingScrollRestoration = nil
    if resolved.followsLatest {
        followsLatest = true
        scrollToLatest(using: proxy)
    } else if let anchor = resolved.anchorMessageID {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
}
```

Do not let `updateBottomMarker` or `updateViewportBottom` set
`followsLatest = true` while a non-latest restoration is pending. This avoids
stale pre-refresh geometry re-enabling the latest-message scroll path before
the saved anchor is applied. Keep the existing notification handoff logic
separate and give it priority when `isOpeningNotificationSession` is true.

- [ ] **Step 4: Re-run the targeted state tests and build the chat UI**

Run both targeted test classes together:

```bash
xcodegen generate
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,id=E174DE05-4FA3-43F6-8135-38F8835E2313' \
  -only-testing:ConduitTests/ChatScrollStateTests \
  -only-testing:ConduitTests/ChatTextSelectionTests \
  -derivedDataPath /tmp/hermes-conduit-chat-interactions-targeted-derived \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected result: all targeted tests pass and the updated `ChatView` compiles.

- [ ] **Step 5: Commit semantic restoration**

```bash
git add Conduit/Views/ChatView.swift
git commit -m "fix: restore chat position after backgrounding"
```

---

### Task 5: Run the full verification suite and perform simulator acceptance testing

**Files:**
- Modify: none unless verification exposes a defect.
- Verify: all source and test files from Tasks 1–4.

- [ ] **Step 1: Regenerate the project and run the complete simulator suite**

```bash
xcodegen generate
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination 'platform=iOS Simulator,id=E174DE05-4FA3-43F6-8135-38F8835E2313' \
  -derivedDataPath /tmp/hermes-conduit-chat-interactions-final-derived \
  -resultBundlePath /tmp/hermes-conduit-chat-interactions-final-tests.xcresult \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected result: the complete suite passes with zero failures. Record the exact test count.

- [ ] **Step 2: Build and install the simulator app**

```bash
xcrun simctl install \
  E174DE05-4FA3-43F6-8135-38F8835E2313 \
  /tmp/hermes-conduit-chat-interactions-final-derived/Build/Products/Debug-iphonesimulator/Conduit.app
xcrun simctl launch E174DE05-4FA3-43F6-8135-38F8835E2313 com.milim.relay
plutil -p \
  /tmp/hermes-conduit-chat-interactions-final-derived/Build/Products/Debug-iphonesimulator/Conduit.app/Info.plist \
  | rg 'CFBundleShortVersionString|CFBundleVersion'
```

Expected result: the simulator launches the follow-up branch and reports version/build `0.1.2 (120)` inherited from the release branch.

- [ ] **Step 3: Verify partial text selection manually**

On the simulator, connect to the test Hermes gateway and long-press/select a substring in each of these surfaces: a user message, an assistant Markdown paragraph, a code block, and tool/approval text. Tap Copy and paste into a text field outside Conduit. Confirm the selection is partial, action buttons still work, and images/diagrams do not become selectable.

- [ ] **Step 4: Verify scroll restoration manually**

1. Open a long conversation and scroll into earlier history. Switch to another app, return after the foreground refresh completes, and confirm the same message remains at the reading position.
2. Repeat while the assistant is streaming and confirm the saved anchor survives the refreshed transcript.
3. Scroll to the bottom, background the app, and confirm new content appears at the latest edge on return.
4. Exercise a session whose saved anchor is no longer present and confirm the view deterministically falls back to the latest message.

- [ ] **Step 5: Review the final diff and verify the working tree**

```bash
git diff --check
git status --short --branch
git log -4 --oneline
```

Expected result: the working tree contains only the intentional source and test changes; the generated Xcode project remains ignored. Do not add a version bump, archive, TestFlight upload, or merge action to this branch until the user requests the next submission after reviewing the simulator behavior.

---

### Task 6: Harden restoration across reconciliation and transcript identity changes

**Reason:** Final review found that geometry readiness alone can race foreground reconciliation, `session.resume` can rotate a runtime ID for the same logical conversation, and `ChatMessage.id` is not stable across local/live/persisted transcript projections. Fix these without changing gateway/network semantics or the existing user-facing latest/notification behavior.

**Files:**
- Modify: `Conduit/Services/ChatScrollState.swift`
- Modify: `ConduitTests/ChatScrollStateTests.swift`
- Modify: `Conduit/Services/AppState.swift`
- Modify: `Conduit/Views/ChatView.swift`

**Interfaces and invariants:**

- Add a Foundation-only deterministic semantic anchor helper for `ChatMessage` rows. Its generated IDs must exclude `ChatMessage.id`, timestamp, author, and other source-specific volatile identifiers; include role/content and the stable activity fields needed to distinguish tool, clarify, approval, review, and attachment rows; and add an occurrence ordinal for duplicate fingerprints. The helper must produce equal anchors for the same logical message represented with different source IDs.
- Add a Foundation-only `ChatScrollSessionIdentity` value type containing a canonical session ID, equivalent runtime/catalog IDs, reconciliation state, and a settled revision. It must answer whether two IDs are equivalent without depending on SwiftUI.
- Expose the active identity from `AppState` as read-only published state. Populate equivalent IDs from the existing session catalog plus reconciliation requested/resolved IDs. Preserve the canonical ID while `session.resume` rotates a runtime ID for the same logical session. Increment the settled revision when existing reconciliation work settles; do not alter RPC payloads, network reconciliation decisions, or persistence formats.
- In `ChatView`, use semantic anchor IDs as scroll targets and use the canonical session ID for scroll-state keys and the latest-message anchor. Keep `ForEach` rendering identity and existing controls intact.
- Do not finish a non-latest restoration until the active identity is no longer reconciling and its settled revision has advanced past the revision observed when foreground restoration was requested. Re-check from identity/revision changes as well as geometry callbacks. If the scene becomes active without a reconciliation, the current revision may be used immediately.
- Treat a raw `activeSessionId` change as a user session switch only when the old and new IDs are not equivalent under the published identity. Runtime-ID rotation must not cancel a pending restoration or force latest. Deliberate user drag, explicit scroll-to-latest, notification handoff, and a genuinely different session must still cancel/override restoration.
- Keep iOS 17 APIs, iPhone/iPad orientation behavior, version/build metadata, whole-response/code copy buttons, latest-following behavior, and interactive non-text controls unchanged.

- [ ] **Step 1: Add failing pure tests**

Extend `ChatScrollStateTests` with coverage for:

- semantically identical user/assistant rows with different raw IDs producing equal anchors;
- duplicate semantic rows receiving distinct occurrence-qualified anchors;
- stable activity/attachment fields participating in the fingerprint;
- equivalent session IDs sharing one canonical identity while unrelated IDs do not;
- a pending restoration remaining blocked while reconciliation is active and becoming eligible only after the settled revision advances (using a pure helper if needed).

Run the focused test command before adding production implementations and record the expected compile/test failure.

- [ ] **Step 2: Implement the pure identity and anchor helpers**

Keep the helpers deterministic, bounded, and independent of SwiftUI. Preserve the existing `ChatScrollSnapshot` and `ChatScrollStateStore` behavior, changing only the anchor/session-key types needed to make restoration source-stable.

- [ ] **Step 3: Expose AppState reconciliation/session identity**

Connect the new value type to the already-existing `reconciliation`, `reconciliationToken`, active session catalog, and `session.resume` result flow. Ensure successful, failed, invalidated, and user-selected session paths cannot leave the published state claiming that reconciliation is active forever.

- [ ] **Step 4: Integrate the hardening into ChatView**

Replace raw message IDs in semantic scroll targets and snapshot availability checks; gate restoration on the published reconciliation identity; preserve notification/manual-latest/session-switch priority; and cancel pending restoration on deliberate user drag.

- [ ] **Step 5: Run targeted and full verification**

Run the two new/updated focused test classes, then the complete simulator suite. Record any unavailable XcodeGen/manual-authenticated UI limitation truthfully. Do not bump the version, archive, upload, or merge.

---

### Task 7: Close restoration correctness and streaming-cost gaps from final review

**Reason:** Final review identified an empty-authoritative-transcript deadlock, profile collisions in the in-memory scroll store, projection-dependent tool anchors, repeated full-transcript fingerprinting during streaming, and insufficient direct coverage of the identity resolver.

**Files:**
- Modify: `Conduit/Services/ChatScrollState.swift`
- Modify: `ConduitTests/ChatScrollStateTests.swift`
- Modify: `Conduit/Views/ChatView.swift`
- Modify: `Conduit/Services/AppState.swift`

**Requirements:**

- Once reconciliation has settled, allow a non-latest snapshot to resolve against an empty authoritative transcript. The existing store fallback must produce `.latest`, clear the pending restore, and let streaming/typing follow latest normally. Add a pure regression test.
- Make scroll-state keys and session identity profile-qualified. Equal IDs in different Hermes profiles must not be equivalent, overwrite snapshots, or preserve pending restoration/following state across `activeProfile` changes. Explicitly cancel/reset pending restoration on profile changes and add a pure test.
- Make tool-row semantic anchors independent of full/absent/truncated projection previews. Use only source-stable tool identity fields and occurrence ordering; add a test where the same tool has full input in one projection and missing or truncated input in another.
- Cache `ChatMessageScrollTargets` in `ChatView`/a small pure cache and refresh it only when message semantics change, not on every `streamingText` render. Keep rendering identity and scroll identity behavior unchanged. The cache must be initialized when the view appears and refreshed when `AppState.messages` changes; a bounded pure cache/update test is preferred.
- Route AppState’s catalog/requested/resolved canonical-ID calculation through a pure Foundation-only resolver, or add an equally direct pure seam, and test catalog aliases, runtime-ID rotation, unrelated sessions, profile separation, and reconciliation state/revision transitions. Do not alter RPC payloads or network semantics.
- Preserve all earlier constraints: iOS 17 APIs, latest-following, manual latest, notification priority, controls/copy actions, iPhone/iPad orientations, version/build `0.1.2 (120)`, and no archive/upload/merge.

- [ ] **Step 1: Add failing pure tests for all five findings**
- [ ] **Step 2: Implement the pure fixes and resolver/cache seams**
- [ ] **Step 3: Integrate profile-scoped identity and cached targets into AppState/ChatView**
- [ ] **Step 4: Run focused tests and full simulator verification**
