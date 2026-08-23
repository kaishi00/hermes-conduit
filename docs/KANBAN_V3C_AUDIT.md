# Kanban V3C — Upstream Audit (bulk operations + selection)

- Upstream: https://github.com/NousResearch/hermes-agent @ **2eaa863112d2980bbe6f15ea409a6a29e50964fe** ("Merge pull request #93102 from kshitijk4poor/feat/bot-envelope-ttl", 2026-08-24 01:10:53 +0530); audited 2026-08-24.
- Sources: plugins/kanban/dashboard/plugin_api.py (line ranges are navigation aids, not machine-verifiable evidence), apps/desktop/src/plugins/kanban/{api.ts (bulkTasks at ~221), board.tsx (SelectionBar ~954-1068, selection/prune ~1102-1161)}.

## POST /tasks/bulk?board=<slug> (plugin_api.py:1297-1454)
- BulkTaskBody: ids (list[str], required non-empty -> 400 "ids is required"), status?, assignee? ("" or None = unassign), priority? (Int), archive (bool false), result/summary/metadata, reclaim_first (bool false), model_override/provider_override/clear flags, reasoning_effort/clear (all OUT OF SCOPE for Conduit).
- Independent per-task iteration (docstring: "per-task failures don't abort siblings"). Per-TASK outcomes appended in REQUEST order: {id, ok:True} or {id, ok:False, error}.
- Failure strings: "not found", "archive refused", "transition to 'x' refused", "Cannot set status to 'running' directly; use the dispatcher/claim path", "unknown status 'x'", "assign refused", RuntimeError str(e), and a defensive per-task except -> str(e) ("one bad id shouldn't kill the batch").
- status: done->complete_task, blocked->block_task, review->request_review(force=True, reviewer=assignee), ready->unblock/reopen/_set_status_direct, running->refused, scheduled->schedule_task, todo/triage->_set_status_direct; else unknown status refused. Omitted when archive=true.
- assignee: reclaim_first ? reassign_task(tid, assignee or None, reclaim_first=True) : assign_task(tid, assignee or None). So Unassign = {assignee: "", reclaim_first: true} -> reassign(None, reclaim).
- priority: NO bounds/normalization upstream — direct int UPDATE + 'reprioritized' event. Conduit keeps plain integer semantics (same as single-task priority).
- Response: {"results": [{id, ok, error?}]} — HTTP 200 even when every entry is ok:false. No rollback, no transaction.

## Desktop product semantics (board.tsx SelectionBar + selection):
- Selection: Set<string> of task IDs; toggleSelect; Escape clears. Selection NOT scoped to a context stamp in Desktop (client Page) — Conduit ADDS board/server ownership per the V3C spec (selectionContext stamp).
- Prune: useEffect([board]) -> alive = all column task IDs in the current board snapshot; selection = selection ∩ alive (ghost IDs removed when they left the board; NOT when merely moving lanes).
- finish(failed): invalidate board (ONE authoritative refetch after each bulk op); notify "N of M failed: firstError"; onDone(failedIds) -> selection := failed set ONLY (successful IDs leave selection, failed stay for retry).
- Top-level bulk error (onError): notify error; selection untouched (all remain selected).
- bulkDelete: NO backend bulk-delete; fan out DELETE /tasks/{id} per selected id via Promise.allSettled; rejected -> {error, id}; all settle; one finish (one board invalidation). Conduit mirrors this with a dedicated KanbanStore.bulkDeleteTasks under ONE mutation ownership + ONE authoritative reconciliation.
- Move destinations: columns.filter(name => !isLockedTarget(name)) — locked lanes (review/running/scheduled) never offered; bulk archive uses {archive:true} (separate control), NOT move-to-archived.
- Assign roster: profiles (fetchProfiles); Unassign item {assignee:'', reclaim_first:true}.
- Desktop has no bulk Priority UI despite backend support — Conduit exposes it under More… (V3C scope).

## Known coverage gaps (tracked, non-blocking)
1. Busy serialization (mutationInProgress single-live-op) - UI-level, not unit-tested.
2. Staged-confirmation immutability (PendingBulkDelete freeze-on-tap) - UI-level.
3. Board-change selection clearing end-to-end - covered via the isOwned predicate + fail-closed store path.
4. Polling prune end-to-end - pure predicate tested.
5. Immutable capture vs selection mutation - guaranteed by by-value ids + store normalization; the parked-request retargeting test covers the board-switch half.
6. Top-level bulk failure keeps all selected - the view keeps selection on throw; the store asserts mutation error + reload.
7. Auto-exit on empty selection / disabled controls in selection mode - UI-level.
8. Upstream 400 "ids is required" missing-field path - client-side empty guard tested; upstream 400 path not synthesized.
