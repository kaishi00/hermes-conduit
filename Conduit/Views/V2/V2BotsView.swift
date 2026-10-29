//
//  V2BotsView.swift
//  Conduit
//
//  Bots: the roster as a chat-style list under a plain "Bots" title with a
//  "+" for a new bot (the profile picker steps aside here). Tapping a bot
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
            HStack(spacing: 10) {
                Text(V2Tab.bots.title)
                    .font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button {
                    createRequest = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .conduitFixedGlyph()
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .conduitGlassControl(cornerRadius: 22, interactive: false)
                .disabled(!canCreate)
                .accessibilityLabel(AppLocalization.string("New Bot"))
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
