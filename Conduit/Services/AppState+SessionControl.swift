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
        sessionControl.apply(snapshot, for: sessionID)
    }

    /// Reads the chat's controls (`session.control.read`). A Hermes without
    /// the verb, or a chat with no live session, leaves the dock as it is.
    func refreshSessionControl(for sessionID: String) async {
        guard let client, !sessionID.isEmpty else { return }
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
        guard self.client === client else { return }
        applySessionControl(snapshot, for: sessionID)
    }

    /// Runs one of the dock's actions on the chat its controls belong to.
    /// Hermes' answer replaces what the dock shows; a refusal says why
    /// under it.
    func runSessionControl(_ action: SessionControlAction) async {
        guard let client, let sessionID = sessionControl.sessionID,
              sessionControlIsOpenChat(sessionID), sessionControl.working == nil else { return }
        sessionControl.begin(action)
        do {
            let answer: (snapshot: SessionControlSnapshot?, note: String?)
            if let run = chatResumeLifecycleOperations.runSessionControl {
                answer = try await run(client, action, sessionID)
            } else {
                answer = try await client.runSessionControl(action, sessionId: sessionID)
            }
            guard self.client === client, sessionControl.sessionID == sessionID else { return }
            sessionControl.end()
            if let snapshot = answer.snapshot {
                sessionControl.apply(snapshot, for: sessionID)
            } else {
                await refreshSessionControl(for: sessionID)
            }
            // What Hermes said about it ("Removed criterion 2"), under the dock.
            if let note = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty,
               sessionControl.sessionID == sessionID {
                sessionControl.notice = note
            }
        } catch {
            guard self.client === client, sessionControl.sessionID == sessionID else { return }
            sessionControl.end()
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
