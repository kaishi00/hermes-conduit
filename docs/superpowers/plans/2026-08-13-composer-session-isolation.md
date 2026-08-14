# Composer Session Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent composer crashes and synchronization stalls when switching sessions with text or attachments in the composer, while preserving drafts per session in memory.

**Architecture:** Move draft data into a small profile/session-keyed in-memory store owned by `ComposerBar`, while treating first responder, slash suggestions, measured height, and UIKit identity as transient editor state. A session change saves the old draft, tears down the old UIKit editor, restores the destination draft without focusing it, and ignores callbacks from the old editor generation.

**Tech Stack:** Swift 5.9, SwiftUI 17, UIKit `UITextView`, XCTest.

## Global Constraints

- Target iOS 17.0 with no new dependencies or server protocol changes.
- Preserve drafts per profile/session in memory, including attachment metadata and temporary-file URIs; do not retain first-responder state across sessions.
- The restored destination composer must not auto-focus.
- Programmatic text restoration must not trigger user-edit callbacks, slash suggestion churn, or stale context work.
- Existing AppState request-generation, client/session guards, rapid-switch tests, and cancellation tests remain authoritative.
- Change `AppState.swift` only if a new failing lifecycle test proves the existing reconciliation ownership is incomplete.

## File Map

- Create: `Conduit/Views/Components/ComposerDraftStore.swift` — profile/session key and bounded in-memory draft storage.
- Modify: `Conduit/Views/Components/ComposerBar.swift` — store ownership, session handoff, editor generation, and draft restoration.
- Modify: `Conduit/Views/Components/ComposerPasteTextView.swift` — programmatic-update guard and UIKit teardown.
- Create: `ConduitTests/ComposerDraftStoreTests.swift` — storage isolation and replacement tests.
- Modify: `ConduitTests/ComposerPasteTextViewTests.swift` — editor callback/teardown regression coverage.
- Modify: `ConduitTests/AppStateChatResumeTests.swift` only if a focused composer/session test demonstrates an AppState defect.

### Task 1: Create the profile/session draft store with explicit isolation

**Files:**
- Create: `ConduitTests/ComposerDraftStoreTests.swift`
- Create: `Conduit/Views/Components/ComposerDraftStore.swift`

**Interfaces:**
- `ComposerDraft` is `Equatable` and contains `text: String` and `attachments: [Attachment]`.
- `ComposerDraftKey` is `Hashable` and contains `profile: String` and `sessionID: String`.
- `ComposerDraftStore` is `@MainActor final class` with `init(capacity: Int = 12)`, `draft(for:)`, `save(_:for:)`, `removeDraft(for:)`, and `removeAll()`.
- The store treats the key `sessionID == "new-conversation"` as the draft bucket for a new unsaved conversation.

- [ ] **Step 1: Write failing storage-isolation tests**

```swift
@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    func testDraftsAreIsolatedByProfileAndSession() {
        let store = ComposerDraftStore(capacity: 12)
        let first = ComposerDraftKey(profile: "default", sessionID: "one")
        let second = ComposerDraftKey(profile: "default", sessionID: "two")
        let otherProfile = ComposerDraftKey(profile: "work", sessionID: "one")
        let draft = ComposerDraft(text: "draft one", attachments: [])

        store.save(draft, for: first)

        XCTAssertEqual(store.draft(for: first), draft)
        XCTAssertEqual(store.draft(for: second), ComposerDraft.empty)
        XCTAssertEqual(store.draft(for: otherProfile), ComposerDraft.empty)
    }

    func testSavingEmptyDraftRemovesTheBucket() {
        let store = ComposerDraftStore()
        let key = ComposerDraftKey(profile: "default", sessionID: "one")
        store.save(ComposerDraft(text: "text", attachments: []), for: key)
        store.save(.empty, for: key)

        XCTAssertEqual(store.draft(for: key), .empty)
    }

    func testStoreEvictsTheOldestBucketWhenCapacityIsExceeded() {
        let store = ComposerDraftStore(capacity: 1)
        let first = ComposerDraftKey(profile: "default", sessionID: "one")
        let second = ComposerDraftKey(profile: "default", sessionID: "two")
        store.save(ComposerDraft(text: "one", attachments: []), for: first)
        store.save(ComposerDraft(text: "two", attachments: []), for: second)

        XCTAssertEqual(store.draft(for: first), .empty)
        XCTAssertEqual(store.draft(for: second).text, "two")
    }
}
```

- [ ] **Step 2: Run the tests and confirm the store types are missing**

Run:

```bash
/Users/agrias/bin/bin/xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -only-testing:ConduitTests/ComposerDraftStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: compilation failure for the missing store types.

- [ ] **Step 3: Implement bounded in-memory storage**

Use a dictionary plus an insertion/access-order array. `save(.empty, for:)` removes the key; non-empty saves replace the existing value and move the key to the end. When the count exceeds `capacity`, remove the oldest key. `draft(for:)` returns `.empty` without creating a bucket and moves a hit to the end. This store owns no UIKit objects and performs no asynchronous work.

- [ ] **Step 4: Run the store tests and commit**

Expected: isolation, empty-removal, replacement, and capacity tests pass.

```bash
git add Conduit/Views/Components/ComposerDraftStore.swift ConduitTests/ComposerDraftStoreTests.swift
git commit -m "feat: isolate composer drafts by session"
```

### Task 2: Make the UIKit bridge safe during programmatic handoff

**Files:**
- Modify: `Conduit/Views/Components/ComposerPasteTextView.swift`
- Modify: `ConduitTests/ComposerPasteTextViewTests.swift`

**Interfaces:**
- `ComposerPasteTextView` gains an `editorIdentity: UUID` input used to identify a mounted editor generation.
- `Coordinator` gains `isApplyingProgrammaticState` and `isActive` flags plus `apply(text:to:)` and `deactivate(textView:)` helpers.
- `dismantleUIView` removes the delegate/callback closures and resigns first responder before the old bridge is released.

- [ ] **Step 1: Add failing callback tests**

Test that a text change delivered while `isApplyingProgrammaticState` is true does not mutate the SwiftUI binding, and that a deactivated coordinator does not publish focus or measured-height changes. Keep the existing paste metadata/error tests unchanged.

```swift
@MainActor
func testProgrammaticTextApplicationDoesNotPublishAsUserEditing() {
    var value = "old"
    let view = ComposerPasteTextView(
        text: Binding(get: { value }, set: { value = $0 }),
        isFocused: .constant(false),
        measuredHeight: .constant(44),
        enabled: true,
        onPastedImage: { _ in },
        onPastedImageError: { _ in },
        editorIdentity: UUID()
    )
    let coordinator = ComposerPasteTextView.Coordinator(view)
    coordinator.isApplyingProgrammaticState = true

    let textView = ImagePasteTextView()
    textView.text = "restored"
    coordinator.textViewDidChange(textView)

    XCTAssertEqual(value, "old")
}
```

- [ ] **Step 2: Run the test and confirm the guard/identity API is absent**

Run the focused composer test command. Expected: compilation failure for the new initializer field or coordinator flags.

- [ ] **Step 3: Implement guarded updates and deterministic teardown**

In `updateUIView`, call `coordinator.apply(text:to:)` instead of assigning `uiView.text` directly. The helper wraps the assignment in `isApplyingProgrammaticState`, restores a clamped selection, and updates the editor identity. `textViewDidChange`, `textViewDidBeginEditing`, and `textViewDidEndEditing` return immediately when inactive or applying programmatic state. `dismantleUIView` clears the closures and delegate, marks the coordinator inactive, and calls `resignFirstResponder`.

- [ ] **Step 4: Run the full composer bridge tests and commit**

```bash
git add Conduit/Views/Components/ComposerPasteTextView.swift ConduitTests/ComposerPasteTextViewTests.swift
git commit -m "fix: isolate composer UIKit callbacks during handoff"
```

### Task 3: Save, tear down, and restore drafts at the session boundary

**Files:**
- Modify: `Conduit/Views/Components/ComposerBar.swift`
- Modify: `Conduit/Views/Components/ComposerPasteTextView.swift`
- Modify: `ConduitTests/ComposerDraftStoreTests.swift`

**Interfaces:**
- `ComposerBar` owns `@State private var draftStore = ComposerDraftStore()`, `@State private var editorIdentity = UUID()`, and `@State private var loadedDraftKey: ComposerDraftKey?`.
- `ComposerBar` provides `composerDraftKey(for:)`, `saveDraft(for:)`, `loadDraft(for:)`, and `handoffComposer(to:)` helpers.
- `ComposerPasteTextView` is rendered with `.id(editorIdentity)` and receives the identity input.

- [ ] **Step 1: Add a failing handoff test around the pure key/draft operations**

Cover this sequence: save `"draft A"` under session A, load an empty session B, save `"draft B"`, switch back to A, and assert the exact text and attachment arrays are restored independently. Add a test that a profile switch uses a separate key even if the session IDs match.

- [ ] **Step 2: Run the test and confirm the ComposerBar handoff helpers are not present**

Run the focused composer command. Expected: failure until the key and store integration exists.

- [ ] **Step 3: Implement the session-change transaction**

On first appearance, load the active session’s draft and set `loadedDraftKey`. Observe the combined `ComposerDraftKey(profile: appState.activeProfile, sessionID: appState.activeSessionId ?? "new-conversation")`, so both a session switch and a profile switch enter the same handoff. Save `loadedDraftKey` before changing any local state, set `isFocused = false`, set `isShowingSlashSuggestions = false`, increment `editorIdentity`, restore the new key’s text/attachments, set `loadedDraftKey` to the destination, reset `composerTextHeight` to `ComposerPasteTextView.minimumHeight`, and leave `isFocused` false. Use `withAnimation` only for the same visual collapse already used by `collapseSubmittedDraft`; do not await a network operation in the handoff.

Use the active profile plus `activeSessionId ?? "new-conversation"` for the key. When a send succeeds, clear the current bucket; when a send fails and the current editor is still empty, restore the submitted draft as the existing method already does. Do not write drafts to `UserDefaults` or the server.

- [ ] **Step 4: Guard delayed context refresh and paste callbacks by session/editor identity**

Keep `.task(id: appState.activeSessionId)` for context refresh, but add a capture of the session ID and guard before applying any result in the callback path already protected by AppState. Capture `editorIdentity` in paste-image and paste-error closures; ignore a callback whose identity no longer matches the current editor. This prevents an image provider completing after a switch from mutating the destination composer.

- [ ] **Step 5: Run focused tests and commit the ComposerBar integration**

```bash
git add Conduit/Views/Components/ComposerBar.swift Conduit/Views/Components/ComposerPasteTextView.swift ConduitTests/ComposerDraftStoreTests.swift
git commit -m "fix: restore composer drafts per active session"
```

### Task 4: Verify the crash and synchronization regression against real session switches

**Files:**
- Modify: `ConduitTests/AppStateChatResumeTests.swift` only if a new test proves an AppState ownership defect.
- No other source changes without a failing test identifying the exact stale callback or transition.

- [ ] **Step 1: Run all focused session and composer tests**

```bash
/Users/agrias/bin/bin/xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -only-testing:ConduitTests/ComposerDraftStoreTests \
  -only-testing:ConduitTests/ComposerPasteTextViewTests \
  -only-testing:ConduitTests/AppStateChatResumeTests \
  CODE_SIGNING_ALLOWED=NO
```

Expected: the existing 63 AppState resume tests plus new composer tests pass, with `turnState` settling to `.idle` after the latest session switch.

- [ ] **Step 2: Exercise the user flow on Simulator**

Type multiline text and add an attachment in session A. Switch to session B repeatedly while the keyboard is visible and while a context refresh is pending. Confirm there is no crash, no stuck “Synchronizing” composer, no focus in B, and B’s draft is independent. Switch back to A and confirm the text/attachment draft returns. Repeat while a paste-image provider is still loading.

- [ ] **Step 3: Run the full suite and commit only evidence-backed AppState changes**

Run the full simulator test command from the selection plan. If AppState remains unchanged, keep the existing cancellation tests as the regression proof. If a new AppState test fails, fix the specific token/settlement path and rerun the focused plus full suites before committing.
