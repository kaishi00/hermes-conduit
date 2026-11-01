import Foundation

/// A bot's work as its Bot Chat coordinates it (Bot workstreams, the
/// notifier's `bot-workstreams` branch): the workstreams it started, hidden
/// chats of its own named W1, W2, and its asks to other bots and theirs to
/// it (A1, A2). The plugin's `/workstreams` route lists them; the user's own
/// actions on a workstream (Reply, Stop, Continue, Check first) go straight
/// to it there, with no Bot Chat turn.
struct BotWorkItem: Identifiable, Equatable {
    enum Kind: String {
        case workstream
        case askOut = "ask_out"
        case askIn = "ask_in"
    }

    /// What the user can do with the work now, as the plugin says.
    enum Action: String, CaseIterable {
        case send, stop, `continue`, check
    }

    /// A line of the workstream's own checklist (`work_progress`).
    struct Step: Equatable, Identifiable {
        enum State: String {
            case done, doing, todo
        }

        let index: Int
        let text: String
        let state: State
        var id: Int { index }
    }

    let ref: String
    let kind: Kind
    let status: String
    let title: String
    let goal: String
    /// The workstream's own chat, by its stored id. Empty for an ask.
    let sessionID: String
    let result: String
    let error: String
    /// The tool step it's on while it works ("terminal: command: make").
    let step: String
    /// The other bot of an ask: the one it waits on, or the one asking.
    let otherBot: String
    let checklist: [Step]
    let updatedAt: Date
    let isClosed: Bool
    /// A restart cut it off during a step that can change things, so it may
    /// or may not have taken effect: Check first is offered.
    let isUncertain: Bool
    let actions: [Action]

    var id: String { ref }

    init?(row: [String: Any]) {
        guard let ref = row["ref"] as? String, !ref.isEmpty,
              let kind = Kind(rawValue: row["kind"] as? String ?? "") else { return nil }
        self.ref = ref
        self.kind = kind
        status = row["status"] as? String ?? ""
        title = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        goal = row["goal"] as? String ?? ""
        sessionID = (row["session_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        result = row["result"] as? String ?? ""
        error = row["error"] as? String ?? ""
        step = row["step"] as? String ?? ""
        otherBot = row["bot"] as? String ?? ""
        let rows = row["checklist"] as? [[String: Any]] ?? []
        checklist = rows.enumerated().compactMap { index, line in
            guard let text = line["step"] as? String, !text.isEmpty else { return nil }
            return Step(index: index, text: text, state: Step.State(rawValue: line["state"] as? String ?? "") ?? .todo)
        }
        updatedAt = Date(timeIntervalSince1970: (row["updated_at"] as? NSNumber)?.doubleValue ?? 0)
        isClosed = row["closed"] as? Bool ?? false
        isUncertain = row["uncertain"] as? Bool ?? false
        actions = (row["actions"] as? [String] ?? []).compactMap(Action.init(rawValue:))
    }

    /// Still the bot's or the user's to finish: a restart's cut-off waits
    /// on the user, so it stays with the active work.
    var isActive: Bool {
        !isClosed && ["starting", "running", "needs_you", "waiting", "ready", "interrupted"].contains(status)
    }

    var isWorking: Bool { status == "starting" || status == "running" }

    /// Waiting on the user: an approval or a question in its chat, or a
    /// restart that left it for them to decide.
    var needsYou: Bool { kind == .workstream && (status == "needs_you" || status == "interrupted") }

    /// What it's doing now: its checklist's step in progress, else the tool
    /// step it's on.
    var doing: String? {
        guard isWorking || status == "needs_you" else { return nil }
        if let line = checklist.first(where: { $0.state == .doing }) { return line.text }
        return step.isEmpty ? nil : step
    }

    var doneCount: Int { checklist.filter { $0.state == .done }.count }

    var shownTitle: String {
        if !title.isEmpty { return title }
        return goal.isEmpty ? ref : goal
    }

    var statusText: String {
        switch kind {
        case .askOut:
            switch status {
            case "waiting": return AppLocalization.string("Waiting on \(otherBot)")
            case "done": return AppLocalization.string("\(otherBot) answered")
            default: return Self.statusWord(status)
            }
        case .askIn:
            return status == "done" ? AppLocalization.string("Answered") : AppLocalization.string("\(otherBot) asks")
        case .workstream:
            return Self.statusWord(status)
        }
    }

    static func statusWord(_ status: String) -> String {
        switch status {
        case "starting": return AppLocalization.string("Starting")
        case "running": return AppLocalization.string("Working")
        case "needs_you": return AppLocalization.string("Needs you")
        case "ready": return AppLocalization.string("Ready")
        case "done": return AppLocalization.string("Done")
        case "failed": return AppLocalization.string("Failed")
        case "stopped": return AppLocalization.string("Stopped")
        case "interrupted": return AppLocalization.string("Interrupted")
        case "waiting": return AppLocalization.string("Waiting")
        default: return status
        }
    }
}

/// One bot's work as the plugin last listed it.
struct BotWorkSnapshot: Equatable {
    /// The bot's profile the list was read for.
    let profile: String
    /// "off" while the bot's workstreams are off; "strict" or "lookups".
    let policy: String
    let botName: String
    var items: [BotWorkItem]
    let workingCount: Int
    let needsYouCount: Int
    let readyCount: Int

    init?(response: [String: Any], profile: String) {
        guard response["ok"] as? Bool == true, let rows = response["work"] as? [[String: Any]] else { return nil }
        self.profile = profile
        policy = response["policy"] as? String ?? "off"
        botName = response["bot"] as? String ?? profile
        items = rows.compactMap(BotWorkItem.init(row:))
        let counts = response["counts"] as? [String: Any] ?? [:]
        workingCount = (counts["working"] as? NSNumber)?.intValue ?? 0
        needsYouCount = (counts["needs_you"] as? NSNumber)?.intValue ?? 0
        readyCount = (counts["ready"] as? NSNumber)?.intValue ?? 0
    }

    var isOn: Bool { policy != "off" }

    var active: [BotWorkItem] { items.filter(\.isActive) }
    var recent: [BotWorkItem] { items.filter { !$0.isActive } }

    /// Every workstream's chat, so lists and search leave them to the bot.
    var sessionIDs: Set<String> {
        Set(items.compactMap { $0.kind == .workstream && !$0.sessionID.isEmpty ? $0.sessionID : nil })
    }

    func item(forSession ids: Set<String>) -> BotWorkItem? {
        items.first { $0.kind == .workstream && ids.contains($0.sessionID) }
    }

    /// The Work strip's words ("2 working · 1 needs you"), or nil when
    /// there's no work to show.
    var stripText: String? {
        var parts: [String] = []
        if workingCount > 0 { parts.append(AppLocalization.string("\(workingCount) working")) }
        if needsYouCount > 0 { parts.append(AppLocalization.string("\(needsYouCount) needs you")) }
        if readyCount > 0 { parts.append(AppLocalization.string("\(readyCount) ready")) }
        if parts.isEmpty, !items.isEmpty { return AppLocalization.string("Work") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The Work panel's reads and the user's actions, through the host's
/// notifier plugin. A bot's work is driven in the dashboard's own process,
/// so a plugin that serves `dashboard-profiles` is asked with
/// `?conduit_profile=` (Hermes would send a `?profile=` route for a
/// secondary bot to a plugin host without the session API).
final class BotWorkstreamsClient {
    static let capability = "bot-workstreams"
    static let path = "/api/plugins/conduit_push/workstreams"

    typealias Request = WorkspaceFilesClient.Request

    enum Failure: Error {
        case malformed
    }

    private let profile: String
    private let parameter: String
    private let request: Request

    init(profile: String, parameter: String, request: @escaping Request) {
        self.profile = profile
        self.parameter = parameter
        self.request = request
    }

    /// Where the list is kept on the phone, per dashboard and profile.
    static let keptRoute = path

    @MainActor
    func list(keptIn answers: KeptAnswers? = nil) async throws -> BotWorkSnapshot {
        let path = DashboardPath.withProfile(Self.path, profile: profile, parameter: parameter)
        let profile = profile
        let read = { () async throws -> [String: Any] in
            let response = try await self.request(path, "GET", nil)
            guard BotWorkSnapshot(response: response, profile: profile) != nil else { throw Failure.malformed }
            return response
        }
        let response: [String: Any]
        if let answers {
            response = try await answers.keep(Self.keptRoute, false, read)
        } else {
            response = try await read()
        }
        guard let snapshot = BotWorkSnapshot(response: response, profile: profile) else { throw Failure.malformed }
        return snapshot
    }

    /// The list kept for the bot, or nil.
    @MainActor
    func kept(in answers: KeptAnswers) -> BotWorkSnapshot? {
        answers.kept(Self.keptRoute).flatMap { BotWorkSnapshot(response: $0, profile: profile) }
    }

    /// The user's action on a workstream; the row as it is now.
    @MainActor
    func act(ref: String, action: BotWorkItem.Action, text: String? = nil) async throws -> BotWorkItem? {
        guard let encoded = DashboardPath.encodedQueryComponent(ref) else { throw Failure.malformed }
        let path = DashboardPath.withProfile("\(Self.path)/\(encoded)/\(action.rawValue)", profile: profile, parameter: parameter)
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        let response = try await request(path, "POST", body)
        guard response["ok"] as? Bool == true else { throw Failure.malformed }
        return (response["work"] as? [String: Any]).flatMap(BotWorkItem.init(row:))
    }
}

/// A Bot Chat's work tool call, as its transcript card shows it ("Started
/// W3: Login bug", "Asked Nahida"). A model behind Tool Search calls the
/// tools through `tool_call`, which names the tool and its arguments.
struct BotWorkCall: Equatable {
    enum Tool: String {
        case start = "work_start"
        case send = "work_send"
        case stop = "work_stop"
        case read = "work_read"
        case close = "work_close"
        case list = "work_list"
        case ask = "work_ask"
        case reply = "work_reply"
        case note = "work_note"
        case progress = "work_progress"
    }

    let tool: Tool
    /// The work's ref, from the answer or the arguments ("W3").
    let ref: String?
    let title: String?
    /// The other bot of an ask.
    let bot: String?
    /// What was sent or asked.
    let text: String?
    /// The workstream's chat, from the answer's link.
    let sessionID: String?
    /// The bot's profile the link names.
    let profile: String?
    /// False when the answer says nothing was done.
    let succeeded: Bool

    static let scanLimit = 64 * 1024

    static func parse(toolName: String, input: String?, output: String?) -> BotWorkCall? {
        var name = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name == "tool_call" || Tool(rawValue: name) != nil,
              (input?.utf8.count ?? 0) <= scanLimit, (output?.utf8.count ?? 0) <= scanLimit else { return nil }
        var arguments = input.flatMap(jsonObject) ?? [:]
        if name == "tool_call" {
            guard let inner = arguments["name"] as? String else { return nil }
            name = inner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let nested = arguments["arguments"] as? [String: Any] {
                arguments = nested
            } else if let nested = (arguments["arguments"] as? String).flatMap(jsonObject) {
                arguments = nested
            } else {
                arguments = [:]
            }
        }
        guard let tool = Tool(rawValue: name) else { return nil }
        let answer = output.flatMap(answerObject) ?? [:]
        func text(_ key: String, _ object: [String: Any]) -> String? {
            guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let instructions = ["text", "instructions", "goal", "task"].lazy.compactMap { text($0, arguments) }.first
        return BotWorkCall(
            tool: tool,
            ref: text("ref", answer) ?? text("ref", arguments)?.uppercased(),
            title: text("title", answer) ?? text("title", arguments),
            bot: text("bot", answer) ?? text("bot", arguments),
            text: instructions,
            sessionID: text("link", answer).flatMap(sessionID(inLink:)),
            profile: text("link", answer).flatMap(profile(inLink:)),
            succeeded: answer["ok"] as? Bool ?? true
        )
    }

    /// The card's title, or nil to keep the step's own words.
    func title(running: Bool) -> String? {
        let ref = ref ?? ""
        if running {
            switch tool {
            case .start: return AppLocalization.string("Starting work…")
            case .ask: return bot.map { AppLocalization.string("Asking \($0)…") }
            default: return nil
            }
        }
        guard succeeded else { return nil }
        switch tool {
        case .start:
            guard !ref.isEmpty else { return nil }
            let named = title.map { "\(ref): \($0)" } ?? ref
            return AppLocalization.string("Started \(named)")
        case .send: return ref.isEmpty ? nil : AppLocalization.string("Sent to \(ref)")
        case .stop: return ref.isEmpty ? nil : AppLocalization.string("Stopped \(ref)")
        case .read: return ref.isEmpty ? nil : AppLocalization.string("Read \(ref)")
        case .close: return ref.isEmpty ? nil : AppLocalization.string("Closed \(ref)")
        case .ask: return bot.map { AppLocalization.string("Asked \($0)") }
        case .reply: return ref.isEmpty ? nil : AppLocalization.string("Answered \(ref)")
        case .list, .note, .progress: return nil
        }
    }

    /// The stored id in a `conduit://session/<id>` link the tools answer with.
    static func sessionID(inLink link: String) -> String? {
        guard let range = link.range(of: "conduit://session/") else { return nil }
        let rest = link[range.upperBound...]
        let id = rest.prefix { !"?)]> \n".contains($0) }
        let decoded = String(id).removingPercentEncoding ?? String(id)
        return decoded.isEmpty ? nil : decoded
    }

    /// The `?profile=` a `conduit://session/` link names.
    static func profile(inLink link: String) -> String? {
        guard let start = link.range(of: "conduit://session/") else { return nil }
        let rest = link[start.upperBound...]
        guard let query = rest.range(of: "?profile=") else { return nil }
        let value = rest[query.upperBound...].prefix { !"&)]> \n".contains($0) }
        let decoded = String(value).removingPercentEncoding ?? String(value)
        return decoded.isEmpty ? nil : decoded
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// The tool's answer: its JSON, or a bridge's answer wrapping it.
    private static func answerObject(_ text: String) -> [String: Any]? {
        guard let object = jsonObject(text) else { return nil }
        if object["ref"] == nil, object["ok"] == nil {
            for key in ["result", "output", "content"] {
                if let inner = (object[key] as? String).flatMap(jsonObject) { return inner }
                if let inner = object[key] as? [String: Any] { return inner }
            }
        }
        return object
    }
}
