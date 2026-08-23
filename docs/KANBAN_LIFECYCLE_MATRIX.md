# Kanban Lifecycle / Status Matrix — V3A (audit-verified 2026-08-23)

Audited upstream: NousResearch/hermes-agent @ fd760435c (2026-08-22). Evidence: kanban_db.py VALID_STATUSES:102,
ui.tsx LOCKED_COLUMNS:51, board.tsx:317, plugin_api.py PATCH /tasks/:869-972, POST /tasks:623.

| Status | User create target? | Manual move target? | Backend/system transition? | Desktop behavior | Conduit V3A behavior |
|---|---|---|---|---|---|
| triage | YES (via triage flag) | YES (PATCH _set_status_direct) | specifier/decomposer flip triage→todo | creatable; specifier target | create OK; move OK; Specify/Decompose eligible |
| todo | YES (landing when parents open) | YES | recompute_ready promotes todo→ready | creatable | create/move OK |
| scheduled | NO | NO (desktop locks; PATCH works only from todo/ready/running/blocked via schedule_task — park semantics, not a plain target) | cron/automation parks; unblock_task exits | LOCKED_COLUMNS | visible; locked; never offered |
| ready | YES (default landing when parent-free) | YES | dispatcher claims ready→running | creatable / claim target | create/move OK |
| running | NO | NO — PATCH → HTTP 400 hard lock | worker/dispatcher owned | LOCKED_COLUMNS | visible; locked; claim/reclaim paths only |
| blocked | YES (create + PATCH block_task) | YES | dispatcher may unblock when parents done; sticky worker blocks stay | manual + worker transitions | create/move OK |
| review | NO | NO (request_review path only — parents+claim gated; not a generic move target) | claim/review dispatcher path | LOCKED_COLUMNS | visible; locked |
| done | YES | YES (PATCH complete_task) | worker completes | manual + worker | create/move OK |
| archived | NO create | YES (PATCH archive_task) | archive releases parents (recompute_ready) | archive action | archive action/move OK |
| unknown | NO | NO | treated system/backend-controlled | fallback render | render-only fallback |

Differences from Conduit V2 policy: NONE. LOCKED_COLUMNS unchanged; no creation/move contract change; scheduled's REST path no longer
requires a wake time but Desktop still refuses it as a target, so the user-facing policy is unchanged (documented, no regression needed).
