import Foundation
import SwiftUI

/// Viewport and draft keys for bot/group conversations. The reserved profile
/// never enters Hermes session identity; it only scopes composer drafts and
/// ChatViewportController follow-latest state.
enum MessagingConversationChrome {
    static let reservedProfile = "__conduit_messaging__"

    static func sessionKey(for destination: MessagingDestination) -> ChatScrollSessionKey {
        ChatScrollSessionKey(profile: reservedProfile, sessionID: destination.id)
    }

    static func identity(for destination: MessagingDestination) -> ChatScrollSessionIdentity {
        ChatScrollSessionIdentity(
            profile: reservedProfile,
            canonicalSessionID: destination.id,
            equivalentSessionIDs: [destination.id],
            isReconciling: false,
            settledRevision: 0
        )
    }

    static func draftKey(for destination: MessagingDestination) -> ComposerDraftKey {
        ComposerDraftKey(profile: reservedProfile, sessionID: destination.id)
    }
}

enum MessagingComposerAction {
    static func resolve(
        hasText: Bool,
        canWrite: Bool,
        isSending: Bool,
        hasPending: Bool
    ) -> ComposerAction {
        guard canWrite, !isSending, !hasPending, hasText else { return .unavailable }
        return .send
    }
}

struct MessagingComposerAdapter {
    let placeholder: String
    let canWrite: Bool
    let isSending: Bool
    let hasPending: Bool
    let editorAccessibilityIdentifier: String
    let draftKey: ComposerDraftKey
    let seedDraft: String
    let onDraftChange: (String) -> Void
    let onSend: (String) async -> Bool
}

/// Generic optimistic typing chrome while messaging waits for real run presence.
struct MessagingAwaitingReplyDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                staticDots
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { index in
                            let phase = (t + Double(index) * 0.18).truncatingRemainder(dividingBy: 0.9) / 0.9
                            let lift = abs(sin(phase * .pi))
                            Circle()
                                .fill(Color.secondary.opacity(0.85))
                                .frame(width: 7, height: 7)
                                .offset(y: -4 * lift)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .conduitGlassSurface(cornerRadius: 16, tint: .conduitAccent.opacity(0.07))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for a reply")
        .accessibilityIdentifier("messaging.awaiting-reply")
    }

    private var staticDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.secondary.opacity(0.7))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
