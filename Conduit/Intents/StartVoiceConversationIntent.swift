//
//  StartVoiceConversationIntent.swift
//  Conduit
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct ConduitProfileEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conduit profile")
    static var defaultQuery = ConduitProfileEntityQuery()

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
        return (unique.isEmpty ? ["default"] : unique).map {
            ConduitProfileEntity(id: $0, displayName: $0 == "default" ? "Default" : $0)
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
    static var title: LocalizedStringResource = "Talk to Conduit"
    static var description = IntentDescription("Open Conduit and start a voice conversation.")

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
    static var openAppWhenRun: Bool = true

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
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceConversationIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start a voice conversation in \(.applicationName)"
            ],
            shortTitle: "Talk to Conduit",
            systemImageName: "mic.fill"
        )
    }
}
