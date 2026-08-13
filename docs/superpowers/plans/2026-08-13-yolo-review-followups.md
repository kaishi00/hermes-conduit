# Session YOLO Review Follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve non-YOLO state from buffered `session.info` events during resume reconciliation and prevent Model Picker `onAppear` from resetting an in-progress YOLO draft.

**Architecture:** Resume reconciliation computes one explicit-YOLO authority decision and passes the resulting authoritative YOLO value only while replaying buffered `session.info` events. `applyRuntime` uses that value for YOLO while continuing to apply every other snapshot field normally. Model Picker draft seeding moves behind a small pure factory that returns a draft only when no initial baseline exists.

**Tech Stack:** Swift, SwiftUI, XCTest, Xcode Simulator.

## Global Constraints

- Do not change the Hermes protocol or profile-wide approval settings.
- A fresh resume with no newer local write remains authoritative for session YOLO.
- Buffered event replay must preserve running state, model, provider, context usage, and other non-YOLO fields.
- Repeated Model Picker appearances must not overwrite an existing YOLO draft or comparison baseline.
- Use simulator `6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355` with `CODE_SIGNING_ALLOWED=NO`.

---

### Task 1: Add the buffered-event regression (RED)

**Files:** `ConduitTests/SessionYoloPersistenceTests.swift`

Add `testBufferedConflictingSessionInfoPreservesNonYoloRuntimeFields`. Use the existing `SessionYoloResumeGate` and `makeAppState` seams. Return a resume snapshot with `model = "resume-model"`, `provider = "resume-provider"`, `context_percent = 10`, and `yolo = false`. While `openSession` is suspended, buffer a `.sessionInfo` snapshot with `model = "buffered-model"`, `provider = "buffered-provider"`, `context_percent = 42`, `running = true`, and `yolo = true`. After releasing the gate and awaiting `syncSession()`, assert `runtime.yolo == false`, `runtime.model == "buffered-model"`, `runtime.provider == "buffered-provider"`, and `runtime.contextPercent == 42`.

- [ ] **Step 1: Write the test before production changes.**
- [ ] **Step 2: Run the focused test and confirm the current whole-event filter fails because `runtime.model` remains `resume-model`.**

```bash
xcodebuild test -quiet -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-yolo-followup-red CODE_SIGNING_ALLOWED=NO \
  -only-testing:ConduitTests/SessionYoloPersistenceTests/testBufferedConflictingSessionInfoPreservesNonYoloRuntimeFields
```

### Task 2: Preserve buffered fields while anchoring YOLO authority (GREEN)

**Files:** `Conduit/Services/AppState.swift`

1. Extend the private `applyChatResume` overload with optional `reconcileExplicitYolo: Bool?`. Pass the already-computed reconciliation decision from `reconcile`; direct callers retain the existing baseline-derived default.
2. Extend `applyRuntime` with `authoritativeYolo: Bool? = nil` and use `authoritativeYolo ?? snapshot.yolo` only for the YOLO branch. Leave all other runtime field handling unchanged.
3. Extend `applyStreamEvent` with `authoritativeYolo: Bool? = nil`. In `.sessionInfo`, pass it through to `applyRuntime`; normal live callers use the default.
4. During buffered replay, pass `result.snapshot.yolo` only when the single `reconcileExplicitYolo` decision is true. Remove `filteringBufferedSessionInfo`; no buffered event is dropped merely because its YOLO value is stale.

- [ ] **Step 1: Implement the smallest production change described above.**
- [ ] **Step 2: Run the new regression plus the existing stale-ordering tests.**

```bash
xcodebuild test -quiet -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-yolo-followup-buffered-green CODE_SIGNING_ALLOWED=NO \
  -only-testing:ConduitTests/SessionYoloPersistenceTests/testBufferedConflictingSessionInfoPreservesNonYoloRuntimeFields \
  -only-testing:ConduitTests/SessionYoloPersistenceTests/testBufferedStaleSessionInfoCannotReapplyClearedOverride \
  -only-testing:ConduitTests/SessionYoloPersistenceTests/testStaleResumeSnapshotCannotClearJustPersistedOverride
```

- [ ] **Step 3: Commit the buffered replay fix.**

```bash
git add Conduit/Services/AppState.swift ConduitTests/SessionYoloPersistenceTests.swift
git commit -m "fix: preserve buffered session info fields"
```

### Task 3: Add the Model Picker draft regression (RED)

**Files:** `ConduitTests/ModelPickerTests.swift`

Add tests for a new pure factory on `ModelPickerYoloDraft`:

```swift
func testModelPickerYoloDraftSeedsWhenInitialBaselineIsMissing() {
    let draft = ModelPickerYoloDraft.seededIfNeeded(initial: nil, runtimeYolo: true)
    XCTAssertEqual(draft, ModelPickerYoloDraft(runtimeYolo: true))
}

func testModelPickerYoloDraftDoesNotReseedAnExistingBaseline() {
    let draft = ModelPickerYoloDraft.seededIfNeeded(initial: false, runtimeYolo: true)
    XCTAssertNil(draft)
}
```

- [ ] **Step 1: Add the tests before adding the factory.**
- [ ] **Step 2: Run `ModelPickerTests`; the current source must fail to compile because `seededIfNeeded` is missing.**

```bash
xcodebuild test -quiet -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-yolo-followup-picker-red CODE_SIGNING_ALLOWED=NO \
  -only-testing:ConduitTests/ModelPickerTests
```

### Task 4: Guard Model Picker draft initialization (GREEN)

**Files:** `Conduit/Views/ModelPickerView.swift`, `ConduitTests/ModelPickerTests.swift`

Add:

```swift
static func seededIfNeeded(initial: Bool?, runtimeYolo: Bool) -> ModelPickerYoloDraft? {
    guard initial == nil else { return nil }
    return ModelPickerYoloDraft(runtimeYolo: runtimeYolo)
}
```

Replace the unconditional `.onAppear` assignments with an `if let` call to this factory. When `initialYoloEnabled` already has a value, do nothing; when it is nil, assign both `yoloEnabled` and `initialYoloEnabled` from the returned draft. Keep the existing `loadModels` nil-baseline guard unchanged.

- [ ] **Step 1: Implement the factory and guarded `onAppear`.**
- [ ] **Step 2: Run all `ModelPickerTests`; the new and existing tests must pass.**
- [ ] **Step 3: Commit the picker fix.**

```bash
git add Conduit/Views/ModelPickerView.swift ConduitTests/ModelPickerTests.swift
git commit -m "fix: preserve Model Picker YOLO drafts"
```

### Task 5: Verify and hand off PR #55

**Files:** PR #55 description; the approved spec only if implementation wording needs correction.

- [ ] **Step 1: Run focused coverage for `SessionYoloPersistenceTests` and `ModelPickerTests`.**

```bash
xcodebuild test -quiet -project Conduit.xcodeproj -scheme Conduit \
  -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' \
  -derivedDataPath /tmp/conduit-yolo-followup-focused CODE_SIGNING_ALLOWED=NO \
  -only-testing:ConduitTests/SessionYoloPersistenceTests \
  -only-testing:ConduitTests/ModelPickerTests
```

- [ ] **Step 2: Run the complete XCTest suite and inspect `xcresulttool get test-results summary` for actual passed/failed counts.**
- [ ] **Step 3: Run `git diff --check`, inspect the final diff, and confirm the worktree is clean after commits.**
- [ ] **Step 4: Update PR #55 validation notes with the new behavior and final counts.**
- [ ] **Step 5: Push `codex/session-yolo-persistence` and verify the new CI/review checks; do not reply to or resolve comments unless explicitly requested.**
