//
//  V2ChatsView.swift
//  Conduit
//
//  Chats: the dense session list (Pinned, Recent, child sessions under
//  their parent) and, behind the folder toggle, Projects. The filters are
//  a native pull-down menu and combine (Unread and Chat lists unread
//  chats); the active ones show as a gold chip in the search field. Rows
//  keep the old drawer's swipes and context menu.
//

import SwiftUI

/// One filter in the Chats menu. Status filters flatten the list to matching
/// rows; Voice, Scheduled and the other sources keep it nested, like the old
/// source filters.
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

    /// Unread, Needs approval and Running: what state a row is in, rather
    /// than where it came from.
    var isStatus: Bool { self == .unread || isLive }

    /// The source a source filter lists (Scheduled lists cron runs).
    var sessionSource: SessionSource? {
        switch self {
        case .voice: return .voice
        case .scheduled: return .cron
        case .source(let source): return source
        case .all, .unread, .needsApproval, .running: return nil
        }
    }

    /// Menu order: the fixed filters first, then other sources by name.
    fileprivate var menuRank: (Int, String) {
        if let index = Self.menuCases.firstIndex(of: self) { return (index, "") }
        if case .source(let source) = self { return (Self.menuCases.count, source.rawValue) }
        return (Self.menuCases.count + 1, rawValue)
    }

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

/// The Chats filters, any number at once. A row is listed when it has one of
/// the chosen statuses and comes from one of the chosen sources; a group with
/// nothing chosen doesn't narrow. Saved comma-separated under the single
/// filter's old key, so a filter saved by an earlier build reads as itself
/// and "all" as none.
struct V2FilterSelection: Equatable {
    private(set) var filters: Set<V2SessionFilter>

    static let empty = V2FilterSelection(filters: [])

    init(filters: Set<V2SessionFilter>) {
        self.filters = filters.subtracting([.all])
    }

    init(rawValue: String) {
        self.init(filters: Set(rawValue.split(separator: ",").map {
            V2SessionFilter(rawValue: $0.trimmingCharacters(in: .whitespaces))
        }))
    }

    var rawValue: String {
        isEmpty ? V2SessionFilter.all.rawValue : ordered.map(\.rawValue).joined(separator: ",")
    }

    var isEmpty: Bool { filters.isEmpty }

    /// In menu order.
    var ordered: [V2SessionFilter] {
        filters.sorted { $0.menuRank < $1.menuRank }
    }

    var statuses: [V2SessionFilter] { ordered.filter(\.isStatus) }
    var sources: [V2SessionFilter] { ordered.filter { !$0.isStatus } }

    /// A status is a lookup, not a browse: the list flattens to the matching
    /// rows.
    var flattens: Bool { !statuses.isEmpty }

    /// All counts as chosen when nothing else is.
    func contains(_ filter: V2SessionFilter) -> Bool {
        filter == .all ? isEmpty : filters.contains(filter)
    }

    /// Turns one filter on or off; turning All on clears the rest.
    func setting(_ filter: V2SessionFilter, on: Bool) -> V2FilterSelection {
        guard filter != .all else { return on ? .empty : self }
        var changed = filters
        if on { changed.insert(filter) } else { changed.remove(filter) }
        return V2FilterSelection(filters: changed)
    }

    /// While the gateway can't report live status, Needs approval and
    /// Running sit out rather than empty the list.
    var withoutLive: V2FilterSelection {
        V2FilterSelection(filters: filters.filter { !$0.isLive })
    }

    /// What the menu counts beside `filter`: the other group's choices with
    /// `filter` alone in its own group, so with Unread on, Chat counts the
    /// unread chats.
    func facet(_ filter: V2SessionFilter) -> V2FilterSelection {
        guard filter != .all else { return .empty }
        let otherGroup = filter.isStatus ? sources : statuses
        return V2FilterSelection(filters: Set(otherGroup + [filter]))
    }

    /// The filter whose empty-list wording fits the selection.
    var emptyStateFilter: V2SessionFilter {
        statuses.first ?? sources.first ?? .all
    }

    /// The rows the selection lists. `everything` is what a status looks
    /// through when no source is chosen. Chosen sources keep the listing's
    /// order, with cron runs (Scheduled) woven in by recency.
    func rows(
        everything: @autoclosure () -> [SessionSummary],
        sessions: [SessionSummary],
        cronSessions: [SessionSummary],
        category: (SessionSummary) -> SessionSource,
        hasStatus: (V2SessionFilter, SessionSummary) -> Bool
    ) -> [SessionSummary] {
        let kinds = Set(sources.compactMap(\.sessionSource))
        let listed: [SessionSummary]
        if kinds.isEmpty {
            listed = everything()
        } else {
            // Cron runs come only from their own list, as under Scheduled.
            let chats = sessions.filter { session in
                guard !session.isArchived else { return false }
                let source = category(session)
                return source != .cron && kinds.contains(source)
            }
            listed = kinds.contains(.cron)
                ? Self.mergedByRecency(chats, cronSessions.filter { !$0.isArchived })
                : chats
        }
        let wanted = statuses
        guard !wanted.isEmpty else { return listed }
        return listed.filter { session in wanted.contains { hasStatus($0, session) } }
    }

    /// Two lists, each newest first, merged so each keeps its own order. A
    /// row without a time goes after the other list's timed rows.
    static func mergedByRecency(_ first: [SessionSummary], _ second: [SessionSummary]) -> [SessionSummary] {
        var merged: [SessionSummary] = []
        merged.reserveCapacity(first.count + second.count)
        var i = first.startIndex
        var j = second.startIndex
        while i < first.endIndex, j < second.endIndex {
            if (second[j].lastActivityAt ?? -.infinity) > (first[i].lastActivityAt ?? -.infinity) {
                merged.append(second[j])
                j += 1
            } else {
                merged.append(first[i])
                i += 1
            }
        }
        merged.append(contentsOf: first[i...])
        merged.append(contentsOf: second[j...])
        return merged
    }
}

struct V2ChatsView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
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

    private var savedSelection: V2FilterSelection {
        V2FilterSelection(rawValue: filterRaw)
    }

    /// A live filter saved while the gateway can't report live status sits
    /// out, so the list doesn't empty out behind a filter nobody can see.
    private var selection: V2FilterSelection {
        appState.liveSessionStatusAvailable ? savedSelection : savedSelection.withoutLive
    }

    private func select(_ newSelection: V2FilterSelection) {
        Haptics.selection()
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { filterRaw = newSelection.rawValue }
    }

    var body: some View {
        ZStack {
            V2Backdrop(isTabRoot: true)
            Group {
                if showingProjects {
                    projectsList
                } else {
                    sessionsList
                }
            }
            .opacity(shell.contentFaded ? 0 : 1)
        }
        .v2EdgeBar(.top) {
            V2TopBar { trailingControls }
                .withoutScrollEdge()
                .modifier(V2LegacyScrollEdge())
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

    /// One glass capsule: Sessions/Projects toggle, Artifacts, Filter (amber
    /// dot while approvals wait), New chat.
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

            NavigationLink(value: V2Route.artifacts) {
                V2CapsuleIcon(systemImage: "square.grid.2x2")
            }
            .buttonStyle(PressableButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { Haptics.selection() })
            .accessibilityLabel(AppLocalization.string("Artifacts"))

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
        // Read once: it walks the catalog.
        let waitingApprovalCount = self.waitingApprovalCount
        return Menu {
            if showingProjects {
                Button {
                    Haptics.selection()
                    showProjectCreator = true
                } label: {
                    Label("New project", systemImage: "folder.badge.plus")
                }
                .disabled(!appState.supportsProjects)
            } else {
                filterToggle(.all)

                Section(AppLocalization.string("Status")) {
                    ForEach(statusFilters, id: \.self) { option in
                        filterToggle(option)
                    }
                }

                Section(AppLocalization.string("Sources")) {
                    ForEach(sourceFilters, id: \.self) { option in
                        filterToggle(option)
                    }
                }

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
                systemImage: selection.isEmpty
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill",
                dot: waitingApprovalCount > 0 ? Color.conduitAttention : nil
            )
        }
        .menuOrder(.fixed)
        .accessibilityLabel(AppLocalization.string("Filter"))
        .accessibilityValue(waitingApprovalCount > 0
            ? AppLocalization.string("\(waitingApprovalCount) waiting for approval")
            : spokenSelection)
    }

    /// One filter as a checkable menu item, with the rows it would list
    /// beside what's already chosen. Filters combine, so the menu stays open
    /// while picking; All, which clears them, closes it.
    private func filterToggle(_ option: V2SessionFilter) -> some View {
        Toggle(isOn: Binding(
            get: { selection.contains(option) },
            set: { on in
                // All can't be turned off; pick another filter instead.
                guard on || option != .all else { return }
                select(savedSelection.setting(option, on: on))
            }
        )) {
            Label("\(option.title) \(String(filterRows(selection.facet(option)).count))", systemImage: option.symbol)
        }
        .menuActionDismissBehavior(option == .all ? .automatic : .disabled)
    }

    private var statusFilters: [V2SessionFilter] {
        V2SessionFilter.menuCases.filter { $0.isStatus && (!$0.isLive || appState.liveSessionStatusAvailable) }
    }

    /// Voice and Scheduled, then the other sources that have rows, in the
    /// user's order.
    private var sourceFilters: [V2SessionFilter] {
        let fixed: [V2SessionFilter] = [.voice, .scheduled]
        let others = appState.sessionFilterOrder.filter { source in
            source != .voice && source != .cron && !sourceRows(source).isEmpty
        }
        return fixed + others.map { V2SessionFilter.source($0) }
    }

    /// The chosen filters' names, or All.
    private func selectionTitles(separator: String) -> String {
        selection.isEmpty
            ? V2SessionFilter.all.title
            : selection.ordered.map(\.title).joined(separator: separator)
    }

    /// The chosen filters' names as VoiceOver reads them.
    private var spokenSelection: String {
        selectionTitles(separator: ", ")
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

    private func filterRows(_ selection: V2FilterSelection) -> [SessionSummary] {
        guard !selection.isEmpty else { return mainListRows(sourceRows(nil)) }
        return selection.rows(
            everything: sourceRows(nil),
            sessions: appState.activeProfileSessions,
            cronSessions: appState.activeProfileCronSessions,
            category: appState.sessionCategory,
            hasStatus: hasStatus
        )
    }

    private func hasStatus(_ filter: V2SessionFilter, _ session: SessionSummary) -> Bool {
        switch filter {
        case .unread: return appState.isSessionUnread(session)
        case .needsApproval: return appState.sessionLiveStatus(session) == .needsInput
        case .running: return appState.sessionLiveStatus(session) == .working
        case .all, .voice, .scheduled, .source: return false
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
        let rows = filterRows(selection)
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

    private func nestedSections(_ displayed: [SessionSummary]) -> (pinned: [SessionNesting.Node], recent: [SessionNesting.Node]) {
        SessionNesting.sections(
            displayed,
            query: searchText,
            statusFilterActive: selection.flattens,
            isPinned: appState.isSessionPinned,
            parentKeyOf: appState.sessionNestingParentKey
        )
    }

    // MARK: - Sessions list

    private var sessionsList: some View {
        // Worked out once per render: the rows walk the whole catalog.
        let displayed = displayedSessions
        let sections = nestedSections(displayed)
        let expanded = expandedNestIDs
        let layout = SidebarOfflineLayout.visibility(
            showingProjects: false,
            hasOfflineCopy: appState.offlineChatPresentation != nil,
            displayedSessionsEmpty: displayed.isEmpty
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
                    // A row, not a footer: a plain List paints footers as an
                    // opaque band across the backdrop.
                    Text("Read-only copies from your last connection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16))
                } header: {
                    sectionHeader(AppLocalization.string("Saved on this device"))
                }
            }

            if layout.emptyState {
                ContentUnavailableView(
                    selection.emptyStateFilter.emptyTitle,
                    systemImage: "tray",
                    description: Text(isSearching
                        ? AppLocalization.string("Try a different search.")
                        : selection.emptyStateFilter.emptyDescription)
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if layout.liveSections && !sections.pinned.isEmpty {
                Section {
                    listRows(V2ChatsListItem.items(sections.pinned, expanded: expanded))
                } header: {
                    sectionHeader(AppLocalization.string("Pinned"))
                }
            }

            if layout.liveSections && !sections.recent.isEmpty {
                Section {
                    listRows(V2ChatsListItem.items(sections.recent, expanded: expanded))
                } header: {
                    sectionHeader(AppLocalization.string("Recent"))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Scrolling the list puts the keyboard away; the search stays.
        .scrollDismissesKeyboard(.immediately)
        .environment(\.defaultMinListRowHeight, 1)
        .refreshable {
            await appState.refreshSessionCatalog()
        }
        .onAppear { revealActiveNestAncestors() }
        .onChange(of: appState.activeSessionId) { _, _ in revealActiveNestAncestors() }
        .onChange(of: displayed) { _, _ in revealActiveNestAncestors() }
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
            .padding(.leading, 16)
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

    /// The 40 pt glass search capsule, with the active filters as one
    /// removable gold chip inside it ("Unread · Chat"). While typing, Cancel
    /// beside it clears the search and puts the keyboard away; Search on
    /// the keyboard or a scroll puts it away and keeps the search.
    private var searchField: some View {
        HStack(spacing: 10) {
            searchCapsule
            if searchFocused {
                Button(AppLocalization.string("Cancel")) {
                    searchText = ""
                    searchFocused = false
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.conduitAccent)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: searchFocused)
    }

    private var searchCapsule: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if !selection.isEmpty {
                Button {
                    select(.empty)
                } label: {
                    HStack(spacing: 4) {
                        Text(selectionTitles(separator: " · "))
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
                .accessibilityLabel(AppLocalization.string("Remove filter \(spokenSelection)"))
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
            }
            TextField(searchPrompt, text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
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
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: selection)
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

    /// One List row per item, so the List builds only the rows on screen.
    private func listRows(_ items: [V2ChatsListItem]) -> some View {
        ForEach(items) { item in
            V2ChatsRow(
                item: item,
                onRename: { sessionPendingRename = $0 },
                onDelete: { sessionPendingDeletion = $0 },
                setExpanded: setExpanded
            )
        }
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
                isSelected: presentation.displayedSessionID == session.id,
                icon: .chat
            )
        }
        .buttonStyle(.plain)
        .disabled(!isSaved)
        .opacity(isSaved ? 1 : 0.5)
        .accessibilityHint(isSaved ? "" : AppLocalization.string("This conversation has no saved copy on this device"))
        .v2ListRow(dividerInset: V2SessionRow.iconTextInset)
    }

    // MARK: - Reveal

    /// Expands the parents of the open conversation so returning to the
    /// list shows its row (the drawer's NestRevealLatch rules).
    private func revealActiveNestAncestors() {
        let displayed = displayedSessions
        let sections = nestedSections(displayed)
        let nest = SessionNesting.ancestorKeys(of: appState.activeSessionId ?? "", in: sections.pinned + sections.recent)
        guard let toExpand = revealLatch.reveal(
            active: appState.activeSessionId,
            ancestors: nest.keys,
            listHasRows: !displayed.isEmpty,
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
                    listRows(pinned.map(V2ChatsListItem.leaf))
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
        // Scrolling the list puts the keyboard away; the search stays.
        .scrollDismissesKeyboard(.immediately)
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

// MARK: - List rows

/// One row of the Chats list. A nest used to be one block of a varying
/// number of rows (the row, its "3 jobs" line, its open children), so on
/// every redraw the List built every row of the list just to count them.
/// With one List row per item it builds only the rows on screen.
struct V2ChatsListItem: Identifiable {
    enum Kind {
        /// A conversation at the top of its nest, or on its own.
        case session(SessionNesting.Node)
        /// The "3 jobs · 1 running" line under a parent: its expander.
        case nest(SessionNesting.Node, key: String, isExpanded: Bool)
        /// An open nest's descendant, on the parent's thread line. The
        /// last one draws the hairline that closes the nest.
        case child(SessionSummary, depth: Int, parentTitle: String, isLast: Bool)
    }

    let id: String
    let kind: Kind

    /// A row with nothing nested under it (the pinned chats over Projects).
    static func leaf(_ session: SessionSummary) -> V2ChatsListItem {
        V2ChatsListItem(id: session.id, kind: .session(SessionNesting.Node(session: session, children: [])))
    }

    /// The rows of `nodes` in list order: each node, its "3 jobs" line
    /// when it has children, and, when `expanded` holds its nest key, its
    /// descendants depth first. A conversation's row keeps its id whether
    /// it sits at the top or in a nest, so moving between them is a move.
    static func items(_ nodes: [SessionNesting.Node], expanded: Set<String>) -> [V2ChatsListItem] {
        var items: [V2ChatsListItem] = []
        for node in nodes {
            items.append(V2ChatsListItem(id: node.id, kind: .session(node)))
            guard !node.children.isEmpty else { continue }
            let key = SessionNesting.nestKey(of: node.session)
            let isExpanded = expanded.contains(key)
            items.append(V2ChatsListItem(id: "nest:" + node.id, kind: .nest(node, key: key, isExpanded: isExpanded)))
            guard isExpanded else { continue }
            let descendants = descendants(of: node.children, depth: 0)
            for (index, entry) in descendants.enumerated() {
                items.append(V2ChatsListItem(
                    id: entry.session.id,
                    kind: .child(
                        entry.session,
                        depth: entry.depth,
                        parentTitle: node.session.title,
                        isLast: index == descendants.count - 1
                    )
                ))
            }
        }
        return items
    }

    private static func descendants(of nodes: [SessionNesting.Node], depth: Int) -> [(session: SessionSummary, depth: Int)] {
        nodes.flatMap { node in
            [(session: node.session, depth: depth)] + descendants(of: node.children, depth: depth + 1)
        }
    }
}

/// One Chats list row. It works out its own dot, status and preview, so
/// only the rows on screen do.
private struct V2ChatsRow: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: V2ChatsListItem
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void
    /// Opens or closes the nest with this key.
    let setExpanded: (String, Bool) -> Void

    var body: some View {
        switch item.kind {
        case .session(let node):
            sessionRow(node)
        case .nest(let node, let key, let isExpanded):
            nestDisclosure(node, key: key, isExpanded: isExpanded)
                .v2ListRow(divider: !isExpanded, dividerInset: V2SessionRow.iconTextInset)
        case .child(let session, let depth, let parentTitle, let isLast):
            childRow(session, depth: depth, parentTitle: parentTitle)
                .v2ListRow(divider: isLast, dividerInset: V2SessionRow.iconTextInset)
                .sessionActions(
                    session: session,
                    nest: nil,
                    onRename: { onRename(session) },
                    onDelete: { onDelete(session) }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// A top-level row. Its dot speaks for the whole nest, so a closed
    /// nest never hides an unread reply.
    private func sessionRow(_ node: SessionNesting.Node) -> some View {
        let session = node.session
        let hasChildren = !node.children.isEmpty
        let signals = SessionNesting.signals(
            node,
            isUnread: appState.isSessionUnread,
            liveStatus: appState.sessionLiveStatus
        )
        return Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            appState.requestOpenSession(session.id)
        } label: {
            V2SessionRow(
                title: session.title,
                time: session.updatedLabel,
                preview: appState.v2RowPreview(for: session),
                status: appState.v2RowStatus(for: session),
                isUnread: signals.isUnread,
                isSelected: session.id == appState.activeSessionId,
                icon: appState.sessionCategory(for: session),
                hasNestBelow: hasChildren
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(AppLocalization.string("Swipe or touch and hold for conversation actions."))
        .v2ListRow(divider: !hasChildren, dividerInset: V2SessionRow.iconTextInset)
        .sessionActions(
            session: session,
            nest: SessionNesting.readToggleInputs(for: node, aggregateIsUnread: signals.isUnread),
            onRename: { onRename(session) },
            onDelete: { onDelete(session) }
        )
    }

    /// The parent's summary of what sits under it, and its expander.
    private func nestDisclosure(_ node: SessionNesting.Node, key: String, isExpanded: Bool) -> some View {
        let summary = V2ChatsView.nestSummary(
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
            .padding(.leading, V2SessionRow.iconTextInset)
            .padding(.bottom, 11)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .accessibilityLabel(Text(node.session.title) + Text(verbatim: ", ") + Text(summary))
        .accessibilityHint(SessionList.nestExpanderHint(isExpanded: isExpanded))
        .accessibilityValue(Text(AppLocalization.string(isExpanded ? "Expanded" : "Collapsed")))
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
                    .padding(.leading, 34 + CGFloat(min(depth, 3)) * 14)
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
