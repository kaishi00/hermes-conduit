# Conduit Launcher Widgets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship attractive Native and Conduit-chan medium widgets that reliably resume a conversation, create a text chat, or start fresh foreground voice.

**Architecture:** A dedicated App Group holds a bounded, atomic display snapshot. Both WidgetKit entries read it and emit typed links to one process-owned app coordinator, which resolves exact dashboard/profile/conversation ownership through existing app flows. The extension never connects to Hermes or handles authentication/audio.

**Tech Stack:** Swift 5.9, SwiftUI, WidgetKit, AppIntents, Foundation, XCTest, XcodeGen; iOS 17+.

**Spec:** [Approved design](../specs/2026-10-10-launcher-widgets-design.md).

## Global Constraints

- Two medium Home Screen gallery entries, **Native** and **Conduit-chan**, with identical actions and independent per-instance configuration.
- iOS 17+; iPhone and iPad; system typography, accessible labels, Dynamic Type, privacy-sensitive titles and an option to hide them.
- Follow current dashboard/workspace profile or choose a saved workspace; optional saved conversation selection.
- Each displayed timeline entry captures its exact workspace; a later app switch cannot redirect its tap.
- Dedicated group `group.com.milim.relay.widgets`; display metadata and identifiers only; no notification group, credentials, Keychain, gateway URLs, tickets or transcripts.
- Retain at most 100 workspace records and 20 saved conversation choices per workspace; last, pinned, then recent priority.
- Cache eviction shows **Open Conduit to refresh**; it never implies deletion or substitutes another conversation.
- Pending launches are process-local and expire after 30 seconds on a monotonic deadline, including authentication/connection time.
- New explicit navigation or sign-out supersedes older work; active-call policy is respected; Talk uses current voice settings and foreground readiness.
- No Live Activities, live counts/status, background widget networking, inline approvals, prompt presets, extra sizes, or Siri/Watch/CarPlay behavior changes.
- Use an isolated worktree from then-current main. Preserve unrelated changes, release/version state and existing general session-link restrictions.
- `project.yml` is authoritative; regenerate with XcodeGen; no manual generated-project edits or unauthorized generated-file commits.
- No commits, pushes, PRs, merges, releases or TestFlight uploads are authorized. Use diff checkpoints in place of commit steps.
- Use established Mac/harness validation where available. Exact-head hosted `CI Gate` governs a future PR; Nightly governs a future release candidate; do not run the retired exhaustive local gate.

## Review Focus

1. Identical profiles/session IDs on different dashboards, or Dashboard and Bot Chats sharing an ID: a tap resolves only its full typed owner.
2. Old timeline entries after switching, renaming, eviction or removal: preserve the displayed target or explain why it cannot be opened.
3. Authentication/connection suspensions, newer navigation and expiry during voice preparation: stale work never selects a chat or arms the microphone.
4. Repeated taps and duplicate scene delivery: one in-flight action runs; a deliberate tap after completion can create another chat.
5. Missing/corrupt snapshots, long/RTL labels and hidden titles: widgets remain legible and offer safe setup/refresh destinations.

---

## File map and execution baseline

Source inspection used `origin/main` `46f25da3`. Recheck names against the execution worktree rather than treating line numbers as stable.

| Files | Responsibility |
|---|---|
| `Shared/Widgets/WidgetSnapshot.swift`, `WidgetSnapshotStore.swift`, `WidgetLaunchLink.swift`, `WidgetSelection.swift` | Foundation-only DTOs, atomic storage, strict route codec and pure entry selection |
| `Shared/Widgets/WidgetConfiguration.swift` | Local snapshot-backed AppIntent configuration and entities |
| `Conduit/Services/WidgetSnapshotPublisher.swift`, `AppState+Widgets.swift` | Settled app projection, identity adapter, pruning and reload coalescing |
| `Conduit/Services/WidgetLaunchCoordinator.swift`, `AppState+WidgetLaunch.swift` | Process-local request ownership/deadline and existing app action adapters |
| `Conduit/Services/AppState.swift`, `Conduit/ConduitApp.swift` | Narrow publication, explicit-navigation and async ownership hooks |
| `ConduitWidgets/ConduitWidgets.swift`, `WidgetViews.swift`, `Assets.xcassets`, `Info.plist`, `ConduitWidgets.entitlements` | Bundle, provider, both layouts, artwork and extension packaging |
| `project.yml`, `Conduit/Conduit.entitlements`, `Conduit/Localizable.xcstrings` | Target embedding, isolated group membership and localized widget/app feedback |
| `ConduitTests/WidgetSnapshotTests.swift`, `WidgetLaunchLinkTests.swift`, `WidgetSnapshotPublisherTests.swift`, `WidgetLaunchCoordinatorTests.swift`, `AppStateWidgetLaunchTests.swift` | Focused pure/model and app integration coverage |
| `Conduit/Services/WidgetLaunchUITestFixture.swift`, `ConduitUITests/WidgetLaunchUITests.swift`, `docs/WIDGETS.md` | DEBUG-only URL-delivery fixture, foreground launch scenarios and configuration/validation notes |

Execute tasks 1 → 2 → 3 → 4 → 5. Task 4 may follow task 2 once task 1's interfaces are accepted, but serialize overlapping `project.yml`, catalogs and app edits. No dependency updates or CI workflow changes are planned.

**Validation shorthand used below:** start with XcodeBuildMCP `session_show_defaults`, confirm the isolated Mac checkout, Conduit scheme and simulator, then `build_sim(buildForTesting: true)` and `test_sim(extraArgs: ["-only-testing:ConduitTests/<Class>"])`. Substitute the exact class listed in a task. Use simulator signing overrides if required. An unavailable harness/Mac is a recorded validation limitation; it is not a passing test cycle. Never build against the intentional Mac release checkout or start competing simulator builds.

### Task 1: Shared snapshot, selection and link contract

**Files:** Create the four Foundation-only files in `Shared/Widgets`; test `WidgetSnapshotTests.swift` and `WidgetLaunchLinkTests.swift`.

**Interfaces:**
- Produces `WidgetWorkspaceID: Codable, Hashable` with `dashboardID: UUID`, `profile: String`.
- Produces `WidgetConversationReference: Codable, Hashable` retaining `kind` (`dashboard`/`bot`), `scopeProfile`, `botName`, `sessionID`, `isUnverified`; store optional `botLabel` with display data, never in URLs. App adaptation preserves existing `SessionReference` evidence.
- Produces `WidgetConversationChoice` (typed reference, title, pinned state, recency) and `WidgetWorkspaceSnapshot` (ID, dashboard/profile labels, last reference, choices, recency).
- Produces `WidgetSnapshot: Codable, Equatable` with schema version `1`, app-language selection, optional current workspace ID and workspace records.
- Produces `WidgetSnapshotStore.init(directory: URL)`, `read() -> WidgetSnapshot?`, `write(_ snapshot: WidgetSnapshot) throws -> Bool`; `true` means changed bytes were atomically replaced. Production directory resolves the dedicated group; missing group fails safely without falling back to standard defaults.
- Produces `WidgetLaunchAction` (`open`, `resume`, `newChat`, `talk`), `WidgetLaunchLink: Equatable` with action, optional workspace and optional typed reference; `init?(action: WidgetLaunchAction, workspace: WidgetWorkspaceID?, reference: WidgetConversationReference?)`, `init?(url: URL)`, `var url: URL`. Construction canonicalizes away display-only `botLabel`; routing identity and classification evidence remain intact.
- Produces `WidgetSelection.resolve(snapshot: WidgetSnapshot?, workspace: WidgetWorkspaceID?, conversation: WidgetConversationReference?, hideTitle: Bool = false) -> WidgetEntryModel`. Nil workspace means follow current; a missing fixed target produces refresh, never follow-current fallback. `WidgetEntryModel` exposes `title`, dashboard/profile labels, `resumeLink`, optional `newChatLink` and optional `talkLink`; invalid/unusable identities expose only explicit generic refresh/setup recovery, never scoped actions or cached target labels. Hidden-title copy is generic while target identity stays exact.

- [ ] Write named tests with the following assertions (temporary-directory and fixed-clock helpers are ordinary helper types):

```swift
// testSnapshotRoundTripKeepsDashboardAndBotIdentity
XCTAssertEqual(decoded, original) // same IDs in two dashboards and both kinds
// testSnapshotBoundsPrioritizeLastPinnedRecent
XCTAssertEqual(result.workspaces.count, 100)
XCTAssertEqual(result.workspaces[0].choices.count, 20)
XCTAssertTrue(result.workspaces[0].choices.contains(lastChoice))
// testAtomicStoreRetainsValidSnapshotWhenWriteFails
XCTAssertEqual(store.read(), previous)
// testMalformedOrUnknownSchemaProducesSetup
XCTAssertNil(store.read())
// testSelectionCapturesDisplayedWorkspaceAndDoesNotReplaceEvictedTarget
XCTAssertEqual(entry.resumeLink.workspace, displayedWorkspace)
XCTAssertEqual(evicted.title, "Open Conduit to refresh")
// testWidgetLinkRoundTripAndStrictNamespace
XCTAssertEqual(WidgetLaunchLink(url: link.url), link)
XCTAssertNil(WidgetLaunchLink(url: malformedURL))
```

Also cover Unicode/percent-encoded profiles, repeated/unknown query keys, unsupported versions/actions, missing required identity, foreign schemes/hosts, resume without a reference, and New Chat/Talk carrying a conversation. Encoded routes contain only action/identity, never labels or arbitrary endpoints. Add `testLongRTLTitleRoundTripsAndHiddenTitleRedactsDisplay`: assert the stored Unicode title is unchanged, hidden entry copy is generic, and its exact target link is unchanged.
- [ ] Run both focused classes; confirm meaningful failures before implementation.
- [ ] Implement the interfaces. Use `conduit://widget/v1/<action>` plus `URLComponents` query fields for exact workspace and typed identity; reject ambiguous or inconsistent shapes. Keep `ConduitAppLink` unchanged. Write `launcher-v1.json` atomically; decode unknown/corrupt data safely. Apply deterministic caps without treating eviction as deletion.
- [ ] Run both classes to completion; inspect the diff for group isolation and round-trip fidelity.

### Task 2: Publish settled app metadata

**Files:** Create `WidgetSnapshotPublisher.swift`, `AppState+Widgets.swift`, `WidgetSnapshotPublisherTests.swift`; add narrow hooks in `AppState.swift` and the existing language-change callback in `ConduitApp.swift`.

**Interfaces:**
- Consumes Task 1 DTOs/store and existing `SessionReference`/saved-dashboard registry.
- Produces `@MainActor WidgetSnapshotPublisher.init(store: WidgetSnapshotStore, reload: @escaping () -> Void)`, `publish(_ workspace: WidgetWorkspaceSnapshot, current: WidgetWorkspaceID?, language: String) throws`, `remove(dashboardID: UUID) throws`, `retainProfiles(_ profiles: Set<String>, dashboardID: UUID) throws`.
- Produces AppState `publishWidgetSnapshot()`, `widgetReference(from: SessionReference) -> WidgetConversationReference`, `sessionReference(from: WidgetConversationReference) -> SessionReference`.

- [ ] Add `testIdenticalProjectionDoesNotWriteOrReload`, `testOfflineKeepsOtherDashboardRecords`, `testSignOutPurgesOnlyItsDashboard`, `testAuthoritativeProfileRemovalPrunesButRefreshFailureDoesNot`, `testBotReferenceRoundTripPreservesOwnerAndEvidence`, and `testLanguageSelectionReloadsWithoutInventingSystemLocale`. Assert exact reload/write counts, retained workspace IDs and unchanged evidence; test selected `system` and explicit localization IDs.
- [ ] Run `WidgetSnapshotPublisherTests` before implementing; confirm failures.
- [ ] Implement merge/prune/coalescing, preserving previously visited dashboards across active switches. Publish only after admitted session identity/catalog state. Wire `setActiveSessionState`, `adoptSessionReference`, settled session catalog loads, pin/title mutations, successful profile/dashboard selection, profile-label changes and language change. Purge on `signOutDashboard`/`removeDashboard` and authoritative profile removal; distinguish ordinary network disconnect from sign-out. Never serialize each stream frame.
- [ ] Run the focused class plus `SessionIdentityContractTests` and `AppLanguageTests`; confirm completion. Inspect serialized fixtures: only the allowlisted DTO fields exist, with no conversation bodies, URLs or auth fields.

### Task 3: Own foreground launches through startup and suspension

**Files:** Create `WidgetLaunchCoordinator.swift`, `AppState+WidgetLaunch.swift`, `WidgetLaunchCoordinatorTests.swift`, `AppStateWidgetLaunchTests.swift`; modify only routing/ownership seams in `ConduitApp.swift` and `AppState.swift`.

**Interfaces:**
- Consumes `WidgetLaunchLink`, workspace/reference adapters, existing dashboard/profile readiness, session identity and voice flows.
- Produces `@MainActor WidgetLaunchCoordinator.init(now: @escaping () -> Duration, prepare: @escaping (WidgetLaunchLink, WidgetLaunchLease) async -> WidgetLaunchOutcome, perform: @escaping (WidgetLaunchLink, WidgetLaunchLease) async -> WidgetLaunchOutcome, finish: @escaping (WidgetLaunchOutcome) -> Void)`, `receive(_ link: WidgetLaunchLink)`, `supersede()`, `readinessChanged()`. `finish` presents ordinary app feedback for terminal failure/expiry; superseded work clears silently.
- Produces `@MainActor WidgetLaunchLease` with `var isCurrent: Bool` (generation, monotonic deadline and foreground/target ownership), and `WidgetLaunchOutcome` (`handled`, `deferred`, `failed(String)`).
- Produces AppState `prepareWidgetLaunch(_ link: WidgetLaunchLink, lease: WidgetLaunchLease) async -> WidgetLaunchOutcome`, `performWidgetLaunch(_ link: WidgetLaunchLink, lease: WidgetLaunchLease) async -> WidgetLaunchOutcome`, and one lazy coordinator owned by the process-wide AppState.

- [ ] Add deterministic suspended-operation tests; inject fake monotonic time and continuations rather than timing sleeps:

```swift
// testDuplicateInFlightDeliveryRunsOnceButLaterTapRunsAgain
XCTAssertEqual(createCount, 1) // duplicate while prepare is suspended
XCTAssertEqual(createCountAfterCompletedRetap, 2)
// testSupersededOrExpiredTalkCannotArmMicrophone
XCTAssertEqual(voicePresentations, 0)
XCTAssertEqual(microphoneStarts, 0) // expire at exactly 30 seconds
// testDisplayedWorkspaceWinsOverCurrentWorkspace
XCTAssertEqual(openedWorkspace, displayedWorkspace)
// testWidgetNavigationWinsOverSuspendedAutomaticRestore
XCTAssertEqual(selectedReference, requestedReference)
// testRemovedTargetNeverOpensCurrentDashboard
XCTAssertEqual(openCount, 0)
```

Add named `testAuthCancellationIsTerminal`, `testStableOfflineFailureDoesNotReplayAfterReconnect`, `testActiveCallRefusesBeforeWorkspaceSwitch`, `testMissingConversationStaysInRequestedWorkspace`, `testBotOwnerCollisionUsesTypedReference`, and `testWarmAndColdNewChatAndTalkStartFreshOnce`. Suspend at workspace authentication, profile switching, session creation and voice capability/preparation, then supersede/sign out/background/expire; assert no stale selection or audio after each boundary.
- [ ] Run both new classes before implementation and confirm failures.
- [ ] Implement the coordinator with a process-generated ownership token, one in-flight equivalent request and a single 30-second timer. Coalesce only while in flight; do not persist requests or embed a permanent deduplication token in links. Stable failure/canceled auth ends the request; readiness changes may retry only current deferred work.
- [ ] Implement the app adapters. Validate saved dashboard and exact profile, respect active calls before mutation, and use typed ownership for Bot Chats. Resume through current identity-aware open paths; New Chat through owned creation; Talk through the existing fresh voice path/current engine settings. Thread the lease through the minimal async action seams so checks occur inside the actual preparation path after suspension and immediately before selection/presentation/microphone arming, not merely around an outer await. Preserve existing callers through optional/default ownership parameters.
- [ ] Route widget URLs before the ordinary external parser. At validated admission, include pending widget ownership in `hasPendingExplicitNavigation` and call `cancelChatResumeRestoration()` before waiting for connection/authentication. Use `beginExplicitChatViewportTransition()` only when the conversation action starts; do not freeze the viewport throughout sign-in. Clear only the matching generation. Connect non-widget explicit navigation and sign-out to supersession without changing their destinations. Preserve the process runtime registry, push/Siri flows and iPad window guard. Invalid widget URLs do nothing and cannot become permissive ordinary links.
- [ ] Run both classes and relevant existing regressions: `AppStateChatResumeTests`, `AppStateMultiDashboardTests`, `PendingVoiceIntentLifecycleTests`, plus external-link coverage in `HermesVoiceGatewayTimeoutTests` (its source is `ConduitExternalLinkTests.swift`). Record assertion failures separately from incomplete/infrastructure runs.

### Task 4: Package and render both widget styles

**Files:** Create the extension files/resources and `Shared/Widgets/WidgetConfiguration.swift`; modify `project.yml`, app entitlements and `Conduit/Localizable.xcstrings`; extend `WidgetSnapshotTests.swift` for configuration resolution.

**Interfaces:**
- Consumes snapshot store, exact selection resolution and route links.
- Produces `WidgetWorkspaceEntity: AppEntity`, `WidgetConversationEntity: AppEntity`, snapshot-only `EntityQuery` implementations and `LauncherWidgetConfigurationIntent: WidgetConfigurationIntent` with workspace, optional conversation and `hideTitle` parameters.
- Produces `LauncherTimelineProvider: AppIntentTimelineProvider`, `NativeLauncherWidget`, `CharacterLauncherWidget`, and `ConduitWidgets: WidgetBundle`. Stable kinds are `com.milim.relay.widgets.native` and `com.milim.relay.widgets.character`; both support only `.systemMedium`.

- [ ] Add `testFixedWorkspaceConfigurationDoesNotFollowCurrent`, `testUnknownConfiguredEntityShowsRefresh`, `testConfiguredConversationBelongsToSelectedWorkspace`, `testNoWorkspaceShowsSetup`, `testKnownWorkspaceWithoutChatKeepsNewChatAndTalk`, and `testHideTitleKeepsGenericExactTargetLink`. Assert resolved action/identity and exact fallback copy. Entity IDs encode full identity, never bare profile/session ID; queries cannot fetch network data or silently replace unavailable selections.
- [ ] Run focused selection tests before implementation; confirm failures.
- [ ] Implement configuration/provider and both layouts from the approved concepts using system medium margins. Render three `Link` destinations, explicit accessible action labels, decorative existing artwork, adaptive contrast, `.privacySensitive()` title and generic Resume/Open Chat when hidden. Guard newer tinted/clear rendering APIs by availability and inspect their actual rendering on a supported simulator/device. Capture targets when creating entries; use cached data and `.never` timeline policy with app-triggered reloads.
- [ ] Reuse the app's String Catalog as an extension resource without compiling app services. Read `docs/LOCALIZATION.md`; add widget/configuration/feedback keys for every shipped language and retain draft stripping in both bundles, reusing the app Info.plist's draft list. Preserve System Default language semantics; do not add languages. Populate minimal `WidgetCharacter`/`WidgetMark` image sets from `Conduit/Resources/Assets.xcassets/AppIconPreview.imageset/icon.png` and `AppIconLightPreview.imageset/icon-light.png`; retain the approved artwork through SwiftUI cropping and avoid unrelated application resources.
- [ ] Add `ConduitWidgets` app-extension (`com.milim.relay.widgets`, iOS 17, device families 1/2, `APPLICATION_EXTENSION_API_ONLY: YES`, `SKIP_INSTALL: YES`), app embedding dependency, WidgetKit extension Info.plist and widget entitlements containing only the launcher group. Add that group to app entitlements while preserving existing groups. Compile only `Shared/Widgets` into the widget; exclude `Widgets/**` from the notification extension's broad Shared source inclusion. Keep app version/build unchanged. Use the established manual signing approach with widget profile `Conduit Widgets App Store`; record that device/archive signing requires its App ID/profile and group membership, without modifying release/signing credentials.
- [ ] On the isolated Mac checkout, extend PATH for Homebrew and run `xcodegen generate`; follow generated-project policy. Build the app/embedded extension through the harness, inspect new compiler warnings and built `PlugIns/ConduitWidgets.appex`. Check target membership and entitlement isolation; run `python3 scripts/check-l10n-coverage.py --repo-root .`. Missing signing resources do not prevent an unsigned simulator build.

### Task 5: Exercise routing, inspect real widgets and hand off evidence

**Files:** Create `Conduit/Services/WidgetLaunchUITestFixture.swift`, `ConduitUITests/WidgetLaunchUITests.swift` and `docs/WIDGETS.md`; add only the fixture attachment in `ConduitApp.swift`.

**Interfaces:** Consumes the finished launcher routes, widgets and app coordinator. Produces DEBUG-only `WidgetLaunchUITestFixture.launchURL(arguments: [String]) -> URL?` and `WidgetLaunchUITestFixtureModifier: ViewModifier`, plus focused UI coverage and a verification record separating source, XCTest, simulator/device, signing and hosted results.

- [ ] Add named UI scenarios `testColdWidgetResumeOpensRequestedWorkspace`, `testWarmWidgetNewChatCreatesFreshConversation`, `testWidgetTalkWaitsForForegroundReadiness`, and `testRemovedWidgetTargetShowsRecovery`. Reuse the seeded connected-dashboard/profile fixture pattern from `ProfilePickerUITests`; no existing UI URL-delivery helper was found. Add `-CONDUIT_UI_TEST_WIDGET_URL` for cold delivery and a test-only control with accessibility ID `widgetUITestDeliverURL` for warm delivery, enabled only in DEBUG with `CONDUIT_UITEST=1`. Both call the same URL ingestion used by `.onOpenURL`; release builds omit the fixture. Assertions check visible requested workspace/conversation, fresh-chat identity, deferred voice presentation and recovery feedback. These are fixture-delivery tests; actual OS delivery is checked with installed widgets below. Unit spies from Task 3 prove microphone non-activation; a UI label assertion is not audio proof.
- [ ] Run the focused UI class through `test_sim` and finish the required relevant unit coverage. Run `python3 scripts/plan-tests.py validate`, `python3 scripts/plan-tests.py hosted`, and `python3 scripts/plan-tests.py smoke`; expect successful discovery/coverage with new classes automatically assigned. No shard-count/workflow edits are needed. If a CI-tooling change becomes necessary, also run `python3 -m unittest discover -s scripts/tests`.
- [ ] Inspect actual installed widgets on iPhone/iPad: both styles together with different fixed/follow configurations, warm/cold taps, light/dark and supported tinted/clear modes, accessibility text, long/RTL titles, hidden titles, no account and evicted conversation. Verify touch regions and contrast after WidgetKit rendering. Record screenshots and unsupported/unavailable device/OS cases; the browser concept is only a design reference.
- [ ] Document widget setup, local-only picker availability, cache versus deletion recovery, dedicated group/signing prerequisites and verified/unverified environments in `docs/WIDGETS.md`. Record actual build/test completion and warnings. Future hosted CI cannot be claimed without a pushed exact head and completed `CI Gate`; this task does not authorize publishing to obtain it.
- [ ] Review the combined diff and `git diff --check`, confirm version/build and unrelated files stayed unchanged, then obtain the chosen execution method's independent review. Resolve material correctness findings and rerun only affected checks. Deliver the isolated path, changed files and validation limits without committing or publishing.

## Plan self-review

The five review-focus conditions have named tests in Tasks 1–4 and real rendering checks in Task 5. Shared interfaces, full conversation evidence, eviction recovery, both independent configurations, locale/privacy behavior, inner async ownership fences and signing/CI boundaries are covered. Existing app services remain authoritative; no new voice provider, general-link permission, networking layer or release gate is introduced.
