//
//  SidebarView.swift
//  Conduit
//
//  Full-screen slide-in sidebar with Sessions / Cron / Kanban tabs.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    let onRequestSettings: () -> Void
    /// Drawer mode keeps the current modal-sheet behavior; persistent mode
    /// renders the same content as a fixed root-layout column with no close
    /// control and no dismissal.
    var presentation: SidebarPresentation = .drawer
    @AppStorage("conduit.sidebarTab") private var selectedTabRaw = SidebarTab.sessions.rawValue

    private var selectedTab: SidebarTab {
        get { SidebarTab.migrated(rawValue: selectedTabRaw) }
        set { selectedTabRaw = newValue.rawValue }
    }
    @State private var showProfilePicker = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                // The drawer is a sheet over the drifting chat; only the
                // persistent column is a main surface of its own.
                ConduitBackdrop(drifts: presentation == .persistent)

                VStack(spacing: 16) {
                    ConduitGlassGroup(spacing: 12) {
                        HStack(spacing: 10) {
                            Button {
                                Haptics.selection()
                                showProfilePicker = true
                            } label: {
                                HStack(spacing: 7) {
                                    ProfileAvatarView(
                                        profile: appState.activeProfile,
                                        displayName: appState.profileDisplayName(appState.activeProfile),
                                        url: appState.profileAvatarURL(for: appState.activeProfile),
                                        size: 28
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Workspace")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        Text(appState.profileDisplayName(appState.activeProfile))
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(2)
                                    }
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .frame(minHeight: 48)
                            }
                            .disabled(appState.isProfileSwitching)
                            .conduitGlassControl(cornerRadius: 18, tint: .conduitAccent.opacity(0.08))
                            .accessibilityIdentifier("sidebar.workspace")

                            Spacer(minLength: 0)

                            Button {
                                Haptics.selection()
                                onRequestSettings()
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 44, height: 44)
                            }
                            .conduitGlassControl(cornerRadius: 18)
                            .accessibilityLabel("Settings")

                            if presentation == .drawer {
                                Button {
                                    dismiss()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .frame(width: 44, height: 44)
                                }
                                .conduitGlassControl(cornerRadius: 18)
                                .accessibilityLabel("Close sessions")
                            }
                        }
                    }

                    ConduitGlassGroup(spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(SidebarTab.allCases, id: \.self) { tab in
                                Button {
                                    withAnimation(ConduitMotion.response) {
                                        Haptics.selection()
                                        selectedTabRaw = tab.rawValue
                                    }
                                } label: {
                                    // Icon only when the name no longer fits
                                    // its quarter of the bar (large text).
                                    ViewThatFits(in: .horizontal) {
                                        Label(tab.displayName, systemImage: tab.icon)
                                            .lineLimit(1)
                                        Label(tab.displayName, systemImage: tab.icon)
                                            .labelStyle(.iconOnly)
                                            .conduitFixedGlyph()
                                    }
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: 40)
                                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                                        .background(
                                            selectedTab == tab ? Color.conduitAccent.opacity(0.16) : .clear,
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityShowsLargeContentViewer {
                                    Label(tab.displayName, systemImage: tab.icon)
                                }
                            }
                        }
                        .padding(4)
                        .conduitGlassSurface(cornerRadius: 20, tint: .conduitAccent.opacity(0.05))
                    }

                    Group {
                        switch selectedTab {
                        case .sessions:
                            SessionList()
                        case .bots:
                            BotRosterView()
                        case .cron:
                            CronList()
                        case .kanban:
                            KanbanView()
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showProfilePicker) {
            ProfilePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            // Explicitly migrate removed raw values such as Capabilities.
            selectedTabRaw = SidebarTab.migrated(rawValue: selectedTabRaw).rawValue
        }
    }
}

// MARK: - Session List

struct SessionList: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var showFilterOrder = false
    @State private var showArchivedSessions = false
    @State private var showProjectCreator = false
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingRename: SessionSummary?
    @State private var selectedProject: ProjectSummary?
    @State private var projectPendingRename: ProjectSummary?
    @State private var projectPendingDeletion: ProjectSummary?
    @AppStorage("conduit.sessionSourceFilter") private var selectedSourceRaw: String = "all"
    @AppStorage("conduit.sessionPresentation") private var sessionPresentationRaw = "sessions"
    /// Quick status filter (#454), layered on top of the source filter.
    @AppStorage("conduit.sessionStatusFilter") private var statusFilterRaw = ""
    /// A live filter saved while the gateway can't report live status reads
    /// as no filter, so the list doesn't empty out behind a hidden chip.
    private var statusFilter: SessionStatusFilter? {
        guard let filter = SessionStatusFilter(rawValue: statusFilterRaw) else { return nil }
        return visibleStatusFilters.contains(filter) ? filter : nil
    }

    private var visibleStatusFilters: [SessionStatusFilter] {
        SessionStatusFilter.allCases.filter { !$0.isLive || appState.liveSessionStatusAvailable }
    }

    private enum SessionPresentation: String {
        case sessions
        case projects
    }

    private var sessionPresentation: SessionPresentation {
        SessionPresentation(rawValue: sessionPresentationRaw) ?? .sessions
    }

    private var showingProjects: Bool {
        sessionPresentation == .projects
    }
    private var selectedSource: SessionSource? {
        get { selectedSourceRaw == "all" ? nil : SessionSource(rawValue: selectedSourceRaw) }
    }
    private func setSelectedSource(_ source: SessionSource?) {
        selectedSourceRaw = source?.rawValue ?? "all"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    Haptics.medium()
                    appState.dismissSidebarDrawer()
                    Task { await appState.createNewSession() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("New Chat")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    .foregroundStyle(Color.conduitBackgroundColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.conduitAccent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                // The saved copy has no live gateway to create a chat on.
                .disabled(appState.turnState == .synchronizing || appState.offlineChatPresentation != nil)
                .opacity(appState.turnState == .synchronizing || appState.offlineChatPresentation != nil ? 0.6 : 1)

                // A call of its own, not tied to the open chat: its work
                // runs as jobs on the Voice Jobs model.
                if appState.showsComposerVoiceButton {
                    Button {
                        Haptics.medium()
                        appState.dismissSidebarDrawer()
                        Task {
                            _ = await appState.openVoiceConversation(
                                PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: true, source: .newCall)
                            )
                        }
                    } label: {
                        Image(systemName: "waveform")
                            .font(.title3.weight(.semibold))
                            .conduitFixedGlyph()
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .conduitGlassControl(cornerRadius: 14)
                    .disabled(!appState.canStartPhoneVoiceConversation || appState.isVoiceInUse)
                    .accessibilityLabel("New voice call")
                    .accessibilityHint(appState.phoneVoiceUnavailableReason ?? AppLocalization.string("Starts a voice call that isn't tied to a chat"))
                }

                Menu {
                    Button {
                        Haptics.selection()
                        showFilterOrder = true
                    } label: {
                        Label("Reorder filters", systemImage: "arrow.left.arrow.right")
                    }

                    Button {
                        Haptics.selection()
                        showArchivedSessions = true
                    } label: {
                        Label("Archived conversations", systemImage: "archivebox")
                    }

                    Button {
                        Haptics.light()
                        appState.markAllSessionsRead()
                    } label: {
                        Label("Mark all as read", systemImage: "envelope.open")
                    }
                    .disabled(!sourceRows(nil).contains { appState.isSessionUnread($0) })

                    Button {
                        Haptics.selection()
                        sessionPresentationRaw = SessionPresentation.projects.rawValue
                        showProjectCreator = true
                    } label: {
                        Label("New project", systemImage: "folder.badge.plus")
                    }
                    .disabled(!appState.supportsProjects)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .conduitGlassControl(cornerRadius: 14)
                .accessibilityLabel("Manage sessions")

                if showingProjects {
                    Button {
                        Haptics.selection()
                        showProjectCreator = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .conduitGlassControl(cornerRadius: 14)
                    .disabled(!appState.supportsProjects)
                    .accessibilityLabel("New project")
                }

                Button {
                    Haptics.selection()
                    withAnimation(ConduitMotion.response) {
                        sessionPresentationRaw = showingProjects ? SessionPresentation.sessions.rawValue : SessionPresentation.projects.rawValue
                    }
                } label: {
                    Image(systemName: showingProjects ? "list.bullet" : "folder")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .conduitGlassControl(cornerRadius: 14, tint: showingProjects ? .conduitAccent.opacity(0.14) : .clear)
                .accessibilityLabel(showingProjects ? AppLocalization.string("Show sessions") : AppLocalization.string("Browse projects"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
            if !showingProjects {
                sourceFilters
            }
            let layout = SidebarOfflineLayout.visibility(
                showingProjects: showingProjects,
                hasOfflineCopy: appState.offlineChatPresentation != nil,
                displayedSessionsEmpty: displayedSessions.isEmpty
            )
            List {
                if showingProjects {
                    // Pinned chats from every project stay one tap away
                    // without leaving the folder view (#338).
                    let pinned = projectsViewPinnedSessions
                    if !pinned.isEmpty {
                        Section("Pinned") {
                            ForEach(pinned) { session in
                                sessionRow(session)
                            }
                        }
                    }
                    projectContent(hasPinnedSessions: !pinned.isEmpty)
                }
                if layout.savedSection, let offline = appState.offlineChatPresentation {
                    // While the saved copy is up (#99), its saved session list
                    // shows ABOVE the live sections, which keep rendering as
                    // soon as the live catalog arrives. Read-only — only
                    // conversations with a saved transcript open, and they
                    // open inside the offline copy.
                    Section {
                        ForEach(offline.snapshot.sessions) { session in
                            offlineSessionRow(session, presentation: offline)
                        }
                    } header: {
                        Text("Saved on this device")
                    } footer: {
                        Text("Read-only copies from your last connection.")
                    }
                }
                if layout.emptyState {
                    ContentUnavailableView(
                        statusFilter?.emptyTitle
                            ?? (selectedSource == nil ? AppLocalization.string("No Sessions") : AppLocalization.string("No \(selectedSource!.label) Sessions")),
                        systemImage: statusFilter?.emptySystemImage ?? "tray",
                        description: Text(searchText.isEmpty
                            ? statusFilter?.emptyDescription ?? AppLocalization.string("Sessions will appear here once created.")
                            : AppLocalization.string("Try a different search."))
                    )
                }

                if layout.liveSections && !pinnedSessions.isEmpty {
                    Section("Pinned") {
                        ForEach(pinnedSessions) { session in
                            sessionRow(session)
                        }
                    }
                }

                if layout.liveSections && !unpinnedSessions.isEmpty {
                    Section(pinnedSessions.isEmpty ? AppLocalization.string("Sessions") : AppLocalization.string("Recent")) {
                        ForEach(unpinnedSessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: showingProjects ? AppLocalization.string("Search projects and pinned chats") : AppLocalization.string("Search sessions"))
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .refreshable {
                await appState.refreshSessionCatalog()
            }
        }
        .sheet(isPresented: $showFilterOrder) {
            SessionFilterOrderSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showArchivedSessions) {
            ArchivedSessionsSheet()
        }
        .sheet(item: $selectedProject) { project in
            ProjectSessionsSheet(project: project)
        }
        .sheet(isPresented: $showProjectCreator) {
            ProjectCreateSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task(id: appState.activeProfile) {
            await appState.refreshProjects()
        }
        // Working / Needs input (#454) follow the gateway's live registry
        // while the list is on screen.
        .task(id: appState.activeProfile) {
            while !Task.isCancelled {
                await appState.refreshLiveSessionStatuses()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .sheet(item: $projectPendingRename) { project in
            RenameSheet(
                title: AppLocalization.string("Rename project"),
                placeholder: AppLocalization.string("Project name"),
                initialText: project.title,
                normalize: { SessionRenameOperation.normalizedTitle($0, currentTitle: project.title) }
            ) { name in
                Task { Haptics.mutationCompleted(await appState.renameProject(project, to: name)) }
            }
        }
        .alert("Delete project?", isPresented: Binding(
            get: { projectPendingDeletion != nil },
            set: { if !$0 { projectPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                projectPendingDeletion = nil
                Task { Haptics.mutationCompleted(await appState.deleteProject(project)) }
            }
            Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
        } message: {
            Text(AppLocalization.string("This removes \(projectPendingDeletion?.title ?? "") from Hermes. Its folders, files and conversations are kept."))
        }
        .alert("Delete conversation?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let session = sessionPendingDeletion else { return }
                sessionPendingDeletion = nil
                Task { await appState.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("This permanently deletes the conversation and cannot be undone.")
        }
        .sheet(item: $sessionPendingRename) { session in
            RenameSheet.conversation(session) { title in
                Task { await appState.renameSession(session, to: title) }
            }
        }

    }

    private var allSessions: [SessionSummary] {
        var listed = sourceRows(selectedSource)
        if let statusFilter {
            listed = listed.filter { matches($0, statusFilter) }
        }
        return listed
    }

    private func matches(_ session: SessionSummary, _ filter: SessionStatusFilter) -> Bool {
        switch filter {
        case .needsInput: return appState.sessionLiveStatus(session) == .needsInput
        case .working: return appState.sessionLiveStatus(session) == .working
        case .unread: return appState.isSessionUnread(session)
        }
    }

    /// Counted within the selected source, matching what the chip shows.
    private func statusCount(_ filter: SessionStatusFilter) -> Int {
        sourceRows(selectedSource).filter { matches($0, filter) }.count
    }

    /// The rows a source filter lists: cron runs only under Cron, plus the
    /// pinned ones in All (#485).
    private func sourceRows(_ source: SessionSource?) -> [SessionSummary] {
        SidebarSourceRows.rows(
            sessions: appState.activeProfileSessions,
            cronSessions: appState.activeProfileCronSessions,
            source: source,
            category: appState.sessionCategory,
            isPinned: appState.isSessionPinned
        )
    }

    private var displayedSessions: [SessionSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allSessions }
        return allSessions.filter { sessionMatches($0, query: query) }
    }

    private func sessionMatches(_ session: SessionSummary, query: String) -> Bool {
        [session.title, session.model, session.id, appState.sessionCategory(for: session).label]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// The Projects view hides the source filters, so its Pinned section
    /// ignores them and lists pinned chats from every project.
    private var projectsViewPinnedSessions: [SessionSummary] {
        SidebarPinnedSessions.forProjectsView(
            sourceRows(nil),
            query: searchText,
            isPinned: appState.isSessionPinned,
            matches: sessionMatches
        )
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A search that only matches pinned chats shows them without a "No
    /// Matching Projects" state under them.
    @ViewBuilder
    private func projectContent(hasPinnedSessions: Bool) -> some View {
        if appState.projectsLoading && displayedProjects.isEmpty {
            ProgressView("Loading projects…")
                .frame(maxWidth: .infinity, minHeight: 140)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if displayedProjects.isEmpty && hasPinnedSessions && isSearching {
            EmptyView()
        } else if displayedProjects.isEmpty {
            ContentUnavailableView(
                isSearching ? AppLocalization.string("No Matching Projects") : AppLocalization.string("No Projects"),
                systemImage: "folder",
                description: Text(!isSearching
                    ? AppLocalization.string("Projects created in Hermes Desktop will appear here.")
                    : AppLocalization.string("Try a different search."))
            )
        } else {
            Section("Projects") {
                ForEach(displayedProjects) { project in
                    Button {
                        Haptics.light()
                        selectedProject = project
                    } label: {
                        ProjectRow(project: project)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(appState.isProjectEditable(project)
                        ? AppLocalization.string("Opens the conversations in this project. Swipe or touch and hold to rename or delete it.")
                        : AppLocalization.string("Opens the conversations in this project."))
                    .projectActionsMenu(isEnabled: appState.isProjectEditable(project)) {
                        Button {
                            Haptics.selection()
                            DispatchQueue.main.async { projectPendingRename = project }
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        .disabled(appState.isProjectMutationInFlight)
                        Button(role: .destructive) {
                            Haptics.warning()
                            projectPendingDeletion = project
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(appState.isProjectMutationInFlight)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if appState.isProjectEditable(project) {
                            Button(role: .destructive) {
                                Haptics.warning()
                                projectPendingDeletion = project
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(appState.isProjectMutationInFlight)
                            Button {
                                Haptics.selection()
                                DispatchQueue.main.async { projectPendingRename = project }
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            .tint(.conduitAccent)
                            .disabled(appState.isProjectMutationInFlight)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                }
            }
        }
    }

    private var displayedProjects: [ProjectSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.projects }
        return appState.projects.filter { project in
            project.title.localizedCaseInsensitiveContains(query)
                || project.previewSessions.contains { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    private var availableSources: [SessionSource] {
        appState.sessionFilterOrder.filter { !sourceRows($0).isEmpty }
    }

    private var pinnedSessions: [SessionSummary] {
        displayedSessions.filter { appState.isSessionPinned($0) }
    }

    private var unpinnedSessions: [SessionSummary] {
        displayedSessions.filter { !appState.isSessionPinned($0) }
    }

    private var sourceFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                statusFilterMenu
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 18)
                    .accessibilityHidden(true)
                sourceFilter(title: AppLocalization.string("All"), count: sourceRows(nil).count, source: nil)
                ForEach(availableSources, id: \.self) { source in
                    sourceFilter(title: source.label, count: sourceRows(source).count, source: source)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }

    /// One chip for Needs input, Working and Unread, so they don't crowd the
    /// source filters. Picking a status narrows whichever source filter is
    /// selected ("Unread" inside "Telegram"); picking it again clears it.
    private var statusFilterMenu: some View {
        let selected = statusFilter
        let waiting = visibleStatusFilters.filter { $0 != selected && statusCount($0) > 0 }
        return Menu {
            ForEach(visibleStatusFilters) { filter in
                Button {
                    withAnimation(ConduitMotion.response) {
                        Haptics.selection()
                        statusFilterRaw = selected == filter ? "" : filter.rawValue
                    }
                } label: {
                    if selected == filter {
                        Label("\(filter.title) \(String(statusCount(filter)))", systemImage: "checkmark")
                    } else {
                        Text("\(filter.title) \(String(statusCount(filter)))")
                    }
                }
                .accessibilityHint(filter.accessibilityHint)
            }
        } label: {
            HStack(spacing: 5) {
                if let selected {
                    Circle()
                        .fill(Color.conduitBackgroundColor)
                        .frame(width: 6, height: 6)
                    Text("\(selected.title) \(String(statusCount(selected)))")
                } else {
                    // A dot per status with something in it, so a chat
                    // waiting on you shows without opening the menu.
                    ForEach(waiting) { filter in
                        Circle().fill(filter.color).frame(width: 6, height: 6)
                    }
                    Text(AppLocalization.string("Status"))
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected == nil ? Color.secondary : Color.conduitBackgroundColor)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(selected?.color ?? Color.primary.opacity(0.07), in: Capsule())
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        // The idle dots say which statuses have chats; VoiceOver hears them too.
        .accessibilityLabel(([AppLocalization.string("Status")]
            + (selected.map { [$0] } ?? waiting).map { "\($0.title) \(String(statusCount($0)))" })
            .joined(separator: ", "))
        .accessibilityAddTraits(selected == nil ? [] : .isSelected)
    }

    private func sourceFilter(title: String, count: Int, source: SessionSource?) -> some View {
        Button { withAnimation(ConduitMotion.response) { Haptics.selection()
                setSelectedSource(source) } } label: {
            Text("\(title) \(String(count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(selectedSource == source ? Color.conduitBackgroundColor : .secondary)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(selectedSource == source ? Color.conduitAccent : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Haptics.selection()
                showFilterOrder = true
            } label: {
                Label("Reorder filters", systemImage: "arrow.left.arrow.right")
            }
        }
    }

    private func offlineSessionRow(
        _ session: OfflineCachedSession,
        presentation: OfflineChatPresentation
    ) -> some View {
        let isSaved = presentation.snapshot.transcript(for: session.id) != nil
        let isDisplayed = presentation.displayedSessionID == session.id
        return Button {
            Haptics.selection()
            appState.showOfflineCachedSession(session.id)
            appState.dismissSidebarDrawer()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.subheadline.weight(isDisplayed ? .semibold : .regular))
                    .lineLimit(1)
                Text(isSaved ? session.displayUpdatedLabel() : AppLocalization.string("Not saved offline"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!isSaved)
        .opacity(isSaved ? 1 : 0.5)
        .accessibilityHint(isSaved ? "" : AppLocalization.string("This conversation has no saved copy on this device"))
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            appState.requestOpenSession(session.id)
        } label: {
            SessionRow(
                session: session,
                isSelected: session.id == appState.activeSessionId,
                isPinned: appState.isSessionPinned(session),
                isUnread: appState.isSessionUnread(session),
                liveStatus: appState.sessionLiveStatus(session),
                isVoiceJob: appState.isVoiceJobSession(session),
                category: appState.sessionCategory(for: session),
                detail: appState.voiceSessionDetail(for: session)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Swipe or touch and hold for conversation actions.")
        .contextMenu {
            SessionActionMenuItems(
                session: session,
                onRename: { sessionPendingRename = session },
                onDelete: { sessionPendingDeletion = session }
            )
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Haptics.light()
                appState.toggleSessionPinned(session)
            } label: {
                Label(appState.isSessionPinned(session) ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"), systemImage: appState.isSessionPinned(session) ? "pin.slash" : "pin")
            }
            .tint(.conduitAccent)

            ReadStateToggleButton(session: session)
                .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task {
                    Haptics.mutationCompleted(await appState.archiveSession(session))
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.orange)
            .disabled(appState.isSessionMutationInFlight(session))

            Button(role: .destructive) {
                Haptics.warning()
                sessionPendingDeletion = session
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(appState.isSessionMutationInFlight(session))
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
    }
}

private struct SessionFilterOrderSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.sessionFilterOrder, id: \.self) { source in
                        Label(source.label, systemImage: source.iconName)
                            .foregroundStyle(source.color)
                    }
                    .onMove { from, to in
                        appState.moveSessionFilters(fromOffsets: from, toOffset: to)
                    }
                } footer: {
                    Text("Drag categories into the order you prefer. All remains first in the session drawer.")
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Session filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct ArchivedSessionsSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var sessionPendingDeletion: SessionSummary?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                List {
                    if isLoading {
                        ProgressView("Loading archived conversations…")
                            .frame(maxWidth: .infinity, minHeight: 140)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else if displayedSessions.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? AppLocalization.string("Nothing archived") : AppLocalization.string("No matching conversations"),
                            systemImage: "archivebox",
                            description: Text("Archived conversations stay here until you restore or permanently delete them.")
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(displayedSessions) { session in
                            HStack(spacing: 10) {
                                SessionRow(
                                    session: session,
                                    isVoiceJob: appState.isVoiceJobSession(session),
                                    category: appState.sessionCategory(for: session),
                                    detail: appState.voiceSessionDetail(for: session),
                                    showsDisclosureIndicator: false
                                )

                                VStack(spacing: 6) {
                                    Button {
                                        Task {
                                            Haptics.mutationCompleted(await appState.restoreArchivedSession(session))
                                        }
                                    } label: {
                                        Image(systemName: "arrow.uturn.backward")
                                            .font(.caption.weight(.bold))
                                            .frame(width: 34, height: 34)
                                    }
                                    .buttonStyle(.plain)
                                    .conduitGlassControl(cornerRadius: 12, tint: .conduitAccent.opacity(0.12))
                                    .accessibilityLabel("Restore \(session.title)")

                                    Button(role: .destructive) {
                                        Haptics.warning()
                                        sessionPendingDeletion = session
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption.weight(.bold))
                                            .frame(width: 34, height: 34)
                                    }
                                    .buttonStyle(.plain)
                                    .conduitGlassControl(cornerRadius: 12, tint: .red.opacity(0.12))
                                    .accessibilityLabel("Delete \(session.title)")
                                }
                                .disabled(appState.isSessionMutationInFlight(session))
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                    }
                }
                .searchable(text: $searchText, prompt: AppLocalization.string("Search archived conversations"))
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .refreshable { await refresh() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Archived conversations"), close: { dismiss() })
            }
        }
        .task { await refresh() }
        .alert("Delete conversation?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let session = sessionPendingDeletion else { return }
                sessionPendingDeletion = nil
                Task { await appState.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("This permanently deletes the conversation and cannot be undone.")
        }
    }

    private var displayedSessions: [SessionSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.archivedSessions }
        return appState.archivedSessions.filter { session in
            [session.title, session.model, session.id, appState.sessionCategory(for: session).label]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func refresh() async {
        isLoading = true
        await appState.loadArchivedSessions()
        isLoading = false
    }
}

struct SessionRow: View {
    let session: SessionSummary
    var isSelected = false
    var isPinned = false
    /// Has activity the user hasn't seen (#454).
    var isUnread = false
    /// A turn is running, or it waits on the user (#454).
    var liveStatus: SessionLiveStatus? = nil
    /// Started as a Voice background job (issue #163).
    var isVoiceJob = false
    /// The filter the row is filed under (a voice tag's, else its source).
    var category: SessionSource? = nil
    /// Replaces the model on the second line (a saved call's engine, the
    /// call a voice job came from).
    var detail: String? = nil
    var showsDisclosureIndicator = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var icon: SessionSource { category ?? session.source }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon.iconName)
                .font(.caption.weight(.semibold))
                .conduitFixedGlyph()
                .foregroundStyle(icon.color)
                .frame(width: 30, height: 30)
                .background(icon.color.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.subheadline.weight(isUnread ? .semibold : .medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                // Stacked at large text so the model doesn't truncate the time.
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text(detail ?? session.model)
                            .lineLimit(2)
                        Text(session.updatedLabel)
                    } else {
                        HStack(spacing: 5) {
                            Text(detail ?? session.model)
                            Text("•")
                            Text(session.updatedLabel)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            switch liveStatus {
            case .needsInput?:
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(SessionStatusFilter.needsInput.color)
                    .accessibilityLabel(SessionStatusFilter.needsInput.title)
            case .working?:
                ProgressView()
                    .controlSize(.mini)
                    .tint(SessionStatusFilter.working.color)
                    .accessibilityLabel(SessionStatusFilter.working.title)
            case nil:
                EmptyView()
            }
            if isUnread {
                Circle()
                    .fill(SessionStatusFilter.unread.color)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(SessionStatusFilter.unread.title)
            }
            if isVoiceJob, icon != .voiceJob {
                Image(systemName: "waveform")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.conduitAura)
                    .accessibilityLabel("Started from voice")
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.conduitAccent)
            }
            if showsDisclosureIndicator {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isSelected ? Color.conduitAccent : Color.secondary.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isSelected ? Color.conduitAccent.opacity(0.15) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isSelected ? Color.conduitAccent.opacity(0.34) : Color.white.opacity(0.08), lineWidth: 1)
        }
        .animation(ConduitMotion.response, value: isSelected)
    }
}

private extension View {
    /// Attaches a context menu only when there is something in it, so a
    /// row with no actions (Home, auto-discovered repos) gets no empty
    /// long-press preview.
    @ViewBuilder
    func projectActionsMenu<MenuItems: View>(
        isEnabled: Bool,
        @ViewBuilder menuItems: () -> MenuItems
    ) -> some View {
        if isEnabled {
            contextMenu(menuItems: menuItems)
        } else {
            self
        }
    }
}

/// A conversation's touch-and-hold actions, shared by the main session list,
/// a project's conversation list and the open chat's title, so all three
/// offer the same menu. Rename and Delete need a host-owned sheet or alert,
/// so the host supplies those two actions.
struct SessionActionMenuItems: View {
    @EnvironmentObject private var appState: AppState
    let session: SessionSummary
    var excludingProjectID: String? = nil
    let onRename: () -> Void
    let onDelete: () -> Void
    /// Runs after a mutation that changes which list the row belongs in.
    var onChanged: () -> Void = {}

    var body: some View {
        Button {
            Haptics.selection()
            // Next turn, once the menu has started closing: the rename sheet
            // isn't presented in the same update as the menu's dismissal.
            DispatchQueue.main.async { onRename() }
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        .disabled(appState.isSessionMutationInFlight(session))

        Button {
            Haptics.light()
            appState.toggleSessionPinned(session)
        } label: {
            Label(appState.isSessionPinned(session) ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"), systemImage: appState.isSessionPinned(session) ? "pin.slash" : "pin")
        }

        ReadStateToggleButton(session: session)

        // A cron run keeps the job's workspace (#485).
        if session.source != .cron {
            MoveToProjectMenu(session: session, excludingProjectID: excludingProjectID, onMoved: onChanged)
        }

        Button {
            Task {
                let archived = await appState.archiveSession(session)
                Haptics.mutationCompleted(archived)
                if archived { onChanged() }
            }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .disabled(appState.isSessionMutationInFlight(session))

        Button(role: .destructive) {
            Haptics.warning()
            onDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(appState.isSessionMutationInFlight(session))
    }
}

/// Mark as read / Mark as unread for one conversation (#454). Writes Hermes'
/// shared read flag too, so Hermes Desktop follows.
struct ReadStateToggleButton: View {
    @EnvironmentObject private var appState: AppState
    let session: SessionSummary

    var body: some View {
        let isUnread = appState.isSessionUnread(session)
        Button {
            Haptics.light()
            if isUnread {
                appState.markSessionRead(session)
            } else {
                appState.markSessionUnread(session)
            }
        } label: {
            Label(
                isUnread ? AppLocalization.string("Mark as read") : AppLocalization.string("Mark as unread"),
                systemImage: isUnread ? "envelope.open" : "envelope.badge"
            )
        }
    }
}

/// Quick status filters in the session list (#454).
enum SessionStatusFilter: String, CaseIterable, Identifiable {
    case needsInput
    case working
    case unread

    var id: String { rawValue }

    /// Filled from the gateway's `session.active_list`, not from local state.
    var isLive: Bool { self != .unread }

    var title: String {
        switch self {
        case .needsInput: return AppLocalization.string("Needs input")
        case .working: return AppLocalization.string("Working")
        case .unread: return AppLocalization.string("Unread")
        }
    }

    var color: Color {
        switch self {
        case .needsInput: return .orange
        case .working: return .green
        case .unread: return .blue
        }
    }

    var accessibilityHint: String {
        switch self {
        case .needsInput: return AppLocalization.string("Shows only chats waiting on your answer or approval")
        case .working: return AppLocalization.string("Shows only chats where Hermes is working")
        case .unread: return AppLocalization.string("Shows only chats with replies you haven't seen")
        }
    }

    var emptyTitle: String {
        switch self {
        case .needsInput: return AppLocalization.string("Nothing Needs You")
        case .working: return AppLocalization.string("Nothing Running")
        case .unread: return AppLocalization.string("No Unread Chats")
        }
    }

    var emptyDescription: String {
        switch self {
        case .needsInput: return AppLocalization.string("No chat is waiting on your answer.")
        case .working: return AppLocalization.string("No chat has a reply in progress.")
        case .unread: return AppLocalization.string("You're all caught up.")
        }
    }

    var emptySystemImage: String {
        switch self {
        case .needsInput: return "checkmark.bubble"
        case .working: return "moon.zzz"
        case .unread: return "envelope.open"
        }
    }
}

/// The session row's "Move to Project" submenu. Hidden when the gateway has
/// no projects capability or no project with a folder to move into.
struct MoveToProjectMenu: View {
    @EnvironmentObject private var appState: AppState
    let session: SessionSummary
    var excludingProjectID: String? = nil
    var onMoved: () -> Void = {}

    var body: some View {
        let currentProjectID = excludingProjectID ?? appState.knownProjectID(for: session)
        let targets = appState.projectMoveTargets.filter { $0.id != currentProjectID }
        if !targets.isEmpty {
            Menu {
                ForEach(targets) { project in
                    Button(project.title) {
                        Haptics.selection()
                        Task {
                            let moved = await appState.moveSession(session, to: project)
                            Haptics.mutationCompleted(moved)
                            if moved { onMoved() }
                        }
                    }
                }
            } label: {
                Label(AppLocalization.string("Move to Project"), systemImage: "folder")
            }
            // `moveSession` refuses while ANY conversation mutation runs.
            .disabled(appState.sessionMutationID != nil)
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: project.isHome ? "house.fill" : "folder.fill")
                .font(.caption.weight(.semibold))
                .conduitFixedGlyph()
                .foregroundStyle(project.isHome ? Color.conduitAccent : .orange)
                .frame(width: 30, height: 30)
                .background((project.isHome ? Color.conduitAccent : .orange).opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text("\(project.sessionCount) conversations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.secondary.opacity(0.45))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct ProjectSessionsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let project: ProjectSummary
    @State private var detail: ProjectSessionDetail?
    @State private var isLoading = true
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingRename: SessionSummary?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                List {
                    if isLoading {
                        ProgressView("Loading conversations…")
                            .frame(maxWidth: .infinity, minHeight: 140)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else if let detail, detail.lanes.isEmpty {
                        ContentUnavailableView {
                            Label("No Conversations", systemImage: "tray")
                        } description: {
                            Text("This project does not have any conversations yet.")
                        } actions: {
                            if newConversationPath != nil {
                                Button("New conversation", action: startNewConversation)
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else if let detail {
                        ForEach(detail.lanes) { lane in
                            Section(lane.title) {
                                ForEach(lane.sessions) { session in
                                    Button {
                                        appState.dismissSidebarDrawer()
                                        dismiss()
                                        appState.requestOpenSession(session.id)
                                    } label: {
                                        SessionRow(
                                            session: session,
                                            isSelected: session.id == appState.activeSessionId,
                                            isPinned: appState.isSessionPinned(session),
                                            isUnread: appState.isSessionUnread(session),
                                            liveStatus: appState.sessionLiveStatus(session),
                                            isVoiceJob: appState.isVoiceJobSession(session),
                                            category: appState.sessionCategory(for: session),
                                            detail: appState.voiceSessionDetail(for: session)
                                        )
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Swipe or touch and hold for conversation actions.")
                                    .contextMenu {
                                        SessionActionMenuItems(
                                            session: session,
                                            excludingProjectID: project.id,
                                            onRename: { sessionPendingRename = session },
                                            onDelete: { sessionPendingDeletion = session },
                                            onChanged: reloadDetail
                                        )
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            Haptics.light()
                                            appState.toggleSessionPinned(session)
                                        } label: {
                                            Label(appState.isSessionPinned(session) ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"), systemImage: appState.isSessionPinned(session) ? "pin.slash" : "pin")
                                        }
                                        .tint(.conduitAccent)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button {
                                            Task {
                                                let archived = await appState.archiveSession(session)
                                                Haptics.mutationCompleted(archived)
                                                if archived { reloadDetail() }
                                            }
                                        } label: {
                                            Label("Archive", systemImage: "archivebox")
                                        }
                                        .tint(.orange)
                                        .disabled(appState.isSessionMutationInFlight(session))

                                        Button(role: .destructive) {
                                            Haptics.warning()
                                            sessionPendingDeletion = session
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .disabled(appState.isSessionMutationInFlight(session))
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
            .navigationTitle(project.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if newConversationPath != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: startNewConversation) {
                            Image(systemName: "plus.bubble")
                        }
                        .accessibilityLabel("New conversation in \(project.title)")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: project.id) {
            isLoading = true
            detail = await appState.loadProjectSessions(project)
            isLoading = false
        }
        .alert("Delete conversation?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let session = sessionPendingDeletion else { return }
                sessionPendingDeletion = nil
                Task {
                    if await appState.deleteSession(session) { reloadDetail() }
                }
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("This permanently deletes the conversation and cannot be undone.")
        }
        .sheet(item: $sessionPendingRename) { session in
            RenameSheet.conversation(session) { title in
                Task {
                    if await appState.renameSession(session, to: title) { reloadDetail() }
                }
            }
        }
    }

    private func reloadDetail() {
        Task { detail = await appState.loadProjectSessions(project) }
    }

    private var newConversationPath: String? {
        guard let path = project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }

    private func startNewConversation() {
        guard let path = newConversationPath else { return }
        appState.dismissSidebarDrawer()
        dismiss()
        Task { await appState.createNewSession(cwd: path) }
    }
}

private struct ProjectCreateSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folders: [String] = []
    @State private var idea = ""
    @State private var showFolderPicker = false
    @State private var isCreating = false
    @State private var validationMessage: String?

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folders.isEmpty && !isCreating
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                Form {
                    Section {
                        TextField("e.g. Skunkworks", text: $name)
                            .textInputAutocapitalization(.words)
                    } header: {
                        Text("Name")
                    } footer: {
                        Text("Name a workspace and add one or more folders.")
                    }

                    Section("Folders") {
                        if folders.isEmpty {
                            Text("No folders added yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(folders, id: \.self) { folder in
                            Label(folder, systemImage: "folder.fill")
                                .lineLimit(1)
                        }
                        .onDelete { folders.remove(atOffsets: $0) }

                        Button {
                            validationMessage = nil
                            guard !appState.projectFolderPickerRoot.isEmpty else {
                                validationMessage = AppLocalization.string("Open a chat with a workspace before choosing a project folder.")
                                return
                            }
                            showFolderPicker = true
                        } label: {
                            Label("Add folder", systemImage: "plus")
                        }
                    }

                    Section {
                        TextEditor(text: $idea)
                            .frame(minHeight: 120)
                    } header: {
                        Text("Idea (optional)")
                    } footer: {
                        Text("Saved as IDEA.md in the first folder, just like Hermes Desktop.")
                    }

                    if let validationMessage {
                        Section {
                            Label(validationMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await createProject() }
                    } label: {
                        if isCreating { ProgressView() } else { Text("Create") }
                    }
                    .disabled(!canCreate)
                }
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            ProjectFolderPickerSheet(rootPath: appState.projectFolderPickerRoot) { folder in
                if !folders.contains(folder) { folders.append(folder) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func createProject() async {
        isCreating = true
        validationMessage = nil
        let created = await appState.createProject(name: name, folders: folders, idea: idea)
        isCreating = false
        if created {
            dismiss()
        } else if validationMessage == nil {
            validationMessage = AppLocalization.string("Hermes could not create this project.")
        }
    }
}

private struct ProjectFolderPickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let rootPath: String
    let onChoose: (String) -> Void
    @State private var currentPath = ""
    @State private var entries: [WorkspaceEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                List {
                    Section {
                        Text(currentPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if isLoading {
                        ProgressView("Loading folders…")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if let errorMessage {
                        ContentUnavailableView(
                            "Folder unavailable",
                            systemImage: "folder.badge.questionmark",
                            description: Text(errorMessage)
                        )
                    } else {
                        ForEach(entries.filter(\.isDirectory)) { entry in
                            Button {
                                Task { await open(entry.path) }
                            } label: {
                                Label(entry.name, systemImage: "folder.fill")
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Choose Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose") {
                        onChoose(currentPath)
                        dismiss()
                    }
                    .disabled(currentPath.isEmpty || isLoading)
                }
            }
        }
        .task {
            await open(rootPath)
        }
    }

    private func open(_ path: String) async {
        isLoading = true
        errorMessage = nil
        currentPath = path
        do {
            entries = try await appState.workspaceDirectoryEntries(at: path)
        } catch {
            entries = []
            errorMessage = UserFacingError.message(for: error)
        }
        isLoading = false
    }
}

// MARK: - Cron List

struct CronList: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedJob: CronJob?
    /// The Jobs list shows a few rows until expanded (#485), so the runs
    /// below it stay in reach.
    @AppStorage("conduit.cronJobsShowAll") private var showAllJobs = false
    @AppStorage("conduit.cronJobsFilter") private var jobFilterRaw = CronJobFilter.all.rawValue

    private var jobFilter: Binding<CronJobFilter> {
        Binding(
            get: { CronJobFilter(rawValue: jobFilterRaw) ?? .all },
            set: { jobFilterRaw = $0.rawValue }
        )
    }

    var body: some View {
        let jobs = CronJobFilter.visibleJobs(appState.cronJobs, filter: jobFilter.wrappedValue, query: searchText)
        List {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scheduled jobs").font(.headline)
                    if appState.cronJobs.isEmpty {
                        Text("\(appState.cronJobs.count) configured").font(.caption).foregroundStyle(.secondary)
                    } else {
                        // Two counts, so two plurals: each agrees with its own number.
                        Text(verbatim: AppLocalization.string("\(activeJobCount) active") + " · " + AppLocalization.string("\(inactiveJobCount) inactive"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if appState.cronJobsLoading { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            if !appState.cronJobs.isEmpty {
                Picker("Show jobs", selection: jobFilter) {
                    ForEach(CronJobFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if jobs.isEmpty && !appState.cronJobsLoading {
                let empty = CronJobFilter.emptyState(
                    filter: jobFilter.wrappedValue,
                    hasJobs: !appState.cronJobs.isEmpty,
                    isSearching: isSearching
                )
                ContentUnavailableView(empty.title, systemImage: "clock", description: Text(empty.description))
            }

            if !jobs.isEmpty {
                let shown = CronJobFilter.shownJobs(jobs, showAll: showAllJobs, isSearching: isSearching)
                HStack {
                    Text("Jobs").font(.headline)
                    Spacer()
                    Text("\(jobs.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                ForEach(shown) { job in
                    Button { selectedJob = job } label: { CronJobRow(job: job) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if !isSearching && jobs.count > CronJobFilter.collapsedRowCount {
                    Button {
                        Haptics.selection()
                        withAnimation(ConduitMotion.response) { showAllJobs.toggle() }
                    } label: {
                        Label(
                            showAllJobs
                                ? AppLocalization.string("Show fewer")
                                : AppLocalization.string("Show \(jobs.count - shown.count) more"),
                            systemImage: showAllJobs ? "chevron.up" : "chevron.down"
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.conduitAccent)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            if !appState.activeProfileCronSessions.isEmpty {
                Section("Recent runs") {
                    ForEach(appState.activeProfileCronSessions.prefix(20)) { session in
                        let isPinned = appState.isSessionPinned(session)
                        Button {
                            appState.dismissSidebarDrawer()
                            appState.requestOpenSession(session.id)
                        } label: {
                            SessionRow(session: session, isSelected: session.id == appState.activeSessionId, isPinned: isPinned).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Swipe or touch and hold for conversation actions.")
                        // A pinned run sits at the top of the Sessions list (#485).
                        .contextMenu {
                            pinButton(session, isPinned: isPinned)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            pinButton(session, isPinned: isPinned)
                                .tint(.conduitAccent)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: AppLocalization.string("Search scheduled jobs"))
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .task(id: appState.activeProfile) { await appState.refreshCronContent() }
        .refreshable { await appState.refreshCronContent() }
        .sheet(item: $selectedJob) { CronJobDetailSheet(job: $0) }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func pinButton(_ session: SessionSummary, isPinned: Bool) -> some View {
        Button {
            Haptics.light()
            appState.toggleSessionPinned(session)
        } label: {
            Label(isPinned ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"), systemImage: isPinned ? "pin.slash" : "pin")
        }
    }

    private var activeJobCount: Int {
        appState.cronJobs.filter(\.isActive).count
    }

    private var inactiveJobCount: Int {
        appState.cronJobs.count - activeJobCount
    }
}

/// The Cron tab's Active / Inactive / All filter (#392). A job is active
/// while it will run on its own (`CronJob.isActive`); paused jobs and
/// finished one-shot jobs are inactive. Every filter lists active jobs
/// first, then by name, so the running ones are never buried under a long
/// tail of paused ones.
enum CronJobFilter: String, CaseIterable, Identifiable {
    case active
    case inactive
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: AppLocalization.string("Active")
        case .inactive: AppLocalization.string("Inactive")
        case .all: AppLocalization.string("All")
        }
    }

    func includes(_ job: CronJob) -> Bool {
        switch self {
        case .active: job.isActive
        case .inactive: !job.isActive
        case .all: true
        }
    }

    /// The jobs the Cron list shows: the ones this filter keeps that match
    /// the search field, active first, then by name.
    static func visibleJobs(_ jobs: [CronJob], filter: CronJobFilter, query: String) -> [CronJob] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return jobs
            .filter { filter.includes($0) && (query.isEmpty || matches($0, query: query)) }
            .sorted(by: listOrder)
    }

    /// Rows the collapsed Jobs list shows (#485).
    static let collapsedRowCount = 3

    /// A search shows every match; otherwise the list stays collapsed to
    /// its first rows until expanded.
    static func shownJobs(_ jobs: [CronJob], showAll: Bool, isSearching: Bool) -> [CronJob] {
        showAll || isSearching ? jobs : Array(jobs.prefix(collapsedRowCount))
    }

    static func matches(_ job: CronJob, query: String) -> Bool {
        [job.displayName, job.prompt ?? "", job.scheduleDisplay ?? job.schedule?.display ?? "", job.deliver ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func listOrder(_ lhs: CronJob, _ rhs: CronJob) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }

    /// What the list says when nothing is left to show: no jobs at all, no
    /// search match, or nothing under the chosen filter.
    static func emptyState(filter: CronJobFilter, hasJobs: Bool, isSearching: Bool) -> (title: String, description: String) {
        if hasJobs && isSearching {
            let hint = filter == .all
                ? AppLocalization.string("Try a different search.")
                : AppLocalization.string("Try a different search or filter.")
            return (AppLocalization.string("No Matching Jobs"), hint)
        }
        switch filter {
        case .active where hasJobs:
            return (AppLocalization.string("No Active Jobs"), AppLocalization.string("Every scheduled job is paused or finished."))
        case .inactive where hasJobs:
            return (AppLocalization.string("No Inactive Jobs"), AppLocalization.string("Every scheduled job is active."))
        default:
            // No jobs at all. All with jobs and no search always lists them.
            return (AppLocalization.string("No Scheduled Jobs"), AppLocalization.string("Scheduled jobs from Hermes appear here."))
        }
    }
}

private struct CronJobRow: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let job: CronJob
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "clock")
                .conduitFixedGlyph()
                .foregroundStyle(job.isActive ? .green : .secondary)
                .frame(width: 30, height: 30).background((job.isActive ? Color.green : .secondary).opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(job.scheduleDisplay ?? job.schedule?.display ?? job.schedule?.expr ?? AppLocalization.string("No schedule"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(job.statusLabel).font(.caption2.weight(.semibold)).foregroundStyle(job.isActive ? .green : .secondary)
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct CronJobDetailSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// The job as it was tapped; `job` follows the live list so Pause and
    /// Resume flip the sheet as soon as Hermes answers.
    let selectedJob: CronJob

    init(job: CronJob) {
        selectedJob = job
    }

    private var job: CronJob {
        appState.cronJobs.first { $0.id == selectedJob.id } ?? selectedJob
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ConduitSettingsSection(title: job.displayName, symbol: "clock.fill", tint: .conduitAccent) {
                            SettingsMetricRow(label: AppLocalization.string("Status"), value: job.statusLabel)
                            SettingsMetricRow(label: AppLocalization.string("Schedule"), value: job.scheduleDisplay ?? job.schedule?.display ?? job.schedule?.expr ?? "—")
                            SettingsMetricRow(label: AppLocalization.string("Next run"), value: job.isFinished ? "—" : job.nextRunAt ?? "—")
                            SettingsMetricRow(label: AppLocalization.string("Last run"), value: job.lastRunAt ?? "—")
                            SettingsMetricRow(label: AppLocalization.string("Delivery"), value: job.deliver ?? AppLocalization.string("Local"))
                        }
                        AdaptiveStack(spacing: 10) {
                            // A finished one-shot job has nothing left to pause
                            // or resume.
                            if !job.isFinished {
                                Button { Task { _ = await appState.performCronAction(job.enabled ? .pause : .resume, for: job) } } label: {
                                    Label(job.enabled ? AppLocalization.string("Pause") : AppLocalization.string("Resume"), systemImage: job.enabled ? "pause.fill" : "play.fill").frame(maxWidth: .infinity)
                                }
                                .disabled(appState.cronJobActionID != nil)
                                .frame(minHeight: 48)
                                .conduitGlassControl(cornerRadius: 16, tint: .orange.opacity(0.18))
                            }
                            Button { Task { _ = await appState.performCronAction(.trigger, for: job); await appState.loadCronRuns(for: job) } } label: {
                                Label(appState.cronJobActionID == job.id ? AppLocalization.string("Working…") : AppLocalization.string("Run now"), systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(Color.white)
                            }
                            .disabled(appState.cronJobActionID != nil)
                            .frame(minHeight: 48)
                            .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent, prominent: true)
                        }
                        .font(.subheadline.weight(.semibold))
                        if let prompt = job.prompt, !prompt.isEmpty {
                            ConduitSettingsSection(title: AppLocalization.string("Prompt"), symbol: "text.quote", tint: .conduitAura) { Text(prompt).textSelection(.enabled).font(.callout) }
                        }
                        ConduitSettingsSection(title: AppLocalization.string("Run history"), symbol: "clock.arrow.circlepath", tint: .conduitAura) {
                            if appState.cronRuns.isEmpty { Text("This job has not run yet.").font(.footnote).foregroundStyle(.secondary) }
                            ForEach(appState.cronRuns) { run in
                                Button { appState.dismissSidebarDrawer(); dismiss(); appState.requestOpenSession(run.id) } label: {
                                    HStack { VStack(alignment: .leading) { Text(run.title ?? run.preview ?? run.id).lineLimit(1); Text(run.model ?? "Hermes").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(run.lastActive.map(String.init) ?? "").font(.caption2).foregroundStyle(.tertiary) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Scheduled job"), close: { dismiss() })
            }
        }
        .task { await appState.loadCronRuns(for: job) }
    }
}

/// Which rows a Sessions source filter lists (#485). Cron runs stay out of
/// All and the other filters, like Hermes Desktop's main list: Cron lists
/// every run, and a pinned run joins All at the top so it works like any
/// pinned chat.
enum SidebarSourceRows {
    static func rows(
        sessions: [SessionSummary],
        cronSessions: [SessionSummary],
        source: SessionSource?,
        category: (SessionSummary) -> SessionSource,
        isPinned: (SessionSummary) -> Bool
    ) -> [SessionSummary] {
        let chats = sessions.filter { !$0.isArchived }
        let runs = cronSessions.filter { !$0.isArchived }
        switch source {
        case nil:
            return runs.filter(isPinned) + chats
        case .cron?:
            return runs
        case let source?:
            return chats.filter { category($0) == source }
        }
    }
}

/// The Projects view's Pinned section (#338): every non-archived pinned chat
/// in the profile, pinned cron runs included (#485), whatever its project or
/// source, narrowed by the search field like the project list below it.
enum SidebarPinnedSessions {
    static func forProjectsView(
        _ sessions: [SessionSummary],
        query: String,
        isPinned: (SessionSummary) -> Bool,
        matches: (SessionSummary, String) -> Bool
    ) -> [SessionSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            !session.isArchived && isPinned(session) && (query.isEmpty || matches(session, query))
        }
    }
}

/// Which session-list parts the sidebar shows while a saved offline copy
/// (#99) may be up. The saved section never replaces the live sections: a
/// live catalog published before the live transcript replaces the copy (the
/// owed-bootstrap window) renders alongside it.
enum SidebarOfflineLayout {
    struct Visibility: Equatable {
        let savedSection: Bool
        let liveSections: Bool
        let emptyState: Bool
    }

    static func visibility(
        showingProjects: Bool,
        hasOfflineCopy: Bool,
        displayedSessionsEmpty: Bool
    ) -> Visibility {
        Visibility(
            savedSection: !showingProjects && hasOfflineCopy,
            liveSections: !showingProjects,
            emptyState: !showingProjects && !hasOfflineCopy && displayedSessionsEmpty
        )
    }
}

/// Renaming a conversation or project. A sheet rather than an alert with a
/// text field: an alert presented from a row's touch-and-hold menu inside
/// the sessions drawer could leave its field unable to take typing, then
/// hang the app (TestFlight 0.1.16 build 174). The draft is this sheet's own
/// state, so each keystroke redraws only the sheet, never the session list
/// behind it.
struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    /// Returns the name to commit, or nil while the draft can't be saved
    /// (empty, or unchanged).
    let normalize: @MainActor (String) -> String?
    let onRename: @MainActor (String) -> Void
    private let initialText: String
    @State private var draft: String
    @State private var isCommitting = false
    @FocusState private var fieldFocused: Bool

    init(
        title: String,
        placeholder: String,
        initialText: String,
        normalize: @escaping @MainActor (String) -> String?,
        onRename: @escaping @MainActor (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.normalize = normalize
        self.onRename = onRename
        self.initialText = initialText
        _draft = State(initialValue: initialText)
    }

    static func conversation(_ session: SessionSummary, onRename: @escaping @MainActor (String) -> Void) -> RenameSheet {
        RenameSheet(
            title: AppLocalization.string("Rename conversation"),
            placeholder: AppLocalization.string("Conversation title"),
            initialText: session.title,
            normalize: { SessionRenameOperation.normalizedTitle($0, currentTitle: session.title) },
            onRename: onRename
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(placeholder, text: $draft)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .onSubmit(commit)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename", action: commit)
                        .disabled(isCommitting || normalize(draft) == nil)
                }
            }
        }
        // Medium, not a fixed height: at accessibility text sizes the field
        // and toolbar must stay reachable.
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task {
            // A focus request made while the sheet is still sliding in (over
            // the drawer sheet) can be dropped; ask again once it settles.
            fieldFocused = true
            try? await Task.sleep(for: .milliseconds(400))
            // Only while unfocused and untouched: once the user has typed,
            // focus is theirs.
            guard !Task.isCancelled, !fieldFocused, draft == initialText else { return }
            fieldFocused = true
        }
    }

    private func commit() {
        // Return and the button can both land while the sheet slides out.
        guard !isCommitting, let name = normalize(draft) else { return }
        isCommitting = true
        dismiss()
        onRename(name)
    }
}
