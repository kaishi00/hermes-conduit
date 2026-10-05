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

/// Asks the composer of one chat to take focus. Another chat's composer
/// drops it.
struct ComposerFocusRequest: Equatable {
    let id = UUID()
    let sessionID: String
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

    /// How long Conduit must already be on screen before the screenshot
    /// for it to count as taken in Conduit, not by the launch that
    /// brought Conduit up.
    static let onScreenGrace: TimeInterval = 5

    /// A press inside Conduit may never take the scene off screen, so no
    /// departure is stamped: being on screen when the screenshot was
    /// taken counts as using Conduit now.
    static func wasOnScreen(activeSince: Date?, enqueuedAt: Date) -> Bool {
        guard let activeSince else { return false }
        return enqueuedAt.timeIntervalSince(activeSince) >= onScreenGrace
    }
}

/// "Opens with" in Voice settings: how a screenshot chat takes the
/// question when the action doesn't say. Per device.
enum ScreenQuestionPreferences {
    static let startWithKey = "conduit.screenQuestion.startWith"

    static func startWith(defaults: UserDefaults = .standard) -> ScreenQuestionStart {
        defaults.string(forKey: startWithKey).flatMap(ScreenQuestionStart.init(rawValue:)) ?? .voice
    }
}

/// Which voice takes a screen question. It starts in the profile's own
/// voice mode, and reliable Live delegation is a device-test gate (Eric,
/// 2026-10-05): an engine that doesn't reliably hand the first screenshot
/// question to Hermes comes off this list, and its profiles take screen
/// questions in classic voice.
enum ScreenQuestionVoiceRouting {
    static let liveEngines: Set<VoiceCallEngine> = [.gptLive, .geminiLive, .grokLive]

    /// The live engine for a screen question: the profile's own when it is
    /// cleared, otherwise nil (classic voice).
    static func liveEngine(
        for configured: VoiceCallEngine?,
        allowed: Set<VoiceCallEngine> = liveEngines
    ) -> VoiceCallEngine? {
        guard let configured, allowed.contains(configured) else { return nil }
        return configured
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
        takePendingScreenshotEntry(forSession: sessionID)?.attachment
    }

    /// The same, with the id it was kept under, so a failed send puts it
    /// back under that id.
    func takePendingScreenshotEntry(forSession sessionID: String?) -> PendingScreenshot? {
        guard let index = pendingScreenshotIndex(forSession: sessionID) else { return nil }
        return pendingScreenshots.remove(at: index)
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

    /// The screenshot waiting on a live call's chat.
    func pendingScreenshot(forThread thread: VoiceThreadTarget) -> Attachment? {
        for id in [thread.runtimeSessionID, thread.storedSessionID].compactMap({ $0 }) {
            if let screenshot = pendingScreenshot(forSession: id) { return screenshot }
        }
        return nil
    }

    /// The screenshot the voice on screen will ask about: a live call's
    /// chat's, or the classic conversation's.
    var voiceScreenshot: Attachment? {
        if isLiveVoiceCallActive {
            return voiceBackgroundJobSupervisor.liveThread.flatMap { pendingScreenshot(forThread: $0) }
        }
        return pendingScreenshot(forSession: activeSessionId)
    }

    /// The voice sheet's remove button.
    func discardVoiceScreenshot() {
        guard isLiveVoiceCallActive else {
            discardPendingScreenshot(forSession: activeSessionId)
            return
        }
        guard let thread = voiceBackgroundJobSupervisor.liveThread else { return }
        for id in [thread.runtimeSessionID, thread.storedSessionID].compactMap({ $0 }) {
            discardPendingScreenshot(forSession: id)
        }
    }

    // MARK: - Opening the chat

    /// The router's handler for an Ask Hermes About Screen launch. Returns
    /// false only while Hermes isn't connected: the router then fails the
    /// request and the screenshot is parked.
    func openScreenQuestion(_ intent: PendingVoiceIntent) async -> Bool {
        guard let request = intent.screenQuestion else { return true }
        noteScreenQuestion(request)
        return await openScreenQuestion(request, profile: intent.profile, resumingParked: false)
    }

    /// A launch that found Hermes gone was superseded meanwhile. The newest
    /// screenshot wins: this one is dropped when a newer one exists, and
    /// kept when something else (a Siri or wake phrase launch) took over.
    func settleSupersededScreenQuestion(
        _ request: ScreenQuestionRequest,
        profile: String?,
        newerScreenQuestionPending: Bool
    ) {
        if newerScreenQuestionPending || isOutdated(request) {
            Self.deleteStagedScreenshot(request.attachment)
        } else {
            parkScreenQuestion(request, profile: profile)
        }
    }

    private func noteScreenQuestion(_ request: ScreenQuestionRequest) {
        if let newest = newestScreenQuestionAt, newest >= request.enqueuedAt { return }
        newestScreenQuestionAt = request.enqueuedAt
    }

    /// A newer screenshot was routed or parked since this one was taken.
    private func isOutdated(_ request: ScreenQuestionRequest) -> Bool {
        newestScreenQuestionAt.map { $0 > request.enqueuedAt } ?? false
    }

    /// Sign-out: screenshots waiting for a question belong to the
    /// signed-out user, like drafts.
    func discardScreenQuestions() {
        for pending in pendingScreenshots {
            Self.deleteStagedScreenshot(pending.attachment)
        }
        pendingScreenshots = []
        if let parked = parkedScreenQuestion {
            Self.deleteStagedScreenshot(parked.request.attachment)
        }
        parkedScreenQuestion = nil
        newestScreenQuestionAt = nil
    }

    /// Keeps a screenshot Hermes couldn't take yet. The newest one wins.
    func parkScreenQuestion(_ request: ScreenQuestionRequest, profile: String?) {
        guard !isOutdated(request) else {
            Self.deleteStagedScreenshot(request.attachment)
            return
        }
        noteScreenQuestion(request)
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
        guard isConnected, !isConnecting, !isProfileSwitching, let parked = parkedScreenQuestion else { return }
        parkedScreenQuestion = nil
        if !(await openScreenQuestion(parked.request, profile: parked.profile, resumingParked: true)) {
            // The connection dropped again before a chat opened.
            holdScreenQuestion(parked.request, profile: parked.profile)
        }
    }

    /// Keeps a screenshot no chat could take yet, without a revision bump:
    /// it is tried again when the connection changes, never in a loop. A
    /// newer screenshot parked meanwhile wins.
    private func holdScreenQuestion(_ request: ScreenQuestionRequest, profile: String?) {
        // A newer screenshot placed while this one waited wins.
        guard !isOutdated(request) else {
            Self.deleteStagedScreenshot(request.attachment)
            return
        }
        if let parked = parkedScreenQuestion {
            if parked.request.attachment.uri != request.attachment.uri {
                Self.deleteStagedScreenshot(request.attachment)
            }
            return
        }
        parkedScreenQuestion = ParkedScreenQuestion(request: request, profile: profile)
    }

    private func openScreenQuestion(
        _ request: ScreenQuestionRequest,
        profile: String?,
        resumingParked: Bool
    ) async -> Bool {
        guard isConnected else { return false }
        guard !isOutdated(request) else {
            Self.deleteStagedScreenshot(request.attachment)
            return true
        }
        // A newer press replaces a screenshot kept from an outage.
        if !resumingParked, let parked = parkedScreenQuestion {
            parkedScreenQuestion = nil
            if parked.request.attachment.uri != request.attachment.uri {
                Self.deleteStagedScreenshot(parked.request.attachment)
            }
        }
        let requestedProfile = PendingVoiceLaunchPolicy.normalizedProfile(profile)
        var switchedProfile = false
        if let requestedProfile, requestedProfile != activeProfile {
            await switchProfile(to: requestedProfile)
            guard isConnected else { return false }
            if requestedProfile == activeProfile {
                switchedProfile = true
            } else {
                // Kept, not dropped: it waits in the profile on screen.
                errorMessage = AppLocalization.string("Conduit could not open the profile the shortcut asked for, so the screenshot is in this one.")
            }
        }

        // A live call attached to a chat takes the screenshot on that chat,
        // so the call's next question carries it.
        if !switchedProfile, isLiveVoiceCallActive,
           let thread = voiceBackgroundJobSupervisor.liveThread, thread.profile == nil, !isOpenChat(thread) {
            _ = await openSession(thread.storedSessionID ?? thread.runtimeSessionID)
            guard isConnected else { return false }
        }

        let hasOpenChat = activeSessionId != nil && activeRoomSurface == nil && offlineChatPresentation == nil
        let continuesOpenChat: Bool
        if switchedProfile {
            continuesOpenChat = false
        } else if resumingParked || isVoiceInUse || ScreenQuestionPolicy.wasOnScreen(
            activeSince: isSceneActive ? sceneActiveSince : nil,
            enqueuedAt: request.enqueuedAt
        ) {
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
                // Kept, not dropped: tried again once the connection settles.
                // A profile that couldn't open is tried again too.
                holdScreenQuestion(request, profile: requestedProfile)
                errorMessage = AppLocalization.string("Hermes could not start a chat for the screenshot. It's kept and will be attached once Hermes is ready.")
                return true
            }
            sessionID = created
        }

        // A newer screenshot placed while this launch waited wins.
        guard !isOutdated(request) else {
            Self.deleteStagedScreenshot(request.attachment)
            return true
        }
        setPendingScreenshot(request.attachment, forSession: sessionID)
        showSidebar = false
        if let question = request.question, !question.isEmpty {
            if resumingParked || turnState != .idle || Self.parseSlashCommand(question) != nil {
                // Not sent into a running reply as a steer, nor long after
                // it was asked, nor run as a command: it waits in the
                // composer.
                prefillComposer(question)
                // Held until the composer unlocks.
                requestComposerFocus(on: sessionID)
            } else {
                // A reply found running (a stale idle state) gets no steer
                // either. A send that fails leaves the question in the
                // composer, beside the screenshot.
                let sent = await submitComposer(text: question, onBusy: {})
                if !sent {
                    prefillComposer(question)
                    // Held until the composer unlocks.
                    requestComposerFocus(on: sessionID)
                }
            }
        } else if isVoiceInUse {
            // A conversation already running takes it: its next question
            // carries it.
            noteScreenshotToLiveCall(on: sessionID)
        } else if resumingParked {
            requestComposerFocus(on: sessionID)
        } else {
            await startScreenQuestionInput(request.startWith ?? screenQuestionStartPreference, on: sessionID)
        }
        return true
    }

    /// No question came with the screenshot: start the profile's voice, or
    /// the keyboard ("Opens with" in Voice settings). A turn still running
    /// in the chat gets the keyboard: the screenshot waits for a new turn.
    private func startScreenQuestionInput(_ start: ScreenQuestionStart, on sessionID: String) async {
        guard start == .voice, turnState == .idle else {
            requestComposerFocus(on: sessionID)
            return
        }
        if ScreenQuestionVoiceRouting.liveEngine(for: configuredLiveVoiceEngine(profile: activeProfile)) == nil {
            // Classic voice: a profile without it set up gets the keyboard.
            await refreshVoiceCapabilities()
            guard canStartVoiceConversation else {
                requestComposerFocus(on: sessionID)
                return
            }
        }
        let intent = PendingVoiceIntent(profile: nil, startsFreshConversation: false, source: .screenQuestion)
        if !(await openVoiceConversation(intent)) {
            requestComposerFocus(on: sessionID)
        }
    }

    /// A live call attached to the chat hears, quietly, that a screenshot
    /// arrived: it can't see it, and the chat's next turn carries it.
    private func noteScreenshotToLiveCall(on sessionID: String) {
        guard isLiveVoiceCallActive, let thread = voiceBackgroundJobSupervisor.liveThread,
              thread.owns(sessionID: sessionID) || isOpenChat(thread) else { return }
        voiceBackgroundJobSupervisor.noteScreenshotShared()
    }

    func requestComposerFocus(on sessionID: String) {
        composerFocusRequest = ComposerFocusRequest(sessionID: sessionID)
    }

    /// A composer took the request: it focused, or it belongs to another
    /// chat and dropped it.
    func consumeComposerFocusRequest(_ id: UUID) {
        guard composerFocusRequest?.id == id else { return }
        composerFocusRequest = nil
    }
}
