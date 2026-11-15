//
//  V2VoiceButton.swift
//  Conduit
//
//  V2's voice button: a gold circle beside the tab bar on every tab and
//  project page, except split beside a chat that shows its own. A tap starts voice where the user is (a new call, or a
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
    /// Sessions, Tasks and Settings: a new call in the current profile.
    case home
    /// Bots Home: a tap lists the bots, the one used last first, and
    /// picking one calls it in its Bot Chat (Eric 2026-11-03).
    case bots
    /// A project's page: a new chat in that project's folder, in voice.
    case project(ProjectSummary)
    /// The open conversation: voice in it (a Bot Chat calls its bot, a
    /// saved call's row resumes the call).
    case conversation

    /// The same button: a project's page is told apart by its folder, all
    /// the button reads of it, so the page's other changes (its chats, its
    /// count) don't redraw the button.
    func isSameVoiceButton(as other: V2VoiceContext) -> Bool {
        switch (self, other) {
        case (.home, .home), (.bots, .bots), (.conversation, .conversation): return true
        case (.project(let mine), .project(let theirs)):
            return V2VoiceButton.folder(of: mine) == V2VoiceButton.folder(of: theirs)
        default: return false
        }
    }
}

/// The gold circle or its top-bar glyph. This outer view reads AppState, so
/// it runs with every publish, and hands what the button shows to
/// `V2VoiceButtonContent`, which redraws only when that changes: several
/// buttons stay alive under a pushed chat (the tabs', a top bar's, a
/// project page's), and none of them should redraw during a push or a
/// swipe back.
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

    /// How long a press lasts before it records while held.
    static let holdToRecordDelay: TimeInterval = 0.3
    /// How far the finger slides away before letting go cancels.
    static let slideToCancelDistance: CGFloat = 80

    static let diameter: CGFloat = 56

    var body: some View {
        V2VoiceButtonContent(
            context: context,
            style: style,
            isHidden: isHidden,
            inputs: V2VoiceButtonInputs(appState: appState, context: context, style: style, appChatVoiceButton: appChatVoiceButton),
            appState: appState
        )
        .equatable()
    }

    /// The `limit` most recently active of `sessions`, newest first, ties
    /// in list order. One pass rather than a sort: the button reads them
    /// with every AppState publish.
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

    static func botsToCall(_ roster: [BotProfile]) -> [BotProfile] {
        let shown = roster.filter { !$0.isHiddenByMeta }
        return shown.enumerated().sorted { a, b in
            let left = a.element.lastActive ?? 0, right = b.element.lastActive ?? 0
            return left != right ? left > right : a.offset < b.offset
        }.map(\.element)
    }

    /// The bot a menu's choice names, as the roster has it now: the menu
    /// keeps only its name and label. Nil once it has left the roster.
    static func bot(_ choice: V2VoiceBotChoice, in roster: [BotProfile]) -> BotProfile? {
        roster.first { $0.name == choice.id }
    }

    /// The project's folder for a new chat, as its page reads it.
    static func folder(of project: ProjectSummary) -> String? {
        guard let path = project.primaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return path
    }
}

/// A bot in Bots Home's voice menu: what the menu shows of it. The tap
/// reads the bot itself from the roster.
struct V2VoiceBotChoice: Identifiable, Equatable {
    /// The bot's profile name.
    let id: String
    let label: String
}

/// A recent conversation in the voice button's menu.
struct V2VoiceRecentChat: Identifiable, Equatable {
    let id: String
    let title: String
}

/// What a voice button shows, read from AppState once per publish. The
/// button redraws when one of these changes, and not otherwise.
struct V2VoiceButtonInputs: Equatable {
    /// A minimised call: the button is the way back to it.
    let returnsToCall: Bool
    /// Voice is off for this profile: the button opens its setup instead.
    let needsSetup: Bool
    /// What a tap does here. Only the chat's big button follows the
    /// setting; a top-bar button is always the call.
    let chatAction: ChatVoiceButtonAction
    /// The composer takes a dictation or a voice message now.
    let composerTakesVoice: Bool
    /// A call can start here now, but for a start of this button's own
    /// still in flight.
    let canStartCall: Bool
    /// Why a call can't start, for VoiceOver.
    let unavailableReason: String?
    /// Home's menu: the three most recently active conversations of this
    /// profile, but Pulse's own chat, which the Pulse screen stands in for.
    let recentChats: [V2VoiceRecentChat]
    /// Bots Home's menu: the bots shown there, the one that talked last
    /// first.
    let callableBots: [V2VoiceBotChoice]
    /// The call's label in the chat, whatever the button's tap does.
    let conversationCallLabel: String
    /// The App Language its labels were made in.
    let language: AppLanguage

    @MainActor
    init(appState: AppState, context: V2VoiceContext, style: V2VoiceButton.Style, appChatVoiceButton: String) {
        language = AppLanguage.current
        returnsToCall = appState.minimisedLiveVoice != nil
        needsSetup = !appState.showsComposerVoiceButton
        chatAction = context == .conversation && style == .circle
            ? ChatVoiceButtonAction.resolved(profile: appState.chatVoiceButtonOverride, app: appChatVoiceButton)
            : .liveCall
        let voiceInUse = appState.isVoiceInUse
        let composerIsEnabled = appState.composerIsEnabled
        composerTakesVoice = composerIsEnabled && !voiceInUse
        unavailableReason = appState.phoneVoiceUnavailableReason
        if appState.isPreparingVoiceResume || unavailableReason != nil || voiceInUse {
            canStartCall = false
        } else if context == .conversation {
            // In a chat, like the composer's voice button: not mid-sync, and a
            // running reply only holds back classic voice.
            canStartCall = composerIsEnabled && !appState.voiceWaitsForRunningTurn
        } else {
            canStartCall = true
        }
        if context == .home {
            let sessions = appState.activeProfileSessions
            let listed = appState.pulseHomeChat == nil ? sessions : sessions.filter { !appState.isPulseHomeChat($0) }
            recentChats = V2VoiceButton.mostRecent(listed, limit: 3).map { V2VoiceRecentChat(id: $0.id, title: $0.title) }
        } else {
            recentChats = []
        }
        callableBots = context == .bots
            ? V2VoiceButton.botsToCall(appState.shownBotRoster).map { V2VoiceBotChoice(id: $0.name, label: $0.displayLabel) }
            : []
        if context != .conversation {
            conversationCallLabel = ""
        } else if appState.openChatCallToResume != nil {
            conversationCallLabel = AppLocalization.string("Resume call")
        } else if appState.activeBotChatProfile != nil {
            conversationCallLabel = AppLocalization.string("Call \(appState.conversationAgentIdentity.name)", table: .voice)
        } else {
            conversationCallLabel = AppLocalization.string("Talk in this conversation", table: .voice)
        }
    }
}

/// The button itself, behind `.equatable()`: AppState is held for its
/// actions only, never observed here.
struct V2VoiceButtonContent: View, Equatable {
    let context: V2VoiceContext
    let style: V2VoiceButton.Style
    /// Faded out (the expanded composer): its bars stop redrawing unseen.
    let isHidden: Bool
    let inputs: V2VoiceButtonInputs
    let appState: AppState
    @Environment(\.v2MainButtonDiameter) private var mainButtonDiameter
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

    nonisolated static func == (lhs: V2VoiceButtonContent, rhs: V2VoiceButtonContent) -> Bool {
        lhs.context.isSameVoiceButton(as: rhs.context) && lhs.style == rhs.style && lhs.isHidden == rhs.isHidden
            && lhs.inputs == rhs.inputs && lhs.appState === rhs.appState
    }

    private var returnsToCall: Bool { inputs.returnsToCall }
    private var needsSetup: Bool { inputs.needsSetup }

    /// The big button beside a chat's composer: its tap is the chosen
    /// action, and touch and hold offers the others.
    private var isChatButton: Bool { context == .conversation && style == .circle }

    private var chatAction: ChatVoiceButtonAction { inputs.chatAction }

    /// A tap dictates into the draft. A minimised call still comes first:
    /// the button is the way back to it.
    private var dictates: Bool { chatAction == .dictation && !returnsToCall }

    /// A tap records a voice message; holding records until let go.
    private var recordsMessage: Bool { chatAction == .voiceMessage && !returnsToCall }

    private var canAct: Bool {
        if dictates { return inputs.composerTakesVoice }
        if recordsMessage {
            return inputs.composerTakesVoice && (!voiceMessages.isActive || voiceMessages.isHeld)
        }
        if returnsToCall || needsSetup { return true }
        return !isStarting && inputs.canStartCall
    }

    private var recentChats: [V2VoiceRecentChat] { inputs.recentChats }

    private var showsRecentMenu: Bool {
        context == .home && !returnsToCall && !needsSetup && !recentChats.isEmpty
    }

    /// Bots Home's button: which bot to call, never a call of its own.
    private var showsBotMenu: Bool {
        context == .bots && !returnsToCall && !needsSetup && !callableBots.isEmpty
    }

    private var callableBots: [V2VoiceBotChoice] { inputs.callableBots }

    /// Touch and hold on the chat's big button: a live call or dictation,
    /// whichever the tap doesn't do.
    private var showsChatMenu: Bool { isChatButton && !returnsToCall && !recordsMessage }

    private var conversationCallLabel: String { inputs.conversationCallLabel }

    private var label: String {
        if returnsToCall { return AppLocalization.string("Return to call", table: .voice) }
        if dictates { return AppLocalization.string("Dictate") }
        if recordsMessage { return AppLocalization.string("Record voice message", table: .voice) }
        if needsSetup { return AppLocalization.string("Set up voice", table: .voice) }
        switch context {
        case .home: return AppLocalization.string("New voice call")
        case .bots:
            return callableBots.isEmpty ? AppLocalization.string("New voice call") : AppLocalization.string("Call a bot", table: .voice)
        case .project(let project):
            return V2VoiceButton.folder(of: project) == nil
                ? AppLocalization.string("New voice call")
                : AppLocalization.string("Talk in this project", table: .voice)
        case .conversation:
            return conversationCallLabel
        }
    }

    private var hint: String? {
        if dictates {
            return canAct
                ? AppLocalization.string("Types what you say into the message. Touch and hold for a live call.", table: .voice)
                : nil
        }
        if recordsMessage {
            return canAct
                ? AppLocalization.string("Records a voice message. Or touch and hold to record, and let go to send.", table: .voice)
                : nil
        }
        if !canAct { return inputs.unavailableReason }
        if showsChatMenu { return AppLocalization.string("Touch and hold to dictate instead", table: .voice) }
        if showsBotMenu { return AppLocalization.string("Lists your bots to call one", table: .voice) }
        return showsRecentMenu ? AppLocalization.string("Touch and hold for recent conversations", table: .voice) : nil
    }

    var body: some View {
        Group {
            if showsBotMenu {
                Menu {
                    ForEach(callableBots) { bot in
                        Button {
                            call(bot)
                        } label: {
                            Label {
                                Text(verbatim: bot.label)
                            } icon: {
                                Image(systemName: "waveform")
                            }
                        }
                    }
                } label: {
                    face
                }
                .menuIndicator(.hidden)
                // The one used last stays nearest the button.
                .menuOrder(.fixed)
            } else if showsRecentMenu {
                Menu {
                    Button {
                        tap()
                    } label: {
                        Label("New voice call", systemImage: "waveform")
                    }
                    Section("Recent") {
                        ForEach(recentChats) { session in
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
                    .disabled(!inputs.composerTakesVoice)
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
        .frame(width: mainButtonDiameter, height: mainButtonDiameter)
        .background(Color.conduitAccent, in: Circle())
        .opacity(canAct ? 1 : 0.55)
        .contentShape(Circle())
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
                        try? await Task.sleep(for: .seconds(V2VoiceButton.holdToRecordDelay))
                        // Still the same press, and still down.
                        guard pressBegan == began, !voiceMessages.isActive else { return }
                        Haptics.medium()
                        holdStarted = true
                        voiceMessages.isHeld = true
                        await appState.startVoiceMessage()
                    }
                }
                let distance = hypot(value.translation.width, value.translation.height)
                let cancels = distance > V2VoiceButton.slideToCancelDistance
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
        case .home, .bots:
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
            guard let path = V2VoiceButton.folder(of: project) else {
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

    /// Opens a bot's Bot Chat and calls the bot in it.
    private func call(_ choice: V2VoiceBotChoice) {
        guard !isStarting else { return }
        guard let bot = V2VoiceButton.bot(choice, in: appState.shownBotRoster) else {
            // Removed or renamed while the menu was open. Bots Home shows
            // its own notice, not a chat's error.
            appState.botsListNotice = AppLocalization.string("Could not open \(choice.label)'s Bot Chat.")
            return
        }
        Haptics.medium()
        isStarting = true
        Task { @MainActor in
            defer { isStarting = false }
            appState.beginOpeningBotChat(bot.name)
            let opened = await appState.openBotChatFromList(bot)
            // A failed open says why itself; a superseded one (a newer
            // navigation took over) is no failure, so nothing more is said.
            guard opened else { return }
            await startVoice(
                PendingVoiceIntent(profile: appState.activeProfile, startsFreshConversation: false, source: .composer)
            )
        }
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
    @Environment(\.v2MainButtonDiameter) private var mainButtonDiameter
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
                .frame(width: mainButtonDiameter, height: mainButtonDiameter)
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

private struct V2MainButtonDiameterKey: EnvironmentKey {
    static let defaultValue: CGFloat = V2VoiceButton.diameter
}

extension EnvironmentValues {
    /// The main button's circle (Voice or New chat): 56 pt beside the
    /// floating tabs, the 50 pt of iOS's own controls in a Duo's status
    /// strip (issue 2118).
    var v2MainButtonDiameter: CGFloat {
        get { self[V2MainButtonDiameterKey.self] }
        set { self[V2MainButtonDiameterKey.self] = newValue }
    }
}
