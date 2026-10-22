//
//  V2VoiceButton.swift
//  Conduit
//
//  V2's voice button: a gold circle beside the tab bar on every tab and
//  project page. A tap starts voice where the user is (a new call, or a
//  new chat in the open project's folder); touch and hold on a tab lists
//  the three most recent conversations to talk in instead. While a call is
//  minimised the button brings it back, its bars moving.
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
    /// A start in flight: a second tap doesn't make a second chat or call.
    @State private var isStarting = false

    static let diameter: CGFloat = 56

    /// A minimised call: the button is the way back to it.
    private var returnsToCall: Bool { appState.minimisedLiveVoice != nil }
    /// Voice is off for this profile: the button opens its setup instead.
    private var needsSetup: Bool { !appState.showsComposerVoiceButton }

    private var canAct: Bool {
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
        context == .home && !returnsToCall && !needsSetup && !appState.activeProfileSessions.isEmpty
    }

    private var label: String {
        if returnsToCall { return AppLocalization.string("Return to call") }
        if needsSetup { return AppLocalization.string("Set up voice") }
        switch context {
        case .home: return AppLocalization.string("New voice call")
        case .project(let project):
            return Self.folder(of: project) == nil
                ? AppLocalization.string("New voice call")
                : AppLocalization.string("Talk in this project")
        case .conversation:
            if appState.openChatCallToResume != nil { return AppLocalization.string("Resume call") }
            if appState.activeBotChatProfile != nil {
                return AppLocalization.string("Call \(appState.conversationAgentIdentity.name)")
            }
            return AppLocalization.string("Talk in this conversation")
        }
    }

    private var hint: String? {
        if !canAct { return appState.phoneVoiceUnavailableReason }
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
            } else {
                Button(action: tap) { face }
                    .buttonStyle(PressableButtonStyle())
            }
        }
        .disabled(!canAct)
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: "waveform")
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
        // Only a minimised call moves them: any other call's screen covers
        // the button, so it doesn't redraw unseen.
        V2VoiceBars(isLive: returnsToCall && !isHidden)
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
