//
//  StartVoiceConversationIntent.swift
//  Conduit
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct ConduitProfileEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conduit profile")
    static let defaultQuery = ConduitProfileEntityQuery()

    let id: String
    let displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)")
    }
}

@available(iOS 16.0, *)
struct ConduitProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ConduitProfileEntity] {
        profiles().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ConduitProfileEntity] { profiles() }

    private func profiles() -> [ConduitProfileEntity] {
        let values = UserDefaults.standard.stringArray(forKey: "conduit.knownProfiles.v1") ?? ["default"]
        let unique = values.reduce(into: [String]()) { result, value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, !result.contains(normalized) { result.append(normalized) }
        }
        // Named as in Conduit, renames included (AppState keeps the map).
        let names = UserDefaults.standard.dictionary(forKey: "conduit.knownProfileNames.v1") as? [String: String] ?? [:]
        return (unique.isEmpty ? ["default"] : unique).map {
            ConduitProfileEntity(id: $0, displayName: names[$0] ?? ($0 == "default" ? AppLocalization.string("Default") : $0))
        }
    }
}

/// Siri deliberately launches Conduit before a microphone is opened. The root
/// scene consumes this pending request once Hermes is ready — or fails it so
/// a stale Siri launch cannot open Voice much later.
///
/// Foreground-first: `perform()` only records the request. It never opens the
/// microphone or a full voice conversation inside the App Intent context.
@available(iOS 16.0, *)
struct StartVoiceConversationIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Conduit"
    static let description = IntentDescription("Open Conduit and start a voice conversation.")

    /// iOS 26+ deprecates `openAppWhenRun` in favor of `supportedModes`. This
    /// redeclaration stays only for iOS 17–25 (the project's deployment
    /// floor) and is marked deprecated at the same OS boundary so current-SDK
    /// builds do not emit a normal deprecation warning. On iOS 26+,
    /// `supportedModes` is the modern declaration; both express the same
    /// foreground-first contract.
    ///
    /// The value must be a boolean literal: the App Intents metadata
    /// processor rejects computed/unknown values for this property.
    @available(iOS, deprecated: 26.0, message: "Use supportedModes on iOS 26+; retained for iOS 17–25.")
    static let openAppWhenRun: Bool = true

    /// Bring Conduit to the foreground before the pending voice launch is
    /// consumed. Never background-only: microphone capture and the voice
    /// conversation belong to the foreground app scene.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @Parameter(title: "Profile") var profile: ConduitProfileEntity?

    init() {}

    init(profile: ConduitProfileEntity?) { self.profile = profile }

    func perform() async throws -> some IntentResult {
        let pending = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: profile?.id)
        await MainActor.run {
            PendingVoiceIntentStore.shared.enqueue(pending)
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct ConduitVoiceShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceConversationIntent(),
            // "Talk to …" alone reads to Siri as a phone call to a contact,
            // so the first (suggested) phrases avoid it.
            phrases: [
                "Start \(.applicationName) voice",
                "Start voice in \(.applicationName)",
                "Voice chat in \(.applicationName)",
                "Start a voice conversation in \(.applicationName)",
                "\(.applicationName) voice",
                "Talk to \(.applicationName)",
                // Profile phrases ("Start Fam voice in Conduit"). Siri can
                // only match profiles it has been told about, so AppState
                // calls updateAppShortcutParameters() when the list changes.
                "Start \(\.$profile) voice in \(.applicationName)",
                "\(.applicationName) voice with \(\.$profile)"
            ],
            shortTitle: "Talk to Conduit",
            systemImageName: "mic.fill"
        )
        // Siri asks what to send, and speaks Hermes's answer.
        AppShortcut(
            intent: SendToHermesIntent(),
            phrases: [
                "Ask Hermes in \(.applicationName)",
                "Send to Hermes in \(.applicationName)"
            ],
            shortTitle: "Ask Hermes",
            systemImageName: "paperplane.fill"
        )
    }
}

/// Tells Siri the profile list changed. Lives here so callers need not
/// import AppIntents for the provider's static method.
enum SiriProfileShortcuts {
    static func refresh() {
        ConduitVoiceShortcuts.updateAppShortcutParameters()
    }
}
