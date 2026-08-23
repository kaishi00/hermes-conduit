# Kanban V3B — Upstream Audit (board admin, filters, running-by-profile)

- Upstream: https://github.com/NousResearch/hermes-agent @ **f293e7206b4ddd66042329442c6afebc19a8808d** ("fix(dashboard): detect stale code after hermes update and refuse model picker with clear 503 (#86207)"), committed 2026-08-23 06:36:57 -0700; audited 2026-08-23.
- Sources: plugins/kanban/dashboard/plugin_api.py (lines cited), hermes_cli/kanban_db.py, apps/desktop/src/plugins/kanban/{api.ts, board.tsx, board-switcher.tsx, types.ts, i18n.ts}.

## Board CRUD contracts (exact)

### GET /boards (plugin_api.py:2462)
- Query: include_archived (default False) — archived boards are EXCLUDED from the switcher list by default.
- Returns {boards: [...], current}. Each board meta: slug, name, description, icon, color, default_workdir (null), project_id (null), created_at, archived (bool), db_path + enrichments is_current, counts, total (live cards only), default_workspace_kind, project_name.
- list_boards (kanban_db.py:956): always includes "default" first, others alphabetical (case-insensitive dir scan).

### POST /boards (plugin_api.py:2505) — CreateBoardBody {slug (required), name?, description?, icon?, color?, default_workdir?, project_id?, switch=false}
- slug normalization: _normalize_board_slug (kanban_db.py:551) = lowercase + strip; regex ^[a-z0-9][a-z0-9\-_]{0,63}$ -> ValueError -> HTTP 400.
- Idempotent: create_board (kanban_db.py:923) returns EXISTING metadata on slug collision ("mkdir -p semantics"). The response carries NO created/new flag — a client cannot tell "new" vs "returned existing" from the body alone (created_at is the original first-write timestamp).
- default_workdir validated: absolute + existing directory, else 400; resolved path stored.
- project_id: resolved via _resolve_project (id OR slug); when it resolves, its primary_path becomes default_workdir UNLESS default_workdir was passed explicitly.
- switch: true -> kanban_db.set_current_board(slug) — mutates the server-wide current pointer. Desktop sends NO switch (default false) and selects locally via its own atom.
- Response: {board: meta (+default_workspace_kind, project_name), current}.

### PATCH /boards/{slug} (plugin_api.py:2538) — RenameBoardBody {name?, description?, icon?, color?, default_workdir?, project_id?}
- slug is immutable (normalized + must exist -> 404).
- Tri-state (write_board_metadata, kanban_db.py:871):
  - field omitted/nil -> leave unchanged
  - default_workdir "" -> CLEAR (stored None); path -> validate + set
  - project_id "" -> CLEAR scope; value -> resolve + set
  - name "" -> server substitutes the default display name for the slug
- Project set (non-empty) with default_workdir omitted -> server MIRRORS the project primary repo into default_workdir. Re-sending the SAME project_id re-mirrors (this is the wire for "Project Default").
- Removing the project does NOT clear the previously mirrored default_workdir when ONLY project_id is sent (backend keeps it; a Desktop comment claims otherwise — backend is authoritative).
- CONDUIT adaptation (documented): the mobile editor's "No Project" path also lands the Default Workspace row on None/Scratch, so the Save sends an EXPLICIT default_workdir:"" alongside project_id:"" — clearing the stale mirror. The wire clears both intentfully rather than leaving a stale mirrored directory.
- Response: {board: meta (+default_workspace_kind, project_name)}.

### DELETE /boards/{slug} (plugin_api.py:2578) — delete: bool = Query(False) ("Hard-delete instead of archive")
- Default (no query / delete=false) -> ARCHIVE: directory moved to <root>/kanban/boards/_archived/<slug>-<ts> (recoverable; kanban_db.remove_board:1000).
- delete=true -> shutil.rmtree (hard delete). V3B exposes ARCHIVE ONLY; never sends delete=true.
- Restrictions surfaced as ValueError -> HTTP 400 (detail text preserved): the "default" board cannot be removed; unknown slug -> "board does not exist"; archiving the CURRENT board clears the server pointer back to default (backend handles); an already-archived slug no longer exists under its active name -> 400.
- Response: {result: {slug, action, new_path}, current}.
- NOTE: Desktop has NO archive UI (api.ts has no deleteBoard) — Conduit's Archive Board… is a mobile-native feature on the exact backend contract.

### POST /boards/{slug}/switch (plugin_api.py:2588) — persists the server-wide current pointer; the Desktop switcher never calls it (client-side localStorage selection). Conduit likewise NEVER calls it.

## Desktop product semantics

### Create flow (board-switcher.tsx NewBoardDialog:73-127)
- slug derived from name: name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') — ASCII-only; empty result disables Create.
- POST /boards {slug, name, project_id?} (NO switch); onSuccess: local selection = result.board.slug; boards list invalidated; dialog closes.
- Board Settings dialog: name + project picker only; slug read-only; PATCH {name, project_id}.

### Filters (board.tsx:870-938 dropdown, 1170-1184 predicate)
- Client-side over the loaded board: search over title/body/id (trimmed, lowercase, includes), tenant exact equality, assignee exact equality; AND composition.
- Show Archived toggles the SERVER include_archived fetch parameter (same state drives fetchBoard(archived)); it is NOT part of the client predicate.
- Filter options come from board.assignees and board.tenants ("All" = empty).
- Active indicator: Boolean(assignee || tenant || archived).

### Running grouped by profile (board.tsx:366-383, 865)
- $lanesByProfile persisted UI preference; lane groups ONLY for column.name === 'running'.
- key = task.assignee || UNASSIGNED_LANE ('unassigned'); groups sorted by key localeCompare (case-insensitive-ish); header renders assignee label (+Avatar when not unassigned).

### default_workspace_kind (plugin_api.py:2423): no workdir -> "scratch"; workdir inside a git repo -> "worktree"; else "dir".

## Conduit-adapted differences (documented)
1. Slug derivation mirrors Desktop byte-for-byte (ASCII); Conduit shows the generated slug and offers manual editing as an advanced option, validated against the upstream regex before POST.
2. Conduit sends switch: false explicitly (deterministic test; never true). Selection after create is local-only.
3. Board Settings extends Desktop's name+project dialog with description + default-workdir controls (backend fields; required by the V3B spec).
4. Archive Board… is Conduit-native (no Desktop counterpart), staging-by-value + fail-closed like card Delete.
5. Filters live in a native sheet rather than a dropdown; the predicate is extracted as a pure policy with the same semantics (search over title/body/id per upstream; Conduit deliberately keeps its V2-preserved extra matches — latest summary and assignee — in the search set).
