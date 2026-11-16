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

struct V2BotsView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @State private var createRequest = false

    private var canCreate: Bool {
        appState.botModePhase == .available && appState.isConnected
    }

    /// The dashboard a new bot is made on, when more than one is combined.
    private var createDashboardID: UUID? {
        guard let id = appState.activeDashboardID, appState.isInCombinedGroup(id) else { return nil }
        return appState.combinedDashboardBadge(id) == nil ? nil : id
    }

    private var newBotTitle: String {
        let title = AppLocalization.string("New Bot", table: .bots)
        guard let id = createDashboardID, let badge = appState.combinedDashboardBadge(id) else { return title }
        return "\(title), \(badge.name)"
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
                    V2AddButton(title: newBotTitle) {
                        createRequest = true
                    }
                    // Combined, the "+" wears the badge of the dashboard the
                    // bot is made on, the one on screen (Eric, 2026-11-16).
                    .overlay(alignment: .bottomTrailing) {
                        if let id = createDashboardID {
                            CombinedDashboardBadge(dashboardID: id, size: 16)
                                .offset(x: 4, y: 4)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
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
    }
}
