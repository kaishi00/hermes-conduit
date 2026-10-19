//
//  PendingComposerSendBubble.swift
//  Conduit
//
//  A message sent while its chat was on its way, waiting below the chat's
//  rows until it goes (AppState+PendingSend.swift).
//

import SwiftUI

struct PendingComposerSendBubble: View {
    let pending: PendingComposerSend
    @EnvironmentObject var appState: AppState
    @Environment(\.sizeCategory) private var sizeCategory
    @Environment(\.chatTextSize) private var chatTextSize

    static let scrollID = "pending-composer-send"
    private static let timestampFormatter = ISO8601DateFormatter()

    private var message: ChatMessage {
        ChatMessage(
            id: "pending-\(pending.id.uuidString)",
            role: .user,
            content: pending.outboundText,
            timestamp: Self.timestampFormatter.string(from: pending.queuedAt)
        )
    }

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                UserMessageContent(
                    message: message,
                    gatewayResolver: nil,
                    sizeCategory: sizeCategory,
                    chatTextSize: chatTextSize
                )

                HStack(spacing: 10) {
                    Label("Sends when connected", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Edit") {
                        Haptics.selection()
                        appState.editPendingComposerSend()
                    }
                    .font(.caption.weight(.semibold))
                    .accessibilityHint(Text("Puts the message back in the composer to change or delete"))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(pending.draftText))
            .accessibilityHint(Text(pending.replyText ?? ""))
            .accessibilityValue(Text("Sends when connected"))
            .accessibilityAction(named: Text("Edit")) {
                Haptics.selection()
                appState.editPendingComposerSend()
            }
        }
        .id(Self.scrollID)
        .accessibilityIdentifier("pending-composer-send")
    }
}
