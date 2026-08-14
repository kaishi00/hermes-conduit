# Design Spec: Surface Decision Cards That Arrive While Conduit Is Backgrounded

**Date:** 2026-08-13
**Branch:** `fix/decision-cards-after-background-arrival`
**Follow-up to:** PR #54 (Keep pending decisions visible after background resume)
**Status:** Proposed — awaiting sign-off

## Problem

When Hermes raises a clarification or approval request while the Conduit iOS
app is backgrounded, the user gets a push notification, taps it, the app
returns to the correct session — but **the answerable card never appears.**

PR #54 fixed a narrower case: a card that was already observed and cached
locally before the app was backgrounded survives a foreground resume. It does
**not** help when the decision event is raised *after* the app is already
backgrounded, because in that case the card was never observed and there is
nothing cached to restore.

## Root cause (confirmed against Hermes source)

A pending decision can only reach the iOS client today via a **one-shot live
WebSocket event** — `clarify`/`clarify.request` or `approval.request`
(`Conduit/Services/StreamEventParser.swift:93-106`), materialized by
`AppState.applyStreamEvent` (`AppState.swift:6810-6847`) and gated on the app
being foregrounded with that session active. When the decision is raised while
the app is backgrounded, iOS is suspended and never receives that event.

There is **no client-side fallback source** for the decision content after the
fact. Verified in `github.com/nousresearch/hermes-agent`:

- **`session.resume` does not carry the decision.** The cold-resume path
  (`tui_gateway/methods_session.py`, `@method("session.resume")`) returns
  `inflight: None`, `messages` = the stored transcript, and `status: "idle"`/
  `"waiting"`. The stored transcript never contains a decision card: decisions
  are live blocking prompts, not persisted message rows.
- **The decision is held only in gateway memory.** `_block()` in
  `tui_gateway/server.py` emits the `*.request` event **exactly once**
  (`_emit(event, sid, payload)`) and blocks the agent thread up to ~5 min. The
  payload lives in `_pending`/`_pending_prompt_payloads` (approval/sudo/secret)
  and `tools/clarify_gateway.py::_entries` (clarify).
- **No replay on reconnect, and no fetch RPC.** `_pending_prompt_payloads` is
  read only by `_session_pending_kind()` to derive `status: "waiting"`. There
  is no re-emit-on-transport-reattach and no `prompts.list` /
  `session.pending_prompt` RPC. Plugins cannot register gateway RPCs either
  (`hermes_cli/plugins.py::PluginContext` exposes `register_tool`,
  `register_approval_transport`, `register_middleware`, hooks — but no RPC
  registration).
- **`MessageNormalizer.normalizeMessages`** (`HermesClient.swift:1404`) maps
  only user/system/reasoning/tool/assistant roles. It has no clarify/approval
  handling, so any decision-shaped row would be dropped. This is also why PR
  #54's "gateway-provided pending decision" path is unreachable in production:
  `normalizeMessages` never emits `.clarify`/`.approval` messages, and PR #54's
  test builds that message by hand (`testApplyChatResumePreservesGatewayPendingDecisionWhenRunningIsNil`).

**Net:** the decision content is genuinely unreachable from the client after a
background gap. No purely client-side change can show the card.

## Existing notification pipeline (already a plugin → relay → APNs path)

Conduit already has a delivery channel for these events. From the Conduit
README and `kaishi00/hermes-conduit-notifier`:

1. **Notifier plugin** (`hermes-conduit-notifier`, repo `kaishi00/...`).
   `register(ctx)` subscribes to Hermes hooks (`__init__.py`):
   - `pre_tool_call` with `tool_name == "clarify"` → sends an `input.needed`
     event whose `body` is `clarification_text(args)` (the question text only).
   - `pre_approval_request` → sends an `approval.needed` event whose `body` is
     the approval `description` (skips `surface == "smart"`).
   - Each event is `push_event(type, session_id, profile, title, body)`
     (`events.py`) — **routing + a short text body only. No structured card
     data (request id, choices, command).**
   - `client.py` POSTs the event to `{relay_url}/v1/events` as a background
     worker.

2. **Relay server** (`push.milim.dev`; source is `relay/` in
   `kaishi00/hermes-conduit-notifier` — Node.js, self-hostable). Receives
   `/v1/events`, maps them to APNs, and pushes to iOS. `notificationFor()`
   builds the APNs `conduit` payload, which currently carries only
   `session_id` / `profile` / `type`; `validateEvent()` whitelists event fields
   and drops everything else.

3. **iOS** `PushNotificationService.receiveNotificationPayload`
   (`PushNotificationService.swift:192`) parses only `session_id`/`profile`/
   `type` into a `ConduitNotificationTarget` and discards everything else.

So the pipe that could carry card content already exists end to end — it just
only carries a routing stub today.

## Goal

When a clarification or approval is raised while Conduit is backgrounded, the
full answerable card (question + choices for clarify; description + choices +
the identity needed to respond for approval) is delivered to the device **at
notification time**, cached locally, and rendered on the next foreground —
without depending on the one-shot stream event or any new gateway RPC.

## Non-goals

- Do not change the Hermes gateway itself (no upstream PR; Nous have no mobile
  client and the merge outlook is poor). The gateway-side work is a **plugin**
  the user already ships and controls.
- Do not change the foreground decision flow. When the app is foregrounded and
  connected, the existing `*.request` stream event path is unchanged.
- Do not introduce a new gateway RPC or a "decision inbox."
- Do not change `clarify.respond` / `approval.respond`.

## Design

Enrich the existing pipeline so decision **content** rides along the
notification, then cache it on receipt (which runs from the APNs handler and
therefore works while backgrounded). On resume, PR #54's cache-restore path
(`SessionPresentationCache.merge` with `includePendingClarifications` /
`includePendingApprovals`) renders the cached card.

This is strictly stronger than fetch-on-resume: the card is captured on the
device the moment the push lands, so it is visible even if the user does not
immediately open the notification, and it survives the agent's ~5-minute
server-side prompt timeout (the card stays visible; only a late *response*
would be rejected).

### Approval — clean and fully answerable

The `pre_approval_request` hook already has everything needed:

- `session_key` (approvals are session-keyed; `approval.respond` takes
  `{choice, session_id}` — confirmed at `HermesClient.swift:932`. No separate
  request id required to respond.)
- `command`, `description`, `pattern_key`, and the allowed choices
  (derivable from `allow_permanent` / `smart_denied` per
  `_emit_approval_request` in `server.py`).

**Plugin change:** in `_pre_approval_request`, include a structured
`approval` object in the event: `{session_key, description, command (redacted),
choices, allow_permanent}`. (Use observer-hook capture — additive, leaves the
foreground `approval.request` event path untouched. This matches the chosen
"Observer hook" direction.)

**Relay change** (`relay/src/server.mjs` in the notifier repo): accept the
`approval` object in `validateEvent()` and forward it into the APNs `conduit`
payload in `notificationFor()`.

**iOS change:** `PushNotificationService` parses the `approval` object, builds
an `ApprovalActivity` (status `.pending`), wraps it in a `.approval`
`ChatMessage`, and writes it to `SessionPresentationCache.save` for that
session on receipt. PR #54 restores it on resume; the existing
`respondToApproval(sessionId:choice:)` answers it.

### Clarify — answerability is blocked by the gateway; only visibility is plugin-reachable

Verified against Hermes source (`tui_gateway/server.py`, `tools/clarify_gateway.py`,
`hermes_cli/plugins.py`):

- `clarify.respond` resolves **only** by `request_id`
  (`server.py::_respond`: `_pending.get(r)`). It is **not** session-keyed,
  unlike approval. (`resolve_text_response_for_session` in `clarify_gateway`
  is a separate text-fallback path for new prompts, not a `clarify.respond`
  route.)
- That `request_id` is the `rid` generated inside `_block()`. The gateway's
  clarify callback is `clarify_callback → _block("clarify.request", sid,
  {question, choices})` (`server.py:5879`); `_block` mints the `rid`, sets
  `payload["request_id"] = rid`, stores it in `_pending`/
  `_pending_prompt_payloads`, and emits `clarify.request` exactly once.
- **No plugin hook surfaces it.** `VALID_HOOKS` has only `pre_tool_call` /
  `post_tool_call` (they fire before/after execution, with no id).
  `clarify_gateway`'s `register_notify` callbacks are a gateway-internal
  adapter bridge, not a plugin hook.
- **Overriding the clarify *tool* does not help either.** The rid is created
  inside the gateway callback the tool delegates to, so a plugin-provided
  clarify tool still never sees it.

So, unlike approval, a pure observer-hook capture cannot make clarify
answerable after a background gap. The options are:

- **B. Visibility-only (plugin-only; ships now).** `pre_tool_call` ships the
  question + choices so the card appears (fixes "cards do not appear"), but the
  cached card carries no `request_id`, so it **cannot be answered** after a
  background miss (the live `clarify.request` is gone and the id is
  unreachable). Use only as an interim, with explicit "reopen within the
  waiting window to answer" framing — and accept that if the user does reopen,
  the live event will not re-deliver, so answering still fails. Honest about
  the limitation; addresses visibility only.
- **C. Plugin-owned clarify loop (plugin-only; answerable; larger build).**
  Override the clarify tool with an implementation that mints its **own** id,
  routes question + choices + id through the relay, and resolves the answer
  through a relay → plugin response channel (not `clarify.respond`). Requires a
  new relay response-forwarding endpoint and iOS responding via the relay
  instead of `clarify.respond`. Risk: bypasses the gateway clarify path, so a
  co-resident desktop/CLI client would need the plugin to also emit
  `clarify.request` on its behalf.
- **D. Gateway re-emit (cleanest; upstream).** Re-emit the pending
  `clarify.request` (and `approval.request`) when a transport reattaches to a
  session. Fixes clarify answerability for every client and removes the need
  for C's parallel loop. This is small and generally useful (helps desktop
  reconnects too), so its merge outlook is better than a mobile-specific
  feature — but it still depends on Nous accepting it, which is uncertain.

**Recommendation:** ship **approval fully now** (Phase 1). For clarify, start
with **B** so the reported symptom ("cards do not appear") is addressed, then
pursue **D** for answerability (fall back to **C** only if upstream is refused
and clarify answerability is required).

### Component changes summary

| Component | Repo | Change |
| --- | --- | --- |
| Notifier plugin | `kaishi00/hermes-conduit-notifier` | Add structured `clarify`/`approval` content (incl. `clarify_id` for clarify) to `input.needed`/`approval.needed` events. Clarify via tool override (option A). |
| Relay server | `kaishi00/hermes-conduit-notifier` under `relay/` (Node.js; same repo as the plugin) | Extend `validateEvent()` + `notificationFor()` in `relay/src/server.mjs` to pass `decision` into the APNs `conduit` payload. Contract below. |
| iOS client | `hermes-conduit` (this repo) | Parse `clarify`/`approval` from the APNs payload; build + cache the card on receipt; PR #54 restores on resume. |

### Relay → APNs payload contract

Extend the existing `conduit` object. Keep `session_id`/`profile`/`type` as
today; add an optional `decision` object:

```jsonc
{
  "conduit": {
    "session_id": "<stored-or-runtime-session-id>",
    "profile": "default",
    "type": "input_needed",            // or "approval_needed"
    "decision": {                       // optional; present only for decision notifications
      "kind": "clarify",                // "clarify" | "approval"
      "request_id": "<clarify_id>",     // clarify only (from option A)
      "session_key": "<approval session key>", // approval only
      "question": "Which color?",       // clarify
      "description": "...",             // approval
      "command": "<redacted>",          // approval, redacted
      "choices": [                      // clarify: {label,value}; approval: ["once","session","always","deny"]
        { "label": "Red", "value": "red" }
      ],
      "allow_permanent": true           // approval
    }
  }
}
```

Constraints: APNs allows ~4 KB; decision payloads are tiny. **Security:** the
approval `command` MUST be redacted before it leaves the gateway (reuse the
gateway's `_redact_approval_command` semantics; the approval transport contract
already treats the request as display-only/redacted). Prefer sending
`description` over raw `command`; never echo credentials. This matters because
the README promises no third-party data handling, and APNs/relay is an
additional egress path.

### iOS changes (this repo)

1. `PushNotificationService.notificationTarget(from:)` /
   `receiveNotificationPayload`: parse the optional `decision` object into a
   typed structure (mirror `ClarifyActivity` / `ApprovalActivity`).
2. On receipt, build the corresponding `.clarify` / `.approval` `ChatMessage`
   (status `.pending`) and persist it via `SessionPresentationCache.save`
   (`preservePendingDecisionCards: true`, with the bounded unconfirmed marker
   so it cannot linger forever — same safeguard PR #54 uses). This runs from
   the APNs delivery callback, so it works while backgrounded.
3. On resume, PR #54's `applyChatResume` → `merge` path already restores
   cached pending cards; verify it renders a card cached this way (it should,
   since the cache shape is identical to a live-observed card). Reconcile by
   decision key so a later live/gateway card replaces the cached one without a
   duplicate.
4. Keep the existing foreground path authoritative: if a live `*.request`
   arrives for the same key, it supersedes the cached push card.

## Open issues / decisions

- **Clarify answerability** — RESOLVED by investigation: no plugin hook exposes
  the clarify `request_id`, and `clarify.respond` is request-id-only (not
  session-keyed). So plugin-only clarify is visibility-only (B); answerability
  needs C (plugin-owned loop) or D (gateway re-emit). See the Clarify section.
- **Relay is in-repo.** The relay source is `relay/` in
  `kaishi00/hermes-conduit-notifier` (Node.js, self-hostable), so the
  payload-forwarding change is a normal PR alongside the plugin — no closed
  component blocks the fix.
- **Self-hosting.** Because the relay is published, self-hosters receive
  decision content too once they update. (Conduit still defaults to the shared
  `push.milim.dev` for zero-setup use.)
- **Redaction** — must be enforced for approval `command` before it enters the
  payload (security-sensitive egress).
- **Coalescing** — multiple decision notifications while backgrounded: approvals
  are one in-flight per session; clarify is keyable by `clarify_id`. Cache by
  decision key so the latest pending card per session wins.

## Phasing

1. **Phase 1 — Approval end-to-end (vertical slice).** Plugin observer hook →
   relay payload → iOS parse/cache → card renders + is answerable on resume.
   Approval needs no new gateway RPC and no clarify-id work, so it proves the
   whole pipe with the least risk.
2. **Phase 2 — Clarify visibility (plugin-only, option B).** Extend
   `input.needed` to carry question + choices so the clarify card appears after
   a background gap. Answerability after backgrounding remains a known
   limitation pending D (or C).
3. **Phase 3 — Clarify answerability (option D preferred).** Pursue the
   gateway re-emit of pending `*.request` events on transport reattach
   upstream; fall back to C (plugin-owned loop) only if upstream is refused.
4. **Phase 4 — Hardening.** Redaction, bounded-expiry sweep, duplicate-key
   reconciliation, and regression tests for the background-arrival cache path.

## Acceptance tests

- An approval raised while the app is backgrounded produces an APNs payload
  whose `conduit.decision` carries description + redacted command + choices.
- iOS, on receipt (backgrounded), writes a pending `ApprovalActivity` to the
  session cache. Foregrounding renders the card answerable via the existing
  `respondToApproval` path, with `turnState == .idle`.
- A clarify raised while backgrounded yields a cached `.clarify` card carrying
  the `clarify_id`; foregrounding renders it answerable via
  `respondToClarification`.
- A later live `*.request` for the same decision key supersedes the cached
  push card without producing a duplicate.
- An unconfirmed cached card expires after
  `SessionPresentationCache.maxUnconfirmedPendingDecisionAge`.
- The existing `SessionPresentationCacheTests` and full XCTest suite remain
  green.
