//
//  OfflineChatTranscriptView.swift
//  Conduit
//
//  Read-only presentation of the saved offline copy (#99).
//

import SwiftUI

struct OfflineChatTranscriptView: View {
    let presentation: OfflineChatPresentation
    @EnvironmentObject var appState: AppState

    private static let topAnchor = "offline-chat-top"

    var body: some View {
        VStack(spacing: 0) {
            OfflineChatBanner(savedAt: presentation.displayedTranscript?.savedAt)
                .padding(.horizontal, 18)
                .padding(.top, 10)
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    Color.clear
                        .frame(height: 1)
                        .id(Self.topAnchor)
                    if presentation.displayedMessages.isEmpty {
                        Text("No saved copy of this conversation")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    }
                    ForEach(presentation.displayedMessages) { message in
                        MessageBubble(message: message, gatewayResolver: nil)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 126)
            }
            .defaultScrollAnchor(.bottom)
            // A different saved conversation starts at its own latest row.
            .id(presentation.displayedSessionID)
            // The header title's scroll-to-top acts on the saved copy while
            // it is the conversation on screen.
            .onChange(of: appState.chatScrollToTopRequest) { _, _ in
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
            }
        }
        .accessibilityIdentifier("offline-chat-transcript")
    }
}

private struct OfflineChatBanner: View {
    let savedAt: Date?
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing a saved copy")
                    .font(.footnote.weight(.semibold))
                if let savedAt {
                    Text("Saved \(savedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if appState.isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Reconnecting…")
            } else {
                Button("Retry") { appState.retryFromOfflineChat() }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.conduitAccent)
                if appState.connection == nil {
                    Button("Sign In") { appState.signInFromOfflineChat() }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.conduitAccent)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
