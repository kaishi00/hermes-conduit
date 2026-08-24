# Kanban V3D — Live Events (invalidation only)

Branch: feature/kanban-v3d-live-events (base origin/main 8c115ad — V3C merged). Audit: docs/KANBAN_V3D_AUDIT.md @ 4a3e5c409.

## Shape
- Models (KanbanModels.swift): tolerant `KanbanLiveEvent` {id?, taskID?} + `KanbanEventFrame` {events, cursor?} — unknown fields/kinds ignored; malformed entries decode to nil/[] without crashing.
- Conduit/Services/KanbanEventStream.swift: `KanbanLiveUpdatePolicy` (backoff schedule, coalescing window, deferred retry delay, watermark validation), `KanbanEventInvalidation` {revision, context, taskIDs, boardInvalidated}, `KanbanEventBatchOutcome`, `KanbanEventStreamCoordinator` (@MainActor) owning ticket minting (fresh EVERY connect), URL construction via ConnectionURLPolicy.webSocketURL, URLSessionWebSocketTask behind the `KanbanEventSocket` protocol (receive/ping/cancel; production adapter cancels with .goingAway), monotonic cursor (never backwards), bounded reconnect backoff [1,2,4,8,15]s reset on establishment, fixed 300 ms trailing coalescing window with union merge + one follow-up flush after an in-flight batch, generation/context ownership (every await re-proves runID; stop() cancels loop/socket/delays FINALly).
- Conduit/Views/Kanban/KanbanLiveUpdateSupport.swift: `streamKey`, `shouldRefreshDetail`, `initialWatermark` (view glue deriving the stream identity and detail-refresh decisions from store state).
- KanbanStore: `refreshFromEvent(expectedContext:includeArchived:) async -> Disposition` (.stale zero-request when stamp != actionable loaded context; .deferred when isMutating/isLoading; .refreshed runs the ordinary non-superseding reload) + `@Published liveInvalidation` publication after a refreshed batch.
- KanbanViews: `.task(id: liveEventsKey)` (bridge identity|baseURL|generation|loadedBoardSlug) starts/stops the coordinator; onBatch -> refreshFromEvent (+retry-once when deferred) -> publishLiveInvalidation.
- KanbanTaskDetailView: onChange(of: store.liveInvalidation) -> touched displayed ID + matching context -> existing loadDetail() (draft protection untouched).

## Tests (KanbanV3DTests.swift)
Scripted `KanbanEventSocket` + gated sleeper (no wall-clock waits): URL/auth contract incl. fresh tickets across reconnects; initial watermark derivation + malformed-watermark no-connect; cursor resume/never-backwards/board-switch isolation; stale-context and stale-generation frames discarded; coalescing window union + exactly-one-follow-up; busy-store deferral then convergence; frame robustness (unknown kind/task_id-less/malformed JSON/empty events/unknown fields); touched-detail invalidation + dirty-draft safety via existing policies; mint-failure fallback keeps REST usable + constants unchanged (8s/4s); cancellation finality.

## Out of scope
Completion notifications, background/APNs work, event history UI, connection indicators, optimistic updates, event-kind reducers, polling optimization, test-suite consolidation, HermesClient/session transport.
