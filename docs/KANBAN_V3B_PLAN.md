# Kanban V3B — Board Administration + Filters + Running-by-Profile

Branch: feature/kanban-v3b-board-admin (base origin/main f0ea33e — V3A merged). Upstream audit: docs/KANBAN_V3B_AUDIT.md @ f293e7206.

## Scope (this branch only)
Board create / edit / archive; project + default-workdir management; assignee filter; tenant filter; Show Archived folded into the filter sheet; Running grouped by profile. NOT: V3C bulk, V3D /events.

## Implementation shape
- KanbanModels: +icon/color/archived on board metadata (tolerant); KanbanCreateBoardRequest (switch:false explicit); KanbanUpdateBoardPatch (tri-state nil=omit, ""=clear).
- KanbanService: createBoard(request), updateBoard(slug, patch), archiveBoard(slug) — no hard delete; fetchBoards unchanged.
- KanbanStore: createBoard (server-scope validation; post-success: boards refresh + LOCAL selection of returned slug + superseding reload), updateBoard (board-scope stamp; settings tied to concrete loaded board; authoritative echo adopted), archiveBoard (board-scope stamp; DECODED result must be action==archived; post-success reconciliation: boards refresh -> validate local selection -> fallback -> single owned reload; partial-success refresh wording survives).
- Support policies (KanbanBoardAdministrationSupport.swift): slug derivation + validation (Desktop-identical), patch tri-state builder, filter predicate (search title/body/id + latestSummary/assignee, assignee/tenant exact equality, AND), stale-filter validation vs rosters, running grouping (assignee || 'unassigned', case-insensitive sort, running lane only, AFTER filtering), archive/selection reconciliation helpers, PendingBoardArchive staged value.
- Views: board menu gains Board Settings… / New Board… / Archive Board… (+ staged confirmation); KanbanBoardEditorView (create + settings modes, V3A editor ownership rules); filter sheet + filter button with active indication; running-lane grouped rendering; header search preserved; Archived toggle moved out of the header into the filter sheet.
- Persistence: Group Running by Profile = persisted preference (@AppStorage); assignee/tenant/search transient; Show Archived keeps existing state/flow.

## Ownership
Same discipline as V2/V3A: capture before suspension; store validates captured stamps back-to-back with context capture; server-scope for create; board-scope (full stamp) for update/archive; staged-by-value archive confirmation; stale completions UI-inert; local busy liveness via token; sheets dismiss on ownership change.

## Tests (KanbanV3BTests.swift, deterministic, no sleeps)
Create (payload encoding incl. switch:false + slug derivation + project/workdir encoding + server A->B race + local selection on success), patch (immutable slug, name-only omits project/workdir, project set/clear, workdir set/clear, project+explicit workdir, project-default re-mirror, server change fails closed, captured slug cannot retarget), archive (no hard-delete query, confirmation required, staged A cannot archive B, backend refusal preserved, selected-board fallback reconciliation, non-selected archive leaves selection), filters (assignee exact, tenant exact, search fields, AND, no store mutation, stale filter resets), archived (include_archived query, column appears/disappears, lane fallback), grouping (off flat, on running grouped, unassigned group, only running, after filtering, deterministic order).
Preserve existing suites; full ios_test; CI keeps ATTEMPT_TIMEOUT_SECS=1200 (do NOT change).

## Report items
1 starting SHA f0ea33e 2 upstream SHA 3 endpoints/contracts 4 create payload semantics 5 slug collision behavior 6 PATCH tri-state 7 project/workdir interaction 8 archive restrictions+reconciliation 9 proof no current-pointer mutation 10 filter architecture 11 grouping architecture 12 ownership model 13 files changed 14 tests added 15 exact ios_test counts 16 CI result 17 timeout still 1200 18 V3C/V3D + transport untouched.
