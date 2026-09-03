import XCTest
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
    @discardableResult
    static func settleUntilCountersQuiet(
        quietFor: TimeInterval = 1.0,
        cap: TimeInterval = 15.0
    ) -> Bool {
        var quietForElapsed: TimeInterval = 0
        var elapsed: TimeInterval = 0
        var last = allCounters()
        let step: TimeInterval = 0.1
        while elapsed < cap {
            RunLoop.current.run(until: Date().addingTimeInterval(step))
            elapsed += step
            let current = allCounters()
            if current == last {
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
}
