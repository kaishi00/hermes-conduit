//
//  V2BotsView.swift
//  Conduit
//
//  Bots, Conduit's first tab: the bots as portraits under a plain "Bots"
//  title with a "+" for a new bot and the Pulse and Artifacts shortcuts
//  (the profile picker steps aside here; V2BotsHome.swift). Tapping a bot
//  opens its persistent chat in this tab; editing stays in BotEditorSheet.
//

import SwiftUI

/// Mounts Bots behind `.equatable()`, equal by AppState identity:
/// redrawn by its own changes only, while the shell redraws on every
/// publish, as Tasks (V2TasksViewGate).
struct V2BotsViewGate: View, Equatable {
    @IdentityEquatable var appState: AppState

    var body: some View {
        V2BotsView(appState: appState)
    }
}

/// Bots, mounted through V2BotsViewGate.
struct V2BotsView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// Followed through `updates`, which holds AppState's changes back
    /// while another tab is up: a hidden Bots Home redrew on every publish
    /// of a turn (issue 1722).
    private let appState: AppState
    @StateObject private var updates: V2ShownUpdates
    @Environment(\.v2Shell) private var shell
    @State private var createRequest = false

    init(appState: AppState) {
        self.appState = appState
        _updates = StateObject(wrappedValue: V2ShownUpdates(appState))
    }

    /// What shows Bots Home: its tab, and nothing pushed over it.
    private var visibility: V2ListVisibility {
        V2ListVisibility(tabActive: shell.isTabActive, covered: shell.isRootCovered, split: shell.isSplit)
    }

    private var canCreate: Bool {
        appState.botModePhase == .available && appState.isConnected
    }

    var body: some View {
        ZStack {
            V2Backdrop(isTabRoot: true)
            BotRosterView(createRequest: $createRequest)
                .v2ProfileSwitchContent()
        }
        .v2EdgeBar(.top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(V2Tab.bots.title)
                        .scaledFont(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    V2AddButton(title: AppLocalization.string("New Bot", table: .bots)) {
                        createRequest = true
                    }
                    .disabled(!canCreate)
                }
                // Pulse and Artifacts are global, not any one bot's: small
                // shortcuts under the title rather than cards among the bots.
                BotsHomeShortcuts()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(minHeight: 52)
            .dynamicTypeSize(...DynamicTypeSize.pinnedChromeCap)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            V2ListCallBar()
        }
        // The feed's every-minute read, as the Chats tab draws it; this tab
        // keeps its own reader so Pulse's dot and marks stay fresh here too.
        .background(PulseFeedReader())
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(V2Tab.bots.title)
        .environmentObject(updates)
        .environment(\.v2ShownUpdates, updates)
        // Another tab or a chat pushed over Bots Home holds its updates
        // back, as the Chats list (audit 1722).
        .onChange(of: visibility, initial: true) { was, now in
            if now.isShown, !was.isShown {
                ResponsivenessSignposts.signposter.emitEvent("Bots shown", "pop \(now.isPop(from: was), privacy: .public)")
            }
            updates.follow(now, from: was)
        }
        // Beside an open chat, a streamed reply's bursts draw once, as
        // the Chats list's do.
        .onChange(of: shell.hasChatBeside, initial: true) { _, beside in
            updates.coalesces = beside
        }
    }
}
