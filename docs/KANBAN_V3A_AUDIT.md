# Kanban V3A — Upstream Audit (authoritative contract basis)

- Upstream repo: https://github.com/NousResearch/hermes-agent (clone at any revision >= the audited commit and diff against it)
- Audited revision: **fd760435c6688a2b6c6b7436dde30e267237baef** ("test(bedrock): make the botocore stub windows airtight — kills the vendored-import flake")
- Commit date: 2026-08-22 19:30:10 -0700
- Audit date: 2026-08-23 (session)
- Sources: plugins/kanban/dashboard/plugin_api.py, hermes_cli/kanban_db.py, hermes_cli/kanban_specify.py,
  hermes_cli/kanban_decompose.py, apps/desktop/src/plugins/kanban/{api.ts,types.ts,orchestration.tsx,ui.tsx,board.tsx,drawer.tsx}
- Backend behavior is authoritative for correctness; Desktop is authoritative for product semantics where the backend permits several.

## 1. Lifecycle / status contract (VS the V2-era assumptions)
- VALID_STATUSES (kanban_db.py:102): triage, todo, scheduled, ready, running, blocked, review, done, archived — unchanged.
- Desktop LOCKED_COLUMNS (ui.tsx:51): ['review', 'running', 'scheduled'] — UNCHANGED.
- Move menu filter (board.tsx:317): .filter(name => name !== task.status && !isLockedTarget(name)) — locked lanes are never offered;
  drag into a locked lane shows a lockedReason toast (board.tsx:1242-1243).
- PATCH /tasks/{id} status handling (plugin_api.py:869-972):
  - done → complete_task; blocked → block_task; review → request_review (force=True for dashboard human actions; still gated on parents/claims);
    ready → unblock/_reopen_if_review/_set_status_direct; archived → archive_task; todo/triage → _set_status_direct (TRIAGE IS a legal PATCH destination);
  - scheduled → schedule_task (valid only FROM todo/ready/running/blocked — kanban_db.py:7915-7957); no wake-time argument exists in the current REST path;
    desktop still refuses to offer it (LOCKED_COLUMNS).
  - running → HTTP 400 "Cannot set status to 'running' directly; use the dispatcher/claim path" — still hard-locked;
    unknown status → 400; invalid transition → 409.
- Create (POST /tasks, plugin_api.py:623): no status field; kanban_db.create_task (3158+) → triage=True forces 'triage', else 'ready' when no
  open parents else 'todo' (VALID_INITIAL_STATUSES exists only for internal caller; not reachable from REST).
- Conduit V2 policy conclusion: NO policy change required. review/running/scheduled remain system-owned manual destinations in Desktop
  (LOCKED_COLUMNS unchanged); backend 'scheduled' still sits behind schedule_task (park semantics, not the old wake-time story, but still
  not offered by Desktop and still not a plain drag target). triage/todo/ready/blocked/done/archived remain manual move targets;
  creation targets unchanged. Conduit's existing KanbanStatusPresentation matrix is preserved verbatim.

## 2. Orchestration settings
- GET /orchestration (plugin_api.py:2778-2818) → {
    orchestrator_profile: "", default_assignee: "", auto_decompose: bool (default True),
    auto_promote_children: bool (default True),
    resolved_orchestrator_profile: str, resolved_default_assignee: str, active_profile: str }
  Unset config = "" (empty string). Resolved fills in active default profile when unset/unknown.
- PUT /orchestration (2821-2889), body OrchestrationSettingsBody {orchestrator_profile?: str, default_assignee?: str,
  auto_decompose?: bool, auto_promote_children?: bool}. Only present fields are written. "" clears the override (falls back to default).
  Unknown profile name → HTTP 400. Response = GET shape (resolved echo). Server-global (NO board query param). Not dispatcher-nudged.
- Desktop picker (orchestration.tsx): value || '__default__' sentinel; onSave('__default__' → ''). So "Default" ⇔ "" empty string on the wire.
  No Conduit-specific encoding needed.

## 3. Profile routing descriptions
- GET /profiles (2628-2655) → {profiles:[{name, is_default, model, provider, description, description_auto, skill_count}]} — matches Conduit KanbanProfile.
- PATCH /profiles/{name} (2658-2688), body {description: str} → stores description (trimmed; "" clears) with description_auto=FALSE (user-authored).
  Response {ok, profile, description}. Not nudged. Unknown profile → 404. normalize_profile_name: "default" is valid.
- POST /profiles/{name}/describe-auto (2691-2716), body {overwrite: bool} → LLM-generated; PERSISTS immediately with description_auto=TRUE.
  Response {ok, profile, reason, description}. Non-ok is NOT an HTTP error (e.g. "no auxiliary client configured") — render reason inline.
  Desktop sends overwrite:true and replaces its local draft from result.description + refetches (orchestration.tsx auto onSuccess).
- Conduit addition required by the task (desktop has no guard): generating must NOT silently overwrite an unsaved manual draft → dirty-state ownership.

## 4. Dispatcher nudge (manual)
- POST /dispatch?board=<slug> body {} (plugin_api.py:2281-2299) → DispatchResult asdict {spawned: list[(id, assignee, workspace)], ...}.
  Desktop nudgeDispatcher ignores the body except {spawned?: unknown[]}; failures are non-events (nudged() .catch). Conduit: unobtrusive
  "Dispatcher nudged" only; no fabricated diagnostics. Board-scoped. Auto-nudge is debounced 400 ms (api.ts autoNudge) after task writes.

## 5. Specify
- POST /tasks/{task_id}/specify?board=<slug>, body SpecifyBody {author?: str} (plugin_api.py:1800-1841).
- Valid input: ONLY status == 'triage' (kanban_specify.py:159-162) → else outcome ok:false "task is not in triage (status=...)"; unknown id → "unknown task id".
- Behavior: aux LLM {title, body}; lenient JSON parse (fallback: whole reply as body, title untouched); specify_triage_task (kanban_db.py:7189-7277)
  updates title/body/assignee when provided and flips status triage → todo in one write txn; audit comment only when fields actually changed;
  'specified' event; recompute_ready() afterwards (parent-free tasks → ready immediately).
- Response: {ok, task_id, reason, new_title} — HTTP 200 EVEN when ok:false ("A non-OK outcome is NOT an HTTP error — the UI renders the
  reason inline"). Semantic failure MUST be inspected by the client.
- Resulting status: todo (then possibly ready via recompute_ready). Dependencies/metadata unchanged. Author recorded on comment.

## 6. Decompose
- POST /tasks/{task_id}/decompose?board=<slug>, body DecomposeBody {author?: str} (plugin_api.py:2727-2763).
- Valid input: ONLY status == 'triage' (kanban_decompose.py:288-291; same ok:false reason shape); unknown id likewise.
- LLM returns fanout:true + tasks[{title, body, assignee, parents(indices)}] OR fanout:false (single-task tighten == specify + optional assignee).
- fanout:false → specify_triage_task with assignee only when task.assignee is empty; outcome ok, fanout=false, new_title.
- fanout:true → decompose_triage_task (kanban_db.py:7280-7510), single write txn: creates children (status 'todo', tenant + workspace
  inherited from root, per-child overrides; children NEVER assignee=None — invalid picks rewritten to default_assignee); sibling dependency
  edges per parents indices; root task becomes child of every child (root wakes when all children done); root flips triage → todo and is
  assigned the ORCHESTRATOR profile; audit comment "Decomposed into <ids>..."; 'decomposed' event {child_ids, root_assignee};
  cycle check (Kahn) → ValueError → outcome ok:false "DB rejected graph: ...". auto_promote (config auto_promote_children, default True)
  → recompute_ready() promotes parent-free children to 'ready'; when False children stay 'todo' (manual-review-first workflows).
- Response: {ok, task_id, reason, fanout, child_ids: [], new_title} — HTTP 200 even when ok:false.
- Root task is NOT deleted; it remains the orchestration/root task. Response is NOT a full board snapshot (ids only — do NOT synthesize
  child cards; reload authoritative board + task instead).
- Failure reasons observed: unknown task id / not in triage / auxiliary client unavailable / LLM error / malformed JSON /
  fanout=true with empty tasks / tasks[i].title missing / DB rejected graph / task moved out of triage before decomposition.
- Non-ok reasons are stable product semantics → display verbatim.

## 7. Desktop triage actions
- Desktop exposes NO Specify/Decompose task actions (grep of board/drawer/orchestration/plugin: none). Endpoints serve the CLI and the
  gateway auto-decompose path. Conduit's Triage Actions are a mobile-native operational addition following the backend contract exactly
  (triage-only gating, {ok, reason} result semantics, no HTTP-error conflation).

## 8. Conduit file:line evidence
- Clerked above per claim (plugin_api.py / kanban_db.py / kanban_specify.py / kanban_decompose.py / api.ts / orchestration.tsx / ui.tsx / board.tsx line refs).
