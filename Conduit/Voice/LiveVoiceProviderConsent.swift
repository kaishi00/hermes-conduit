//
//  LiveVoiceProviderConsent.swift
//  Conduit
//
//  The user's OK for a live voice mode to send their voice to the company
//  that runs it (#827, App Review 5.1.2(i)). Gemini Live, GPT-Live and Grok
//  Live send microphone audio, the transcript and what Hermes adds to
//  Google, OpenAI or xAI, so each asks once before its first call. Local
//  Live stays with the user's own Hermes host and never asks.
//

import Foundation

enum LiveVoiceProviderConsent {
    /// Posted when a mode's consent is given or withdrawn.
    static let didChange = Notification.Name("conduit.liveVoiceProviderConsent.didChange")

    /// Whether the mode sends the call to a third party at all.
    static func isRequired(for mode: LiveVoiceModeName) -> Bool {
        mode != .localLive
    }

    /// Kept per provider on this device, so switching to another mode asks
    /// again. Not per Hermes profile: the consent is the person's.
    static func key(for mode: LiveVoiceModeName) -> String {
        "conduit.liveVoiceProviderConsent.\(mode.storageID)"
    }

    static func isGranted(_ mode: LiveVoiceModeName, defaults: UserDefaults = .standard) -> Bool {
        !isRequired(for: mode) || defaults.bool(forKey: key(for: mode))
    }

    /// The mode itself while it still needs the user's OK, nil once it may
    /// connect: what a live controller checks before each call.
    static func missing(_ mode: LiveVoiceModeName, defaults: UserDefaults = .standard) -> LiveVoiceModeName? {
        isGranted(mode, defaults: defaults) ? nil : mode
    }

    static func setGranted(_ granted: Bool, for mode: LiveVoiceModeName, defaults: UserDefaults = .standard) {
        guard isRequired(for: mode) else { return }
        if granted {
            defaults.set(true, forKey: key(for: mode))
        } else {
            defaults.removeObject(forKey: key(for: mode))
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

extension LiveVoiceModeName: Identifiable {
    var id: String { storageID }
}
