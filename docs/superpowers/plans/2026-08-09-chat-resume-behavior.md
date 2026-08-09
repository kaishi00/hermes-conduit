# Chat Resume Behavior Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a device-local return behavior that either restores the exact conversation and reading position or deliberately opens the newest chat at its bottom across foregrounding and cold launch.

**Architecture:** A focused `ChatResumeCoordinator` composes a pure session-selection policy with a versioned `ChatResumeStore`. `AppState` remains authoritative for catalog and transcript reconciliation, while `ChatView` only reports stable viewport snapshots and applies generation-scoped restoration requests after reconciliation settles.

**Tech Stack:** Swift 5.9, SwiftUI, Foundation `UserDefaults`/`Codable`, XCTest, XcodeGen, iOS 17+

## Global Constraints

- **Continue where I left off** is the default for existing and new installations.
- The preference and viewport snapshots are device-local and must not change Hermes profile configuration.
- Notification taps, explicit session/profile choices, new-conversation actions, user scrolling, and message submission override automatic restoration.
- `RootView` is the only scene-phase observer after this change.
- Resume metadata must never block login, connection, session selection, or manual navigation.
- The store retains at most 100 snapshots and treats corrupt or unknown-version data as empty/default state.
- Runtime, stored, and alternate session IDs must resolve to one canonical stored identity.
- Do not add dependencies or raise the iOS 17.0 deployment target.
- Preserve unrelated user changes; implementation stays in `/private/tmp/hermes-conduit-chat-scroll-restoration-fix`.
- Never hardcode a Simulator model. Before test commands, resolve `CONDUIT_SIMULATOR_ID` with the same available-device JSON selection used by `.github/workflows/ci.yml`:

```bash
CONDUIT_SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if "iPhone" in device["name"]:
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit(1)
')
```

## File map

- Create `Conduit/Services/ChatResumePolicy.swift`: behavior enum, sync purpose, pure automatic-session resolver, and viewport fallback resolver.
- Create `Conduit/Services/ChatResumeStore.swift`: versioned device-local payload, one-time legacy active-session import, snapshot conversion, pruning, and explicit flush.
- Create `Conduit/Services/ChatResumeCoordinator.swift`: lifecycle freeze/thaw, 300 ms write scheduling, restoration generations, and restoration request production.
- Create `ConduitTests/ChatResumePolicyTests.swift`: session-selection and viewport-resolution policy tests.
- Create `ConduitTests/ChatResumeStoreTests.swift`: persistence, migration, corruption, versioning, and pruning tests.
- Create `ConduitTests/ChatResumeCoordinatorTests.swift`: lifecycle ordering, freeze, cancellation, and cold-launch restoration tests.
- Modify `Conduit/Services/ChatScrollState.swift`: make persisted anchor conversion reusable and remove in-memory ownership superseded by the coordinator.
- Modify `Conduit/Services/AppState.swift`: own the coordinator, distinguish automatic return from recovery sync, migrate active-session persistence, and publish restoration requests.
- Modify `Conduit/Views/ChatView.swift`: report stable snapshots, consume restoration requests, and remove its independent scene observer/store.
- Modify `Conduit/Views/AuxiliaryViews.swift`: expose the device-local return behavior in Chat settings.
- Modify `Conduit/Views/RootView.swift`: pass the settings save action and remain the sole scene-phase source.
- Modify `ConduitTests/ChatScrollStateTests.swift`: retain semantic-anchor coverage while removing tests tied to superseded local-store ownership.

---

### Task 0: Establish the PR #19 baseline

**Files:**
- Verify only; do not modify production or test files.

**Interfaces:**
- Consumes: current `agent/chat-scroll-restoration-fix` branch at design commit `7ebdd59` or its descendant.
- Produces: a known-green baseline before any TDD change.

- [ ] **Step 1: Confirm the isolated worktree and branch state**

Run:

```bash
git status --short --branch
git worktree list
```

Expected: the current directory is `/private/tmp/hermes-conduit-chat-scroll-restoration-fix`, branch `agent/chat-scroll-restoration-fix` is checked out only there, and only the committed plan/design documentation differs from the remote branch.

- [ ] **Step 2: Regenerate the project and run the existing full suite**

Resolve `CONDUIT_SIMULATOR_ID` using the Global Constraints command, then run:

```bash
xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER=""
```

Expected: all existing tests pass. If any existing test fails, stop implementation and report the baseline failure separately rather than attributing it to the first TDD change.

- [ ] **Step 3: Confirm regeneration did not introduce an unintended diff**

Run:

```bash
git status --short
git diff --check
```

Expected: only intentional XcodeGen output, if any, is present. Do not create a baseline commit.

---

### Task 1: Pure return behavior and session-selection policy

**Files:**
- Create: `Conduit/Services/ChatResumePolicy.swift`
- Create: `ConduitTests/ChatResumePolicyTests.swift`

**Interfaces:**
- Produces: `ChatResumeBehavior`, `ChatResumeSyncPurpose`, `ChatResumeSessionResolver.target(in:behavior:purpose:savedSessionID:currentSessionID:)`.
- Consumes: existing `SessionSummary`, `SessionSource`, and catalog ordering (most recent first).

- [ ] **Step 1: Write failing selection-policy tests**

Create `ConduitTests/ChatResumePolicyTests.swift` with a local session factory and the exact A/B regression:

```swift
import XCTest
@testable import Conduit

final class ChatResumePolicyTests: XCTestCase {
    private func session(
        _ id: String,
        alternates: [String] = [],
        source: SessionSource = .chat
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternates,
            title: id,
            model: "Hermes",
            updatedLabel: "now",
            profile: "default",
            source: source,
            isActive: false,
            isArchived: false,
            lineageRootId: nil
        )
    }

    func testContinueReturnsSavedConversationWhenAnotherConversationIsNewer() {
        let newestB = session("stored-b", alternates: ["runtime-b"])
        let savedA = session("stored-a", alternates: ["runtime-a"])

        let selected = ChatResumeSessionResolver.target(
            in: [newestB, savedA],
            behavior: .continueWhereLeftOff,
            purpose: .automaticReturn,
            savedSessionID: "runtime-a",
            currentSessionID: "runtime-a"
        )

        XCTAssertEqual(selected?.id, "stored-a")
    }

    func testLatestReturnDeliberatelyIgnoresSavedConversation() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-b"), session("stored-a")],
            behavior: .latestActivity,
            purpose: .automaticReturn,
            savedSessionID: "stored-a",
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(selected?.id, "stored-b")
    }

    func testRecoverySyncPreservesCurrentConversationRegardlessOfPreference() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("stored-b"), session("stored-a")],
            behavior: .latestActivity,
            purpose: .preserveCurrent,
            savedSessionID: "stored-a",
            currentSessionID: "stored-a"
        )

        XCTAssertEqual(selected?.id, "stored-a")
    }

    func testUnavailableSavedConversationFallsBackToNewestOrdinaryChat() {
        let selected = ChatResumeSessionResolver.target(
            in: [session("cron", source: .cron), session("stored-b")],
            behavior: .continueWhereLeftOff,
            purpose: .automaticReturn,
            savedSessionID: "deleted-a",
            currentSessionID: "deleted-a"
        )

        XCTAssertEqual(selected?.id, "stored-b")
    }
}
```

- [ ] **Step 2: Regenerate the project and run the new tests to verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -only-testing:ConduitTests/ChatResumePolicyTests CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `ChatResumeBehavior`, `ChatResumeSyncPurpose`, and `ChatResumeSessionResolver` do not exist.

- [ ] **Step 3: Implement the minimal pure policy**

Create `Conduit/Services/ChatResumePolicy.swift`:

```swift
import Foundation

enum ChatResumeBehavior: String, Codable, CaseIterable {
    case continueWhereLeftOff
    case latestActivity
}

enum ChatResumeSyncPurpose: Equatable {
    case automaticReturn
    case preserveCurrent
}

enum ChatResumeSessionResolver {
    static func target(
        in catalog: [SessionSummary],
        behavior: ChatResumeBehavior,
        purpose: ChatResumeSyncPurpose,
        savedSessionID: String?,
        currentSessionID: String?
    ) -> SessionSummary? {
        let requestedID = purpose == .preserveCurrent ? currentSessionID : savedSessionID
        if purpose == .preserveCurrent || behavior == .continueWhereLeftOff,
           let requestedID,
           let matched = catalog.first(where: {
               $0.id == requestedID || $0.alternateIds.contains(requestedID)
           }) {
            return matched
        }
        return catalog.first(where: { $0.source == .chat })
    }
}
```

- [ ] **Step 4: Add edge tests and run GREEN**

Add these cases to `ChatResumePolicyTests`:

```swift
func testLatestReturnsNilWhenNoOrdinaryChatExists() {
    XCTAssertNil(ChatResumeSessionResolver.target(
        in: [session("cron", source: .cron)],
        behavior: .latestActivity,
        purpose: .automaticReturn,
        savedSessionID: "cron",
        currentSessionID: "cron"
    ))
}

func testRecoveryMatchesAlternateCurrentID() {
    let selected = ChatResumeSessionResolver.target(
        in: [session("stored-a", alternates: ["runtime-a"])],
        behavior: .latestActivity,
        purpose: .preserveCurrent,
        savedSessionID: nil,
        currentSessionID: "runtime-a"
    )
    XCTAssertEqual(selected?.id, "stored-a")
}

func testContinueCanRestoreSavedCronConversation() {
    let selected = ChatResumeSessionResolver.target(
        in: [session("stored-b"), session("cron-a", source: .cron)],
        behavior: .continueWhereLeftOff,
        purpose: .automaticReturn,
        savedSessionID: "cron-a",
        currentSessionID: "cron-a"
    )
    XCTAssertEqual(selected?.id, "cron-a")
}
```

Rerun the Step 2 command. Expected: all `ChatResumePolicyTests` pass.

- [ ] **Step 5: Commit the policy**

```bash
git add Conduit/Services/ChatResumePolicy.swift ConduitTests/ChatResumePolicyTests.swift Conduit.xcodeproj/project.pbxproj
git commit -m "feat: define chat resume selection policy"
```

---

### Task 2: Versioned device-local resume store

**Files:**
- Create: `Conduit/Services/ChatResumeStore.swift`
- Create: `ConduitTests/ChatResumeStoreTests.swift`
- Modify: `Conduit/Services/ChatScrollState.swift`

**Interfaces:**
- Consumes: `ChatResumeBehavior`, `ChatScrollSessionKey`, `ChatScrollSnapshot`, and `ChatScrollAnchorMetadata`.
- Produces: `ChatResumeStore.behavior`, `setBehavior(_:)`, `lastSessionID(for:)`, `setLastSessionID(_:for:)`, `snapshot(for:)`, `save(_:for:at:)`, `migrateSnapshot(from:to:)`, `clearResumeState()`, and `flush()`.

- [ ] **Step 1: Write failing store tests with isolated defaults**

Create `ConduitTests/ChatResumeStoreTests.swift`:

```swift
import XCTest
@testable import Conduit

final class ChatResumeStoreTests: XCTestCase {
    private func defaults() -> (UserDefaults, String) {
        let suite = "ChatResumeStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testUnsavedBehaviorDefaultsToContinueWhereLeftOff() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ChatResumeStore(defaults: defaults).behavior, .continueWhereLeftOff)
    }

    func testPreferenceSessionAndAnchorSurviveStoreRecreation() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let snapshot = ChatScrollSnapshot(
            anchorMessageID: "anchor-12",
            followsLatest: false,
            anchorMetadata: .init(fingerprint: "fingerprint", duplicateCount: 1),
            anchorSourceMessageID: "source-12"
        )
        let store = ChatResumeStore(defaults: defaults)

        store.setBehavior(.latestActivity)
        store.setLastSessionID("stored-a", for: "default")
        store.save(snapshot, for: key, at: Date(timeIntervalSince1970: 100))
        store.flush()

        let restored = ChatResumeStore(defaults: defaults)
        XCTAssertEqual(restored.behavior, .latestActivity)
        XCTAssertEqual(restored.lastSessionID(for: "default"), "stored-a")
        XCTAssertEqual(restored.snapshot(for: key), snapshot)
    }

    func testCorruptPayloadFallsBackWithoutThrowing() {
        let (defaults, suite) = defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: ChatResumeStore.defaultStorageKey)

        let store = ChatResumeStore(defaults: defaults)

        XCTAssertEqual(store.behavior, .continueWhereLeftOff)
        XCTAssertNil(store.lastSessionID(for: "default"))
    }
}
```

- [ ] **Step 2: Run the store tests to verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -only-testing:ConduitTests/ChatResumeStoreTests CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `ChatResumeStore` does not exist.

- [ ] **Step 3: Make scroll anchor values persistable without persisting messages**

Update the declarations in `ChatScrollState.swift`:

```swift
struct ChatScrollAnchorMetadata: Codable, Equatable { /* existing fields */ }
struct ChatScrollSessionKey: Codable, Hashable { /* existing normalization */ }
struct ChatScrollSnapshot: Codable, Equatable { /* existing fields */ }
```

Do not make `ChatMessage` or `ChatMessageScrollTarget` part of the stored payload.

- [ ] **Step 4: Implement the versioned store**

Create a `final class ChatResumeStore` with a private payload matching these exact persisted fields:

```swift
final class ChatResumeStore {
    static let defaultStorageKey = "conduit.chatResume.v1"
    static let schemaVersion = 1
    static let maximumSnapshots = 100

    private struct StoredSnapshot: Codable, Equatable {
        let key: ChatScrollSessionKey
        let snapshot: ChatScrollSnapshot
        let updatedAt: Date
    }

    private struct Payload: Codable, Equatable {
        let version: Int
        var behavior: ChatResumeBehavior
        var lastSessionIDsByProfile: [String: String]
        var snapshots: [StoredSnapshot]
    }

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = ChatResumeStore.defaultStorageKey,
        legacyActiveSessionsKey: String = "conduit.activeSessionIdsByProfile.v1"
    )
}
```

Load only payloads whose `version == schemaVersion`. If the storage key is absent, import `[String: String]` from `legacyActiveSessionsKey`, write a version-1 payload, and never consult the legacy key again. If the storage key exists but is corrupt or has an unknown version, replace it with an empty version-1 payload using continue mode; do not re-import legacy state. Normalize profiles through `ChatScrollSessionKey`, prune by descending `updatedAt`, and keep the newest 100 entries.

- [ ] **Step 5: Add migration, unknown-version, alias-migration, pruning, and clearing tests**

Add concrete tests with these assertions (use `JSONSerialization` for the unknown-version payload so tests do not access private store types):

```swift
func testLegacySessionMapImportsOnlyOnce() {
    let (defaults, suite) = defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["default": "stored-a"], forKey: "legacy")
    _ = ChatResumeStore(defaults: defaults, legacyActiveSessionsKey: "legacy")
    defaults.set(["default": "stored-b"], forKey: "legacy")

    XCTAssertEqual(
        ChatResumeStore(defaults: defaults, legacyActiveSessionsKey: "legacy").lastSessionID(for: "default"),
        "stored-a"
    )
}

func testUnknownVersionResetsToDefault() throws {
    let (defaults, suite) = defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let data = try JSONSerialization.data(withJSONObject: [
        "version": 999,
        "behavior": "latestActivity",
        "lastSessionIDsByProfile": ["default": "stored-a"],
        "snapshots": []
    ])
    defaults.set(data, forKey: ChatResumeStore.defaultStorageKey)

    XCTAssertEqual(ChatResumeStore(defaults: defaults).behavior, .continueWhereLeftOff)
}

func testPruningKeepsNewestHundredSnapshots() {
    let (defaults, suite) = defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ChatResumeStore(defaults: defaults)
    for index in 0...100 {
        store.save(
            .init(anchorMessageID: "anchor-\(index)", followsLatest: false),
            for: .init(profile: "default", sessionID: "session-\(index)"),
            at: Date(timeIntervalSince1970: TimeInterval(index))
        )
    }
    XCTAssertNil(store.snapshot(for: .init(profile: "default", sessionID: "session-0")))
    XCTAssertNotNil(store.snapshot(for: .init(profile: "default", sessionID: "session-100")))
}

func testClearResumeStatePreservesBehavior() {
    let (defaults, suite) = defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ChatResumeStore(defaults: defaults)
    store.setBehavior(.latestActivity)
    store.setLastSessionID("stored-a", for: "default")
    store.save(.latest, for: .init(profile: "default", sessionID: "stored-a"), at: Date())
    store.clearResumeState()

    XCTAssertEqual(store.behavior, .latestActivity)
    XCTAssertNil(store.lastSessionID(for: "default"))
    XCTAssertNil(store.snapshot(for: .init(profile: "default", sessionID: "stored-a")))
}
```

Add the alias migration assertion:

```swift
func testSnapshotMigratesFromRuntimeToCanonicalKey() {
    let (defaults, suite) = defaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ChatResumeStore(defaults: defaults)
    let runtime = ChatScrollSessionKey(profile: "default", sessionID: "runtime-a")
    let canonical = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
    let snapshot = ChatScrollSnapshot(
        anchorMessageID: "anchor-12",
        followsLatest: false,
        anchorMetadata: .init(fingerprint: "fingerprint", duplicateCount: 2),
        anchorSourceMessageID: "source-12"
    )
    store.save(snapshot, for: runtime, at: Date())

    store.migrateSnapshot(from: runtime, to: canonical)

    XCTAssertEqual(store.snapshot(for: canonical), snapshot)
}
```

- [ ] **Step 6: Run focused store and existing scroll tests**

Run:

```bash
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -only-testing:ConduitTests/ChatResumeStoreTests -only-testing:ConduitTests/ChatScrollStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: all store and scroll-state tests pass.

- [ ] **Step 7: Commit the store**

```bash
git add Conduit/Services/ChatResumeStore.swift Conduit/Services/ChatScrollState.swift ConduitTests/ChatResumeStoreTests.swift Conduit.xcodeproj/project.pbxproj
git commit -m "feat: persist chat resume state"
```

---

### Task 3: Focused lifecycle coordinator

**Files:**
- Create: `Conduit/Services/ChatResumeCoordinator.swift`
- Create: `ConduitTests/ChatResumeCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ChatResumeStore`, `ChatResumeSessionResolver`, `ChatScrollSessionIdentity`, and `ChatScrollSnapshot`.
- Produces: `ChatResumeRestorationRequest`, `selectTarget(in:profile:purpose:currentSessionID:)`, `recordViewport(_:for:)`, `freezeViewport()`, `reconciliationSettled(sessionKey:)`, `cancelRestoration()`, `completeRestoration(generation:)`, `clearResumeState()`, and `flush()`.

- [ ] **Step 1: Write failing lifecycle tests**

Create tests using isolated `UserDefaults`:

```swift
@MainActor
final class ChatResumeCoordinatorTests: XCTestCase {
    func testInactiveFreezeRejectsLateGeometryOverwrite() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let reading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)

        harness.coordinator.recordViewport(reading, for: key)
        harness.coordinator.freezeViewport()
        harness.coordinator.recordViewport(.latest, for: key)
        harness.coordinator.flush()

        XCTAssertEqual(harness.store.snapshot(for: key), reading)
    }

    func testContinueRequestIsEmittedOnlyAfterReconciliationSettles() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        let reading = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
        harness.store.save(reading, for: key, at: Date())
        harness.store.setLastSessionID("stored-a", for: "default")

        _ = harness.coordinator.selectTarget(
            in: [session("stored-b"), session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        XCTAssertNil(harness.coordinator.pendingRestoration)

        let request = harness.coordinator.reconciliationSettled(sessionKey: key)
        XCTAssertEqual(request?.destination, .snapshot(reading))
    }

    func testExplicitActionCancelsAnOlderGeneration() {
        let harness = makeHarness()
        let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
        _ = harness.coordinator.selectTarget(
            in: [session("stored-a")],
            profile: "default",
            purpose: .automaticReturn,
            currentSessionID: "stored-a"
        )
        let request = harness.coordinator.reconciliationSettled(sessionKey: key)!

        harness.coordinator.cancelRestoration()

        XCTAssertFalse(harness.coordinator.isCurrent(generation: request.generation))
    }
}
```

The harness returns `(coordinator, store, defaults, suite)` and removes its persistent domain in teardown.

- [ ] **Step 2: Run lifecycle tests to verify RED**

Run:

```bash
xcodegen generate
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -only-testing:ConduitTests/ChatResumeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because the coordinator and request types do not exist.

- [ ] **Step 3: Implement generation-scoped restoration requests**

Create these public module-internal types:

```swift
enum ChatResumeRestorationDestination: Equatable {
    case latest
    case snapshot(ChatScrollSnapshot)
}

struct ChatResumeRestorationRequest: Identifiable, Equatable {
    let generation: UInt64
    let sessionKey: ChatScrollSessionKey
    let destination: ChatResumeRestorationDestination
    var id: UInt64 { generation }
}

@MainActor
final class ChatResumeCoordinator {
    private(set) var pendingRestoration: ChatResumeRestorationRequest?
    var behavior: ChatResumeBehavior { store.behavior }

    init(store: ChatResumeStore)
    func setBehavior(_ behavior: ChatResumeBehavior)
    func lastSessionID(for profile: String) -> String?
    func rememberSessionID(_ sessionID: String?, for profile: String)
    func selectTarget(in catalog: [SessionSummary], profile: String, purpose: ChatResumeSyncPurpose, currentSessionID: String?) -> SessionSummary?
    func recordViewport(_ snapshot: ChatScrollSnapshot, for key: ChatScrollSessionKey)
    func migrateSnapshot(from oldKey: ChatScrollSessionKey, to newKey: ChatScrollSessionKey)
    func freezeViewport()
    func reconciliationSettled(sessionKey: ChatScrollSessionKey) -> ChatResumeRestorationRequest?
    func cancelRestoration()
    func completeRestoration(generation: UInt64)
    func isCurrent(generation: UInt64) -> Bool
    func clearResumeState()
    func flush()
}
```

`selectTarget` marks an automatic return as pending only for `.automaticReturn`. `reconciliationSettled` emits `.latest` for latest mode, otherwise emits the stored snapshot or `.latest`. Keep snapshot mutation frozen until the matching request completes or any explicit cancellation occurs. `setBehavior(_:)` cancels an in-flight restoration before saving the new behavior. `clearResumeState()` cancels work and delegates to the store while preserving the selected behavior.

- [ ] **Step 4: Add the 300 ms coalesced write without timing-dependent tests**

On accepted `recordViewport`, update the store's in-memory payload immediately, cancel the previous write task, and schedule:

```swift
pendingFlushTask = Task { [weak self] in
    do { try await Task.sleep(for: .milliseconds(300)) }
    catch { return }
    guard !Task.isCancelled else { return }
    self?.store.flush()
}
```

`freezeViewport()` and `flush()` cancel this task and call `store.flush()` synchronously. Tests should invoke `flush()` directly rather than sleep.

- [ ] **Step 5: Add latest-mode, cold-launch, fallback, and completion tests**

Add these explicit assertions to `ChatResumeCoordinatorTests`:

```swift
func testLatestModeSelectsNewestAndEmitsLatest() {
    let harness = makeHarness()
    harness.coordinator.setBehavior(.latestActivity)
    let selected = harness.coordinator.selectTarget(
        in: [session("stored-b"), session("stored-a")],
        profile: "default",
        purpose: .automaticReturn,
        currentSessionID: "stored-a"
    )
    let request = harness.coordinator.reconciliationSettled(
        sessionKey: .init(profile: "default", sessionID: selected!.id)
    )

    XCTAssertEqual(selected?.id, "stored-b")
    XCTAssertEqual(request?.destination, .latest)
}

func testColdLaunchRestoresPersistedSnapshot() {
    let harness = makeHarness()
    let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
    let snapshot = ChatScrollSnapshot(anchorMessageID: "anchor-12", followsLatest: false)
    harness.store.save(snapshot, for: key, at: Date())
    harness.store.setLastSessionID("stored-a", for: "default")
    harness.store.flush()
    let recreated = ChatResumeCoordinator(store: ChatResumeStore(defaults: harness.defaults))

    _ = recreated.selectTarget(
        in: [session("stored-b"), session("stored-a")],
        profile: "default",
        purpose: .automaticReturn,
        currentSessionID: nil
    )

    XCTAssertEqual(recreated.reconciliationSettled(sessionKey: key)?.destination, .snapshot(snapshot))
}

func testCompletingCurrentRequestAllowsViewportWritesAgain() {
    let harness = makeHarness()
    let key = ChatScrollSessionKey(profile: "default", sessionID: "stored-a")
    _ = harness.coordinator.selectTarget(
        in: [session("stored-a")],
        profile: "default",
        purpose: .automaticReturn,
        currentSessionID: "stored-a"
    )
    let request = harness.coordinator.reconciliationSettled(sessionKey: key)!
    harness.coordinator.completeRestoration(generation: request.generation)
    harness.coordinator.recordViewport(.latest, for: key)
    harness.coordinator.flush()

    XCTAssertEqual(harness.store.snapshot(for: key), .latest)
}
```

Add the missing-A coordinator boundary case:

```swift
func testMissingContinueTargetSelectsNewestChat() {
    let harness = makeHarness()
    harness.store.setLastSessionID("deleted-a", for: "default")

    let selected = harness.coordinator.selectTarget(
        in: [session("stored-b")],
        profile: "default",
        purpose: .automaticReturn,
        currentSessionID: "deleted-a"
    )

    XCTAssertEqual(selected?.id, "stored-b")
}
```

- [ ] **Step 6: Run all three focused resume suites**

Run:

```bash
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -only-testing:ConduitTests/ChatResumePolicyTests -only-testing:ConduitTests/ChatResumeStoreTests -only-testing:ConduitTests/ChatResumeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: all pass without fixed-delay test waits.

- [ ] **Step 7: Commit the coordinator**

```bash
git add Conduit/Services/ChatResumeCoordinator.swift ConduitTests/ChatResumeCoordinatorTests.swift Conduit.xcodeproj/project.pbxproj
git commit -m "feat: coordinate durable chat restoration"
```

---

### Task 4: Integrate automatic session selection with AppState

**Files:**
- Modify: `Conduit/Services/AppState.swift`
- Modify: `ConduitTests/ChatResumeCoordinatorTests.swift`

**Interfaces:**
- Consumes: all coordinator APIs from Task 3.
- Produces: `AppState.chatResumeBehavior`, `chatResumeRestorationRequest`, `setChatResumeBehavior(_:)`, `recordChatViewport(_:for:)`, `flushChatResumeViewport()`, `completeChatResumeRestoration(generation:)`, and `cancelChatResumeRestoration()` for Settings and ChatView.

- [ ] **Step 1: Add a failing test for automatic-versus-recovery sync intent**

Extend coordinator tests with:

```swift
func testRecoverySyncPreservesCurrentWhileAutomaticReturnUsesPreference() {
    let harness = makeHarness()
    harness.coordinator.setBehavior(.latestActivity)
    let catalog = [session("stored-b"), session("stored-a")]

    let automatic = harness.coordinator.selectTarget(
        in: catalog,
        profile: "default",
        purpose: .automaticReturn,
        currentSessionID: "stored-a"
    )
    harness.coordinator.cancelRestoration()
    let recovery = harness.coordinator.selectTarget(
        in: catalog,
        profile: "default",
        purpose: .preserveCurrent,
        currentSessionID: "stored-a"
    )

    XCTAssertEqual(automatic?.id, "stored-b")
    XCTAssertEqual(recovery?.id, "stored-a")
}
```

This protects send/interrupt recovery paths from unexpectedly changing sessions.

- [ ] **Step 2: Add coordinator-owned published surfaces to AppState**

Add:

```swift
@Published private(set) var chatResumeBehavior: ChatResumeBehavior = .continueWhereLeftOff
@Published private(set) var chatResumeRestorationRequest: ChatResumeRestorationRequest?
private let chatResumeCoordinator = ChatResumeCoordinator(store: ChatResumeStore())
```

At the start of `init()`, assign `chatResumeBehavior = chatResumeCoordinator.behavior`. Add forwarding methods that update the published request after `reconciliationSettled` and clear it only when the matching generation completes or cancellation occurs.

- [ ] **Step 3: Make the coordinator the sole active-session persistence source**

Remove `activeSessionIDsByProfileKey`, `activeSessionIDsByProfile`, and `migrateLegacyActiveSessionStateIfNeeded()` from `AppState`; Task 2 performs the one-time import. Change:

```swift
private func restoreActiveSessionState(for profile: String) {
    activeSessionId = chatResumeCoordinator.lastSessionID(for: profile)
    activeSessionTitle = activeSessionTitlesByProfile[profile] ?? "New conversation"
}
```

After canonicalizing inside `setActiveSessionState`, call `chatResumeCoordinator.rememberSessionID(persistedID, for: activeProfile)`. Keep title persistence in `activeSessionTitlesByProfile`.

In `disconnect()`, call `chatResumeCoordinator.clearResumeState()` and remove the obsolete active-session-map reset. This preserves the device-local behavior choice while preventing snapshots from one server being reused after connecting to another.

- [ ] **Step 4: Thread an explicit sync purpose through catalog reconciliation**

Replace the overloads with:

```swift
func syncSession() async {
    await syncSession(purpose: .preserveCurrent, using: nil)
}

private func syncSession(
    purpose: ChatResumeSyncPurpose,
    using existingReconciliationToken: UUID?
) async
```

After loading `allSessions`, choose the target through:

```swift
let target = chatResumeCoordinator.selectTarget(
    in: allSessions,
    profile: profile,
    purpose: purpose,
    currentSessionID: activeSessionId
)
```

Use `.automaticReturn` only for saved-connection launch, explicit connect completion, and foreground recovery. Keep `.preserveCurrent` for send/attachment/steer/interrupt error recovery, manual refresh, and profile switching.

- [ ] **Step 5: Preserve automatic purpose across reconnect retries**

Change signatures to:

```swift
private func scheduleReconnect(
    immediately: Bool = false,
    purpose: ChatResumeSyncPurpose = .preserveCurrent
)

func reconnect(
    purpose: ChatResumeSyncPurpose = .preserveCurrent
) async
```

Capture `purpose` in the retry task. Foreground health-check failure calls `reconnect(purpose: .automaticReturn)`; a failed automatic reconnect schedules another automatic retry. Other reconnect callers retain the default preserve-current behavior.

- [ ] **Step 6: Publish restoration only after successful reconciliation**

After `applyResume`, buffered-event replay, and `settleReconciliation(token)`, call a helper that:

1. obtains the canonical `activeChatScrollSessionIdentity.canonicalSessionKey`;
2. calls `chatResumeCoordinator.reconciliationSettled(sessionKey:)`;
3. assigns the result to `chatResumeRestorationRequest`.

Do not consume the pending automatic return on catalog or reconcile failure; retain it for the retry. Creating a new fallback session should publish `.latest` after the created session settles.

- [ ] **Step 7: Freeze viewport state from the single scene-phase path**

In `handleScenePhase`:

- call `chatResumeCoordinator.freezeViewport()` on `.inactive` before layout can collapse;
- retain presentation-cache flushing and reconciliation invalidation on `.background`;
- call `syncSession(purpose: .automaticReturn, using: token)` on `.active`;
- cancel stale resume requests when disconnecting, switching profile, handling a notification target, or starting a new conversation.

- [ ] **Step 8: Run resume suites and the existing reconciliation-related suites**

Run:

```bash
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -only-testing:ConduitTests/ChatResumePolicyTests -only-testing:ConduitTests/ChatResumeStoreTests -only-testing:ConduitTests/ChatResumeCoordinatorTests -only-testing:ConduitTests/ChatScrollStateTests -only-testing:ConduitTests/StreamEventParserTests -only-testing:ConduitTests/TurnStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: all selected suites pass.

- [ ] **Step 9: Commit AppState integration**

```bash
git add Conduit/Services/AppState.swift ConduitTests/ChatResumeCoordinatorTests.swift
git commit -m "feat: apply resume policy during session sync"
```

---

### Task 5: Make ChatView a restoration consumer

**Files:**
- Modify: `Conduit/Views/ChatView.swift`
- Modify: `Conduit/Services/ChatScrollState.swift`
- Modify: `ConduitTests/ChatScrollStateTests.swift`
- Modify: `ConduitTests/ChatResumePolicyTests.swift`

**Interfaces:**
- Consumes: `AppState.chatResumeRestorationRequest`, viewport reporting/cancellation/completion methods, and semantic targets.
- Produces: no new global state; `ChatView` only reports snapshots and applies requests.

- [ ] **Step 1: Write failing viewport-resolution policy tests**

Add `ChatResumeViewportResolver` expectations:

```swift
func testPersistedAnchorSurvivesWhenTargetExists() {
    let message = ChatMessage(id: "source-12", role: .assistant, content: "Stable", timestamp: "now")
    let target = ChatMessageScrollTargets.make(for: [message])[0]
    let snapshot = ChatScrollSnapshot(
        anchorMessageID: target.semanticID,
        followsLatest: false,
        anchorMetadata: target.restorationMetadata,
        anchorSourceMessageID: target.id
    )

    XCTAssertEqual(
        ChatResumeViewportResolver.destination(
            for: snapshot,
            availableTargets: .init(targets: [target])
        ),
        .anchor(target.semanticID)
    )
}

func testMissingAnchorFallsBackToLatestWithinSelectedConversation() {
    XCTAssertEqual(
        ChatResumeViewportResolver.destination(
            for: .init(anchorMessageID: "deleted", followsLatest: false),
            availableTargets: .init(targets: [])
        ),
        .latest
    )
}
```

Retain the existing source-message re-anchor and duplicate-fingerprint cases.

- [ ] **Step 2: Run focused policy/scroll tests to verify RED**

Run:

```bash
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -only-testing:ConduitTests/ChatResumePolicyTests -only-testing:ConduitTests/ChatScrollStateTests CODE_SIGNING_ALLOWED=NO
```

Expected: compilation fails because `ChatResumeViewportResolver` does not exist.

- [ ] **Step 3: Extract the reusable viewport resolver**

In `ChatResumePolicy.swift`, add:

```swift
enum ChatResumeViewportDestination: Equatable {
    case latest
    case anchor(String)
}

enum ChatResumeViewportResolver {
    static func destination(
        for snapshot: ChatScrollSnapshot,
        availableTargets: ChatScrollTargetAvailability
    ) -> ChatResumeViewportDestination
}
```

Move the exact-anchor, metadata validation, and source-message re-anchor logic out of `ChatScrollStateStore.restoration` into this pure resolver. Keep semantic target generation in `ChatScrollState.swift`.

Change `ChatScrollTargetAvailability.contains`, `metadata(for:)`, and `semanticID(forSourceMessageID:)` from `fileprivate` to module-internal so `ChatResumePolicy.swift` can use them without duplicating target maps.

- [ ] **Step 4: Remove ChatView's independent lifecycle ownership**

Delete:

- `@Environment(\.scenePhase)`;
- local `ChatScrollStateStore` persistence ownership;
- the `.onChange(of: scenePhase)` handler;
- reconciliation gates that duplicate the coordinator's settled request;
- delayed scroll callbacks that are not generation-checked.

Keep semantic target caching, bottom/viewport geometry, notification handoff, and the user-facing jump-to-latest button.

- [ ] **Step 5: Report stable viewport snapshots through AppState**

Refactor `saveChatScrollPosition` so it builds the existing semantic snapshot and calls:

```swift
appState.recordChatViewport(snapshot, for: sessionKey)
```

Report when `topVisibleChatID` changes, after stable drag completion, before explicit session/profile switches while the old transcript is still rendered, and whenever `followsLatest` changes. The coordinator ignores suspension-time callbacks while frozen.

On stable drag completion, call `appState.flushChatResumeViewport()` immediately after reporting the snapshot. `AppState` forwards this to `ChatResumeCoordinator.flush()`.

- [ ] **Step 6: Consume generation-scoped restoration requests**

Observe `appState.chatResumeRestorationRequest`. For `.latest`, scroll to `bottomAnchor` only if the generation remains current. For `.snapshot`, wait until the target cache reflects the reconciled `messages`, resolve through `ChatResumeViewportResolver`, and perform a nonanimated anchor scroll or latest fallback.

After success call:

```swift
appState.completeChatResumeRestoration(generation: request.generation)
```

On drag, jump-to-latest, composer request, session/profile switch, or notification handoff, call `appState.cancelChatResumeRestoration()` before the explicit action.

- [ ] **Step 7: Prevent message updates from stealing a restored viewport**

Update `ChatMessageScrollUpdatePolicy.shouldReassertLatest` calls so any pending resume request suppresses latest reassertion. Continue mode with `followsLatest == false` must retain the anchor when new messages arrive and leave the down-arrow visible.

- [ ] **Step 8: Remove superseded local-store tests and run focused suites**

Delete only tests that assert the old in-memory `ChatScrollStateStore` owns session persistence. Retain and adapt semantic-anchor, duplicate-content, projection replacement, latest-reassertion, notification handoff, and source-ID re-anchor tests.

Run:

```bash
xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" -only-testing:ConduitTests/ChatScrollStateTests -only-testing:ConduitTests/ChatResumePolicyTests -only-testing:ConduitTests/ChatResumeCoordinatorTests CODE_SIGNING_ALLOWED=NO
```

Expected: all selected suites pass.

- [ ] **Step 9: Commit the view integration**

```bash
git add Conduit/Views/ChatView.swift Conduit/Services/ChatScrollState.swift Conduit/Services/ChatResumePolicy.swift ConduitTests/ChatScrollStateTests.swift ConduitTests/ChatResumePolicyTests.swift
git commit -m "fix: restore chat viewport through coordinator"
```

---

### Task 6: Add the Chat settings control

**Files:**
- Modify: `Conduit/Views/AuxiliaryViews.swift`
- Modify: `Conduit/Views/RootView.swift`
- Modify: `Conduit/Services/AppState.swift`
- Modify: `ConduitTests/ChatResumePolicyTests.swift`

**Interfaces:**
- Consumes: `AppState.chatResumeBehavior` and `setChatResumeBehavior(_:)`.
- Produces: `SettingsSnapshot.chatResumeBehavior` and a device-local segmented control.

- [ ] **Step 1: Add failing copy/default tests**

Give `ChatResumeBehavior` stable presentation values and test them:

```swift
func testResumeBehaviorPresentationCopyIsStable() {
    XCTAssertEqual(ChatResumeBehavior.continueWhereLeftOff.title, "Continue where I left off")
    XCTAssertEqual(ChatResumeBehavior.latestActivity.title, "Jump to latest activity")
}
```

- [ ] **Step 2: Implement stable behavior copy**

Add to `ChatResumePolicy.swift`:

```swift
extension ChatResumeBehavior {
    var title: String {
        switch self {
        case .continueWhereLeftOff: return "Continue where I left off"
        case .latestActivity: return "Jump to latest activity"
        }
    }
}
```

- [ ] **Step 3: Thread the device-local setting through SettingsSnapshot**

Add `chatResumeBehavior: ChatResumeBehavior` to `SettingsSnapshot` and `makeSettingsSnapshot()`. Add `persistChatResumeBehavior: (ChatResumeBehavior) -> Void` to `SettingsView`, pass it into `ChatSettingsDetail`, and supply this closure from `RootView`:

```swift
persistChatResumeBehavior: { appState.setChatResumeBehavior($0) }
```

- [ ] **Step 4: Add the segmented Chat settings section**

Before profile-backed chat fields, render:

```swift
ConduitSettingsSection(
    title: "When returning to Conduit",
    symbol: "arrow.uturn.backward.circle",
    tint: .conduitAccent
) {
    Text("Choose whether Conduit preserves your exact reading position or follows the newest conversation.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    Picker("When returning to Conduit", selection: $behavior) {
        Text("Continue").tag(ChatResumeBehavior.continueWhereLeftOff)
        Text("Latest").tag(ChatResumeBehavior.latestActivity)
    }
    .pickerStyle(.segmented)
}
```

Initialize local state from the snapshot and persist immediately on selection. Label the section as device-local so it is not confused with Hermes profile settings.

- [ ] **Step 5: Run policy tests and build the app**

Run the focused policy tests, then:

```bash
xcodebuild build -project Conduit.xcodeproj -scheme Conduit -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO
```

Expected: tests pass and the app builds.

- [ ] **Step 6: Commit Settings integration**

```bash
git add Conduit/Views/AuxiliaryViews.swift Conduit/Views/RootView.swift Conduit/Services/AppState.swift Conduit/Services/ChatResumePolicy.swift ConduitTests/ChatResumePolicyTests.swift
git commit -m "feat: add chat return behavior setting"
```

---

### Task 7: Full regression and simulator acceptance

**Files:**
- Modify only files required by failures directly caused by Tasks 1-6.
- Verify: all `ConduitTests` and both user-facing behavior modes.

**Interfaces:**
- Consumes: completed implementation from Tasks 1-6.
- Produces: evidence that PR #19 satisfies the design and introduces no test regression.

- [ ] **Step 1: Regenerate and inspect the final diff**

Run:

```bash
xcodegen generate
git diff --check
git status --short
git diff --stat 609fef2...HEAD
```

Confirm `ChatView` no longer observes scene phase, the coordinator store is the only automatic-session persistence source, and no production file contains duplicate restoration callbacks.

- [ ] **Step 2: Run the full unit-test suite with a dynamically selected simulator**

Resolve an available iPhone UDID using the same JSON selection strategy as `.github/workflows/ci.yml`, then run:

```bash
CONDUIT_RESULT_DIR=$(mktemp -d /tmp/conduit-chat-resume.XXXXXX)
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination "platform=iOS Simulator,id=$CONDUIT_SIMULATOR_ID" \
  -configuration Debug \
  -resultBundlePath "$CONDUIT_RESULT_DIR/TestResults.xcresult" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER=""
```

Expected: all tests pass. Preserve the `.xcresult` if any test fails.

- [ ] **Step 3: Run simulator acceptance in continue mode**

On an iPhone Simulator connected to a test Hermes instance:

1. Select A and scroll to an older message.
2. Background Conduit and create or receive newer activity in B.
3. Return and verify A remains selected at the same anchor with jump-to-latest available.
4. Terminate and relaunch Conduit; verify A and its anchor restore again.
5. Add messages to A while backgrounded and verify the viewport does not move.

- [ ] **Step 4: Run simulator acceptance in latest mode**

Change the Chat setting to **Jump to latest activity**, repeat background/foreground and terminate/relaunch, and verify B opens at its bottom both times.

- [ ] **Step 5: Verify precedence and fallback**

Verify a notification destination wins while automatic restoration is pending, a manual session tap cancels restoration, and deleting saved A causes a clean fallback to the newest ordinary chat without an error.

- [ ] **Step 6: Commit only direct verification fixes**

If verification required a direct fix, rerun the focused failing test and full suite before committing it with a narrow message. If no code changed, do not create an empty commit.

- [ ] **Step 7: Review branch history and hand off PR #19**

Run:

```bash
git status --short --branch
git log --oneline --decorate 609fef2..HEAD
```

Expected: clean worktree, focused commits, and no uncommitted generated/test artifacts. Push and update PR #19 only after code review and user approval.
