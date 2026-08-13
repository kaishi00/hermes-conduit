# Design Spec: Persist Session YOLO Overrides

**Date:** 2026-08-13
**Branch:** `codex/session-yolo-persistence`
**Status:** Implemented

## Problem

Conduit sends a session-scoped `config.set` request when the user changes YOLO
mode and updates `runtime.yolo` in memory. A later resume or turn snapshot can
omit the session-level `yolo` field while including the profile-level
`approvalsMode`; `applyRuntime` then derives `runtime.yolo` from that global
fallback and overwrites the user's session choice. The choice is also lost
when the app is relaunched because no local session override is stored.

## Goal

Remember the user's explicit YOLO choice for the current conversation across
turns, backgrounding, and app relaunch, while keeping the choice isolated to
that conversation and profile. Switching to a different session must reload
that session's own override or its current global fallback rather than leaking
the previous session's value.

## Non-goals

- Do not change the Hermes `config.set` protocol or profile-wide approval
  settings.
- Do not persist a value when the gateway rejects the setting request.
- Do not make one session's override affect another session, profile, or
  gateway identity.
- Do not add a migration for unrelated preference stores.

## Design

### Injectable session override store

Add a small `SessionYoloStore` backed by injectable `UserDefaults`. It stores an
optional override keyed by the normalized active profile and canonical session
ID. The optional state is important: `true`, `false`, and no local override are
three distinct states. The store should expose read and write operations that
are straightforward to exercise with an isolated defaults suite.

Canonicalization must use the existing session identity rules, including
catalog alternate IDs, so a runtime/session ID and the persisted conversation
ID address the same entry. Profile and session keys must remain independent.

### Runtime precedence

When deriving `runtime.yolo` for a session, use this precedence:

1. An explicit session-level `snapshot.yolo` from Hermes.
2. A locally persisted override for the active normalized profile/session when
   the snapshot omits session YOLO.
3. The profile-level `snapshot.approvalsMode` fallback.

The local override preserves the user's explicit choice when a later snapshot
omits session-level YOLO. When Hermes explicitly reports session YOLO, that
gateway state is authoritative; a conflicting local override is cleared so the
visible runtime and the server cannot diverge.

When the active session changes, recompute this value for the new canonical
session. A session with no override must not retain the previous session's
local value; it should use that session's snapshot/global fallback. Returning
to an overridden session must reload its saved choice.

### Write and lifecycle behavior

- `setYoloMode(_:)` calls the existing gateway method first. Only after success
  does it write the explicit boolean to `SessionYoloStore` and update
  `runtime.yolo`.
- On failure, the persisted value and visible runtime value remain unchanged,
  and the existing error reporting remains in place.
- Resume, foreground synchronization, session selection, and app relaunch
  paths must resolve the canonical active session and apply the store before or
  alongside runtime snapshot reconciliation.
- A new conversation without a canonical session ID has no session override;
  it must not reuse the last session's value.

## Expected implementation surface

- `Conduit/Services/SessionYoloStore.swift`: injectable profile/session-keyed
  persistence with explicit optional override semantics.
- `Conduit/Services/AppState.swift`: inject/use the store, persist successful
  changes, apply precedence, and refresh on session/profile transitions.
- `Conduit/Services/ChatScrollState.swift` or the existing identity seam only
  if a small reusable canonical-ID helper is needed; avoid duplicating
  normalization rules.
- `ConduitTests/SessionYoloStoreTests.swift` and/or
  `ConduitTests/AppStateChatResumeTests.swift`: store round trips, true/false
  distinction, profile/session isolation, runtime precedence, failure
  behavior, and session switching.

## Acceptance tests

- `true` and `false` overrides round-trip through an isolated `UserDefaults`
  suite, while an absent key returns no override.
- Overrides for two sessions or two profiles do not collide.
- A stored session override wins over a later snapshot containing only the
  profile/global approval mode.
- With no stored override, explicit `snapshot.yolo` still wins over
  `approvalsMode`, and `approvalsMode` remains the fallback when session YOLO
  is omitted.
- An explicit `snapshot.yolo` replaces a conflicting local override and clears
  the stale persisted value.
- Switching from an overridden session to an unoverridden session clears the
  previous local value from the visible runtime; switching back restores it.
- A failed `config.set` does not write the override.
- The complete existing test suite remains green.

## Verification

Run the store and AppState-focused tests first, then run the complete `Conduit`
XCTest suite in the iOS Simulator. Review the final diff to confirm that the
store is scoped only to profile/session YOLO state and that no profile-wide
setting is mutated.
