# Design Follow-up: Session YOLO Server Authority

**Date:** 2026-08-13
**Branch:** `fix/session-yolo-server-authority`
**Follows:** [2026-08-13-session-yolo-persistence-design.md](2026-08-13-session-yolo-persistence-design.md) (PR #55)
**Status:** Implemented

## Problem

After PR #55 the per-session YOLO indicator persisted locally across turns and
relaunches, but it could disagree with what the server actually enforced:

1. **Global floor:** Hermes auto-approves whenever `approvals.mode == "off"`
   (`tools/approval.py`: `_YOLO_MODE_FROZEN or session_flag or approval_mode == "off"`).
   It is an OR, so no per-session toggle can require approvals while the profile
   is `off`. The local override made the indicator show the per-session choice,
   so it could claim "approvals on" while the server auto-approved everything.
2. **Gateway ephemerality:** the Hermes `tui_gateway` holds the per-session YOLO
   flag in an in-memory set (`tools/approval._session_yolo`) and its `config.set`
   handler never persists it. (The CLI *does* persist it, via
   `SessionDB.set_session_yolo` → `model_config.yolo_mode`, and restores it on
   resume — `cli.py:_restore_session_yolo`. Desktop/Conduit talk to the gateway,
   not the CLI, so they hit the gap.) After a gateway process restart or rebuilt
   agent the flag reverts to the profile default while the indicator keeps the
   user's choice.

The original PR-55 design assumed the server's fresh-resume `yolo` was
authoritative and cleared a conflicting local override. That assumption is wrong
for the gateway path: the post-resume value is the forgotten profile default,
not authority.

## Changes

### Indicator accuracy + global floor (`applyRuntime`)

`RuntimeState` now carries the last-known `approvalsMode`. The effective `yolo`
precedence in `applyRuntime` is:

1. Global floor: `approvalsMode == "off"` → `runtime.yolo = true` (be honest that
   Hermes auto-approves globally; a per-session toggle cannot require approvals).
2. Else a stored per-session override wins (the user's explicit choice).
3. Else the snapshot's `yolo` (or buffered-resume authority).
4. Else a non-off approval mode **reported by the snapshot itself** means
   approvals apply (`false`). A last-known mode with the signals omitted
   entirely is unknown, not a disagreement — the last-known indicator value is
   kept so partial projections cannot flicker it.

### Resume re-assertion (`reassertSessionYolo`)

After every successful resume, if a stored override exists and the server's
reported `yolo` disagrees, AppState re-sends `config.set { key: "yolo",
session_id, value }` via the same seam `setYoloMode` uses. Ordering inside
`reconcile`: the suspending `refreshChatResumeContext` runs first, then the
existing token/profile/client ownership guard re-validates the reconciliation,
then the buffered-event replay and the synchronous
`settleReconciliationAndPublish` complete atomically, and only then — gated on
the settle succeeding — does the re-assert fire. A profile or client switch
during the context refresh therefore aborts the write instead of pushing a
stale one. A residual race (a switch after the send begins) is accepted: the
value was chosen under verified ownership and the next resume reconciles.

It is a no-op under `approvalsMode == "off"` (the floor dominates), when there
is no override, when the snapshot does not report a session-level `yolo`
(unknown is not a disagreement — the gateway's `session.info` projection always
reports `yolo` as a boolean, so omitting it means "no signal", and re-asserting
every resume would be churn), or when the server's reported value already
matches the override. The floor check reads the same resolved source
`applyRuntime` maintains (`runtime.approvalsMode`: the snapshot's value when
present, else the last-known mode), so a snapshot that omits `approvals_mode`
cannot make the floor and the re-assert decision diverge. Failure is non-fatal
(logged via the `SessionYolo` OSLog category); the local override still governs
the indicator and the next resume retries.

Buffered `session.info` replay anchors the approval mode to the fresh resume
snapshot the same way it anchors `yolo` (`authoritativeApprovalsMode`), so a
stale buffered event cannot re-impose an outdated global floor.

This single hook covers cold start, foreground re-sync, WebSocket reconnect, and
session switching because they all funnel through `reconcile`.

**Known trade-off:** with clear-on-conflict removed, an override is only
cleared by an explicit toggle (or archive/delete). If a conversation were ever
reset server-side while reusing the same session ID, a stale override would be
re-asserted into it. Session IDs are freshly minted per conversation in
practice, so the store cannot distinguish a reconnect from a genuine new
conversation and this risk is accepted.

### Reversal of the PR-55 clear-on-conflict semantic

`applyRuntime` no longer clears a stored override when a fresh-resume snapshot
disagrees. The `reconcileExplicitYolo` parameter was removed from `applyRuntime`
and `applyChatResume` (it is still computed in `reconcile` to drive the buffered
`session.info` replay authority).

### UX: Model Picker toggle lock and manual-toggle guard

When `approvalsMode == "off"`, the Model Picker YOLO toggle is locked on
(`.disabled`) with a note explaining the global floor, so users are not offered a
control that silently does nothing. The same floor guards `setYoloMode` itself:
under `off` it returns early without sending `config.set` or persisting an
override (a write would be a server-side no-op, and a persisted override would
silently resurface when the profile mode changes back). This covers the `/yolo`
slash command and any other caller. The override is retained in the store so it
applies again if the profile mode changes.

`runtime.approvalsMode` is refreshed from snapshots, is mirrored immediately
when Approval mode is saved in Workspace & safety (re-resolving the effective
indicator through the same precedence `applyRuntime` uses, via the shared
`applyEffectiveYolo` helper, carrying the session-level value through so only
the floor/override precedence re-runs), and is reset on profile switch — along
with neutralizing `runtime.yolo` to the safe display — so one profile's floor
cannot leak into the next. The picker re-seeds its draft only when the save or
push crosses the `off` boundary — other mode changes (e.g. `manual ↔ smart`)
leave an in-progress draft untouched.

### Settings copy

Workspace & safety → Approval mode help text now documents the Hermes limitation:
when set to `off`, per-session YOLO toggles have no effect; use `manual` or
`smart` to enable per-session YOLO.

## What is NOT changed

- The Hermes `config.set` / `approvals.mode` protocol is untouched (Conduit
  cannot fix the gateway-side persistence; that lives in `nousresearch/hermes-agent`).
- `SessionYoloStore` remains a local cache of the explicit per-session choice.
- The global floor under `off` is a server-imposed limitation; Conduit reflects
  it honestly rather than masking it.

## Tests

`ConduitTests/SessionYoloPersistenceTests` was updated: the
clear-on-conflict cases were rewritten to assert the override now survives, and
new tests cover the global floor, the resume re-assertion (fire / skip-when-agree
/ skip-under-off / failure-is-non-fatal). See the file for the full list.
