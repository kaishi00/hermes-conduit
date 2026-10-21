//
//  VoiceSetupIssue.swift
//  Conduit
//
//  Why Voice can't start, named by what the user has to fix and where.
//  A bare "Voice unavailable" on CarPlay read as "CarPlay doesn't work" to
//  an App Store reviewer whose Voice was simply never turned on, so every
//  surface says which thing is missing and where it is fixed.
//

import AVFoundation

/// The voice modes that run on the Hermes host, named as Voice settings
/// names them.
enum LiveVoiceModeName: Equatable {
    case geminiLive
    case gptLive
    case grokLive
    /// Local Live in agent mode: the host's fast model calls the tools.
    case localLive

    var displayName: String {
        switch self {
        case .geminiLive: return "Gemini Live"
        case .gptLive: return "GPT-Live"
        case .grokLive: return "Grok Live"
        case .localLive: return AppLocalization.string("Local Live")
        }
    }

    /// Stored in consent settings (health reads by voice).
    var storageID: String {
        switch self {
        case .geminiLive: return "gemini-live"
        case .gptLive: return "gpt-live"
        case .grokLive: return "grok-live"
        case .localLive: return "local-live"
        }
    }

    /// The company that runs the model, which receives what it reads.
    var company: String {
        switch self {
        case .geminiLive: return "Google"
        case .gptLive: return "OpenAI"
        case .grokLive: return "xAI"
        // Whichever model the user set their Hermes host to run for it.
        case .localLive: return AppLocalization.string("your Hermes host's model")
        }
    }

    static let all: [LiveVoiceModeName] = [.geminiLive, .gptLive, .grokLive, .localLive]
}

/// What a live voice mode's host check found wrong, kept by the live
/// controllers so CarPlay can say it without the phone's full message.
enum LiveVoiceHostIssue: Equatable {
    /// The Hermes notifier plugin (or its routes for this mode) is missing.
    case pluginMissing
    /// The host has the plugin but can't run the mode (no key, no sign-in).
    case notSetUp

    init?(_ availability: GeminiLiveAvailability) {
        switch availability {
        case .available: return nil
        case .pluginMissing: self = .pluginMissing
        case .unavailable: self = .notSetUp
        }
    }

    init?(_ availability: GPTLiveAvailability) {
        switch availability {
        case .available: return nil
        case .pluginMissing: self = .pluginMissing
        case .unavailable: self = .notSetUp
        }
    }

    init?(_ availability: GrokLiveAvailability) {
        switch availability {
        case .available: return nil
        case .pluginMissing: self = .pluginMissing
        case .unavailable: self = .notSetUp
        }
    }

    /// The host issue behind an availability check that threw, if it was one.
    init?(error: any Error) {
        switch error {
        case GeminiLiveTokenError.unavailable(let availability): self.init(availability)
        case GPTLiveClientError.unavailable(let availability): self.init(availability)
        case GrokLiveClientError.unavailable(let availability): self.init(availability)
        default: return nil
        }
    }
}

enum VoiceSetupIssue: Equatable {
    /// Conduit isn't connected to Hermes.
    case notConnected
    /// Classic Voice was never turned on for this profile on this device.
    case voiceOff
    /// iOS microphone access is denied for Conduit.
    case microphoneDenied
    /// iOS Speech Recognition is denied, and on-device transcription is chosen.
    case speechRecognitionDenied
    /// On-device transcription is chosen but doesn't support the language.
    case speechRecognitionUnsupported(locale: String)
    /// Hermes has no ready speech-to-text provider. `detail` is the gateway's
    /// own explanation when it gave one.
    case noSpeechToText(detail: String?)
    /// Hermes has no ready text-to-speech provider.
    case noTextToSpeech
    /// The Hermes host can't run this live voice mode.
    case liveModeNotSetUp(LiveVoiceModeName)
    /// The Hermes notifier plugin this live voice mode needs is missing.
    case notifierPluginMissing
    /// The user hasn't yet allowed this live voice mode's provider to hear
    /// them (#827). Only the phone asks.
    case providerConsentNeeded(LiveVoiceModeName)

    /// The phone's full message: what is wrong and where to fix it.
    var message: String {
        switch self {
        case .notConnected:
            return AppLocalization.string("Connect to Hermes before starting voice.")
        case .voiceOff:
            return AppLocalization.string("Voice is off for this profile. Turn on \"Enable voice on this device\" in Settings > Voice.")
        case .microphoneDenied:
            return VoiceAudioError.microphonePermissionDenied.localizedDescription
        case .speechRecognitionDenied:
            return AppLocalization.string("Allow Speech Recognition for Conduit in iPhone Settings > Conduit, or choose another speech-to-text option in Settings > Voice.")
        case .speechRecognitionUnsupported(let locale):
            return AppLocalization.string("On-device Apple speech recognition doesn't support \(locale). Choose another speech-to-text option in Settings > Voice.")
        case .noSpeechToText(let detail):
            if let detail, !detail.isEmpty { return detail }
            return AppLocalization.string("This Hermes profile has no ready speech-to-text provider. Set one up in Settings > Voice.")
        case .noTextToSpeech:
            return AppLocalization.string("This Hermes profile has no ready text-to-speech provider. Set one up in Settings > Voice.")
        case .liveModeNotSetUp(let mode):
            return AppLocalization.string("\(mode.displayName) isn't set up on your Hermes server. Settings > Voice shows what it needs.")
        case .notifierPluginMissing:
            return AppLocalization.string("Install or update the Hermes notifier plugin on your Hermes server.")
        case .providerConsentNeeded(let mode):
            return AppLocalization.string("\(mode.displayName) sends your voice to \(mode.company). Allow it in Conduit on your iPhone to start the call.")
        }
    }

    /// Short titles for the CarPlay screen, longest first; CarPlay shows the
    /// longest one that fits. Each names the fix, never failure internals.
    /// Translations keep the same order: longest first.
    var carPlayTitleVariants: [String] {
        switch self {
        case .notConnected:
            return [
                AppLocalization.string("Can't reach Hermes. Check your iPhone."),
                AppLocalization.string("Can't reach Hermes"),
            ]
        case .voiceOff:
            return [
                AppLocalization.string("Voice is off: Conduit Settings > Voice"),
                AppLocalization.string("Turn on Voice in Conduit"),
                AppLocalization.string("Voice is off"),
            ]
        case .microphoneDenied:
            return [
                AppLocalization.string("Allow the mic in iPhone Settings"),
                AppLocalization.string("Microphone not allowed"),
            ]
        case .speechRecognitionDenied:
            return [
                AppLocalization.string("Allow Speech Recognition for Conduit"),
                AppLocalization.string("Speech Recognition is off"),
            ]
        case .speechRecognitionUnsupported:
            return [
                AppLocalization.string("Change speech to text in Conduit"),
                AppLocalization.string("Speech to text unavailable"),
            ]
        case .noSpeechToText:
            return [
                AppLocalization.string("Set up speech to text in Conduit"),
                AppLocalization.string("No speech to text"),
            ]
        case .noTextToSpeech:
            return [
                AppLocalization.string("Set up assistant voice in Conduit"),
                AppLocalization.string("No assistant voice"),
            ]
        case .liveModeNotSetUp(let mode):
            return [
                AppLocalization.string("\(mode.displayName) isn't set up on Hermes"),
                AppLocalization.string("\(mode.displayName) not set up"),
            ]
        case .notifierPluginMissing:
            return [
                AppLocalization.string("Update the Hermes notifier plugin"),
                AppLocalization.string("Plugin update needed"),
            ]
        case .providerConsentNeeded(let mode):
            return [
                AppLocalization.string("Allow \(mode.displayName) on your iPhone"),
                AppLocalization.string("Allow on your iPhone"),
            ]
        }
    }

    /// Whether iOS has denied Conduit the microphone (not merely unasked).
    static var isMicrophoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }
}
