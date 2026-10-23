//
//  V2VoiceButton.swift
//  Conduit
//
//  V2's voice button: a gold circle beside the tab bar on every tab and
//  project page. A tap starts voice where the user is (a new call, or a
//  new chat in the open project's folder); touch and hold on a tab lists
//  the three most recent conversations to talk in instead. While a call is
//  minimised the button brings it back, its bars moving. Beside a chat's
//  composer a tap does what Chat voice button says: a call or dictation,
//  where touch and hold offers the other, or a voice message, recorded
//  while the button is held.
//

import SwiftUI

/// Where the voice button sits, which decides what a tap starts.
enum V2VoiceContext: Equatable {
    /// Chats, Tasks, Bots and Settings: a new call in the current profile.
    case home
    /// A project's page: a new chat in that project's folder, in voice.
    case project(ProjectSummary)
    /// The open conversation: voice in it (a Bot Chat calls its bot, a
    /// saved call's row resumes the call).
    case conversation
}

struct V2VoiceButton: View {
    /// The button's look: the gold circle, or a plain glyph in a top bar
    /// when the gold circle starts new chats instead.
    enum Style: Equatable {
        case circle
        /// In a top bar's glass capsule, like New chat's pencil.
        case capsule
        /// In a navigation bar's toolbar.
        case toolbar
    }

    let context: V2VoiceContext
    var style: Style = .circle
    /// Faded out (the expanded composer): its bars stop redrawing unseen.
    var isHidden = false
    @EnvironmentObject private var appState: AppState
    /// What the big button beside a chat does, app-wide (Settings >
    /// Appearance); a profile can override it.
    @AppStorage(ChatVoiceButtonAction.key) private var appChatVoiceButton = ChatVoiceButtonAction.defaultValue.rawValue
    /// A start in flight: a second tap doesn't make a second chat or call.
    @State private var isStarting = false
    @ObservedObject private var voiceMessages = VoiceMessageRecorder.shared
    /// When the press that may become a held recording began.
    @State private var pressBegan: Date?
    /// The finger slid far enough away that letting go throws the held
    /// recording away.
    @State private var releaseCancels = false
    /// This press became a held recording (whether or not it started).
    @State private var holdStarted = false
    /// Down on the button; resets on release and on a cancelled press.
    @GestureState private var isPressing = false

    /// How long a press lasts before it records while held.
    static let holdToRecordDelay: TimeInterval = 0.3
    /// How far the finger slides away before letting go cancels.
    static let slideToCancelDistance: CGFloat = 80

    static let diameter: CGFloat = 56

    /// A minimised call: the button is the way back to it.
    private var returnsToCall: Bool { appState.minimisedLiveVoice != nil }
    /// Voice is off for this profile: the button opens its setup instead.
    private var needsSetup: Bool { !appState.showsComposerVoiceButton }

    /// The big button beside a chat's composer: its tap is the chosen
    /// action, and touch and hold offers the others.
    private var isChatButton: Bool { context == .conversation && style == .circle }

    /// What a tap does here. Only the chat's big button follows the
    /// setting; a top-bar button is always the call.
    private var chatAction: ChatVoiceButtonAction {
        guard isChatButton else { return .liveCall }
        return ChatVoiceButtonAction.resolved(profile: appState.chatVoiceButtonOverride, app: appChatVoiceButton)
    }

    /// A tap dictates into the draft. A minimised call still comes first:
    /// the button is the way back to it.
    private var dictates: Bool { chatAction == .dictation && !returnsToCall }

    /// A tap records a voice message; holding records until let go.
    private var recordsMessage: Bool { chatAction == .voiceMessage && !returnsToCall }

    private var canAct: Bool {
        if dictates { return appState.composerIsEnabled && !appState.isVoiceInUse }
        if recordsMessage {
            return appState.composerIsEnabled && !appState.isVoiceInUse
                && (!voiceMessages.isActive || voiceMessages.isHeld)
        }
        if returnsToCall || needsSetup { return true }
        guard !isStarting, !appState.isPreparingVoiceResume,
              appState.canStartPhoneVoiceConversation, !appState.isVoiceInUse else { return false }
        // In a chat, like the composer's voice button: not mid-sync, and a
        // running reply only holds back classic voice.
        if context == .conversation {
            return appState.composerIsEnabled && !appState.voiceWaitsForRunningTurn
        }
        return true
    }

    /// The three most recently active conversations of this profile, but
    /// Pulse's own chat, which the Pulse screen stands in for.
    private var recentSessions: [SessionSummary] {
        let sessions = appState.activeProfileSessions
        guard appState.pulseHomeChatID != nil else { return Self.mostRecent(sessions, limit: 3) }
        return Self.mostRecent(sessions.filter { !appState.isPulseHomeChat($0) }, limit: 3)
    }

    /// The `limit` most recently active of `sessions`, newest first, ties
    /// in list order. One pass rather than a sort: the button redraws with
    /// every AppState publish.
    static func mostRecent(_ sessions: [SessionSummary], limit: Int) -> [SessionSummary] {
        var recent: [SessionSummary] = []
        for session in sessions {
            let activity = session.lastActivityAt ?? 0
            let index = recent.firstIndex { ($0.lastActivityAt ?? 0) < activity } ?? recent.count
            guard index < limit else { continue }
            recent.insert(session, at: index)
            if recent.count > limit { recent.removeLast() }
        }
        return recent
    }

    private var showsRecentMenu: Bool {
        context == .home && !returnsToCall && !needsSetup && !recentSessions.isEmpty
    }

    /// Touch and hold on the chat's big button: a live call or dictation,
    /// whichever the tap doesn't do.
    private var showsChatMenu: Bool { isChatButton && !returnsToCall && !recordsMessage }

    /// The call's label in the chat, whatever the button's tap does.
    private var conversationCallLabel: String {
        if appState.openChatCallToResume != nil { return AppLocalization.string("Resume call") }
        if appState.activeBotChatProfile != nil {
            return AppLocalization.string("Call \(appState.conversationAgentIdentity.name)")
        }
        return AppLocalization.string("Talk in this conversation")
    }

    private var label: String {
        if returnsToCall { return AppLocalization.string("Return to call") }
        if dictates { return AppLocalization.string("Dictate") }
        if recordsMessage { return AppLocalization.string("Record voice message") }
        if needsSetup { return AppLocalization.string("Set up voice") }
        switch context {
        case .home: return AppLocalization.string("New voice call")
        case .project(let project):
            return Self.folder(of: project) == nil
                ? AppLocalization.string("New voice call")
                : AppLocalization.string("Talk in this project")
        case .conversation:
            return conversationCallLabel
        }
    }

    private var hint: String? {
        if dictates {
            return canAct
                ? AppLocalization.string("Types what you say into the message. Touch and hold for a live call.")
                : nil
        }
        if recordsMessage {
            return canAct
                ? AppLocalization.string("Records a voice message. Or touch and hold to record, and let go to send.")
                : nil
        }
        if !canAct { return appState.phoneVoiceUnavailableReason }
        if showsChatMenu { return AppLocalization.string("Touch and hold to dictate instead") }
        return showsRecentMenu ? AppLocalization.string("Touch and hold for recent conversations") : nil
    }

    var body: some View {
        Group {
            if showsRecentMenu {
                Menu {
                    Button {
                        tap()
                    } label: {
                        Label("New voice call", systemImage: "waveform")
                    }
                    Section("Recent") {
                        ForEach(recentSessions) { session in
                            Button {
                                talk(in: session.id)
                            } label: {
                                Label {
                                    Text(verbatim: session.title)
                                } icon: {
                                    Image(systemName: "bubble.left")
                                }
                            }
                        }
                    }
                } label: {
                    face
                } primaryAction: {
                    tap()
                }
                .menuIndicator(.hidden)
            } else if showsChatMenu {
                Menu {
                    Button {
                        callTap()
                    } label: {
                        Label(conversationCallLabel, systemImage: "waveform")
                    }
                    Button {
                        dictate()
                    } label: {
                        Label(AppLocalization.string("Dictate"), systemImage: "mic")
                    }
                    .disabled(!appState.composerIsEnabled || appState.isVoiceInUse)
                } label: {
                    face
                } primaryAction: {
                    tap()
                }
                .menuIndicator(.hidden)
            } else if recordsMessage {
                face
                    .gesture(holdToRecord)
                    // A press the system took away never reaches onEnded.
                    // A turn later, so a normal release's onEnded goes first.
                    .onChange(of: isPressing) { _, pressing in
                        guard !pressing else { return }
                        Task { @MainActor in finishPress(cancelled: true) }
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { tap() }
            } else {
                Button(action: tap) { face }
                    .buttonStyle(PressableButtonStyle())
            }
        }
        .disabled(!canAct)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .macTooltip(label)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: dictates || recordsMessage ? chatAction.symbol : "waveform")
        }
    }

    @ViewBuilder private var face: some View {
        switch style {
        case .circle: circleFace
        case .capsule:
            V2CapsuleIcon(systemImage: "waveform", tint: returnsToCall ? Color.conduitAccent : nil)
                .opacity(canAct ? 1 : 0.55)
        case .toolbar:
            Image(systemName: "waveform")
                .foregroundStyle(returnsToCall ? Color.conduitAccent : Color.primary)
                .opacity(canAct ? 1 : 0.55)
        }
    }

    private var circleFace: some View {
        Group {
            if dictates || recordsMessage {
                Image(systemName: chatAction.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .conduitFixedGlyph()
                    .foregroundStyle(Color.black.opacity(0.82))
            } else {
                // Only a minimised call moves them: any other call's screen
                // covers the button, so it doesn't redraw unseen.
                V2VoiceBars(isLive: returnsToCall && !isHidden)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .background(Color.conduitAccent, in: Circle())
        .opacity(canAct ? 1 : 0.55)
        .contentShape(Circle())
    }

    /// The project's folder for a new chat, as its page reads it.
    static func folder(of project: ProjectSummary) -> String? {
        guard let path = project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }

    // MARK: - Actions

    private func tap() {
        if dictates {
            dictate()
            return
        }
        if recordsMessage {
            Haptics.medium()
            Task { await appState.startVoiceMessage() }
            return
        }
        callTap()
    }

    /// A tap starts a recording to preview; a press held past a moment
    /// records until let go and sends, unless the finger slid away.
    private var holdToRecord: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard canAct else { return }
                if pressBegan == nil {
                    let began = Date()
                    pressBegan = began
                    releaseCancels = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Self.holdToRecordDelay))
                        // Still the same press, and still down.
                        guard pressBegan == began, !voiceMessages.isActive else { return }
                        Haptics.medium()
                        holdStarted = true
                        voiceMessages.isHeld = true
                        await appState.startVoiceMessage()
                    }
                }
                let distance = hypot(value.translation.width, value.translation.height)
                let cancels = distance > Self.slideToCancelDistance
                if voiceMessages.isHeld, cancels != releaseCancels {
                    releaseCancels = cancels
                    Haptics.selection()
                }
            }
            .updating($isPressing) { _, pressing, _ in pressing = true }
            .onEnded { _ in finishPress(cancelled: false) }
    }

    /// The press ended: let go, or taken away by the system (an alert such
    /// as the first microphone permission, a call, Control Center).
    private func finishPress(cancelled: Bool) {
        guard pressBegan != nil else { return }
        let held = holdStarted
        let cancels = releaseCancels
        pressBegan = nil
        releaseCancels = false
        holdStarted = false
        guard held else {
            // A tap, not a hold.
            if !cancelled, canAct { tap() }
            return
        }
        // The recording couldn't start: its reason is showing.
        guard voiceMessages.isHeld else { return }
        voiceMessages.isHeld = false
        // Nobody let go: the recording carries on with its Stop button,
        // to preview before sending.
        guard !cancelled else { return }
        Task { @MainActor in
            // Let go while the microphone was still coming up. Not for
            // long: a start that waits on longer is left to its Stop
            // button rather than sent much later.
            let deadline = Date().addingTimeInterval(5)
            while voiceMessages.phase == .starting {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if cancels {
                Haptics.light()
                voiceMessages.cancel()
                return
            }
            if voiceMessages.phase == .recording {
                await voiceMessages.stop()
            }
            // Already stopping on its own (the length cap, or the
            // microphone went away): still let go to send.
            while voiceMessages.phase == .finishing {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard voiceMessages.phase == .recorded else { return }
            await appState.sendRecordedVoiceMessage()
        }
    }

    /// Dictation in the open chat's composer, which expands to show it.
    private func dictate() {
        appState.requestComposerDictation()
    }

    /// Voice where the button is: back to a minimised call, voice setup,
    /// or a new call.
    private func callTap() {
        if returnsToCall {
            Haptics.medium()
            appState.restoreMinimisedLiveVoice()
            return
        }
        if needsSetup {
            Haptics.medium()
            appState.settingsLinkRequest = .voice
            return
        }
        guard !isStarting else { return }
        Haptics.medium()
        isStarting = true
        switch context {
        case .home:
            // A call of its own, like the old drawer's New voice call. Its
            // screen covers the tabs; the list stays where it was.
            Task { @MainActor in
                defer { isStarting = false }
                await startVoice(
                    PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: true, source: .newCall)
                )
            }
        case .conversation:
            // Voice in the open chat, as the composer's voice button does.
            Task { @MainActor in
                defer { isStarting = false }
                await startVoice(
                    PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
                )
            }
        case .project(let project):
            // A new chat in the project's folder, then voice in it. Without a
            // folder (the page offers no New conversation either) it's a call
            // of its own rather than a chat outside the project.
            guard let path = Self.folder(of: project) else {
                Task { @MainActor in
                    defer { isStarting = false }
                    await startVoice(
                        PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: true, source: .newCall)
                    )
                }
                return
            }
            let previous = appState.activeSessionId
            Task { @MainActor in
                defer { isStarting = false }
                await appState.createNewSession(cwd: path)
                guard appState.activeSessionId != previous else {
                    reportCouldNotOpen()
                    return
                }
                await startVoice(
                    PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
                )
            }
        }
    }

    /// Starts voice, and says so when it couldn't (the connection dropped
    /// between showing the button and the tap).
    private func startVoice(_ intent: PendingVoiceIntent) async {
        let started = await appState.openVoiceConversation(intent)
        if !started, !appState.isConnected {
            appState.errorMessage = AppLocalization.string("Reconnect to Hermes to start voice.")
        }
    }

    /// A chat couldn't be made or opened: say so, unless something already did.
    private func reportCouldNotOpen() {
        guard appState.errorMessage == nil else { return }
        appState.errorMessage = appState.isConnected
            ? AppLocalization.string("Couldn't open that chat for voice.")
            : AppLocalization.string("Reconnect to Hermes to start voice.")
    }

    /// Opens a recent conversation and talks in it.
    private func talk(in sessionID: String) {
        guard !isStarting else { return }
        Haptics.medium()
        isStarting = true
        Task { @MainActor in
            defer { isStarting = false }
            switch await appState.openSessionOutcome(sessionID) {
            case .opened: break
            // A newer navigation took over: not a failure, and not this chat.
            case .superseded: return
            case .failed:
                reportCouldNotOpen()
                return
            }
            await startVoice(
                PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
            )
        }
    }
}

/// The gold circle when the user swapped it for New chat (Settings >
/// Appearance): a new chat in the current profile, or on a project's page a
/// new chat in its folder. Voice moves to the top bar's New chat slot.
struct V2NewChatButton: View {
    let context: V2VoiceContext
    @EnvironmentObject private var appState: AppState
    /// A creation in a project's folder in flight: a second tap doesn't
    /// make a second chat.
    @State private var isCreating = false

    /// A plain new chat answers while Conduit connects, as the pencil does.
    /// One in a project's folder is dimmed while disconnected (a tap would
    /// do nothing) and on the saved copy, which has no live gateway to
    /// create a chat on.
    private var canAct: Bool {
        guard folder != nil else { return appState.canTapNewChat }
        return appState.isConnected && appState.turnState != .synchronizing && appState.offlineChatPresentation == nil
    }

    private var folder: String? {
        if case .project(let project) = context { return V2VoiceButton.folder(of: project) }
        return nil
    }

    private var label: String {
        if case .project(let project) = context, folder != nil {
            return AppLocalization.string("New conversation in \(project.title)")
        }
        return AppLocalization.string("New Chat")
    }

    var body: some View {
        Button {
            guard let path = folder else {
                Haptics.medium()
                appState.startNewChat()
                return
            }
            guard !isCreating else { return }
            isCreating = true
            Haptics.medium()
            appState.dismissSidebarDrawer()
            Task { @MainActor in
                defer { isCreating = false }
                await appState.createNewSession(cwd: path)
            }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 21, weight: .semibold))
                .conduitFixedGlyph()
                .foregroundStyle(Color.black.opacity(0.82))
                .frame(width: V2VoiceButton.diameter, height: V2VoiceButton.diameter)
                .background(Color.conduitAccent, in: Circle())
                .opacity(canAct ? 1 : 0.55)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!canAct)
        .accessibilityLabel(label)
        .macTooltip(label)
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: "square.and.pencil")
        }
    }
}

/// The button's glyph: five dark bars, swaying while a call is live. They
/// stand still without a call (nothing redraws, so the app can idle) and
/// under Reduce Motion.
struct V2VoiceBars: View {
    let isLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let restingHeights: [CGFloat] = [0.34, 0.62, 0.9, 0.62, 0.34]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !isLive || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(Color.black.opacity(0.82))
                        .frame(width: 3.5, height: 22 * height(index, time: time))
                }
            }
            .frame(height: 22)
        }
        .accessibilityHidden(true)
    }

    private func height(_ index: Int, time: TimeInterval) -> CGFloat {
        let resting = Self.restingHeights[index]
        guard isLive, !reduceMotion else { return resting }
        let wave = sin(time * 6 + Double(index) * 1.1)
        return max(0.22, min(1, resting + CGFloat(wave) * 0.3))
    }
}
