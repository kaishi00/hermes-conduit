# Chat Viewport Rewrite — Phase 0 Analysis & Behavior Ledger

Branch: `unified-chat-viewport` (from `origin/main` @ 9a06e33). Written 2026-08-18.

## 1. Current control-path inventory

Every path that can move (or decide not to move) the chat viewport today.
Line numbers refer to `Conduit/Views/ChatView.swift` at 9a06e33 (offset by
the Phase-0 trace additions, ~+30 lines past line 417).

| # | Path | Guard conditions | Scrolls? |
|---|------|------------------|----------|
| 1 | `.onChange(of: appState.messages)` | cache update ≠ unchanged && followsLatest && !pendingRestoration && !handoff; double-checked after `DispatchQueue.main.async` | `scrollToLatest` (animated + 150ms retry) |
| 2 | `.onChange(of: appState.chatScrollRequest)` (send path pulse) | none (always) | `scrollToLatest` |
| 3 | `.onChange(of: appState.chatScrollToTopRequest)` (title tap pulse) | none | `scrollToTop` (non-animated + 150ms retry) |
| 4 | `.onChange(of: appState.activeSessionId)` | notification branch vs equivalent-key branch vs real switch; `shouldFollowLatestAfterTransition(isDragging:)` | `scrollToLatest` on real switch when not dragging |
| 5 | `.onChange(of: appState.activeProfile)` | same shape as #4 + handoff branch | `scrollToLatest` |
| 6 | `.onChange(of: appState.streamingText)` | followsLatest && !pendingRestoration | raw `proxy.scrollTo(bottom)` per network delta — **no owner token, no retry, animated by ambient transaction** |
| 7 | `.onChange(of: appState.isBusy)` | !isBusy && followsLatest && !pendingRestoration | `scrollToLatest` |
| 8 | `scrollToLatest(using:)` | `guard !hasPendingRestoration`; claims latest owner | animated scroll + naked-delayed retry validated against `scrollOwnerState` |
| 9 | `scrollToTop(using:request:)` | claims top owner | non-animated scroll + retry validated against top owner token |
| 10 | `applyChatResumeRestoration` poll loop (`.task(id: restorationRequest?.generation)`) | `ChatResumeRenderRestorationState.nextAction` scope match (session + cache revision + restoration generation + transcript revision) + installed-target + confirmation checks; bounded 80 checks / retry every 4 | raw `proxy.scrollTo` (non-animated) for latest/anchor |
| 11 | `finishNotificationHandoffIfReady` (geometry + session + flag guards) | `handoffCompletionAction`: active top owner → top; else `shouldFollowLatestAfterTransition` → latest; else none | `scrollToTop` or raw `proxy.scrollTo(bottom)` (non-animated) |
| 12 | Latest-button overlay | `!followsLatest && !isNearBottom` visibility | `scrollToLatest` |
| 13 | `relatchFollowsLatestIfSettled` (both geometry preferences) | top-owner near-bottom return; `shouldRelatch` truth table | no scroll (mode change only) |
| 14 | **`.scrollPosition(id: $topVisibleChatID, anchor: .top)`** | SwiftUI-owned; writes on session change (`topVisibleChatID = nil`) | second, independent viewport authority |

Ownership state supporting these: `followsLatest` (Bool), `scrollOwnerState`
(`ChatScrollOwnerState` generation + owner), `chatDragLifecycle` +
`chatDragCompletionToken`, `notificationHandoffPending/SessionKey/HasMeasuredLayout`,
`renderedScrollSessionKey/Content/Targets/TranscriptRevision/ViewportTransitionGeneration`.

## 2. Overlapping-authority problems (the bug)

1. **Two viewport authorities.** Imperative `ScrollViewReader.scrollTo`
   (paths 1–12) coexists with the writable `.scrollPosition` binding (#14).
   SwiftUI's scrollPosition can re-anchor content that `scrollTo` just
   positioned (especially growing streaming content at the bottom), and the
   binding is also the only source of `topVisibleChatID` — one mechanism
   both *observes* and *moves*.
2. **Streaming follow is network-coupled.** Path 6 scrolls on every
   `streamingText` publication (33ms coalesced network projection), but the
   bubble visually grows between publications (StreamingText reveal pacing —
   explicitly out of scope to change). The viewport can lag the rendered
   bottom by up to one reveal quantum; nothing follows rendered growth
   between deltas.
3. **Owner tokens don't own everything.** Paths 6, 10, 11 call
   `proxy.scrollTo` with no owner token; their correctness rests on
   re-checking booleans at call time. Any interleaving that flips a boolean
   between check and scroll is a race the token system was built to prevent.
4. **Follow-latest has four homes.** `followsLatest` (view Bool),
   `scrollOwnerState.owner == .latest`, drag lifecycle validity, and the
   handoff booleans all participate in "are we following" — with different
   update points. E.g. the settle-handshake generation mirror is only
   updated *when following* in the session-change handlers but
   unconditionally in the messages/revision handlers.
5. **Geometry callbacks mutate ownership.** `updateBottomMarker` /
   `updateViewportBottom` feed `relatchFollowsLatestIfSettled`, so a layout
   tick can change viewport ownership — the spec requires geometry to report
   facts to one authority instead.

## 3. Preserved-behavior ledger → tests that pin it

| Spec behavior group | Pinned by (suite) |
|---|---|
| 1. Return behavior / durable resume (continue vs latest, fallbacks, recovery preserves current) | `ChatResumePolicyTests` (continue/latest/recovery/fallbacks/cron), `ChatResumeCoordinatorTests` (selection, freeze, fallback-to-latest, preserve-current), `ChatResumeStoreTests` (defaults, round-trip, corrupt payload), `AppStateChatResumeTests` (purpose retention, reconnect purpose) |
| 2. Stable restoration identity (profile in key, aliases, runtime rotation, semantic anchors, duplicates, source-ID fallback, no ephemeral IDs persisted) | `ChatScrollStateTests` (semantic anchors, duplicates, session identity/resolver, snapshot validity), `ChatTitleScrollTests` (synthetic top anchor → first message) |
| 3. Transition snapshot safety (capture before replace, freeze during replacement, rendered ≠ active key) | `AppStateChatResumeTests` (`testPreTransitionCapture*`, `testOpenSessionTeardownLayoutCannotReleaseTransitionBeforeReconciliation`, `testAuthoritativeEmptyTranscriptSettlesFromScopedRevisionZeroLayout`, revision-advance tests) |
| 4. Lazy transcript restoration (scope + revision + generation + installed-target verification, offscreen bootstrap, confirmation after layout, bounded retries) | `ChatScrollStateTests` (`testRestorationWaitsForMatchingRenderedTarget…`, `testMatchingScrollPositionCannotCompleteBeforeActualRowRegistration`, `testLatestRestorationRequiresMatchingBottomLayout…`, `testRenderRestorationTimesOut…`) |
| 5. User drag wins | `ChatScrollStateTests` (relatch truth table, completion-currency, transition-keeps-follow-disabled, canonical persistence key, drag lifecycle family, async completion sequencing) |
| 6. Explicit commands win | `AppStateChatResumeTests` (send/steer/redirect/slash invalidate restoration), `ChatScrollStateTests` (latest reassert yields to restoration/handoff), `ChatTitleScrollTests` (monotonic top request, top retry superseded by later owner) |
| 7. Title-to-top | `ChatTitleScrollTests` (scoped anchor, retry owner, handoff top win, synthetic anchor persistence) |
| 8. Notification handoff | `ChatTitleScrollTests` (handoff completion actions), `AppStateChatResumeTests` (stale notification continuation, busy flag, empty-canvas protection via `isOpeningNotificationSession` freeze semantics) |
| 9. Rapid session switching | `AppStateChatResumeTests` (superseded branch, rapid 8-switch, cancelled open, stale token/sync exclusion) |
| 10. Selection & nested scrolling | `ChatTextSelectionTests`, `MarkdownSelectionCoordinatorTests`, `MarkdownTableLayoutTests` |
| 11. Dynamic content | `ChatScrollStateTests` (target cache rendering-changed handling + reassert policy) — **coverage gap: no test drives continuous rendered growth** (rewrite adds it) |

## 4. Phase-0 repro scenarios → coverage

| Scenario | Today's coverage |
|---|---|
| Normal long streaming | characterization `testCharacterizeStreamingDeltaFollowWhileFollowing` (per-delta scroll); rendered-growth behavior untested |
| Streaming Markdown/code | no direct test (MarkdownTableLayoutTests cover layout only) |
| Streaming table/wrapping changes | no direct test |
| User drag upward during stream | characterization `testCharacterizeDragDuringStreamDisablesFollowAndGeometryCannotRelatch` + `ChatScrollStateTests` relatch table |
| Title-to-top during stream | characterization `testCharacterizeTitleTopOwnerSurvivesUntilNearBottomOrNewerClaim` (partial — view-level guard is a documented gap) |
| Stream completion | characterization `testCharacterizeBusyEndScrollConditionTruthTable` (truth table only) |

Manual/simulator verification of the full scenario list is Task 8 in the
plan; `ChatViewportTrace` records the decision trail for those runs.

## 5. What the rewrite must keep true (contract summary)

- Freeze-before-replace and settle-on-rendered-scope handshake in AppState
  (`beginExplicitChatViewportTransition` … `chatViewportLayoutDidSettle`)
  stays exactly as is; the controller only changes *which view code*
  maintains the mirrored scope.
- `ChatResumeStore` schema, `ChatResumeCoordinator` freeze/complete/abandon
  generations, and the `.automaticReturn` / `.preserveCurrent` purpose
  split are untouched.
- The 126pt bottom padding anchor, `ChatTitleScrollAnchor` id scheme, and
  bottom-anchor id scheme (`chat-latest-<profile>-<sessionID>`) are kept —
  restoration matching and persisted-snapshot compatibility depend on them.
