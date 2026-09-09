import SwiftUI

/// Primary home: Bots messaging shelf by default; Sessions is upstream SessionList.
struct InboxView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var shell: AppShellState
    @ObservedObject var messaging: MessagingStore
    var presentation: SidebarPresentation = .drawer
    var horizontalInset: CGFloat = ConduitInboxMetrics.phoneHorizontalInset
    var profileRailSize: CGFloat = ConduitInboxMetrics.profileRailSizePhone
    var onRequestSettings: () -> Void
    var onOpenConversation: (String) -> Void
    var onCreateConversation: () -> Void
    var onResumeConversation: () -> Void
    var onSetupMessagingWithAgent: () -> Void = {}
    var onOpenMessaging: (MessagingDestination) -> Void = { _ in }

    @AppStorage("conduit.sidebarTab") private var selectedTabRaw = SidebarTab.sessions.rawValue
    @AppStorage("conduit.chatsHomePane") private var chatsHomePaneRaw = ChatsHomePane.bots.rawValue
    @Environment(\.scenePhase) private var messagingScenePhase
    @State private var showMessagingSetup = false
    @State private var messagingAction: String?
    @State private var showProfilePicker = false
    @State private var showFilterOrder = false
    @State private var showArchivedSessions = false
    @State private var showProjectCreator = false
    @State private var showProjects = false

    private var selectedTab: SidebarTab {
        get { SidebarTab.migrated(rawValue: selectedTabRaw) }
        nonmutating set { selectedTabRaw = newValue.rawValue }
    }

    private var chatsHomePane: ChatsHomePane {
        get { ChatsHomePane.migrated(rawValue: chatsHomePaneRaw) }
        nonmutating set { chatsHomePaneRaw = newValue.rawValue }
    }

    private var messagingSetupAgentEnabled: Bool {
        appState.isConnected
            && !appState.isConnecting
            && !appState.isProfileSwitching
            && appState.turnState != .synchronizing
            && !shell.isCreatingConversation
    }

    private var showMessagingFeatureCard: Bool {
        !messaging.cardDismissed
            && messaging.availability != .checking
            && !messaging.isReady
    }

    var body: some View {
        ZStack {
            ConduitCanvasBackground()

            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                if selectedTab == .sessions {
                    chatsHomePanePicker
                        .padding(.horizontal, horizontalInset)
                        .padding(.bottom, 10)

                    if chatsHomePane == .bots {
                        MessagingInboxView(
                            store: messaging,
                            requestedAction: $messagingAction,
                            openMessaging: onOpenMessaging,
                            showFeatureCard: showMessagingFeatureCard,
                            onOpenFeatureCard: { showMessagingSetup = true },
                            pinnedSize: profileRailSize
                        )
                    } else {
                        SessionList(
                            onOpenSession: onOpenConversation,
                            onCreateSession: {
                                guard !shell.isCreatingConversation else { return }
                                shell.isCreatingConversation = true
                                onCreateConversation()
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    nonChatsHeader
                        .padding(.horizontal, horizontalInset)
                        .padding(.bottom, 10)

                    Group {
                        switch selectedTab {
                        case .sessions:
                            EmptyView()
                        case .cron:
                            CronList(onOpenSession: onOpenConversation)
                                .padding(.horizontal, max(0, horizontalInset - 14))
                        case .kanban:
                            KanbanView()
                                .padding(.horizontal, max(0, horizontalInset - 14))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: appState.dashboardTicketBridge.map(ObjectIdentifier.init)) {
            #if DEBUG
            if MessagingUITestFixture.requested {
                messaging.connect(requester: MessagingUITestFixture.shared, scope: "ui-test-messaging")
            } else {
                messaging.connect(requester: appState.dashboardTicketBridge, scope: appState.connection?.baseUrl ?? "")
            }
            #else
            messaging.connect(requester: appState.dashboardTicketBridge, scope: appState.connection?.baseUrl ?? "")
            #endif
            await messaging.refresh()
        }
        .task(id: messagingScenePhase) {
            guard messagingScenePhase == .active else { return }
            while !Task.isCancelled {
                await messaging.refresh()
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .sheet(isPresented: $showMessagingSetup) {
            MessagingFeatureSheet(
                store: messaging,
                server: appState.connection?.baseUrl ?? "Hermes",
                workspaceProfileName: appState.profileDisplayName(appState.activeProfile),
                setupWithAgentEnabled: messagingSetupAgentEnabled,
                onSetupWithAgent: {
                    showMessagingSetup = false
                    onSetupMessagingWithAgent()
                }
            )
        }
        .sheet(isPresented: $showProfilePicker) {
            ProfilePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showFilterOrder) {
            SessionFilterOrderSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showArchivedSessions) {
            ArchivedSessionsSheet()
        }
        .sheet(isPresented: $showProjectCreator) {
            ProjectCreateSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showProjects) {
            NavigationStack {
                SessionList(
                    onOpenSession: { sessionID in
                        showProjects = false
                        onOpenConversation(sessionID)
                    },
                    onCreateSession: {
                        showProjects = false
                        onCreateConversation()
                    }
                )
                .navigationTitle("Projects")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showProjects = false }
                    }
                }
            }
            .onAppear {
                UserDefaults.standard.set("projects", forKey: "conduit.sessionPresentation")
            }
            .onDisappear {
                UserDefaults.standard.set("sessions", forKey: "conduit.sessionPresentation")
            }
        }
        .onAppear {
            selectedTabRaw = SidebarTab.migrated(rawValue: selectedTabRaw).rawValue
            chatsHomePaneRaw = ChatsHomePane.migrated(rawValue: chatsHomePaneRaw).rawValue
            if let profile = shell.consumePendingSessionsProfile() {
                handleProfileSelection(profile)
            }
        }
        .onChange(of: shell.pendingSessionsProfile) { _, profile in
            guard profile != nil, let consumed = shell.consumePendingSessionsProfile() else { return }
            handleProfileSelection(consumed)
        }
    }

    private var chatsHomePanePicker: some View {
        Picker("Home", selection: Binding(
            get: { chatsHomePane },
            set: { chatsHomePane = $0 }
        )) {
            ForEach(ChatsHomePane.allCases) { pane in
                Text(pane.title).tag(pane)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("chats.home.pane")
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.selection()
                showProfilePicker = true
            } label: {
                AgentAvatar(
                    profileID: appState.activeProfile,
                    displayName: appState.profileDisplayName(appState.activeProfile),
                    photoURL: appState.profileAvatarURL(for: appState.activeProfile),
                    size: 36,
                    state: appState.avatarState(for: appState.activeProfile)
                )
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(appState.isProfileSwitching)
            .accessibilityLabel("Profile management")

            Spacer(minLength: 0)

            if selectedTab == .sessions, chatsHomePane == .bots {
                Menu {
                    Button("Message a bot") { messagingAction = "message" }
                        .disabled(!messaging.isReady)
                    Button("New group") { messagingAction = "group" }
                        .disabled(messaging.capability?.supportsGroups != true)
                    Button("New session · " + appState.profileDisplayName(appState.activeProfile)) {
                        guard !shell.isCreatingConversation else { return }
                        shell.isCreatingConversation = true
                        onCreateConversation()
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .bold))
                        .frame(width: 44, height: 44).conduitPrimaryActionControl(cornerRadius: 22)
                }.accessibilityLabel("New conversation")
            }

            Menu {
                Button { showMessagingSetup = true } label: {
                    Label("Messaging", systemImage: "bubble.left.and.bubble.right")
                }
                if appState.activeSessionId != nil {
                    Button {
                        Haptics.selection()
                        onResumeConversation()
                    } label: {
                        Label("Resume conversation", systemImage: "arrow.uturn.forward")
                    }
                }
                Button {
                    Haptics.selection()
                    selectDestination(.cron)
                } label: {
                    Label("Scheduled", systemImage: "clock")
                }
                Button {
                    Haptics.selection()
                    selectDestination(.kanban)
                } label: {
                    Label("Boards", systemImage: "rectangle.3.group")
                }
                Button {
                    Haptics.selection()
                    showProjects = true
                } label: {
                    Label("Projects", systemImage: "folder")
                }
                .disabled(!appState.supportsProjects)
                Button {
                    Haptics.selection()
                    showProjectCreator = true
                } label: {
                    Label("New project", systemImage: "folder.badge.plus")
                }
                .disabled(!appState.supportsProjects)
                Button {
                    Haptics.selection()
                    showArchivedSessions = true
                } label: {
                    Label("Archived conversations", systemImage: "archivebox")
                }
                Button {
                    Haptics.selection()
                    showFilterOrder = true
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button {
                    Haptics.selection()
                    onRequestSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.conduitPrimaryText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
    }

    private var nonChatsHeader: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(ConduitMotion.response) {
                    Haptics.selection()
                    selectedTab = .sessions
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                    Text("Chats")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.conduitPrimaryText)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Chats")

            Text(selectedTab.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.conduitPrimaryText)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private func selectDestination(_ tab: SidebarTab) {
        withAnimation(ConduitMotion.response) {
            selectedTab = tab
            if tab != .sessions {
                shell.isConversationSearchActive = false
                shell.conversationSearchText = ""
            }
        }
    }

    /// Messaging handoff: land on Sessions with the requested workspace profile active.
    private func handleProfileSelection(_ profile: String) {
        chatsHomePane = .sessions
        selectedTab = .sessions
        guard profile != appState.activeProfile else { return }
        shell.resetListTransientState()
        UserDefaults.standard.set("all", forKey: "conduit.sessionSourceFilter")
        Task {
            await appState.switchProfile(to: profile)
        }
    }
}
