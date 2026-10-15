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
    /// The open conversation: voice in it (a Bot Chat calls its bot).
    case conversation
}

struct V2VoiceButton: View {
    let context: V2VoiceContext
    /// Picks of iOS 26's voice tab slot under this button, which act as a tap.
    var slotPicks = 0
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
        guard !isStarting, appState.canStartPhoneVoiceConversation, !appState.isVoiceInUse else { return false }
        // In a chat, like the composer's voice button: not mid-sync or busy.
        if context == .conversation {
            return appState.composerIsEnabled && !appState.isBusy
        }
        return true
    }

    /// The three most recently active conversations of this profile.
    private var recentSessions: [SessionSummary] {
        let sorted = appState.activeProfileSessions.sorted {
            ($0.lastActivityAt ?? 0) > ($1.lastActivityAt ?? 0)
        }
        return Array(sorted.prefix(3))
    }

    private var showsRecentMenu: Bool {
        context == .home && !returnsToCall && !needsSetup && !recentSessions.isEmpty
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
            if let bot = appState.activeBotChatProfile {
                return AppLocalization.string("Call \(appState.profileDisplayName(bot))")
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
        .onChange(of: slotPicks) { _, _ in
            if canAct { tap() }
        }
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
        .accessibilityShowsLargeContentViewer {
            Label(label, systemImage: "waveform")
        }
    }

    private var face: some View {
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
