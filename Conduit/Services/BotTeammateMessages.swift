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

    /// Past this a tool call or result isn't scanned: rows render on the
    /// main thread.
    static let scanLimit = 65_536

    /// How much of a user turn the signature is read from: the longest
    /// signature ("Message from 🤖 " + a 64-character name, handle and
    /// machine) fits. The rest is the message, however long.
    static let signatureScanLength = 320

    /// The teammate delivery `text` is, or nil for anything the user wrote.
    /// Desktop also takes an unsigned "Message from Name: …"; Conduit wants
    /// the bot signature (🤖 or an `@handle`) or the bracket form, so a
    /// forwarded "Message from Mom: …" stays the user's own text.
    static func inbound(_ text: String) -> Inbound? {
        let start = text.firstIndex(where: { !$0.isWhitespace }) ?? text.endIndex
        let rest = text[start...]
        guard rest.hasPrefix("Message from ") || rest.hasPrefix("[Message from agent '"),
              let regex = inboundRegex else { return nil }
        let head = String(rest.prefix(signatureScanLength))
        guard let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: head).map { String(head[$0]) }
        }
        let robot = group(1) != nil
        let signedName = group(2)?.trimmingCharacters(in: .whitespaces)
        let signedHandle = group(3)
        let bracketName = group(4)?.trimmingCharacters(in: .whitespaces)
        guard bracketName != nil || robot || signedHandle != nil else { return nil }
        guard let sender = (signedName ?? bracketName).flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        // The message runs on past the scanned head.
        var body = ""
        if let bodyRange = Range(match.range(at: 5), in: head) {
            let offset = head.distance(from: head.startIndex, to: bodyRange.lowerBound)
            body = String(rest[rest.index(rest.startIndex, offsetBy: offset)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Inbound(sender: sender, handle: signedHandle ?? bracketName ?? sender, body: body)
    }

    /// The teammate a finished or running tool call messaged, as the
    /// routing key ("atlas"), or nil when the call isn't a delivery.
    static func deliveryTarget(toolName: String, input: String?) -> String? {
        delivery(toolName: toolName, input: input, output: nil)?.target
    }

    /// A tool call that messaged a teammate.
    struct Delivery: Equatable {
        /// The routing key ("atlas").
        let target: String
        /// What was sent, without the sender's signature.
        let message: String?
        /// A terminal run's answer from the teammate (`chat -Q` prints it).
        let reply: String?
    }

    /// The delivery a `message_agent` call or a terminal `hermes -p name
    /// chat … -q "Message from …"` run made, or nil. `terminal` and
    /// `process` both run commands, as in the Live Activity's categories.
    static func delivery(toolName: String, input: String?, output: String?) -> Delivery? {
        guard let input, input.utf8.count <= scanLimit else { return nil }
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "message_agent":
            let object = jsonObject(input)
            let key = agentKey(object?["target"] as? String ?? "")
            guard !key.isEmpty else { return nil }
            let message = (object?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Delivery(target: key, message: message?.isEmpty == false ? message : nil, reply: nil)
        case "terminal", "process":
            let command = jsonObject(input)?["command"] as? String ?? input
            guard command.range(of: "Message from", options: .caseInsensitive) != nil,
                  let regex = deliveryCommandRegex,
                  let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
                  let range = Range(match.range(at: 2), in: command) else { return nil }
            var message: String?
            if let payload = Range(match.range(at: 4), in: command) {
                let sent = unescaped(String(command[payload]))
                message = inbound(sent)?.body ?? sent
            }
            return Delivery(
                target: command[range].lowercased(),
                message: message?.isEmpty == false ? message : nil,
                reply: output.flatMap { replyText(fromOutput: $0) }
            )
        default:
            return nil
        }
    }

    /// The teammate's answer in a terminal delivery's output (upstream
    /// `replyTextFromResult`): the `output` of a JSON result, without the
    /// `session_id:` lines, and without a signature the teammate echoed.
    static func replyText(fromOutput output: String) -> String? {
        guard output.utf8.count <= scanLimit else { return nil }
        var raw = output
        if let object = jsonObject(raw), let text = object["output"] as? String { raw = text }
        let reply = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("session_id:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = inbound(reply)?.body ?? reply
        return body.isEmpty ? nil : body
    }

    /// A shell-quoted payload's `\"` and `\'` as plain quotes.
    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\'", with: "'")
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
        // A signature without a handle carries the bot's title ("Trip Scout").
        let claimed = roster.filter {
            BotMentions.resolvableForms(of: $0).contains(wanted)
                || $0.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
        return claimed.count == 1 ? claimed[0] : nil
    }

    /// What the chat calls the teammate: its roster name, else the key as
    /// written.
    static func displayName(for key: String, in roster: [BotProfile]) -> String {
        bot(named: key, in: roster)?.displayLabel ?? key
    }

    /// The bot's replies to a teammate's delivery, by message id, with the
    /// teammate's name: Desktop folds these under "Replied to Atlas", since
    /// they answer the teammate, not the user. Not a reply this bot asked
    /// for: when it messaged that teammate first, the delivery is the
    /// teammate's answer and what follows is the report to the user
    /// (upstream `dispatchedTo`, #114629). A reply still streaming stays open.
    static func teammateReplies(
        in messages: [ChatMessage],
        streamingMessageID: String? = nil
    ) -> [String: String] {
        var replies: [String: String] = [:]
        // The delivery the current run of rows answers, and its sender.
        var answering: String?
        for (index, message) in messages.enumerated() {
            switch message.role {
            case .user:
                answering = nil
                guard let inbound = inbound(message.content) else { continue }
                if !dispatched(in: messages[..<index], to: [inbound.handle, inbound.sender]) {
                    answering = inbound.sender
                }
            case .assistant:
                if let sender = answering, message.id != streamingMessageID {
                    replies[message.id] = sender
                }
            default:
                continue
            }
        }
        return replies
    }

    /// The reply the running turn is writing: the last assistant row after
    /// the user last wrote (a steer joins the turn). Nil before it has one,
    /// so an earlier turn's folded reply stays folded meanwhile.
    static func runningReplyID(in messages: [ChatMessage]) -> String? {
        for message in messages.reversed() {
            if message.role == .user && !message.isSteer { return nil }
            if message.role == .assistant { return message.id }
        }
        return nil
    }

    /// Whether this bot messaged one of `keys` since the last thing the
    /// user said (or that teammate's last delivery).
    private static func dispatched(in earlier: ArraySlice<ChatMessage>, to keys: [String]) -> Bool {
        let wanted = Set(keys.map(agentKey).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return false }
        for message in earlier.reversed() {
            switch message.role {
            case .user:
                guard let inbound = inbound(message.content),
                      !wanted.contains(agentKey(inbound.handle)),
                      !wanted.contains(agentKey(inbound.sender)) else { return false }
            case .tool:
                if let tool = message.tool,
                   let target = deliveryTarget(toolName: tool.name, input: tool.input),
                   wanted.contains(target) {
                    return true
                }
            default:
                continue
            }
        }
        return false
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
        pattern: #"^(?:Message from (🤖\s*)?([^:\n]{1,64}?)(?:\s*\(@([a-z0-9][a-z0-9_-]{0,63})(?:@[a-zA-Z0-9][a-zA-Z0-9_-]{0,63})?\))?:\s*|\[Message from agent '([^']{1,64})'\]\s*)([\s\S]*)$"#,
        options: [.caseInsensitive]
    )

    private static let deliveryCommandRegex = try? NSRegularExpression(
        // Groups: 2 the profile, 4 the quoted `-q` message (3 its quote).
        pattern: #"(?:^|[;&|]\s*|\bhermes\s+)(?:-p|--profile)(?:\s+|=)(["']?)([a-z0-9][a-z0-9_-]{0,63})\1\s+chat\b[\s\S]*?-q\s+(["'])((?=Message from)(?:\\.|(?!\3)[^\\])*)\3?"#,
        options: [.caseInsensitive]
    )

    private static func jsonObject(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
