//
//  LinkAsks.swift
//  Conduit
//
//  Asks between linked agents (designs/cross-owner-agents, C7): what each
//  linked person's Hermes may ask yours, set for each Link in Settings >
//  People. The plugin answers by these rules (link_asks.py, notifier
//  0.120): whether you're free on a date, from the calendar your phone
//  shares with the profile the rules name, and a question, which only you
//  answer. Never a model reading their words. What waits for you comes as a
//  confirmation on the present panel (PresentedLink).
//

import Foundation

/// What a linked person's Hermes may ask yours, as the plugin keeps it.
struct LinkAskRules: Equatable {
    /// Free on a date: `yes_no` (say free or busy without asking), `times`
    /// (also the busy times then), `ask` (the default: you see the answer
    /// and Share it or not) or `off`.
    var freeOn: String
    /// A question: `ask` (the default) or `off`.
    var questions: String
    /// The profile whose calendar and phone answer.
    var profile: String

    static let freeOnChoices = ["yes_no", "times", "ask", "off"]
    static let questionChoices = ["ask", "off"]
}

/// A Link and its rules: the defaults where none were set.
struct LinkAskRulesEntry: Identifiable, Equatable {
    let id: String
    let name: String
    /// The Link's status, as RoomLink has it.
    let status: String
    var rules: LinkAskRules
}

/// The plugin's link rules routes. They take no profile: Links are the
/// installation's, and each Link's rules name the profile that answers.
struct LinkAsksClient {
    static let capability = "link-asks"
    static let path = "/api/plugins/conduit_push/links/rules"

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    func rules() async throws -> [LinkAskRulesEntry] {
        try Self.parseList(try await request(Self.path, "GET", nil))
    }

    /// Changes only what `changes` names (`free_on`, `questions`,
    /// `profile`); the plugin answers with all of the Link's rules.
    func set(_ changes: [String: String], linkID: String) async throws -> LinkAskRules {
        var body: [String: Any] = changes
        body["link_id"] = linkID
        return try Self.parseChange(try await request(Self.path, "PUT", body), linkID: linkID)
    }

    /// A Link the page can't show is left out rather than refusing the list.
    static func parseList(_ response: [String: Any]) throws -> [LinkAskRulesEntry] {
        guard response["ok"] as? Bool == true, let links = response["links"] as? [[String: Any]] else {
            throw HermesError.invalidResponse
        }
        return links.compactMap { link in
            guard let id = link["id"] as? String, !id.isEmpty,
                  let name = link["name"] as? String,
                  let status = link["status"] as? String,
                  let rules = rules(link["rules"]) else { return nil }
            return LinkAskRulesEntry(id: id, name: name, status: status, rules: rules)
        }
    }

    /// Another Link's answer is never shown as this one's.
    static func parseChange(_ response: [String: Any], linkID: String) throws -> LinkAskRules {
        guard response["ok"] as? Bool == true, response["id"] as? String == linkID,
              let rules = rules(response["rules"]) else { throw HermesError.invalidResponse }
        return rules
    }

    static func rules(_ value: Any?) -> LinkAskRules? {
        guard let rules = value as? [String: Any],
              let freeOn = rules["free_on"] as? String,
              let questions = rules["questions"] as? String,
              let profile = rules["profile"] as? String, !profile.isEmpty else { return nil }
        return LinkAskRules(freeOn: freeOn, questions: questions, profile: profile)
    }
}

/// What Settings > People says about a Link's asks.
enum LinkAskText {
    static func freeOnTitle(_ choice: String) -> String {
        switch choice {
        case "yes_no": return AppLocalization.string("Say if you're free")
        case "times": return AppLocalization.string("Say when you're busy")
        case "ask": return AppLocalization.string("Ask me first")
        case "off": return AppLocalization.string("Don't answer")
        default: return choice
        }
    }

    static func questionsTitle(_ choice: String) -> String {
        switch choice {
        case "ask": return AppLocalization.string("Ask me")
        case "off": return AppLocalization.string("Don't answer")
        default: return choice
        }
    }

    /// What the rules do, under the choices.
    static func caption(_ rules: LinkAskRules, name: String, profileName: String) -> String {
        let freeOn: String
        switch rules.freeOn {
        case "yes_no":
            freeOn = AppLocalization.string("Asked whether you're free on a date, your Hermes says free or busy from the calendar your phone shares with \(profileName), without asking you.")
        case "times":
            freeOn = AppLocalization.string("Asked whether you're free on a date, your Hermes says so from the calendar your phone shares with \(profileName), and when you're busy then (the times only), without asking you.")
        case "off":
            freeOn = AppLocalization.string("Your Hermes doesn't say whether you're free.")
        default:
            freeOn = AppLocalization.string("Asked whether you're free on a date, you see what your Hermes would answer from the calendar your phone shares with \(profileName), and Share it, say something else, or don't.")
        }
        let questions = rules.questions == "off"
            ? AppLocalization.string("Your Hermes turns \(name)'s questions away.")
            : AppLocalization.string("Questions from \(name)'s Hermes wait for you: only you answer them, never an agent.")
        return "\(freeOn) \(questions)"
    }
}

extension AppState {
    /// Whether the host's plugin answers asks between linked agents.
    var canSetLinkAsks: Bool {
        notifierPlugin.reports(LinkAsksClient.capability)
    }

    /// Requests stay with the dashboard they were made for.
    var linkAsksClient: LinkAsksClient {
        let dashboard = activeDashboardID
        return LinkAsksClient(dashboardID: dashboard) { [weak self] path, method, body in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: nil)
        }
    }
}
