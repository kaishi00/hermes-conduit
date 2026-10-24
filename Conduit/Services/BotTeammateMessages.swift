import Foundation

/// Bot-to-bot messages in a chat, read the way upstream Desktop reads them
/// (`thread/user-message.tsx` `AGENT_MESSAGE_RE` and `thread/agent-delivery.tsx`,
/// pinned upstream SHA fdec926e). A teammate's delivery arrives as a user
/// turn signed "Message from 🤖 Atlas (@atlas): …", and the sender's side is
/// a `message_agent` call or the terminal `hermes -p atlas chat … -q
/// "Message from …"` run. Neither is something the user typed or ran, so the
/// chat shows them as "Message from Atlas" and "Messaged Atlas".
enum BotTeammateMessages {
    struct Inbound: Equatable {
        /// The name the sender signed with.
        let sender: String
        /// Its `@handle`, else the signed name.
        let handle: String
        /// What it said, without the signature.
        let body: String
    }

    /// Past this a user turn isn't scanned: a teammate's message is a chat
    /// message, and rows render on the main thread.
    static let scanLimit = 65_536

    /// The teammate delivery `text` is, or nil for anything the user wrote.
    /// Desktop also takes an unsigned "Message from Name: …"; Conduit wants
    /// the bot signature (🤖 or an `@handle`) or the bracket form, so a
    /// forwarded "Message from Mom: …" stays the user's own text.
    static func inbound(_ text: String) -> Inbound? {
        guard text.utf8.count <= scanLimit else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Message from ") || trimmed.hasPrefix("[Message from agent '"),
              let regex = inboundRegex,
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: trimmed).map { String(trimmed[$0]) }
        }
        let robot = group(1) != nil
        let signedName = group(2)?.trimmingCharacters(in: .whitespaces)
        let signedHandle = group(3)
        let bracketName = group(4)?.trimmingCharacters(in: .whitespaces)
        guard bracketName != nil || robot || signedHandle != nil else { return nil }
        guard let sender = (signedName ?? bracketName).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        return Inbound(
            sender: sender,
            handle: signedHandle ?? bracketName ?? sender,
            body: (group(5) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// The teammate a finished or running tool call messaged, as the
    /// routing key ("atlas"), or nil when the call isn't a delivery.
    static func deliveryTarget(toolName: String, input: String?) -> String? {
        guard let input, input.utf8.count <= scanLimit else { return nil }
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "message_agent":
            let key = agentKey(jsonObject(input)?["target"] as? String ?? "")
            return key.isEmpty ? nil : key
        case "terminal":
            let command = jsonObject(input)?["command"] as? String ?? input
            guard command.range(of: "Message from", options: .caseInsensitive) != nil,
                  let regex = deliveryCommandRegex,
                  let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                  let range = Range(match.range(at: 2), in: command) else { return nil }
            return command[range].lowercased()
        default:
            return nil
        }
    }

    /// The roster bot a signed handle or routing key names: its profile
    /// name, its `@` handle, or a mention form of its title only one bot
    /// claims. Nil leaves the row with the name as written.
    static func bot(named key: String, in roster: [BotProfile]) -> BotProfile? {
        let wanted = agentKey(key)
        guard !wanted.isEmpty else { return nil }
        if let exact = roster.first(where: { BotMentions.handle(for: $0).lowercased() == wanted }) {
            return exact
        }
        let claimed = roster.filter { BotMentions.resolvableForms(of: $0).contains(wanted) }
        return claimed.count == 1 ? claimed[0] : nil
    }

    /// What the chat calls the teammate: its roster name, else the key as
    /// written.
    static func displayName(for key: String, in roster: [BotProfile]) -> String {
        bot(named: key, in: roster)?.displayLabel ?? key
    }

    /// `@Dr. Foo`, `scribe@laptop`, `peer/scribe` → `dr. foo`, `scribe`:
    /// the routing alias a `message_agent` target and a signature share
    /// (upstream `agentKey`).
    static func agentKey(_ value: String) -> String {
        var key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.hasPrefix("@") { key.removeFirst() }
        if let at = key.lastIndex(of: "@") { key = String(key[..<at]) }
        if let slash = key.lastIndex(of: "/") { key = String(key[key.index(after: slash)...]) }
        return key.lowercased()
    }

    // Groups: 1 the robot, 2 the signed name, 3 the handle, 4 the bracket
    // form's name, 5 the message.
    private static let inboundRegex = try? NSRegularExpression(
        pattern: #"^(?:Message from (🤖\s*)?([^:\n(]{1,64}?)(?:\s*\(@([a-z0-9][a-z0-9_-]{0,63})(?:@[a-zA-Z0-9][a-zA-Z0-9_-]{0,63})?\))?:\s*|\[Message from agent '([^']{1,64})'\]\s*)([\s\S]*)$"#
    )

    private static let deliveryCommandRegex = try? NSRegularExpression(
        pattern: #"(?:^|[;&|]\s*|\bhermes\s+)(?:-p|--profile)(?:\s+|=)(["']?)([a-z0-9][a-z0-9_-]{0,63})\1\s+chat\b[\s\S]*?-q\s+["']Message from"#,
        options: [.caseInsensitive]
    )

    private static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
