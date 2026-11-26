import Foundation

/// What one of a bot's running chats is doing now, as the plugin notes it
/// (GET /live-steps, plugin 0.200+): its phase and, for a tool, the tool's
/// category, the same coarse one the Lock Screen shows. Bots Home says it
/// on the portrait in place of "Replying" (Eric, 2026-11-26), for every
/// chat, not only the ones this phone follows.
struct BotLiveStep: Equatable {
    enum Phase: String {
        case thinking, tool, approval, input
    }

    static let capability = "live-steps"
    static let path = "/api/plugins/conduit_push/live-steps"

    let phase: Phase
    let tool: HermesToolCategory?
    /// When the step began (Unix seconds), so a bot's newest step wins.
    let since: Double

    /// The Lock Screen's words for it (Localizable.xcstrings).
    var titleKey: String {
        switch phase {
        case .thinking: "Thinking"
        case .approval: "Waiting for your approval"
        case .input: "Waiting for your answer"
        case .tool: HermesTurnCopy.toolKey(tool ?? .tool)
        }
    }

    var title: String { AppLocalization.string(String.LocalizationValue(titleKey)) }

    /// A GET /live-steps answer's steps by session id; nil when it has none
    /// (an error body, or a plugin without the route).
    static func steps(listed: Any) -> [String: BotLiveStep]? {
        guard let body = listed as? [String: Any], let raw = body["steps"] as? [String: Any] else { return nil }
        var steps: [String: BotLiveStep] = [:]
        for (id, value) in raw {
            guard !id.isEmpty, let entry = value as? [String: Any],
                  let phase = (entry["phase"] as? String).flatMap(Phase.init(rawValue:)) else { continue }
            let tool: HermesToolCategory? = phase == .tool ? (entry["tool"] as? String).map { HermesToolCategory(rawValue: $0) ?? .tool } ?? .tool : nil
            steps[id] = BotLiveStep(phase: phase, tool: tool, since: (entry["since"] as? NSNumber)?.doubleValue ?? 0)
        }
        return steps
    }

    /// The newest step among the chats whose ids are given (each chat by
    /// every id it goes by), or nil.
    static func newest(in steps: [String: BotLiveStep], chats: [Set<String>]) -> BotLiveStep? {
        chats.compactMap { ids in ids.compactMap { steps[$0] }.max { $0.since < $1.since } }
            .max { $0.since < $1.since }
    }
}
