# Kanban V3D — Upstream Audit (/events live invalidation)

- Upstream: https://github.com/NousResearch/hermes-agent @ **4a3e5c4094d96c2e184dead99bccb4f4aabb2e1b** ("Merge PR", committed 2026-08-23 16:28:56 -0700); audited 2026-08-24.
- DIFFERENCE FROM PROMPT: the prompt predicted upstream main at **8db59d08f45ba6285908be554da14e96ce5b3643**; current main is **4a3e5c409**. The /events contract inspected below matches the prompt's description in every audited respect (endpoint shape, auth gate, poll cadence, frame shape, board pinning), so no behavioral divergence was found — Conduit follows CURRENT SOURCE per the prompt's rule.
- Sources: plugins/kanban/dashboard/plugin_api.py (events WS + _ws_upgrade_authorized), hermes_cli/web_server.py (_ws_auth_ok canonical gate), apps/desktop/src/plugins/kanban/{api.ts bindApi/onEventsFrame, completion-notify.ts}, board.tsx.

## WS /api/plugins/kanban/events (plugin_api.py:2893-3016)
- Auth: upgrade authorized via the dashboard's CANONICAL WebSocket gate (`hermes_cli.web_server._ws_auth_ok`) — accepts loopback `?token=`, gated-OAuth single-use `?ticket=` (the browser SDK mints one per connect), or server-internal `?internal=`. Browsers cannot set Authorization headers on a WS upgrade; the credential rides in the query string. Rejected upgrades close with 1008 POLICY_VIOLATION.
- Query params: `since` (int; default "0"; malformed -> 0) and `board` (normalized slug; PINNED at handshake — "Changing boards mid-stream would require reconciling two cursors, so the UI just opens a new WS on board change").
- Server loop: polls task_events every **0.3 s** (`_EVENT_POLL_SECONDS`; receive() raced against that timeout to detect disconnects); `SELECT id, task_id, run_id, kind, payload, created_at FROM task_events WHERE id > ? ORDER BY id ASC LIMIT 200`; cursor = last row id of the batch; a frame `{"events":[...],"cursor":N}` is sent ONLY when the batch is non-empty.
- No application-level hello; client messages other than disconnect are ignored.

## Desktop semantics
- onEventsFrame (api.ts:63): empty events -> return (no invalidation). Otherwise invalidate ['kanban','board'] AND BOARDS_KEY metadata ("any event can change a card count"), then each UNIQUE non-blank task_id's detail cache. Completion notifications run AFTER invalidation and are failure-tolerant — CONDUIT DOES NOT PORT THEM (V3D scope is invalidation only).
- Socket lifecycle (api.ts:116-124): pinned to the board slug at open; board change closes + reopens against the new slug.
- Polls REMAIN as fallback while live events provide immediacy (8s board / 4s drawer).
- Desktop does NOT send `since` — it replays nothing only because it opens with an empty cache. Conduit IMPROVES on this by starting from GET /board latest_event_id (Conduit delta documented below).

## Conduit deltas (documented)
1. Initial `since` = authoritative `KanbanBoard.latest_event_id` from the just-loaded REST snapshot (closes the snapshot-vs-connect race; avoids replaying historical tables). nil/malformed/negative watermark -> live events unavailable for that snapshot; ordinary polling continues.
2. Cursor retained across reconnects WITHIN one context; never persisted; never crosses board/server boundaries.
3. Fixed trailing coalescing window (~300 ms) + single follow-up flush after an in-flight refresh (Desktop relies on React Query dedup instead).
4. Store-side disposition boundary refreshFromEvent (.refreshed/.deferred/.stale) so socket bursts can never fight mutations or loads.