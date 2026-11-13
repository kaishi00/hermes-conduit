//
//  AppState+SessionControl.swift
//  Conduit
//
//  The open chat's standing goal, loop and heartbeat (SessionControl.swift),
//  read when the chat opens and kept current by Hermes'
//  `session.control.update`, with the dock's pause, resume and end; and the
//  chat's background processes for the Agents sheet (BackgroundProcess.swift).
//

import Foundation

extension AppState {
    // MARK: - Goal, loop and heartbeat

    /// Whether `sessionID` names the open chat (any of its ids).
    func sessionControlIsOpenChat(_ sessionID: String?) -> Bool {
        guard let sessionID, !sessionID.isEmpty, let open = activeSessionId else { return false }
        return sessionID == open || knownSessionIDs(for: open).contains(sessionID)
    }

    /// Hermes' word on a chat's controls. Another chat's is dropped: the
    /// dock shows the open chat's only, and reads a chat's again when it
    /// opens.
    func applySessionControl(_ snapshot: SessionControlSnapshot, for sessionID: String) {
        guard sessionControlIsOpenChat(sessionID) else { return }
        // One key per chat: word under another of its ids (runtime or
        // stored) doesn't release an action still waiting.
        let key = sessionControl.sessionID.flatMap { sessionControlIsOpenChat($0) ? $0 : nil } ?? sessionID
        sessionControl.apply(snapshot, for: key)
    }

    /// Reads the chat's controls (`session.control.read`). A Hermes without
    /// the verb, or a chat with no live session, leaves the dock as it is:
    /// empty on a chat just opened, since opening one clears it (issue
    /// 2372), so it never offers the last visit's controls.
    func refreshSessionControl(for sessionID: String) async {
        guard let client, !sessionID.isEmpty else { return }
        let revision = sessionControl.revision
        let snapshot: SessionControlSnapshot
        do {
            if let read = chatResumeLifecycleOperations.readSessionControl {
                snapshot = try await read(client, sessionID)
            } else {
                snapshot = try await client.sessionControl(sessionId: sessionID)
            }
        } catch {
            return
        }
        // Newer word (an event, an action's answer) landed meanwhile.
        guard self.client === client, sessionControl.revision == revision else { return }
        applySessionControl(snapshot, for: sessionID)
    }

    /// Runs one of the dock's actions on the chat its controls belong to.
    /// Hermes' answer replaces what the dock shows; a refusal says why
    /// under it.
    func runSessionControl(_ action: SessionControlAction) async {
        guard let client, let sessionID = sessionControl.sessionID,
              sessionControlIsOpenChat(sessionID), sessionControl.working == nil else { return }
        // Hermes counts criteria by place: one picked from a list that
        // changed since would remove another (issue 2372).
        if case .subgoalRemove(let index, let criterion?) = action {
            let subgoals = sessionControl.snapshot.goal?.subgoals ?? []
            guard subgoals.indices.contains(index - 1), subgoals[index - 1] == criterion else {
                sessionControl.notice = AppLocalization.string("The goal's criteria changed. Pick the one to remove again.", table: .chat)
                return
            }
        }
        let token = sessionControl.begin(action)
        // Ended on every path, the connection changing included, and only
        // after the dock reads the new state: an action on the old list
        // could name the wrong criterion.
        defer { sessionControl.end(token) }
        do {
            let answer: (snapshot: SessionControlSnapshot?, note: String?)
            if let run = chatResumeLifecycleOperations.runSessionControl {
                answer = try await run(client, action, sessionID)
            } else {
                answer = try await client.runSessionControl(action, sessionId: sessionID)
            }
            // Dropped once the store went to another chat, like the note.
            guard self.client === client, sessionControl.isCurrent(token),
                  sessionControl.sessionID == sessionID else { return }
            if let snapshot = answer.snapshot {
                sessionControl.apply(snapshot, for: sessionID)
            } else {
                await refreshSessionControl(for: sessionID)
            }
            // What Hermes said about it ("Removed criterion 2"), under the dock.
            if let note = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty,
               sessionControl.isCurrent(token), sessionControlIsOpenChat(sessionID) {
                sessionControl.notice = note
            }
        } catch {
            guard self.client === client, sessionControl.isCurrent(token),
                  sessionControl.sessionID == sessionID else { return }
            sessionControl.notice = UserFacingError.message(for: error)
        }
    }

    // MARK: - Background processes

    /// The open chat's live session id, for the Agents sheet's processes.
    var backgroundProcessSessionID: String? {
        guard let open = activeSessionId, !open.isEmpty else { return nil }
        return open
    }

    /// The background processes Hermes runs for the open chat
    /// (`process.list`). Nil when Hermes can't say (an older Hermes, or a
    /// chat with no live session); the sheet then leaves them out.
    func loadBackgroundProcesses() async -> [BackgroundProcess]? {
        guard let client, let sessionID = backgroundProcessSessionID else { return nil }
        let processes: [BackgroundProcess]
        do {
            if let list = chatResumeLifecycleOperations.listBackgroundProcesses {
                processes = try await list(client, sessionID)
            } else {
                processes = try await client.backgroundProcesses(sessionId: sessionID)
            }
        } catch {
            return nil
        }
        guard self.client === client, activeSessionId == sessionID else { return nil }
        return processes
    }

    /// Ends one background process (`process.kill`). Nil when it went, else
    /// why it couldn't.
    func killBackgroundProcess(_ process: BackgroundProcess) async -> String? {
        guard let client, let sessionID = backgroundProcessSessionID else {
            return AppLocalization.string("Reconnect to Hermes to stop this process.", table: .chat)
        }
        do {
            if let kill = chatResumeLifecycleOperations.killBackgroundProcess {
                try await kill(client, sessionID, process.id)
            } else {
                try await client.killBackgroundProcess(sessionId: sessionID, processId: process.id)
            }
            return nil
        } catch {
            return UserFacingError.message(for: error)
        }
    }
}
