//
//  VoiceSetupDefaults.swift
//  Conduit
//
//  The one-switch happy path for classic Voice. Turning Voice on picks
//  defaults that work on any Hermes host without installing anything:
//  speech to text on this iPhone (Apple's on-device model) and Edge TTS for
//  the assistant's voice (Hermes' own default, no key needed). A reviewer
//  whose Voice was never set up read CarPlay's "Voice unavailable" as
//  CarPlay not working; with these defaults the switch alone is enough.
//

import Foundation

enum VoiceSetupDefaults {
    /// Hermes' provider id for Microsoft Edge TTS.
    static let edgeTTSProviderID = "edge"

    struct Plan: Equatable {
        /// Choose "On this iPhone" for speech to text.
        var usesOnDeviceTranscription = false
        /// Switch the profile's assistant voice to Edge TTS.
        var switchesSpeechToEdge = false
    }

    /// What turning Voice on should change. Only fills in what is missing:
    /// a speech-to-text choice the user already made is kept, and the
    /// assistant voice changes only when the current one isn't ready and
    /// Edge TTS is.
    static func plan(
        transcriptionModeChosen: Bool,
        appleSpeechAvailability: AppleSpeechRecognitionAvailability,
        snapshot: VoiceConfigurationSnapshot
    ) -> Plan {
        Plan(
            usesOnDeviceTranscription: !transcriptionModeChosen && appleSpeechAvailability.canAttemptRecognition,
            switchesSpeechToEdge: canSwitchSpeechToEdge(snapshot)
        )
    }

    /// Whether Edge TTS would fix an assistant voice that isn't ready.
    static func canSwitchSpeechToEdge(_ snapshot: VoiceConfigurationSnapshot) -> Bool {
        guard snapshot.capability.isGatewayConnected,
              !snapshot.capability.supportsSpeech,
              snapshot.selectedTTSProvider != edgeTTSProviderID else { return false }
        return providerReadiness(edgeTTSProviderID, in: snapshot.ttsProviders) == .ready
    }

    enum Readiness: Equatable {
        case ready
        /// Hermes reported a status other than ready ("needs_keys"…).
        case notReady(status: String)
        /// Hermes reported nothing for this provider.
        case unknown
    }

    /// Hermes' own readiness report for one provider, whether or not it is
    /// the selected one.
    static func providerReadiness(_ id: String, in providers: [VoiceProviderConfiguration]) -> Readiness {
        guard let readiness = providers.first(where: { $0.descriptor.id == id })?.readiness else { return .unknown }
        if readiness.status.caseInsensitiveCompare("ready") == .orderedSame { return .ready }
        return .notReady(status: readiness.status)
    }
}
