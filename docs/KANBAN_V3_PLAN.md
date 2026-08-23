# Hermes Conduit — Kanban V3 Plan (V3A implemented here; V3B–V3D scoped)

Status: V3A implementation in progress. Written 2026-08-23.

## Repo / branch facts
- Repo: kaishi00/hermes-conduit (origin: https://github.com/kaishi00/hermes-conduit.git)
- Branch: feature/kanban-v3a-orchestration-triage (tracking origin/main; PR #94)
- Base commit: 10719f4 — "Merge pull request #93 from kaishi00/feature/kanban-v2" (V2 merged; upstream iOS baseline)
- iOS test target: the Harness ios_test tool against this repo (scheme Conduit, prepare 'xcodegen generate'; see .ios-test.json at the repo root)
- project.yml picks up Conduit/** and ConduitTests/** automatically (XcodeGen). Never edit Conduit.xcodeproj.

## Keep-out list (do NOT modify)
- Conduit/Services/HermesClient.swift, chat/session WebSocket transport, reconnect logic, session restoration, prompt submission, streaming, message handling, viewport restoration.
- Conduit/Models/KanbanStatus.swift status policy UNLESS the current upstream audit proves the contract changed (then isolate + regress-test the change).
- V1/V2 invariants: DashboardTicketBridge-only Kanban networking; dedicated KanbanService; KanbanStore mutation ownership (KanbanOperationContext, configurationGeneration, performMutation, loadedBoardSlug, loadedContextStamp); concrete board slug pinning; stale-board non-actionability; shared cross-profile semantics (no ?profile= fabrication); post-mutation superseding reconciliation; dirty task drafts; dependency/model-editor identity isolation; context-bound destructive confirmation; polling fallback; lane-chip + vertical-card layout.

## Session playbook (how to continue if interrupted)
1. Read this file.
2. git status in the phase worktree (expect: branch feature/kanban-v3a-orchestration-triage).
3. Upstream audit: docs/KANBAN_V3A_AUDIT.md (upstream commit SHA recorded; re-verify if the upstream head moved).
4. Finish open todos: implement service/store/views/tests -> run the Harness ios_test tool (full) -> multi-model review (workflows/multi-model-review.js) -> fix findings -> push + PR -> final 17-item report.
5. AGENTS.md review gate applies BEFORE pushing to any PR.

## V3A scope (this branch)
- Re-audit lifecycle/status semantics vs V2 (matrix in report).
- Orchestration settings: read + update (auto_decompose, orchestrator_profile, default_assignee, auto_promote_children if present). Model configured vs resolved (resolved_* fields already decoded in KanbanOrchestrationSettings).
- Profile routing descriptions: list, edit (manual save), generate automatically; description_auto flag already decoded in KanbanProfile; dirty-draft protection; 'Automatically generated — review recommended' state if upstream stages generation.
- Nudge Dispatcher: lightweight board menu action (existing debounced POST /dispatch machinery extended for manual nudges; keep fire-and-forget but return unobtrusive 'Dispatcher nudged').
- Triage: Specify + Decompose as Task Detail 'Triage Actions' section, only when eligible (status == 'triage' per upstream audit; verify exact gate).
- Ownership discipline for every new mutation (freeze context pre-suspension; generation-guarded completions; post-mutation superseding board/detail reload).
- Error taxonomy: HTTP/network vs semantic {ok:false, reason} vs stale completion vs success-with-failed-refresh.
- Tests: lifecycle, orchestration read/update/defaults encoding, profiles (save/generate/dirty/stale), dispatcher (context, no-request-after-ownership-loss), specify (success/semantic-fail/network-fail/invalid-state/stale), decompose (success/semantic-fail/confirmation/reload/partial refresh failure/navigation race). No sleeps.
- Preserve entire existing suite; run full ios_test.

## Planned file layout (V3A)
- Conduit/Models/KanbanModels.swift: extend with orchestrations-patch/profile-description/(specify+decompose response) model types; tolerant decode; Codable wire fidelity from audit.
- Conduit/Services/KanbanService.swift: fetchProfileDescriptions (profiles already fetched), updateProfileDescription(profile:description:), generateProfileDescription(profile:), updateOrchestration(_ patch:), specifyTask(id:board:), decomposeTask(id:board:), manual nudge (or reuse scheduleDispatcherNudge with immediate-post variant); all behind DashboardJSONRequester; no HermesClient.
- Conduit/Services/KanbanStore.swift: store mutations mirrored on existing performMutation discipline; new published state for profile descriptions if needed (profiles already published); orchestration update; specify/decompose completion reconciliation (superseding reload of board+detail).
- Conduit/Views/KanbanViews.swift: board header gains an ellipsis '…' menu (Orchestration Settings…, Profiles routing list, Nudge Dispatcher). Keep header uncrowded.
- Conduit/Views/Kanban/KanbanOrchestrationSettingsSheet.swift (new): toggles + profile pickers; render 'Default (resolved)' clearly for configured-vs-resolved.
- Conduit/Views/Kanban/KanbanProfileRoutingScreen.swift (new): list + editor with multiline TextEditor, Save, Generate Automatically, generated-review banner, dirty ownership.
- Conduit/Views/Kanban/KanbanTaskDetailView.swift: 'Triage Actions' section gated on eligibility; Specify button; Decompose button + confirmationDialog ("Decompose this task?" with wording); semantic failure shown inline; success -> authoritative reload.
- ConduitTests/KanbanV3ATests.swift (new): policy + store-level deterministic tests with ContextRaceMockRequester-style mock (define locally in the test file).

## V3A completion checklist (from task)
[ ] upstream lifecycle semantics re-audited (SHA + date recorded)
[ ] orchestration settings readable/editable
[ ] configured vs resolved defaults represented correctly
[ ] profile routing descriptions editable
[ ] auto-description generation works (upstream semantics)
[ ] dispatcher nudged manually
[ ] eligible Triage tasks expose Specify
[ ] eligible Triage tasks expose Decompose
[ ] semantic failures distinguished from HTTP success
[ ] Decompose requires confirmation
[ ] successful actions reconcile from authoritative REST state
[ ] every new mutation board/server/task ownership-safe
[ ] V1/V2 mutation protections intact
[ ] full ios_test passes

## V3B (NEXT phase, do not implement here) — Board Administration + Board Views
- New Board / Edit Board / Archive Board (service methods createBoard/updateBoard already exist read-side; add store+UI), project & default_workdir editing.
- assignee filter, tenant filter (board payload already carries tenants/assignees arrays), Show Archived integration (include_archived exists), Group Running by Profile.
- Use actual upstream create/update/archive semantics; preserve per-dashboard board-selection persistence (scopedBoardKey).
- Own branch + PR + focused tests + full ios_test.

## V3C (later) — Bulk Operations
- Temporary mobile selection mode; bulk Move/Assign/Priority/Archive/Delete; UX like "Cancel | 3 Selected ... [Move] [Assign] [More…]".
- Bulk APIs may return per-task failures; NOT globally transactional unless upstream is; UI shows '2 tasks updated / 1 task failed / Task C <reason>'.
- Own branch + PR + tests + ios_test.

## V3D (later) — Live Events
- board-scoped /events WebSocket; architecture: upstream event -> debounce/coalesce -> invalidate relevant state -> authoritative REST refetch; event payload NEVER canonical board state; keep polling fallback; slow safety poll while healthy.
- Independent review (new long-lived connection, new reconnect/context ownership concerns); do NOT reuse chat/session WebSocket transport.
- Own branch + PR + tests + ios_test.

## Final V3A report (17 items)
1 starting Conduit commit (10719f4) 2 upstream SHA+audit date 3 lifecycle matrix + V2 diffs 4 endpoints/contracts audited 5 orchestration settings implemented 6 default/inheritance semantics 7 profile description editing/generation 8 nudge behavior 9 Specify behavior 10 Decompose behavior 11 semantic failure handling 12 concurrency/context ownership 13 files changed 14 tests added 15 exact full ios_test count 16 confirmation HermesClient/session transport untouched 17 V3B/V3C/V3D scope.
