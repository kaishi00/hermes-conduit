import Foundation

/// A bot's work as its Bot Chat coordinates it (Bot workstreams, the
/// notifier's `bot-workstreams` branch): the workstreams it started, hidden
/// chats of its own named W1, W2, and its asks to other bots and theirs to
/// it (A1, A2). The plugin's `/workstreams` route lists them; the user's own
/// actions on a workstream (Reply, Stop, Continue, Check first) go straight
/// to it there, with no Bot Chat turn, as does how they file it (Pin,
/// Resolve, Reopen).
struct BotWorkItem: Identifiable, Equatable {
    enum Kind: String {
        case workstream
        case askOut = "ask_out"
        case askIn = "ask_in"
    }

    /// What the user can do with the work now, as the plugin says, and how
    /// they can file it (`manage`).
    enum Action: String, CaseIterable {
        case send, stop, `continue`, check
        case pin, unpin, resolve, reopen
        /// Answers the approval its "Needs you" card shows (`approval`).
        case approve, deny
    }

    /// The approval a workstream waits on, as the plugin read it from
    /// Hermes: one named by its request, so an answer reaches only it.
    struct Approval: Equatable {
        let requestID: String
        let command: String
        let description: String
        /// The card shows the whole command as written, so Approve approves
        /// what it showed. False for an empty or cut one: deny only here.
        var isApprovable = true
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
    /// Resolved: by the user, or by the bot (`work_close`).
    let isClosed: Bool
    let closedAt: Date?
    /// "user" or "bot" while it's resolved.
    let resolvedBy: String
    let isPinned: Bool
    /// A restart cut it off during a step that can change things, so it may
    /// or may not have taken effect: Check first is offered.
    let isUncertain: Bool
    let actions: [Action]
    /// Pin or Unpin, Resolve, or Reopen.
    let manage: [Action]
    /// What it's waiting on the user to approve; nil when nothing, or when
    /// only its chat can answer it.
    let approval: Approval?

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
        let closed = (row["closed_at"] as? NSNumber)?.doubleValue ?? 0
        closedAt = closed > 0 ? Date(timeIntervalSince1970: closed) : nil
        resolvedBy = row["resolved_by"] as? String ?? ""
        isPinned = row["pinned"] as? Bool ?? false
        isUncertain = row["uncertain"] as? Bool ?? false
        actions = (row["actions"] as? [String] ?? []).compactMap(Action.init(rawValue:))
        manage = (row["manage"] as? [String] ?? []).compactMap(Action.init(rawValue:))
        if let asked = row["approval"] as? [String: Any], let requestID = asked["request_id"] as? String,
           !requestID.isEmpty {
            let command = asked["command"] as? String ?? ""
            approval = Approval(requestID: requestID, command: command,
                                description: asked["description"] as? String ?? "",
                                isApprovable: (asked["approvable"] as? Bool ?? true)
                                    && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } else {
            approval = nil
        }
    }

    /// Still the bot's or the user's to finish: a restart's cut-off waits
    /// on the user, so it stays with the active work.
    var isActive: Bool {
        !isClosed && ["starting", "running", "needs_you", "waiting", "ready", "interrupted"].contains(status)
    }

    var isWorking: Bool { status == "starting" || status == "running" }

    /// Waiting on the user: an approval or a question in its chat, or a
    /// restart that left it for them to decide.
    var needsYou: Bool { kind == .workstream && !isClosed && (status == "needs_you" || status == "interrupted") }

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

    /// Resolved before it finished: it reads as resolved, not by the
    /// status it was left in ("Needs you", "Working").
    var isResolvedUnfinished: Bool {
        isClosed && ["needs_you", "interrupted", "starting", "running", "waiting"].contains(status)
    }

    var statusText: String {
        if isResolvedUnfinished { return AppLocalization.string("Resolved") }
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
    private(set) var workingCount: Int
    private(set) var needsYouCount: Int
    private(set) var readyCount: Int
    private(set) var resolvedCount: Int
    /// Every workstream's chat the plugin knows, resolved ones too.
    let knownSessionIDs: Set<String>

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
        resolvedCount = (response["resolved_count"] as? NSNumber)?.intValue ?? 0
        knownSessionIDs = Set((response["workstream_sessions"] as? [String] ?? []).filter { !$0.isEmpty })
    }

    var isOn: Bool { policy != "off" }

    /// The list with one row as an action left it, its counts moved by the
    /// row's change, as the plugin counts them, so the strip follows a Stop
    /// at once.
    func replacing(_ item: BotWorkItem) -> BotWorkSnapshot {
        guard let index = items.firstIndex(where: { $0.ref == item.ref }) else { return self }
        var copy = self
        let old = items[index]
        if item.isClosed {
            // Resolved: it leaves the list for the Resolved one.
            copy.items.remove(at: index)
            copy.resolvedCount += old.isClosed ? 0 : 1
            copy.add(old, sign: -1)
            return copy
        }
        copy.items[index] = item
        copy.workingCount = max(0, workingCount - Self.counts(old, "working") + Self.counts(item, "working"))
        copy.needsYouCount = max(0, needsYouCount - Self.counts(old, "needs_you") + Self.counts(item, "needs_you"))
        copy.readyCount = max(0, readyCount - Self.counts(old, "ready") + Self.counts(item, "ready"))
        return copy
    }

    /// The list with a row the user reopened from the Resolved list back
    /// at its top.
    func reopening(_ item: BotWorkItem) -> BotWorkSnapshot {
        guard !item.isClosed, !items.contains(where: { $0.ref == item.ref }) else { return replacing(item) }
        var copy = self
        copy.items.insert(item, at: 0)
        copy.resolvedCount = max(0, resolvedCount - 1)
        copy.add(item, sign: 1)
        return copy
    }

    private mutating func add(_ item: BotWorkItem, sign: Int) {
        workingCount = max(0, workingCount + sign * Self.counts(item, "working"))
        needsYouCount = max(0, needsYouCount + sign * Self.counts(item, "needs_you"))
        readyCount = max(0, readyCount + sign * Self.counts(item, "ready"))
    }

    private static func counts(_ item: BotWorkItem, _ count: String) -> Int {
        guard item.kind == .workstream, !item.isClosed else { return 0 }
        switch count {
        case "working": return ["starting", "running"].contains(item.status) ? 1 : 0
        case "needs_you": return ["needs_you", "interrupted"].contains(item.status) ? 1 : 0
        default: return item.status == "ready" ? 1 : 0
        }
    }

    /// The panel's sections: what the user pinned, then work still at it
    /// or waiting on them, then the rest, newest change first.
    var pinned: [BotWorkItem] { items.filter(\.isPinned) }
    var active: [BotWorkItem] { items.filter { $0.isActive && !$0.isPinned } }
    var recent: [BotWorkItem] { items.filter { !$0.isActive && !$0.isPinned } }

    /// Every workstream's chat, so lists and search leave them to the bot.
    var sessionIDs: Set<String> {
        Set(items.compactMap { $0.kind == .workstream && !$0.sessionID.isEmpty ? $0.sessionID : nil })
            .union(knownSessionIDs)
    }

    func item(forSession ids: Set<String>) -> BotWorkItem? {
        items.first { $0.kind == .workstream && ids.contains($0.sessionID) }
    }

    /// The words under the Bot Chat's title ("2 working · 1 needs you"),
    /// or nil when there's no work to show.
    var stripText: String? {
        var parts: [String] = []
        if workingCount > 0 { parts.append(AppLocalization.string("\(workingCount) working")) }
        if needsYouCount > 0 { parts.append(AppLocalization.string("\(needsYouCount) needs you")) }
        if readyCount > 0 { parts.append(AppLocalization.string("\(readyCount) ready")) }
        // Resolved work alone still opens the panel, for its Resolved list.
        if parts.isEmpty, !items.isEmpty || resolvedCount > 0 { return AppLocalization.string("Work") }
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
        let botProfile = profile
        let path = DashboardPath.withProfile(Self.path, profile: botProfile, parameter: parameter)
        let read = { () async throws -> [String: Any] in
            let response = try await self.request(path, "GET", nil)
            guard BotWorkSnapshot(response: response, profile: botProfile) != nil else { throw Failure.malformed }
            return response
        }
        let response: [String: Any]
        if let answers {
            response = try await answers.keep(Self.keptRoute, false, read)
        } else {
            response = try await read()
        }
        guard let snapshot = BotWorkSnapshot(response: response, profile: botProfile) else { throw Failure.malformed }
        return snapshot
    }

    /// A page of the bot's resolved work, last resolved first, and whether
    /// there's another (`before`: the last row's resolved time).
    @MainActor
    func resolved(before: Date? = nil) async throws -> (items: [BotWorkItem], more: Bool) {
        var route = "\(Self.path)?resolved=1"
        if let before { route += "&before=\(before.timeIntervalSince1970)" }
        let response = try await request(DashboardPath.withProfile(route, profile: profile, parameter: parameter), "GET", nil)
        guard response["ok"] as? Bool == true, let rows = response["work"] as? [[String: Any]] else { throw Failure.malformed }
        return (rows.compactMap(BotWorkItem.init(row:)), response["more"] as? Bool ?? false)
    }

    /// The list kept for the bot, or nil.
    @MainActor
    func kept(in answers: KeptAnswers) -> BotWorkSnapshot? {
        answers.kept(Self.keptRoute).flatMap { BotWorkSnapshot(response: $0, profile: profile) }
    }

    /// The user's action on a workstream; the row as it is now.
    @MainActor
    func act(ref: String, action: BotWorkItem.Action, text: String? = nil,
             requestID: String? = nil) async throws -> BotWorkItem? {
        guard let encoded = DashboardPath.encodedQueryComponent(ref) else { throw Failure.malformed }
        let path = DashboardPath.withProfile("\(Self.path)/\(encoded)/\(action.rawValue)", profile: profile, parameter: parameter)
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let requestID { body["request_id"] = requestID }
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
            // An answer that can't be read keeps the step's own words.
            succeeded: answer["ok"] as? Bool ?? !answer.isEmpty
        )
    }

    /// The card's title, or nil to keep the step's own words.
    func title(running: Bool) -> String? {
        let ref = self.ref ?? ""
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
                if let inner = object[key] as? [String: Any] { return inner }
                // A bridge's plain-text answer ("W3 is not running") says
                // nothing was done for sure: the step keeps its own words.
                if let text = object[key] as? String { return jsonObject(text) }
            }
        }
        return object
    }
}

/// The links to its work a Bot Chat's reply carries ("[Open W46](conduit://
/// session/…)", which the plugin hands the bot): drawn as work cards under
/// the reply instead of plain links among its words.
enum BotWorkLinks {
    struct Link: Equatable {
        let ref: String
        let sessionID: String
        let profile: String?
        let url: URL
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"\[(?:Open )?(W\d+)\]\((conduit://session/[^)\s]+)\)"#)

    /// The reply's text without those links, and the links in order (each
    /// workstream once); nil when it has none.
    static func split(_ text: String) -> (text: String, links: [Link])? {
        guard text.contains("conduit://session/") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        var links: [Link] = []
        var kept = text
        for match in pattern.matches(in: text, range: range).reversed() {
            guard let refRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text),
                  let whole = Range(match.range, in: kept),
                  let url = URL(string: String(text[urlRange])),
                  case .session(let id, let profile, _) = ConduitAppLink(url: url) else { continue }
            let ref = String(text[refRange])
            if !links.contains(where: { $0.ref == ref }) {
                links.insert(Link(ref: ref, sessionID: id, profile: profile, url: url), at: 0)
            }
            // The spaces before it go too, and the "(…)" around it once it's
            // empty; the rest of the reply stays as written.
            var lower = spacesBefore(whole.lowerBound, in: kept)
            var upper = whole.upperBound
            if lower > kept.startIndex, kept[kept.index(before: lower)] == "(",
               upper < kept.endIndex, kept[upper] == ")" {
                lower = spacesBefore(kept.index(before: lower), in: kept)
                upper = kept.index(after: upper)
            }
            kept.removeSubrange(lower..<upper)
        }
        guard !links.isEmpty else { return nil }
        return (kept.trimmingCharacters(in: .whitespacesAndNewlines), links)
    }

    private static func spacesBefore(_ index: String.Index, in text: String) -> String.Index {
        var lower = index
        while lower > text.startIndex, text[text.index(before: lower)] == " " { lower = text.index(before: lower) }
        return lower
    }
}

/// A workstream's first message: the brief its coordinator wrote (the
/// plugin's `WORKER_PROMPT`). Its chat shows it as a card, the task first,
/// rather than as something the user typed.
struct WorkstreamBrief: Equatable {
    static let opening = "You're working on a task for "
    static let taskMark = "\n\nTask:\n"
    /// Where the plugin's go-ahead rules begin, after the task.
    static let rulesMarks = ["\nBefore a step that can't be undone", "\nHermes' approvals decide which steps"]

    /// The coordinating bot's name.
    let bot: String
    /// What the coordinator asked for.
    let task: String
    /// The user's message the coordinator was answering, when the brief
    /// quotes it.
    let userWords: String?

    static func parse(_ text: String) -> WorkstreamBrief? {
        guard text.hasPrefix(opening), let mark = text.range(of: taskMark) else { return nil }
        let head = text[text.index(text.startIndex, offsetBy: opening.count)..<mark.lowerBound]
        guard let comma = head.range(of: ", who coordinates") else { return nil }
        let bot = String(head[..<comma.lowerBound]).trimmingCharacters(in: .whitespaces)
        var task = text[mark.upperBound...]
        if let rules = rulesMarks.compactMap({ task.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            task = task[..<rules.lowerBound]
        }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bot.isEmpty, !trimmed.isEmpty else { return nil }
        var words: String?
        if let quoted = head.range(of: "\n\nThe user's message that "),
           let open = head[quoted.upperBound...].range(of: "«"),
           let close = head[open.upperBound...].range(of: "»", options: .backwards) {
            let said = head[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            words = said.isEmpty ? nil : said
        }
        return WorkstreamBrief(bot: bot, task: trimmed, userWords: words)
    }
}

extension ChatMessage {
    /// The same row showing other words: a Bot Chat reply with its work
    /// links drawn as cards (BotWorkLinks).
    func withContent(_ text: String) -> ChatMessage {
        var copy = self
        copy.content = text
        copy.rawContent = copy.rawContent.map { _ in text }
        return copy
    }
}
