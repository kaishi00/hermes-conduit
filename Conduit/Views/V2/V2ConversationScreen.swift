//
//  V2ConversationScreen.swift
//  Conduit
//
//  The open conversation, pushed over Chats (or Bots for a bot's chat) with
//  the tab bar hidden. The same ChatView and GroupChatView the drawer shell
//  showed; only the header changes: Back replaces the drawer button, and a
//  child session (a call's job, a chat's call) gets a gold link back to the
//  conversation it came from.
//

import SwiftUI

struct V2ConversationScreen: View {
    @EnvironmentObject private var appState: AppState
    @State private var chatTitlePendingRename: SessionSummary?
    @State private var chatTitlePendingDeletion: SessionSummary?

    private var parent: SessionSummary? {
        guard appState.activeRoomSurface == nil,
              let session = appState.activeChatSessionSummary else { return nil }
        return appState.nestingParent(of: session)
    }

    var body: some View {
        ZStack {
            V2Backdrop()
            if appState.activeRoomSurface != nil {
                // Keyed by room: another room starts with its own draft.
                GroupChatView()
                    .id(appState.activeRoomSurface?.room.roomID)
            } else {
                ChatView()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // An open room supplies its own leading Leave button, which also
        // ends this screen; a second leading control would be ambiguous.
        .navigationBarBackButtonHidden(appState.activeRoomSurface != nil)
        .toolbar {
            // Session-only controls: an open room owns the title and actions.
            if appState.activeRoomSurface == nil {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        ChatTitleControl(
                            onRename: { chatTitlePendingRename = $0 },
                            onDelete: { chatTitlePendingDeletion = $0 },
                            compact: parent != nil
                        )
                        if let parent {
                            Button {
                                Haptics.light()
                                appState.requestOpenSession(parent.id)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.turn.left.up")
                                        .font(.caption2.weight(.bold))
                                    Text(parent.title)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(Color.conduitAccent)
                                .frame(minHeight: 18)
                            }
                            .buttonStyle(.plain)
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .accessibilityLabel(AppLocalization.string("From \(parent.title)"))
                            .accessibilityHint(AppLocalization.string("Opens the conversation this one came from"))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await appState.refreshActiveSession() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .rotationEffect(.degrees(appState.isChatRefreshing ? 360 : 0))
                            .animation(
                                appState.isChatRefreshing
                                    ? .linear(duration: 0.75).repeatForever(autoreverses: false)
                                    : .default,
                                value: appState.isChatRefreshing
                            )
                            .frame(width: 40, height: 40)
                    }
                    .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.10))
                    .disabled(!appState.isConnected || appState.isChatRefreshing)
                    .accessibilityLabel(AppLocalization.string("Refresh conversation"))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionStatusIndicator()
            }
        }
        .sheet(item: $chatTitlePendingRename) { session in
            RenameSheet.conversation(session) { title in
                Task { await appState.renameSession(session, to: title) }
            }
        }
        .alert("Delete conversation?", isPresented: Binding(
            get: { chatTitlePendingDeletion != nil },
            set: { if !$0 { chatTitlePendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let session = chatTitlePendingDeletion else { return }
                chatTitlePendingDeletion = nil
                Task { await appState.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) { chatTitlePendingDeletion = nil }
        } message: {
            Text("This permanently deletes the conversation and cannot be undone.")
        }
    }
}
