# Restore Answerable Pending Decisions After Background Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` or `superpowers:subagent-driven-development` to implement this plan task-by-task.

**Goal:** Keep unresolved clarification and approval cards visible and answerable after a background-to-foreground resume, even when the resume snapshot reports `running == false` and omits the one-shot decision event.

**Architecture:** Preserve the existing gateway-authoritative transcript and `SessionPresentationCache` merge. Treat pending clarification and approval cards as one pending-decision presentation class during reconciliation, use canonical decision keys, and keep explicit settled turn state separate from card actionability. Use the existing bounded unconfirmed-card cache protection for gateway-provided and locally restored cards.

**Tech Stack:** Swift, SwiftUI `AppState`, XCTest, XcodeGen, iOS Simulator.

## Global Constraints

- Do not change Hermes protocol messages or notification delivery.
- Do not introduce a separate decision inbox or a new gateway query.
- Do not change the existing clarification or approval response APIs.
- Gateway-resolved decision records remain authoritative and suppress cached pending duplicates.
- Explicit `running == false` maps to `.idle`; omitted `running` retains the existing conservative ambiguity handling.
- Unconfirmed pending decision cards expire after `SessionPresentationCache.maxUnconfirmedPendingDecisionAge`.

---

## Tasks

- [ ] 1. Add the failing regression tests (RED)
  - In `ConduitTests/SessionPresentationCacheTests.swift`, change the cached clarification test for an explicit `running == false` snapshot to expect `turnState == .idle` while retaining assertions that the card is pending, present, composer-enabled, and cached.
  - Replace the settled gateway approval-pruning test with a pending-approval restoration test: supply a gateway approval with `running == false`, assert the pending card remains in `AppState`, assert `turnState == .idle`, and assert it is cached for the grace period.
  - Add a cached pending approval test parallel to the cached clarification test: seed the presentation cache, resume with transcript text but no approval event and `running == false`, then assert the approval card remains pending and answerable.
  - Add an expiry assertion for a gateway-provided pending decision using an injected clock, so preserving gateway cards cannot create an unbounded stale-card path.
  - Refresh the generated project with `/Users/agrias/bin/bin/xcodegen generate`, then run the updated focused tests before changing production code. The approval tests must fail because the current implementation rejects approvals when `running == false`; the clarification test must fail because the current implementation reports `.running`.

- [ ] 2. Implement shared pending-decision resume reconciliation
  - In `Conduit/Services/AppState.swift`, set both pending clarification and approval restoration eligibility independently of `snapshot.running`; retain gateway decision-key matching so resolved records replace cached pending cards without duplicates.
  - Remove the explicit-`false` approval pruning branch and the manually rebuilt clarification-key set. Use `SessionPresentationCache.pendingDecisionKey(for:)`/`pendingDecisionKeys(in:)` for all pending decision identity comparisons.
  - Include gateway-provided pending decision keys in the unconfirmed preservation set whenever the snapshot is not explicitly active, so `SessionPresentationCache.save` keeps them with its existing bounded timestamp.
  - Keep the local restored-card confirmation guard for cards absent from the gateway result, while allowing both decision types to remain retryable after resume.
  - Resolve `turnState` from the gateway snapshot after applying the merged presentation: explicit `running == false` must remain `.idle`; only the existing ambiguous `running == nil` live-projection/pending-decision path may force `.running`.
  - Update comments/helper names in `AppState.swift` and `SessionPresentationCache.swift` to describe shared pending-decision behavior and the bounded unconfirmed safeguard.

- [ ] 3. Run focused verification (GREEN)
  - Run the complete integration group:
    `xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' -derivedDataPath /tmp/conduit-pending-decision-focused CODE_SIGNING_ALLOWED=NO -only-testing:ConduitTests/SessionPresentationCacheTests`
  - Confirm cached and gateway-provided clarification and approval tests pass, including explicit settled idle state, resolved gateway suppression, retryable submitting cards, and expiry.
  - Review the diff for accidental changes to response APIs, notification routing, or Hermes protocol behavior.

- [ ] 4. Verify and publish the updated PR
  - Refresh `Conduit.xcodeproj` with `/Users/agrias/bin/bin/xcodegen generate` after final source changes.
  - Run the full XCTest suite in the iOS Simulator and record the final test count/result.
  - Run `git diff --check`, inspect `git diff origin/main...HEAD`, and confirm only pending-decision resume implementation, tests, and spec/plan documentation are present.
  - Commit the implementation with a message describing pending decision cards after background resume.
  - Push `codex/clarify-background-resume` and update PR #54’s title/body to cover both clarifications and approvals, without replying to or resolving review threads unless explicitly requested.
