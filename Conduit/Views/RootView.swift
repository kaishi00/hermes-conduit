//
//  RootView.swift
//  Conduit
//
//  Root container — handles auth state and scene phase changes.
//  Compact layout: Inbox → Conversation NavigationStack.
//  Wide iPad opt-in: persistent Inbox column beside Conversation.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if appState.showLogin || appState.connection == nil {
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
        .onChange(of: scenePhase) { _, newPhase in
            appState.handleScenePhase(newPhase)
        }
    }
}

private enum ConversationDestination: Hashable {
    case active
}

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var shell = AppShellState()
    @StateObject private var messaging = MessagingStore()
    @AppStorage("conduit.ipadPersistentSidebar") private var prefersPersistentSidebar = false
    @State private var availableWindowWidth: CGFloat = 0
    @State private var settingsPresentation: SettingsSnapshot?
    @State private var navigationPath = NavigationPath()

    private var sidebarPresentation: SidebarPresentation {
        SidebarLayoutPolicy.resolvePresentation(
            idiom: UIDevice.current.userInterfaceIdiom,
            prefersPersistentSidebar: prefersPersistentSidebar,
            availableWidth: availableWindowWidth
        )
    }

    private var isPersistentSidebarActive: Bool { sidebarPresentation == .persistent }

    var body: some View {
        shellLayoutContent
        .sheet(isPresented: $appState.showModelPicker) {
            ModelPickerView()
                .presentationDetents([.medium, .large])
                .presentationBackground(.clear)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showContextSheet) {
            ContextSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showWorkspaceSheet) {
            WorkspaceBrowserSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showGatewaySheet) {
            GatewayDiagnosticsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showAgentsSheet) {
            DelegateAgentsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $appState.showVoiceSheet, onDismiss: appState.closeVoiceConversation) {
            VoiceConversationSheet(
                controller: appState.voiceConversationController,
                profile: appState.activeProfile,
                onClose: appState.closeVoiceConversation
            )
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
                .environmentObject(shell)
                .presentationDetents([.large])
        }
        .background(windowWidthReader)
        .onPreferenceChange(MainViewWindowWidthKey.self) { availableWindowWidth = $0 }
        .onChange(of: isPersistentSidebarActive) { _, persistentActive in
            // Hard invariant: the persistent layout must never coexist with
            // showSidebar == true — that flag suppresses streaming/reasoning
            // publication.
            if persistentActive {
                appState.dismissSidebarDrawer()
                navigationPath = NavigationPath()
                shell.showInbox()
            }
        }
        .task(id: voiceCapabilityRefreshKey) {
            await appState.refreshVoiceCapabilities()
        }
        .task {
            appState.requestPreferredReturnSurfaceForColdLaunch()
            presentPreferredReturnSurfaceIfNeeded()
            presentConversationPreferenceIfNeeded()
        }
        .onChange(of: appState.preferredReturnSurfaceRequest) { _, _ in
            presentPreferredReturnSurfaceIfNeeded()
        }
        .onChange(of: appState.isOpeningNotificationSession) { _, opening in
            if opening {
                revealConversation(reason: .notification)
            }
        }
        .onChange(of: appState.showVoiceSheet) { _, showing in
            if showing {
                revealConversation(reason: .voice)
            }
        }
        .onChange(of: shell.compactRoute) { _, route in
            syncNavigationPath(with: route)
        }
        .onChange(of: appState.messagingSetupSessionRequest) { _, request in
            guard request != nil else { return }
            appState.clearMessagingSetupSessionRequest()
            settingsPresentation = nil
            appState.isSettingsSheetPresented = false
            createMessagingSetupConversation()
        }
        .environmentObject(shell)
    }

    @ViewBuilder
    private var shellLayoutContent: some View {
        if isPersistentSidebarActive {
            HStack(spacing: 0) {
                inboxColumn(
                    presentation: .persistent,
                    horizontalInset: ConduitInboxMetrics.narrowColumnHorizontalInset,
                    profileRailSize: ConduitInboxMetrics.profileRailSizeNarrow
                )
                .frame(width: SidebarLayoutMetrics.persistentSidebarWidth)

                Divider()
                    .ignoresSafeArea(.container, edges: .vertical)

                conversationHost(showsBack: false)
            }
        } else {
            NavigationStack(path: $navigationPath) {
                inboxColumn(
                    presentation: .drawer,
                    horizontalInset: ConduitInboxMetrics.phoneHorizontalInset,
                    profileRailSize: ConduitInboxMetrics.profileRailSizePhone
                )
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ConversationDestination.self) { _ in
                    conversationHost(showsBack: true)
                }
            }
            .onChange(of: navigationPath.count) { _, count in
                if count == 0 {
                    shell.showInbox()
                } else if shell.compactRoute != .conversation {
                    shell.showConversationWithoutOpenRequest()
                }
            }
        }
    }

    private func inboxColumn(
        presentation: SidebarPresentation,
        horizontalInset: CGFloat,
        profileRailSize: CGFloat
    ) -> some View {
        InboxView(
            shell: shell,
            messaging: messaging,
            presentation: presentation,
            horizontalInset: horizontalInset,
            profileRailSize: profileRailSize,
            onRequestSettings: presentSettings,
            onOpenConversation: { sessionID in
                openConversation(sessionID: sessionID, reason: .rowSelection)
            },
            onCreateConversation: {
                createConversation()
            },
            onResumeConversation: {
                revealConversation(reason: .resume)
            },
            onSetupMessagingWithAgent: {
                createMessagingSetupConversation()
            },
            onOpenMessaging: { destination in
                openMessaging(destination)
            }
        )
    }

    private var isShowingMessaging: Bool { shell.messagingDestination != nil }

    private func conversationHost(showsBack: Bool) -> some View {
        ZStack {
            ConduitCanvasBackground()
            if let destination = shell.messagingDestination {
                MessagingConversationView(
                    destination: destination,
                    owner: messaging,
                    embedsInHost: true,
                    onClose: { navigateBackToInbox() },
                    openSessions: { profileName in
                        shell.requestProfileSessionsAfterMessaging(profileName)
                        navigationPath = NavigationPath()
                        Task { await messaging.refreshConversations() }
                    }
                )
                .id(destination.id)
            } else {
                ChatView()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if showsBack {
                    Button {
                        Haptics.selection()
                        navigateBackToInbox()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Bots")
                                .font(.body.weight(.medium))
                        }
                        .foregroundStyle(Color.conduitPrimaryText)
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to Bots")
                } else if !isShowingMessaging {
                    AgentAvatar(
                        profileID: appState.activeProfile,
                        displayName: appState.profileDisplayName(appState.activeProfile),
                        photoURL: appState.profileAvatarURL(for: appState.activeProfile),
                        size: 28,
                        state: appState.avatarState(for: appState.activeProfile)
                    )
                    .accessibilityHidden(true)
                }
            }
            ToolbarItem(placement: .principal) {
                if isShowingMessaging {
                    Text(messagingHostTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.conduitPrimaryText)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .conduitRaisedSurface(cornerRadius: 16)
                        .accessibilityLabel(messagingHostTitle)
                } else {
                    Button {
                        appState.requestChatScrollToTop()
                    } label: {
                        Text(appState.activeSessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.conduitPrimaryText)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .conduitRaisedSurface(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(appState.activeSessionTitle)
                    .accessibilityHint("Scroll to top of conversation")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if showsBack && !isShowingMessaging {
                    AgentAvatar(
                        profileID: appState.activeProfile,
                        displayName: appState.profileDisplayName(appState.activeProfile),
                        photoURL: appState.profileAvatarURL(for: appState.activeProfile),
                        size: 28,
                        state: appState.avatarState(for: appState.activeProfile)
                    )
                    .accessibilityLabel(appState.profileDisplayName(appState.activeProfile))
                }
            }
            if !isShowingMessaging {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await appState.refreshActiveSession() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(!appState.isConnected || appState.isChatRefreshing)

                        Button {
                            appState.showGatewaySheet = true
                        } label: {
                            Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.conduitPrimaryText)
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Conversation menu")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionStatusIndicator()
            }
        }
    }

    private var messagingHostTitle: String {
        guard let destination = shell.messagingDestination else { return "Messages" }
        if let profileID = destination.profileID,
           let profile = messaging.profiles.first(where: { $0.id == profileID }) {
            return profile.displayName
        }
        if let conversationID = destination.conversationID,
           let conversation = messaging.conversations.first(where: { $0.id == conversationID }) {
            return conversation.title
        }
        return "Messages"
    }

    private func openMessaging(_ destination: MessagingDestination) {
        appState.dismissSidebarDrawer()
        shell.showMessaging(destination)
        // compactRoute onChange → syncNavigationPath pushes ConversationDestination.active.
    }

    private func openConversation(sessionID: String, reason: AppShellState.ConversationOpenRequest.Reason) {
        let generation = shell.beginConversationOpen(sessionID: sessionID, reason: reason)
        // Already-selected conversation: reveal without unnecessarily resetting.
        if let active = appState.activeSessionId,
           appState.activeChatScrollSessionIdentity.areEquivalent(active, sessionID)
            || active == sessionID {
            _ = shell.admitConversationOpen(generation: generation, sessionID: sessionID)
            revealConversation(reason: reason)
            return
        }
        appState.dismissSidebarDrawer()
        appState.requestOpenSession(sessionID)
        _ = shell.admitConversationOpen(generation: generation, sessionID: sessionID)
        revealConversation(reason: reason)
    }

    private func createConversation() {
        let generation = shell.beginConversationOpen(sessionID: nil, reason: .newConversation)
        appState.dismissSidebarDrawer()
        Task {
            await appState.createNewSession()
            guard shell.admitConversationOpen(
                generation: generation,
                sessionID: appState.activeSessionId
            ) else {
                shell.rejectConversationOpen(generation: generation)
                return
            }
            revealConversation(reason: .newConversation)
        }
    }

    private func createMessagingSetupConversation() {
        guard appState.isConnected,
              !appState.isConnecting,
              !appState.isProfileSwitching,
              appState.turnState != .synchronizing,
              !shell.isCreatingConversation else { return }
        let generation = shell.beginConversationOpen(sessionID: nil, reason: .newConversation)
        appState.dismissSidebarDrawer()
        shell.isCreatingConversation = true
        Task {
            defer { shell.isCreatingConversation = false }
            await appState.createNewSession()
            guard shell.admitConversationOpen(
                generation: generation,
                sessionID: appState.activeSessionId
            ) else {
                shell.rejectConversationOpen(generation: generation)
                return
            }
            revealConversation(reason: .newConversation)
            guard appState.activeSessionId != nil else { return }
            var principal: String?
            if let bridge = appState.dashboardTicketBridge {
                do {
                    let identity = try await MessagingService(requester: bridge).identity()
                    principal = MessagingSetupPrompt.principal(from: identity)
                } catch {
                    principal = nil
                }
            }
            let seed = MessagingSetupPrompt.text(
                principal: principal,
                activeProfile: appState.activeProfile
            )
            _ = await appState.sendMessage(seed)
        }
    }

    private func revealConversation(reason: AppShellState.ConversationOpenRequest.Reason) {
        _ = reason
        if isPersistentSidebarActive {
            shell.showConversationWithoutOpenRequest()
            return
        }
        shell.showConversationWithoutOpenRequest()
        if navigationPath.isEmpty {
            navigationPath.append(ConversationDestination.active)
        }
    }

    private func navigateBackToInbox() {
        let wasMessaging = shell.messagingDestination != nil
        shell.showInbox()
        navigationPath = NavigationPath()
        // Legacy flag must stay false so streaming is not suppressed.
        appState.dismissSidebarDrawer()
        if wasMessaging {
            Task { await messaging.refreshConversations() }
        }
    }

    private func syncNavigationPath(with route: AppShellState.CompactRoute) {
        guard !isPersistentSidebarActive else { return }
        switch route {
        case .inbox:
            if !navigationPath.isEmpty {
                navigationPath = NavigationPath()
            }
        case .conversation:
            if navigationPath.isEmpty {
                navigationPath.append(ConversationDestination.active)
            }
        }
    }

    private func presentSettings() {
        appState.isSettingsSheetPresented = true
        settingsPresentation = appState.makeSettingsSnapshot()
    }

    /// Presents Inbox for a preferred-return-surface request. Consumption
    /// semantics live in AppState; this layer only owns presentation. An
    /// active persistent sidebar already shows Inbox, so the request is
    /// consumed without a redundant push.
    private func presentPreferredReturnSurfaceIfNeeded() {
        guard appState.claimPreferredReturnSurfacePresentation() else { return }
        let alreadyShowingInbox = isPersistentSidebarActive
            || (shell.compactRoute == .inbox && navigationPath.isEmpty)
        guard AppShellState.shouldPresentInboxForReturnSurface(
            persistentSidebarActive: isPersistentSidebarActive,
            alreadyShowingInbox: alreadyShowingInbox
        ) else { return }
        navigateBackToInbox()
    }

    /// Explicit Conversation preference restores the chat surface without
    /// flashing Inbox first on cold launch / foreground return.
    private func presentConversationPreferenceIfNeeded() {
        guard appState.chatReturnSurface == .conversation else { return }
        guard !isPersistentSidebarActive else { return }
        revealConversation(reason: .returnSurface)
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

// MARK: - Connection Status

struct ConnectionStatusIndicator: View {
    @EnvironmentObject var appState: AppState

    private var color: Color {
        if appState.isConnected {
            return .green
        } else if appState.isConnecting {
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
        .accessibilityLabel(appState.isConnected ? "Gateway connected" : "Gateway disconnected")
    }
}

// MARK: - Edge Pan Gesture

/// Detects a left-edge pan gesture. Retained for compatibility; compact
/// inbox navigation no longer opens a drawer from this gesture.
struct EdgePanGesture: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let gesture = UIScreenEdgePanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
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

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }

        @objc func handle(_ gesture: UIScreenEdgePanGestureRecognizer) {
            if gesture.state == .began { action() }
        }
    }
}
