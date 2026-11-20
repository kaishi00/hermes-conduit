//
//  ScreenshotCallFixture.swift
//  Conduit
//
//  App Store screenshots (scripts/app-store, ConduitScreenshots): a live
//  voice call's audio can't be played into a simulator, so
//  `-conduitScreenshotCall speaking|listening` puts the real call screen
//  over the app with a scripted conversation and no session behind it.
//  `-conduitScreenshotCallProvider qwen|gpt|grok` titles it for that
//  provider (Gemini Live otherwise), and an app running in Simplified Chinese
//  gets the conversation in Chinese (the zh-Hans demo videos).
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

    static let providerArgument = "-conduitScreenshotCallProvider"

    /// The call screen's title, as the real call names its provider.
    static func title(arguments: [String] = ProcessInfo.processInfo.arguments) -> String {
        let provider = arguments.firstIndex(of: providerArgument).flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        switch provider {
        case "qwen": return AppLocalization.string("Qwen Live")
        case "gpt": return AppLocalization.string("GPT-Live")
        case "grok": return AppLocalization.string("Grok Live")
        default: return AppLocalization.string("Gemini Live")
        }
    }

    /// The conversation in the language the app is running in: Simplified
    /// Chinese for the zh-Hans demo videos, English otherwise.
    static var transcript: [VoiceConversationTranscriptEntry] {
        Bundle.main.preferredLocalizations.first == "zh-Hans" ? transcriptZhHans : transcriptEnglish
    }

    static let transcriptZhHans: [VoiceConversationTranscriptEntry] = [
        .init(speaker: .user, text: "我今天下午有什么安排？"),
        .init(speaker: .assistant, text: "两件事：三点看牙医，五点半是小美的足球训练。要我设个两点四十出发的提醒吗？"),
        .init(speaker: .user, text: "好，再给教练发个消息，说我们可能晚到十分钟。"),
        .init(speaker: .assistant, text: "提醒设好了，两点四十。给李教练的消息已经起草好，正在后台发送。")
    ]

    static let transcriptEnglish: [VoiceConversationTranscriptEntry] = [
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
                    title: ScreenshotCallFixture.title(),
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
