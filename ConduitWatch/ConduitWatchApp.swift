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
    @StateObject private var call = WatchVoiceCall.shared
    @StateObject private var link = WatchLink.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchLink.shared.activate()
        // Before launch finishes: a call from Hermes that launched the app
        // waits on its PushKit registry.
        HermesWatchCalls.shared.activate()
        // The Action button, a control or a shortcut (TalkToHermesIntent).
        WatchCallRequests.handler = { WatchVoiceCall.shared.requestCall(source: $0) }
        WatchVoiceCall.shared.applyScreenshotFixture()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(call)
                .environmentObject(link)
                .onOpenURL { url in
                    // The watch face complication.
                    if WatchCallURL.isTalk(url) { call.requestCall(source: "complication") }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            call.scenePhaseChanged(phase)
            // A suspended app sends nothing: the call log's waiting lines
            // go first.
            if phase == .background { WatchCallLog.shared.sendBatch() }
        }
    }
}

/// The home screen, or the call while one is on screen.
struct WatchRootView: View {
    @EnvironmentObject private var call: WatchVoiceCall
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        let accent = WatchAccent.color(link.phoneContext?.accent)
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
        // The iPhone's accent. Not the app's tint: watchOS fills toolbar
        // buttons with it, which hid the Settings gear in a gold disc.
        .environment(\.watchAccent, accent)
    }
}
