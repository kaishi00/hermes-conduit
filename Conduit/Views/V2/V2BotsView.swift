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
                    V2AddButton(title: AppLocalization.string("New Bot")) {
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
            MinimisedLiveVoiceBar()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(V2Tab.bots.title)
    }
}
