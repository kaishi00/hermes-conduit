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

private struct V2ComposerRestsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// V2's conversation: the composer rests as a slim bar beside the voice
    /// button and expands while it is in use.
    var v2ComposerRests: Bool {
        get { self[V2ComposerRestsKey.self] }
        set { self[V2ComposerRestsKey.self] = newValue }
    }
}

/// Whether a resting composer has expanded, so the voice button beside it
/// can step aside and the minimised call bar hide.
struct V2ComposerExpandedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct V2ConversationScreen: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerExpanded = false
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
                    .environment(\.v2ComposerRests, true)
            }
        }
        .modifier(V2FadingBarBackdrop())
        .onPreferenceChange(V2ComposerExpandedKey.self) { expanded in
            composerExpanded = expanded
        }
        .overlay(alignment: .bottomTrailing) {
            if appState.activeRoomSurface == nil {
                // Beside the resting composer; it slides aside, shrinks and
                // fades while the composer is expanded.
                V2VoiceButton(context: .conversation, isHidden: composerExpanded)
                    .scaleEffect(composerExpanded && !reduceMotion ? 0.4 : 1)
                    .offset(x: composerExpanded && !reduceMotion ? 30 : 0)
                    .opacity(composerExpanded ? 0 : 1)
                    .allowsHitTesting(!composerExpanded)
                    .accessibilityHidden(composerExpanded)
                    .padding(.trailing, 16)
                    .padding(.bottom, 10)
                    .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: composerExpanded)
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
                        V2ConnectionLine()
                    }
                    .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.isConnected)
                    .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.isConnecting)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                V2ConversationMenu(
                    onRename: { chatTitlePendingRename = $0 },
                    onDelete: { chatTitlePendingDeletion = $0 }
                )
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

/// Before iOS 26, a fading material behind the navigation bar, so the
/// transcript fades out under the header instead of ending at a line.
/// iOS 26 gets its soft scroll edge on the transcript itself (ChatView).
private struct V2FadingBarBackdrop: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.overlay(alignment: .top) {
                // Zero height at the top of the content: ignoring the safe
                // area grows it up over exactly the navigation bar.
                V2ScrollEdgeBackground()
                    .frame(height: 0)
            }
        }
    }
}

/// Shown under the title only while the gateway isn't connected, so the
/// header stays quiet when all is well.
private struct V2ConnectionLine: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if !appState.isConnected {
            let connecting = appState.isConnecting
            HStack(spacing: 4) {
                Image(systemName: connecting ? "arrow.triangle.2.circlepath" : "wifi.slash")
                    .font(.caption2.weight(.bold))
                Text(connecting ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Disconnected"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(connecting ? Color.orange : Color.red)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(connecting ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Disconnected"))
        }
    }
}

/// The header's one trailing control: refresh and the conversation's own
/// actions, with the gateway's state as a dot on the button and its
/// diagnostics one item away.
private struct V2ConversationMenu: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void

    private var statusColor: Color {
        if appState.isConnected { return .green }
        return appState.isConnecting ? .orange : .red
    }

    private var statusWord: String {
        if appState.isConnected { return AppLocalization.string("Connected") }
        return appState.isConnecting ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Disconnected")
    }

    var body: some View {
        Menu {
            // An open room has its own actions in its header.
            if appState.activeRoomSurface == nil {
                Button {
                    Task { await appState.refreshActiveSession() }
                } label: {
                    Label(AppLocalization.string("Refresh conversation"), systemImage: "arrow.clockwise")
                }
                .disabled(!appState.isConnected || appState.isChatRefreshing)
                if let session = appState.activeChatSessionSummary {
                    Section {
                        SessionActionMenuItems(
                            session: session,
                            onRename: { onRename(session) },
                            onDelete: { onDelete(session) }
                        )
                    }
                }
            }
            Section(statusWord) {
                Button {
                    // The sheet loads its diagnostics as it opens.
                    appState.showGatewaySheet = true
                } label: {
                    Label(AppLocalization.string("Gateway"), systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        } label: {
            // The two glyphs crossfade in one fixed frame, so the dot stays put.
            ZStack {
                // Mounted only while refreshing, so a hidden spinner never runs.
                if appState.isChatRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .opacity(appState.isChatRefreshing ? 0 : 1)
            }
            .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.isChatRefreshing)
            .accessibilityHidden(true)
            .frame(width: 40, height: 40)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .offset(x: -8, y: 8)
                    .accessibilityHidden(true)
            }
            .modifier(V2PreGlassToolbarControl())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(AppLocalization.string("Conversation options"))
        .accessibilityValue(statusWord)
        .accessibilityIdentifier("conversation.menu")
    }
}

/// iOS 26 draws toolbar items on its own glass; earlier versions get the
/// app's glass circle so the control still reads as a button.
private struct V2PreGlassToolbarControl: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.10))
        }
    }
}
