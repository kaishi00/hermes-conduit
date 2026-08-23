# Kanban V3C — Multi-Select + Bulk Operations

Branch: feature/kanban-v3c-bulk-ops (base origin/main 3a682ae — V3B merged). Upstream audit: docs/KANBAN_V3C_AUDIT.md @ 2eaa86311.

## Scope
Mobile selection mode (context-owned), bulk Move/Assign/Unassign/Priority/Archive/Delete with per-task partial failures, one authoritative reconciliation per operation. NOT: /events, select-all-server, cross-board, bulk overrides/deps/workspace/text.

## Implementation shape
- KanbanModels: KanbanBulkTaskRequest (ids + status/assignee/priority/archive/reclaimFirst — minimal), KanbanBulkTaskResult/Response (tolerant; reconcile by ID), KanbanBulkOperationOutcome {succeeded, failures}, KanbanBulkFailure {id, reason}.
- KanbanService: bulkUpdateTasks(request, board) -> POST /tasks/bulk; deleteTasksFanout(ids, board) -> [KanbanBulkTaskResult] (per-ID DELETE fanout under one caller-owned context; every child settles; failures captured per ID; NO invented bulk-delete route).
- KanbanStore: bulkUpdateTasks(ids:patch:expectedContext: NON-OPTIONAL, includeArchived:) and bulkDeleteTasks(ids:expectedContext:) — guards (non-empty ids, !isMutating, validateExpectedContext actionable), context capture back-to-back, performMutation (ONE post-op superseding reload), outcome reconciliation via pure policy. All board-scoped.
- KanbanBulkOperationSupport: selection ownership (selectionContext stamp), prune(selected ∩ alive), reconcile(requested, results) -> succeeded + failed/unknown (missing outcome => failure with reason "Hermes returned no result for this task."; duplicates: first wins; unexpected extra ids ignored), PendingBulkOperation {ids sorted, context, action} frozen at tap, PendingBulkDelete staged for confirmation, destination = KanbanStatusPresentation.manuallySelectableStatuses minus archived (locked never offered), partial-failure display model + wording ("N updated, M failed" + per-task detail).
- KanbanViews: Select Tasks menu item + long-press to enter selection; selection header (Cancel | N Selected), tap toggles (detail navigation disabled), visually selected cards with accessibility traits; bottom bar Move/Assign/More… (Priority/Archive/Delete); sheets for Move destinations / Assign roster+Unassign / Priority stepper; staged confirmations for Archive + Delete; failures detail sheet; controls disabled while busy (single live bulk op, synchronous busy state); filter/search/board-admin disabled in selection mode; selection clears on board/server change; prune on authoritative board refresh; auto-exit when selection empties.

## Tests (KanbanV3CTests.swift, deterministic)
Wire per action (exact bodies incl. reclaim_first); context ownership (alpha->beta zero requests); immutable capture (selection changes after tap -> request still A+B); reconciliation (ok/fail/ok; missing outcome not success; extra id ignored); top-level transport failure keeps all selected; delete fanout per-ID outcomes + exactly ONE post-op reconciliation (board fetch count delta == 1); polling prune; board-change clears selection; locked destinations absent; priority integer encoding; staged confirmations immutable; busy serialization.

## Preserved
V3B board CRUD + filters/grouping/archive semantics, V1/V2/V3A ownership, single-task flows (move/delete/specify/decompose/etc. untouched), DashboardTicketBridge-only networking, ATTEMPT_TIMEOUT_SECS=1200 unchanged. No HermesClient/session changes. No V3D.
