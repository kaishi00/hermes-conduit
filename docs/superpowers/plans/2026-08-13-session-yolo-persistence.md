# Implementation Plan: Persist Session YOLO Overrides

**Goal:** Persist an explicit YOLO choice per normalized profile and canonical conversation, restore it across turns/backgrounding/relaunch, and prevent it from leaking between sessions.

**Architecture:** Add an injectable `UserDefaults`-backed `SessionYoloStore` with three states (`true`, `false`, absent). Resolve the active canonical session through the existing chat identity/catalog seam, then apply local override > explicit session snapshot `yolo` > profile `approvalsMode`.

**Tech Stack:** Swift, SwiftUI `AppState`, UserDefaults/JSON Codable storage, XCTest, XcodeGen, iOS Simulator.

## Tasks

- [ ] 1. Add store and AppState regression tests first (RED)
  - Add `ConduitTests/SessionYoloStoreTests.swift` with isolated UserDefaults coverage for absent, `true`, and `false` values, plus profile/session isolation and round-trip persistence.
  - Add focused AppState coverage in a dedicated `ConduitTests/SessionYoloPersistenceTests.swift` for:
    - a stored session override winning over a later snapshot containing only `approvals_mode`;
    - no override using explicit `snapshot.yolo`, then `approvals_mode` when session YOLO is omitted;
    - switching from overridden session A to unoverridden session B and back without leaking A's value;
    - canonicalizing an alternate runtime/session ID to the catalog's canonical session ID;
    - a failed YOLO gateway operation leaving both the store and visible runtime unchanged.
  - Use the existing `AppState` test constructor seams and an isolated defaults suite; add the `setSessionYolo` lifecycle operation seam before wiring the failure test rather than opening a real socket.
  - Refresh the generated project with `/Users/agrias/bin/bin/xcodegen generate`, then run both new test classes before adding production types:
    `xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination 'platform=iOS Simulator,id=E174DE05-4FA3-43F6-8135-38F8835E2313' -derivedDataPath /tmp/conduit-yolo-red CODE_SIGNING_ALLOWED=NO -only-testing:ConduitTests/SessionYoloStoreTests -only-testing:ConduitTests/SessionYoloPersistenceTests`
  - Confirm the tests fail to compile or fail assertions because `SessionYoloStore` and the persistence path do not yet exist.

- [ ] 2. Implement the injectable persistence store
  - Add `Conduit/Services/SessionYoloStore.swift`.
  - Inject `UserDefaults` and a storage key; encode a profile/session-keyed `[String: Bool]` payload so explicit `false` is preserved and an absent key remains distinguishable from false.
  - Normalize profile and session components using the existing `ChatScrollSessionKey` identity normalization, reject invalid/empty keys, and expose read/write operations suitable for isolated tests.
  - Keep the store limited to session YOLO overrides; do not mutate or reuse the profile-wide approval settings.

- [ ] 3. Wire AppState lifecycle, canonical identity, and precedence
  - In `Conduit/Services/AppState.swift`, inject a `SessionYoloStore` (defaulting to one backed by the AppState defaults) without breaking existing test constructors.
  - Add a helper that resolves the active canonical session ID with `ChatSessionPersistenceIdentity.canonicalID`, `activeChatScrollSessionIdentity`, the session/cron catalog, and `activeProfile`.
  - Apply the local override when resuming a session and whenever runtime snapshots arrive, while preserving the existing `snapshot.yolo` over `approvalsMode` fallback when no local override exists. Pass the resumed session ID explicitly where that avoids resolving a stale active ID.
  - Recompute/clear the session-local visible state on profile/session transitions so switching sessions cannot retain the previous session's override; a session without an override must use its own snapshot/global fallback.
  - Extend `ChatResumeLifecycleOperations` with an injectable session-YOLO setter if required by the failure test, and have `setYoloMode(_:)` call it or the real `HermesClient` method first.
  - Persist the boolean and update `runtime.yolo` only after the gateway call succeeds. Preserve existing error handling and leave persistence/runtime unchanged on failure.
  - Cover relaunch by constructing a new AppState/store against the same defaults suite and restoring the same conversation.

- [ ] 4. Run focused verification (GREEN)
  - Run the store and AppState-focused tests, then the Hermes/client tests if the lifecycle seam changes:
    `xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination 'platform=iOS Simulator,id=E174DE05-4FA3-43F6-8135-38F8835E2313' -derivedDataPath /tmp/conduit-yolo-focused CODE_SIGNING_ALLOWED=NO -only-testing:ConduitTests/SessionYoloStoreTests -only-testing:ConduitTests/AppStateChatResumeTests -only-testing:ConduitTests/HermesClientTests`
  - Confirm true/false/absent semantics, profile/session isolation, canonical IDs, precedence, session switching, relaunch, and failure behavior.
  - Review the diff for accidental changes to global approval settings or unrelated runtime fields.

- [ ] 5. Verify the branch and prepare the PR
  - Refresh `Conduit.xcodeproj` with `/Users/agrias/bin/bin/xcodegen generate` after the final source changes.
  - Run the full XCTest suite in the iOS Simulator and record the final test count/result.
  - Run `git diff --check`, inspect `git diff main...HEAD`, and confirm only the YOLO persistence implementation, tests, and plan/spec documentation are present.
  - Commit the implementation as `fix: persist session YOLO overrides`.
  - Push `codex/session-yolo-persistence` and open its PR against `main` with a summary, precedence rule, failure behavior, and test evidence.
