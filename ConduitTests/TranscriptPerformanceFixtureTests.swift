import XCTest
import SwiftUI
@testable import Conduit

/// Performance fixture (spec: 250 settled Markdown-heavy messages + one
/// active streaming response, every message below the 100 KB large-document
/// threshold, plus a plain-text counterpart). Asserts the architectural
/// acceptance criterion with deterministic counters, never wall-clock:
///
///   one streaming publish
///       → only the live StreamingBubble changes
///       settled Markdown presentation rebuilds ≈ 0
///       settled TextKit measurements ≈ 0
///
/// The fixture hosts the real ChatView (real ForEach, real gating, real
/// StreamingBubble) so the measured cascade is the production one. The
/// LazyVStack mounts the visible subset of rows, exactly as on a device.
@MainActor
final class TranscriptPerformanceFixtureTests: XCTestCase {

    /// Retained for the full lifetime of each measurement so the hosted
    /// hierarchy stays genuinely mounted; torn down explicitly per test.
    private var testWindow: UIWindow?

    override func setUp() {
        super.setUp()
        TranscriptPerf.resetRenderLedgerForTesting()
    }

    override func tearDown() {
        // Detach the window first so dismantle work is triggered, then flush
        // it with a bounded pump (see SettledMessageIsolationTests.tearDown:
        // a zero-interval tick lets cold-simulator dismantle transactions
        // land inside the NEXT test's measurement window). Counters reset
        // after the pump, so the next test starts from zero.
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        testWindow = nil
        TranscriptPerf.reset()
        super.tearDown()
    }

    private func makeAppState() throws -> AppState {
        let suiteName = "transcript-perf-fixture"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "test UserDefaults suite must initialize"
        )
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    // MARK: - Fixture transcripts

    /// Markdown-heavy settled messages covering paragraphs, headings,
    /// lists, quotes, links, and moderate code blocks. Diverse from the
    /// first message onward — the LazyVStack mounts roughly the first
    /// screenful, so the mounted subset must exercise every block shape.
    static func markdownTranscript(count: Int = 250) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: "fixture-\(index)",
                role: index % 2 == 0 ? .assistant : .user,
                content: markdownBody(index: index),
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    private static func markdownBody(index: Int) -> String {
        switch index % 6 {
        case 0:
            return """
            ### Section heading \(index)

            A settled paragraph with **bold**, *italic*, and `inline code` —
            message \(index) of the cumulative-transcript fixture. It repeats
            enough prose to resemble a real assistant answer, and carries a
            [reference link](https://example.com/item/\(index)) for coverage.

            - first list item with some detail
            - second list item
            - third list item with a trailing note
            """
        case 1:
            return """
            Message \(index) asks a settled question with _emphasis_ and a
            [link](https://example.com/q/\(index)); the answer follows in the
            next turn. Ordinary paragraphs keep the reading column busy.
            """
        case 2:
            return """
            > A quoted passage for message \(index).
            > Quotes render through the selectable flow path with italic runs.

            Follow-up paragraph after the quote, long enough to wrap across
            two or three display lines in the fixture viewport.
            """
        case 3:
            return """
            #### Code-bearing answer \(index)

            ```swift
            func settled\(index)() -> String {
                let value = "message \\(index)"
                return value
            }
            ```

            A short paragraph after the code block for coverage.
            """
        case 4:
            return """
            1. Ordered first step for message \(index)
            2. Ordered second step
            3. Ordered third step with a [docs link](https://example.com/docs/\(index))

            Closing paragraph.
            """
        default:
            return """
            ## Heading \(index)

            Mixed content: a paragraph, then a list, then a quote.

            - bullet one
            - bullet two

            > quoted line
            """
        }
    }

    /// Plain-text counterpart: no Markdown structure, same volume.
    static func plainTextTranscript(count: Int = 250) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: "plain-\(index)",
                role: index % 2 == 0 ? .assistant : .user,
                content: String(
                    repeating: "Plain settled message \(index) body text. ",
                    count: 24
                ),
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    // MARK: - Harness

    /// Hosts the full ChatView in a retained, live window.
    ///
    /// The Dynamic Type and chat text-size environments are PINNED — same
    /// discipline as SettledMessageIsolationTests.mountRow: on a freshly
    /// booted CI simulator the hosting window's trait resolution lands
    /// asynchronously, and a late trait-sync transaction inside the
    /// measurement window re-opens every mounted row's Equatable gate
    /// (one burst of spurious settled re-evaluations). Production ChatView
    /// injects chatTextSize at its root, so pinning it here mirrors the
    /// production environment shape rather than weakening the fixture.
    ///
    /// The OUTER harness pin alone is not sufficient for chatTextSize
    /// (review finding, PR #201): ChatView re-writes `\.chatTextSize` at
    /// its own root from the shared @AppStorage preference, and the NEARER
    /// write wins — so the shared preference state (whatever the test
    /// host's standard defaults hold, or any mid-test change) would shadow
    /// the pin and decide the rows' gate input. The fixture therefore also
    /// pins the INNER write through ChatView's test-only
    /// `chatTextSizeOverride`, making the effective value deterministic at
    /// exactly the point that currently consumes the AppStorage value.
    private func mountChat(
        appState: AppState,
        streaming: String
    ) -> UIHostingController<PinnedChatRoot> {
        appState.streamingText = streaming
        let host = UIHostingController(rootView: PinnedChatRoot(appState: appState))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        // makeKeyAndVisible so the key/attach transition completes during
        // the mount drain (same cold-first-launch discipline as
        // SettledMessageIsolationTests.mountRow), never inside a window.
        window.makeKeyAndVisible()
        testWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    /// Concrete pinned ChatView root, built identically for mount and churn
    /// so a re-created root keeps the exact concrete modifier chain. A
    /// stable concrete type (instead of an erased AnyView) keeps subtree
    /// identity STRUCTURAL across the churn re-creation — same discipline
    /// as the isolation suite's ChurnableRoot — so the preference-churn
    /// regression cannot depend on AnyView same-type identity preservation.
    ///
    /// `generation` is defensive: the churn bumps it so the re-created
    /// root is a genuinely DIFFERENT value (same discipline as the
    /// isolation suite's ChurnableRoot, whose churn changes `ambient`).
    /// A non-Equatable root is expected to re-run its body on every
    /// re-assignment anyway (the invariant SettledGateHarnessRow's doc
    /// states), so the field is inert today and only keeps
    /// the churn observable if an equality fast-path ever applies to an
    /// otherwise identical value. The release-gate flake itself was the
    /// bare run-loop wait; see the vacuity gates' layout-pumping waits.
    /// It is not read by `body`, so the rendered hierarchy and row identity
    /// are unchanged.
    private struct PinnedChatRoot: View {
        let appState: AppState
        var generation = 0

        var body: some View {
            DormancyHarnessEnvironment.applying(
                ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize)
                    .environmentObject(appState)
            )
        }
    }

    /// Drives `ticks` streaming publishes at the production ~30 Hz cadence,
    /// pumping layout each tick (see the SwiftUI async-commit pitfall:
    /// state set from async contexts needs a forced layout pass per pump).
    ///
    /// Tick content changes every tick but keeps a CONSTANT length, so the
    /// live row's height — and therefore the transcript's layout — is
    /// stable across the measured window: streaming is measured in its
    /// steady state, with no layout-shift churn folding into the counters.
    private func streamTicks(
        _ ticks: Int,
        appState: AppState,
        host: UIHostingController<PinnedChatRoot>
    ) {
        let steadyBody = String(repeating: "Steady padding body text for the live row. ", count: 10)
        for tick in 0..<ticks {
            appState.streamingText =
                "Live streaming delta \(tick) — the only view that should change. "
                + steadyBody
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date())
        }
    }

    // MARK: - Fixtures

    func testStreamingTicksLeaveSettledMarkdownDormant_MarkdownTranscript() throws {
        let appState = try makeAppState()
        appState.messages = Self.markdownTranscript()

        let host = mountChat(appState: appState, streaming: "Initial streaming frame")

        // Sanity: the settled transcript actually mounted and rendered.
        let settledMarkdownAtRest = TranscriptPerf.settledMarkdownTextBodyEvaluations
        XCTAssertGreaterThan(
            settledMarkdownAtRest, 0,
            "fixture must mount settled Markdown rows before streaming starts"
        )

        // Settle tick: the first streaming delta can legitimately mount one
        // additional lazy row as layout adjusts. Steady-state work is what
        // the acceptance criterion bounds, so measure from the second tick.
        streamTicks(1, appState: appState, host: host)
        let settled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard settled else {
            XCTFail("counter window never reached a quiet state; measurement would be meaningless on this runner")
            return
        }

        TranscriptPerf.reset()
        streamTicks(10, appState: appState, host: host)

        // Dormancy invariant, classified by position: streaming must never
        // re-render INTERIOR settled rows — that is the per-publish cascade
        // the acceptance criterion bounds (every mounted row joining each
        // tick). A growing streaming bubble legitimately shifts the
        // bottom-anchored LazyVStack, and remounts of rows AT THE VIEWPORT
        // EDGES are tolerated however many a loaded scheduler produces.
        let atRestRerenders = TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations
        let interiorRerenders = TranscriptPerf.interiorAtRestRerenders(
            sources: TranscriptPerf.recentPreWindowRepeatSources,
            transcript: Self.markdownTranscript()
        )
        let markdownSpanSuffix = TranscriptPerf.windowEvaluationSpans.isEmpty
            ? ""
            : " — spans:\n\(TranscriptPerf.windowEvaluationSpans.joined(separator: "\n"))"
        XCTAssertTrue(
            interiorRerenders.isEmpty,
            "streaming re-rendered \(interiorRerenders.count) interior settled Markdown rows "
                + "(of \(atRestRerenders) at-rest re-renders; edge remounts are tolerated): "
                + "\(interiorRerenders.map { String($0.prefix(32)) })"
                + markdownSpanSuffix
        )
        // The live streaming row legitimately updates, rebuilds, and measures
        // its own few block text views each tick (~3 SelectableTextViews,
        // ~2 rebuilds). Under the pre-fix cascade every mounted settled row
        // joined these counts per tick (thousands per window), which stays
        // caught. Each TOLERATED viewport-edge remount additionally costs
        // its own row's few text views, so the allowance grows by one
        // remount's footprint per edge re-render the dormancy classifier
        // above accepted — zero churn keeps the original strict bound.
        let edgeRemountAllowance = max(atRestRerenders, TranscriptPerf.settledMarkdownWindowDuplicateEvaluations)
        XCTAssertLessThanOrEqual(
            TranscriptPerf.selectableTextViewUpdateCalls, 30 + 5 * edgeRemountAllowance,
            "SelectableTextView work must be bounded to the live row (~3/tick) plus tolerated edge remounts"
        )
        XCTAssertLessThanOrEqual(
            TranscriptPerf.textKitMeasurementCalls, 30 + 5 * edgeRemountAllowance,
            "TextKit measurement must be bounded to the live row, not the settled transcript"
        )
        XCTAssertLessThanOrEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, 20 + 3 * edgeRemountAllowance,
            "attributed-text rebuilds must be bounded to the live row's changed content (~2/tick) plus tolerated edge remounts"
        )
    }

    func testStreamingTicksLeaveSettledMarkdownDormant_PlainTextTranscript() throws {
        let appState = try makeAppState()
        appState.messages = Self.plainTextTranscript()

        let host = mountChat(appState: appState, streaming: "Initial streaming frame")
        streamTicks(1, appState: appState, host: host)
        let settled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard settled else {
            XCTFail("counter window never reached a quiet state; measurement would be meaningless on this runner")
            return
        }

        TranscriptPerf.reset()
        streamTicks(10, appState: appState, host: host)

        // Same position classification: interior plain rows re-rendering
        // under streaming is the cascade; edge remounts are layout churn.
        let plainAtRestRerenders = TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations
        let plainInteriorRerenders = TranscriptPerf.interiorAtRestRerenders(
            sources: TranscriptPerf.recentPreWindowRepeatSources,
            transcript: Self.plainTextTranscript()
        )
        let plainSpanSuffix = TranscriptPerf.windowEvaluationSpans.isEmpty
            ? ""
            : " — spans:\n\(TranscriptPerf.windowEvaluationSpans.joined(separator: "\n"))"
        XCTAssertTrue(
            plainInteriorRerenders.isEmpty,
            "plain-text transcript: streaming re-rendered \(plainInteriorRerenders.count) interior rows "
                + "(of \(plainAtRestRerenders) at-rest re-renders; edge remounts are tolerated): "
                + "\(plainInteriorRerenders.map { String($0.prefix(32)) })"
                + plainSpanSuffix
        )
        // Same remount-footprint allowance as the markdown variant: the
        // strict bound holds whenever no edge churn occurred.
        let plainEdgeAllowance = max(plainAtRestRerenders, TranscriptPerf.settledMarkdownWindowDuplicateEvaluations)
        XCTAssertLessThanOrEqual(
            TranscriptPerf.textKitMeasurementCalls, 30 + 5 * plainEdgeAllowance,
            "TextKit measurement must be bounded to the live row plus tolerated edge remounts"
        )
    }

    /// The shared chat text-size preference must not leak into the fixture
    /// (review finding, PR #201). ChatView re-writes `\.chatTextSize` at
    /// its own root from the shared @AppStorage preference — an environment
    /// write NO outer harness pin can dominate — so the fixture pins that
    /// INNER write through ChatView's test-only `chatTextSizeOverride`, and
    /// this regression proves the pin at the effective write point:
    ///
    /// 1. Mid-measurement, the SHARED preference (standard defaults —
    ///    exactly what @AppStorage reads) flips to a non-pinned value.
    /// 2. The ChatView root is then re-created through the same concrete
    ///    modifier chain, so the fresh body synchronously consumes the
    ///    churned preference at the inner write. SwiftUI preserves the
    ///    LazyVStack row identity across the re-creation (same structure,
    ///    same message ids), so every settled row re-diffs through its
    ///    Equatable gate — the production re-creation shape.
    /// 3. With the pin, the rows keep observing the pinned test value:
    ///    the re-creation provably reaches ChatView's body and the rows'
    ///    body chain (vacuity gates below), yet opens no gate and
    ///    re-renders no INTERIOR settled row — only viewport-edge remounts
    ///    of fresh row instances (rendered through the same pinned inner
    ///    write) are tolerated, bounded exactly as the streaming fixtures
    ///    bound them.
    ///
    /// Mutation-sensitive: strip the override and the re-created ChatView
    /// writes the churned preference into EVERY preserved row's gate input
    /// (field: chatTextSize — visible in the gate-reopen report) — those
    /// re-evaluations are interior pre-window repeats and fail the
    /// assertions below.
    ///
    /// Why not a live defaults-only mutation: in a hosted unit-test host,
    /// @AppStorage's preference-change invalidation does not reach the view
    /// at all (verified while authoring: a landed store write left
    /// ChatView's body flat across a 10s run-loop pump). Re-creating the
    /// ChatView root while the store holds the churned value is the
    /// deterministic equivalent of the re-presentation shape and requires
    /// no notification delivery.
    func testSharedChatTextSizePreferenceChurnDoesNotReopenSettledGate() throws {
        let appState = try makeAppState()
        appState.messages = Self.markdownTranscript()

        let host = mountChat(appState: appState, streaming: "Initial streaming frame")
        let settled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard settled else {
            XCTFail("counters never reached a quiet state; the churn measurement would be meaningless")
            return
        }

        TranscriptPerf.reset()

        // Precondition: the churned value must actually DIVERGE from the
        // pin, or the whole vector no-ops trivially.
        XCTAssertNotEqual(
            DormancyHarnessEnvironment.pinnedChatTextSize, .largest,
            "the pinned chatTextSize must differ from the churned preference for this regression to bite"
        )

        // The churn: the SHARED preference flips to a non-pinned value
        // mid-measurement, then the ChatView root is re-created — its
        // fresh body reads the churned store value at the inner write.
        // Whatever the store held before is restored, so a crash mid-test
        // cannot leak the churned value into later suites in this lane.
        let preferenceKey = ChatTypography.preferenceKey
        let previousPreference = UserDefaults.standard.object(forKey: preferenceKey)
        defer {
            if let previousPreference {
                UserDefaults.standard.set(previousPreference, forKey: preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferenceKey)
            }
        }
        UserDefaults.standard.set(ChatTextSize.largest.rawValue, forKey: preferenceKey)
        // The write itself must have landed: a runner whose CFPrefs store
        // is wedged ("Path not accessible") cannot exercise the shared-
        // preference vector at all, and the vacuity gates below would only
        // report flat counters.
        guard ChatTextSize(rawValue: UserDefaults.standard.integer(forKey: preferenceKey)) == .largest else {
            XCTFail(
                "the shared-preference write never landed in standard defaults; "
                    + "this runner cannot exercise the preference-churn vector"
            )
            return
        }
        host.rootView = PinnedChatRoot(appState: appState, generation: host.rootView.generation + 1)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Vacuity gate 1: the re-creation must have re-run ChatView's body.
        // Pump layout every turn, not just the run loop: under lane load
        // the hosting update can sit behind a deferred commit that a bare
        // run-loop turn never forces (the SwiftUI async-commit pitfall
        // streamTicks already guards against).
        let chatViewReran = PerformanceFixtureWait.eventually(pumpingLayoutOf: host.view) {
            TranscriptPerf.chatViewBodyEvaluations > 0
        }
        guard chatViewReran else {
            XCTFail(
                "the re-created ChatView body never re-ran; the fixture's "
                    + "chatTextSize pinning is not under test on this runner"
            )
            return
        }

        // Drain the re-creation's own trailing row work (forcing layout
        // each turn, as gate 2's wait will) before the snapshot, so gate 2
        // credits the streaming publish rather than re-creation work that
        // had not landed yet. Gate 1 returns on the first pass where
        // ChatView's body ran, which can be before the re-created rows
        // finish.
        guard PerformanceFixtureWait.settleUntilCountersQuiet(
            quietFor: 1.2,
            pumpingLayoutOf: host.view
        ) else {
            XCTFail("post-re-creation counters never quieted; vacuity gate 2 could not attribute the publish on this runner")
            return
        }
        let bubblesAfterRecreation = TranscriptPerf.settledMessageBubbleBodyEvaluations

        // A streaming publish tick in the same window: the publish
        // invalidation re-runs the settled rows' body chains THROUGH the
        // re-created environment (the same vector the streaming fixtures
        // drive), so the dormancy assertions below measure a genuinely
        // consulted gate under the churned preference — not a pruned
        // subtree.
        appState.streamingText = "Shared-preference churn tick — the live row only."
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Vacuity gate 2: the publish must have re-run the settled rows'
        // body chains BEYOND what the re-creation itself did (AssistantBubble
        // bodies note through the publish) — otherwise the dormancy
        // assertions measure a pruned update, not a consulted gate.
        let rowsReran = PerformanceFixtureWait.eventually(pumpingLayoutOf: host.view) {
            TranscriptPerf.settledMessageBubbleBodyEvaluations > bubblesAfterRecreation
        }
        guard rowsReran else {
            XCTFail(
                "the churn never reached the settled rows' body chain; "
                    + "the dormancy assertions would be vacuous"
            )
            return
        }
        // And the store really holds the churned value the inner write was
        // required to ignore.
        XCTAssertEqual(
            ChatTypography.stored(), .largest,
            "precondition: the churned preference must be what @AppStorage resolves"
        )

        // Give any (incorrect) re-evaluation time to surface before
        // asserting; a non-quiet post-churn hierarchy would make the
        // snapshot below race in-flight commits, so the failsafe must
        // fail the test (the helper's contract), not be discarded.
        let postChurnSettled = PerformanceFixtureWait.settleUntilCountersQuiet(
            quietFor: 1.2,
            pumpingLayoutOf: host.view
        )
        guard postChurnSettled else {
            XCTFail("post-churn counters never quieted; the dormancy snapshot would race in-flight commits on this runner")
            return
        }

        // Dormancy invariant, classified by position (the same discipline
        // as the streaming fixtures): re-creating the ChatView root may
        // legitimately remount rows AT THE VIEWPORT EDGES as the
        // bottom-anchored LazyVStack re-settles — those are fresh row
        // instances rendered THROUGH the pinned inner write. The guarded
        // failure shapes are: an INTERIOR row re-rendering (its source was
        // already at rest, so any re-evaluation means the row's gate input
        // changed — i.e. the churned preference leaked in), a gate-reopen
        // report naming chatTextSize, or SelectableTextView work beyond
        // the live row plus tolerated edge remounts.
        let atRestRerenders = TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations
        let interiorRerenders = TranscriptPerf.interiorAtRestRerenders(
            sources: TranscriptPerf.recentPreWindowRepeatSources,
            transcript: Self.markdownTranscript()
        )
        let reopenSuffix = TranscriptPerf.recentGateReopenReports.isEmpty
            ? ""
            : " (gate reopens: \(TranscriptPerf.recentGateReopenReports.joined(separator: "; ")))"
        let spanSuffix = TranscriptPerf.windowEvaluationSpans.isEmpty
            ? ""
            : " — spans:\n\(TranscriptPerf.windowEvaluationSpans.joined(separator: "\n"))"
        XCTAssertTrue(
            interiorRerenders.isEmpty,
            "the shared chatTextSize preference churn re-rendered \(interiorRerenders.count) interior "
                + "settled rows (of \(atRestRerenders) at-rest re-renders; edge remounts are "
                + "tolerated) — the fixture's inner override failed to hold the rows' gate input"
                + "\(reopenSuffix)\(spanSuffix)"
        )
        // The chatTextSize dimension of the same invariant, asserted
        // directly: NO gate may reopen on chatTextSize while the churned
        // shared preference is in effect.
        let chatTextSizeReopens = TranscriptPerf.recentGateReopenReports.filter {
            $0.contains("chatTextSize")
        }
        XCTAssertTrue(
            chatTextSizeReopens.isEmpty,
            "a gate reopened on chatTextSize under the churned shared preference "
                + "— the inner override must prevent the churned value from reaching "
                + "any row's gate input: \(chatTextSizeReopens)"
        )
        // The preserved rows kept observing the pinned test value: with the
        // override stripped (mutation check) the re-created ChatView writes
        // the churned preference into EVERY preserved row's gate, whose
        // re-evaluations land as interior pre-window repeats and gate
        // reopens — caught above. Window duplicates and edge remounts are
        // mount noise, bounded here exactly as the streaming fixtures bound
        // them.
        let edgeRemountAllowance = max(atRestRerenders, TranscriptPerf.settledMarkdownWindowDuplicateEvaluations)
        XCTAssertLessThanOrEqual(
            TranscriptPerf.selectableTextViewUpdateCalls, 30 + 5 * edgeRemountAllowance,
            "SelectableTextView work must be bounded to the live row plus tolerated edge remounts"
        )
        XCTAssertLessThanOrEqual(
            TranscriptPerf.textKitMeasurementCalls, 30 + 5 * edgeRemountAllowance,
            "TextKit measurement must be bounded to the live row plus tolerated edge remounts"
        )
        XCTAssertLessThanOrEqual(
            TranscriptPerf.selectableTextViewTextRebuilds, 20 + 3 * edgeRemountAllowance,
            "attributed-text rebuilds must be bounded to the live row's changed content plus tolerated edge remounts"
        )
    }

    /// First-render gateway resolver (#5): settled Markdown must render
    /// exactly once on first appearance — no nil → resolver invalidation
    /// sweep. The resolver identity must be stable for the profile and the
    /// settled evaluation count must not grow after the initial layout.
    func testFirstAppearanceRendersSettledMarkdownOnce() throws {
        let appState = try makeAppState()
        appState.messages = Self.markdownTranscript()

        // Stable identity per profile, available from the first body pass.
        let first = appState.gatewayMediaResolver
        XCTAssertIdentical(
            appState.gatewayMediaResolver, first,
            "the resolver must be identity-stable while the profile is unchanged"
        )

        let host = mountChat(appState: appState, streaming: "Initial frame")
        // Let lazy mounting fully settle: the first pass mounts the visible
        // screenful and LazyVStack prefetches neighbor rows on subsequent
        // turns — each a legitimate FIRST render of a new row, not a
        // re-render of an existing one. Cold CI simulators trickle those
        // prefetches over seconds, so wait for the sustained-quiet baseline
        // (counter condition; the cap is only a failsafe).
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let baselineSettled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        // Without a settled baseline the "no second render pass" assertion
        // would race against still-in-flight lazy mounts on slow runners.
        guard baselineSettled else {
            XCTFail("lazy mounting never reached a quiet state; the first-appearance baseline would be meaningless on this runner")
            return
        }
        let initialEvaluations = TranscriptPerf.settledMarkdownTextBodyEvaluations
        XCTAssertGreaterThan(
            initialEvaluations, 0,
            "settled Markdown must render on first appearance"
        )

        // Open the measurement window: every row rendered by the drain is
        // now "already at rest" for the repeat ledger.
        TranscriptPerf.reset()

        // The pre-fix nil → resolver transition re-evaluated every mounted
        // settled row here — an INTERIOR-row cascade the position
        // classifier fails loudly. Relayout waking the lazy prefetcher to
        // FIRST-mount one more neighbor row, or remounting viewport-edge
        // rows, is not a second render pass of at-rest content.
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let relayoutSettled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard relayoutSettled else {
            XCTFail("post-relayout updates never quieted; the no-second-pass check would race pending commits on this runner")
            return
        }

        let atRestRerenders = TranscriptPerf.settledMarkdownPreWindowRepeatEvaluations
        let interiorRerenders = TranscriptPerf.interiorAtRestRerenders(
            sources: TranscriptPerf.recentPreWindowRepeatSources,
            transcript: Self.markdownTranscript()
        )
        XCTAssertTrue(
            interiorRerenders.isEmpty,
            "relayout re-rendered \(interiorRerenders.count) interior settled rows after first appearance "
                + "(of \(atRestRerenders) at-rest re-renders; edge remounts are tolerated): "
                + "\(interiorRerenders.map { String($0.prefix(32)) })"
        )
    }

    /// The settled transcript itself still renders through the normal path
    /// when it genuinely changes: appending a message re-renders exactly the
    /// new content, and the fingerprint bound stays O(append).
    func testGenuineAppendRendersNewMessageAndFingerprintsBounded() throws {
        let appState = try makeAppState()
        var messages = Self.markdownTranscript(count: 100)
        appState.messages = messages

        let host = mountChat(appState: appState, streaming: "")
        appState.streamingText = ""  // StreamingBubble unmounts

        TranscriptPerf.reset()
        messages.append(
            ChatMessage(
                id: "fixture-new",
                role: .assistant,
                content: "## A genuinely new message\n\nWith a paragraph and a [link](https://example.com/new).",
                timestamp: "2026-01-02T00:00:00Z"
            )
        )
        appState.messages = messages
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Semantic readiness, not elapsed time: the mutation must have been
        // fingerprinted by the scroll-target cache (the append-specific
        // signal) and the new content must have rendered before the
        // bounded-work assertions mean anything. Exactness is asserted
        // below; these gates only decide readiness.
        let appendFingerprinted = PerformanceFixtureWait.eventually {
            TranscriptPerf.lastFingerprintedMessageCount >= 1
        }
        XCTAssertTrue(
            appendFingerprinted,
            "the append never reached the scroll-target cache on this runner"
        )
        let newMessageRendered = PerformanceFixtureWait.eventually {
            TranscriptPerf.settledMarkdownTextBodyEvaluations > 0
        }
        XCTAssertTrue(
            newMessageRendered,
            "the genuinely new message never rendered on this runner"
        )

        XCTAssertEqual(
            TranscriptPerf.lastFingerprintedMessageCount, 1,
            "appending to a 100-message transcript must fingerprint exactly the appended message"
        )
        XCTAssertEqual(
            TranscriptPerf.transcriptChangedCalls, 1,
            "one messages mutation must cause exactly one transcriptChanged call"
        )
    }
}
