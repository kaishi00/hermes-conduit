//
//  V2ChatsView.swift
//  Conduit
//
//  Chats: the dense session list (Pinned, Recent, child sessions under
//  their parent) and, behind the folder toggle, Projects. The filter is a
//  native pull-down menu; an active filter shows as a gold chip in the
//  search field. Rows keep the old drawer's swipes and context menu.
//

import SwiftUI

/// The Chats filter menu. Status filters flatten the list to matching rows;
/// Voice and Scheduled keep it nested, like the old source filters.
enum V2SessionFilter: Equatable, Hashable {
    case all
    case unread
    case needsApproval
    case running
    case voice
    case scheduled
    case source(SessionSource)

    static let menuCases: [V2SessionFilter] = [.all, .unread, .needsApproval, .running, .voice, .scheduled]

    init(rawValue: String) {
        switch rawValue {
        case "unread": self = .unread
        case "needsApproval": self = .needsApproval
        case "running": self = .running
        case "voice": self = .voice
        case "scheduled": self = .scheduled
        default:
            if rawValue.hasPrefix("source."),
               let source = SessionSource(rawValue: String(rawValue.dropFirst("source.".count))) {
                self = .source(source)
            } else {
                self = .all
            }
        }
    }

    var rawValue: String {
        switch self {
        case .all: return "all"
        case .unread: return "unread"
        case .needsApproval: return "needsApproval"
        case .running: return "running"
        case .voice: return "voice"
        case .scheduled: return "scheduled"
        case .source(let source): return "source.\(source.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .all: return AppLocalization.string("All")
        case .unread: return AppLocalization.string("Unread")
        case .needsApproval: return AppLocalization.string("Needs approval")
        case .running: return AppLocalization.string("Running")
        case .voice: return AppLocalization.string("Voice")
        case .scheduled: return AppLocalization.string("Scheduled")
        case .source(let source): return source.label
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .unread: return "circle.fill"
        case .needsApproval: return "checkmark.shield"
        case .running: return "arrow.triangle.2.circlepath"
        case .voice: return "waveform"
        case .scheduled: return "clock"
        case .source(let source): return source.iconName
        }
    }

    /// Needs approval and Running come from the gateway's live registry.
    var isLive: Bool { self == .needsApproval || self == .running }

    /// A lookup, not a browse: the list flattens to the matching rows.
    var flattens: Bool { self == .unread || isLive }

    var emptyTitle: String {
        switch self {
        case .unread: return SessionStatusFilter.unread.emptyTitle
        case .needsApproval: return SessionStatusFilter.needsInput.emptyTitle
        case .running: return SessionStatusFilter.working.emptyTitle
        default: return AppLocalization.string("No Sessions")
        }
    }

    var emptyDescription: String {
        switch self {
        case .unread: return SessionStatusFilter.unread.emptyDescription
        case .needsApproval: return SessionStatusFilter.needsInput.emptyDescription
        case .running: return SessionStatusFilter.working.emptyDescription
        default: return AppLocalization.string("Sessions will appear here once created.")
        }
    }
}

struct V2ChatsView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var showArchivedSessions = false
    @State private var showProjectCreator = false
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingRename: SessionSummary?
    @State private var projectPendingRename: ProjectSummary?
    @State private var projectPendingDeletion: ProjectSummary?
    /// The last activation the reveal served (NestRevealLatch).
    @State private var revealLatch = NestRevealLatch()
    @AppStorage("conduit.sessionPresentation") private var sessionPresentationRaw = "sessions"
    @AppStorage("conduit.v2.sessionFilter") private var filterRaw = "all"
    /// Expanded parents, remembered per parent across launches.
    @AppStorage("conduit.v2.expandedNests") private var expandedNestsRaw = ""
    /// Parsed once per change of the store, not once per parent row.
    @State private var expansionCache = V2NestExpansionCache()

    private var showingProjects: Bool { sessionPresentationRaw == "projects" }

    /// A live filter saved while the gateway can't report live status reads
    /// as All, so the list doesn't empty out behind a filter nobody can see.
    private var filter: V2SessionFilter {
        let saved = V2SessionFilter(rawValue: filterRaw)
        if saved.isLive && !appState.liveSessionStatusAvailable { return .all }
        return saved
    }

    var body: some View {
        ZStack {
            V2Backdrop()
            Group {
                if showingProjects {
                    projectsList
                } else {
                    sessionsList
                }
            }
            .opacity(shell.contentFaded ? 0 : 1)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            V2TopBar { trailingControls }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MinimisedLiveVoiceBar()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(V2Tab.chats.title)
        .sheet(isPresented: $showArchivedSessions) {
            ArchivedSessionsSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showProjectCreator) {
            ProjectCreateSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .environmentObject(appState)
        }
        // V2 opens on this list, often before the gateway connects: a load
        // then has no client, so Projects loads once it connects, and again
        // each time Projects is shown. The session catalog's own load keeps
        // the project list fresh behind Sessions.
        .task(id: "\(appState.activeProfile)|\(appState.isConnected)|\(showingProjects)|\(shell.isTabActive)") {
            guard appState.isConnected, showingProjects, shell.isTabActive else { return }
            await appState.refreshProjects()
        }
        // Running and Needs approval follow the gateway's live registry
        // while the list is on screen; a hidden tab or a conversation
        // pushed over the list stops polling.
        .task(id: "\(appState.activeProfile)|\(shell.isTabActive)|\(appState.showSidebar)") {
            guard shell.isTabActive, appState.showSidebar else { return }
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

    // MARK: - Top bar controls

    /// One glass capsule: Sessions/Projects toggle, Filter (amber dot while
    /// approvals wait), New chat.
    private var trailingControls: some View {
        V2ControlCapsule {
            Button {
                Haptics.selection()
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
                    sessionPresentationRaw = showingProjects ? "sessions" : "projects"
                }
            } label: {
                V2CapsuleIcon(systemImage: "folder", tint: showingProjects ? Color.conduitAccent : nil)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(showingProjects ? AppLocalization.string("Show sessions") : AppLocalization.string("Browse projects"))

            filterMenu

            Button {
                Haptics.medium()
                appState.dismissSidebarDrawer()
                Task { await appState.createNewSession() }
            } label: {
                V2CapsuleIcon(systemImage: "square.and.pencil")
            }
            .buttonStyle(PressableButtonStyle())
            // The saved copy has no live gateway to create a chat on.
            .disabled(appState.turnState == .synchronizing || appState.offlineChatPresentation != nil)
            .accessibilityLabel(AppLocalization.string("New Chat"))
        }
    }

    private var waitingApprovalCount: Int {
        guard appState.liveSessionStatusAvailable else { return 0 }
        return sourceRows(nil).filter { appState.sessionLiveStatus($0) == .needsInput }.count
    }

    private var filterMenu: some View {
        Menu {
            if showingProjects {
                Button {
                    Haptics.selection()
                    showProjectCreator = true
                } label: {
                    Label("New project", systemImage: "folder.badge.plus")
                }
                .disabled(!appState.supportsProjects)
            } else {
                Picker(selection: Binding(
                    get: { filter.rawValue },
                    set: { raw in
                        Haptics.selection()
                        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { filterRaw = raw }
                    }
                )) {
                    ForEach(visibleFilters, id: \.self) { option in
                        Label("\(option.title) \(String(filterRows(option).count))", systemImage: option.symbol)
                            .tag(option.rawValue)
                    }
                    if !otherSources.isEmpty {
                        Section(AppLocalization.string("Sources")) {
                            ForEach(otherSources, id: \.self) { source in
                                let option = V2SessionFilter.source(source)
                                Label("\(option.title) \(String(filterRows(option).count))", systemImage: option.symbol)
                                    .tag(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Text("Filter")
                }
                .pickerStyle(.inline)

                Section {
                    Button {
                        Haptics.selection()
                        showArchivedSessions = true
                    } label: {
                        Label("Archived", systemImage: "archivebox")
                    }
                    Button {
                        Haptics.light()
                        appState.markAllSessionsRead()
                    } label: {
                        Label("Mark all as read", systemImage: "envelope.open")
                    }
                    .disabled(!sourceRows(nil).contains { appState.isSessionUnread($0) })
                }
            }
        } label: {
            V2CapsuleIcon(
                systemImage: filter == .all
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill",
                dot: waitingApprovalCount > 0 ? Color.conduitAttention : nil
            )
        }
        .menuOrder(.fixed)
        .accessibilityLabel(AppLocalization.string("Filter"))
        .accessibilityValue(waitingApprovalCount > 0
            ? AppLocalization.string("\(waitingApprovalCount) waiting for approval")
            : filter.title)
    }

    private var visibleFilters: [V2SessionFilter] {
        V2SessionFilter.menuCases.filter { !$0.isLive || appState.liveSessionStatusAvailable }
    }

    /// Sources beyond Voice and Scheduled that have rows, in the user's order.
    private var otherSources: [SessionSource] {
        appState.sessionFilterOrder.filter { source in
            source != .voice && source != .cron && !sourceRows(source).isEmpty
        }
    }

    // MARK: - Rows

    /// The rows a source lists (cron runs only under Scheduled, plus the
    /// pinned ones in All, #485).
    private func sourceRows(_ source: SessionSource?) -> [SessionSummary] {
        SidebarSourceRows.rows(
            sessions: appState.activeProfileSessions,
            cronSessions: appState.activeProfileCronSessions,
            source: source,
            category: appState.sessionCategory,
            isPinned: appState.isSessionPinned
        )
    }

    private func filterRows(_ filter: V2SessionFilter) -> [SessionSummary] {
        switch filter {
        case .all: return mainListRows(sourceRows(nil))
        case .unread: return sourceRows(nil).filter { appState.isSessionUnread($0) }
        case .needsApproval: return sourceRows(nil).filter { appState.sessionLiveStatus($0) == .needsInput }
        case .running: return sourceRows(nil).filter { appState.sessionLiveStatus($0) == .working }
        case .voice: return sourceRows(.voice)
        case .scheduled: return sourceRows(.cron)
        case .source(let source): return sourceRows(source)
        }
    }

    /// A project's conversations live on its page, not in the main list;
    /// a pinned one stays, since pinning asks for it here. The catalog
    /// carries no folder, so this hides the conversations the project tree
    /// is known to hold.
    private func mainListRows(_ rows: [SessionSummary]) -> [SessionSummary] {
        guard appState.supportsProjects else { return rows }
        return rows.filter { appState.isSessionPinned($0) || appState.knownProjectID(for: $0) == nil }
    }

    private var displayedSessions: [SessionSummary] {
        let rows = filterRows(filter)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter { sessionMatches($0, query: query) }
    }

    private func sessionMatches(_ session: SessionSummary, query: String) -> Bool {
        [session.title, session.model, session.id, session.preview ?? "", appState.sessionCategory(for: session).label]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var nestedSections: (pinned: [SessionNesting.Node], recent: [SessionNesting.Node]) {
        SessionNesting.sections(
            displayedSessions,
            query: searchText,
            statusFilterActive: filter.flattens,
            isPinned: appState.isSessionPinned,
            parentKeyOf: appState.sessionNestingParentKey
        )
    }

    // MARK: - Sessions list

    private var sessionsList: some View {
        let sections = nestedSections
        let layout = SidebarOfflineLayout.visibility(
            showingProjects: false,
            hasOfflineCopy: appState.offlineChatPresentation != nil,
            displayedSessionsEmpty: displayedSessions.isEmpty
        )
        return List {
            searchField
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

            if layout.savedSection, let offline = appState.offlineChatPresentation {
                Section {
                    ForEach(offline.snapshot.sessions) { session in
                        offlineSessionRow(session, presentation: offline)
                    }
                } header: {
                    sectionHeader(AppLocalization.string("Saved on this device"))
                } footer: {
                    Text("Read-only copies from your last connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if layout.emptyState {
                ContentUnavailableView(
                    filter.emptyTitle,
                    systemImage: "tray",
                    description: Text(isSearching
                        ? AppLocalization.string("Try a different search.")
                        : filter.emptyDescription)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if layout.liveSections && !sections.pinned.isEmpty {
                Section {
                    nestRows(sections.pinned)
                } header: {
                    sectionHeader(AppLocalization.string("Pinned"))
                }
            }

            if layout.liveSections && !sections.recent.isEmpty {
                Section {
                    nestRows(sections.recent)
                } header: {
                    sectionHeader(AppLocalization.string("Recent"))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .refreshable {
            await appState.refreshSessionCatalog()
        }
        .onAppear { revealActiveNestAncestors() }
        .onChange(of: appState.activeSessionId) { _, _ in revealActiveNestAncestors() }
        .onChange(of: displayedSessions) { _, _ in revealActiveNestAncestors() }
        .onChange(of: appState.pinnedSessionIDs) { _, _ in revealActiveNestAncestors() }
        .onChange(of: appState.voiceSessionTagsByKey) { _, _ in revealActiveNestAncestors() }
        .onChange(of: appState.voiceCallChatLinksRevision) { _, _ in revealActiveNestAncestors() }
        .onChange(of: appState.activeProfile) { _, _ in
            revealLatch = NestRevealLatch()
            revealActiveNestAncestors()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.leading, 32)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .accessibilityAddTraits(.isHeader)
    }

    /// "Search Home" names the profile the list belongs to.
    private var searchPrompt: String {
        if showingProjects { return AppLocalization.string("Search projects") }
        let name = appState.profileDisplayName(appState.activeProfile)
        return AppLocalization.string("Search \(name)")
    }

    /// The 40 pt glass search capsule, with the active filter as a removable
    /// gold chip inside it.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if filter != .all {
                Button {
                    Haptics.selection()
                    withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { filterRaw = "all" }
                } label: {
                    HStack(spacing: 4) {
                        Text(filter.title)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.conduitAccent, in: Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(AppLocalization.string("Remove filter \(filter.title)"))
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
            TextField(searchPrompt, text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Clear search"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(minHeight: 40)
        .conduitGlassSurface(cornerRadius: 20)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: filter)
        .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
    }

    // MARK: - Nested rows

    /// Stored as "profile<TAB>nestKey" lines: nest keys are session ids,
    /// which another profile can reuse.
    private var expansionPrefix: String { appState.activeProfile + "\t" }

    private var expandedNestIDs: Set<String> {
        expansionCache.ids(in: expandedNestsRaw, prefix: expansionPrefix)
    }

    private func setExpanded(_ key: String, _ expanded: Bool) {
        let prefix = expansionPrefix
        let all = expandedNestsRaw.split(separator: "\n").map(String.init)
        var own = Set(all.filter { $0.hasPrefix(prefix) })
        let others = all.filter { !$0.hasPrefix(prefix) }
        let line = prefix + key
        if expanded { own.insert(line) } else { own.remove(line) }
        // Bounded per profile so years of expansions don't grow the default
        // forever, and one profile never evicts another's.
        expandedNestsRaw = (others + own.sorted().suffix(200)).joined(separator: "\n")
    }

    @ViewBuilder
    private func nestRows(_ nodes: [SessionNesting.Node]) -> some View {
        ForEach(nodes) { node in
            nestBlock(node)
        }
    }

    /// A top-level row, its "3 jobs · 1 running" disclosure, and, once
    /// expanded, its descendants on a thread line.
    @ViewBuilder
    private func nestBlock(_ node: SessionNesting.Node) -> some View {
        let key = SessionNesting.nestKey(of: node.session)
        let isExpanded = expandedNestIDs.contains(key)
        let hasChildren = !node.children.isEmpty
        let signals = SessionNesting.signals(
            node,
            isUnread: appState.isSessionUnread,
            liveStatus: appState.sessionLiveStatus
        )
        let readToggle = SessionNesting.readToggleInputs(for: node, aggregateIsUnread: signals.isUnread)

        sessionRowButton(node.session, isUnread: signals.isUnread, parentTitle: nil)
            .v2ListRow(divider: !hasChildren)
            .sessionActions(
                session: node.session,
                nest: readToggle,
                onRename: { sessionPendingRename = node.session },
                onDelete: { sessionPendingDeletion = node.session }
            )

        if hasChildren {
            nestDisclosure(node, key: key, isExpanded: isExpanded)
                .v2ListRow(divider: !isExpanded)
            if isExpanded {
                let descendants = Self.flatten(node.children, depth: 0)
                ForEach(Array(descendants.enumerated()), id: \.element.node.id) { index, entry in
                    childRow(entry.node.session, depth: entry.depth, parentTitle: node.session.title)
                        .v2ListRow(divider: index == descendants.count - 1)
                        .sessionActions(
                            session: entry.node.session,
                            nest: nil,
                            onRename: { sessionPendingRename = entry.node.session },
                            onDelete: { sessionPendingDeletion = entry.node.session }
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private struct FlatNode {
        let node: SessionNesting.Node
        let depth: Int
    }

    private static func flatten(_ nodes: [SessionNesting.Node], depth: Int) -> [FlatNode] {
        nodes.flatMap { node in
            [FlatNode(node: node, depth: depth)] + flatten(node.children, depth: depth + 1)
        }
    }

    private func sessionRowButton(_ session: SessionSummary, isUnread: Bool, parentTitle: String?) -> some View {
        Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            appState.requestOpenSession(session.id)
        } label: {
            V2SessionRow(
                title: session.title,
                time: session.updatedLabel,
                preview: appState.v2RowPreview(for: session),
                status: appState.v2RowStatus(for: session),
                isUnread: isUnread,
                isSelected: session.id == appState.activeSessionId
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(AppLocalization.string("Swipe or touch and hold for conversation actions."))
    }

    /// The parent's summary of what sits under it, and its expander.
    private func nestDisclosure(_ node: SessionNesting.Node, key: String, isExpanded: Bool) -> some View {
        let summary = Self.nestSummary(
            node,
            category: appState.sessionCategory,
            liveStatus: appState.sessionLiveStatus
        )
        return Button {
            Haptics.light()
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
                setExpanded(key, !isExpanded)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .conduitFixedGlyph()
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(summary)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 32)
            .padding(.top, 0)
            .padding(.bottom, 8)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .accessibilityLabel(Text(node.session.title) + Text(verbatim: ", ") + Text(summary))
        .accessibilityHint(SessionList.nestExpanderHint(isExpanded: isExpanded))
        .accessibilityValue(Text(AppLocalization.string(isExpanded ? "Expanded" : "Collapsed")))
    }

    /// "3 jobs · 1 running · 1 to approve": the count names jobs when every
    /// child is one, else sessions.
    static func nestSummary(
        _ node: SessionNesting.Node,
        category: (SessionSummary) -> SessionSource,
        liveStatus: (SessionSummary) -> SessionLiveStatus?
    ) -> String {
        let descendants = node.sessionsInNest.filter { $0.id != node.session.id }
        let count = descendants.count
        let allJobs = !descendants.isEmpty && descendants.allSatisfy { category($0) == .voiceJob }
        var parts = [allJobs
            ? AppLocalization.string("\(count) jobs")
            : AppLocalization.string("\(count) sessions")]
        let runningCount = descendants.filter { liveStatus($0) == .working }.count
        if runningCount > 0 { parts.append(AppLocalization.string("\(runningCount) running")) }
        let approvalCount = descendants.filter { liveStatus($0) == .needsInput }.count
        if approvalCount > 0 { parts.append(AppLocalization.string("\(approvalCount) to approve")) }
        return parts.joined(separator: " · ")
    }

    /// An expanded child: one line on the parent's 1.5 pt thread line.
    private func childRow(_ session: SessionSummary, depth: Int, parentTitle: String) -> some View {
        let status = appState.v2RowStatus(for: session)
        let isUnread = appState.isSessionUnread(session)
        return Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            appState.requestOpenSession(session.id)
        } label: {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1.5)
                    .padding(.leading, 21 + CGFloat(min(depth, 3)) * 14)
                    .padding(.trailing, 6)
                V2StatusGlyph(status: status == .none ? .source(appState.sessionCategory(for: session)) : status)
                Text(session.title)
                    .font(.subheadline.weight(isUnread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(status.actionWord ?? session.updatedLabel)
                    .font(.footnote)
                    .foregroundStyle(status.actionWord == nil ? Color.primary.opacity(0.45) : status.color)
                    .lineLimit(1)
            }
            .padding(.trailing, 16)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(session.title))
        .accessibilityValue(Text([
            AppLocalization.string("From \(parentTitle)"),
            isUnread ? AppLocalization.string("Unread") : nil,
            status.accessibilityWord,
            session.updatedLabel
        ].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(AppLocalization.string("Swipe or touch and hold for conversation actions."))
        .accessibilityAddTraits(.isButton)
    }

    private func offlineSessionRow(
        _ session: OfflineCachedSession,
        presentation: OfflineChatPresentation
    ) -> some View {
        let isSaved = presentation.snapshot.transcript(for: session.id) != nil
        return Button {
            Haptics.selection()
            appState.showOfflineCachedSession(session.id)
            appState.dismissSidebarDrawer()
        } label: {
            V2SessionRow(
                title: session.title,
                time: isSaved ? session.displayUpdatedLabel() : "",
                preview: isSaved ? "" : AppLocalization.string("Not saved offline"),
                status: .none,
                isSelected: presentation.displayedSessionID == session.id
            )
        }
        .buttonStyle(.plain)
        .disabled(!isSaved)
        .opacity(isSaved ? 1 : 0.5)
        .accessibilityHint(isSaved ? "" : AppLocalization.string("This conversation has no saved copy on this device"))
        .v2ListRow()
    }

    // MARK: - Reveal

    /// Expands the parents of the open conversation so returning to the
    /// list shows its row (the drawer's NestRevealLatch rules).
    private func revealActiveNestAncestors() {
        let sections = nestedSections
        let nest = SessionNesting.ancestorKeys(of: appState.activeSessionId ?? "", in: sections.pinned + sections.recent)
        guard let toExpand = revealLatch.reveal(
            active: appState.activeSessionId,
            ancestors: nest.keys,
            listHasRows: !displayedSessions.isEmpty,
            rowIsListed: nest.rowIsListed,
            hiddenAncestors: nest.keys.subtracting(expandedNestIDs)
        ) else { return }
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
            for key in toExpand { setExpanded(key, true) }
        }
    }

    // MARK: - Projects

    private var displayedProjects: [ProjectSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.projects }
        return appState.projects.filter { project in
            project.title.localizedCaseInsensitiveContains(query)
                || project.previewSessions.contains { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    private var projectsList: some View {
        let pinned = SidebarPinnedSessions.forProjectsView(
            sourceRows(nil),
            query: searchText,
            isPinned: appState.isSessionPinned,
            matches: sessionMatches
        )
        return List {
            searchField
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))

            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { session in
                        sessionRowButton(session, isUnread: appState.isSessionUnread(session), parentTitle: nil)
                            .v2ListRow()
                            .sessionActions(
                                session: session,
                                nest: nil,
                                onRename: { sessionPendingRename = session },
                                onDelete: { sessionPendingDeletion = session }
                            )
                    }
                } header: {
                    sectionHeader(AppLocalization.string("Pinned"))
                }
            }

            // Before the gateway connects the list hasn't loaded yet, which
            // isn't "no projects".
            if (appState.projectsLoading || !appState.isConnected) && displayedProjects.isEmpty && !isSearching {
                ProgressView(AppLocalization.string("Loading projects…"))
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if displayedProjects.isEmpty && !isSearching && appState.projectsLoadFailed {
                ContentUnavailableView {
                    Label(AppLocalization.string("Couldn’t Load Projects"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(AppLocalization.string("Hermes didn’t answer. Pull down or try again."))
                } actions: {
                    Button(AppLocalization.string("Try Again")) {
                        Task { await appState.refreshProjects() }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if displayedProjects.isEmpty && !(isSearching && !pinned.isEmpty) {
                ContentUnavailableView(
                    isSearching ? AppLocalization.string("No Matching Projects") : AppLocalization.string("No Projects"),
                    systemImage: "folder",
                    description: Text(!isSearching
                        ? AppLocalization.string("Projects created in Hermes Desktop will appear here.")
                        : AppLocalization.string("Try a different search."))
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if !displayedProjects.isEmpty {
                Section {
                    ForEach(displayedProjects) { project in
                        projectRow(project)
                    }
                } header: {
                    sectionHeader(AppLocalization.string("Projects"))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 1)
        .refreshable {
            await appState.refreshProjects()
        }
    }

    private func projectRow(_ project: ProjectSummary) -> some View {
        NavigationLink(value: V2Route.project(project)) {
            V2ProjectRow(project: project, runningCount: runningCount(project))
        }
        .accessibilityHint(appState.isProjectEditable(project)
            ? AppLocalization.string("Opens the conversations in this project. Swipe or touch and hold to rename or delete it.")
            : AppLocalization.string("Opens the conversations in this project."))
        .contextMenu {
            if appState.isProjectEditable(project) {
                projectActions(project)
            }
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
                    Task { @MainActor in projectPendingRename = project }
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                .tint(.conduitAccent)
                .disabled(appState.isProjectMutationInFlight)
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .overlay(alignment: .bottom) { V2RowDivider(leadingInset: 60) }
    }

    @ViewBuilder
    private func projectActions(_ project: ProjectSummary) -> some View {
        Button {
            Haptics.selection()
            Task { @MainActor in projectPendingRename = project }
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

    /// Running conversations among the ones the project tree lists.
    private func runningCount(_ project: ProjectSummary) -> Int {
        project.previewSessions.filter { appState.sessionLiveStatus($0) == .working }.count
    }
}

// MARK: - Row actions

extension View {
    /// The conversation actions every V2 session row carries: the context
    /// menu (Rename, Pin, Read, Move to Project, Archive, Delete) and the
    /// drawer's swipes.
    func sessionActions(
        session: SessionSummary,
        nest: NestReadToggle?,
        excludingProjectID: String? = nil,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onChanged: @escaping () -> Void = {}
    ) -> some View {
        modifier(V2SessionActions(
            session: session,
            nest: nest,
            excludingProjectID: excludingProjectID,
            onRename: onRename,
            onDelete: onDelete,
            onChanged: onChanged
        ))
    }
}

private struct V2SessionActions: ViewModifier {
    @EnvironmentObject private var appState: AppState
    let session: SessionSummary
    let nest: NestReadToggle?
    let excludingProjectID: String?
    let onRename: () -> Void
    let onDelete: () -> Void
    let onChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                SessionActionMenuItems(
                    session: session,
                    excludingProjectID: excludingProjectID,
                    nest: nest,
                    onRename: onRename,
                    onDelete: onDelete,
                    onChanged: onChanged
                )
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    Haptics.light()
                    appState.toggleSessionPinned(session)
                } label: {
                    Label(
                        appState.isSessionPinned(session) ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"),
                        systemImage: appState.isSessionPinned(session) ? "pin.slash" : "pin"
                    )
                }
                .tint(.conduitAccent)

                ReadStateToggleButton(session: session, nest: nest)
                    .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    Task {
                        let archived = await appState.archiveSession(session)
                        Haptics.mutationCompleted(archived)
                        if archived { onChanged() }
                    }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .tint(.orange)
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
}

// MARK: - Project row

/// A project in the Projects view: colored folder tile, title, path in
/// monospace, conversation count, a running line, and "Discovered" for a
/// repo Hermes found on its own.
struct V2ProjectRow: View {
    let project: ProjectSummary
    let runningCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            V2ProjectTile(project: project, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(project.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if project.isAuto {
                        Text("Discovered")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                    }
                }
                if let path = project.primaryPath, !path.isEmpty {
                    Text(path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if runningCount > 0 {
                    HStack(spacing: 5) {
                        V2StatusGlyph(status: .running)
                        Text("\(runningCount) running")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.conduitAccent)
                    }
                }
            }
            Spacer(minLength: 6)
            Text(String(project.sessionCount))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.45))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(AppLocalization.string("\(project.sessionCount) conversations")))
    }
}

/// A project's colored folder tile (Home gets a house).
struct V2ProjectTile: View {
    let project: ProjectSummary
    let size: CGFloat

    var color: Color { Self.color(for: project) }

    static func color(for project: ProjectSummary) -> Color {
        if let hex = project.colorHex?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty {
            return BotAvatarView.color(for: hex, name: project.title)
        }
        return project.isHome ? .conduitAccent : .orange
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: project.isHome ? "house" : "folder")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: shape)
            .overlay(shape.strokeBorder(color.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// The expanded nest keys of one profile, parsed from the stored lines only
/// when those lines or the profile change.
final class V2NestExpansionCache {
    private var raw: String?
    private var prefix: String?
    private var cached: Set<String> = []

    func ids(in raw: String, prefix: String) -> Set<String> {
        if raw == self.raw, prefix == self.prefix { return cached }
        self.raw = raw
        self.prefix = prefix
        cached = Set(raw.split(separator: "\n").compactMap { line in
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        })
        return cached
    }
}
