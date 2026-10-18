import XCTest
import SwiftUI
@testable import Conduit

/// Regression tests for settled-row isolation (Fix 2): publishing unrelated
/// live state must not re-evaluate settled Markdown presentation. These use
/// the deterministic TranscriptPerf counters, not wall-clock timing.
///
/// What this suite asserts: the gate's input contract at value level
/// (`testEquatableConformanceComparesEveryGateInput` — every Equality field,
/// including both environment-derived inputs), that a content, resolver or
/// Dynamic Type change still OPENS the gate and re-renders
/// (`testContentChange…`, `testResolverChange…`,
/// `testDynamicTypeChange…`), and that ancestry environment churn cannot
/// re-open a pinned row (`testWindowTraitChurnDoesNotReopenSettledGate`, the
/// build-147 churn vector, with an unpinned canary proving the churn reached
/// the hierarchy).
///
/// What this suite deliberately does NOT assert: dormancy itself. On a cold
/// erased device (2026-09-22, this suite run alone in the exact composition
/// hosted CI runs), a settled row hosted on its own re-evaluates its Markdown
/// once per unrelated publish while the gate comparison is not reached at all
/// in a majority of runs — the hosting graph re-runs the row's
/// dynamic-property body. That is a property of hosting a settled row outside
/// a transcript, and it is invariant to the shape (hosting root, ForEach child
/// of a LazyVStack in a ScrollView, environment pin above or below the row).
/// The dormancy invariant is therefore asserted where production exercises it:
/// TranscriptPerformanceFixtureTests, over a 10-tick streaming window in the
/// real transcript shape, with per-position classification and bounded
/// per-tick work.
@MainActor
final class SettledMessageIsolationTests: XCTestCase {

    /// Retained for the full lifetime of each measurement so the hosted
    /// hierarchy stays genuinely mounted; torn down explicitly per test.
    private var testWindow: UIWindow?

    override func setUp() {
        super.setUp()
        TranscriptPerf.reset()
    }

    override func tearDown() {
        // Detach the window first so dismantle work is triggered, then flush
        // it with a bounded pump before the counters reset. A zero-interval
        // tick is NOT enough on a cold simulator: the dismantle/appearance
        // transactions land ~0.3s later, inside the NEXT test's measurement
        // window, and re-attach churn there remounts the row (observed as a
        // gate-free MarkdownText re-run at the first tick render). The pump
        // is teardown hygiene — it moves pending hosting work out of the
        // next measurement window; no measurement waits on it.
        testWindow?.isHidden = true
        testWindow?.rootViewController = nil
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        testWindow = nil
        TranscriptPerf.reset()
        super.tearDown()
    }

    private func makeAppState() throws -> AppState {
        let suiteName = "settled-isolation-tests"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName),
            "test UserDefaults suite must initialize"
        )
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(defaults: defaults, loadSavedConnection: false)
    }

    private func markdownMessage(id: String = "m1") -> ChatMessage {
        ChatMessage(
            id: id,
            role: .assistant,
            content: """
            ## Heading one

            A settled paragraph with **bold**, *italic*, and `code` runs.

            - list item one
            - list item two

            > A quoted line for coverage.

            [A link](https://example.com)
            """,
            timestamp: "2026-01-01T00:00:00Z"
        )
    }

    /// Hosts an AssistantBubble row in a retained, live window. The Dynamic
    /// Type environment is PINNED: on a freshly booted CI simulator the
    /// hosting window's content-size category resolves asynchronously, and a
    /// late trait-sync transaction inside a measurement window would
    /// otherwise read as a spurious settled re-evaluation (the same failure
    /// mode testDynamicTypeChangeReOpensSettledContentGate was hardened
    /// against).
    private func mountRow(
        message: ChatMessage,
        appState: AppState,
        resolver: GatewayMediaDataURLResolver?
    ) -> UIHostingController<AnyView> {
        let row = AnyView(
            DormancyHarnessEnvironment.applying(
                AssistantBubble(
                    message: message,
                    readAloudController: appState.messageReadAloudController,
                    gatewayResolver: resolver
                )
                .chatRows()
                .environmentObject(appState)
            )
        )
        let host = UIHostingController(rootView: row)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        // makeKeyAndVisible (not a bare isHidden flip) so the key/attach
        // transition completes HERE, during the mount drain — on a cold
        // first-launch simulator a transition still in flight would flush
        // inside the measurement window and rebuild the row identity
        // (observed as a gate-free MarkdownText re-run).
        window.makeKeyAndVisible()
        testWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    /// Concrete-root hosting for the dormancy/gate tests. A stable concrete
    /// type (instead of an erased AnyView) gives UIHostingController direct
    /// value diffing and mirrors the production shape, where a streaming
    /// publish re-creates every mounted row as a concrete value through
    /// MessageBubble's switch inside an established hierarchy.
    private func makeHarnessRow(
        message: ChatMessage,
        appState: AppState,
        resolver: GatewayMediaDataURLResolver?,
        sizeCategory: ContentSizeCategory = DormancyHarnessEnvironment.pinnedSizeCategory
    ) -> SettledGateHarnessRow {
        SettledGateHarnessRow(
            message: message,
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolver,
            appState: appState,
            sizeCategory: sizeCategory
        )
    }

    /// Hosts a concrete harness row in a retained, live window (see
    /// `makeHarnessRow` for why the root must stay concrete).
    private func mountConcreteRow(
        message: ChatMessage,
        appState: AppState,
        resolver: GatewayMediaDataURLResolver?,
        sizeCategory: ContentSizeCategory = DormancyHarnessEnvironment.pinnedSizeCategory
    ) -> UIHostingController<SettledGateHarnessRow> {
        let host = UIHostingController(
            rootView: makeHarnessRow(
                message: message,
                appState: appState,
                resolver: resolver,
                sizeCategory: sizeCategory
            )
        )
        testWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        testWindow?.rootViewController = host
        // See mountRow: the key/attach transition must complete during the
        // mount drain, not inside a later measurement window.
        testWindow?.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date())
        return host
    }

    func testContentChangeStillReRendersSettledContent() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")

        let host = mountRow(message: markdownMessage(), appState: appState, resolver: resolver)

        // A genuinely changed message must open the gate. The content must
        // actually differ (not just the id) so the selectable text view
        // receives a new attributed string.
        TranscriptPerf.reset()
        var changed = markdownMessage(id: "m2")
        changed.content += "\n\nA second paragraph with different content."
        host.rootView = AnyView(AssistantBubble(
            message: changed,
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolver
        )
        .chatRows()
        .environmentObject(appState)
        .environment(\.sizeCategory, .large))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "changed content must re-evaluate settled presentation"
        )
        XCTAssertGreaterThan(
            TranscriptPerf.selectableTextViewUpdateCalls, 0,
            "changed content must update the selectable text view"
        )
    }

    /// An AppState publish that changes nothing a row shows leaves the row
    /// alone (rows used to observe AppState, so each publish redrew every
    /// row on screen); one that changes what it shows redraws it: a newer
    /// reply decides whether this one still takes a reaction.
    func testAppStatePublishRedrawsARowOnlyWhenWhatItShowsChanges() throws {
        let appState = try makeAppState()
        let host = mountRow(message: markdownMessage(), appState: appState, resolver: nil)
        drainUntil(0.5) { false }

        TranscriptPerf.reset()
        appState.objectWillChange.send()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainUntil(0.5) { false }
        XCTAssertEqual(
            TranscriptPerf.settledMessageBubbleBodyEvaluations, 0,
            "a publish that changes nothing the row shows must not redraw it"
        )

        appState.messages = [markdownMessage(id: "newest")]
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainUntil(2.0) { TranscriptPerf.settledMessageBubbleBodyEvaluations > 0 }
        XCTAssertGreaterThan(
            TranscriptPerf.settledMessageBubbleBodyEvaluations, 0,
            "a newer reply changes what the row shows"
        )
    }

    func testAppStatePublishRedrawsTheComposerOnlyWhenWhatItShowsChanges() throws {
        let appState = try makeAppState()
        let host = UIHostingController(rootView: ComposerParent().environmentObject(appState))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        testWindow = window
        XCTAssertTrue(PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.0), "the mount never settled")

        TranscriptPerf.reset()
        appState.objectWillChange.send()
        drainUntil(0.5) { false }
        XCTAssertEqual(
            TranscriptPerf.composerBarBodyEvaluations, 0,
            "a publish that changes nothing the composer shows must not redraw it, though its parent redraws"
        )

        appState.composerNotice = "Reconnecting"
        drainUntil(2.0) { TranscriptPerf.composerBarBodyEvaluations > 0 }
        XCTAssertGreaterThan(TranscriptPerf.composerBarBodyEvaluations, 0, "a notice changes what it shows")
    }

    /// Redraws on every publish, as ChatView does.
    private struct ComposerParent: View {
        @EnvironmentObject var appState: AppState
        var body: some View {
            VStack {
                Text(appState.activeProfile)
                ComposerBar(appState: appState).equatable()
            }
        }
    }

    func testResolverChangeStillReRendersSettledContent() throws {
        let appState = try makeAppState()
        let resolverA = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let resolverB = GatewayMediaDataURLResolver(appState: appState, profile: "other")

        let host = mountRow(message: markdownMessage(), appState: appState, resolver: resolverA)

        // A different resolver identity (profile switch) must open the gate.
        TranscriptPerf.reset()
        host.rootView = AnyView(AssistantBubble(
            message: markdownMessage(),
            readAloudController: appState.messageReadAloudController,
            gatewayResolver: resolverB
        )
        .chatRows()
        .environmentObject(appState)
        .environment(\.sizeCategory, .large))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "resolver identity change (profile switch) must re-evaluate settled presentation"
        )
    }

    /// The gate's INPUT CONTRACT, asserted at value level so it can never be
    /// vacuous: every field the equality describes is covered here, including
    /// the two environment-derived inputs (Dynamic Type, chat text size) and
    /// the identity fields. A publish that re-creates a settled row with the
    /// same inputs must compare equal — which is exactly the "identical
    /// recreation" condition the transcript fixtures rely on — and a change in
    /// ANY input must compare unequal so the gate opens.
    ///
    /// This is asserted directly rather than through the hosting machinery on
    /// purpose: a hosted assertion depends on SwiftUI consulting the
    /// comparison, which the measured single-row shape does not guarantee
    /// (see the class note), while this one is deterministic.
    func testEquatableConformanceComparesEveryGateInput() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let otherResolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")

        let identity = ConversationAgentIdentity.workspace(name: "Hermes", photoURL: nil)
        let a = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: identity,
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let sameInputs = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: identity,
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentResolver = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: identity,
            gatewayResolver: otherResolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentMessage = SettledAssistantMessageContent(
            message: markdownMessage(id: "m2"),
            identity: identity,
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentSizeCategory = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: identity,
            gatewayResolver: resolver,
            sizeCategory: .extraExtraLarge,
            chatTextSize: .default
        )
        let differentChatTextSize = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: identity,
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .largest
        )
        let differentName = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: .workspace(name: "Hermes (work)", photoURL: nil),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentPhotoURL = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: .workspace(name: "Hermes", photoURL: URL(string: "https://example.com/avatar.png")),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentBotFace = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: ConversationAgentIdentity(
                name: "Hermes", photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas", colorString: nil, image: UIImage()
                )
            ),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let differentBotColor = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: ConversationAgentIdentity(
                name: "Hermes", photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas", colorString: "purple", image: nil
                )
            ),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        // The bot picture compares by INSTANCE: the avatar cache hands out
        // the same object across streaming publishes, and a refresh delivers
        // a new one. Both directions of that contract are pinned here.
        let cachedPicture = UIImage()
        let withPicture = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: ConversationAgentIdentity(
                name: "Hermes", photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas", colorString: nil, image: cachedPicture
                )
            ),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let samePictureInstance = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: ConversationAgentIdentity(
                name: "Hermes", photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas", colorString: nil, image: cachedPicture
                )
            ),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let refreshedPicture = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: ConversationAgentIdentity(
                name: "Hermes", photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas", colorString: nil, image: UIImage()
                )
            ),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        // Same picture INSTANCE, only one face input differing, so every
        // arm of BotFace's equality is load-bearing on its own.
        let samePictureDifferentColor = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: ConversationAgentIdentity(
                name: "Hermes", photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas", colorString: "green", image: cachedPicture
                )
            ),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )
        let samePictureDifferentProfileName = SettledAssistantMessageContent(
            message: markdownMessage(),
            identity: ConversationAgentIdentity(
                name: "Hermes", photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas-2", colorString: nil, image: cachedPicture
                )
            ),
            gatewayResolver: resolver,
            sizeCategory: .large,
            chatTextSize: .default
        )

        XCTAssertEqual(a, sameInputs, "equal message + same resolver identity must compare equal")
        XCTAssertNotEqual(a, differentResolver, "different resolver instance must compare unequal even with equal contents")
        XCTAssertNotEqual(a, differentMessage, "different message must compare unequal")
        XCTAssertNotEqual(a, differentSizeCategory, "a Dynamic Type change must compare unequal and re-open the gate")
        XCTAssertNotEqual(a, differentChatTextSize, "a chat text-size change must compare unequal and re-open the gate")
        XCTAssertNotEqual(a, differentName, "an agent identity name change must compare unequal")
        XCTAssertNotEqual(a, differentPhotoURL, "a profile photo change must compare unequal")
        XCTAssertNotEqual(a, differentBotFace, "a bot face arriving must compare unequal")
        XCTAssertNotEqual(a, differentBotColor, "a bot color change must compare unequal")
        XCTAssertEqual(withPicture, samePictureInstance,
                       "the same cached picture instance must keep the gate closed across streaming publishes")
        XCTAssertNotEqual(withPicture, refreshedPicture,
                          "a refreshed picture instance must re-open the gate")
        XCTAssertNotEqual(withPicture, samePictureDifferentColor,
                          "a color-string change must compare unequal")
        XCTAssertNotEqual(withPicture, samePictureDifferentProfileName,
                          "a profile-name change (the color's fallback seed) must compare unequal")
    }

    /// The identity value the transcript gates on must be stable across
    /// SEPARATE construction: a streaming publish re-creates the row's
    /// inputs, and the bot's picture (the same instance the avatar cache
    /// hands out) plus its face inputs must compare equal so the settled
    /// rows stay gated.
    func testConversationAgentIdentityEqualityIsStableAcrossSeparateValues() {
        let picture = UIImage()
        let first = ConversationAgentIdentity(
            name: "Atlas Prime",
            photoURL: nil,
            botFace: ConversationAgentIdentity.BotFace(
                name: "atlas", colorString: "purple", image: picture
            )
        )
        let second = ConversationAgentIdentity(
            name: "Atlas Prime",
            photoURL: nil,
            botFace: ConversationAgentIdentity.BotFace(
                name: "atlas", colorString: "purple", image: picture
            )
        )
        XCTAssertEqual(first, second,
                       "same picture instance + same face inputs must compare equal")

        XCTAssertNotEqual(
            first,
            ConversationAgentIdentity(
                name: "Atlas Prime",
                photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas", colorString: "purple", image: UIImage()
                )
            ),
            "a refreshed picture instance must compare unequal"
        )
        XCTAssertNotEqual(
            first,
            ConversationAgentIdentity(
                name: "Atlas Prime",
                photoURL: nil,
                botFace: ConversationAgentIdentity.BotFace(
                    name: "atlas-2", colorString: "purple", image: picture
                )
            ),
            "a bot profile rename re-seeds the fallback hue, so the face must compare unequal"
        )
    }

    /// Dynamic Type invalidation (#4): a size-category change must re-open
    /// the settled-content gate so the settled Markdown body re-evaluates.
    ///
    /// Same-category dormancy (the streaming-tick shape) is covered in the
    /// production transcript shape by
    /// TranscriptPerformanceFixtureTests.testStreamingTicksLeaveSettledMarkdownDormant_*;
    /// this test exercises only the gate-reopening half.
    ///
    /// Structurally deterministic: after each mutation the run loop is
    /// drained until the asserted condition holds or a bounded deadline
    /// expires. SwiftUI hosting commits are driven by display links, which
    /// need real elapsed time — a zero-interval `RunLoop.run(until: Date())`
    /// tick observes only whatever flushed synchronously and made the
    /// previous version of this test flaky on slower CI runners (a late
    /// transaction from the initial mount landed inside the measurement
    /// window). Actual font delivery cannot be asserted in-process:
    /// UIFontMetrics resolve against UIApplication's
    /// preferredContentSizeCategory, which is process-global. The Equatable
    /// input contract (including sizeCategory) is covered directly by
    /// testEquatableConformanceComparesEveryGateInput.
    func testDynamicTypeChangeReOpensSettledContentGate() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let message = markdownMessage()

        let host = mountConcreteRow(
            message: message,
            appState: appState,
            resolver: resolver,
            sizeCategory: .large
        )
        // Let the initial mount fully settle — including trait-sync follow-up
        // transactions — before arming the measurement window.
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        TranscriptPerf.reset()
        host.rootView = makeHarnessRow(
            message: message,
            appState: appState,
            resolver: resolver,
            sizeCategory: .extraExtraLarge
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        XCTAssertGreaterThan(
            TranscriptPerf.settledMarkdownTextBodyEvaluations, 0,
            "a Dynamic Type change must re-open the settled-content gate and re-evaluate settled content"
        )
    }

    /// Drains the run loop in short real intervals until `condition` holds or
    /// the bounded deadline passes. Display-link-driven SwiftUI commits need
    /// elapsed time to fire, so draining until the observable state is
    /// reached is deterministic where a fixed zero-interval tick is not: it
    /// exits as early as possible and fails only when the state genuinely
    /// never arrives.
    private func drainUntil(_ seconds: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Window trait churn (the hosted determinism vector)

    /// Records the ambient sizeCategory its body sees. Mounted OUTSIDE the
    /// harness pin as a sibling, it proves a window trait churn actually
    /// reached the hosted hierarchy — without it, a churn that no-op'd
    /// would let the dormancy assertion below pass vacuously.
    private final class AmbientObservationBox {
        var observed: [ContentSizeCategory] = []
    }

    private struct AmbientSizeCategoryCanary: View {
        @Environment(\.sizeCategory) private var ambient
        let box: AmbientObservationBox

        var body: some View {
            let _ = box.observed.append(ambient)
            Color.clear.frame(height: 0)
        }
    }

    /// Deterministic regression for the build-147 hosted blocker (Sep 2026):
    /// environment churn in the ancestry ABOVE the harness pin — the shape
    /// hosting-level trait sync takes (freshly booted CI simulators re-push
    /// window traits under the app root) — must NOT re-open the settled
    /// gate, because the harness re-asserts the gate's environment inputs
    /// BELOW the churn point.
    ///
    /// Hierarchy (review-corrected): the ambient `.environment(\.sizeCategory)`
    /// write sits on the COMMON ANCESTOR of the canary and the pinned row,
    /// so the churn genuinely propagates into the ROW's ancestry — not just
    /// into the canary's subtree. The unpinned canary above the pin proves
    /// the churn reached the hosted hierarchy (vacuity guard); the harness
    /// pin below the ancestor re-asserts the row's gate inputs, which is
    /// exactly the shielding under test.
    ///
    /// Delivery vehicle: a CONCRETE rootView value re-assignment mutating
    /// ONLY `ambient` (the pinned values and the row value are re-applied
    /// unchanged). No AnyView erasure in THIS vehicle — UIHostingController
    /// diffs the concrete root, the same `SettledGateHarnessRow` value is
    /// re-applied unchanged below the harness pin so SwiftUI preserves the
    /// row's structural identity, and the vehicle cannot recreate the
    /// erased-root remount artifact #200 removed. Genuine remounts would
    /// surface in the fresh-mount/window-duplicate ledgers; ambient
    /// propagation shows in the canary; pinning shows in the zero counts.
    ///
    /// Mutation-sensitive: strip the DormancyHarnessEnvironment pinning and
    /// the same churn flows through the row's ancestry into
    /// `AssistantBubble`'s `\.sizeCategory` environment read, opens the
    /// SettledAssistantMessageContent gate (field: sizeCategory — visible
    /// in the gate-reopen report), and re-evaluates MarkdownText, failing
    /// the zero assertions.
    func testWindowTraitChurnDoesNotReopenSettledGate() throws {
        let appState = try makeAppState()
        let resolver = GatewayMediaDataURLResolver(appState: appState, profile: "default")
        let message = markdownMessage()
        let canary = AmbientObservationBox()

        // Ambient environment on the COMMON ANCESTOR (stands in for the
        // window's); the harness pin BELOW it stays constant across the
        // churn and overrides ambient for the row's subtree.
        struct ChurnableRoot: View {
            let ambient: ContentSizeCategory
            let canary: AmbientObservationBox
            let row: SettledGateHarnessRow

            var body: some View {
                VStack(spacing: 0) {
                    AmbientSizeCategoryCanary(box: canary)
                    DormancyHarnessEnvironment.applying(row)
                }
                .environment(\.sizeCategory, ambient)
            }
        }

        let row = makeHarnessRow(
            message: message,
            appState: appState,
            resolver: resolver
        )
        let host = UIHostingController(
            rootView: ChurnableRoot(ambient: .large, canary: canary, row: row)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        // See mountRow: absorb the key/attach transition at mount.
        window.makeKeyAndVisible()
        testWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        // Initial mount performed the settled work; wait it out so the
        // measurement window opens on a quiet hierarchy.
        drainUntil(2.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }
        let settled = PerformanceFixtureWait.settleUntilCountersQuiet(quietFor: 1.2)
        guard settled else {
            XCTFail("counters never reached a quiet state; the churn measurement would be meaningless")
            return
        }

        TranscriptPerf.reset()

        // The churn: ambient environment above the pin changes; the pin
        // itself is re-applied unchanged below it.
        host.rootView = ChurnableRoot(ambient: .extraExtraExtraLarge, canary: canary, row: row)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Give any (incorrect) re-evaluation time to surface before
        // asserting, so the zero assertions measure reality.
        drainUntil(1.0) { TranscriptPerf.settledMarkdownTextBodyEvaluations > 0 }

        // Vacuity guard: the churn MUST have reached the hierarchy — the
        // canary sits OUTSIDE the pinned subtree, so it observes whatever
        // the ambient ancestor pushed down (here: the churned category).
        // Without this, a churn that no-op'd would make the zero
        // assertions below pass without testing anything.
        guard canary.observed.last == .extraExtraExtraLarge else {
            XCTFail(
                "ambient churn never reached the hosted hierarchy " +
                "(canary saw \(canary.observed.last.map(String.init(describing:)) ?? "nothing")); " +
                "test measures nothing"
            )
            return
        }

        // Anti-vacuity, part 2 of 2 — carried by the MUTATION CYCLE, not a
        // counter: with the pin present, SwiftUI prunes the row's subtree
        // outright, because its value AND its effective environment are
        // unchanged below the pin (AssistantBubble bodies stay flat BY
        // DESIGN — that is the pin holding). A bubble-body counter would
        // contradict correct pruning semantics. What proves this vehicle
        // genuinely reaches the row is stripping the pin: the exact same
        // churn then flows into the row's `\.sizeCategory` read, opens the
        // gate, and fails the zero assertions (executed red/green/green in
        // the PR's validation).
        //
        // THE INVARIANT: pinned settled content stays dormant under the
        // same churn that reached the unpinned canary.
        let evaluations = TranscriptPerf.settledMarkdownTextBodyEvaluations
        let reopenSuffix = TranscriptPerf.recentGateReopenReports.isEmpty
            ? ""
            : " (gate reopens: \(TranscriptPerf.recentGateReopenReports.joined(separator: "; ")))"
        XCTAssertEqual(
            evaluations, 0,
            "ancestry environment churn must not re-evaluate pinned settled Markdown"
                + " (evaluations: \(evaluations)\(reopenSuffix)"
                + (TranscriptPerf.windowEvaluationSpans.isEmpty
                    ? ")"
                    : "; spans: \(TranscriptPerf.windowEvaluationSpans.joined(separator: " | "))")
        )
        XCTAssertEqual(
            TranscriptPerf.selectableTextViewUpdateCalls, 0,
            "ancestry environment churn must not touch SelectableTextView for settled content"
        )
    }
}

/// Concrete hosted root for the gate tests. A stable concrete type (instead
/// of an erased AnyView) gives UIHostingController direct value diffing:
/// changing `sizeCategory` is a first-class rootView value change, and the
/// environment write happens inside `body` exactly once per value.
///
/// MUST stay non-Equatable: the dormancy fixture relies on the root's body
/// re-running (and re-diffing `AssistantBubble`) on every re-assignment so
/// the inner `SettledAssistantMessageContent.equatable()` gate is what
/// actually holds the row at rest. An Equatable root could let SwiftUI prune
/// the update above the gate and make the stay-at-zero assertion vacuous —
/// the fixture guards this with its bubble-body anti-vacuity check.
private struct SettledGateHarnessRow: View {
    let message: ChatMessage
    let readAloudController: MessageReadAloudController
    let gatewayResolver: GatewayMediaDataURLResolver?
    let appState: AppState
    let sizeCategory: ContentSizeCategory

    var body: some View {
        DormancyHarnessEnvironment.applying(
            AssistantBubble(
                message: message,
                readAloudController: readAloudController,
                gatewayResolver: gatewayResolver
            )
            .chatRows()
            .environmentObject(appState),
            sizeCategory: sizeCategory
        )
        // Note: DormancyHarnessEnvironment.applying pins BOTH gate
        // environment inputs; the explicit sizeCategory parameter preserves
        // the Dynamic Type mutation vector for
        // testDynamicTypeChangeReOpensSettledContentGate. The pinning
        // contract's mutation sensitivity is carried by
        // testWindowTraitChurnDoesNotReopenSettledGate (sizeCategory) and
        // testSharedChatTextSizePreferenceChurnDoesNotReopenSettledGate
        // (chatTextSize).
    }
}
