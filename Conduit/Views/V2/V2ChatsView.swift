//
//  V2ChatsView.swift
//  Conduit
//
//  Chats: the dense session list (Pinned, then Today, Yesterday, Last 7
//  days and Older, each collapsible; child sessions under their parent)
//  and, behind the folder toggle, Projects. The filters are a native
//  pull-down menu and combine (Unread and Chat lists unread
//  chats, Starred narrows either to starred ones); the active ones show as
//  a gold chip in the search field. Filter ▸ Projects leaves the projects
//  you untick out. Rows keep the old drawer's swipes and context menu, plus
//  Star.
//

import SwiftUI

/// One filter in the Chats menu. Starred and the status filters flatten the
/// list to matching rows; Voice, Scheduled and the other sources keep it
/// nested, like the old source filters.
enum V2SessionFilter: Equatable, Hashable {
    case all
    case starred
    case unread
    case needsApproval
    case running
    case voice
    case scheduled
    case source(SessionSource)

    static let menuCases: [V2SessionFilter] = [.all, .starred, .unread, .needsApproval, .running, .voice, .scheduled]

    init(rawValue: String) {
        switch rawValue {
        case "starred": self = .starred
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
        case .starred: return "starred"
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
        case .starred: return AppLocalization.string("Starred")
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
        case .starred: return "star"
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

    /// Starred narrows whatever else is chosen (Starred and Unread lists
    /// starred chats that are unread), where statuses list any of theirs.
    var isScope: Bool { self == .starred }

    /// The source a source filter lists (Scheduled lists cron runs).
    var sessionSource: SessionSource? {
        switch self {
        case .voice: return .voice
        case .scheduled: return .cron
        case .source(let source): return source
        case .all, .starred, .unread, .needsApproval, .running: return nil
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
        case .starred: return AppLocalization.string("No starred chats")
        case .unread: return SessionStatusFilter.unread.emptyTitle
        case .needsApproval: return SessionStatusFilter.needsInput.emptyTitle
        case .running: return SessionStatusFilter.working.emptyTitle
        default: return AppLocalization.string("No Sessions")
        }
    }

    var emptyDescription: String {
        switch self {
        case .starred: return AppLocalization.string("Swipe a chat or touch and hold it to star it.")
        case .unread: return SessionStatusFilter.unread.emptyDescription
        case .needsApproval: return SessionStatusFilter.needsInput.emptyDescription
        case .running: return SessionStatusFilter.working.emptyDescription
        default: return AppLocalization.string("Sessions will appear here once created.")
        }
    }
}

/// The Chats filters, any number at once. A row is listed when it has one of
/// the chosen statuses, comes from one of the chosen sources and, with
/// Starred on, is starred; a group with nothing chosen doesn't narrow. Saved
/// comma-separated under the single filter's old key, so a filter saved by
/// an earlier build reads as itself and "all" as none.
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
    var sources: [V2SessionFilter] { ordered.filter { !$0.isStatus && !$0.isScope } }
    var scopes: [V2SessionFilter] { ordered.filter(\.isScope) }

    /// A status or Starred is a lookup, not a browse: the list flattens to
    /// the matching rows, project chats included and no section closed.
    var flattens: Bool { !statuses.isEmpty || !scopes.isEmpty }

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
    /// unread chats. Starred narrows every count while it's on, and its own
    /// count is the starred rows among what's chosen.
    func facet(_ filter: V2SessionFilter) -> V2FilterSelection {
        guard filter != .all else { return .empty }
        if filter.isScope { return V2FilterSelection(filters: filters.union([filter])) }
        let otherGroup = filter.isStatus ? sources : statuses
        return V2FilterSelection(filters: Set(otherGroup + scopes + [filter]))
    }

    /// The filter whose empty-list wording fits the selection.
    var emptyStateFilter: V2SessionFilter {
        scopes.first ?? statuses.first ?? sources.first ?? .all
    }

    /// The rows the selection lists. `everything` is what a status or
    /// Starred looks through when no source is chosen; `hasStatus` answers
    /// for Starred too. Chosen sources keep the listing's
    /// order, with cron runs (Scheduled) woven in by recency.
    func rows(
        everything: @autoclosure () -> [SessionSummary],
        sessions: [SessionSummary],
        cronSessions: [SessionSummary],
        category: (SessionSummary) -> SessionSource,
        hasStatus: (V2SessionFilter, SessionSummary) -> Bool
    ) -> [SessionSummary] {
        let kinds = Set(sources.compactMap(\.sessionSource))
        let scopes = self.scopes
        let listed: [SessionSummary]
        if kinds.isEmpty, !scopes.isEmpty {
            // A run starred under Scheduled is listed under Starred alone
            // too, not only once it is pinned.
            let rows = everything()
            let ids = Set(rows.map(\.id))
            listed = Self.mergedByRecency(rows, cronSessions.filter { !$0.isArchived && !ids.contains($0.id) })
        } else if kinds.isEmpty {
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
        guard !wanted.isEmpty || !scopes.isEmpty else { return listed }
        return listed.filter { session in
            (wanted.isEmpty || wanted.contains { hasStatus($0, session) })
                && scopes.allSatisfy { hasStatus($0, session) }
        }
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

struct V2ChatsView: View, Equatable {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// Followed through `updates`, which holds AppState's changes back
    /// while a chat or a page covers the list or another tab is up.
    private let appState: AppState
    @StateObject private var updates: V2ShownUpdates
    @Environment(\.v2Shell) private var shell
    @Environment(\.v2OpenBeside) private var openBeside
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    /// The bar is stacked (profiles on their own row): search is a button
    /// in the controls and opens over the filter row, so the list doesn't
    /// carry a third row of chrome. The bar only reports its layout once it
    /// appears, so this starts from the last layout seen (`barStackedKey`),
    /// and is nil before any: the list leaves its search row out until the
    /// bar says it's one row, rather than show it for a frame and take it
    /// away. Read into state like `collapsedSections`; nothing observes the
    /// key, so it stays out of `updates`.
    @State private var barStacked = UserDefaults.standard.object(forKey: V2ChatsView.barStackedKey) as? Bool
    private static let barStackedKey = "conduit.v2.barStacked"
    /// The magnifier was tapped: the stacked bar shows the field.
    @State private var barSearchOpen = false
    /// The tap that opened the field also focuses it, once; coming back
    /// from a chat leaves the keyboard down.
    @State private var barSearchFocusPending = false
    /// Hermes' full-text search behind the field, for chats whose messages
    /// match ("In messages").
    @StateObject private var contentSearch = SessionContentSearchModel()
    @State private var showArchivedSessions = false
    /// Every pinned reply of the profile (#918).
    @State private var showPinnedReplies = false
    /// Reorder pinned chats, from a pinned row's menu or the Pinned header
    /// (issue 1354).
    @State private var pinnedOrderTarget: PinnedChatsOrderTarget?
    @State private var showProjectCreator = false
    @State private var sessionPendingDeletion: SessionSummary?
    @State private var sessionPendingRename: SessionSummary?
    @State private var projectPendingRename: ProjectSummary?
    @State private var projectPendingDeletion: ProjectSummary?
    /// Repair Connection opened from the top of the list.
    @State private var repairContext: ConnectionRepairContext?
    /// The last activation the reveal served (NestRevealLatch).
    @State private var revealLatch = NestRevealLatch()
    // Saved settings, read and written through `updates` so the list
    // under a chat stays still when anything else writes to the defaults.
    static let presentationKey = "conduit.sessionPresentation"
    static let filterKey = "conduit.v2.sessionFilter"
    /// Expanded parents, remembered per parent across launches.
    static let expandedNestsKey = "conduit.v2.expandedNests"

    private var sessionPresentationRaw: String {
        get { updates.defaults.string(forKey: Self.presentationKey) ?? "sessions" }
        nonmutating set { updates.set(newValue, forKey: Self.presentationKey) }
    }

    private var filterRaw: String {
        get { updates.defaults.string(forKey: Self.filterKey) ?? "all" }
        nonmutating set { updates.set(newValue, forKey: Self.filterKey) }
    }

    private var expandedNestsRaw: String {
        get { updates.defaults.string(forKey: Self.expandedNestsKey) ?? "" }
        nonmutating set { updates.set(newValue, forKey: Self.expandedNestsKey) }
    }

    private var projectChats: ProjectChatsInChats {
        ProjectChatsInChats.stored(in: updates.defaults)
    }

    /// Filter ▸ Projects: projects belong to one profile, so All lists
    /// every project's chats.
    private var filtersProjects: Bool {
        appState.supportsProjects && !appState.isAllProfilesChatsOn
    }

    /// The projects Filter ▸ Projects leaves out, for the profile in use.
    /// Only the ones listed now count: a deleted project's leftover id
    /// hides nothing, and until the projects load every chat would look
    /// like one in no project, so nothing is hidden yet.
    private var hiddenProjects: Set<String> {
        let projects = filterProjects
        guard filtersProjects, !projects.isEmpty else { return [] }
        let stored = HiddenChatProjects.ids(in: updates.defaults.object(forKey: HiddenChatProjects.key), profile: appState.activeProfile)
        guard !stored.isEmpty else { return [] }
        return stored.intersection(Set(projects.map(\.id)).union([HiddenChatProjects.noProject]))
    }

    private func setHiddenProjects(_ ids: Set<String>) {
        updates.set(
            HiddenChatProjects.setting(ids, profile: appState.activeProfile, in: updates.defaults.object(forKey: HiddenChatProjects.key)),
            forKey: HiddenChatProjects.key
        )
    }

    /// The projects Filter ▸ Projects lists: Home's chats are the ones in
    /// no project, so it stands for those.
    private var filterProjects: [ProjectSummary] {
        appState.projects.filter { !$0.isHome }
    }

    /// How many of the listed choices are hidden.
    private var hiddenProjectCount: Int {
        hiddenProjects.count
    }

    /// The list is empty because of hidden projects: with them shown, the
    /// selection would list something. Asked only of an empty list.
    private var hidesEverything: Bool {
        guard !isSearching, hiddenProjectCount > 0 else { return false }
        return !uncachedFilterRows(selection, searching: false, hidingProjects: false).isEmpty
    }

    /// Something narrows the list: a filter, or a hidden project. The
    /// Projects page lists every project, so hidden ones don't count there.
    private var narrowsList: Bool {
        !selection.isEmpty || shownHiddenProjectCount > 0
    }

    /// Hidden projects as the bar reports them: none on the Projects page.
    private var shownHiddenProjectCount: Int {
        showingProjects ? 0 : hiddenProjectCount
    }

    private var mainButtonNewChat: Bool {
        updates.defaults.object(forKey: V2MainButtonPreference.key) as? Bool ?? V2MainButtonPreference.defaultValue
    }
    /// Parsed once per change of the store, not once per parent row.
    @State private var expansionCache = V2NestExpansionCache()
    /// The catalog walks one render shares (#1065).
    @State private var renderMemo = V2ChatsRenderMemo()
    /// A conversation opened from elsewhere whose closed section still has
    /// to open once its row is listed.
    @State private var pendingSectionReveal: String?
    /// The closed list sections (#696), remembered across launches. Read
    /// into state so a tap can animate the change, which an `@AppStorage`
    /// write ignores.
    @State private var collapsedSections = ChatListSection.collapsed(
        from: UserDefaults.standard.string(forKey: V2ChatsView.collapsedSectionsKey) ?? ChatListSection.defaultCollapsedRaw
    )
    /// All grouped by profile: the closed profile sections, by name.
    @State private var collapsedProfiles = Set(
        (UserDefaults.standard.string(forKey: V2ChatsView.collapsedProfilesKey) ?? "")
            .split(separator: "\n").map(String.init)
    )

    init(appState: AppState) {
        self.appState = appState
        _updates = StateObject(wrappedValue: V2ShownUpdates(appState, defaultsKeys: [
            Self.presentationKey, Self.filterKey, Self.expandedNestsKey, V2MainButtonPreference.key,
            ProjectChatsInChats.key, HiddenChatProjects.key,
        ]))
    }

    /// Redrawn by its own changes only; the shell redraws on every publish.
    nonisolated static func == (lhs: V2ChatsView, rhs: V2ChatsView) -> Bool {
        lhs.appState === rhs.appState
    }

    /// Nothing pushed over the list, on the selected tab.
    private var isShown: Bool { shell.isTabActive && !shell.isRootCovered }

    /// No chat covers the list: none is open, or a wide window shows the
    /// list beside it.
    private var listInView: Bool { appState.showSidebar || shell.isSplit }

    /// The list, or a project's page pushed over it, shows on the selected
    /// tab: their rows' Running and Needs approval follow the live
    /// registry. Split, a project's page stays beside the open chat.
    private var showsLiveRows: Bool { shell.isTabActive && shell.showsChatRows && listInView }

    /// Projects belong to one profile, so All shows chats only.
    private var showingProjects: Bool { sessionPresentationRaw == "projects" && !appState.isAllProfilesChatsOn }

    /// All's rows carry their profile's picture, unless the list groups by
    /// profile and the section says it.
    private var badgesRows: Bool {
        appState.isAllProfilesChatsOn && !appState.allProfilesGroupsByProfile
    }

    /// What leads a row's list id: nothing outside All, else its profile.
    private func rowScope(_ session: SessionSummary) -> String {
        appState.isAllProfilesChatsOn ? appState.rowProfile(session) + "\u{1F}" : ""
    }

    private func profileBadge(for session: SessionSummary) -> V2ProfileBadge? {
        guard badgesRows else { return nil }
        let profile = appState.rowProfile(session)
        return V2ProfileBadge(
            profile: profile,
            name: appState.profileDisplayName(profile),
            url: appState.profileAvatarURL(for: profile)
        )
    }

    /// The listed chats and cron runs: the profile in use's, or in All
    /// every included profile's. Worked out once per render.
    private var listed: (sessions: [SessionSummary], cron: [SessionSummary]) {
        renderMemo.listed {
            // Pulse's own chat stays behind the Pulse screen, in All too.
            let sessions = appState.chatListSessions
            let chats = appState.pulseHomeChat == nil ? sessions : sessions.filter { !appState.isPulseHomeChat($0) }
            return (chats, appState.chatListCronSessions)
        }
    }

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
        // Snaps: re-filtering the whole list isn't worth animating, and an
        // `@AppStorage` write ignored the `withAnimation` it used to sit in.
        filterRaw = newSelection.rawValue
    }

    /// Under Reduce Motion the lists only crossfade.
    private func presentationTransition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    var body: some View {
        // A new render reads the catalog afresh; within it, the list, the
        // filter menu and its counts share each walk.
        let _ = renderMemo.reset()
        // Read once: it walks the catalog, and the bar measures both its
        // layouts.
        let waitingApprovalCount = self.waitingApprovalCount
        ZStack {
            V2Backdrop(isTabRoot: true)
            // Projects sits behind the folder button on the right, so it
            // slides in from the trailing side and Sessions comes back from
            // the leading one. Keyed on the stored value: the tap's
            // `withAnimation` never animated this `@AppStorage` change.
            ZStack {
                if showingProjects {
                    projectsList
                        .transition(presentationTransition(from: .trailing))
                } else {
                    sessionsList
                        .transition(presentationTransition(from: .leading))
                }
            }
            .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: showingProjects)
            .v2ProfileSwitchContent()
        }
        .v2EdgeBar(.top) {
            V2TopBar(lowerLeading: { stackedLeading(waitingApprovalCount: waitingApprovalCount) }) { stacked in
                if !(stacked && showsBarSearch) {
                    trailingControls(stacked: stacked, waitingApprovalCount: waitingApprovalCount)
                        .onAppear { if !stacked { barUnstacked() } }
                }
            }
                .withAllProfilesChip()
                .withoutScrollEdge()
                .modifier(V2LegacyScrollEdge())
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MinimisedLiveVoiceBar()
        }
        .environmentObject(updates)
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(V2Tab.chats.title)
        .onChange(of: shell.hasChatBeside, initial: true) { _, beside in
            updates.coalesces = beside
        }
        .onChange(of: isShown, initial: true) { _, shown in
            updates.isShown = shown
            // Anything over the list (a chat, a page, another tab) puts the
            // keyboard away and keeps the search: SwiftUI otherwise hands
            // focus back to the field on the way back, over the results.
            if !shown { searchFocused = false }
        }
        // Here rather than on the chats list, so an activation that arrives
        // while Projects is shown still opens its section on the way back.
        .onChange(of: appState.activeSessionId) { _, active in
            pendingSectionReveal = active
            revealActiveSection()
        }
        .sheet(isPresented: $showArchivedSessions) {
            ArchivedSessionsSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showPinnedReplies) {
            PinnedRepliesSheet()
                .environmentObject(appState)
        }
        .sheet(item: $pinnedOrderTarget) { target in
            PinnedChatsOrderSheet(profile: target.profile)
                .environmentObject(appState)
        }
        .sheet(item: $repairContext) { context in
            ConnectionRepairSetupSheet(context: context)
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
        // The list's first read once the connection is up (a sign-in lands
        // here before its catalog sync has published anything): when that
        // sync settles without a catalog, the list reads it itself. Only
        // while the list shows, like the rest of its updates.
        .task(id: "\(appState.activeProfile)|\(appState.isConnected)|\(appState.turnState == .synchronizing)|\(isShown)") {
            guard isShown else { return }
            await appState.loadSessionCatalogIfNeeded()
        }
        // Running and Needs approval follow the gateway's live registry
        // while the list or a project's page is on screen; a hidden tab or
        // a conversation pushed over them stops polling. The poll slows
        // down while nothing on the list changes (PollCadence). Split, the
        // list column stays on screen beside the open chat (#1353).
        .task(id: "\(appState.activeProfile)|\(showsLiveRows)") {
            guard showsLiveRows else { return }
            await appState.runChatListPolling()
        }
        // All reads every profile's chats on its own, slower poll.
        .task(id: "\(appState.activeProfile)|\(appState.isAllProfilesChatsOn)|\(appState.isConnected)|\(isShown)|\(listInView)") {
            guard appState.isAllProfilesChatsOn, appState.isConnected, isShown, listInView else { return }
            await appState.runAllProfilesCatalogPolling()
        }
        // Searching is looking at the list: it catches up at once.
        .onChange(of: searchText) { _, _ in
            if isShown { appState.noteChatListInteraction() }
        }
        // Back in the app over the list: it reads the catalog again if its
        // last read is old (a chat started elsewhere meanwhile).
        .onChange(of: scenePhase) { _, phase in
            // Off screen, a scroll may never report coming to rest.
            if phase != .active { updates.endScrolling() }
            if phase == .active, isShown, listInView { appState.chatListBecameActive() }
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
    /// dot while approvals wait), New chat. Under a row of profiles
    /// (`stacked`) Filter leaves it for the labeled pill on the left.
    private func trailingControls(stacked: Bool, waitingApprovalCount: Int) -> some View {
        V2ControlCapsule {
            if stacked {
                Button {
                    Haptics.selection()
                    barSearchFocusPending = true
                    withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { barSearchOpen = true }
                } label: {
                    V2CapsuleIcon(systemImage: "magnifyingglass")
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(AppLocalization.string("Search"))
                .macTooltip(AppLocalization.string("Search"))
            }

            Button {
                Haptics.selection()
                sessionPresentationRaw = showingProjects ? "sessions" : "projects"
            } label: {
                V2CapsuleIcon(systemImage: "folder", tint: showingProjects ? Color.conduitAccent : nil)
                    .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: showingProjects)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(appState.isAllProfilesChatsOn)
            .accessibilityLabel(showingProjects ? AppLocalization.string("Show sessions") : AppLocalization.string("Browse projects"))
            .macTooltip(showingProjects ? AppLocalization.string("Show sessions") : AppLocalization.string("Browse projects"))

            if appState.showsPulseScreen {
                V2PulseButton()
            }

            NavigationLink(value: V2Route.artifacts) {
                V2CapsuleIcon(systemImage: "square.grid.2x2")
            }
            .buttonStyle(PressableButtonStyle())
            .simultaneousGesture(TapGesture().onEnded { Haptics.selection() })
            .accessibilityLabel(AppLocalization.string("Artifacts"))
            .macTooltip(AppLocalization.string("Artifacts"))

            if !stacked {
                filterMenu(waitingApprovalCount: waitingApprovalCount) { filterIcon(waitingApprovalCount: waitingApprovalCount) }
            }

            // The gold button beside the tabs makes new chats instead
            // (Settings > Appearance): voice takes New chat's place here,
            // unless a chat beside the list shows its own.
            if mainButtonNewChat {
                if !shell.hasChatVoiceBeside {
                    V2VoiceButton(context: .home, style: .capsule)
                }
            } else if appState.isAllProfilesChatsOn && appState.allProfilesIncluded.count > 1 {
                newChatInProfileMenu
            } else {
                Button {
                    Haptics.medium()
                    // All with one profile in it: that one.
                    if appState.isAllProfilesChatsOn, let only = appState.allProfilesIncluded.first {
                        appState.startNewChat(inProfile: only)
                    } else {
                        appState.startNewChat()
                    }
                } label: {
                    V2CapsuleIcon(systemImage: "square.and.pencil")
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!appState.canTapNewChat)
                .accessibilityLabel(AppLocalization.string("New Chat"))
                .macTooltip(AppLocalization.string("New Chat"))
            }
        }
    }

    /// New Chat in All asks which profile, the one in use first.
    private var newChatInProfileMenu: some View {
        let included = appState.allProfilesIncluded
        let ordered = included.filter { $0 == appState.activeProfile } + included.filter { $0 != appState.activeProfile }
        return Menu {
            Section(AppLocalization.string("New chat in")) {
                ForEach(ordered, id: \.self) { profile in
                    Button {
                        Haptics.medium()
                        appState.startNewChat(inProfile: profile)
                    } label: {
                        Text(appState.profileDisplayName(profile))
                    }
                }
            }
        } label: {
            V2CapsuleIcon(systemImage: "square.and.pencil")
        }
        .menuOrder(.fixed)
        .disabled(!appState.canTapNewChat)
        .accessibilityLabel(AppLocalization.string("New Chat"))
        .macTooltip(AppLocalization.string("New Chat"))
    }

    private var waitingApprovalCount: Int {
        guard appState.liveSessionStatusAvailable else { return 0 }
        return sourceRows(nil).filter { appState.sessionLiveStatus($0) == .needsInput }.count
    }

    /// The stacked bar's second row: the filter pill beside the controls,
    /// or the search field across the row once the magnifier is tapped (or
    /// a search is running). One container, so its appearing says the bar
    /// stacked.
    private func stackedLeading(waitingApprovalCount: Int) -> some View {
        HStack(spacing: 0) {
            if showsBarSearch {
                barSearchField
                    .transition(.opacity)
            } else {
                filterPill(waitingApprovalCount: waitingApprovalCount)
                    .transition(.opacity)
            }
        }
        // Ahead of the bar's spacer, so the pill or the field takes the
        // whole row up to the controls instead of sharing it.
        .layoutPriority(1)
        // Set by the layout that shows, never on disappearing: a chat
        // pushed over the list hides both, and the list keeps its rows.
        .onAppear {
            setBarStacked(true)
            // A query brought over from the list's field keeps the field
            // up while it's edited down to nothing, until Cancel.
            if !searchText.isEmpty { barSearchOpen = true }
        }
    }

    /// The one-row bar took over. A query carries over to the list's
    /// field; an empty open one doesn't come back on the next stack.
    private func barUnstacked() {
        setBarStacked(false)
        barSearchOpen = false
    }

    /// A change (rotation, a profile added) fades the list's search row in
    /// or out with the bar instead of jumping it.
    private func setBarStacked(_ stacked: Bool) {
        guard stacked != barStacked else { return }
        UserDefaults.standard.set(stacked, forKey: Self.barStackedKey)
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { barStacked = stacked }
    }

    /// A query keeps the field up after the keyboard goes away; Cancel
    /// closes it.
    private var showsBarSearch: Bool {
        barSearchOpen || !searchText.isEmpty
    }

    private var barSearchField: some View {
        HStack(spacing: 10) {
            searchCapsule(minHeight: 44)
                .frame(maxHeight: 44)
            Button(AppLocalization.string("Cancel")) {
                searchText = ""
                searchFocused = false
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { barSearchOpen = false }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.conduitAccent)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            // Opened by the magnifier: straight to typing. Not when a
            // running search moved here or the list came back into view.
            if barSearchFocusPending {
                barSearchFocusPending = false
                searchFocused = true
            }
        }
    }

    /// The filter menu's button where the bar stacks: what the list shows,
    /// by name, so the filters aren't hidden behind an icon. It fills the
    /// row up to the controls.
    private func filterPill(waitingApprovalCount: Int) -> some View {
        filterMenu(waitingApprovalCount: waitingApprovalCount) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .semibold))
                    .conduitFixedGlyph()
                Text(showingProjects ? AppLocalization.string("Projects") : selectionTitles(separator: ", "))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .conduitFixedGlyph()
                if waitingApprovalCount > 0 {
                    Circle()
                        .fill(Color.conduitAttention)
                        .frame(width: 8, height: 8)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .conduitGlassControl(cornerRadius: 22, interactive: false)
            .contentShape(Capsule())
        }
    }

    private func filterIcon(waitingApprovalCount: Int) -> some View {
        V2CapsuleIcon(
            systemImage: !narrowsList
                ? "line.3.horizontal.decrease"
                : "line.3.horizontal.decrease.circle.fill",
            dot: waitingApprovalCount > 0 ? Color.conduitAttention : nil
        )
    }

    /// The filter menu behind `button`.
    private func filterMenu<MenuButton: View>(waitingApprovalCount: Int, @ViewBuilder button: () -> MenuButton) -> some View {
        Menu {
            if showingProjects {
                Button {
                    Haptics.selection()
                    showProjectCreator = true
                } label: {
                    Label("New project", systemImage: "folder.badge.plus")
                }
                // Projects shown from the saved list say nothing yet about
                // whether this Hermes takes new ones.
                .disabled(!appState.supportsProjects || appState.projectsSeededFromSavedList)
            } else {
                filterToggle(.all)
                filterToggle(.starred)

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

                if filtersProjects, !filterProjects.isEmpty {
                    Section {
                        projectsFilterMenu
                    }
                }

                if appState.isAllProfilesChatsOn {
                    Section {
                        Toggle(isOn: Binding(
                            get: { appState.allProfilesGroupsByProfile },
                            set: { grouped in
                                Haptics.selection()
                                appState.setAllProfilesGroupsByProfile(grouped)
                            }
                        )) {
                            Label(AppLocalization.string("Group by profile"), systemImage: "rectangle.stack")
                        }
                        .menuActionDismissBehavior(.disabled)
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
                        Haptics.selection()
                        showPinnedReplies = true
                    } label: {
                        Label(AppLocalization.string("Pinned replies"), systemImage: "pin")
                    }
                    Button {
                        Haptics.light()
                        appState.markAllSessionsRead()
                    } label: {
                        Label("Mark all as read", systemImage: "envelope.open")
                    }
                    // The saved rows aren't the live list it marks.
                    .disabled(appState.isShowingSavedChatList || !sourceRows(nil).contains { appState.isSessionUnread($0) })
                }
            }
        } label: {
            button()
        }
        .menuOrder(.fixed)
        // With Projects showing, the menu only makes projects.
        .accessibilityLabel(showingProjects ? AppLocalization.string("Projects") : AppLocalization.string("Filter"))
        .macTooltip(showingProjects ? AppLocalization.string("Projects") : AppLocalization.string("Filter"))
        .accessibilityValue([
            showingProjects ? nil : spokenSelection,
            waitingApprovalCount > 0 ? AppLocalization.string("\(waitingApprovalCount) waiting for approval") : nil
        ].compactMap { $0 }.joined(separator: ", "))
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
            Label("\(option.title) \(String(filterRows(selection.facet(option), searching: false).count))", systemImage: option.symbol)
        }
        .menuActionDismissBehavior(option == .all ? .automatic : .disabled)
    }

    /// Filter ▸ Projects: every project ticked to start, one tick each, and
    /// the menu stays open while picking. All leaves it as it is, so a
    /// project hidden here stays hidden until it's ticked again.
    private var projectsFilterMenu: some View {
        let hidden = hiddenProjects
        let home = appState.projects.first(where: \.isHome)?.title
        return Menu {
            Button {
                Haptics.selection()
                setHiddenProjects([])
            } label: {
                Label(AppLocalization.string("Show all projects"), systemImage: "eye")
            }
            .disabled(hiddenProjectCount == 0)

            Section {
                projectToggle(
                    HiddenChatProjects.noProject,
                    title: home ?? AppLocalization.string("Not in a project"),
                    symbol: home == nil ? "tray" : "house",
                    hidden: hidden
                )
                ForEach(filterProjects) { project in
                    projectToggle(project.id, title: project.title, symbol: "folder", hidden: hidden)
                }
            }
        } label: {
            Label(AppLocalization.string("Projects"), systemImage: "folder")
        }
        .menuActionDismissBehavior(.disabled)
    }

    private func projectToggle(_ id: String, title: String, symbol: String, hidden: Set<String>) -> some View {
        Toggle(isOn: Binding(
            get: { !hidden.contains(id) },
            set: { shown in
                var changed = hiddenProjects
                if shown { changed.remove(id) } else { changed.insert(id) }
                Haptics.selection()
                setHiddenProjects(changed)
            }
        )) {
            Label(title, systemImage: symbol)
        }
        .menuActionDismissBehavior(.disabled)
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

    /// The chosen filters' names, or All, and what Filter ▸ Projects
    /// hides: how many projects, and Home's chats by name, since those are
    /// in no project.
    private func selectionTitles(separator: String) -> String {
        let hidden = showingProjects ? [] : hiddenProjects
        let names = selection.isEmpty && hidden.isEmpty
            ? [V2SessionFilter.all.title]
            : selection.ordered.map(\.title)
        var parts = names
        if hidden.contains(HiddenChatProjects.noProject) {
            if let home = appState.projects.first(where: \.isHome)?.title {
                parts.append(AppLocalization.string("\(home) hidden"))
            } else {
                parts.append(AppLocalization.string("Chats outside projects hidden"))
            }
        }
        let projectCount = hidden.subtracting([HiddenChatProjects.noProject]).count
        if projectCount > 0 {
            parts.append(AppLocalization.string("\(projectCount) projects hidden"))
        }
        return parts.joined(separator: separator)
    }

    /// The chosen filters' names as VoiceOver reads them.
    private var spokenSelection: String {
        selectionTitles(separator: ", ")
    }

    // MARK: - Rows

    /// The rows a source lists (cron runs only under Scheduled, plus the
    /// pinned ones in All, #485). Until this profile's live list lands,
    /// the rows it showed last time.
    private func sourceRows(_ source: SessionSource?) -> [SessionSummary] {
        renderMemo.sourceRows(source) {
            SidebarSourceRows.rows(
                sessions: listed.sessions,
                cronSessions: listed.cron,
                source: source,
                category: category,
                isPinned: appState.isSessionPinned
            )
        }
    }

    /// The row's filter source, worked out once per render: it looks up
    /// the voice tags and voice jobs by every id the row answers to.
    private func category(_ session: SessionSummary) -> SessionSource {
        renderMemo.category(session.nestingIDs.joined(separator: "\u{1F}")) { appState.sessionCategory(for: session) }
    }

    private func filterRows(_ selection: V2FilterSelection, searching: Bool) -> [SessionSummary] {
        renderMemo.filterRows(selection.rawValue, searching: searching) {
            uncachedFilterRows(selection, searching: searching)
        }
    }

    private func uncachedFilterRows(_ selection: V2FilterSelection, searching: Bool, hidingProjects: Bool = true) -> [SessionSummary] {
        let rows: [SessionSummary]
        if selection.isEmpty {
            // Read once, not once per row.
            let projectChats = self.projectChats
            rows = V2ChatsView.allRows(
                sourceRows(nil),
                searching: searching,
                inMainList: { mainListShows($0, projectChats: projectChats) }
            )
        } else {
            rows = selection.rows(
                everything: sourceRows(nil),
                sessions: listed.sessions,
                cronSessions: listed.cron,
                category: category,
                hasStatus: hasStatus
            )
        }
        // A search looks through every chat, a hidden project's too, and
        // Needs approval lists every wait, as the amber dot counts them.
        let hidden = hidingProjects ? hiddenProjects : []
        guard !searching, !hidden.isEmpty else { return rows }
        let listsWaits = selection.contains(.needsApproval)
        return rows.filter { session in
            !HiddenChatProjects.hides(
                projectID: appState.knownProjectID(for: session),
                pinned: appState.isSessionPinned(session),
                listedWait: listsWaits && hasStatus(.needsApproval, session),
                hidden: hidden
            )
        }
    }

    private func hasStatus(_ filter: V2SessionFilter, _ session: SessionSummary) -> Bool {
        switch filter {
        case .starred: return appState.isSessionStarred(session)
        case .unread: return appState.isSessionUnread(session)
        case .needsApproval: return appState.sessionLiveStatus(session) == .needsInput
        case .running: return appState.sessionLiveStatus(session) == .working
        case .all, .voice, .scheduled, .source: return false
        }
    }

    /// A project's conversations live on its page, not in the main list;
    /// a pinned one stays, since pinning asks for it here, and Settings can
    /// list the recent ones or all of them too, by the row's own activity
    /// (a nest's newer call doesn't count). The catalog carries no folder,
    /// so this hides the conversations the project tree is known to hold.
    private func mainListShows(_ session: SessionSummary, projectChats: ProjectChatsInChats) -> Bool {
        guard appState.supportsProjects else { return true }
        return appState.isSessionPinned(session)
            || appState.knownProjectID(for: session) == nil
            || projectChats.shows(lastActivity: session.lastActivityAt)
    }

    /// What All lists. A search looks through every chat, a project's
    /// included, as the status filters do (#708).
    static func allRows(
        _ rows: [SessionSummary],
        searching: Bool,
        inMainList: (SessionSummary) -> Bool
    ) -> [SessionSummary] {
        searching ? rows : rows.filter(inMainList)
    }

    /// A search result's preview led by its project, if it has one.
    static func searchPreview(_ preview: String, projectTitle: String?) -> String {
        guard let projectTitle, !projectTitle.isEmpty else { return preview }
        return preview.isEmpty ? projectTitle : "\(projectTitle) · \(preview)"
    }

    private var displayedSessions: [SessionSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = filterRows(selection, searching: !query.isEmpty)
        guard !query.isEmpty else { return rows }
        return rows.filter { sessionMatches($0, query: query) }
    }

    /// A project's chat names its project while searching or filtering,
    /// or when Settings lists project chats here, since the main list
    /// doesn't otherwise say where it lives.
    private func rowProjectTitle(_ item: V2ChatsListItem, namesProjects: Bool) -> String? {
        guard namesProjects, case .session(let node) = item.kind else { return nil }
        return projectTitle(for: node.session)
    }

    private func projectTitle(for session: SessionSummary) -> String? {
        guard appState.supportsProjects, let projectID = appState.knownProjectID(for: session) else { return nil }
        return appState.projects.first { $0.id == projectID }?.title
    }

    private func sessionMatches(_ session: SessionSummary, query: String) -> Bool {
        // The project name a result shows finds it too.
        [session.title, session.model, session.id, session.preview ?? "", category(session).label]
            .contains { $0.localizedCaseInsensitiveContains(query) }
            || projectTitle(for: session)?.localizedCaseInsensitiveContains(query) == true
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the content search follows: the query, and where it goes.
    private var contentSearchKey: String {
        let bridge = appState.dashboardTicketBridge.map { String(describing: ObjectIdentifier($0)) } ?? "-"
        let others = appState.isAllProfilesChatsOn ? appState.allProfilesIncluded.joined(separator: ",") : ""
        return [showingProjects ? "" : searchText, appState.activeProfile, others, String(appState.isConnected), bridge]
            .joined(separator: "\u{1F}")
    }

    private func updateContentSearch() {
        contentSearch.update(
            query: showingProjects ? "" : searchText,
            context: appState.sessionContentSearchContext(acrossAllProfiles: appState.isAllProfilesChatsOn)
        )
    }

    /// Chats whose messages match and the list above (`displayed`) doesn't
    /// already show. Under a filter, only chats that filter lists.
    private func contentSearchRows(_ displayed: [SessionSummary]) -> [SessionContentSearchRow] {
        guard isSearching, !contentSearch.hits.isEmpty else { return [] }
        let known = appState.activeProfileSessions + appState.activeProfileCronSessions
            + (appState.isAllProfilesChatsOn ? listed.sessions.filter(appState.isOtherProfileRow) : [])
        let rows = SessionContentSearch.rows(
            hits: contentSearch.hits,
            listed: displayed,
            known: known,
            allowed: selection.isEmpty ? nil : filterRows(selection, searching: true),
            activeProfile: appState.isAllProfilesChatsOn ? appState.activeProfile : "",
            owner: { session in appState.isAllProfilesChatsOn ? appState.rowProfile(session) : "" }
        )
        // Pulse's chat stays behind the Pulse screen, message matches too.
        guard appState.showsPulseScreen, let home = appState.pulseHomeChat else { return rows }
        return rows.filter { row in
            row.session.map { !appState.isPulseHomeChat($0) }
                ?? (row.hit.sessionID != home && appState.canonicalSessionID(for: row.hit.sessionID) != home)
        }
    }

    /// Pinned in the order the person set (issue 1354), then Recent.
    private func nestedSections(_ displayed: [SessionSummary]) -> (pinned: [SessionNesting.Node], recent: [SessionNesting.Node]) {
        let sections = SessionNesting.sections(
            displayed,
            query: searchText,
            statusFilterActive: selection.flattens,
            isPinned: appState.isSessionPinned,
            parentKeyOf: appState.sessionNestingParentKey
        )
        return (appState.arrangePinnedNodes(sections.pinned), sections.recent)
    }

    // MARK: - Sessions list

    private var connectionRepairCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = appState.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Haptics.light()
                repairContext = appState.beginConnectionRepair()
            } label: {
                Label("Repair Connection", systemImage: "wrench.and.screwdriver")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.conduitAccent)
            .accessibilityIdentifier("chats.repair-connection")
            .accessibilityLabel("Repair Connection")
            .accessibilityHint("Test and fix the failed connection, then reconnect")
        }
        .padding(14)
        .settingsCard()
    }

    private var sessionsList: some View {
        // Worked out once per render: the rows walk the whole catalog.
        let displayed = displayedSessions
        let sections = nestedSections(displayed)
        let contentRows = contentSearchRows(displayed)
        let expanded = expandedNestIDs
        let layout = SidebarOfflineLayout.visibility(
            showingProjects: false,
            displayedSessionsEmpty: displayed.isEmpty && contentRows.isEmpty,
            isLoadingList: appState.isLoadingChatList
        )
        return List {
            if barStacked == false {
                searchField
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
            }

            // After the first connection to a dashboard added here.
            if appState.showsFinishSetup && !isSearching {
                V2FinishSetupCard()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 12, trailing: 16))
            }

            // A failed connection: the app opens here, not on a composer,
            // so the composer's Repair Connection is offered here too,
            // searching or not.
            if appState.showsConnectionRepair {
                connectionRepairCard
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 12, trailing: 16))
            }

            if layout.loadingState {
                ProgressView(AppLocalization.string("Loading chats…"))
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if layout.emptyState && !contentSearch.isSearching {
                // Only a catalog Hermes answered says "No Sessions": right
                // after a sign-in the list is empty until its first read
                // lands, and a failed read says it failed. Hidden projects
                // are worked out once: it walks the catalog again.
                let hidesEverything = self.hidesEverything
                SessionListPlaceholderView(
                    placeholder: SessionListPlaceholder.resolve(
                        hasRows: false,
                        hasOfflineCopy: false,
                        catalogPhase: appState.sessionCatalogPhase,
                        isRefreshing: appState.isRefreshingSessionCatalog,
                        filteredOutRows: !listed.sessions.isEmpty || !listed.cron.isEmpty
                    ),
                    emptyTitle: hidesEverything
                        ? AppLocalization.string("No chats to show")
                        : selection.emptyStateFilter.emptyTitle,
                    emptyDescription: hidesEverything
                        ? AppLocalization.string("The chats here are hidden in Filter > Projects. Tick them again to show them.")
                        : isSearching
                            ? AppLocalization.string("Try a different search.")
                            : selection.emptyStateFilter.emptyDescription,
                    retry: { Task { await appState.refreshSessionCatalog() } }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if layout.liveSections && appState.allProfilesGroupsByProfile {
                // A section per profile, its pinned chats first.
                ForEach(profileGroups(sections), id: \.profile) { group in
                    profileSection(group.profile, nodes: group.items, expanded: expanded)
                }
            } else {
                if layout.liveSections && !sections.pinned.isEmpty {
                    collapsibleSection(.pinned, nodes: sections.pinned, expanded: expanded)
                }

                if layout.liveSections {
                    ForEach(ChatListSection.byDate(sections.recent)) { group in
                        collapsibleSection(group.section, nodes: group.nodes, expanded: expanded)
                    }
                }
            }

            if layout.liveSections && (!contentRows.isEmpty || contentSearch.isSearching) {
                Section {
                    ForEach(contentRows) { row in
                        contentSearchRow(row)
                    }
                } header: {
                    contentSearchHeader
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Scrolling the list puts the keyboard away; the search stays.
        .scrollDismissesKeyboard(.immediately)
        .environment(\.defaultMinListRowHeight, 1)
        // Right after launch the connection and the catalog publish many
        // times a second: a scroll draws them once it rests.
        .v2HoldsUpdatesWhileScrolling(updates)
        .refreshable {
            appState.refreshAllProfilesCatalog()
            await appState.refreshSessionCatalog()
            await appState.allProfilesCatalogTask?.value
        }
        .onAppear {
            revealActiveNestAncestors()
            revealActiveSection()
        }
        .onChange(of: contentSearchKey, initial: true) { _, _ in updateContentSearch() }
        .onChange(of: appState.activeSessionId) { _, _ in revealActiveNestAncestors() }
        .onChange(of: displayed) { _, _ in
            revealActiveNestAncestors()
            revealActiveSection()
        }
        .onChange(of: appState.pinnedSessionIDs) { _, _ in revealActiveNestAncestors() }
        .onChange(of: appState.voiceSessionTagsByKey) { _, _ in revealActiveNestAncestors() }
        .onChange(of: appState.voiceCallChatLinksRevision) { _, _ in revealActiveNestAncestors() }
        .onChange(of: appState.activeProfile) { _, _ in
            revealLatch = NestRevealLatch()
            revealActiveNestAncestors()
        }
    }

    static let collapsedSectionsKey = "conduit.v2.collapsedChatSections"
    static let collapsedProfilesKey = "conduit.v2.collapsedProfileSections"

    /// A search or a status filter is a lookup: every section shows its
    /// matches, and the saved open/closed state waits for the browse. The
    /// status filters don't narrow Projects' Pinned section.
    private var sectionsCollapsible: Bool {
        !isSearching && (showingProjects || !selection.flattens)
    }

    private func isCollapsed(_ section: ChatListSection) -> Bool {
        sectionsCollapsible && collapsedSections.contains(section)
    }

    private func toggleSection(_ section: ChatListSection, haptic: Bool = true) {
        if haptic { Haptics.selection() }
        var collapsed = collapsedSections
        if collapsed.contains(section) { collapsed.remove(section) } else { collapsed.insert(section) }
        UserDefaults.standard.set(ChatListSection.storageValue(collapsed), forKey: Self.collapsedSectionsKey)
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
            collapsedSections = collapsed
        }
    }

    /// A list section whose header opens and closes it (#696).
    private func collapsibleSection(
        _ section: ChatListSection,
        nodes: [SessionNesting.Node],
        expanded: Set<String>
    ) -> some View {
        Section {
            if !isCollapsed(section) {
                listRows(
                    V2ChatsListItem.items(nodes, expanded: expanded, scope: rowScope),
                    movesPinned: section == .pinned && dragsPinned
                )
            }
        } header: {
            if section == .pinned {
                pinnedHeader(nodes.map(\.session))
            } else {
                collapsibleHeader(section, count: nodes.count)
            }
        }
    }

    /// All grouped by profile: each included profile's rows, its pinned
    /// ones first, in the strip's order.
    private func profileGroups(
        _ sections: (pinned: [SessionNesting.Node], recent: [SessionNesting.Node])
    ) -> [(profile: String, items: [SessionNesting.Node])] {
        AllProfilesChats.groups(
            sections.pinned + sections.recent,
            profiles: appState.allProfilesIncluded,
            fallback: appState.activeProfile,
            owner: { appState.rowProfile($0.session) }
        )
    }

    private func isProfileCollapsed(_ profile: String) -> Bool {
        sectionsCollapsible && collapsedProfiles.contains(profile)
    }

    private func toggleProfileSection(_ profile: String, haptic: Bool = true) {
        if haptic { Haptics.selection() }
        var collapsed = collapsedProfiles
        if collapsed.contains(profile) { collapsed.remove(profile) } else { collapsed.insert(profile) }
        collapsed = collapsed.filter { name in appState.profiles.contains(name) }
        UserDefaults.standard.set(collapsed.sorted().joined(separator: "\n"), forKey: Self.collapsedProfilesKey)
        withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) {
            collapsedProfiles = collapsed
        }
    }

    /// One profile's chats under its picture and name, opening and closing
    /// like the date sections.
    private func profileSection(
        _ profile: String,
        nodes: [SessionNesting.Node],
        expanded: Set<String>
    ) -> some View {
        Section {
            if !isProfileCollapsed(profile) {
                // Its pinned chats lead it, and move among themselves.
                listRows(V2ChatsListItem.items(nodes, expanded: expanded, scope: rowScope), movesPinned: dragsPinned)
            }
        } header: {
            profileSectionHeader(profile, count: nodes.count)
                .reorderPinnedChatsMenu(isOn: nodes.filter { appState.isSessionPinned($0.session) }.count > 1) {
                    pinnedOrderTarget = PinnedChatsOrderTarget(profile: profile)
                }
        }
    }

    private func profileSectionHeader(_ profile: String, count: Int) -> some View {
        let name = appState.profileDisplayName(profile)
        let collapsible = sectionsCollapsible
        let collapsed = isProfileCollapsed(profile)
        return Button {
            toggleProfileSection(profile)
        } label: {
            HStack(spacing: 8) {
                ProfileAvatarView(
                    profile: profile,
                    displayName: name,
                    url: appState.profileAvatarURL(for: profile),
                    size: 20
                )
                Text(name)
                    .lineLimit(1)
                if collapsible {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .conduitFixedGlyph()
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                Spacer(minLength: 6)
                if collapsed {
                    Text(count, format: .number)
                        .monospacedDigit()
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!collapsible)
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppLocalization.string("\(name) profile")))
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(collapsible
            ? (collapsed
                ? Text(AppLocalization.string("Collapsed")) + Text(verbatim: ", ") + Text(count, format: .number)
                : Text(AppLocalization.string("Expanded")))
            : Text(verbatim: ""))
    }

    /// The section's name and a chevron that turns with it; a closed
    /// section counts the chats it hides. While a search or status filter
    /// keeps every section open it is a plain header.
    @ViewBuilder
    private func collapsibleHeader(_ section: ChatListSection, count: Int) -> some View {
        if sectionsCollapsible {
            let collapsed = isCollapsed(section)
            Button {
                toggleSection(section)
            } label: {
                HStack(spacing: 6) {
                    Text(section.title)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .conduitFixedGlyph()
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Spacer(minLength: 6)
                    if collapsed {
                        Text(count, format: .number)
                            .monospacedDigit()
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.leading, 16)
                .padding(.trailing, 16)
                .padding(.vertical, 2)
                // The whole strip is the tap target, at the 44 pt minimum.
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(section.title))
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(collapsed
                ? Text(AppLocalization.string("Collapsed")) + Text(verbatim: ", ") + Text(count, format: .number)
                : Text(AppLocalization.string("Expanded")))
            .accessibilityHint(AppLocalization.string(collapsed
                ? "Shows the chats in this section."
                : "Hides the chats in this section."))
        } else {
            sectionHeader(section.title)
        }
    }

    /// The Pinned header, whose touch-and-hold menu (and VoiceOver action)
    /// reorders the profile in use's pinned chats; in All's mixed section
    /// it offers that once the profile in use has two pins there.
    private func pinnedHeader(_ pinned: [SessionSummary]) -> some View {
        let own = pinned.filter { !appState.isOtherProfileRow($0) }.count
        return collapsibleHeader(.pinned, count: pinned.count)
            .reorderPinnedChatsMenu(isOn: own > 1) {
                pinnedOrderTarget = PinnedChatsOrderTarget(profile: appState.activeProfile)
            }
    }

    /// Opens the section holding a conversation opened from elsewhere (a
    /// notification, a widget, a new chat), so returning to the list shows
    /// its row; a section closed while it stays open stays closed, and a
    /// launch opens the list the way it was left. An activation whose row
    /// hasn't been listed yet waits for the list to bring it.
    private func revealActiveSection() {
        guard let active = pendingSectionReveal, active == appState.activeSessionId else {
            pendingSectionReveal = nil
            return
        }
        guard !showingProjects, sectionsCollapsible else { return }
        if appState.allProfilesGroupsByProfile {
            // The open chat is always the profile in use's.
            pendingSectionReveal = nil
            if let profile = AllProfilesChats.profile(named: appState.activeProfile, in: appState.allProfilesIncluded),
               collapsedProfiles.contains(profile) {
                toggleProfileSection(profile, haptic: false)
            }
            return
        }
        let sections = nestedSections(displayedSessions)
        guard let section = ChatListSection.section(
            of: active,
            pinned: sections.pinned,
            recent: ChatListSection.byDate(sections.recent)
        ) else { return }
        pendingSectionReveal = nil
        if collapsedSections.contains(section) {
            toggleSection(section, haptic: false)
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

    /// "In messages", with a spinner while Hermes is still searching.
    private var contentSearchHeader: some View {
        HStack(spacing: 6) {
            sectionHeader(AppLocalization.string("In messages"))
                .fixedSize()
            if contentSearch.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(AppLocalization.string("Searching messages"))
            }
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets())
    }

    /// A chat Hermes found by its messages: its title, then the matching
    /// line with the match picked out. A listed chat keeps its row actions.
    @ViewBuilder
    private func contentSearchRow(_ row: SessionContentSearchRow) -> some View {
        let button = Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            if let session = row.session, appState.isOtherProfileRow(session) {
                appState.openListedSession(session)
            } else if row.session != nil {
                appState.requestOpenSession(row.openID)
            } else if let owner = row.hit.profile, !AppState.profilesMatch(owner, appState.activeProfile) {
                // Another profile's chat All hasn't listed: its link's way.
                appState.openOtherProfileChat(row.hit.sessionID, inProfile: owner)
            } else {
                // Older than any listed row: the link route opens it and
                // refreshes the list, as a job link does.
                appState.openAppLink(.session(id: row.openID))
            }
        } label: {
            V2ContentMatchRow(
                title: row.title,
                time: contentMatchTime(row),
                snippet: row.hit.snippet,
                isUnread: row.session.map { appState.isSessionUnread($0) } ?? false,
                isStarred: row.session.map { appState.isSessionStarred($0) } ?? false,
                selection: .chat(
                    isActive: row.openID == appState.activeSessionId && row.hit.profile == nil
                        && !(row.session.map(appState.isOtherProfileRow) ?? false),
                    beside: openBeside
                )
            )
        }
        .buttonStyle(.plain)
        if let session = row.session {
            button
                .accessibilityHint(AppLocalization.string("Swipe or touch and hold for conversation actions."))
                .v2ListRow()
                .sessionActions(
                    appState: appState,
                    session: session,
                    nest: nil,
                    onRename: { sessionPendingRename = session },
                    onDelete: { sessionPendingDeletion = session }
                )
        } else {
            button.v2ListRow()
        }
    }

    /// A match's time, led in All by the other profile it was found in.
    private func contentMatchTime(_ row: SessionContentSearchRow) -> String {
        let time = row.session?.updatedLabel ?? ""
        let owner = row.session.map { appState.isOtherProfileRow($0) ? appState.rowProfile($0) : nil } ?? row.hit.profile
        guard let owner, !AppState.profilesMatch(owner, appState.activeProfile) else { return time }
        let name = appState.profileDisplayName(owner)
        return time.isEmpty ? name : "\(name) · \(time)"
    }

    /// "Search Home" names the profile the list belongs to.
    private var searchPrompt: String {
        if showingProjects { return AppLocalization.string("Search projects") }
        if appState.isAllProfilesChatsOn { return AppLocalization.string("Search all profiles") }
        let name = appState.profileDisplayName(appState.activeProfile)
        return AppLocalization.string("Search \(name)")
    }

    /// The 40 pt glass search capsule, with the active filters as one
    /// removable gold chip inside it ("Unread · Chat"). While typing, Cancel
    /// beside it clears the search and puts the keyboard away; Search on
    /// the keyboard or a scroll puts it away and keeps the search.
    private var searchField: some View {
        HStack(spacing: 10) {
            searchCapsule(minHeight: 40)
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

    private func searchCapsule(minHeight: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if narrowsList {
                Button {
                    // The chip names hidden projects too, so it clears them.
                    if shownHiddenProjectCount > 0 { setHiddenProjects([]) }
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
        .frame(minHeight: minHeight)
        .conduitGlassSurface(cornerRadius: minHeight / 2)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: selection)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: hiddenProjectCount)
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
    /// `movesPinned`: the section's pinned chats move by dragging, a hold
    /// then a move (issue 1354); a hold that stays still opens the menu,
    /// and a swipe starts before either.
    private func listRows(_ items: [V2ChatsListItem], movesPinned: Bool = false) -> some View {
        // Read once, not once per row. A search or a filter looks through
        // project chats whatever the setting, so it names them too.
        let namesProjects = isSearching || !selection.isEmpty || projectChats != .hidden
        let movable: [Bool] = movesPinned ? items.map { item in
            guard case .session(let node) = item.kind else { return false }
            return appState.isSessionPinned(node.session) && !appState.isSavedChatRow(node.session)
        } : []
        let movableIDs = Set(zip(items, movable).compactMap { item, canMove in canMove ? item.id : nil })
        let shown: [SessionSummary] = zip(items, movable).compactMap { item, canMove in
            guard canMove, case .session(let node) = item.kind else { return nil }
            return node.session
        }
        let move: ((IndexSet, Int) -> Void)? = shown.count > 1 ? { source, destination in
            guard let offsets = PinnedChatOrder.movableOffsets(fromOffsets: source, toOffset: destination, movable: movable) else { return }
            appState.movePinnedChats(shown, fromOffsets: offsets.source, toOffset: offsets.destination)
        } : nil
        return ForEach(items) { item in
            V2ChatsRow(
                item: item,
                projectTitle: rowProjectTitle(item, namesProjects: namesProjects),
                profileBadge: profileBadge(for:),
                onRename: { sessionPendingRename = $0 },
                onDelete: { sessionPendingDeletion = $0 },
                onReorderPinned: { pinnedOrderTarget = PinnedChatsOrderTarget(profile: appState.rowProfile($0)) },
                setExpanded: setExpanded
            )
            .moveDisabled(!movableIDs.contains(item.id))
        }
        .onMove(perform: move)
    }

    /// Pinned chats move by dragging while the list shows all of them: not
    /// during a search or under a filter, whose rows are a lookup.
    private var dragsPinned: Bool {
        !isSearching && (showingProjects || selection.isEmpty)
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
        let pinned = appState.arrangePinned(SidebarPinnedSessions.forProjectsView(
            sourceRows(nil),
            query: searchText,
            isPinned: appState.isSessionPinned,
            matches: sessionMatches
        ), session: { $0 })
        return List {
            if barStacked == false {
                searchField
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16))
            }

            if !pinned.isEmpty {
                Section {
                    if !isCollapsed(.pinned) {
                        listRows(pinned.map(V2ChatsListItem.leaf), movesPinned: dragsPinned)
                    }
                } header: {
                    pinnedHeader(pinned)
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
        .v2HoldsUpdatesWhileScrolling(updates)
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
                // Not a destructive role: that removes the row before the
                // confirmation is answered, and on a Mac it can blank the list (#1364).
                Button {
                    Haptics.warning()
                    projectPendingDeletion = project
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
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
    /// `scope` leads every id: in All, the row's profile, since another
    /// profile can hold a chat with the same id (a cloned profile).
    static func items(
        _ nodes: [SessionNesting.Node],
        expanded: Set<String>,
        scope: (SessionSummary) -> String = { _ in "" }
    ) -> [V2ChatsListItem] {
        var items: [V2ChatsListItem] = []
        for node in nodes {
            let prefix = scope(node.session)
            items.append(V2ChatsListItem(id: prefix + node.id, kind: .session(node)))
            guard !node.children.isEmpty else { continue }
            let key = SessionNesting.nestKey(of: node.session)
            let isExpanded = expanded.contains(key)
            items.append(V2ChatsListItem(id: prefix + "nest:" + node.id, kind: .nest(node, key: key, isExpanded: isExpanded)))
            guard isExpanded else { continue }
            let descendants = descendants(of: node.children, depth: 0)
            for (index, entry) in descendants.enumerated() {
                items.append(V2ChatsListItem(
                    id: prefix + entry.session.id,
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
    /// The list's updates (`V2ShownUpdates`): a row under a pushed chat
    /// waits with the list.
    @EnvironmentObject private var updates: V2ShownUpdates
    private var appState: AppState { updates.appState }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v2OpenBeside) private var openBeside
    let item: V2ChatsListItem
    /// The project a listed project chat sits in, named before its preview.
    let projectTitle: String?
    /// All: the picture of the profile a row belongs to.
    let profileBadge: (SessionSummary) -> V2ProfileBadge?
    let onRename: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void
    /// Opens Reorder pinned chats from a pinned row's menu.
    let onReorderPinned: (SessionSummary) -> Void
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
                    appState: appState,
                    session: session,
                    nest: nil,
                    isSavedRow: appState.isSavedChatRow(session),
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
        let preview = appState.v2RowPreview(for: session)
        let hasChildren = !node.children.isEmpty
        let signals = SessionNesting.signals(
            node,
            isUnread: appState.isSessionUnread,
            liveStatus: appState.sessionLiveStatus
        )
        return Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            appState.openListedSession(session)
        } label: {
            V2SessionRow(
                title: session.title,
                time: session.updatedLabel,
                preview: V2ChatsView.searchPreview(preview, projectTitle: projectTitle),
                status: appState.v2RowStatus(for: session),
                isUnread: signals.isUnread,
                isStarred: appState.isSessionStarred(session),
                selection: selection(session),
                icon: appState.sessionCategory(for: session),
                hasNestBelow: hasChildren,
                profileBadge: profileBadge(session)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(AppLocalization.string("Swipe or touch and hold for conversation actions."))
        .v2SelectedTrait(selection(session))
        .v2ListRow(divider: !hasChildren, dividerInset: V2SessionRow.iconTextInset)
        .sessionActions(
            appState: appState,
            session: session,
            nest: SessionNesting.readToggleInputs(for: node, aggregateIsUnread: signals.isUnread),
            isSavedRow: appState.isSavedChatRow(session),
            onRename: { onRename(session) },
            onDelete: { onDelete(session) },
            onReorderPinned: { onReorderPinned(session) }
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
        let isStarred = appState.isSessionStarred(session)
        let rowSelection = selection(session, faintAlone: false)
        return Button {
            Haptics.light()
            appState.dismissSidebarDrawer()
            appState.openListedSession(session)
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
                if isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.conduitAccent)
                        .accessibilityHidden(true)
                }
                Text(status.actionWord ?? session.updatedLabel)
                    .font(.footnote)
                    .foregroundStyle(status.actionWord == nil ? Color.primary.opacity(0.45) : status.color)
                    .lineLimit(1)
            }
            .padding(.trailing, 16)
            .frame(minHeight: 36)
            .v2RowSelection(rowSelection)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(session.title))
        .accessibilityValue(Text([
            AppLocalization.string("From \(parentTitle)"),
            isUnread ? AppLocalization.string("Unread") : nil,
            isStarred ? AppLocalization.string("Starred") : nil,
            status.accessibilityWord,
            session.updatedLabel
        ].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(AppLocalization.string("Swipe or touch and hold for conversation actions."))
        .accessibilityAddTraits(.isButton)
        .v2SelectedTrait(rowSelection)
    }

    /// The open chat's mark: a phone's faint shade, or beside the chat on a
    /// split window the highlight. Another profile's row in All is never
    /// the open chat, whatever its id.
    private func selection(_ session: SessionSummary, faintAlone: Bool = true) -> V2RowSelection {
        .chat(
            isActive: session.id == appState.activeSessionId && !appState.isOtherProfileRow(session),
            beside: openBeside,
            faintAlone: faintAlone
        )
    }
}

// MARK: - Row actions

extension View {
    /// The conversation actions every V2 session row carries: the context
    /// menu (Rename, Pin, Star, Read, Move to Project, Archive, Delete) and the
    /// drawer's swipes. A saved row (the list as it showed last time, up
    /// while Conduit connects) takes none: they would act on a list Hermes
    /// hasn't sent yet.
    func sessionActions(
        appState: AppState,
        session: SessionSummary,
        nest: NestReadToggle?,
        excludingProjectID: String? = nil,
        isSavedRow: Bool = false,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onChanged: @escaping () -> Void = {},
        onReorderPinned: (() -> Void)? = nil
    ) -> some View {
        modifier(V2SessionActions(
            appState: appState,
            session: session,
            nest: nest,
            excludingProjectID: excludingProjectID,
            isSavedRow: isSavedRow,
            onRename: onRename,
            onDelete: onDelete,
            onChanged: onChanged,
            onReorderPinned: onReorderPinned
        ))
    }
}

private struct V2SessionActions: ViewModifier {
    /// Not followed here: the row redraws its actions, so a Chats row
    /// under a pushed chat waits with its list.
    let appState: AppState
    let session: SessionSummary
    let nest: NestReadToggle?
    let excludingProjectID: String?
    let isSavedRow: Bool
    let onRename: () -> Void
    let onDelete: () -> Void
    let onChanged: () -> Void
    let onReorderPinned: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if !isSavedRow {
                    SessionActionMenuItems(
                        session: session,
                        excludingProjectID: excludingProjectID,
                        nest: nest,
                        onRename: onRename,
                        onDelete: onDelete,
                        onChanged: onChanged,
                        onReorderPinned: onReorderPinned
                    )
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if !isSavedRow {
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

                    Button {
                        Haptics.light()
                        appState.toggleSessionStarred(session)
                    } label: {
                        Label(
                            appState.isSessionStarred(session) ? AppLocalization.string("Unstar") : AppLocalization.string("Star"),
                            systemImage: appState.isSessionStarred(session) ? "star.slash" : "star"
                        )
                    }
                    .tint(.yellow)

                    ReadStateToggleButton(session: session, nest: nest)
                        .tint(.blue)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !isSavedRow {
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

                    // Not a destructive role: that removes the row before the
                    // confirmation is answered, and on a Mac it can blank the list (#1364).
                    Button {
                        Haptics.warning()
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    .disabled(appState.isSessionMutationInFlight(session))
                }
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

/// What one render of the Chats list works out from the catalog, shared
/// by the list, the filter menu and the menu's counts. Right after launch
/// the catalog publishes many times a second, and each render used to walk
/// it a dozen times (the menu alone once per filter). Emptied at the start
/// of every render, so nothing outlives the state it was read from.
@MainActor
final class V2ChatsRenderMemo {
    private var sources: [SessionSource?: [SessionSummary]] = [:]
    private var categories: [String: SessionSource] = [:]
    private var filtered: [String: [SessionSummary]] = [:]
    private var listed: (sessions: [SessionSummary], cron: [SessionSummary])?

    func reset() {
        listed = nil
        sources.removeAll(keepingCapacity: true)
        categories.removeAll(keepingCapacity: true)
        filtered.removeAll(keepingCapacity: true)
    }

    func sourceRows(_ source: SessionSource?, _ make: () -> [SessionSummary]) -> [SessionSummary] {
        if let rows = sources[source] { return rows }
        let rows = make()
        sources[source] = rows
        return rows
    }

    func listed(_ make: () -> (sessions: [SessionSummary], cron: [SessionSummary])) -> (sessions: [SessionSummary], cron: [SessionSummary]) {
        if let listed { return listed }
        let made = make()
        listed = made
        return made
    }

    func category(_ key: String, _ make: () -> SessionSource) -> SessionSource {
        if let category = categories[key] { return category }
        let category = make()
        categories[key] = category
        return category
    }

    func filterRows(_ selection: String, searching: Bool, _ make: () -> [SessionSummary]) -> [SessionSummary] {
        let key = searching ? selection + "\u{1F}searching" : selection
        if let rows = filtered[key] { return rows }
        let rows = make()
        filtered[key] = rows
        return rows
    }
}
