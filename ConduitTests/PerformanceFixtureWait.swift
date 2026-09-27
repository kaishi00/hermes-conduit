import XCTest
import UIKit
@testable import Conduit

/// Shared deterministic-wait support for the performance fixtures.
///
/// Discipline (learned from the CI flakes these fixtures once shipped with):
/// elapsed time is ONLY a failsafe. Every semantic readiness is a counter
/// condition — "the work we intend to measure has happened" and "stray
/// updates have stopped landing" — observed by pumping the main run loop,
/// never by sleeping a fixed duration and assuming completion.
@MainActor
enum PerformanceFixtureWait {

    /// Every counter the transcript fixtures measure. Draining until ALL are
    /// quiet makes the shared helper strictly stricter than either suite's
    /// old per-suite counter subset.
    private static func allCounters() -> [Int] {
        [
            TranscriptPerf.settledMessageBubbleBodyEvaluations,
            TranscriptPerf.settledMarkdownTextBodyEvaluations,
            TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations,
            TranscriptPerf.settledMarkdownWindowDuplicateEvaluations,
            TranscriptPerf.selectableTextViewUpdateCalls,
            TranscriptPerf.selectableTextViewTextRebuilds,
            TranscriptPerf.textKitMeasurementCalls,
            TranscriptPerf.rowFramePreferenceUpdates,
            TranscriptPerf.layoutMetricsChangedCalls,
            TranscriptPerf.transcriptChangedCalls,
            TranscriptPerf.chatViewBodyEvaluations,
            TranscriptPerf.composerBarBodyEvaluations,
            TranscriptPerf.composerUpdateUIViewCalls,
            TranscriptPerf.reasoningProjectionPublishes,
            TranscriptPerf.reasoningTranscriptMutations,
            TranscriptPerf.scrollTargetCommonPrefixComparisons,
            TranscriptPerf.scrollTargetPrefixSetBuilds,
        ]
    }

    /// Pump the main run loop until every measured counter has been quiet
    /// for `quietFor` seconds (a sustained quiet period, not one pass —
    /// cold CI simulators trickle lazy-mount commits for seconds, and a
    /// layout pass can wake the lazy prefetcher after a single quiet turn).
    ///
    /// Returns false only when the failsafe `cap` elapsed without a quiet
    /// window. Callers MUST fail the test in that case: measuring while
    /// work is still landing would make the assertions meaningless.
    ///
    /// The cap is deliberately generous (45s): on a contended hosted runner
    /// the trailing lazy-mount/trait-sync tail has been observed to keep
    /// landing for tens of seconds, and tripping this failsafe fails the
    /// lane WITHOUT any assertion signal. The cap exists only to bound a
    /// genuinely stuck run, so it must be far above the slowest observed
    /// settle time, never a second timing gate.
    @discardableResult
    static func settleUntilCountersQuiet(
        quietFor: TimeInterval = 1.0,
        cap: TimeInterval = 45.0,
        pumpingLayoutOf view: UIView? = nil,
        pumpFor: TimeInterval = 1.0
    ) -> Bool {
        var quietForElapsed: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var last = allCounters()
        let step: TimeInterval = 0.1
        while elapsed < cap {
            // Optional layout pump for the first `pumpFor` seconds only: it
            // flushes a deferred hosting update that only a forced layout
            // would land (see eventually(pumpingLayoutOf:)). Bounded, and
            // the quiet window only counts once pumping stops, because a
            // forced layout can itself wake the lazy prefetcher — pumping
            // for the whole drain could keep renewing the work it waits on.
            let pumping = view != nil && elapsed < pumpFor
            if pumping, let view {
                view.setNeedsLayout()
                view.layoutIfNeeded()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(step))
            elapsed += step
            let current = allCounters()
            if pumping {
                quietForElapsed = 0
                last = current
            } else if current == last {
                quietForElapsed += step
                if quietForElapsed >= quietFor { return true }
            } else {
                quietForElapsed = 0
                last = current
            }
        }
        return false
    }

    /// Pump the main run loop until `condition` holds, checking after every
    /// turn. Failsafe `cap` only prevents a permanently stuck test — the
    /// condition, never elapsed time, decides readiness. Callers fail with
    /// a message naming the condition when this returns false.
    @discardableResult
    static func eventually(
        cap: TimeInterval = 10.0,
        _ condition: () -> Bool
    ) -> Bool {
        var elapsed: TimeInterval = 0
        let step: TimeInterval = 0.05
        while elapsed < cap {
            RunLoop.current.run(until: Date().addingTimeInterval(step))
            elapsed += step
            if condition() { return true }
        }
        return condition()
    }

    /// `eventually`, but forcing a layout pass on `view` before every turn.
    /// Use when the awaited work is a hosting-controller update (a root
    /// reassignment or a published change): a bare run-loop turn only
    /// drains whatever commit SwiftUI already scheduled, and on a loaded
    /// runner that commit can be deferred past the cap. A forced layout
    /// makes each turn flush pending view updates itself.
    ///
    /// Side effect: every turn runs `setNeedsLayout()`/`layoutIfNeeded()`
    /// on `view` BEFORE evaluating `condition`, so the condition must not
    /// rely on no layout happening. The default cap is longer than plain
    /// `eventually`'s because hosting updates are what a loaded release-gate
    /// lane delays; it is still only a failsafe.
    @discardableResult
    static func eventually(
        pumpingLayoutOf view: UIView,
        cap: TimeInterval = 30.0,
        _ condition: () -> Bool
    ) -> Bool {
        eventually(cap: cap) {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            return condition()
        }
    }
}
