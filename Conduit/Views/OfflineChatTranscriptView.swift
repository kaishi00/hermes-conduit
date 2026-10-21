//
//  OfflineChatTranscriptView.swift
//  Conduit
//
//  Read-only presentation of the saved offline copy (#99), and of a chat
//  picked in the saved Chats list while it opens.
//

import SwiftUI

struct OfflineChatTranscriptView: View {
    let presentation: OfflineChatPresentation
    @EnvironmentObject var appState: AppState
    @Environment(\.v2ComposerRests) private var composerFloats

    private static let topAnchor = "offline-chat-top"

    /// Only a real offline state says this is a saved copy. While Hermes is
    /// on its way, between retries too, the copy reads as the chat itself,
    /// and the header and the composer say Conduit is connecting.
    private var showsBanner: Bool {
        !appState.isConnected && !appState.isRecoveringConnection
    }

    /// A chat picked in the saved list with no copy of its own, on its way
    /// in: it says so for as long as the banner is down.
    private var isOpeningPickedChat: Bool {
        presentation.isPickedChat && presentation.displayedRows.isEmpty && !showsBanner
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsBanner {
                OfflineChatBanner(
                    savedAt: presentation.displayedTranscript?.savedAt,
                    showsCopy: !presentation.displayedRows.isEmpty
                )
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: ChatStepStyle.transcriptRowSpacing) {
                    Color.clear
                        .frame(height: 1)
                        .id(Self.topAnchor)
                    if isOpeningPickedChat {
                        ProgressView("Opening conversation…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    } else if presentation.displayedRows.isEmpty && appState.pendingComposerSendOnScreen == nil {
                        Text("No saved copy of this conversation")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    }
                    OfflineChatRows(rows: presentation.displayedRows)
                    // A message sent while the chat is on its way waits
                    // below the copy.
                    if let pending = appState.pendingComposerSendOnScreen {
                        PendingComposerSendBubble(pending: pending)
                    }
                    // Ends as the live transcript does (ChatView's bottom
                    // anchor): a 1 pt row one row spacing below the last, so
                    // the copy lines up with it when it hands over.
                    Color.clear
                        .frame(height: 1)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
            }
            .modifier(V2SoftTopScrollEdge(isOn: composerFloats))
            .defaultScrollAnchor(.bottom)
            // A different saved conversation starts at its own latest row.
            .id(presentation.displayedSessionID)
            // The header title's scroll-to-top acts on the saved copy while
            // it is the conversation on screen.
            .onChange(of: appState.chatScrollToTopRequest) { _, _ in
                withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
            }
            .onChange(of: appState.pendingComposerSendOnScreen?.draftText) { _, text in
                guard text != nil else { return }
                withAnimation { proxy.scrollTo(PendingComposerSendBubble.scrollID, anchor: .bottom) }
            }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsBanner)
        .accessibilityIdentifier("offline-chat-transcript")
        .chatRows()
    }
}

/// The saved rows as the live transcript draws them: a turn's steps as one
/// card with their times, pictures kept on the phone, reactions.
private struct OfflineChatRows: View {
    let rows: [ChatMessageScrollTarget]
    @EnvironmentObject var appState: AppState
    /// Which step cards are open, for this conversation only: the scroll
    /// view's `.id` starts the next one with its own.
    @State private var disclosure = ChatRowDisclosure()
    @State private var stepToggleRevision: UInt64 = 0

    /// As the live transcript: a step that draws nothing gets no row, or the
    /// stack would space it (ChatStepPlacement.drawsRow).
    private var drawnRows: [ChatMessageScrollTarget] {
        _ = stepToggleRevision
        let preferences = appState.displayPreferences
        return rows.filter { row in
            row.step?.drawsRow(messageID: row.id, preferences: preferences, isBusy: appState.isBusy, disclosure: disclosure) ?? true
        }
    }

    var body: some View {
        ForEach(drawnRows) { row in
            MessageBubble(
                message: row.message,
                gatewayResolver: appState.gatewayMediaResolver,
                step: row.step
            )
            .equatable()
        }
        .environment(\.chatRowDisclosure, disclosure)
        .onReceive(disclosure.groupToggles.$revision) { stepToggleRevision = $0 }
    }
}

/// Up only while Hermes can't be reached: Retry and Sign In are what it
/// offers.
private struct OfflineChatBanner: View {
    let savedAt: Date?
    /// A saved conversation is on screen. Without one (a chat picked in the
    /// saved list that has no copy) the banner says Hermes can't be reached.
    let showsCopy: Bool
    @EnvironmentObject var appState: AppState

    private var title: String {
        showsCopy
            ? AppLocalization.string("Showing a saved copy")
            : AppLocalization.string("Can't reach Hermes")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                if let savedAt {
                    Text("Saved \(savedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
