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
4. Else `false`.

### Resume re-assertion (`reassertSessionYolo`)

After every successful resume (`reconcile`, immediately after
`refreshChatResumeContext`), if a stored override exists and the server's
reported `yolo` disagrees, AppState re-sends `config.set { key: "yolo",
session_id, value }` via the same seam `setYoloMode` uses. It is a no-op under
`approvalsMode == "off"` (the floor dominates), when there is no override, or
when the server already agrees. Failure is non-fatal (logged via the `SessionYolo`
OSLog category); the local override still governs the indicator and the next
resume retries.

This single hook covers cold start, foreground re-sync, WebSocket reconnect, and
session switching because they all funnel through `reconcile`.

### Reversal of the PR-55 clear-on-conflict semantic

`applyRuntime` no longer clears a stored override when a fresh-resume snapshot
disagrees. The `reconcileExplicitYolo` parameter was removed from `applyRuntime`
and `applyChatResume` (it is still computed in `reconcile` to drive the buffered
`session.info` replay authority).

### UX: Model Picker toggle lock

When `approvalsMode == "off"`, the Model Picker YOLO toggle is locked on
(`.disabled`) with a note explaining the global floor, so users are not offered a
control that silently does nothing. The override is retained in the store so it
applies again if the profile mode changes.

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
