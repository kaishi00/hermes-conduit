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

    /// Another combined dashboard's profile has an id of its own, the
    /// profile and that dashboard's id ("atlas@<uuid>"), so "Start Atlas
    /// voice" reaches it from the dashboard on screen. A bare id is the
    /// dashboard in use's profile, as every saved shortcut's is.
    static func farID(profile: String, dashboardID: UUID) -> String {
        "\(profile)@\(dashboardID.uuidString)"
    }

    /// The profile an id names, and the other combined dashboard it's on
    /// (nil: the dashboard in use). A profile name holding an "@" not
    /// followed by a dashboard id is bare.
    static func parts(of id: String) -> (profile: String, dashboardID: UUID?) {
        guard let at = id.lastIndex(of: "@"),
              let dashboardID = UUID(uuidString: String(id[id.index(after: at)...])) else { return (id, nil) }
        let profile = String(id[..<at])
        return profile.isEmpty ? (id, nil) : (profile, dashboardID)
    }

    /// The list AppState keeps of the other combined dashboards' profiles,
    /// each `[farIDKey: id, farNameKey: name]`.
    static let combinedProfilesKey = "conduit.combinedProfiles.v1"
    static let farIDKey = "id"
    static let farNameKey = "name"
}

@available(iOS 16.0, *)
struct ConduitProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ConduitProfileEntity] {
        (Self.localProfiles() + Self.combinedProfiles()).filter { identifiers.contains($0.id) }
    }

    /// The dashboard in use's profiles, then the other combined
    /// dashboards' ("Atlas · Studio"), so Siri's profile phrases reach
    /// every one (no-switch plan stage 2).
    func suggestedEntities() async throws -> [ConduitProfileEntity] { Self.localProfiles() + Self.combinedProfiles() }

    /// The other combined dashboards' profiles, as AppState last listed
    /// them; none outside a group.
    static func combinedProfiles(_ defaults: UserDefaults = .standard) -> [ConduitProfileEntity] {
        let rows = defaults.array(forKey: ConduitProfileEntity.combinedProfilesKey) as? [[String: String]] ?? []
        return rows.compactMap { row in
            guard let id = row[ConduitProfileEntity.farIDKey],
                  ConduitProfileEntity.parts(of: id).dashboardID != nil else { return nil }
            return ConduitProfileEntity(id: id, displayName: row[ConduitProfileEntity.farNameKey] ?? ConduitProfileEntity.parts(of: id).profile)
        }
    }

    /// The dashboard in use's profiles, named as in Conduit.
    static func localProfiles() -> [ConduitProfileEntity] {
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

/// The dashboard in use's profiles only: Send to Hermes sends on the
/// dashboard in use, so another combined dashboard's isn't offered there.
@available(iOS 16.0, *)
struct ConduitLocalProfileOptions: DynamicOptionsProvider {
    func results() async throws -> [ConduitProfileEntity] { ConduitProfileEntityQuery.localProfiles() }
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
        // Another combined dashboard's profile carries its dashboard: its
        // call starts there in place, or switches there.
        let parts = profile.map { ConduitProfileEntity.parts(of: $0.id) }
        let pending = PendingVoiceLaunchPolicy.makeSiriPendingIntent(profile: parts?.profile, dashboardID: parts?.dashboardID)
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
                "Send to Hermes in \(.applicationName)",
                // A chat by name ("Ask Trip planning in Conduit"), a Bot
                // Chat by its bot's ("Ask Furina in Conduit"). Siri knows
                // the widget's chats: ConduitChatSpotlight refreshes them.
                "Ask \(\.$chat) in \(.applicationName)",
                "Message \(\.$chat) in \(.applicationName)"
            ],
            shortTitle: "Ask Hermes",
            systemImageName: "paperplane.fill"
        )
        // Opens on a new chat with the keyboard up: the Action Button's
        // "just let me type" (issue 2860).
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start a new chat in \(.applicationName)",
                "New \(.applicationName) chat",
                "New \(\.$profile) chat in \(.applicationName)"
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenConduitChatIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Show \(\.$target) in \(.applicationName)",
                "Open a chat in \(.applicationName)"
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right"
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
