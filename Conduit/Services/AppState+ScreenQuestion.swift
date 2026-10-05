//
//  AppState+ScreenQuestion.swift
//  Conduit
//
//  Ask Hermes About Screen: the screenshot handed over by the Shortcuts
//  action waits on a chat as its *pending screenshot*, and the next new
//  turn sent there carries it (`submitComposer` takes it), whether the
//  question is typed or spoken. Design:
//  /mnt/project-files/designs/ask-hermes-about-screen.md
//

import Foundation

/// One screenshot waiting on a chat for the next question sent there.
struct PendingScreenshot: Equatable {
    let sessionID: String
    let attachment: Attachment
}

/// A screenshot Hermes couldn't take yet, with the profile its shortcut
/// named.
struct ParkedScreenQuestion: Equatable {
    let request: ScreenQuestionRequest
    let profile: String?
}

/// Pure rules for where a screenshot goes.
enum ScreenQuestionPolicy {
    /// Eric's "Recent chat" rule: a screenshot joins the chat on screen
    /// when Conduit was in use this recently, so switching between Conduit
    /// and the app with the problem keeps one conversation. Otherwise it
    /// starts a new chat and never lands in one from hours ago.
    static let recentChatWindow: TimeInterval = 5 * 60

    /// Screenshots kept in memory at once; the oldest is dropped.
    static let maximumPendingScreenshots = 4

    static func continuesOpenChat(lastLeftForegroundAt: Date?, enqueuedAt: Date, hasOpenChat: Bool) -> Bool {
        guard hasOpenChat, let lastLeftForegroundAt else { return false }
        return enqueuedAt.timeIntervalSince(lastLeftForegroundAt) <= recentChatWindow
    }
}

extension AppState {
    // MARK: - Pending screenshot

    func pendingScreenshot(forSession sessionID: String?) -> Attachment? {
        pendingScreenshotIndex(forSession: sessionID).map { pendingScreenshots[$0].attachment }
    }

    /// A newer screenshot for the same chat replaces the older one.
    func setPendingScreenshot(_ attachment: Attachment, forSession sessionID: String) {
        if let index = pendingScreenshotIndex(forSession: sessionID) {
            let replaced = pendingScreenshots.remove(at: index)
            if replaced.attachment.uri != attachment.uri {
                Self.deleteStagedScreenshot(replaced.attachment)
            }
        }
        pendingScreenshots.append(PendingScreenshot(sessionID: sessionID, attachment: attachment))
        trimPendingScreenshots()
    }

    /// The composer's remove button: the screenshot never leaves the phone.
    func discardPendingScreenshot(forSession sessionID: String?) {
        guard let index = pendingScreenshotIndex(forSession: sessionID) else { return }
        Self.deleteStagedScreenshot(pendingScreenshots.remove(at: index).attachment)
    }

    /// Hands the chat's screenshot to the send that carries it. The staged
    /// file stays: the sent bubble previews from it.
    func takePendingScreenshot(forSession sessionID: String?) -> Attachment? {
        guard let index = pendingScreenshotIndex(forSession: sessionID) else { return nil }
        return pendingScreenshots.remove(at: index).attachment
    }

    /// A send that failed puts its screenshot back, unless a newer one
    /// already landed on the chat meanwhile.
    func restorePendingScreenshot(_ attachment: Attachment, forSession sessionID: String) {
        guard pendingScreenshotIndex(forSession: sessionID) == nil else {
            // It will never be sent now.
            if pendingScreenshot(forSession: sessionID)?.uri != attachment.uri {
                Self.deleteStagedScreenshot(attachment)
            }
            return
        }
        pendingScreenshots.append(PendingScreenshot(sessionID: sessionID, attachment: attachment))
        trimPendingScreenshots()
    }

    private func trimPendingScreenshots() {
        while pendingScreenshots.count > ScreenQuestionPolicy.maximumPendingScreenshots {
            Self.deleteStagedScreenshot(pendingScreenshots.removeFirst().attachment)
        }
    }

    private func pendingScreenshotIndex(forSession sessionID: String?) -> Int? {
        guard let sessionID, !sessionID.isEmpty, !pendingScreenshots.isEmpty else { return nil }
        if let exact = pendingScreenshots.lastIndex(where: { $0.sessionID == sessionID }) {
            return exact
        }
        // Reopened, the chat runs under a new runtime id; its own ids
        // still name it.
        let ids = screenshotChatIDs(for: sessionID)
        return pendingScreenshots.lastIndex { !ids.isDisjoint(with: screenshotChatIDs(for: $0.sessionID)) }
    }

    static func deleteStagedScreenshot(_ attachment: Attachment) {
        guard let url = URL(string: attachment.uri), url.isFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Opening the chat

    /// The router's handler for an Ask Hermes About Screen launch. Returns
    /// false only while Hermes isn't connected: the router then fails the
    /// request and the screenshot is parked.
    func openScreenQuestion(_ intent: PendingVoiceIntent) async -> Bool {
        guard let request = intent.screenQuestion else { return true }
        return await openScreenQuestion(request, profile: intent.profile, resumingParked: false)
    }

    /// Keeps a screenshot Hermes couldn't take yet. The newest one wins.
    func parkScreenQuestion(_ request: ScreenQuestionRequest, profile: String?) {
        if let parked = parkedScreenQuestion, parked.request.attachment.uri != request.attachment.uri {
            Self.deleteStagedScreenshot(parked.request.attachment)
        }
        parkedScreenQuestion = ParkedScreenQuestion(request: request, profile: profile)
        parkedScreenQuestionRevision &+= 1
    }

    /// Attaches a screenshot kept through an outage once Hermes connects.
    /// The user is in Conduit by then, so it joins the chat on screen (or a
    /// new chat on the profile the shortcut named), with the keyboard:
    /// never the microphone, and a question waits in the composer rather
    /// than being sent long after it was asked.
    func resumeParkedScreenQuestion() async {
        guard isConnected, let parked = parkedScreenQuestion else { return }
        parkedScreenQuestion = nil
        if !(await openScreenQuestion(parked.request, profile: parked.profile, resumingParked: true)) {
            // The connection dropped again before a chat opened. A newer
            // screenshot parked meanwhile wins.
            if parkedScreenQuestion == nil {
                parkScreenQuestion(parked.request, profile: parked.profile)
            } else if parkedScreenQuestion?.request.attachment.uri != parked.request.attachment.uri {
                Self.deleteStagedScreenshot(parked.request.attachment)
            }
        }
    }

    private func openScreenQuestion(
        _ request: ScreenQuestionRequest,
        profile: String?,
        resumingParked: Bool
    ) async -> Bool {
        guard isConnected else { return false }
        // A newer press replaces a screenshot kept from an outage.
        if !resumingParked, let parked = parkedScreenQuestion {
            parkedScreenQuestion = nil
            if parked.request.attachment.uri != request.attachment.uri {
                Self.deleteStagedScreenshot(parked.request.attachment)
            }
        }
        var switchedProfile = false
        if let profile = PendingVoiceLaunchPolicy.normalizedProfile(profile), profile != activeProfile {
            await switchProfile(to: profile)
            guard profile == activeProfile else {
                Self.deleteStagedScreenshot(request.attachment)
                errorMessage = AppLocalization.string("Conduit could not open the requested profile, so the screenshot was not attached.")
                return true
            }
            guard isConnected else { return false }
            switchedProfile = true
        }

        let hasOpenChat = activeSessionId != nil && activeRoomSurface == nil && offlineChatPresentation == nil
        let continuesOpenChat: Bool
        if switchedProfile {
            continuesOpenChat = false
        } else if resumingParked || isVoiceInUse {
            // The user is in Conduit now, or talking in that chat.
            continuesOpenChat = hasOpenChat
        } else {
            continuesOpenChat = ScreenQuestionPolicy.continuesOpenChat(
                lastLeftForegroundAt: lastLeftForegroundAt,
                enqueuedAt: request.enqueuedAt,
                hasOpenChat: hasOpenChat
            )
        }
        // An empty new chat is as good as a fresh one.
        let openChatIsEmpty = hasOpenChat && messages.isEmpty && turnState == .idle
        let sessionID: String
        if let open = activeSessionId, continuesOpenChat || openChatIsEmpty {
            sessionID = open
        } else {
            let previous = activeSessionId
            await createNewSession()
            guard let created = activeSessionId, created != previous else {
                guard isConnected else { return false }
                Self.deleteStagedScreenshot(request.attachment)
                errorMessage = AppLocalization.string("Hermes could not start a chat for the screenshot.")
                return true
            }
            sessionID = created
        }

        setPendingScreenshot(request.attachment, forSession: sessionID)
        showSidebar = false
        if let question = request.question, !question.isEmpty {
            if resumingParked || turnState != .idle || Self.parseSlashCommand(question) != nil {
                // Not sent into a running reply as a steer, nor long after
                // it was asked, nor run as a command: it waits in the
                // composer.
                prefillComposer(question)
            } else {
                // A reply found running (a stale idle state) gets no steer
                // either. A send that fails leaves the question in the
                // composer, beside the screenshot.
                let sent = await submitComposer(text: question, onBusy: {})
                if !sent {
                    prefillComposer(question)
                    // Held until the composer unlocks.
                    composerFocusRequest = UUID()
                }
            }
        } else {
            composerFocusRequest = UUID()
        }
        return true
    }

    /// ComposerBar focused the field.
    func consumeComposerFocusRequest(_ id: UUID) {
        guard composerFocusRequest == id else { return }
        composerFocusRequest = nil
    }
}
