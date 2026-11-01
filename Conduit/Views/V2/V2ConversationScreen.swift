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

/// The resting composer bar's height (0 while it is expanded), so the voice
/// button beside it stays centred on it when the bar grows past the
/// button: a placeholder that wraps (a long translation), a large Text Size.
struct V2RestingComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Whether someone is typing in a resting composer (it has focus; on a Mac
/// or an iPad's keyboard, words too, since the field keeps focus
/// after a send), so the minimised call bar steps aside. Only typing hides it:
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
    /// The last resting bar's height: kept while the composer is expanded,
    /// so the button doesn't move as it steps aside.
    @State private var restingComposerHeight: CGFloat = 0
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
    /// Artifacts beside the chat, on a window wide enough for both.
    @AppStorage(ChatSidePanel.key) private var sidePanelOpen = false
    @AppStorage(ChatSidePanel.widths.key) private var storedSidePanelWidth = Double(ChatSidePanel.widths.standard)
    /// The panel's width while its line is dragged (`ColumnDivider`).
    @State private var draggedSidePanelWidth: CGFloat?
    @State private var sidePanelTab: ArtifactsTab = .made
    /// The chat's ids when the panel opened.
    @State private var sidePanelIDs: [String] = []
    @State private var screenWidth: CGFloat = 0
    /// The Bot Chat's Work panel: beside the chat on a window with room,
    /// else a sheet.
    @State private var workPanelOpen = false

    /// The bot whose Work panel can open: the open Bot Chat's.
    private var workProfile: String? {
        appState.activeRoomSurface == nil && appState.servesBotWorkstreams ? appState.activeBotChatProfile : nil
    }
    private var showsWorkPanel: Bool { workPanelOpen && fitsSidePanel && workProfile != nil }

    private var fitsSidePanel: Bool { ChatSidePanel.fits(width: screenWidth) }
    /// As wide as the user dragged it, less on a window without the room.
    private var sidePanelWidth: CGFloat {
        // A width dragged as the window narrows goes through the same bounds.
        ChatSidePanel.widths.resolved(draggedSidePanelWidth.map { Double($0) } ?? storedSidePanelWidth, window: screenWidth, keeping: V2SplitLayout.minimumChatWidth)
    }
    private var showsSidePanel: Bool {
        sidePanelOpen && fitsSidePanel && appState.activeRoomSurface == nil && !showsWorkPanel
    }

    private var parent: SessionSummary? {
        guard appState.activeRoomSurface == nil,
              let session = appState.activeChatSessionSummary else { return nil }
        return appState.nestingParent(of: session)
    }

    /// The chat column's width, beside Artifacts when they show.
    private var chatColumnWidth: CGFloat {
        showsSidePanel || showsWorkPanel ? screenWidth - sidePanelWidth - 1 : screenWidth
    }

    /// Expanded on a Mac and on an iPad with the room, so the voice button
    /// stays beside it; resting on an iPhone (#1483).
    private var composerStaysExpanded: Bool {
        ComposerLayout.staysExpanded(width: chatColumnWidth)
    }

    @ViewBuilder private var conversation: some View {
        if appState.activeRoomSurface != nil {
            // Keyed by room: another room starts with its own draft.
            GroupChatView()
                .id(appState.activeRoomSurface?.room.roomID)
                .environment(\.v2ComposerRests, true)
                .environment(\.composerStaysExpanded, composerStaysExpanded)
        } else {
            ChatView()
                .environment(\.v2ComposerRests, true)
                .environment(\.composerStaysExpanded, composerStaysExpanded)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            chatColumn
            if showsSidePanel {
                // Drags the panel's width (#1487).
                ColumnDivider(
                    widths: ChatSidePanel.widths,
                    width: sidePanelWidth,
                    room: screenWidth - V2SplitLayout.minimumChatWidth - 1,
                    columnEdge: .trailing,
                    label: AppLocalization.string("Artifacts width"),
                    stored: $storedSidePanelWidth,
                    live: $draggedSidePanelWidth
                )
                ChatSidePanel(sessionIDs: sidePanelIDs, tab: $sidePanelTab) {
                    sidePanelOpen = false
                }
                .frame(width: sidePanelWidth)
                .transition(.move(edge: .trailing))
            }
            if showsWorkPanel, let workProfile {
                Divider()
                BotWorkPanel(work: appState.botWork, profile: workProfile) {
                    workPanelOpen = false
                }
                .frame(width: sidePanelWidth)
                .transition(.move(edge: .trailing))
            }
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: showsSidePanel)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: showsWorkPanel)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { screenWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in screenWidth = width }
            }
        }
        // A file path tapped in a reply: the Folder tab beside the chat, or
        // in the chat's Artifacts sheet on a phone. The tab takes the path.
        .onChange(of: appState.workspaceReveal?.id) { _, id in
            guard id != nil, appState.activeRoomSurface == nil else { return }
            openArtifacts(tab: .folder)
        }
        .onAppear { sidePanelIDs = appState.activeChatArtifactSessionIDs }
        .onChange(of: appState.activeSessionId) { _, _ in
            sidePanelIDs = appState.activeChatArtifactSessionIDs
            // A workstream opened from the panel shows its own chat, and
            // the Bot Chat opens again without it, on any window.
            workPanelOpen = false
        }
        .onPreferenceChange(V2ComposerExpandedKey.self) { expanded in
            composerExpanded = expanded
        }
        .onPreferenceChange(V2RestingComposerHeightKey.self) { height in
            if height > 0 { restingComposerHeight = height }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbarItems }
        .onChange(of: artifactSessionIDs != nil || chatTitlePendingRename != nil
                  || chatTitlePendingDeletion != nil) { _, covered in
            appState.chatCoveredBySheet = covered
            // What came in under the sheet is read once it closes (#1579).
            if !covered { appState.clearShownChatNotifications() }
        }
        .onDisappear { appState.chatCoveredBySheet = false }
        .sheet(isPresented: Binding(
            get: { workPanelOpen && !fitsSidePanel && workProfile != nil },
            set: { if !$0 { workPanelOpen = false } }
        )) {
            if let workProfile {
                BotWorkPanel(work: appState.botWork, profile: workProfile) {
                    workPanelOpen = false
                }
                .presentationDetents([.medium, .large])
                .environmentObject(appState)
            }
        }
        .sheet(item: $artifactSessionIDs) { sheet in
            ChatArtifactsSheet(sessionIDs: sheet.ids, tab: sheet.tab) { artifactSessionIDs?.tab = $0 }
                .environmentObject(appState)
        }
        .modifier(ConversationDialogs(
            chatTitlePendingRename: $chatTitlePendingRename,
            chatTitlePendingDeletion: $chatTitlePendingDeletion,
            confirmsRoomDisband: $confirmsRoomDisband,
            choosesRoomPicture: $choosesRoomPicture
        ))
    }

    /// The chat's ⋯ › Artifacts, or a tapped file path: beside the chat
    /// when the window has room, else the sheet.
    private func openArtifacts(tab: ArtifactsTab) {
        let ids = appState.activeChatArtifactSessionIDs
        if fitsSidePanel {
            sidePanelIDs = ids
            sidePanelTab = tab
            sidePanelOpen = true
            // One column beside the chat: Artifacts take the Work panel's.
            workPanelOpen = false
        } else if artifactSessionIDs?.tab != tab || tab == .made {
            // An open sheet on the other tab comes back on this one, where
            // its Folder takes the tapped path.
            artifactSessionIDs = ArtifactSheetIDs(ids: ids, tab: tab)
        }
    }

    /// The composer's own bottom padding, plus half of what the resting bar
    /// stands taller than the button, so the two share a centre line. Beside
    /// a composer that stays expanded, the button sits level with its
    /// bottom, by the controls row, however tall the draft grows.
    static func voiceButtonBottomPadding(restingComposerHeight: CGFloat, composerStaysExpanded: Bool = false) -> CGFloat {
        guard !composerStaysExpanded else { return 10 }
        return 10 + max(0, (restingComposerHeight - V2VoiceButton.diameter) / 2)
    }

    private var chatColumn: some View {
        ZStack {
            // A Bot Chat glows in its bot's color, as its working line does;
            // a group room keeps the profile in use.
            V2Backdrop(glowProfile: appState.activeRoomSurface == nil ? appState.conversationIdentityProfile : nil)
            conversation
                // A Bot Chat's Work strip, or the bar over a workstream's
                // own chat (Bot workstreams).
                .safeAreaInset(edge: .top, spacing: 0) {
                    if appState.activeRoomSurface == nil, appState.servesBotWorkstreams {
                        BotWorkHeader(work: appState.botWork, isPanelOpen: workPanelOpen) {
                            workPanelOpen.toggle()
                            // One column beside the chat: the Work panel
                            // takes Artifacts'.
                            if workPanelOpen, fitsSidePanel { sidePanelOpen = false }
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if appState.activeRoomSurface == nil {
                        // Beside the resting composer; it slides aside,
                        // shrinks and fades while the composer is expanded
                        // for use. One that stays expanded keeps it.
                        V2VoiceButton(context: .conversation, isHidden: hidesVoiceButton)
                            .scaleEffect(hidesVoiceButton && !reduceMotion ? 0.4 : 1)
                            .offset(x: hidesVoiceButton && !reduceMotion ? 30 : 0)
                            .opacity(hidesVoiceButton ? 0 : 1)
                            .allowsHitTesting(!hidesVoiceButton)
                            .accessibilityHidden(hidesVoiceButton)
                            .padding(.trailing, 16)
                            .padding(.bottom, Self.voiceButtonBottomPadding(restingComposerHeight: restingComposerHeight, composerStaysExpanded: composerStaysExpanded))
                            .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: hidesVoiceButton)
                    }
                }
                // On a wide window the transcript, the composer and the
                // voice button beside it keep to a readable column that
                // widens with the window, its text a size or more larger as
                // it does; the backdrop still fills it.
                .readableChatColumn()
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
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
                                    .scaledFont(.caption2.weight(.bold))
                                Text(parent.title)
                                    .scaledFont(.caption.weight(.semibold))
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
                onArtifacts: { openArtifacts(tab: .made) }
            )
        }
        // Artifacts beside the chat, on a window with room for both.
        if fitsSidePanel, appState.activeRoomSurface == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.light()
                    if showsSidePanel {
                        sidePanelOpen = false
                    } else {
                        openArtifacts(tab: sidePanelTab)
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(showsSidePanel ? Color.conduitAccent : Color.primary)
                        .frame(width: 40, height: 40)
                        .modifier(V2PreGlassToolbarControl())
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!shell.isTabActive)
                .accessibilityLabel(showsSidePanel ? AppLocalization.string("Hide artifacts") : AppLocalization.string("Show artifacts"))
                .accessibilityIdentifier("conversation.sidePanelToggle")
            }
        }
    }
}

/// The conversation's rename sheet, delete alert, room picture picker and
/// disband confirmation.
private struct ConversationDialogs: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Binding var chatTitlePendingRename: SessionSummary?
    @Binding var chatTitlePendingDeletion: SessionSummary?
    @Binding var confirmsRoomDisband: Bool
    @Binding var choosesRoomPicture: GroupRoomPictureRequest?

    func body(content: Content) -> some View {
        content
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

/// Artifacts beside the chat on a wide window (#1389): the chat's own
/// files and its Folder, as the ⋯ › Artifacts sheet shows them on a phone.
struct ChatSidePanel: View {
    static let key = "chatSidePanelOpen"
    /// The panel's widths as the user drags it (#1487). It shows on a
    /// window with room for its standard width, as before the drag, and a
    /// window too small for the user's gets less.
    static let widths = ColumnWidth(key: "conduit.chatSidePanelWidth", standard: 340, minimum: 300, maximum: 720)

    /// Whether a window this wide keeps a readable chat beside the panel.
    static func fits(width: CGFloat) -> Bool {
        width >= V2SplitLayout.minimumChatWidth + widths.standard + 1
    }

    @EnvironmentObject private var appState: AppState
    let sessionIDs: [String]
    @Binding var tab: ArtifactsTab
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Artifacts")
                    .scaledFont(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    Haptics.light()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Hide artifacts"))
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 8)
            ChatArtifactsContent(sessionIDs: sessionIDs, tab: $tab, inPanel: true) { item in
                appState.showArtifactInChat(item, chatIsOpen: true)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
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
                    .scaledFont(.caption2.weight(.bold))
                Text(connecting ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Disconnected"))
                    .scaledFont(.caption.weight(.semibold))
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
    var tab: ArtifactsTab = .made
}
