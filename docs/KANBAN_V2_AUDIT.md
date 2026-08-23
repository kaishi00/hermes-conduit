# Kanban V2 — Upstream Audit (source of truth: NousResearch/hermes-agent)

Audited files (upstream HEAD, shallow clone):
- `plugins/kanban/dashboard/plugin_api.py` (backend routes/schemas)
- `hermes_cli/kanban_db.py` (validation constants, create_task)
- `apps/desktop/src/plugins/kanban/{board,drawer,model-override,ui,i18n,api,types}.tsx/ts`

## 1. Task creation field matrix

| Field | Desktop exposes? | Backend field (`CreateTaskBody`) | Required? | Default / inheritance | Conduit support |
|---|---|---|---|---|---|
| title | yes (Input) | `title: str` | yes | — | exists |
| body/description | yes (Textarea) | `body: Optional[str]` | no | nil | exists |
| priority | yes (number input, default 0) | `priority: int = 0` | no | 0 | exists (picker) |
| assignee | yes: select `Default (<resolved>)` / profiles (minus resolved) / `Parked` | `assignee: Optional[str]` | no | Desktop sends `resolved_default_assignee \|\| "default"`; **Parked ⇒ omit the field entirely** (nil = unassigned; dispatcher default-assignee may pick up ready tasks later) | exists as raw string; V2 adds selection enum |
| workspace kind | yes: `scratch\|worktree\|dir`, initialized from board `default_workspace_kind` (fallback scratch) | `workspace_kind: str = 'scratch'`; validated against `{scratch, worktree, dir}` | no | board metadata → backend fallback scratch | request field existed but UI never set it from board; V2 fixes |
| workspace path | yes when kind ≠ scratch; empty = inherit board `default_workdir`; placeholder shows it | `workspace_path: Optional[str]` | no | backend resolves board/project dir | exists; V2 UI |
| skills | yes: free-text comma list (i18n placeholder `translation, github`) | `skills: Optional[list[str]]` | no | none | field exists; V2 adds picker seeded from Hermes `/api/skills` names + manual entry; serialized trimmed array |
| model override | yes (`ModelOverrideField`, detached state) | `model_override: Optional[str]` | no | unset = assigned profile's own model | exists; V2 UI |
| provider override | yes (part of same control) | `provider_override: Optional[str]` | no | unset | exists; V2 UI |
| reasoning effort | yes (effort submenu; '' = inherit; `none` = thinking off is a VALUE) | `reasoning_effort: Optional[str]`; valid: `none,minimal,low,medium,high,xhigh,max,ultra` (`hermes_constants.VALID_REASONING_EFFORTS` + none) | no | profile's own effort | exists; V2 UI |
| parents | yes: SINGLE parent select over board tasks (`parents: [parent]`), even though API accepts a list | `parents: list[str]` | no | [] | field exists; V2 single-parent picker matching product behavior |
| Goal Mode | yes: plain toggle. No max-turns control in Desktop UI | `goal_mode: bool = False`, `goal_max_turns: Optional[int] = None` | no | false / nil | fields exist; V2 toggle + max-turns control revealed only when enabled (API-backed mobile addition) |
| project ID | not in dialog (board-scoped project inherited server-side when omitted) | `project_id: Optional[str]` | no | board's scoped project | keep omitted |
| initial status | per-lane add button targets that lane; global New Task targets **triage**; locked lanes get no add button | `triage: bool` (+ follow-up PATCH when target ≠ created status) | no | triage flag → triage else ready/todo | store already implements guarded two-step creation |
| tenant | not in dialog | `tenant: Optional[str]` | no | nil | unchanged |
| idempotency key / max_runtime_seconds | not in dialog | accepted by API | no | nil | unchanged (kept for future) |
| estimate | yes (`estimateNew` button; makes an aux-model call) | POST `/estimate` | — | — | **deferred** (per task §21) |

Create submit semantics (desktop `submit()`): `assignee = PARKED ? undefined : (assignee \|\| resolvedDefault)`; `workspace_path` only sent when kind ≠ scratch and non-empty; model fields via `overrideCreateFields` (**omit** untouched fields on create); `goal_mode` always sent; `parents` only when chosen; `triage` flag only for triage target; then PATCH status if returned task status ≠ requested lane.

## 2. Task detail / mutation matrix

- **PATCH `UpdateTaskBody`**: `status, assignee, priority, title, body, result, block_reason, summary, metadata, model_override, provider_override, clear_model_override, reasoning_effort, clear_reasoning_effort`. NO goal-mode fields post-create ⇒ **Goal Mode is create-only**.
- Status transitions: `done`(complete_task), `blocked`(block_task), `scheduled`(schedule_task), `review`(request_review, only running/ready), `ready`(unblock/reopen/direct), `archived`(archive_task — plain PATCH, NOT destructive), `running`→400 direct-set, `todo/triage` direct. Unknown → 400.
- **Archive** = `PATCH {status:'archived'}` from drawer ⋯ menu. Delete = DELETE with destructive confirm (mobile keeps confirm).
- Drawer ⋯ menu: Copy task id · Copy title · Archive · Delete. Card context menu: Open/select/move-to-unlocked/delete.
- **Reassign**: POST `/tasks/{id}/reassign` `{profile, reclaim_first:true, reason?}` (drawer assignee menu lists roster profiles only). `profile` nil/"" unassigns.
- **Reclaim**: POST `/tasks/{id}/reclaim` `{reason?}`; 409 unless claimable (running).
- **Note & requeue** (running): addComment then reclaim — both endpoints Conduit already has.
- Diagnostics actions: only `reclaim` (button → reclaim endpoint) and `cli_hint` (copy `payload.command`). Never invent other mutations.
- Worker log GET `/tasks/{id}/log?tail=<bytes ≤ 2_000_000>` → `{exists,size_bytes,content,truncated}` (Conduit decodes this already).
- Activity event kinds mapped upstream: `created,status,assigned,commented,claimed,spawned,completed,blocked,unblocked,reclaimed,specified,promoted,scheduled,archived,reprioritized` (+ `edited`); unknown kinds fall back to kind + key=value detail.
- Runs: outcome/status badge (failed set `crashed|failed|timed_out|gave_up`), profile, duration(ended−started), relative time, error/summary lines.
- Model options source: desktop uses SDK catalog menu; kanban plugin also serves GET `/model-options` (`{providers:[{slug,label,models[]}]}`) curated so the dropdown can never offer a pair Hermes would reject — Conduit uses this via KanbanService (keeps Kanban networking on DashboardTicketBridge).

## 3. Deliberate mobile deviations
1. Composer is a grouped Form (Basics/Assignment/Execution/Dependencies) instead of one flat dialog; selectors push/sheet.
2. Skills: searchable multi-select sheet seeded from active Hermes config (`appState.skills` names) + manual add — superset of desktop's comma text input; identical serialized form.
3. Goal Mode max-turns stepper exposed (API supports `goal_max_turns`; desktop hides it).
4. Move To remains the movement primitive (no drag between columns); card menu gains Copy ID/Title/Archive.
5. Worker log is a dedicated push-in screen with explicit refresh (no 3s auto-poll while hidden).
6. Dependency chips show title + short id + status (data desktop doesn't render); tap replaces current detail (no sheet stacking).
7. Estimate controls deferred.
