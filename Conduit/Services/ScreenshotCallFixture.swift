//
//  ScreenshotCallFixture.swift
//  Conduit
//
//  App Store screenshots (scripts/app-store, ConduitScreenshots): a live
//  voice call's audio can't be played into a simulator, so
//  `-conduitScreenshotCall speaking|listening` puts the real call screen
//  over the app with a scripted conversation and no session behind it.
//  Debug builds only.
//

#if DEBUG
import SwiftUI

enum ScreenshotCallFixture {
    static let launchArgument = "-conduitScreenshotCall"

    static func phase(arguments: [String] = ProcessInfo.processInfo.arguments) -> LiveVoiceCallPhase? {
        guard let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count else { return nil }
        switch arguments[index + 1] {
        case "listening": return .listening
        case "speaking": return .speaking
        default: return nil
        }
    }

    // Demo content, English only like the rest of the demo world.
    static let transcript: [VoiceConversationTranscriptEntry] = [
        .init(speaker: .user, text: "What's on my calendar this afternoon?"),
        .init(speaker: .assistant, text: "Two things: a dentist appointment at 3, and Maya's soccer practice at 5:30. Want me to set a reminder to leave by 2:40?"),
        .init(speaker: .user, text: "Yes, and text Maya's coach that we might be ten minutes late."),
        .init(speaker: .assistant, text: "Reminder set for 2:40. I've drafted the text to Coach Rivera and started a job to send it.")
    ]
}

struct ScreenshotCallFixtureModifier: ViewModifier {
    let appState: AppState
    @State private var phase = ScreenshotCallFixture.phase()

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { phase != nil }, set: { if !$0 { phase = nil } })) {
            if let phase {
                LiveVoiceCallSheet(
                    title: AppLocalization.string("Gemini Live"),
                    phase: phase,
                    statusText: phase == .speaking ? AppLocalization.string("Speaking") : AppLocalization.string("Listening"),
                    transcript: ScreenshotCallFixture.transcript,
                    assistantLabel: { "Hermes: \($0)" },
                    jobs: appState.voiceBackgroundJobSupervisor,
                    appState: appState,
                    isMicrophoneMuted: false,
                    isSpeakerMuted: false,
                    canMute: true,
                    canInterrupt: phase == .speaking,
                    onToggleMute: {},
                    onToggleSpeaker: {},
                    onInterrupt: {},
                    onEnd: { self.phase = nil },
                    onRetry: {}
                )
            }
        }
    }
}
#endif
