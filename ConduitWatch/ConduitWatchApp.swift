//
//  ConduitWatchApp.swift
//  Conduit Watch
//
//  Talk to Hermes from the wrist. Gemini Live runs on the Watch itself
//  (designs/apple-watch-voice-direct.md); GPT-Live runs on the Hermes host,
//  which streams it to the Watch through the push relay
//  (designs/apple-watch-gpt-live.md). The iPhone sets each call up and
//  saves it in voice history; the call itself carries on with the wrist
//  down and the phone locked.
//

import SwiftUI

@main
struct ConduitWatchApp: App {
    @StateObject private var call = WatchVoiceCall()
    @StateObject private var link = WatchLink.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(call)
                .environmentObject(link)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            call.scenePhaseChanged(phase)
        }
    }
}

/// The home screen, or the call while one is on screen.
struct WatchRootView: View {
    @EnvironmentObject private var call: WatchVoiceCall

    var body: some View {
        Group {
            if call.isPresenting {
                WatchCallView()
                    .transition(.opacity)
            } else {
                NavigationStack {
                    WatchHomeView()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: call.isPresenting)
    }
}
