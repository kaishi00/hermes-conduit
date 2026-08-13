# Design Spec: Restore Answerable Pending Decisions After Background Resume

**Date:** 2026-08-13
**Branch:** `codex/clarify-background-resume`
**Status:** Approved design; implementation in progress

## Problem

When Conduit receives a clarification request or approval request while the app
is backgrounded, the notification arrives and the surrounding transcript is
present after the app returns to the foreground, but the answerable card can be
missing. The resume path merges the server transcript with the locally
persisted `SessionPresentationCache`. A resume snapshot with `running == false`
currently acts as a settled-turn signal and removes or refuses to restore
locally cached pending decision presentation. Hermes can report the transcript
without replaying the one-shot decision event, so this loses the only
answerable representation of the request.

## Goal

After a background-to-foreground resume, a pending clarification or approval
remains visible and answerable whenever Conduit has not received a gateway
record that resolves that exact decision.

The behavior must hold when the resume snapshot explicitly reports
`running == false`, and it must preserve the current notification, transcript,
cache, and response lifecycle behavior. An explicit settled gateway state must
still map to an idle session state; card visibility and session turn state are
separate concerns.

## Non-goals

- Do not change Hermes protocol messages or notification delivery.
- Do not introduce a separate decision inbox or a new gateway query.
- Do not change the existing clarification or approval response APIs.
- Do not keep a decision that the gateway has already answered, rejected, or
  otherwise resolved.

## Design

1. Treat a locally cached pending clarification or approval as eligible for
   resume whenever that decision is still unresolved. The value of
   `snapshot.running` must not by itself disable pending decision restoration.
2. Reconcile by the decision identity already used by
   `SessionPresentationCache`. A gateway message for the same decision key is
   authoritative: an answered/resolved gateway activity replaces the cached
   pending presentation, and no duplicate pending card is appended.
3. An explicit `running == false` with no resolved record must not remove a
   pending clarification or approval. The old approval-specific pruning path is
   removed because both cards have the same resume semantics.
4. Resolve turn state from the gateway snapshot. Explicit `running == false`
   remains `.idle`, which keeps the composer and decision controls usable while
   avoiding a false typing indicator or stop/steer action. An omitted running
   state may still use the existing conservative `.running` path when live
   projection or a pending decision makes the gateway state ambiguous.
5. Continue persisting the merged transcript through the existing presentation
   cache. Gateway-provided pending decisions observed without active-turn
   confirmation receive the same bounded unconfirmed marker as locally restored
   cards, so they expire rather than remaining answerable forever. User
   interaction continues through the existing clarification and approval
   response paths.

## Expected implementation surface

- `Conduit/Services/AppState.swift`: unify pending-decision resume eligibility,
  remove settled approval pruning, preserve idle turn state for explicit false,
  and apply bounded persistence to gateway-provided pending decisions.
- `Conduit/Services/SessionPresentationCache.swift`: use the shared pending-key
  helpers for reconciliation and keep expiry behavior type-independent.
- `ConduitTests/SessionPresentationCacheTests.swift`: cover cached and
  gateway-provided clarification and approval cards, explicit settled state,
  expiry, and resolved-decision suppression.

## Acceptance tests

- A cached pending clarification is restored when the resumed gateway response
  contains preceding assistant text, omits the clarification event, and reports
  `running == false`.
- A cached pending approval is restored when the resumed gateway response omits
  the approval event and reports `running == false`.
- Both restored cards remain pending and their existing answer paths are
  available while `turnState == .idle` for an explicit settled snapshot.
- A gateway-provided pending clarification or approval remains visible when
  `running == false` and is stored with the bounded unconfirmed marker.
- A gateway activity with the same request ID and an answered/resolved status
  (or the equivalent approval key) suppresses the cached pending card and
  leaves only the authoritative gateway representation.
- An unconfirmed gateway-provided card expires after
  `SessionPresentationCache.maxUnconfirmedPendingDecisionAge`.
- The existing full test suite remains green, including current pending
  approval and clarification cache tests.

## Verification

Run the focused pending-decision resume tests first, then run the complete
`Conduit` XCTest suite in the iOS Simulator. Review the final diff to confirm
that the change is limited to pending-decision resume reconciliation and its
tests.
