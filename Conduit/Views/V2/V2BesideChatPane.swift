//
//  V2BesideChatPane.swift
//  Conduit
//
//  The chat kept beside the one on screen in a wide window (all-live stage
//  2, AppState+BesideChat.swift): its newest rows, and its reply as it
//  streams. The pane only shows. Swap opens its chat in the chat's own
//  column, where it can be written to, and keeps the other here.
//

import SwiftUI

struct V2BesideChatPane: View {
    @EnvironmentObject private var appState: AppState
    let chat: BackgroundChat

    var body: some View {
        ZStack {
            V2Backdrop(drifts: false, glowProfile: chat.profile)
            VStack(spacing: 0) {
                header
                V2BesideChatRows(
                    live: appState.besideChatLive,
                    chat: chat,
                    gatewayResolver: appState.gatewayMediaResolver(for: chat.profile)
                )
            }
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(verbatim: chat.title)
                .scaledFont(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button {
                Haptics.selection()
                appState.swapBesideChat()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(AppLocalization.string("Swap Chats", table: .chat))
            .accessibilityHint(AppLocalization.string("Opens this chat to write in, and keeps the other one here.", table: .chat))
            Button {
                Haptics.selection()
                appState.closeBesideChat()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(AppLocalization.string("Close Chat Beside", table: .chat))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.conduitAccent)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 52)
    }
}

/// The pane's rows. They follow the pane's own notice (`BesideChatLive`),
/// so a reply streaming here redraws these and nothing else.
private struct V2BesideChatRows: View {
    @ObservedObject var live: BesideChatLive
    let chat: BackgroundChat
    let gatewayResolver: GatewayMediaDataURLResolver

    /// The newest rows it draws: Swap shows the whole chat.
    private static let rowLimit = 60

    var body: some View {
        let state = chat.state
        let isRunning = chat.isRunning
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(chat.newestSettledRows(Self.rowLimit)) { row in
                    MessageBubble(message: row, gatewayResolver: gatewayResolver)
                        .equatable()
                }
                if let thinking = chat.liveThinkingRow {
                    ThinkingCard(message: thinking)
                }
                if !state.streamingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    StreamingBubble(text: state.streamingBuffer, active: isRunning)
                } else if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.conduitAccent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(AppLocalization.string("Working"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // Nothing here acts on its chat: Swap opens it to act on.
            .allowsHitTesting(false)
        }
        .defaultScrollAnchor(.bottom)
        .chatRowsBeside(profile: chat.profile, isBusy: isRunning)
    }
}
