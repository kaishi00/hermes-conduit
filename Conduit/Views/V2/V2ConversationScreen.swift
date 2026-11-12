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
import os

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

/// A Bot Chat and its workstreams show in one pushed screen (the
/// conversation in the Bots stack), so going between them pushes nothing:
/// the screen slides the new chat in instead, a workstream from the
/// trailing edge and Back to its Bot Chat from the leading one.
enum BotChatSwap: Equatable {
    case forward
    case back

    struct Shown: Equatable {
        /// The bot whose Bot Chat shows, if one does.
        var botChat: String?
        /// The bot whose workstream shows, if one does.
        var workstreamOf: String?
    }

    static func direction(from old: Shown, to new: Shown) -> BotChatSwap? {
        if let bot = old.botChat ?? old.workstreamOf, same(bot, new.workstreamOf) { return .forward }
        if let bot = old.workstreamOf, same(bot, new.botChat) { return .back }
        return nil
    }

    /// A swipe toward the trailing edge, mostly sideways and far enough.
    static func isBackSwipe(_ translation: CGSize) -> Bool {
        translation.width > 80 && abs(translation.height) < translation.width * 0.6
    }

    private static func same(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}

struct V2ConversationScreen: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v2Shell) private var shell
    @State private var composerExpanded = false
    /// Someone is typing in the composer, which stays expanded on a wide
    /// window: the swipe back waits, so a caret dragged along a line stays.
    @State private var composerTyping = false
    /// The last resting bar's height: kept while the composer is expanded,
    /// so the button doesn't move as it steps aside.
    @State private var restingComposerHeight: CGFloat = 0
    @AppStorage(V2ChatListPreference.key) private var chatListBeside = V2ChatListPreference.defaultValue
    @AppStorage(ChatVoiceButtonAction.key) private var appChatVoiceButton = ChatVoiceButtonAction.defaultValue.rawValue
    /// A voice message recorded while the big button is held keeps the
    /// button under the finger, though the composer opens beside it.
    @ObservedObject private var voiceMessages = VoiceMessageRecorder.shared

    private var hidesVoiceButton: Bool { composerExpanded && !voiceMessages.isHeld }
    /// What the round button beside the composer does here.
    private var chatVoiceButtonAction: ChatVoiceButtonAction {
        ChatVoiceButtonAction.resolved(profile: appState.chatVoiceButtonOverride, app: appChatVoiceButton)
    }
    @State private var chatTitlePendingRename: SessionSummary?
    @State private var chatTitlePendingDeletion: SessionSummary?
    @State private var confirmsRoomDisband = false
    /// The ended room someone else hosts whose Delete, from the menu,
    /// waits for its confirmation.
    @State private var roomCopyPendingDelete: RoomCopy?
    @State private var showsRoomInfo = false
    @State private var choosesRoomPicture: GroupRoomPictureRequest?
    @State private var showsRoomSettings = false
    /// The open chat's ids while its Artifacts sheet shows.
    @State private var artifactSessionIDs: ArtifactSheetIDs?
    /// Edit Bot from a Bot Chat's ⋯ menu (Eric 2026-11-03).
    @State private var editedBot: BotEditorSheet.Mode?
    /// The bot's screen, opened from the menu (Bot Screen).
    @State private var screenTarget: BotScreenTarget?
    /// What a save from there couldn't do, said as the Bots list says it.
    @State private var editBotWarning: String?
    @State private var pendingEditBotWarning: String?
    /// Edit Bot tapped in the bot's overview: the editor opens once the
    /// overview has gone.
    @State private var editAfterOverview: BotProfile?
    /// Artifacts beside the chat, on a window wide enough for both.
    @AppStorage(ChatSidePanel.key) private var sidePanelOpen = false
    @AppStorage(ChatSidePanel.widths.key) private var storedSidePanelWidth = Double(ChatSidePanel.widths.standard)
    /// The panel's width while its line is dragged (`ColumnDivider`).
    @State private var draggedSidePanelWidth: CGFloat?
    @State private var sidePanelTab: ArtifactsTab = .made
    /// The chat's ids when the panel opened.
    @State private var sidePanelIDs: [String] = []
    @State private var screenWidth: CGFloat = 0
    /// Whether `screenWidth` stays put while a bot's screen in full screen
    /// has the iPhone turned: not for a screen that opened during it.
    @State private var holdsWidth = true
    /// The Bot Chat's Work panel: beside the chat on a window with room,
    /// else a sheet.
    @State private var workPanelOpen = false
    /// Which Bot Chat or workstream the screen showed last, so going from
    /// one to the other slides (`BotChatSwap`).
    @State private var shownChat = BotChatSwap.Shown()
    /// The chat sliding in, as a share of the column's width: 1 from the
    /// trailing edge (a workstream opening), -1 from the leading edge (Back
    /// to its Bot Chat).
    @State private var swapShift: CGFloat = 0
    /// This Bot Chat grew out of its portrait on Bots Home.
    @Environment(\.botChatZoomed) private var botChatZoomed
    @Environment(\.dismiss) private var dismiss

    /// The bot whose Work panel can open: the open Bot Chat's.
    private var workProfile: String? {
        appState.activeRoomSurface == nil && appState.servesBotWorkstreams ? appState.activeBotChatProfile : nil
    }
    private var showsWorkPanel: Bool {
        workPanelOpen && fitsSidePanel && workProfile != nil && appState.botChatComingOverAnother == nil
    }

    private var fitsSidePanel: Bool { ChatSidePanel.fits(width: screenWidth) }
    /// As wide as the user dragged it, less on a window without the room.
    private var sidePanelWidth: CGFloat {
        // A width dragged as the window narrows goes through the same bounds.
        ChatSidePanel.widths.resolved(draggedSidePanelWidth.map { Double($0) } ?? storedSidePanelWidth, window: screenWidth, keeping: V2SplitLayout.minimumChatWidth)
    }
    private var showsSidePanel: Bool {
        sidePanelOpen && fitsSidePanel && appState.activeRoomSurface == nil && !showsWorkPanel
            // The chat open before keeps its panels until the coming one lands.
            && appState.botChatComingOverAnother == nil
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
                    // Opened while a full screen holds the screens' widths
                    // (a push tapped as the phone turns back): this one
                    // never laid out in portrait, so it holds no width.
                    .onAppear {
                        screenWidth = proxy.size.width
                        holdsWidth = InterfaceOrientationGate.holdLeft == nil
                    }
                    // An iPhone turned sideways for a bot's screen in full
                    // screen keeps its Work panel where it was: moving it
                    // closed the screen opened from it.
                    .onChange(of: proxy.size.width) { _, width in
                        screenWidth = holdsWidth
                            ? InterfaceOrientationGate.layoutWidth(live: width, kept: screenWidth) : width
                    }
                    // Held: the window's width once the hold ends.
                    .task(id: proxy.size.width) {
                        let live = proxy.size.width
                        guard (live != screenWidth && screenWidth > 0) || !holdsWidth else { return }
                        await InterfaceOrientationGate.layoutReleased()
                        guard !Task.isCancelled else { return }
                        screenWidth = InterfaceOrientationGate.layoutWidth(live: live, kept: screenWidth)
                        holdsWidth = true
                    }
                    // The chat open before's Work closes under a Bot Chat
                    // on its way, and doesn't come back over the one that
                    // lands. (Here, off the screen's long modifier chain.)
                    .onChange(of: appState.botChatComingOverAnother) { _, coming in
                        if coming != nil { workPanelOpen = false }
                    }
            }
        }
        // A file path tapped in a reply: the Folder tab beside the chat, or
        // in the chat's Artifacts sheet on a phone. The tab takes the path.
        .onChange(of: appState.workspaceReveal?.id) { _, id in
            guard id != nil, appState.activeRoomSurface == nil else { return }
            openArtifacts(tab: .folder)
        }
        .onAppear {
            // The other end of the shell's "Chat pushed" marker. It is the
            // screen being on screen, not its first painted frame; the
            // Animation Hitches track says whether that frame came late.
            ResponsivenessSignposts.signposter.emitEvent("Conversation appeared")
            sidePanelIDs = appState.activeChatArtifactSessionIDs
            shownChat = currentShownChat
        }
        .onChange(of: appState.activeSessionId) { _, _ in
            sidePanelIDs = appState.activeChatArtifactSessionIDs
            let shown = currentShownChat
            if !shell.isSplit, !reduceMotion, let swap = BotChatSwap.direction(from: shownChat, to: shown) {
                slideIn(swap)
            }
            shownChat = shown
            // A workstream opened from the panel shows its own chat, and
            // the Bot Chat opens again without it, on any window.
            workPanelOpen = false
        }
        .onPreferenceChange(V2ComposerExpandedKey.self) { expanded in
            composerExpanded = expanded
        }
        .onPreferenceChange(V2ComposerTypingKey.self) { typing in
            composerTyping = typing
        }
        .onPreferenceChange(V2RestingComposerHeightKey.self) { height in
            if height > 0 { restingComposerHeight = height }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // A workstream's chat goes back to the Bot Chat that started it,
        // by Back and by the edge swipe, not to the list under both.
        .navigationBarBackButtonHidden(workstreamGoesBack != nil)
        // Hiding Back doesn't stop the system's own swipes off the screen:
        // a Bot Chat's zoom from its portrait (a slow swipe went to Bots
        // Home, a quick one to the Bot Chat), and iOS 26's swipe from
        // anywhere. Only `backSwipe` goes back from a workstream.
        .background { SystemBackSwipeGate(blocked: workstreamGoesBack != nil) }
        // A swipe back let go can leave the list's hidden bar over the
        // chat (a Bot Chat or room grown from its portrait, Eric
        // 2026-11-06): the chat's title, Back and ⋯ come back.
        .background { NavigationBarKeeper() }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { toolbarItems }
        // The bot's overview and Edit Bot cover the chat too, and a room's
        // settings, info, picture picker and disband prompt cover the room
        // (issue 2064).
        .onChange(of: screenTarget != nil || artifactSessionIDs != nil || chatTitlePendingRename != nil
                  || chatTitlePendingDeletion != nil || editedBot != nil
                  || (workPanelOpen && !fitsSidePanel && workProfile != nil)
                  || showsRoomSettings || showsRoomInfo || confirmsRoomDisband || roomCopyPendingDelete != nil
                  || choosesRoomPicture != nil) { _, covered in
            appState.chatCoveredBySheet = covered
            // What came in under the sheet is read once it closes (#1579).
            if !covered { appState.clearShownChatNotifications() }
        }
        .onDisappear { appState.chatCoveredBySheet = false }
        .sheet(isPresented: Binding(
            // The chat open before's Work closes under a Bot Chat on its way.
            get: { workPanelOpen && !fitsSidePanel && workProfile != nil && appState.botChatComingOverAnother == nil },
            set: { if !$0 { workPanelOpen = false } }
        ), onDismiss: {
            if let bot = editAfterOverview {
                editAfterOverview = nil
                editedBot = .edit(bot)
            }
        }) {
            if let workProfile {
                // On a phone, the bot's overview: the same Work list, its
                // artifacts, and Chat, which is this chat.
                BotOverviewSheet(
                    work: appState.botWork,
                    profile: workProfile,
                    onEdit: appState.botModePhase == .available && appState.isConnected
                        ? { (bot: BotProfile) in
                            editAfterOverview = bot
                            workPanelOpen = false
                        } : nil,
                    onChat: { workPanelOpen = false },
                    onClose: { workPanelOpen = false }
                )
                .environmentObject(appState)
            }
        }
        .sheet(item: $screenTarget) { target in
            BotScreenSheet(target: target)
                .environmentObject(appState)
        }
        .sheet(item: $artifactSessionIDs) { sheet in
            ChatArtifactsSheet(sessionIDs: sheet.ids, tab: sheet.tab) { artifactSessionIDs?.tab = $0 }
                .environmentObject(appState)
        }
        .sheet(item: $editedBot, onDismiss: {
            // Shown once the sheet is gone: an alert can't come up over it.
            editBotWarning = pendingEditBotWarning
            pendingEditBotWarning = nil
        }) { mode in
            // Editing makes no new chat: nothing to open when it closes.
            BotEditorSheet(mode: mode) { _, warning, _ in pendingEditBotWarning = warning }
                .environmentObject(appState)
        }
        .alert(AppLocalization.string("Edit Bot"), isPresented: Binding(
            get: { editBotWarning != nil }, set: { if !$0 { editBotWarning = nil } }
        )) {
            Button(AppLocalization.string("OK"), role: .cancel) { editBotWarning = nil }
        } message: {
            Text(verbatim: editBotWarning ?? "")
        }
        .modifier(ConversationDialogs(
            chatTitlePendingRename: $chatTitlePendingRename,
            chatTitlePendingDeletion: $chatTitlePendingDeletion,
            confirmsRoomDisband: $confirmsRoomDisband,
            roomCopyPendingDelete: $roomCopyPendingDelete,
            choosesRoomPicture: $choosesRoomPicture,
            showsRoomSettings: $showsRoomSettings,
            showsRoomInfo: $showsRoomInfo
        ))
        // Group Settings asked for from a room's tile on Bots Home: once
        // that room is open here and Hermes has read its settings.
        .onChange(of: roomSettingsKey, initial: true) { _, _ in showRequestedRoomSettings() }
    }

    private var roomSettingsKey: String {
        "\(appState.activeRoomSurface?.room.roomID ?? "")|\(appState.canEditActiveRoomSettings)|\(appState.groupSettingsOnOpen.map { "\($0.roomID)@\($0.at.timeIntervalSinceReferenceDate)" } ?? "")|\(shell.isTabActive)"
    }

    private func showRequestedRoomSettings() {
        guard let request = appState.groupSettingsOnOpen, shell.isTabActive,
              request.shows(openRoomID: appState.activeRoomSurface?.room.roomID,
                            canEdit: appState.canEditActiveRoomSettings) else { return }
        appState.groupSettingsOnOpen = nil
        showsRoomSettings = true
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
                // The bar over a workstream's own chat while it needs a
                // tap (Bot workstreams); a Bot Chat's work shows under
                // its title.
                .safeAreaInset(edge: .top, spacing: 0) {
                    if appState.activeRoomSurface == nil, appState.servesBotWorkstreams {
                        BotWorkHeader(work: appState.botWork)
                    }
                }
                // A Bot Chat and its workstreams share this screen: one
                // slides in over the other as a push or a pop would.
                .offset(x: swapShift * chatColumnWidth)
                .opacity(1 - Double(abs(swapShift)) * 0.6)
                .overlay(alignment: .bottomTrailing) {
                    // On a Mac, not when all it would do is the call the
                    // header has (issue 1534).
                    if appState.activeRoomSurface == nil, ChatVoiceButtonAction.roundButtonBeside(chatVoiceButtonAction) {
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
                // Under the cover, VoiceOver doesn't reach it either.
                .accessibilityHidden(appState.botChatComingOverAnother != nil)
            // A Bot Chat tapped in Bots is pushed before its open lands:
            // the chat open before, another bot's, stays under a cover
            // until then, and is never shown as the tapped bot's.
            if appState.botChatComingOverAnother != nil {
                BotChatComingCover(bot: appState.botChatOnItsWay?.bot)
                    .transition(.opacity)
            }
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.botChatComingOverAnother)
        // The chat's column only: a drag in a panel beside it (Artifacts,
        // its divider, the Work panel's swipes) is that panel's.
        .simultaneousGesture(backSwipe, including: swipesBack ? .all : .subviews)
    }

    /// The bot whose Bot Chat a workstream's Back returns to; nil for any
    /// other chat, a room shown over the workstream (its Back leaves the
    /// room), or beside the list on a wide window, which has no Back.
    private var workstreamGoesBack: String? {
        // Under a Bot Chat on its way, Back is the list's: it stands that
        // open down, rather than open the hidden workstream's Bot Chat.
        guard !shell.isSplit, appState.activeRoomSurface == nil,
              appState.botChatComingOverAnother == nil else { return nil }
        return appState.activeWorkstream?.profile
    }

    private func backToCoordinator() {
        guard let profile = workstreamGoesBack else { return }
        Haptics.light()
        appState.openCoordinator(profile: profile)
    }

    /// A Bot Chat or a room grown from its portrait goes home by a swipe from
    /// anywhere, as a session's chat does: the zoom's own swipe starts only
    /// where the transcript has no text. A workstream's chat goes to its Bot
    /// Chat by this swipe alone, slow or quick: `SystemBackSwipeGate` holds
    /// the system's and the zoom's swipes back there.
    /// Not while the composer is in use (a caret or selection dragged
    /// along a line) or a held voice message slides to cancel.
    private var swipesBack: Bool {
        guard !composerExpanded, !composerTyping, !voiceMessages.isActive else { return false }
        return workstreamGoesBack != nil || (botChatZoomed && !shell.isSplit
            && (appState.activeBotChatProfile != nil || appState.activeRoomSurface != nil))
    }

    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { drag in
            // Nor while text in the chat is selected: a handle dragged
            // toward the trailing edge read as this swipe, and the chat
            // closed under the finger (issue 1948). Asked as the drag ends,
            // since a selection doesn't redraw the screen.
            guard swipesBack, BotChatSwap.isBackSwipe(drag.translation),
                  !ChatTextSelection.isShowing else { return }
            if workstreamGoesBack != nil {
                backToCoordinator()
            } else {
                dismiss()
            }
        }
    }

    private var currentShownChat: BotChatSwap.Shown {
        BotChatSwap.Shown(botChat: appState.activeBotChatProfile, workstreamOf: appState.activeWorkstream?.profile)
    }

    /// The new chat starts off to one side, then slides into place.
    private func slideIn(_ swap: BotChatSwap) {
        var start = Transaction()
        start.disablesAnimations = true
        withTransaction(start) { swapShift = swap == .forward ? 1 : -1 }
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.32)) { swapShift = 0 }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        if workstreamGoesBack != nil {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: backToCoordinator) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 40, height: 40)
                        .modifier(V2PreGlassToolbarControl())
                }
                .accessibilityLabel(AppLocalization.string("Back"))
                .accessibilityIdentifier("workstream.backButton")
            }
        }
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
                    // Its shortcut, too, does nothing behind a sheet.
                    guard KeyboardCommands.nothingInFront else { return }
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
                .keyboardShortcut(ConduitKeyboardShortcut.chatList.shortcut)
                .disabled(!shell.chatTakesKeys)
                .accessibilityLabel(shell.isSplit ? AppLocalization.string("Hide chat list") : AppLocalization.string("Show chat list"))
                .accessibilityIdentifier("conversation.chatListToggle")
            }
        }
        // A Bot Chat on its way names its bot; the chat under the cover
        // keeps its title and actions to itself.
        if let coming = appState.botChatComingOverAnother {
            ToolbarItem(placement: .principal) {
                Text(coming)
                    .scaledFont(.headline)
                    .lineLimit(1)
            }
        }
        // Session-only controls: an open room owns the title and actions.
        if appState.activeRoomSurface == nil, appState.botChatComingOverAnother == nil {
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
                    // A Bot Chat's work, or whose work a workstream is.
                    if appState.servesBotWorkstreams {
                        BotWorkTitleStatus(work: appState.botWork, isPanelOpen: workPanelOpen) {
                            workPanelOpen.toggle()
                            // One column beside the chat: the Work panel
                            // takes Artifacts'.
                            if workPanelOpen, fitsSidePanel { sidePanelOpen = false }
                        }
                    }
                    V2ConnectionLine()
                }
                .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.isConnected)
                .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.isRecoveringConnection)
                .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: appState.hidesBriefReconnect)
            }
        }
        // The big button does something else: a live call stays one
        // tap away up here. On a Mac the call is always up here, where a
        // desktop client has it, and shows a minimised call in gold
        // (issue 1534).
        if appState.activeRoomSurface == nil, appState.botChatComingOverAnother == nil,
           ChatVoiceButtonAction.headerCallButton(chatVoiceButtonAction) {
            ToolbarItem(placement: .topBarTrailing) {
                V2VoiceButton(context: .conversation, style: .toolbar)
            }
        }
        if appState.botChatComingOverAnother == nil {
            ToolbarItem(placement: .topBarTrailing) {
                V2ConversationMenu(
                    onRename: { chatTitlePendingRename = $0 },
                    onDelete: { chatTitlePendingDeletion = $0 },
                    onShowRoomInfo: { showsRoomInfo = true },
                    onDisbandRoom: { confirmsRoomDisband = true },
                    onDeleteRoomCopy: { roomCopyPendingDelete = $0 },
                    onChooseRoomPicture: { choosesRoomPicture = $0 },
                    onRoomSettings: { showsRoomSettings = true },
                    onArtifacts: { openArtifacts(tab: .made) },
                    onEditBot: { editedBot = .edit($0) },
                    onScreen: { screenTarget = $0 },
                    screens: appState.botScreens
                )
            }
        }
        // Artifacts beside the chat, on a window with room for both.
        if fitsSidePanel, appState.activeRoomSurface == nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard KeyboardCommands.nothingInFront else { return }
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
                .keyboardShortcut(ConduitKeyboardShortcut.artifacts.shortcut)
                // The cover hides the panel: it waits for the coming chat.
                .disabled(!shell.chatTakesKeys || appState.botChatComingOverAnother != nil)
                .accessibilityLabel(showsSidePanel ? AppLocalization.string("Hide artifacts") : AppLocalization.string("Show artifacts"))
                .accessibilityIdentifier("conversation.sidePanelToggle")
            }
        }
    }
}

/// The conversation's rename sheet, delete alert, room picture picker, room
/// settings and info, and its disband or (hosted elsewhere) delete
/// confirmation.
private struct ConversationDialogs: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Binding var chatTitlePendingRename: SessionSummary?
    @Binding var chatTitlePendingDeletion: SessionSummary?
    @Binding var confirmsRoomDisband: Bool
    @Binding var roomCopyPendingDelete: RoomCopy?
    @Binding var choosesRoomPicture: GroupRoomPictureRequest?
    @Binding var showsRoomSettings: Bool
    @Binding var showsRoomInfo: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsRoomSettings) {
                GroupRoomSettingsSheet()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showsRoomInfo) {
                GroupRoomInfoSheet()
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
                Text(GroupRoomDisband.warning(members: appState.activeRoomSurface?.room.members ?? []))
            }
            .modifier(RoomCopyDelete(copy: roomCopyPendingDelete, confirming: Binding(
                get: { roomCopyPendingDelete != nil },
                set: { if !$0 { roomCopyPendingDelete = nil } }
            )))
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
/// reconnect gets a few seconds to land before it shows, until a message
/// waits for it (#296, #1624).
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
    let onShowRoomInfo: () -> Void
    let onDisbandRoom: () -> Void
    let onDeleteRoomCopy: (RoomCopy) -> Void
    let onChooseRoomPicture: (GroupRoomPictureRequest) -> Void
    let onRoomSettings: () -> Void
    let onArtifacts: () -> Void
    let onEditBot: (BotProfile) -> Void
    let onScreen: (BotScreenTarget) -> Void
    @ObservedObject var screens: BotScreenSupport

    /// The bot whose screen this chat can open, once its host said it can
    /// have one: a Bot Chat's or a workstream's bot, else the profile an
    /// ordinary chat runs under (issue 2132). Not a room's (its bots may be
    /// another host's) or a saved copy's (no host to ask).
    private var screenProfile: String? {
        BotScreenUse.menuProfile(
            inRoom: appState.activeRoomSurface != nil,
            botChatProfile: appState.activeBotChatProfile,
            workstreamProfile: appState.activeWorkstream?.profile,
            savedCopy: appState.offlineChatPresentation != nil,
            sessionID: appState.activeSessionId,
            rowProfile: appState.activeChatSessionSummary?.profile,
            activeProfile: appState.activeProfile
        )
    }

    /// The bot whose chat this is, once the roster has it.
    private var chatBot: BotProfile? {
        guard let profile = appState.activeBotChatProfile else { return nil }
        return appState.botRoster.first { $0.name == profile }
    }

    /// The dot stays a neutral grey while a reconnect back in the app is
    /// still kept quiet, as the line under the title does: calm, without
    /// claiming Connected. The menu's own words say what is happening to
    /// anyone who opens it (#1624).
    private var statusColor: Color {
        if appState.isConnected { return .green }
        if appState.hidesBriefReconnect { return .secondary }
        return appState.isRecoveringConnection ? .orange : .red
    }

    private var statusWord: String {
        if appState.isConnected { return AppLocalization.string("Connected") }
        return appState.isRecoveringConnection ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Disconnected")
    }

    var body: some View {
        Menu {
            if appState.activeRoomSurface != nil {
                GroupRoomActionItems(
                    onShowInfo: onShowRoomInfo,
                    onDisband: onDisbandRoom, onChoosePicture: onChooseRoomPicture, onOpenSettings: onRoomSettings,
                    onDeleteCopy: onDeleteRoomCopy
                )
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
                if let bot = chatBot {
                    Button { onEditBot(bot) } label: {
                        Label(AppLocalization.string("Edit Bot"), systemImage: "pencil")
                    }
                    // As the Bots list's Edit Bot: Hermes answers its reads and saves.
                    .disabled(appState.botModePhase != .available || !appState.isConnected)
                }
                if let profile = screenProfile, screens.isSupported(profile) {
                    Button {
                        onScreen(BotScreenTarget(profile: profile,
                                                 botName: appState.botWork.snapshot(profile)?.botName
                                                     ?? appState.profileDisplayName(profile),
                                                 chatSessionIDs: appState.activeSessionId.map { appState.chatOwnSessionIDs(for: $0) } ?? []))
                    } label: {
                        Label(AppLocalization.string("Bot's Screen"), systemImage: "display")
                    }
                    .disabled(!appState.isConnected)
                }
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
        // Asks the bot's host once whether it can have a screen, so the
        // entry shows only where it can (never on Windows or macOS hosts).
        .task(id: "\(screenProfile ?? "")\u{1F}\(appState.isConnected)") {
            if let profile = screenProfile, appState.isConnected {
                screens.check(profile, client: appState.client)
            }
        }
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

/// A Bot Chat's screen while its open is out and the active chat is still
/// the one open before (`AppState.botChatComingOverAnother`): the bot's
/// backdrop and that it's opening. It takes the taps, so nothing reaches
/// the chat under it.
private struct BotChatComingCover: View {
    let bot: String?

    var body: some View {
        ZStack(alignment: .top) {
            V2Backdrop(glowProfile: bot)
            ProgressView("Opening conversation…")
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 60)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
