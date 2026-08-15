# Design Spec: Answerable Clarify Cards After Background Arrival (Plugin-Owned Loop)

**Date:** 2026-08-14
**Branches:** `clarify-visibility-decisions` (notifier), `clarify-cards-background-arrival` (iOS)
**Follow-up to:** PRs #60 / #5 (approval cards; merged)
**Status:** Implementing

## Problem

A clarify raised while Conduit is backgrounded misses the one-shot
`clarify.request` stream event. Unlike approval, `clarify.respond` is
request-id-only and that id is minted inside the gateway (`_block`), so no
plugin hook can observe it — Phase 1's approval architecture (observer hook +
session-keyed respond) cannot apply. Verified 2026-08-14 against Hermes
source:

- The clarify text-intercept (`resolve_text_response_for_session`,
  `get_pending_for_session(include_choice_prompts=True)`) is wired only into
  chat-platform adapters (`gateway/platforms/base.py`), not the TUI/desktop
  WebSocket path Conduit uses.
- Typed replies during a pending clarify are **queued** (`prompt.submit`
  mid-turn queueing), not intercepted — they reach the agent only after the
  clarify resolves (default `agent.clarify_timeout` = 3600s; `<= 0` unlimited).
- A late `clarify.respond` returns **success** `{"status": "expired"}`
  (allow-expired bridge), so a card with a synthetic id would falsely render
  ANSWERED — visibility-only cards must not render answer controls.

## Chosen approach (user decision): plugin-owned loop

The notifier plugin already runs on the user's gateway; it mints its OWN
clarify id, pushes an answerable card, and answers flow back through the
relay. No upstream dependency.

### Key discovery: `tool_execution` middleware, not tool override

`agent/tool_executor.py` dispatches `clarify` through a hardcoded
`elif function_name == "clarify":` branch that imports the built-in
`clarify_tool` directly (`callback=agent.clarify_callback`) — a
`register_tool(override=True)` registration is not consulted on this path.
However, the same call runs through
`_run_agent_tool_execution_middleware(..., execute=_execute)`, and the
middleware contract explicitly supports wrapping the execution callback.

So the plugin registers **`tool_execution` middleware** filtered to
`tool_name == "clarify"`:

1. Read `args` (question, choices, multi_select).
2. Mint `clarify_id = "conduit-push-" + uuid4().hex[:12]` (prefix lets iOS
   route answers to the relay instead of `clarify.respond`).
3. Enqueue the `input.needed` event with the structured decision
   `{kind: "clarify", request_id, question, choices}` (labels flattened via
   the same label/description/text/title unwrap the built-in tool uses).
4. Run `next_call(args)` on a worker thread — this is the ORIGINAL path, so
   the gateway emits its own `clarify.request` and desktop/CLI answering is
   completely unchanged — while the middleware polls the relay for the
   plugin id's answer.
5. **First answer wins.** Relay answer → format the result exactly like the
   built-in tool (`strip_recommended`, multi-select parsing via the
   importable helpers) and return it. `next_call` answer → return that; the
   losing relay answer is ignored (a late respond to the plugin id after the
   gateway already resolved returns an "already resolved" status).
6. Orphaned worker threads are bounded daemon threads that exit at the
   clarify timeout; clarify frequency is human-scale.

Timeout: respect the gateway's configured clarify timeout
(`tools.clarify_gateway.resolve_clarify_timeout`), defaulting to 3600s; the
middleware never extends the wait beyond what the original path allows.

### Relay: pending-decision store + answer endpoints

New store slice `pendingDecisions: {id → {installationId, gatewayId, answer?,
answerAt?, createdAt, question, choices}}` (pruned past a 2h TTL, bounded
like eventIds):

- **Intake** — `validateEvent` keeps a decision when it is well-formed; the
  `/v1/events` handler saves it to the pending store after delivery.
  Clarify decisions require `request_id` + `question` (answerable contract);
  approval decisions unchanged (session-keyed; no pending entry needed —
  approvals answer via the gateway directly).
- `POST /v1/decisions/{id}/respond` — **device** credential; body
  `{answer}`. Resolves only for the same installation; first answer wins,
  later answers get `409 already_resolved`.
- `GET /v1/decisions/{id}` — **gateway** credential; same installation +
  gateway. Returns `{status: "pending" | "answered" | "expired" | "unknown", answer?}`.
  The plugin polls this (~2s interval) while its clarify blocks.

### iOS

- `PendingDecisionPayload.clarify(requestId, question, choices)` — parser
  requires the request id (relay rejects unanswerable clarify anyway).
- `recordNotificationDecision` records a normal pending `ClarifyActivity`
  with the plugin request id — the standard clarify card renders with
  working buttons.
- `AppState.respondToClarify` routes by id prefix: `conduit-push-` ids POST
  to the relay via `PushNotificationService` (relay URL the device already
  holds); gateway ids keep the `clarify.respond` RPC. Relay `unknown/expired`
  failures reuse the expired-prompt card UX from #60.
- Supersede: when a live `clarify.request` arrives (foreground case), drop
  any push-recorded card with the same question so the two paths never show
  duplicate cards for one logical clarify.

### Security / privacy

- Decision content remains gated on `decision_cards` (default on, dedicated
  preference) and bounded by the existing sanitizer + `validateDecision`.
- The answer channel is authenticated: devices answer with their own
  installation credential; the gateway polls with the gateway credential;
  the relay enforces installation match on both. Answers are bounded text.
- The plugin id carries no gateway capability — a compromised relay can at
  most answer a clarify the user already sees pushed.

## Phasing

1. Relay: pending-decision store + two endpoints + tests.
2. Plugin: middleware + push + poll + tests (poll client against a stubbed
   HTTP server).
3. iOS: parser/card/answer routing + supersede + tests; full suite.
4. End-to-end validation on a real gateway; docs.
