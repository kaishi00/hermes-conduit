# Chat Resume Behavior Design

## Context

Conduit currently performs an authoritative session reconciliation whenever it launches or returns to the foreground. If the locally remembered session uses a runtime ID that no longer matches the stored ID in the refreshed catalog, session selection falls back to the first and newest chat. A user who left Conduit while reading conversation A can therefore return to conversation B.

PR #19 added semantic scroll anchors, session-ID aliases, and several restoration callbacks, but it does not model the complete launch/foreground decision. Session selection and viewport restoration are currently split between `AppState`, `RootView`, and `ChatView`, and both `RootView` and `ChatView` independently observe scene changes. This makes callback ordering part of correctness and leaves the reported A-to-B regression without an end-to-end policy test.

## Goals

- Give users an explicit, device-local choice for automatic launch and foreground behavior.
- Make **Continue where I left off** the default for existing and new installations.
- Apply the selected behavior consistently after ordinary foregrounding, process termination, and cold launch.
- In continue mode, reopen the same profile and conversation and restore the last stable reading position.
- In latest mode, deliberately open the newest available chat and follow its bottom.
- Preserve notification routing and explicit user navigation as higher-priority actions.
- Make session choice, snapshot persistence, and restoration sequencing independently testable.
- Reuse the resulting components if Conduit later adopts a broader navigation coordinator.

## Non-goals

- Rewriting Conduit's complete navigation stack.
- Changing Hermes server configuration or synchronizing this preference across devices.
- Restoring a deleted message or conversation.
- Changing how sessions are ordered in the sidebar.
- Changing notification destination behavior.

## User-facing behavior

Chat settings gain a device-local segmented choice titled **When returning to Conduit**:

- **Continue where I left off**: reopen the last visible conversation and restore its last stable viewport anchor. New activity in another conversation does not steal focus. New messages in the restored conversation do not move the reader; the existing jump-to-latest control remains available.
- **Jump to latest activity**: refresh the session catalog, select its newest ordinary chat, and scroll that conversation to the bottom.

Continue mode is the default when no preference has been saved. The setting governs automatic restoration on launch and foregrounding. A notification tap, an explicit session tap, profile selection, or new-conversation action always wins over an automatic resume already in progress.

If a saved conversation no longer exists or is no longer eligible, continue mode falls back to the newest available chat at its bottom. If the conversation still exists but only its saved message anchor is unavailable, Conduit keeps that conversation selected and falls back to its bottom.

## Architecture

Introduce a focused `ChatResumeCoordinator`. It is not a general navigation coordinator. Its responsibilities are limited to:

1. Owning the device-local resume behavior preference.
2. Persisting and retrieving profile/session viewport snapshots.
3. Resolving the automatic session target after the authoritative catalog refresh.
4. Tracking one restoration generation so stale asynchronous work can be cancelled.
5. Emitting a restoration intent only after session reconciliation has settled.

The coordinator is composed from small value-oriented pieces:

- `ChatResumeBehavior`: a codable enum for continue or latest behavior.
- `ChatResumeSessionResolver`: a pure policy that chooses a catalog session from the behavior, saved identity, refreshed catalog, and any higher-priority destination.
- `ChatResumeStore`: a versioned device-local store for the preference, last active session per profile, and viewport snapshots.
- `ChatResumeSnapshot`: the canonical session key, semantic anchor, source message ID, duplicate/fingerprint metadata, whether the viewport follows latest, and the update timestamp.
- `ChatResumeRestorationIntent`: a generation-scoped instruction to wait, restore an anchor, follow latest, or cancel.

`AppState` remains authoritative for connection, catalog loading, and transcript reconciliation. It asks the coordinator which session should be automatically reconciled after loading the catalog and reports reconciliation completion. `ChatView` remains responsible for performing `ScrollViewProxy` operations and reporting stable viewport state, but it no longer observes scene phase or owns automatic-resume policy.

`RootView` remains the single scene-phase entry point. It forwards lifecycle transitions to `AppState`, which coordinates network reconciliation and the resume coordinator in a defined sequence.

## Persistence

The device-local store uses a versioned `Codable` payload in `UserDefaults`. It contains no transcript content or credentials.

Snapshots are keyed by normalized profile plus canonical stored session ID. Runtime and alternate IDs are resolved against the refreshed catalog before lookup. When the version-1 resume store is absent, it imports the existing per-profile active-session map once. After a successful import, the coordinator store becomes the sole automatic-resume source; the legacy map is no longer read or written.

The store retains at most 100 session snapshots, pruning least-recently-updated entries after a successful save. Viewport changes update the in-memory snapshot immediately and persist after a 300-millisecond debounce. A stable drag completion and the inactive transition flush immediately, allowing restoration after both normal backgrounding and process termination without writing on every scroll frame.

## Lifecycle data flow

### Inactive or background

1. `RootView` reports the scene transition once.
2. The coordinator freezes the last valid snapshot for the currently rendered canonical session.
3. Pending viewport writes are flushed.
4. Further geometry and `scrollPosition` callbacks are ignored for snapshot mutation until foreground restoration starts, preventing suspension layout from replacing a reading anchor with `followsLatest`.
5. `AppState` flushes presentation state and invalidates stale network reconciliation as it does today.

### Foreground or cold launch

1. Any notification or explicit navigation destination is checked first.
2. `AppState` refreshes the authoritative profile-scoped session catalog.
3. The pure resolver selects a target:
   - continue mode resolves the saved canonical/alternate identity and chooses that session;
   - latest mode chooses the newest eligible ordinary chat;
   - an unavailable continue target falls back to the newest eligible chat.
4. `AppState` reconciles the selected session and publishes the settled transcript identity.
5. The coordinator emits a generation-scoped restoration intent:
   - restore the semantic anchor in continue mode when available;
   - re-anchor by source message ID if a streaming projection changed the semantic fingerprint;
   - follow latest when requested by policy or required by fallback.
6. `ChatView` performs the nonanimated anchor restoration after SwiftUI installs the target rows. A delayed scroll from an older generation cannot run after restoration or user interaction.
7. Snapshot mutation resumes after the restoration intent completes or cancels.

## Explicit-action precedence

Automatic resume must never override intent expressed after it starts. The following actions increment the restoration generation and cancel older work:

- notification routing;
- tapping a session or changing profile;
- creating a conversation;
- submitting a message or invoking jump-to-latest;
- deliberately dragging the chat;
- disconnecting or changing servers.

Notification routing continues to use its existing destination preparation and layout handoff. The resume coordinator supplies cancellation and does not replace that flow.

## Failure handling

- Missing or ineligible saved session: remove or supersede the stale last-session reference and open the newest eligible chat at its bottom.
- Missing saved anchor in an otherwise valid session: keep the session and follow its bottom.
- Corrupt, unknown-version, or partially decoded local payload: discard the payload, restore the default behavior, and continue without presenting an error.
- Catalog or reconciliation failure: retain the frozen snapshot for a later attempt and use existing connection error handling.
- Runtime/stored ID disagreement: resolve through catalog aliases and the reconciliation-request/resolution pair before declaring the saved session missing.
- Stale callback or task: reject it by restoration generation and active profile/session identity.

Resume metadata is a convenience layer and must never prevent login, connection, session selection, or manual navigation.

## Testing

### Policy tests

- Continue mode chooses conversation A even when conversation B is newer.
- Latest mode deliberately chooses conversation B even when A is saved.
- Runtime, stored, and alternate IDs select the same canonical conversation.
- A missing or ineligible saved session falls back to the newest eligible chat.
- A notification or explicit destination overrides either automatic behavior.
- Profile-scoped IDs do not leak across profiles.

### Lifecycle and coordination tests

- A stable anchor is frozen on inactive and survives background/foreground.
- Suspension-time geometry callbacks cannot overwrite the frozen snapshot.
- Continue mode restores after cold launch and process recreation.
- New activity in B does not replace A in continue mode.
- New messages in A do not move a non-latest restored viewport.
- Latest mode selects B and follows its bottom after foreground and cold launch.
- Reconciliation must settle before a non-latest anchor is applied.
- User interaction, notification routing, and session/profile changes cancel stale restoration generations.
- A changed streaming projection re-anchors by source message ID.
- A missing anchor stays in the selected conversation and follows its bottom.

### Store tests

- Continue mode is the unsaved/default behavior.
- Preference and snapshots survive a new store instance.
- Encoding and decoding preserve all restoration metadata.
- Corrupt and unknown-version payloads reset safely.
- Snapshot pruning retains the 100 most recently updated entries.
- Runtime aliases migrate to canonical keys without losing snapshots.

### Acceptance testing

Run the focused unit tests and the complete Conduit test suite, then verify on Simulator:

1. Open A, scroll to an older message, background Conduit, create or receive newer activity in B, and return in continue mode. Conduit must show A at the saved message.
2. Repeat after terminating and relaunching Conduit.
3. Repeat both flows in latest mode. Conduit must show B at its bottom.
4. Add new messages to A while backgrounded. Continue mode must preserve the reading position and expose jump-to-latest.
5. Delete the saved conversation and relaunch. Conduit must open the newest eligible chat without an error.
6. Trigger a notification while automatic restoration is pending. The notification destination must win.

## Implementation boundary for PR #19

PR #19 should replace or simplify callback-driven restoration code where the coordinator assumes ownership. It should not add another independent scene observer or retain two sources of automatic session selection. Existing semantic-anchor and alias-resolution code may be reused when it fits these boundaries; code introduced by earlier attempts should be removed when the coordinator makes it redundant.

The PR is complete when both behaviors work across foregrounding and cold launch, the A-to-B regression has an automated policy/lifecycle reproduction, and all existing tests remain green.
