//
//  AppState+Projects.swift
//  Conduit
//
//  Projects: listing, creating, renaming, deleting and moving sessions
//  between them, project folders and ideas, and the workspace folders
//  opened. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Projects and workspace folders

    /// Project navigation is always present in the drawer because every current
    /// Hermes profile has the immutable Home project. Load its authoritative
    /// tree independently of the session catalog so opening the drawer never
    /// depends on a manual Session refresh.
    func refreshProjects() async {
        guard let client else { return }
        await loadProjects(using: client, profile: activeProfile)
    }

    /// How long the projects read after a catalog read stay current when
    /// the catalog read changed nothing (issue 2357). A project's chat
    /// count moves with the list, and the Projects page reads on its own.
    static let projectsRereadInterval: TimeInterval = SessionCatalogCache.fullHistoryRefreshInterval

    /// Whether a catalog read that listed nothing new reads the projects
    /// too: never read for this profile and client, read too long ago, or
    /// still the saved list's.
    func projectsNeedReading(using client: HermesClient, profile: String, now: Date = Date()) -> Bool {
        guard let read = shownBot.projectsRead, read.profile == profile, read.client == ObjectIdentifier(client),
              !projectsSeededFromSavedList else { return true }
        return now.timeIntervalSince(read.at) >= Self.projectsRereadInterval || now < read.at
    }

    /// True when Hermes' list came in and is the one shown.
    @discardableResult
    func loadProjects(using client: HermesClient, profile: String) async -> Bool {
        shownBot.projectsRequestGeneration += 1
        let generation = shownBot.projectsRequestGeneration
        projectsLoading = true
        defer {
            if generation == shownBot.projectsRequestGeneration,
               profile == activeProfile,
               self.client === client {
                projectsLoading = false
            }
        }
        do {
            let loaded = try await client.projects()
            guard generation == shownBot.projectsRequestGeneration,
                  profile == activeProfile,
                  self.client === client else { return false }
            let sorted = loaded.sorted {
                if $0.isHome != $1.isHome { return $0.isHome }
                if $0.sessionCount != $1.sessionCount { return $0.sessionCount > $1.sessionCount }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            // The same list again leaves the projects' positions as worked
            // out, unless they came from the saved list (issue 2357).
            if sorted != projects || projectsSeededFromSavedList { projects = sorted }
            shownBot.projectsRead = (profile, ObjectIdentifier(client), Date())
            supportsProjects = true
            projectsLoadFailed = false
            return true
        } catch {
            guard generation == shownBot.projectsRequestGeneration,
                  profile == activeProfile,
                  self.client === client else { return false }
            // A view's load cancelled by leaving it didn't fail.
            if error is CancellationError || Task.isCancelled { return false }
            guard isProjectsUnavailable(error) else {
                projectsLoadFailed = projects.isEmpty
                return false
            }
            projects = []
            supportsProjects = false
            projectsLoadFailed = false
            return false
        }
    }

    private func isProjectsUnavailable(_ error: Error) -> Bool {
        guard let rpcError = error as? RpcError else { return false }
        let message = rpcError.message.lowercased()
        return isMethodUnavailable(error)
            || message.contains("projects.tree") && message.contains("not found")
    }

    func isMethodUnavailable(_ error: Error) -> Bool {
        guard let rpcError = error as? RpcError else { return false }
        let message = rpcError.message.lowercased()
        return rpcError.code == -32601
            || message.contains("method not found")
            || message.contains("unknown method")
    }

    func loadProjectSessions(_ project: ProjectSummary) async -> ProjectSessionDetail? {
        guard let client, supportsProjects else { return nil }
        let profile = activeProfile
        do {
            let detail = try await client.projectSessions(project.id)
            guard profile == activeProfile, self.client === client else { return nil }
            return detail
        } catch {
            guard profile == activeProfile, self.client === client else { return nil }
            // A page's read cancelled by a newer one (the list changed) or
            // by leaving the page didn't fail.
            if error is CancellationError || Task.isCancelled { return nil }
            if isProjectsUnavailable(error) {
                projects = []
                supportsProjects = false
            } else {
                errorMessage = AppLocalization.string("Could not load \(project.title): \(UserFacingError.message(for: error))")
            }
            return nil
        }
    }

    /// What a New Project create came to, for the sheet, which stays open
    /// with the message unless the project was made with all it was given.
    enum ProjectCreateOutcome: Equatable {
        case created
        /// Made (its id), but the idea isn't in IDEA.md: the sheet keeps it
        /// on screen and Save Idea tries the write again.
        case ideaUnsaved(projectID: String, message: String)
        case failed(String?)
    }

    @discardableResult
    func createProject(name: String, folders: [String], idea: String) async -> ProjectCreateOutcome {
        guard let client, supportsProjects else { return .failed(nil) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueFolders = folders.reduce(into: [String]()) { result, folder in
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !result.contains(trimmed) { result.append(trimmed) }
        }
        guard !trimmedName.isEmpty, !uniqueFolders.isEmpty else { return .failed(nil) }

        let profile = activeProfile
        let dashboard = activeDashboardID
        // Checked again on Hermes' list as it is now: another device may
        // have made the same project since the list was read, and Hermes
        // would take a second one. A list that didn't come in checks nothing.
        guard await loadProjects(using: client, profile: profile) else {
            return .failed(AppLocalization.string("Couldn’t check Hermes’ projects. Try again."))
        }
        guard profile == activeProfile, self.client === client else { return .failed(nil) }
        if let problem = projectCreationProblem(name: trimmedName, folders: uniqueFolders) { return .failed(problem) }
        let knownIDs = Set(projects.map(\.id))
        // The idea goes to the first folder of a project that was made.
        func finish(_ created: ProjectSummary) async -> ProjectCreateOutcome {
            let trimmedIdea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
            var ideaSaved = true
            if !trimmedIdea.isEmpty {
                ideaSaved = await writeProjectIdea(trimmedIdea, in: uniqueFolders[0], profile: profile,
                                                   dashboard: dashboard)
            }
            // Hermes made it, so what's left only reports that: a reconnect
            // that replaced the client mid-create reads the list through
            // the new one, and an answered create is never a failure, which
            // a retry would then find as a clash (issue 1688).
            if dashboard == activeDashboardID, profile == activeProfile, let current = self.client {
                await loadProjects(using: current, profile: profile)
            }
            return ideaSaved
                ? .created
                : .ideaUnsaved(projectID: created.id,
                               message: AppLocalization.string("\(created.title) is made, but its idea couldn’t be saved as IDEA.md."))
        }
        do {
            guard let created = try await client.createProject(name: trimmedName, folders: uniqueFolders) else {
                throw HermesError.invalidResponse
            }
            // The same Hermes and profile take the row, across a reconnect.
            if dashboard == activeDashboardID, profile == activeProfile {
                projects = [created] + projects.filter { $0.id != created.id }
                supportsProjects = true
            }
            return await finish(created)
        } catch {
            guard dashboard == activeDashboardID, profile == activeProfile,
                  let current = self.client else { return .failed(nil) }
            if current === client, isProjectsUnavailable(error) {
                projects = []
                supportsProjects = false
                return .failed(nil)
            }
            // Hermes may have made it anyway (an answer Conduit couldn't
            // read, or a reconnect mid-create, read through the new client):
            // a new project with this name on this first folder is this one,
            // and takes the idea; anything else read again lets a retry see
            // the clash.
            if await loadProjects(using: current, profile: profile),
               dashboard == activeDashboardID, profile == activeProfile, self.client === current,
               let made = Self.projectMadeAnyway(name: trimmedName, firstFolder: uniqueFolders[0],
                                                 knownIDs: knownIDs, in: projects) {
                return await finish(made)
            }
            return .failed(AppLocalization.string("Could not create the project: \(UserFacingError.message(for: error))"))
        }
    }

    /// Only projects someone created can be renamed or deleted: Home is
    /// immutable, and auto-discovered repos have no project record.
    func isProjectEditable(_ project: ProjectSummary) -> Bool {
        guard let client, supportsProjects, isConnected,
              client !== projectEditingUnsupportedClient else { return false }
        return !project.isHome && !project.isAuto
    }

    /// Project rename and delete controls stay disabled while one runs.
    var isProjectMutationInFlight: Bool { projectMutationID != nil }

    @discardableResult
    func renameProject(_ project: ProjectSummary, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, projectMutationID == nil else { return false }
        guard let client, isProjectEditable(project) else {
            errorMessage = AppLocalization.string("Could not rename \(project.title): Conduit is not connected to Hermes.")
            return false
        }
        let profile = activeProfile
        projectMutationID = project.id
        defer { projectMutationID = nil }
        do {
            try await client.renameProject(project.id, name: trimmed)
            guard profile == activeProfile, self.client === client else { return false }
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index].title = trimmed
            }
            await loadProjects(using: client, profile: profile)
            return true
        } catch {
            guard profile == activeProfile, self.client === client else { return false }
            if isMethodUnavailable(error) {
                // Only this action is missing; keep the project list.
                projectEditingUnsupportedClient = client
                errorMessage = AppLocalization.string("This Hermes version can't rename or delete projects.")
            } else {
                errorMessage = AppLocalization.string("Could not rename \(project.title): \(UserFacingError.message(for: error))")
            }
            return false
        }
    }

    @discardableResult
    func deleteProject(_ project: ProjectSummary) async -> Bool {
        guard projectMutationID == nil else { return false }
        guard let client, isProjectEditable(project) else {
            errorMessage = AppLocalization.string("Could not delete \(project.title): Conduit is not connected to Hermes.")
            return false
        }
        let profile = activeProfile
        projectMutationID = project.id
        defer { projectMutationID = nil }
        do {
            try await client.deleteProject(project.id)
            guard profile == activeProfile, self.client === client else { return false }
            projects.removeAll { $0.id == project.id }
            await loadProjects(using: client, profile: profile)
            return true
        } catch {
            guard profile == activeProfile, self.client === client else { return false }
            if isMethodUnavailable(error) {
                // Only this action is missing; keep the project list.
                projectEditingUnsupportedClient = client
                errorMessage = AppLocalization.string("This Hermes version can't rename or delete projects.")
            } else {
                errorMessage = AppLocalization.string("Could not delete \(project.title): \(UserFacingError.message(for: error))")
            }
            return false
        }
    }

    /// Projects a conversation can be moved into: every project with a root
    /// folder except Home, which has no folder to move into. Mirrors the
    /// Hermes Desktop "Move to project" submenu.
    var projectMoveTargets: [ProjectSummary] {
        guard supportsProjects, supportsSessionWorkspaceMove else { return [] }
        return projects.filter { project in
            !project.isHome
                && project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    /// The project a conversation is known to live in, from the tree's
    /// preview rows. The session catalog carries no folder, so this is only a
    /// best-effort hint for hiding the no-op "move here" target; nil means
    /// unknown, not "in no project".
    func knownProjectID(for session: SessionSummary) -> String? {
        // A new chat Hermes doesn't list yet belongs to the project it was
        // started in, so the Chats list sorts it as it will once listed.
        if let awaiting = openNewChatAwaitingListing, awaiting.matches(session) {
            return projects.first { !$0.isHome && awaiting.isIn($0) }?.id
        }
        let index = projectPositionsIndex()
        guard !index.isEmpty else { return nil }
        // The first listed project holding any id the conversation answers to.
        var first: Int?
        for id in [session.id, session.storedSessionId].compactMap({ $0 }) + session.alternateIds {
            if let position = index[id], position < (first ?? .max) { first = position }
        }
        return first.map { projects[$0].id }
    }

    /// The catalog's copy of a chat another list carries (a project tree's
    /// preview), which a reply or a read updates between loads of that list.
    /// A row's own ids (`id`, `storedSessionId`) win over the ids it shares
    /// with others (a branch's lineage root is its parent's id), so a parent
    /// never reads a newer branch's copy; the shared ones still find a chat
    /// compressed since the list loaded.
    func catalogRow(answeringTo session: SessionSummary) -> SessionSummary? {
        let index: [String: SessionSummary]
        if let cached = catalogRowsByAnyID {
            index = cached
        } else {
            var built: [String: SessionSummary] = [:]
            for row in sessions {
                for id in Self.ownIDs(row) where built[id] == nil { built[id] = row }
            }
            for row in sessions {
                for id in Self.sharedIDs(row) where built[id] == nil { built[id] = row }
            }
            catalogRowsByAnyID = built
            index = built
        }
        return (Self.ownIDs(session) + Self.sharedIDs(session)).lazy.compactMap { index[$0] }.first
    }

    static func ownIDs(_ session: SessionSummary) -> [String] {
        [session.id, session.storedSessionId].compactMap { $0 }.filter { !$0.isEmpty }
    }

    private static func sharedIDs(_ session: SessionSummary) -> [String] {
        ([session.lineageRootId].compactMap { $0 } + session.alternateIds).filter { !$0.isEmpty }
    }

    private func projectPositionsIndex() -> [String: Int] {
        if let index = shownBot.projectPositionsBySessionID { return index }
        var index: [String: Int] = [:]
        for (position, project) in projects.enumerated() where !project.isHome {
            for preview in project.previewSessions {
                for id in [preview.id, preview.storedSessionId].compactMap({ $0 }) where index[id] == nil {
                    index[id] = position
                }
            }
        }
        shownBot.projectPositionsBySessionID = index
        return index
    }

    /// Moves a conversation into `project` by re-homing its workspace at the
    /// project's root folder (`session.workspace.move`). Hermes derives
    /// project membership from the session's folder, so the project tree is
    /// reloaded afterwards instead of patched locally.
    @discardableResult
    func moveSession(_ session: SessionSummary, to project: ProjectSummary) async -> Bool {
        if sessionMutationID != nil {
            errorMessage = AppLocalization.string("Wait for the current conversation change to finish, then try again.")
            return false
        }
        guard client != nil, isConnected else {
            errorMessage = AppLocalization.string("Reconnect to Hermes to move this conversation.")
            return false
        }
        guard let client,
              supportsProjects,
              supportsSessionWorkspaceMove,
              !project.isHome,
              let path = project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              sessionBelongsToProfile(session, profile: activeProfile) else {
            errorMessage = AppLocalization.string("This conversation can't be moved to \(project.title).")
            return false
        }

        let profile = activeProfile
        sessionMutationID = session.id
        defer { sessionMutationID = nil }
        do {
            // `session_key` is the DURABLE stored key: a live catalog row's
            // `id` is its runtime session id, which the gateway's state.db
            // lookup would not find.
            try await client.moveSessionWorkspace(session.storedSessionId ?? session.id, cwd: path)
            guard profile == activeProfile, self.client === client else { return false }
            await loadProjects(using: client, profile: profile)
            return true
        } catch {
            guard profile == activeProfile, self.client === client else { return false }
            if isMethodUnavailable(error) {
                // The project tree still works on this gateway; only the
                // move is missing, so hide the action instead of projects.
                workspaceMoveUnsupportedClient = client
                errorMessage = AppLocalization.string("Update Hermes to move conversations between projects.")
            } else {
                errorMessage = AppLocalization.string("Could not move this conversation to \(project.title): \(UserFacingError.message(for: error))")
            }
            return false
        }
    }

    /// Whether the open chat can be moved to another folder from the Folder:
    /// a chat is open on a Hermes that re-homes a chat's workspace.
    var canMoveOpenChatFolder: Bool {
        guard let open = activeSessionId, !open.isEmpty else { return false }
        return supportsSessionWorkspaceMove && sessionMutationID == nil
    }

    /// Makes `folder` the open chat's working folder, as Hermes Desktop's
    /// folder chip does: the re-home Move to Project uses
    /// (`session.workspace.move`), for any folder the Folder shows. Hermes
    /// moves a running reply with it, and the chat's project follows the
    /// folder. `.superseded` when the dashboard or profile changed while
    /// it ran, so the answer belongs to nobody on screen.
    func moveOpenChatFolder(to folder: String) async -> ChatFolderMoveResult {
        let path = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = activeSessionId, !open.isEmpty, !path.isEmpty else {
            return .failed(AppLocalization.string("Open a chat first.", table: .chat))
        }
        if sessionMutationID != nil {
            return .failed(AppLocalization.string("Wait for the current conversation change to finish, then try again."))
        }
        guard let client, isConnected, supportsSessionWorkspaceMove else {
            return .failed(AppLocalization.string("Reconnect to Hermes to move this conversation."))
        }
        let identities = knownSessionIDs(for: open).union([open])
        // The open chat's own row first; an alias match only when it has none.
        let row = sessions.first { $0.id == open || $0.storedSessionId == open }
            ?? sessions.first { session in
                identities.contains(session.id)
                    || session.storedSessionId.map(identities.contains) == true
                    || !identities.isDisjoint(with: session.alternateIds)
            }
        let sessionKey = row.map { $0.storedSessionId ?? $0.id } ?? open
        let profile = activeProfile
        sessionMutationID = open
        defer { sessionMutationID = nil }
        do {
            let moved: String
            if let move = chatResumeLifecycleOperations.moveSessionWorkspace {
                moved = try await move(client, sessionKey, path)
            } else {
                moved = try await client.moveSessionWorkspace(sessionKey, cwd: path)
            }
            guard profile == activeProfile, self.client === client else { return .superseded }
            // Hermes' session.info names the new folder too; this shows it
            // at once, and only for the chat still open.
            if activeSessionId == open {
                var updated = runtime
                updated.cwd = moved
                setRuntime(updated)
            }
            if supportsProjects {
                await loadProjects(using: client, profile: profile)
                guard profile == activeProfile, self.client === client else { return .superseded }
            }
            return .moved
        } catch {
            guard profile == activeProfile, self.client === client else { return .superseded }
            if isMethodUnavailable(error) {
                workspaceMoveUnsupportedClient = client
                return .failed(AppLocalization.string("Update Hermes to move conversations between folders.", table: .chat))
            }
            return .failed(UserFacingError.message(for: error))
        }
    }

    /// The project folder picker starts at the same live workspace the chat
    /// browser uses, else at Home's folder, so a project can be made with no
    /// chat open (issue 1661). Folder paths are selected from Hermes'
    /// filesystem listing, not entered as arbitrary strings by the phone.
    var projectFolderPickerRoot: String {
        // runtime.cwd outlives the chat that set it.
        if let session = activeSessionId, !session.isEmpty, let folder = chatWorkspaceFolder { return folder }
        return projects.first(where: \.isHome)?.primaryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Why a new project can't be made as it stands, or nil: Hermes would
    /// take a second project of the same name, or a folder that is already
    /// another project's, and list both (issue 1661). Home and the repos
    /// Hermes found on its own have no record to clash with.
    func projectCreationProblem(name: String, folders: [String]) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let made = projects.filter { !$0.isHome && !$0.isAuto }
        if !trimmedName.isEmpty,
           let clash = made.first(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
               .caseInsensitiveCompare(trimmedName) == .orderedSame }) {
            return AppLocalization.string("There’s already a project named \(clash.title).")
        }
        for folder in folders {
            let path = Self.normalizedWorkspacePath(folder.trimmingCharacters(in: .whitespacesAndNewlines))
            if let owner = made.first(where: { project in
                project.primaryPath.map { Self.normalizedWorkspacePath($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == path
            }) {
                return AppLocalization.string("\(folder) is already the folder of \(owner.title).")
            }
        }
        return nil
    }

    /// The project a create that failed made anyway: new since the create
    /// was asked, with its name and first folder. A name alone could be
    /// another device's.
    static func projectMadeAnyway(name: String, firstFolder: String, knownIDs: Set<String>,
                                  in projects: [ProjectSummary]) -> ProjectSummary? {
        let folder = normalizedWorkspacePath(firstFolder.trimmingCharacters(in: .whitespacesAndNewlines))
        return projects.first { project in
            !knownIDs.contains(project.id) && !project.isHome && !project.isAuto
                && project.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
                && project.primaryPath.map { normalizedWorkspacePath($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == folder
        }
    }

    /// Whether a folder's listing already has an IDEA.md, which a new
    /// project never writes over (issue 1661).
    static func folderHasProjectIdea(_ entries: [WorkspaceEntry]) -> Bool {
        entries.contains { !$0.isDirectory && $0.name.caseInsensitiveCompare("IDEA.md") == .orderedSame }
    }

    /// A new folder for a project, made in `folder` through the plugin's
    /// workspace routes, which refuse a name that's already there.
    func makeProjectFolder(named name: String, in folder: String, profile: String? = nil) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = try await workspaceFilesClient(profile: profile ?? activeProfile)
            .makeFolder(root: folder, in: folder, name: trimmed)
        return entry?.path
    }

    /// Folders opened in the Folder with Open Folder… (issue 1438): on this
    /// device, for each dashboard and profile, the latest first.
    static let openedWorkspaceFoldersKey = "conduit.workspaceOpenedFolders"

    static let openedWorkspaceFoldersLimit = 8

    private func openedWorkspaceFoldersBucket(profile: String) -> String {
        "\(Self.dashboardPreferenceBucket(activeDashboardID))|\(profile)"
    }

    func openedWorkspaceFolders(profile: String) -> [String] {
        let all = defaults.dictionary(forKey: Self.openedWorkspaceFoldersKey) as? [String: [String]] ?? [:]
        return all[openedWorkspaceFoldersBucket(profile: profile)] ?? []
    }

    func rememberOpenedWorkspaceFolder(_ path: String, profile: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let kept = openedWorkspaceFolders(profile: profile).filter { $0 != trimmed }
        setOpenedWorkspaceFolders(Array(([trimmed] + kept).prefix(Self.openedWorkspaceFoldersLimit)), profile: profile)
    }

    func forgetOpenedWorkspaceFolder(_ path: String, profile: String) {
        setOpenedWorkspaceFolders(openedWorkspaceFolders(profile: profile).filter { $0 != path }, profile: profile)
    }

    private func setOpenedWorkspaceFolders(_ paths: [String], profile: String) {
        var all = defaults.dictionary(forKey: Self.openedWorkspaceFoldersKey) as? [String: [String]] ?? [:]
        all[openedWorkspaceFoldersBucket(profile: profile)] = paths.isEmpty ? nil : paths
        objectWillChange.send()
        defaults.set(all, forKey: Self.openedWorkspaceFoldersKey)
    }

    func workspaceDirectoryEntries(at path: String) async throws -> [WorkspaceEntry] {
        let profile = activeProfile
        let entries = try await workspaceDirectoryEntries(at: path, profile: profile)
        guard profile == activeProfile else { return [] }
        return entries
    }

    /// The sheet's Save Idea after a create whose idea wasn't saved.
    /// `profile` and `dashboard` are the ones the project was made in,
    /// which a switch while the sheet waits doesn't change.
    func saveProjectIdea(_ idea: String, in folder: String, profile: String, dashboard: UUID?) async -> Bool {
        let trimmed = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return await writeProjectIdea(trimmed, in: folder, profile: profile, dashboard: dashboard)
    }

    /// Never over an IDEA.md the folder already has: an existing folder
    /// keeps its files (issue 1661), and an unreadable one is left alone.
    /// False when the idea wasn't saved for any other reason, or when
    /// Conduit has switched to another Hermes since the project was made:
    /// the folder is that host's, not this one's (issue 1688).
    private func writeProjectIdea(_ idea: String, in folder: String, profile: String, dashboard: UUID?) async -> Bool {
        guard dashboard == activeDashboardID,
              let entries = try? await workspaceDirectoryEntries(at: folder, profile: profile) else { return false }
        if Self.folderHasProjectIdea(entries) { return true }
        guard dashboard == activeDashboardID, let dashboardTicketBridge else { return false }
        let separator = folder.hasSuffix("/") || folder.hasSuffix("\\") ? "" : "/"
        let path = "\(folder)\(separator)IDEA.md"
        return (try? await dashboardTicketBridge.requestJSON(
            path: dashboardPath("/api/fs/write-text", profile: profile),
            method: "POST",
            body: ["path": path, "content": idea.hasSuffix("\n") ? idea : "\(idea)\n"]
        )) != nil
    }
}

/// How "Work Here in This Chat" ended.
enum ChatFolderMoveResult: Equatable {
    case moved
    /// The dashboard or profile changed while it ran.
    case superseded
    case failed(String)
}
