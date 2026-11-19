import Foundation

/// A bot's Conduit plugin (issue 2803). Hermes serves a profile's plugin
/// routes only once that profile turns the plugin on, and a bot New Bot makes
/// from a fresh profile (no Start From) hasn't, so its notifications, rooms,
/// Folder and cards answer "Plugin not found". Hermes' own plugin switches
/// reach only the dashboard's own profile, so the plugin does it for the bot
/// (`/profiles/plugin`, plugin 0.180.0+): it links the bot's profile to the
/// main install and runs Hermes' own `plugins enable` there. New Bot turns
/// it on for every bot it makes, and Edit Bot offers Turn On for one that
/// has it off (Eric, 2026-11-19).
enum BotPlugin {
    static let capability = "bot-plugin"
    /// Asked of the dashboard's own profile: no `?profile=`, as the bot's
    /// profile can't answer plugin requests until this has run.
    static let path = "/api/plugins/conduit_push/profiles/plugin"
    /// Turn On runs Hermes' enable on the host, which takes a few seconds and
    /// at most 90 there.
    static let turnOnTimeoutMilliseconds = 100_000

    struct State: Equatable {
        /// Hermes serves the plugin for the profile and its chats load it.
        var on: Bool
        /// The dashboard can turn it on there (it runs the main install).
        var canTurnOn: Bool

        init(on: Bool, canTurnOn: Bool) {
            self.on = on
            self.canTurnOn = canTurnOn
        }

        init(response: [String: Any]) {
            on = response["on"] as? Bool == true
            canTurnOn = response["can_turn_on"] as? Bool == true
        }

        /// Edit Bot shows Turn On only for a bot it can help.
        var offersTurnOn: Bool { !on && canTurnOn }
    }

    static func route(profile: String) -> String? {
        guard let name = DashboardPath.encodedQueryComponent(profile) else { return nil }
        return "\(path)?name=\(name)"
    }

    /// What New Bot does about the plugin once the bot exists.
    enum NewBotStep: Equatable {
        /// Ask, and turn it on if it's off.
        case turnOn
        /// The dashboard's plugin can't: a bot that starts fresh is told to
        /// update it, since nothing else will turn it on.
        case askForUpdate
        /// Nothing to do or say.
        case nothing
    }

    static func newBotStep(plugin: NotifierPluginStatus.State, startsFresh: Bool) -> NewBotStep {
        switch plugin {
        case .reported(_, let capabilities) where capabilities.contains(capability): return .turnOn
        case .reported: return startsFresh ? .askForUpdate : .nothing
        // Not reported yet, or a plugin too old to say (or none at all),
        // which Conduit already asks to update or install elsewhere.
        case .unknown, .predatesCapabilities: return .nothing
        }
    }
}

extension AppState {
    /// Whether this dashboard's plugin can tell and change a bot's plugin.
    var servesBotPlugin: Bool { notifierPlugin.reports(BotPlugin.capability) }

    /// The bot's plugin on this dashboard; nil when it can't be told (an
    /// older plugin, no connection, a failed read, the main profile).
    func botPluginState(profile: String) async -> BotPlugin.State? {
        guard servesBotPlugin, let bridge = dashboardTicketBridge,
              let path = BotPlugin.route(profile: profile) else { return nil }
        guard let response = try? await bridge.requestJSON(path: path, timeoutMilliseconds: 30_000) else { return nil }
        return BotPlugin.State(response: response)
    }

    /// Turns the plugin on for the bot. Nil once it's on; otherwise why not.
    func turnOnBotPlugin(profile: String) async -> String? {
        guard isConnected, let bridge = dashboardTicketBridge else {
            return AppLocalization.string("Connect to Hermes to manage bots.")
        }
        do {
            let response = try await bridge.requestJSON(
                path: BotPlugin.path,
                method: "POST",
                body: ["name": profile],
                timeoutMilliseconds: BotPlugin.turnOnTimeoutMilliseconds
            )
            return BotPlugin.State(response: response).on
                ? nil
                : AppLocalization.string("Hermes still has the plugin off for this bot. Try again.", table: .bots)
        } catch {
            return UserFacingError.message(for: error)
        }
    }

    /// New Bot's last step (issue 2803): the bot it made gets the plugin
    /// turned on, a clone that has it already included. A warning for the
    /// save's result, or nil.
    func turnOnPluginForNewBot(_ slug: String, startsFresh: Bool) async -> String? {
        switch BotPlugin.newBotStep(plugin: notifierPlugin.state, startsFresh: startsFresh) {
        case .nothing:
            return nil
        case .askForUpdate:
            return AppLocalization.string(
                "Conduit's features need the Conduit plugin turned on for this bot. Update the plugin, then turn it on in Edit Bot.",
                table: .bots
            )
        case .turnOn:
            if let state = await botPluginState(profile: slug), state.on || !state.canTurnOn { return nil }
            guard let failure = await turnOnBotPlugin(profile: slug) else { return nil }
            return AppLocalization.string(
                "The Conduit plugin wasn't turned on for this bot: \(failure) Edit the bot to try again.",
                table: .bots
            )
        }
    }
}
