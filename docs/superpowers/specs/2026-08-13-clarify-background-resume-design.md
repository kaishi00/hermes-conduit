# Design Spec: Restore Answerable Clarifications After Background Resume

**Date:** 2026-08-13
**Branch:** `codex/clarify-background-resume`
**Status:** Approved design; implementation pending

## Problem

When Conduit receives a clarification request while the app is backgrounded,
the push notification arrives and the preceding assistant text is present after
the app returns to the foreground, but the clarification card can be missing.
The resume path merges the server transcript with the locally persisted
`SessionPresentationCache`. A resume snapshot with `running == false` currently
acts as a settled-turn signal and removes or refuses to restore locally cached
pending decision presentation. Hermes can report the preceding transcript
without replaying the one-shot clarification event, so this loses the only
answerable representation of the request.

## Goal

After a background-to-foreground resume, a pending clarification remains
visible and answerable whenever Conduit has not received a gateway record that
resolves that exact clarification request.

The behavior must hold when the resume snapshot explicitly reports
`running == false`, and it must preserve the current notification, transcript,
and cache lifecycle behavior.

## Non-goals

- Do not change Hermes protocol messages or notification delivery.
- Do not introduce a separate clarification inbox or a new gateway query.
- Do not broaden approval-card restoration semantics beyond what is required by
  shared reconciliation code; existing approval behavior remains covered by
  its current tests.
- Do not keep a clarification that the gateway has already answered, rejected,
  or otherwise resolved.

## Design

1. Treat a locally cached pending clarification as eligible for resume whenever
   the clarification is still unresolved. The value of `snapshot.running` must
   not by itself disable cached clarification restoration.
2. Reconcile by the clarification request identity already used by
   `SessionPresentationCache`. A gateway message for the same request ID is
   authoritative: an answered/resolved gateway activity replaces the cached
   pending presentation, and no duplicate pending card is appended.
3. An explicit `running == false` with no resolved record must not remove a
   cached pending clarification. The existing generic pending-decision pruning
   must be narrowed so it cannot discard this unresolved clarification.
4. When the restored clarification is pending, keep the session action-capable
   so the existing clarification response path can submit an answer. The
   restored card must not be downgraded to an inert historical row merely
   because the resume snapshot says the turn is no longer running.
5. Continue persisting the merged transcript through the existing presentation
   cache. Existing expiry and confirmation safeguards remain in force; user
   interaction continues through `respondToClarify`.

## Expected implementation surface

- `Conduit/Services/AppState.swift`: separate unresolved-clarification resume
  eligibility from the settled-turn pruning path and preserve actionability.
- `Conduit/Services/SessionPresentationCache.swift`: adjust only if the
  shared merge helper needs a narrow clarification-specific distinction.
- `ConduitTests/SessionPresentationCacheTests.swift`: add regression coverage
  for a background-style resume with preceding assistant text and
  `running == false`, plus the resolved-request suppression case.

## Acceptance tests

- A cached pending clarification is restored when the resumed gateway response
  contains preceding assistant text, omits the clarification event, and reports
  `running == false`.
- The restored clarification remains pending and its existing answer path is
  available to the session.
- A gateway activity with the same request ID and an answered/resolved status
  suppresses the cached pending clarification and leaves only the authoritative
  gateway representation.
- The existing full test suite remains green, including current pending
  approval and clarification cache tests.

## Verification

Run the focused clarification resume tests first, then run the complete
`Conduit` XCTest suite in the iOS Simulator. Review the final diff to confirm
that the change is limited to clarification resume reconciliation and its
tests.
