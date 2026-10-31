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

    // The file being viewed.
    @Published private(set) var viewed: WorkspaceEntry?
    @Published private(set) var viewedLine: Int?
    @Published private(set) var preview: WorkspaceFilePreview?
    @Published private(set) var previewError: String?
    @Published private(set) var previewLoading = false

    private weak var appState: AppState?
    /// Where the open folder's listing and recent files are kept: on the
    /// dashboard it opened on, for its profile.
    private var answers: KeptAnswers?
    /// The open folder shows the listing kept last time, which no answer
    /// has replaced yet.
    private var showsKeptRoot = false
    /// Bumped by every change of scope: an answer asked before it is stale.
    private var generation = 0
    private var previewRequest: UUID?
    private var searchRequest: UUID?

    var root: String? { scope?.root }

    /// Whether the plugin serves search, recent files and file actions.
    var canChange: Bool { appState?.supportsWorkspaceFiles ?? false }

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
        await load(root)
        await loadRecent()
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
        closeFile()
    }

    /// The open folders again, in place: after Hermes changed files, a
    /// pull to refresh, or a change made here.
    func refresh() async {
        guard let scope else { return }
        let folders = [scope.root] + expanded.sorted()
        for folder in folders {
            // Another folder opened meanwhile: the rest belongs to the old one.
            guard self.scope == scope else { return }
            await load(folder)
        }
        guard self.scope == scope else { return }
        await loadRecent()
        if let query = search?.query, !query.isEmpty {
            await runSearch(query)
        }
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
        let base = AppState.normalizedWorkspacePath(root)
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
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
            if appState.supportsWorkspaceFiles {
                let listing = try await appState.workspaceFilesClient(profile: scope.profile)
                    .list(root: scope.root, path: folder, keptIn: answers)
                listed = listing.entries
                cut = listing.truncated
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

    private func loadRecent() async {
        guard let appState, let scope, appState.supportsWorkspaceFiles else { return }
        let ticket = generation
        let owner = appState.currentDashboardRuntimeOwner()
        guard let found = try? await appState.workspaceFilesClient(profile: scope.profile)
                .recent(root: scope.root, keptIn: answers),
              isCurrent(ticket, owner, scope.profile) else { return }
        recent = found
    }

    /// Names and lines inside files matching `query`; an empty query ends
    /// the search. Only the latest search's answer shows.
    func runSearch(_ query: String) async {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let appState, let scope, appState.supportsWorkspaceFiles, !words.isEmpty else {
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
        preview = nil
        previewError = nil
        previewLoading = true
        defer { if previewRequest == request { previewLoading = false } }
        do {
            let text = try await appState.readWorkspaceText(entry.path, profile: profile)
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
        for folder in folders where !expanded.contains(folder) {
            expanded.insert(folder)
            if entries[folder] == nil, !(await load(folder)) {
                expanded.remove(folder)
                break
            }
        }
        let parent = (path as NSString).deletingLastPathComponent
        if let listed = entries[parent == AppState.normalizedWorkspacePath(root) ? root : parent]?.first(where: { $0.path == path }) {
            entry = listed
        }
        return entry
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

    /// The viewed file after a save, its new date the next save checks.
    func saved(_ entry: WorkspaceEntry, text: String) {
        guard viewed?.path == entry.path else { return }
        viewed = entry
        if var preview {
            preview.text = text
            preview.byteSize = text.utf8.count
            self.preview = preview
        }
    }
}
