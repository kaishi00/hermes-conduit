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
/// can step aside.
struct V2ComposerExpandedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Whether someone is typing in a resting composer (it has focus), so the
/// minimised call bar steps aside for the keyboard. Only typing hides it:
/// a running turn or a notice also expands the composer, and hiding the bar
/// then left a call started from the chat with no way back (#695).
struct V2ComposerTypingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

struct V2ConversationScreen: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v2Shell) private var shell
    @State private var composerExpanded = false
    @AppStorage(V2ChatListPreference.key) private var chatListBeside = V2ChatListPreference.defaultValue
    @AppStorage(ChatVoiceButtonAction.key) private var appChatVoiceButton = ChatVoiceButtonAction.defaultValue.rawValue
    /// A voice message recorded while the big button is held keeps the
    /// button under the finger, though the composer opens beside it.
    @ObservedObject private var voiceMessages = VoiceMessageRecorder.shared

    private var hidesVoiceButton: Bool { composerExpanded && !voiceMessages.isHeld }
    @State private var chatTitlePendingRename: SessionSummary?
    @State private var chatTitlePendingDeletion: SessionSummary?
    @State private var confirmsRoomDisband = false
    @State private var choosesRoomPicture: GroupRoomPictureRequest?
    /// The open chat's ids while its Artifacts sheet shows.
    @State private var artifactSessionIDs: ArtifactSheetIDs?

    private var parent: SessionSummary? {
        guard appState.activeRoomSurface == nil,
              let session = appState.activeChatSessionSummary else { return nil }
        return appState.nestingParent(of: session)
    }

    @ViewBuilder private var conversation: some View {
        if appState.activeRoomSurface != nil {
            // Keyed by room: another room starts with its own draft.
            GroupChatView()
                .id(appState.activeRoomSurface?.room.roomID)
                .environment(\.v2ComposerRests, true)
        } else {
            ChatView()
                .environment(\.v2ComposerRests, true)
        }
    }

    var body: some View {
        ZStack {
            // A Bot Chat glows in its bot's color, as its working line does;
            // a group room keeps the profile in use.
            V2Backdrop(glowProfile: appState.activeRoomSurface == nil ? appState.conversationIdentityProfile : nil)
            conversation
                .overlay(alignment: .bottomTrailing) {
                    if appState.activeRoomSurface == nil {
                        // Beside the resting composer; it slides aside,
                        // shrinks and fades while the composer is expanded.
                        V2VoiceButton(context: .conversation, isHidden: hidesVoiceButton)
                            .scaleEffect(hidesVoiceButton && !reduceMotion ? 0.4 : 1)
                            .offset(x: hidesVoiceButton && !reduceMotion ? 30 : 0)
                            .opacity(hidesVoiceButton ? 0 : 1)
                            .allowsHitTesting(!hidesVoiceButton)
                            .accessibilityHidden(hidesVoiceButton)
                            .padding(.trailing, 16)
                            .padding(.bottom, 10)
                            .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: hidesVoiceButton)
                    }
                }
                // On a wide window the transcript, the composer and the
                // voice button beside it keep to a readable column that
                // widens with the window; the backdrop still fills it.
                .readableContentWidth(scaling: ReadableWidth.chat(available:))
        }
        .modifier(V2FadingBarBackdrop())
        .onPreferenceChange(V2ComposerExpandedKey.self) { expanded in
            composerExpanded = expanded
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            // Beside the list on a wide window there is no Back: this
            // closes the chat, as Back does on a phone, and the column goes
            // back to offering a new one.
            if shell.isSplit {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.light()
                        appState.showSidebar = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 40, height: 40)
                            .modifier(V2PreGlassToolbarControl())
                    }
                    .accessibilityLabel(AppLocalization.string("Close"))
                    .accessibilityIdentifier("conversation.close")
                }
            }
            // A window wide enough for two columns: hide the list for the
            // whole width, or bring it back beside the chat (#1164).
            if shell.canSplit {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.light()
                        chatListBeside.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 40, height: 40)
                            .modifier(V2PreGlassToolbarControl())
                    }
                    // iPadOS's own sidebar shortcut. A tab kept behind the
                    // selected one still holds its chat, and a shortcut
                    // ignores opacity and hit testing: only the shown tab's.
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .disabled(!shell.isTabActive)
                    .accessibilityLabel(shell.isSplit ? AppLocalization.string("Hide chat list") : AppLocalization.string("Show chat list"))
                    .accessibilityIdentifier("conversation.chatListToggle")
                }
            }
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
                    .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.isRecoveringConnection)
                    .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.hidesBriefReconnect)
                }
            }
            // The big button does something else: a live call stays one
            // tap away up here.
            if appState.activeRoomSurface == nil,
               ChatVoiceButtonAction.resolved(profile: appState.chatVoiceButtonOverride, app: appChatVoiceButton) != .liveCall {
                ToolbarItem(placement: .topBarTrailing) {
                    V2VoiceButton(context: .conversation, style: .toolbar)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                V2ConversationMenu(
                    onRename: { chatTitlePendingRename = $0 },
                    onDelete: { chatTitlePendingDeletion = $0 },
                    onDisbandRoom: { confirmsRoomDisband = true },
                    onChooseRoomPicture: { choosesRoomPicture = $0 },
                    onArtifacts: { artifactSessionIDs = ArtifactSheetIDs(ids: appState.activeChatArtifactSessionIDs) }
                )
            }
        }
        .sheet(item: $artifactSessionIDs) { sheet in
            ChatArtifactsSheet(sessionIDs: sheet.ids)
                .environmentObject(appState)
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
        // On the screen, not the menu: a dialog raised as a menu closes
        // may never show.
        .modifier(GroupRoomPicturePicker(request: $choosesRoomPicture))
        .confirmationDialog(
            AppLocalization.string("Disband this group chat?"),
            isPresented: $confirmsRoomDisband,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Disband"), role: .destructive) {
                Task { await appState.disbandActiveRoom() }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string(
                "The room, its history, and every member's session end permanently. This cannot be undone."
            ))
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
/// header stays quiet when all is well. Coming back to the app, a
/// reconnect gets a few seconds to land before it shows (#296).
private struct V2ConnectionLine: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if !appState.isConnected, !appState.hidesBriefReconnect {
            let connecting = appState.isRecoveringConnection
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
    let onDisbandRoom: () -> Void
    let onChooseRoomPicture: (GroupRoomPictureRequest) -> Void
    let onArtifacts: () -> Void

    private var statusColor: Color {
        if appState.isConnected { return .green }
        return appState.isRecoveringConnection ? .orange : .red
    }

    private var statusWord: String {
        if appState.isConnected { return AppLocalization.string("Connected") }
        return appState.isRecoveringConnection ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Disconnected")
    }

    var body: some View {
        Menu {
            if appState.activeRoomSurface != nil {
                GroupRoomActionItems(onDisband: onDisbandRoom, onChoosePicture: onChooseRoomPicture)
            } else {
                Button {
                    Task { await appState.refreshActiveSession() }
                } label: {
                    Label(AppLocalization.string("Refresh conversation"), systemImage: "arrow.clockwise")
                }
                // A New Chat on its way has nothing to refresh yet.
                .disabled(!appState.isConnected || appState.isChatRefreshing || appState.showsPendingNewChat)
                Button(action: onArtifacts) {
                    Label(AppLocalization.string("Artifacts"), systemImage: "square.grid.2x2")
                }
                // A saved copy has no host to ask.
                .disabled(appState.activeChatArtifactSessionIDs.isEmpty)
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

/// The ids a chat's Artifacts sheet reads, as a sheet item.
private struct ArtifactSheetIDs: Identifiable {
    let id = UUID()
    let ids: [String]
}
