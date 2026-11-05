//
//  AppState+Workspace.swift
//  Conduit
//
//  The Folder tab in Artifacts (#1389): which folders it can open, the
//  client for the plugin's workspace routes, a file path tapped in a reply,
//  and the nudge to refresh when Hermes changes files.
//

import Foundation

extension AppState {
    /// Whether the host's notifier plugin serves the Folder tab's search,
    /// recent files and file actions. Without it the tab still browses and
    /// opens files, through Hermes' own routes.
    var supportsWorkspaceFiles: Bool {
        notifierPlugin.reports(WorkspaceFilesClient.capability)
    }

    /// The profile whose files the open chat works in: a Bot Chat's bot,
    /// else the profile in use.
    var workspaceProfile: String {
        guard let sessionID = activeSessionId, !sessionID.isEmpty else { return activeProfile }
        let ids = activeChatArtifactSessionIDs
        return botStoreProfile(forSessionIDs: ids.isEmpty ? [sessionID] : ids) ?? activeProfile
    }

    func workspaceFilesClient(profile: String) -> WorkspaceFilesClient {
        WorkspaceFilesClient(profile: profile, request: { [weak self] path, method, body in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            // A search walks the whole folder; an upload carries the file.
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: 45_000)
        })
    }

    /// The open chat's working folder, when Hermes has reported one.
    var chatWorkspaceFolder: String? {
        let cwd = runtime.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return cwd.isEmpty ? nil : cwd
    }

    /// The folders the Folder tab can open: the chat's own (with `chat`),
    /// then each project's, once each.
    func workspaceRoots(includingChat chat: Bool) -> [WorkspaceRoot] {
        var roots: [WorkspaceRoot] = []
        var seen = Set<String>()
        if chat, let folder = chatWorkspaceFolder {
            roots.append(WorkspaceRoot(path: folder, title: AppLocalization.string("This chat's folder"), kind: .chat))
            seen.insert(Self.normalizedWorkspacePath(folder))
        }
        for project in projects {
            guard let path = project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
                  seen.insert(Self.normalizedWorkspacePath(path)).inserted else { continue }
            roots.append(WorkspaceRoot(path: path, title: project.title, kind: .project))
        }
        return roots
    }

    static func normalizedWorkspacePath(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") || trimmed.hasSuffix("\\") { trimmed.removeLast() }
        return trimmed
    }

    /// The folder holding `path`, or nil at the top of the disk: what the
    /// project folder picker's Enclosing Folder opens (issue 1661). Hermes
    /// gives a Windows host's paths with backslashes.
    static func parentWorkspacePath(_ path: String) -> String? {
        let normalized = normalizedWorkspacePath(path.trimmingCharacters(in: .whitespacesAndNewlines))
        let posix = normalized.hasPrefix("/") || normalized.hasPrefix("~")
        guard !normalized.isEmpty, normalized != "/", normalized != "~",
              normalized.range(of: #"^[A-Za-z]:[\\/]?$"#, options: .regularExpression) == nil,
              // A POSIX path's name may hold a backslash: only a slash
              // separates there.
              let cut = normalized.lastIndex(where: { $0 == "/" || (!posix && $0 == "\\") }) else { return nil }
        let parent = String(normalized[..<cut])
        if parent.isEmpty { return "/" }
        if parent.range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil {
            return parent + String(normalized[cut])
        }
        return parent
    }

    /// A path a reply named, made absolute: a relative one is in the open
    /// chat's working folder, as Hermes wrote it there.
    func absoluteWorkspacePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isAbsoluteWorkspacePath(trimmed) { return trimmed }
        guard let folder = chatWorkspaceFolder else { return trimmed }
        var relative = trimmed
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        let separator = folder.hasSuffix("/") || folder.hasSuffix("\\") ? "" : "/"
        return folder + separator + relative
    }

    /// A file path tapped in a reply: the open chat shows it in the Folder
    /// tab (beside the chat on a wide window, in its Artifacts sheet on a
    /// phone).
    ///
    /// A bare name or a relative path (`AppState.swift`) is often not in the
    /// chat's folder: the folder is unset, or the agent worked elsewhere. The
    /// plugin finds where the chat's own tool calls had it (issue 1809), and
    /// says so plainly when the host has no such file.
    func revealWorkspaceFile(_ path: String, line: Int? = nil) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A later tap wins over a lookup still running for an earlier one.
        workspaceRevealGeneration &+= 1
        let generation = workspaceRevealGeneration
        // Each id the open chat goes by; none in a group room, whose tap
        // opens the projects' folders as before.
        let ids = activeChatArtifactSessionIDs
        guard !Self.isAbsoluteWorkspacePath(trimmed), !ids.isEmpty,
              notifierPlugin.reports(WorkspaceFilesClient.resolveCapability),
              let owner = currentDashboardRuntimeOwner() else {
            clearWorkspaceLookupNotice()
            workspaceReveal = WorkspaceReveal(path: absoluteWorkspacePath(trimmed), line: line)
            return
        }
        let client = workspaceFilesClient(profile: workspaceProfile)
        let session = activeSessionId
        Task { @MainActor [weak self] in
            let answer: Result<String?, Error>
            do {
                answer = .success(try await client.resolve(path: trimmed, sessionIDs: ids))
            } catch {
                answer = .failure(error)
            }
            guard let self, self.workspaceRevealGeneration == generation, self.ownsDashboardRuntime(owner),
                  self.activeSessionId == session else { return }
            self.showWorkspaceLookup(answer, for: trimmed, line: line)
        }
    }

    /// What the plugin's lookup of a tapped name says: the file it found,
    /// that the host has none (said above the composer, which shows while
    /// the chat is open and connected), or, when the lookup itself failed,
    /// the chat's folder as before.
    func showWorkspaceLookup(_ answer: Result<String?, Error>, for path: String, line: Int?) {
        // An earlier tap's "isn't on the server" goes once a later one
        // answers; any other notice stays.
        clearWorkspaceLookupNotice()
        switch answer {
        case .success(let found?):
            workspaceReveal = WorkspaceReveal(path: found, line: line)
        case .success(nil):
            let name = (path as NSString).lastPathComponent
            let notice = AppLocalization.string("\(name) isn’t on the server. It may have been deleted, or it’s on another computer.")
            // A notice already up (a message that came back) waits under
            // this one and comes back when it goes.
            if let shown = composerNotice {
                workspaceNoticeUnder = (shown, composerNoticeSystemImage)
            }
            composerNotice = notice
            composerNoticeSystemImage = "questionmark.folder"
            workspaceLookupNotice = notice
        case .failure:
            workspaceReveal = WorkspaceReveal(path: absoluteWorkspacePath(path), line: line)
        }
    }

    /// Takes away the last file lookup's notice, if it's still the one shown.
    func clearWorkspaceLookupNotice() {
        if let said = workspaceLookupNotice, composerNotice == said {
            composerNotice = workspaceNoticeUnder?.text
            if let under = workspaceNoticeUnder { composerNoticeSystemImage = under.systemImage }
        }
        workspaceLookupNotice = nil
        workspaceNoticeUnder = nil
    }

    /// A path from the top of a disk or a home folder, as opposed to one
    /// inside a folder.
    static func isAbsoluteWorkspacePath(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    /// Hermes finished a tool that may have changed files: an open Folder
    /// tab reads its folders again.
    func noteWorkspaceToolCompleted(_ name: String) {
        guard Self.workspaceChangingTools.contains(name.lowercased()) else { return }
        workspaceChanges &+= 1
    }

    /// Tools that write, move or delete files, or run commands that can.
    static let workspaceChangingTools: Set<String> = [
        "write_file", "patch", "edit_file", "apply_patch", "str_replace_editor", "create_file", "delete_file",
        "move_file", "terminal", "execute_code", "shell", "bash", "run_command", "image_generate",
        "text_to_speech", "browser_screenshot",
    ]

    /// A text file's first part, for the Folder tab's viewer.
    func readWorkspaceText(_ path: String, profile: String) async throws -> WorkspaceFilePreview {
        guard let bridge = dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        guard let encoded = DashboardPath.encodedQueryComponent(path) else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The workspace path could not be encoded."))
        }
        let result = try await bridge.requestJSON(
            path: DashboardPath.withProfile("/api/fs/read-text?path=\(encoded)", profile: profile)
        )
        return WorkspaceFilePreview(
            binary: result["binary"] as? Bool ?? false,
            byteSize: result["byteSize"] as? Int ?? 0,
            language: result["language"] as? String ?? "text",
            mimeType: result["mimeType"] as? String ?? "text/plain",
            text: result["text"] as? String ?? "",
            truncated: result["truncated"] as? Bool ?? false
        )
    }

    /// A folder's entries through Hermes' own listing, for a plugin without
    /// the workspace routes: names only, no sizes or dates.
    func workspaceDirectoryEntries(at path: String, profile: String) async throws -> [WorkspaceEntry] {
        guard let bridge = dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        guard let encodedPath = DashboardPath.encodedQueryComponent(path) else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("The workspace path could not be encoded."))
        }
        let result = try await bridge.requestJSON(
            path: DashboardPath.withProfile("/api/fs/list?path=\(encodedPath)", profile: profile)
        )
        if let error = result["error"] as? String, !error.isEmpty {
            throw DashboardTicketBridgeError.requestFailed(error)
        }
        return ((result["entries"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let name = item["name"] as? String,
                  let entryPath = item["path"] as? String,
                  !name.isEmpty,
                  !entryPath.isEmpty else { return nil }
            return WorkspaceEntry(name: name, path: entryPath, isDirectory: item["isDirectory"] as? Bool ?? false)
        }.sorted {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
