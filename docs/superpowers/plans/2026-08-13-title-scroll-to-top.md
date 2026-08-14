# Title Scroll-to-Top Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the active session title a reliable control that scrolls the current conversation to its first content without disturbing session restoration or latest-message behavior.

**Architecture:** Add a monotonic `AppState` request signal parallel to `chatScrollRequest`. Render the existing title surface inside a plain-styled toolbar button. `ChatView` adds a stable, session-scoped top anchor and handles each request by invalidating drag/restoration state, disabling latest-following, and scrolling to the top with one layout-delayed retry.

**Tech Stack:** Swift 5.9, SwiftUI 17, `ScrollViewReader`, `LazyVStack`, XCTest.

## Global Constraints

- Target iOS 17.0 with no new dependencies or navigation behavior changes.
- Keep the existing title styling and make the hit target a button with an accessibility label describing “Scroll to top of conversation.”
- Do not change the existing “scroll to latest” request or viewport restoration semantics except where the explicit top action must cancel them.
- Work for populated, empty, restored, and long lazy transcripts.
- The top request is monotonic so repeated title taps are observable even when the destination is already at the top.

## File Map

- Modify: `Conduit/Services/AppState.swift` — published top-scroll request and public request method.
- Modify: `Conduit/Views/RootView.swift` — title button and accessibility label.
- Modify: `Conduit/Views/ChatView.swift` — top anchor and request handler with cancellation/retry.
- Create: `ConduitTests/ChatTitleScrollTests.swift` — monotonic request signal tests.

### Task 1: Add the monotonic AppState command

**Files:**
- Create: `ConduitTests/ChatTitleScrollTests.swift`
- Modify: `Conduit/Services/AppState.swift`

**Interfaces:**
- `AppState` adds `@Published private(set) var chatScrollToTopRequest = 0` beside `chatScrollRequest`.
- `AppState` adds `func requestChatScrollToTop()` that increments the counter with `&+= 1`.

- [ ] **Step 1: Write the failing signal test**

```swift
@MainActor
final class ChatTitleScrollTests: XCTestCase {
    func testTitleScrollRequestIsMonotonicAndObservableForRepeatedTaps() {
        let appState = AppState(loadSavedConnection: false)
        let initial = appState.chatScrollToTopRequest

        appState.requestChatScrollToTop()
        appState.requestChatScrollToTop()

        XCTAssertEqual(appState.chatScrollToTopRequest, initial &+ 2)
    }
}
```

- [ ] **Step 2: Run the test and confirm the command is missing**

Run:

```bash
/Users/agrias/bin/bin/xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -only-testing:ConduitTests/ChatTitleScrollTests CODE_SIGNING_ALLOWED=NO
```

Expected: compilation failure for `chatScrollToTopRequest` or `requestChatScrollToTop`.

- [ ] **Step 3: Implement the published signal and rerun the test**

Place the property next to `chatScrollRequest` and the method next to `requestChatScrollToLatest()`. Do not reset the counter during a session switch; the view consumes changes, not an absolute value.

- [ ] **Step 4: Commit the AppState command**

```bash
git add Conduit/Services/AppState.swift ConduitTests/ChatTitleScrollTests.swift
git commit -m "feat: add chat scroll-to-top request"
```

### Task 2: Turn the toolbar title into an accessible control

**Files:**
- Modify: `Conduit/Views/RootView.swift`

**Interfaces:**
- The principal toolbar item remains the same title surface, but its root is `Button { appState.requestChatScrollToTop() } label: { ... }` with `.buttonStyle(.plain)`.

- [ ] **Step 1: Preserve the title surface inside a button**

Move the existing `Text(appState.activeSessionTitle)` font, line limit, padding, and `conduitGlassSurface` modifiers into the button label without changing visual values. Add `.accessibilityLabel("Scroll to top of conversation")` and keep the title text available to VoiceOver through the button label.

- [ ] **Step 2: Build the app and inspect the toolbar**

Run:

```bash
xcodebuild build -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' CODE_SIGNING_ALLOWED=NO
```

Expected: build succeeds, the title retains its glass surface, and the button does not inherit a default blue tint or unwanted navigation transition.

- [ ] **Step 3: Commit the toolbar control**

```bash
git add Conduit/Views/RootView.swift
git commit -m "feat: make chat title scroll to top"
```

### Task 3: Add the lazy-layout top anchor and request handler

**Files:**
- Modify: `Conduit/Views/ChatView.swift`
- Modify: `ConduitTests/ChatTitleScrollTests.swift`

**Interfaces:**
- `ChatView` adds a private `topAnchor` derived from the current `activeScrollSessionKey`, parallel to `bottomAnchor`.
- `ChatView` adds a private `scrollToTop(using:request:)` helper that guards pending restoration, scrolls without changing the transcript, and retries once after 150 ms. The retry captures the request integer and checks it against `appState.chatScrollToTopRequest` before scrolling.

- [ ] **Step 1: Add a stable top target inside `LazyVStack`**

Insert a `Color.clear.frame(height: 1).id(topAnchor)` as the first child of the existing `LazyVStack`, before `EmptyChatState` and message rows. Keep the current bottom anchor in the lazy layout and keep `.scrollTargetLayout()` unchanged. Derive `topAnchor` from the active profile/session scope so a previous session’s top target cannot be reused after a switch.

- [ ] **Step 2: Handle each top request with explicit state cancellation**

Add `.onChange(of: appState.chatScrollToTopRequest)` beside the existing latest-request handler:

```swift
.onChange(of: appState.chatScrollToTopRequest) { _, request in
    invalidateChatDrag()
    cancelAutomaticRestoration()
    followsLatest = false
    scrollToTop(using: proxy, request: request)
}
```

The handler must not call `scrollToLatest`, must not leave `chatResumeRestorationRequest` pending, and must not allow a delayed latest retry to win after the explicit top request.

- [ ] **Step 3: Implement a layout-delayed top scroll**

Use the same transaction style as restoration for the first scroll: no animation while changing the explicit destination, then one `Task { @MainActor in ... }` delayed by 150 ms that checks `!Task.isCancelled`, the request generation is still the latest observed value, and the active top anchor is still current before calling `proxy.scrollTo(topAnchor, anchor: .top)`. If the transcript is empty, the anchor remains valid and the request is still harmless.

- [ ] **Step 4: Keep viewport persistence coherent after the top action**

After the scroll settles, allow `topVisibleChatID` changes to flow through the existing `saveChatScrollPosition` path. If the top anchor itself is reported as visible, resolve the first message target before producing a non-latest snapshot; do not persist the synthetic anchor as a message ID. The next ordinary drag or session switch must continue using the existing restoration state machine.

- [ ] **Step 5: Run focused tests and commit the ChatView behavior**

```bash
/Users/agrias/bin/bin/xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -only-testing:ConduitTests/ChatTitleScrollTests \
  -only-testing:ConduitTests/ChatScrollStateTests \
  -only-testing:ConduitTests/AppStateChatResumeTests \
  CODE_SIGNING_ALLOWED=NO

git add Conduit/Views/ChatView.swift ConduitTests/ChatTitleScrollTests.swift
git commit -m "fix: scroll chat to top from the title"
```

### Task 4: Verify title behavior across transcript states

**Files:**
- No source changes unless verification exposes a specific request-generation or anchor identity defect.

- [ ] **Step 1: Run the full simulator test suite**

```bash
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `TEST SUCCEEDED`, including the existing rapid session-switch, restoration, and scroll-state tests.

- [ ] **Step 2: Manually verify the title control**

Scroll deep into a long conversation, tap the title, and confirm the first message is visible. Tap it repeatedly, tap during streaming, tap while a restored session is settling, and tap in an empty conversation. Confirm the title remains responsive, the latest-message button still works afterward, and the next session switch restores the correct session’s viewport rather than the synthetic top anchor.

- [ ] **Step 3: Verify accessibility and appearance**

Use VoiceOver to confirm the principal control announces “Scroll to top of conversation.” Repeat in light/dark mode and with larger Dynamic Type; the title remains single-line and the button hit target stays usable.
