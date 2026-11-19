//
//  ChatListUpdatingPill.swift
//  Conduit
//
//  "Updating…" over the Chats list while rows that may be out of date are
//  read again (issue 2706): the saved copy at launch, a list from before
//  the app went to the background, a profile's list before its first read.
//

import SwiftUI

/// A small capsule at the bottom of a chats list. It floats over the rows
/// rather than pushing them down, so a row never moves under a finger, and
/// it takes no taps. It waits a moment before it shows, so a quick read
/// doesn't flash it, and it stays a moment after, so a connection handing
/// over to its read doesn't blink it off and on.
struct ChatListUpdatingPill: View {
    /// `AppState.showsChatListUpdating(overProjects:hidesPulseHomeChat:)`.
    let isUpdating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    static let showDelay: Duration = .milliseconds(400)
    static let hideDelay: Duration = .milliseconds(300)

    var body: some View {
        ZStack {
            if shown {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(AppLocalization.string("Updating…"))
                        .scaledFont(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
                .padding(.bottom, 8)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("chats.updating")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .task(id: isUpdating) {
            try? await Task.sleep(for: isUpdating ? Self.showDelay : Self.hideDelay)
            guard !Task.isCancelled, shown != isUpdating else { return }
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { shown = isUpdating }
        }
    }
}
