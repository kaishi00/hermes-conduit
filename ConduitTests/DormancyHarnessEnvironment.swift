import SwiftUI
@testable import Conduit

/// Single source for the environment pinning the dormancy harnesses rely
/// on (settled-Markdown hosted determinism, Sep 2026).
///
/// Why this exists: `.equatable()` gates a settled row's INPUTS, but SwiftUI
/// environment changes still re-evaluate a gated subtree's body. Both gate
/// types consume `\.sizeCategory` and `\.chatTextSize` as explicit inputs;
/// when the hosting environment churns beneath the harness (freshly booted
/// CI simulators resolve window traits asynchronously and re-push them on
/// layout passes), an unpinned harness lets those pushes re-run
/// MarkdownText with every gate input still equal — the nondeterministic
/// hosted failure that blocked build 147 (unit-7, run 35597418648).
///
/// Every dormancy harness mounts through `applying(_:sizeCategory:chatTextSize:)`
/// so the pinning contract has exactly one implementation. The mutation
/// sensitivities are carried where the effective writes live: strip the
/// sizeCategory write HERE and `testWindowTraitChurnDoesNotReopenSettledGate`
/// fails deterministically (the ambient churn then reaches the row). The
/// chatTextSize write here mirrors ChatView's production shape but is
/// shadowed by ChatView's own inner @AppStorage-driven write — that vector's
/// mutation sensitivity lives at the effective write point: strip
/// `ChatView.chatTextSizeOverride` (in the fixture harness) and
/// `testSharedChatTextSizePreferenceChurnDoesNotReopenSettledGate` fails
/// deterministically.
enum DormancyHarnessEnvironment {

    /// The Dynamic Type value the isolation harnesses pin (production
    /// default). The transcript fixtures pin the same value.
    static let pinnedSizeCategory: ContentSizeCategory = .large

    /// The chat text-size value the harnesses pin (ChatView's own default).
    static let pinnedChatTextSize: ChatTextSize = .default

    /// Apply the harness environment to `view`. The ONLY sanctioned way to
    /// mount a dormancy-fixture hierarchy.
    ///
    /// Also pins `\.scenePhase` to `.active`: a harness window belongs to no
    /// Scene, so SwiftUI reports `.background`, and ChatView pauses its
    /// scroll engine in the background. The transcript then never pins to
    /// the bottom, and an appended row is never mounted. The chat is only
    /// ever on screen in an active scene (production's WindowGroup).
    static func applying<V: View>(
        _ view: V,
        sizeCategory: ContentSizeCategory = DormancyHarnessEnvironment.pinnedSizeCategory,
        chatTextSize: ChatTextSize = DormancyHarnessEnvironment.pinnedChatTextSize
    ) -> some View {
        view
            .environment(\.sizeCategory, sizeCategory)
            .environment(\.chatTextSize, chatTextSize)
            .environment(\.scenePhase, .active)
    }
}
