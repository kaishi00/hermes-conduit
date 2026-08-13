# Implementation Plan: Restore Answerable Clarifications After Background Resume

**Goal:** Keep an unresolved clarification visible and answerable after a background-to-foreground resume, even when the resume snapshot reports `running == false` and omits the one-shot clarification event.

**Architecture:** Preserve the existing gateway-authoritative transcript and `SessionPresentationCache` merge. Split clarification restoration/actionability from the existing settled-turn approval behavior, and use the existing request-ID reconciliation plus bounded unconfirmed-card cache protection.

**Tech Stack:** Swift, SwiftUI `AppState`, XCTest, XcodeGen, iOS Simulator.

## Tasks

- [ ] 1. Add the regression tests first (RED)
  - Update `ConduitTests/SessionPresentationCacheTests.swift` so the explicit-settled clarification case models the reported background resume: seed a cached pending clarification, return preceding assistant text without a clarification event, and use `SessionRuntimeSnapshot(object: ["running": .bool(false)])`.
  - Assert that the assistant text remains, the clarification with the same request ID is present and pending, the session is action-capable, and the presentation cache retains it.
  - Update the existing gateway-pending clarification case so an unresolved gateway clarification also remains visible/actionable when `running == false`.
  - Keep the answered/resolved same-request test asserting that the gateway representation replaces the cached pending card without a duplicate.
  - Preserve the current approval-specific settled behavior tests.
  - Refresh the generated project with `/Users/agrias/bin/bin/xcodegen generate`, then run the single new/updated test before changing production code:
    `xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' -derivedDataPath /tmp/conduit-clarify-red CODE_SIGNING_ALLOWED=NO -only-testing:ConduitTests/SessionPresentationCacheTests/testApplyChatResumeRestoresPendingClarificationWhenRunningIsFalse`
  - Confirm the test fails for the current implementation because `running == false` suppresses the cached card and leaves `turnState` idle.

- [ ] 2. Implement clarification-specific resume reconciliation
  - In `Conduit/Services/AppState.swift`, update `applyChatResume` so cached pending clarifications remain eligible independent of `snapshot.running`; retain the existing running-based eligibility for approvals unless a shared helper requires a narrowly scoped change.
  - Keep locally retained clarification cards eligible when the gateway transcript omits the one-shot event, and continue filtering them by the authoritative gateway decision key so an answered/resolved same-request record wins.
  - Narrow the explicit-`false` pruning path so it cannot remove a pending clarification. If approval pruning remains necessary, pass only approval keys through the existing presentation-pruning helper.
  - Treat any unresolved pending clarification in the merged presentation as action-capable, including when `running == false`, so `respondToClarify` remains usable. Do not change unrelated turn-state behavior for sessions without a pending clarification.
  - Ensure a gateway-supplied pending clarification is included in the existing bounded unconfirmed preservation set when the snapshot is otherwise settled, so the subsequent cache save does not strip it.
  - Update stale comments/helper names in `AppState.swift` and `SessionPresentationCache.swift` so they describe clarification restoration accurately rather than saying it is only valid while a turn is running.
  - Only change `Conduit/Services/SessionPresentationCache.swift` if a type-specific pending-key/pruning helper is needed; keep gateway transcript matching and resolved-card suppression intact.

- [ ] 3. Run focused verification (GREEN)
  - Run the complete clarification integration group:
    `xcodebuild test -project Conduit.xcodeproj -scheme Conduit -destination 'platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355' -derivedDataPath /tmp/conduit-clarify-focused CODE_SIGNING_ALLOWED=NO -only-testing:ConduitTests/SessionPresentationCacheTests`
  - Confirm the restored-card, explicit-settled, gateway-pending, resolved-gateway, approval, and expiry tests all pass.
  - Review the diff for accidental changes to approval restoration, notification routing, or gateway protocol behavior.

- [ ] 4. Verify the branch and prepare the PR
  - Refresh `Conduit.xcodeproj` with `/Users/agrias/bin/bin/xcodegen generate` after the final source changes.
  - Run the full XCTest suite in the iOS Simulator and record the final test count/result.
  - Run `git diff --check`, inspect `git diff main...HEAD`, and confirm only the clarification resume implementation, tests, and plan/spec documentation are present.
  - Commit the implementation as `fix: keep clarifications visible after background resume`.
  - Push `codex/clarify-background-resume` and open its PR against `main` with a summary, root cause, test evidence, and explicit note that approval behavior is unchanged.
