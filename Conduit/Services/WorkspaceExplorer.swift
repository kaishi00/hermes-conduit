import Foundation

/// One Folder tab's state (#1389): the folder it has open, the folders
/// expanded in its tree, search, recent files and the file being viewed.
/// Every answer is for the dashboard, profile and folder it was asked
/// under: one that lands after any of them changed is dropped, its failure
/// too, so another server's or folder's files never show here. A folder
/// opens on its listing and recent files as the plugin gave them last time
/// (#1533), kept on the phone, while it asks again.
@MainActor
final class WorkspaceExplorer: ObservableObject {
    struct Scope: Equatable {
        let dashboard: UUID?
        let profile: String
        let root: String
    }

    @Published private(set) var scope: Scope?
    @Published private(set) var entries: [String: [WorkspaceEntry]] = [:]
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var loading: Set<String> = []
    /// Folders holding more than the host lists.
    @Published private(set) var truncated: Set<String> = []
    /// A folder that couldn't be read, or an action that failed.
    @Published var error: String?
    @Published private(set) var recent: [WorkspaceEntry] = []
    @Published private(set) var search: WorkspaceSearchResult?
    /// Why the latest search failed; a folder's failure is `error`.
    @Published private(set) var searchError: String?
    @Published private(set) var searching = false
    /// What to do when the open folder's profile has the plugin turned off
    /// (Hermes answers its routes "Plugin not found", issue 1438): the
    /// folder browses through Hermes' own listing meanwhile, with no search
    /// or changes, though the dashboard's own profile reports the routes.
    @Published private(set) var pluginOff: String?
    /// What Copy picked, for Paste into a folder of the open one.
    @Published var copied: WorkspaceEntry?

    // The file being viewed.
    @Published private(set) var viewed: WorkspaceEntry?
    @Published private(set) var viewedLine: Int?
    @Published private(set) var preview: WorkspaceFilePreview?
    @Published private(set) var previewError: String?
    @Published private(set) var previewLoading = false
    /// The files opened since the folder did, one tab each (issue 1438),
    /// the viewed one among them; the oldest goes past `openFilesLimit`.
    @Published private(set) var openFiles: [WorkspaceEntry] = []
    static let openFilesLimit = 12
    /// Open files with unsaved changes, which a new tab never pushes out.
    var keepsOpen: Set<String> = []
    /// Bumped when the viewed file's tab went with no other left: the
    /// reader closes rather than show a file that isn't there.
    @Published private(set) var viewedGone = 0

    private weak var appState: AppState?
    /// Where the open folder's listing and recent files are kept: on the
    /// dashboard it opened on, for its profile.
    private var answers: KeptAnswers?
    /// The open folder shows the listing kept last time, which no answer
    /// has replaced yet.
    private var showsKeptRoot = false
    /// Bumped by every change of scope: an answer asked before it is stale.
    private var generation = 0
    /// Bumped by each read that asks the plugin: only the latest one says
    /// whether it's on for the profile, so an older read's refusal landing
    /// after a newer answer doesn't turn it off again.
    private var pluginAsk = 0
    private var previewRequest: UUID?
    private var searchRequest: UUID?

    var root: String? { scope?.root }

    /// Whether the plugin serves search, recent files and file actions for
    /// the open folder's profile.
    var canChange: Bool { (appState?.supportsWorkspaceFiles ?? false) && pluginOff == nil }

    /// Whether the plugin pastes a copy into another folder.
    var canCopy: Bool { canChange && (appState?.notifierPlugin.reports(WorkspaceFilesClient.copyCapability) ?? false) }

    /// Whether `source` may go into `folder`: not where it already is, and
    /// a folder never into itself or a folder inside it.
    static func canMove(_ source: String, into folder: String) -> Bool {
        let from = AppState.normalizedWorkspacePath(source)
        let to = AppState.normalizedWorkspacePath(folder)
        guard to != from, !AppState.workspacePath(to, isIn: from) else { return false }
        return AppState.parentWorkspacePath(from).map(AppState.normalizedWorkspacePath) != to
    }

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    /// Opens `root` for `profile`, from scratch (another folder, profile or
    /// server), or keeps what is open when nothing changed.
    func open(root: String, profile: String) async {
        guard let appState else { return }
        let next = Scope(dashboard: appState.activeDashboardID, profile: profile, root: root)
        guard next != scope else { return }
        generation &+= 1
        scope = next
        entries = [:]
        expanded = []
        loading = []
        truncated = []
        error = nil
        recent = []
        search = nil
        searchError = nil
        searching = false
        pluginOff = nil
        copied = nil
        openFiles = []
        keepsOpen = []
        closeFile()
        let answers = appState.screenAnswers(profile: profile)
        self.answers = answers
        // Before Hermes answers, so nothing comes or goes when it does.
        let client = appState.workspaceFilesClient(profile: profile)
        let kept = client.keptListing(root: root, path: root, in: answers)
        if let kept {
            entries[root] = kept.entries
            if kept.truncated { truncated.insert(root) }
        }
        showsKeptRoot = kept != nil
        recent = client.keptRecent(root: root, in: answers) ?? []
        askPluginIfUnanswered()
        // Two independent reads: together, not one after the other
        // (issue 1964).
        async let listed = load(root)
        async let recentRead: Void = loadRecent()
        _ = await (listed, recentRead)
    }

    /// Clears everything: no folder to show (a chat Hermes hasn't given a
    /// folder yet).
    func close() {
        generation &+= 1
        scope = nil
        answers = nil
        showsKeptRoot = false
        entries = [:]
        expanded = []
        loading = []
        truncated = []
        error = nil
        recent = []
        search = nil
        searchError = nil
        pluginOff = nil
        copied = nil
        openFiles = []
        keepsOpen = []
        closeFile()
    }

    /// The open folders again, in place: after Hermes changed files, a
    /// pull to refresh, or a change made here.
    func refresh() async {
        guard let scope else { return }
        askPluginIfUnanswered()
        let folders = [scope.root] + expanded.sorted()
        var listed: Set<String> = []
        for folder in folders {
            // Another folder opened meanwhile: the rest belongs to the old one.
            guard self.scope == scope else { return }
            if await load(folder) { listed.insert(folder) }
        }
        guard self.scope == scope else { return }
        dropGoneTabs(read: listed)
        await loadRecent()
        if let query = search?.query, !query.isEmpty {
            await runSearch(query)
        }
    }

    /// Connected, and the plugin never said what it serves (its read failed
    /// as Conduit connected): asked again, as the Artifacts list asks, so a
    /// kept listing, which waits for its word, isn't left up until the next
    /// connect. The Folder reads again once it answers (its `Changes`).
    private func askPluginIfUnanswered() {
        guard let appState, !appState.supportsWorkspaceFiles, appState.isConnected,
              appState.notifierPlugin.state == .unknown else { return }
        Task { await appState.refreshNotifierPluginStatus() }
    }

    /// Opens or closes `folder`. Returns why it couldn't open, for the
    /// screen to say: the tree above it still shows, so `error` doesn't.
    @discardableResult
    func toggle(_ folder: WorkspaceEntry) async -> String? {
        guard folder.isDirectory else { return nil }
        if expanded.contains(folder.path) {
            expanded.remove(folder.path)
            return nil
        }
        expanded.insert(folder.path)
        guard entries[folder.path] == nil else { return nil }
        guard !(await load(folder.path)) else { return nil }
        expanded.remove(folder.path)
        guard let message = error, let root = scope?.root, entries[root] != nil else { return nil }
        error = nil
        return message
    }

    /// The tree as rows: each folder's entries under it while it's expanded.
    func rows() -> [(entry: WorkspaceEntry, depth: Int)] {
        guard let root else { return [] }
        return flatten(root, depth: 0)
    }

    private func flatten(_ folder: String, depth: Int) -> [(entry: WorkspaceEntry, depth: Int)] {
        (entries[folder] ?? []).flatMap { entry -> [(entry: WorkspaceEntry, depth: Int)] in
            var result = [(entry: entry, depth: depth)]
            if entry.isDirectory, expanded.contains(entry.path) {
                result += flatten(entry.path, depth: depth + 1)
            }
            return result
        }
    }

    /// Whether `path` is in the open folder.
    func contains(_ path: String) -> Bool {
        guard let root else { return false }
        return AppState.workspacePath(path, isIn: root)
    }

    // MARK: - Reading

    /// Whether an answer asked at `ticket` under `owner` still belongs here.
    private func isCurrent(_ ticket: Int, _ owner: AppState.DashboardRuntimeOwner?, _ profile: String) -> Bool {
        guard ticket == generation, let appState, scope?.profile == profile else { return false }
        if let owner { return appState.ownsDashboardRuntime(owner) }
        return true
    }

    @discardableResult
    private func load(_ folder: String) async -> Bool {
        guard let appState, let scope else { return false }
        let ticket = generation
        let owner = appState.currentDashboardRuntimeOwner()
        // The folder's own listing is what it opens on next time; Hermes'
        // own listing (an older plugin) has no sizes or dates to keep.
        let answers = folder == scope.root ? self.answers : nil
        loading.insert(folder)
        defer { if ticket == generation { loading.remove(folder) } }
        do {
            let listed: [WorkspaceEntry]
            var cut = false
            // Whether this read says if the plugin is on for the profile:
            // its answer for the open folder, or its refusal for any folder.
            var askedPlugin = false
            var remedy: String?
            var ask = 0
            // With the plugin off for this profile, a folder in the tree
            // reads Hermes' listing straight away; the open folder asks the
            // plugin again each time, so turning it on shows on a refresh.
            if appState.supportsWorkspaceFiles, pluginOff == nil || folder == scope.root {
                pluginAsk &+= 1
                ask = pluginAsk
                do {
                    let listing = try await appState.workspaceFilesClient(profile: scope.profile)
                        .list(root: scope.root, path: folder, keptIn: answers)
                    listed = listing.entries
                    cut = listing.truncated
                    askedPlugin = folder == scope.root
                } catch let refused where DashboardTicketBridgeError.pluginOffDetail(of: refused) != nil {
                    guard isCurrent(ticket, owner, scope.profile) else { return false }
                    askedPlugin = true
                    remedy = DashboardTicketBridgeError.pluginOffDetail(of: refused)
                    // Said even when Hermes' own listing then fails too, so
                    // no change is offered on a profile that refuses them.
                    if ask == pluginAsk { markPluginOff(remedy) }
                    listed = try await appState.workspaceDirectoryEntries(at: folder, profile: scope.profile)
                }
            } else if folder == scope.root, showsKeptRoot,
                      appState.notifierPlugin.mayServe(WorkspaceFilesClient.capability) {
                // The kept listing waits for the plugin's word, as kept
                // Artifacts rows do: Hermes' own listing has no sizes or
                // dates, and the folder reads again once the plugin says
                // whether it serves the routes.
                return false
            } else {
                listed = try await appState.workspaceDirectoryEntries(at: folder, profile: scope.profile)
            }
            // The bridge's invalidation makes a late answer throw; this
            // re-check also covers a switch landing between that answer and
            // this resumption, so no other dashboard's listing merges in.
            guard isCurrent(ticket, owner, scope.profile) else { return false }
            if askedPlugin, ask == pluginAsk { markPluginOff(remedy) }
            entries[folder] = listed
            if cut { truncated.insert(folder) } else { truncated.remove(folder) }
            if folder == scope.root { showsKeptRoot = false }
            return true
        } catch is CancellationError {
            // A refresh replaced by the next one: that one reports.
            return false
        } catch {
            // A switch invalidates the bridge, so a listing still in flight
            // fails; that failure belongs to the dashboard switched away
            // from and isn't reported over the next.
            guard isCurrent(ticket, owner, scope.profile) else { return false }
            if folder == scope.root || entries[folder] == nil {
                self.error = UserFacingError.message(for: error)
            }
            return false
        }
    }

    /// Whether the open folder's profile has the plugin off (`remedy`) or
    /// on again (nil).
    private func markPluginOff(_ remedy: String?) {
        guard remedy != pluginOff else { return }
        pluginOff = remedy
        guard remedy != nil else { return }
        // Nothing the plugin gave for this profile still shows.
        recent = []
        search = nil
        searchError = nil
        copied = nil
    }

    private func loadRecent() async {
        guard let appState, let scope, canChange else { return }
        let ticket = generation
        let owner = appState.currentDashboardRuntimeOwner()
        guard let found = try? await appState.workspaceFilesClient(profile: scope.profile)
                .recent(root: scope.root, keptIn: answers),
              isCurrent(ticket, owner, scope.profile), pluginOff == nil else { return }
        recent = found
    }

    /// Names and lines inside files matching `query`; an empty query ends
    /// the search. Only the latest search's answer shows.
    func runSearch(_ query: String) async {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appState, let scope, canChange, !words.isEmpty else {
            searchRequest = nil
            search = nil
            searchError = nil
            searching = false
            return
        }
        let ticket = generation
        let request = UUID()
        searchRequest = request
        let owner = appState.currentDashboardRuntimeOwner()
        searching = true
        defer { if searchRequest == request { searching = false } }
        do {
            let found = try await appState.workspaceFilesClient(profile: scope.profile).search(root: scope.root, query: words)
            guard searchRequest == request, isCurrent(ticket, owner, scope.profile) else { return }
            search = found
            searchError = nil
        } catch is CancellationError {
            return
        } catch {
            guard searchRequest == request, isCurrent(ticket, owner, scope.profile) else { return }
            search = WorkspaceSearchResult(query: words, names: [], matches: [], truncated: false)
            searchError = UserFacingError.message(for: error)
        }
    }

    // MARK: - Viewing

    /// Shows `entry`'s text. Only the latest pick's answer (or failure)
    /// shows, and it is the one that ends the loading state.
    func view(_ entry: WorkspaceEntry, line: Int? = nil) async {
        guard let appState else { return }
        let profile = scope?.profile ?? appState.workspaceProfile
        let ticket = generation
        let owner = appState.currentDashboardRuntimeOwner()
        let request = UUID()
        previewRequest = request
        viewed = entry
        viewedLine = line
        if let index = openFiles.firstIndex(where: { $0.path == entry.path }) {
            openFiles[index] = entry
        } else {
            openFiles.append(entry)
            while openFiles.count > Self.openFilesLimit,
                  let oldest = openFiles.firstIndex(where: { $0.path != entry.path && !keepsOpen.contains($0.path) }) {
                openFiles.remove(at: oldest)
            }
        }
        preview = nil
        previewError = nil
        previewLoading = true
        defer { if previewRequest == request { previewLoading = false } }
        let early = takePrefetchedText(entry.path, profile: profile)
        do {
            let text: WorkspaceFilePreview
            if let early {
                text = try await early.value
            } else {
                text = try await appState.readWorkspaceText(entry.path, profile: profile)
            }
            guard previewRequest == request, ticket == generation,
                  owner.map(appState.ownsDashboardRuntime) ?? true else { return }
            preview = text
        } catch is CancellationError {
            return
        } catch {
            guard previewRequest == request, ticket == generation,
                  owner.map(appState.ownsDashboardRuntime) ?? true else { return }
            previewError = UserFacingError.message(for: error)
        }
    }

    /// A file a reply named, read while its folders are still listed: the
    /// text read starts with the tap instead of after the folder listings
    /// it doesn't need (issue 1964). `view` takes it up for the same file.
    /// A read left behind (its tap replaced, or the file never opened) is
    /// no use after this: a later open reads the file again.
    private var prefetchedText: (path: String, profile: String, dashboard: UUID?, at: Date, read: Task<WorkspaceFilePreview, Error>)?
    static let prefetchedTextLifetime: TimeInterval = 30

    func prefetchText(_ path: String, profile: String) {
        guard let appState else { return }
        // The same file's read still under way is kept; any other one no
        // open can take up any more stops.
        if let kept = prefetchedText {
            if Self.prefetchedTextFits(
                path: kept.path, profile: kept.profile, dashboard: kept.dashboard, readAt: kept.at,
                openingPath: path, profile: profile, dashboard: appState.activeDashboardID, now: Date()
            ) { return }
            kept.read.cancel()
        }
        prefetchedText = (path, profile, appState.activeDashboardID, Date(), Task {
            try await appState.readWorkspaceText(path, profile: profile)
        })
    }

    private func takePrefetchedText(_ path: String, profile: String) -> Task<WorkspaceFilePreview, Error>? {
        guard let kept = prefetchedText else { return nil }
        prefetchedText = nil
        guard Self.prefetchedTextFits(
            path: kept.path, profile: kept.profile, dashboard: kept.dashboard, readAt: kept.at,
            openingPath: path, profile: profile, dashboard: appState?.activeDashboardID, now: Date()
        ) else {
            kept.read.cancel()
            return nil
        }
        return kept.read
    }

    /// Whether a read started at `readAt` is the one an open of
    /// `openingPath` can take up: the same file, profile and dashboard,
    /// within `prefetchedTextLifetime`.
    static func prefetchedTextFits(
        path: String, profile: String, dashboard: UUID?, readAt: Date,
        openingPath: String, profile openingProfile: String, dashboard openingDashboard: UUID?, now: Date
    ) -> Bool {
        path == openingPath && profile == openingProfile && dashboard == openingDashboard
            && now.timeIntervalSince(readAt) < prefetchedTextLifetime
    }

    func closeFile() {
        previewRequest = nil
        viewed = nil
        viewedLine = nil
        preview = nil
        previewError = nil
        previewLoading = false
    }

    /// A path a reply named, or a search match: its folders expand in the
    /// tree when it's in the open folder, and the file opens.
    func reveal(_ path: String) async -> WorkspaceEntry {
        let name = (path as NSString).lastPathComponent
        var entry = WorkspaceEntry(name: name.isEmpty ? path : name, path: path, isDirectory: false)
        guard let root, contains(path), path != AppState.normalizedWorkspacePath(root) else { return entry }
        var folders: [String] = []
        var folder = (path as NSString).deletingLastPathComponent
        while contains(folder), folder != AppState.normalizedWorkspacePath(root), !folder.isEmpty {
            folders.insert(folder, at: 0)
            folder = (folder as NSString).deletingLastPathComponent
        }
        // Every unlisted folder on the way is read at once, not one after
        // another (issue 1964). A folder that fails stays closed, and so do
        // the ones inside it, as the walk used to stop there.
        let opening = folders.filter { !expanded.contains($0) }
        expanded.formUnion(opening)
        let reads = opening.filter { entries[$0] == nil }.map { folder in
            (folder, Task { await self.load(folder) })
        }
        var failedAt: Int?
        for (folder, read) in reads {
            let listed = await read.value
            if !listed, let index = folders.firstIndex(of: folder) {
                failedAt = min(failedAt ?? index, index)
            }
        }
        if let failedAt {
            expanded.subtract(folders[failedAt...].filter(opening.contains))
        }
        if let listed = listed(path) { entry = listed }
        return entry
    }

    /// `path` as its folder's listing has it, with its modified date.
    func listed(_ path: String) -> WorkspaceEntry? {
        guard let root else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return entries[parent == AppState.normalizedWorkspacePath(root) ? root : parent]?.first(where: { $0.path == path })
    }

    // MARK: - Changing

    /// Runs a change through the plugin and reads the folders again. A
    /// refusal is shown, and returned for the caller (a stale save).
    @discardableResult
    func change(_ action: (WorkspaceFilesClient, String) async throws -> Void) async -> Error? {
        guard let appState, let scope else { return nil }
        let ticket = generation
        let owner = appState.currentDashboardRuntimeOwner()
        do {
            try await action(appState.workspaceFilesClient(profile: scope.profile), scope.root)
            guard isCurrent(ticket, owner, scope.profile) else { return nil }
            Haptics.success()
            await refresh()
            return nil
        } catch {
            guard isCurrent(ticket, owner, scope.profile) else { return nil }
            Haptics.error()
            return error
        }
    }

    /// After a refresh (a change, pull to refresh, the agent's edits): a
    /// tab, or the copied entry, whose folder was just read in full and no
    /// longer lists it goes, so it never opens a file that isn't there. A
    /// tab with unsaved changes stays; the reader moves off a tab that goes.
    private func dropGoneTabs(read: Set<String>) {
        guard let root else { return }
        let base = AppState.normalizedWorkspacePath(root)
        // Gone when a folder on its way up, just read in full, no longer
        // lists the part below it (the file, or a folder holding it).
        func gone(_ path: String) -> Bool {
            var child = path
            while let parent = AppState.parentWorkspacePath(child), contains(parent) {
                let atTop = AppState.normalizedWorkspacePath(parent) == base
                let folder = atTop ? root : parent
                if read.contains(folder), !truncated.contains(folder), let listed = entries[folder],
                   !listed.contains(where: { $0.path == child }) {
                    return true
                }
                if atTop { break }
                child = parent
            }
            return false
        }
        openFiles.removeAll { gone($0.path) && !keepsOpen.contains($0.path) }
        if let copied, gone(copied.path) { self.copied = nil }
        if let viewed, !openFiles.contains(where: { $0.path == viewed.path }) {
            if let next = openFiles.last {
                Task { await view(next) }
            } else {
                viewedGone += 1
            }
        }
    }

    /// Takes `path`'s tab away; the sheet shows another or closes.
    func closeTab(_ path: String) {
        openFiles.removeAll { $0.path == path }
    }

    /// The viewed file after a save, its new date the next save checks.
    func saved(_ entry: WorkspaceEntry, text: String) {
        if let index = openFiles.firstIndex(where: { $0.path == entry.path }) { openFiles[index] = entry }
        guard viewed?.path == entry.path else { return }
        viewed = entry
        if var preview {
            preview.text = text
            preview.byteSize = text.utf8.count
            self.preview = preview
        }
    }
}
