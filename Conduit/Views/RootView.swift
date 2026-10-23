//
//  RootView.swift
//  Conduit
//
//  Root container — handles auth state and scene phase changes.
//

import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isPrimaryWindow = false

    var body: some View {
        ZStack {
            // A cold launch that could not reach the server yet still shows
            // the app shell over the read-only saved copy (#99).
            if appState.showLogin
                || (appState.connection == nil && appState.offlineChatPresentation == nil) {
                LoginView()
                    .transition(.opacity)
            } else {
                MainView()
                    .transition(.opacity)
            }

            if let bridge = appState.dashboardTicketBridge {
                DashboardTicketBridgeView(bridge: bridge)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.showLogin)
        // A sign-in code link asks here, above both the sign-in screen and
        // the app, so it survives the sign-in screen giving way to the app
        // while a saved dashboard connects at launch.
        .sheet(item: $appState.pendingConnectLink) { link in
            ConnectLinkSheet(link: link)
                .environmentObject(appState)
        }
        // A draft shared from another app before Conduit listed any chats,
        // with more than one dashboard it could be for (#812). An alert, so
        // it shows the same on iPad, where a dialog would need an anchor.
        .alert(
            Text("Which dashboard is this draft for?"),
            isPresented: Binding(
                get: { appState.sharedDraftChoice != nil },
                set: { presented in
                    if !presented, let choice = appState.sharedDraftChoice { appState.postponeSharedDraftChoice(choice) }
                }
            ),
            presenting: appState.sharedDraftChoice
        ) { choice in
            ForEach(choice.dashboards) { dashboard in
                Button {
                    appState.chooseDashboardForSharedDraft(dashboard.id, for: choice)
                } label: {
                    Text(verbatim: dashboard.label)
                }
            }
            Button(role: .destructive) {
                appState.discardSharedDraft(choice)
            } label: {
                Text("Discard Draft")
            }
            Button(role: .cancel) {
                appState.postponeSharedDraftChoice(choice)
            } label: {
                Text("Not Now")
            }
        } message: { _ in
            Text("Conduit didn't have your chats yet when you shared this. It opens in a new chat, and nothing is sent until you send it.")
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Only the primary window drives the process-wide lifecycle: a
            // transient duplicate window's .background must never suspend a
            // conversation the primary window still presents.
            if isPrimaryWindow {
                appState.handleScenePhase(newPhase)
            }
        }
        .onAppear {
            guard !isPrimaryWindow else { return }
            // Multi-scene support exists for the CarPlay scene; a SECOND
            // foreground Conduit window is not a supported surface and
            // closes itself (the primary window releases its claim on close).
            if ConduitWindowClaimKeeper.claimPrimaryWindow() {
                isPrimaryWindow = true
                appState.startWakeListeningLifecycle()
            } else {
                // Environment-scoped dismissal: close THIS duplicate window
                // only. ID-scoped dismissal targets the WindowGroup and
                // would take the primary window down with it.
                dismissWindow()
            }
        }
        .onDisappear {
            if isPrimaryWindow {
                ConduitWindowClaimKeeper.releaseClaim()
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("conduit.ipadPersistentSidebar") private var prefersPersistentSidebar = false
    /// Conduit V2's tab shell (V2Shell.swift). Off brings back the drawer
    /// shell, the fallback while V2 is on its branch.
    @AppStorage(V2ShellPreference.key) private var useV2Shell = V2ShellPreference.defaultValue
    @AppStorage(VoiceScreenAwake.preferenceKey) private var keepScreenAwake = false
    @State private var availableWindowWidth: CGFloat = 0
    @State private var settingsPresentation: SettingsSnapshot?
    @State private var shouldPresentSettingsAfterSidebarDismissal = false
    /// The page Settings opens at next, for an in-app settings link.
    @State private var settingsOpensAt: ConduitAppLink.SettingsLink?
    @State private var chatTitlePendingRename: SessionSummary?
    @State private var chatTitlePendingDeletion: SessionSummary?

    private var sidebarPresentation: SidebarPresentation {
        SidebarLayoutPolicy.resolvePresentation(
            idiom: UIDevice.current.userInterfaceIdiom,
            prefersPersistentSidebar: prefersPersistentSidebar,
            availableWidth: availableWindowWidth
        )
    }

    private var isPersistentSidebarActive: Bool { !useV2Shell && sidebarPresentation == .persistent }

    private var isVoiceConversationShown: Bool {
        appState.showVoiceSheet || appState.showGeminiLiveSheet || appState.showGPTLiveSheet
            || appState.showGrokLiveSheet || appState.showLocalLiveSheet
    }

    var body: some View {
        sidebarLayoutContent
        // Changes Hermes asked for or just made (AgentSettings.swift).
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                AgentSettingsBanner(sync: appState.agentSettings)
                // A newer Conduit plugin for this dashboard's host.
                NotifierPluginUpdateBanner()
                // Calendar changes Hermes asked for (AppState+PhoneSync.swift);
                // a call's screen shows them over the call.
                if !appState.isVoiceCallScreenPresented {
                    PhoneChangeOverlay(engine: appState.phoneSync)
                }
            }
        }
        // Confirmations Hermes asks to present (PresentedScreens.swift); a
        // call's screen shows its own over the call.
        .overlay(alignment: .bottom) {
            if !appState.isVoiceCallScreenPresented {
                presentedConfirmOverlay(inCall: false)
            }
        }
        .sheet(isPresented: $appState.showModelPicker) {
            ModelPickerView()
                .presentationDetents([.medium, .large])
                .presentationBackground(.clear)
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showContextSheet) {
            ContextSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showWorkspaceSheet) {
            WorkspaceBrowserSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showGatewaySheet) {
            GatewayDiagnosticsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showAgentsSheet) {
            DelegateAgentsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
        .sheet(item: $appState.chatCallTranscript) { call in
            VoiceChatCallTranscriptSheet(call: call)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // "Keep phone awake during voice conversations": hold off auto-lock
        // only while a voice conversation is on screen.
        .onChange(
            of: VoiceScreenAwake.holdsScreenAwake(
                enabled: keepScreenAwake,
                voiceSheetShown: appState.showVoiceSheet,
                liveSheetShown: appState.showGeminiLiveSheet || appState.showGPTLiveSheet || appState.showGrokLiveSheet
                    || appState.showLocalLiveSheet
            ),
            initial: true
        ) { _, holds in
            UIApplication.shared.isIdleTimerDisabled = holds
        }
        // A voice conversation on screen keeps the backdrop drifting, as a
        // running turn does (InteractionIdleState).
        .onChange(of: isVoiceConversationShown, initial: true) { _, shown in
            InteractionIdleState.shared.setVoiceConversationShown(shown)
        }
        // Sign-out swaps this view out with a sheet possibly still up.
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            InteractionIdleState.shared.setVoiceConversationShown(false)
        }
        // Swiping a running call away minimises it; End hangs up.
        .sheet(isPresented: $appState.showGeminiLiveSheet, onDismiss: { appState.liveVoiceSheetDismissed(.geminiLive) }) {
            GeminiLiveVoiceSheet(
                controller: appState.geminiLiveController,
                jobs: appState.voiceBackgroundJobSupervisor,
                appState: appState,
                waitsToStart: appState.waitingCall?.engine == .geminiLive,
                onClose: appState.closeGeminiLiveConversation,
                onRetry: { Task { await appState.geminiLiveController.start() } }
            )
            .safeAreaInset(edge: .top, spacing: 0) { callTopBanners }
            .overlay(alignment: .bottom) { presentedConfirmOverlay(inCall: true) }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showGrokLiveSheet, onDismiss: { appState.liveVoiceSheetDismissed(.grokLive) }) {
            GeminiLiveVoiceSheet(
                controller: appState.grokLiveController,
                jobs: appState.voiceBackgroundJobSupervisor,
                appState: appState,
                engine: .grok,
                waitsToStart: appState.waitingCall?.engine == .grokLive,
                onClose: appState.closeGrokLiveConversation,
                onRetry: { Task { await appState.grokLiveController.start() } }
            )
            .safeAreaInset(edge: .top, spacing: 0) { callTopBanners }
            .overlay(alignment: .bottom) { presentedConfirmOverlay(inCall: true) }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showLocalLiveSheet, onDismiss: { appState.liveVoiceSheetDismissed(.localLive) }) {
            GeminiLiveVoiceSheet(
                controller: appState.localLiveController,
                jobs: appState.voiceBackgroundJobSupervisor,
                appState: appState,
                engine: .local,
                waitsToStart: appState.waitingCall?.engine == .localLive,
                onClose: appState.closeLocalLiveConversation,
                onRetry: { Task { await appState.localLiveController.start() } }
            )
            .safeAreaInset(edge: .top, spacing: 0) { callTopBanners }
            .overlay(alignment: .bottom) { presentedConfirmOverlay(inCall: true) }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showGPTLiveSheet, onDismiss: { appState.liveVoiceSheetDismissed(.gptLive) }) {
            GPTLiveVoiceSheet(
                controller: appState.gptLiveController,
                jobs: appState.voiceBackgroundJobSupervisor,
                appState: appState,
                waitsToStart: appState.waitingCall?.engine == .gptLive,
                onClose: appState.closeGPTLiveConversation,
                onRetry: { Task { await appState.gptLiveController.start() } }
            )
            .safeAreaInset(edge: .top, spacing: 0) { callTopBanners }
            .overlay(alignment: .bottom) { presentedConfirmOverlay(inCall: true) }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        // A CarPlay or Watch call stopped until the user allows its
        // provider to hear them: the phone asks (#827).
        .sheet(item: $appState.liveVoiceConsentRequest) { mode in
            LiveVoiceConsentSheet(mode: mode) { allowed in
                if allowed { appState.setLiveVoiceConsent(true, for: mode) }
                appState.liveVoiceConsentRequest = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showVoiceSheet, onDismiss: appState.closeVoiceConversation) {
            VoiceConversationSheet(
                controller: appState.voiceConversationController,
                backgroundJobs: appState.voiceBackgroundJobSupervisor,
                profile: appState.activeProfile,
                chatTitle: appState.activeChatSessionSummary?.title,
                appState: appState,
                onClose: appState.closeVoiceConversation,
                shouldAutoListen: { appState.consumeVoiceSheetAutoListenIfPresenting() },
                modeSwitch: appState.voiceModeSwitch(for: nil),
                approvals: appState.openChatWaitingApprovals
            )
                .safeAreaInset(edge: .top, spacing: 0) { callTopBanners }
                .overlay(alignment: .bottom) { presentedConfirmOverlay(inCall: true) }
                // What Hermes put on screen (conduit_show), over the conversation.
                .sheet(item: $appState.classicVoiceCard) { card in
                    LiveVoiceScreenCardSheet(title: card.title, markdown: card.markdown, cards: RichCard.cards(card.cards))
                        .environmentObject(appState)
                        .presentationDetents([.medium, .large])
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $settingsPresentation, onDismiss: {
            appState.isSettingsSheetPresented = false
            Task { await appState.refreshVoiceCapabilities() }
        }) { snapshot in
            SettingsView(
                snapshot: snapshot,
                saveTheme: { appState.themePreference = $0 },
                persistBusyInputMode: { mode in await appState.setBusyInputMode(mode) },
                persistChatResumeBehavior: { appState.setChatResumeBehavior($0) },
                persistChatReturnSurface: { appState.setChatReturnSurface($0) },
                loadProfileSettings: { keys in await appState.loadProfileSettings(keys: keys) },
                persistProfileSetting: { key, value in await appState.setProfileSetting(key, value: value) },
                loadProfileConfigOptions: { await appState.loadProfileConfigOptions() },
                loadProfileModelDefaults: { await appState.loadProfileModelDefaults() },
                persistProfileMainModel: { provider, model, reasoning in
                    await appState.setProfileMainModel(provider: provider, model: model, reasoning: reasoning)
                },
                saveDefaultProfileName: { appState.saveDefaultProfileName($0) },
                reconnect: {
                    await appState.reconnect()
                    return appState.isConnected
                },
                disconnect: { appState.disconnect() }
            )
                .presentationDetents([.large])
                .environmentObject(appState)
        }
        // Settings can go with this screen (switching or adding a dashboard
        // swaps in sign-in), and SwiftUI doesn't promise the sheet's
        // onDismiss then. Its flag must not outlive it: it holds back the
        // return surface while it claims a sheet is up.
        .onDisappear { appState.isSettingsSheetPresented = false }
        .background(windowWidthReader)
        .onPreferenceChange(MainViewWindowWidthKey.self) { availableWindowWidth = $0 }
        .onChange(of: isPersistentSidebarActive) { _, persistentActive in
            // Hard invariant: the persistent layout must never coexist with
            // showSidebar == true — that flag suppresses streaming/reasoning
            // publication. A resize, rotation, or the Appearance toggle can
            // activate the persistent layout while the drawer is presented.
            if persistentActive { appState.dismissSidebarDrawer() }
        }
        // Back to the list (V2) or the drawer opening covers the chat: the
        // list reads the catalog again, so a conversation started in that
        // chat, or a turn that ran there, shows without a pull to refresh.
        .onChange(of: appState.showSidebar) { _, covered in
            if covered { appState.refreshCatalogAfterLeavingChat() }
        }
        .task(id: voiceCapabilityRefreshKey) {
            await appState.refreshVoiceCapabilities()
        }
        // Cold launch: MainView first becoming the authenticated surface is
        // the qualifying return. The hook fires once per process (re-login
        // cycles rely on the scene-phase path instead), then any pending
        // request — including one from scene activation — is consumed.
        .task {
            appState.requestPreferredReturnSurfaceForColdLaunch()
            presentPreferredReturnSurfaceIfNeeded()
        }
        .onChange(of: appState.preferredReturnSurfaceRequest) { _, _ in
            presentPreferredReturnSurfaceIfNeeded()
        }
        // A widget's New Chat or Talk asks Settings out of the way
        // (revealChatForWidgetLaunch); the chat it opens must end up on top.
        .onChange(of: appState.settingsDismissRequest) { _, _ in
            // A drawer closing on its way to Settings doesn't open it either.
            shouldPresentSettingsAfterSidebarDismissal = false
            settingsOpensAt = nil
            settingsPresentation = nil
        }
        .onChange(of: appState.settingsLinkRequest) { _, page in
            // V2 opens the page in its Settings tab (V2Shell).
            guard !useV2Shell, let page else { return }
            appState.settingsLinkRequest = nil
            openSettings(at: page)
        }
    }

    /// An in-app settings link (`conduit://settings/calls` or `/voice`, in a reply):
    /// Settings opens at that page. Settings already open stays as it is,
    /// and so does a voice or other sheet: closing a voice sheet ends its
    /// call, and only one sheet shows at a time.
    private func openSettings(at page: ConduitAppLink.SettingsLink) {
        guard settingsPresentation == nil else { return }
        let otherSheetUp = appState.showModelPicker || appState.showContextSheet || appState.showWorkspaceSheet
            || appState.showGatewaySheet || appState.showAgentsSheet || appState.showVoiceSheet
            || appState.showGeminiLiveSheet || appState.showGrokLiveSheet || appState.showGPTLiveSheet
            || appState.showLocalLiveSheet
        guard !otherSheetUp else { return }
        // A host without calls (or not heard from yet) has no such page:
        // Settings opens at its start.
        switch page {
        case .calls: settingsOpensAt = appState.supportsHermesCalls ? page : nil
        case .voice, .plugin: settingsOpensAt = page
        case .health: settingsOpensAt = appState.showsHealthSettings ? page : nil
        case .location: settingsOpensAt = appState.showsLocationSettings ? page : nil
        case .phone: settingsOpensAt = appState.showsPhoneSettings ? page : nil
        }
        if appState.showSidebar, !isPersistentSidebarActive {
            presentSettingsFromDrawer()
        } else {
            presentSettings()
        }
    }

    /// Ask Hermes About Screen: the screenshot the voice will ask about.
    private var voiceScreenshotBanner: some View {
        ScreenQuestionVoiceBanner(
            screenshot: appState.voiceScreenshot,
            onDiscard: appState.discardVoiceScreenshot,
            onNewChat: appState.canMoveVoiceScreenshotToNewChat
                ? { Task { await appState.moveVoiceScreenshotToNewChat() } }
                : nil
        )
    }

    /// Routes the sidebar between its two presentations: the existing chat
    /// shell with the modal drawer, or — on wide iPad windows with the
    /// Appearance opt-in — the same SidebarView as a persistent leading
    /// column beside the chat.
    @ViewBuilder
    private var sidebarLayoutContent: some View {
        if useV2Shell {
            // V2 always opens on the Chats list (Eric, 2026-10-15); a chat
            // a notification or widget opens is pushed over it.
            V2Shell()
        } else if isPersistentSidebarActive {
            HStack(spacing: 0) {
                SidebarView(
                    onRequestSettings: presentSettingsFromPersistentSidebar,
                    presentation: .persistent
                )
                .frame(width: SidebarLayoutMetrics.persistentSidebarWidth)

                Divider()
                    .ignoresSafeArea(.container, edges: .vertical)

                chatNavigationContent
            }
        } else {
            chatNavigationContent
        }
    }

    /// The existing chat shell, shared by both sidebar layouts so the drawer
    /// and the persistent column render the identical conversation surface.
    /// Only the drawer affordances (hamburger and left-edge swipe) hide while
    /// the persistent sidebar is visible. An open Group Chat room replaces
    /// the conversation surface wholesale: a room is NOT a session, so this
    /// swap is the entire viewport integration — `ChatView`'s session state
    /// (and the saved `SessionReference`) is untouched by room navigation.
    private var chatNavigationContent: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop(drifts: true)
                if appState.activeRoomSurface != nil {
                    // Keyed by room: another room starts with its own draft.
                    GroupChatView()
                        .id(appState.activeRoomSurface?.room.roomID)
                } else {
                    ChatView()
                }
            }
            .overlay(alignment: .leading) {
                if !isPersistentSidebarActive {
                    EdgePanGesture { appState.showSidebar = true }
                        .frame(width: 25)
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // An open room supplies its own leading Leave button; a
                    // second leading control would be ambiguous. The edge
                    // swipe still opens the sidebar.
                    if !isPersistentSidebarActive && appState.activeRoomSurface == nil {
                        Button {
                            appState.showSidebar = true
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .conduitGlassControl(cornerRadius: 20, tint: .conduitAccent.opacity(0.10))
                        .accessibilityLabel("Open sessions")
                    }
                }
                // Session-only controls: an open room owns the title and
                // actions (GroupChatView's toolbar), so the session's title,
                // scroll-to-top, and refresh must not act on the hidden
                // conversation behind it.
                if appState.activeRoomSurface == nil {
                    ToolbarItem(placement: .principal) {
                        ChatTitleControl(
                            onRename: { chatTitlePendingRename = $0 },
                            onDelete: { chatTitlePendingDeletion = $0 }
                        )
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
                        // A New Chat on its way has nothing to refresh yet.
                        .disabled(!appState.isConnected || appState.isChatRefreshing || appState.showsPendingNewChat)
                        .accessibilityLabel("Refresh conversation")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionStatusIndicator()
                }
            }
        }
        // The chat title's menu needs host-owned rename and delete prompts,
        // like the session list's rows.
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
        .sheet(isPresented: $appState.showSidebar, onDismiss: presentSettingsAfterSidebarDismissal) {
            SidebarView(onRequestSettings: presentSettingsFromDrawer)
                .environmentObject(appState)
                // No blanket .transaction animation here: forcing one onto
                // every update made the drawer's first layout passes animate,
                // so the glass header and tab bar visibly grew across the
                // screen as the sheet opened. Rows animate via withAnimation.
                .presentationDetents([.large])
        }
    }

    private func presentSettingsFromDrawer() {
        shouldPresentSettingsAfterSidebarDismissal = true
        appState.showSidebar = false
    }

    /// Persistent mode keeps the sidebar visible, so Settings opens directly
    /// instead of waiting for the drawer sheet to dismiss first.
    private func presentSettingsFromPersistentSidebar() {
        presentSettings()
    }

    private func presentSettingsAfterSidebarDismissal() {
        guard shouldPresentSettingsAfterSidebarDismissal else {
            // A link's page belongs to the Settings it opened, not a later one.
            settingsOpensAt = nil
            return
        }
        shouldPresentSettingsAfterSidebarDismissal = false
        presentSettings()
    }

    private func presentSettings() {
        appState.isSettingsSheetPresented = true
        var snapshot = appState.makeSettingsSnapshot()
        snapshot.opensAt = settingsOpensAt
        settingsOpensAt = nil
        settingsPresentation = snapshot
    }

    /// Presents the sessions drawer for a preferred-return-surface request.
    /// Consumption semantics (defer-while-pending, claim-once-per-request,
    /// drop on precedence losers) live in AppState so they survive MainView
    /// teardown; this layer only owns the actual sheet presentation. An
    /// active persistent sidebar already shows Sessions, so the request is
    /// consumed without opening a redundant drawer.
    private func presentPreferredReturnSurfaceIfNeeded() {
        guard appState.claimPreferredReturnSurfacePresentation() else { return }
        guard SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
            persistentSidebarActive: isPersistentSidebarActive,
            drawerPresented: appState.showSidebar
        ) else { return }
        appState.showSidebar = true
    }

    /// A call screen's top: the screenshot banner, then calendar changes
    /// Hermes asked for (under the call screen, they were hidden until the
    /// call was minimised).
    private var callTopBanners: some View {
        VStack(spacing: 0) {
            voiceScreenshotBanner
            PhoneChangeOverlay(engine: appState.phoneSync)
                .environmentObject(appState)
        }
    }

    /// The confirmation Hermes is waiting on, answered by tap.
    private func presentedConfirmOverlay(inCall: Bool) -> some View {
        PresentedConfirmOverlay(
            sync: appState.presentedScreens,
            inCall: inCall,
            onAnswer: { prompt, outcome in
                Task { await appState.answerPresentedConfirm(prompt, outcome: outcome, via: .tap) }
            },
            onEdit: inCall ? nil : { prompt in
                Task { await appState.editPresentedConfirm(prompt) }
            }
        )
    }

    private var windowWidthReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MainViewWindowWidthKey.self, value: proxy.size.width)
        }
    }

    private var voiceCapabilityRefreshKey: String {
        "\(appState.isConnected):\(appState.activeProfile)"
    }
}

/// Reports the width of the window hosting MainView so the sidebar layout
/// decision tracks Split View, Stage Manager, and window resizing.
private struct MainViewWindowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Chat Title

/// The open chat's title. A tap scrolls to the top of the conversation;
/// touch and hold opens the session list's actions for this chat (Rename,
/// Pin, Move to Project, Archive, Delete), so it can be fixed without
/// leaving the chat (#446), cron runs included (#512). A chat without a row of
/// its own (a new chat, a Bot Chat, an offline copy) keeps the plain tap-only
/// title.
struct ChatTitleControl: View {
    @EnvironmentObject var appState: AppState
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void
    /// Plain title without its capsule, for a header that also carries a
    /// subtitle line (V2's link back to a child session's parent).
    var compact = false

    var body: some View {
        if let session = appState.activeChatSessionSummary {
            Menu {
                SessionActionMenuItems(
                    session: session,
                    onRename: { onRename(session) },
                    onDelete: { onDelete(session) }
                )
            } label: {
                titleLabel
            } primaryAction: {
                appState.requestChatScrollToTop()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            // No large content viewer here: its touch and hold would take
            // the one that opens the conversation actions.
            .accessibilityLabel(appState.displayedChatTitle)
            .accessibilityHint(AppLocalization.string("Scroll to top of conversation. Touch and hold for conversation actions."))
            // VoiceOver may open the menu on activation; the scroll stays
            // reachable as a named action.
            .accessibilityAction(named: Text(AppLocalization.string("Scroll to top of conversation"))) {
                appState.requestChatScrollToTop()
            }
        } else {
            Button {
                appState.requestChatScrollToTop()
            } label: {
                titleLabel
            }
            .buttonStyle(.plain)
            .accessibilityShowsLargeContentViewer { Text(appState.displayedChatTitle) }
            .accessibilityLabel(appState.displayedChatTitle)
            .accessibilityHint(AppLocalization.string("Scroll to top of conversation"))
        }
    }

    @ViewBuilder
    private var titleLabel: some View {
        if compact {
            Text(appState.displayedChatTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        } else {
            Text(appState.displayedChatTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .conduitGlassSurface(cornerRadius: 16, tint: .conduitAccent.opacity(0.06))
                // The navigation bar doesn't grow; touch and hold shows it large.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
    }
}

// MARK: - Connection Status

struct ConnectionStatusIndicator: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState

    private var color: Color {
        if appState.isConnected {
            return .green
        } else if appState.isRecoveringConnection {
            return .orange
        } else {
            return .red
        }
    }

    var body: some View {
        Button {
            Task { await appState.loadGatewayDiagnostics() }
        } label: {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                    .shadow(color: color.opacity(0.75), radius: appState.isConnected ? 5 : 0)
                Circle()
                    .stroke(color.opacity(0.38), lineWidth: 1)
                    .frame(width: 19, height: 19)
            }
            .frame(width: 40, height: 40)
        }
        .conduitGlassControl(cornerRadius: 20, tint: color.opacity(0.10))
        .animation(ConduitMotion.response, value: appState.isConnected)
        .accessibilityLabel(appState.isConnected
            ? AppLocalization.string("Gateway connected")
            : (appState.isRecoveringConnection ? AppLocalization.string("Reconnecting…") : AppLocalization.string("Gateway disconnected")))
    }
}


// MARK: - Edge Pan Gesture

/// Detects a left-edge pan gesture to open the sidebar.
/// Uses UIScreenEdgePanGestureRecognizer (~20pt edge width) via UIViewRepresentable.
struct EdgePanGesture: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let gesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(context.coordinator.handle(_:))
        )
        gesture.edges = .left
        gesture.cancelsTouchesInView = false
        view.addGestureRecognizer(gesture)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }

        @objc func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
            if gesture.state == .began { action() }
        }
    }
}
