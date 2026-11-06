import Foundation

/// A bot's work as its Bot Chat coordinates it (Bot workstreams, in the
/// notifier's conduit_push plugin): the workstreams it started, hidden
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
    /// Its git worktree's branch, for the user to merge; empty when it
    /// works in the folder itself.
    let branch: String
    /// A voice call's job (Bot workstreams M5): "phone" or "watch", the
    /// call that started it and tells the user its result; empty for the
    /// bot's own work.
    let fromCall: String
    /// The bot's own workstream a call kept with its Bot Chat started
    /// ("phone" or "watch"); empty otherwise. The phone follows its job, so
    /// a Stop here stops the call's job too.
    let startedInCall: String
    /// The call that started it, either way: the card's "From a voice call".
    var call: String { fromCall.isEmpty ? startedInCall : fromCall }
    /// The bot's screen (Bot Screen): "controlling" while it drives it now,
    /// "waiting" while it waits for it, else empty. Apart from when it used
    /// it last, which says nothing about now (Eric 2026-11-05).
    let screen: String
    let screenUsedAt: Date?
    /// What it waits on the user to do on the bot's screen ("Sign in to
    /// GitHub"); empty when nothing.
    let screenAsk: String

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
        branch = (row["branch"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        fromCall = ["phone", "watch"].contains(row["from_call"] as? String ?? "") ? row["from_call"] as? String ?? "" : ""
        startedInCall = fromCall.isEmpty && ["phone", "watch"].contains(row["call"] as? String ?? "")
            ? row["call"] as? String ?? "" : ""
        screen = ["controlling", "waiting"].contains(row["screen"] as? String ?? "") ? row["screen"] as? String ?? "" : ""
        let used = (row["screen_used_at"] as? NSNumber)?.doubleValue ?? 0
        screenUsedAt = used > 0 ? Date(timeIntervalSince1970: used) : nil
        screenAsk = (row["screen_ask"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        // A screen ask keeps a done row in Active until it's answered.
        !isClosed && (["starting", "running", "needs_you", "waiting", "ready", "interrupted"].contains(status)
                      || !screenAsk.isEmpty)
    }

    var isWorking: Bool { status == "starting" || status == "running" }

    /// Waiting on the user: an approval or a question in its chat, or a
    /// restart that left it for them to decide.
    var needsYou: Bool {
        kind == .workstream && !isClosed && (status == "needs_you" || status == "interrupted" || !screenAsk.isEmpty)
    }

    /// What it's doing now: its checklist's step in progress, else the tool
    /// step it's on.
    var doing: String? {
        guard isWorking || status == "needs_you" else { return nil }
        if let line = checklist.first(where: { $0.state == .doing }) { return line.text }
        return step.isEmpty ? nil : step
    }

    var doneCount: Int { checklist.filter { $0.state == .done }.count }

    /// Its checklist as the chat's Tasks line draws a plan, so a
    /// workstream's chat shows it the way any chat shows Hermes' own.
    /// Nil when it keeps none.
    var checklistPlan: AgentPlan? {
        guard !checklist.isEmpty else { return nil }
        return AgentPlan(items: checklist.map { line in
            let status: AgentPlanItem.Status
            switch line.state {
            case .done: status = .completed
            // Resolved work isn't under way, whatever step it stopped on.
            case .doing: status = isClosed ? .pending : .inProgress
            case .todo: status = .pending
            }
            return AgentPlanItem(id: "work-\(line.index)", content: line.text, status: status, parent: nil)
        }, revision: nil)
    }

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
        if kind == .workstream, !isClosed, !screenAsk.isEmpty { return AppLocalization.string("Needs you") }
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
    /// Who drives the bot's screen now and who used it last; nil from a
    /// plugin before Bot Screen.
    let screen: BotScreenUse?

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
        screen = BotScreenUse(response["screen"] as? [String: Any])
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
        case "needs_you": return item.needsYou ? 1 : 0
        default: return item.status == "ready" && !item.needsYou ? 1 : 0
        }
    }

    /// The panel's sections: what the user pinned, then work still at it
    /// or waiting on them, then the rest, newest change first.
    var pinned: [BotWorkItem] { items.filter(\.isPinned) }
    var active: [BotWorkItem] { items.filter { $0.isActive && !$0.isPinned } }
    var recent: [BotWorkItem] { items.filter { !$0.isActive && !$0.isPinned } }

    /// Every workstream's chat, so lists and search leave them to the bot.
    /// Not a call's job's: it stays listed under Voice Jobs.
    var sessionIDs: Set<String> {
        Set(items.compactMap { $0.kind == .workstream && $0.fromCall.isEmpty && !$0.sessionID.isEmpty ? $0.sessionID : nil })
            .union(knownSessionIDs)
    }

    /// The workstream a chat is. A call's job isn't one: its chat stays a
    /// Voice Jobs chat, with its own title, Back and Stop.
    func item(forSession ids: Set<String>) -> BotWorkItem? {
        items.first { $0.kind == .workstream && $0.fromCall.isEmpty && ids.contains($0.sessionID) }
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
    /// The plugin keeps a voice call's jobs too (`POST /workstreams/adopt`).
    static let adoptCapability = "work-adopt"
    static let callEndedCapability = "work-call-ended"
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

    /// Keeps a voice call's job in the bot's registry (M5), once Hermes takes
    /// the job's request: the Work panel lists it as a call's. `via`
    /// is "phone" or "watch". The row, or nil when the plugin kept none.
    @MainActor
    func adopt(sessionID: String, title: String, via: String, goal: String, chat: String? = nil,
               result: String? = nil, call: String? = nil) async throws -> BotWorkItem? {
        let path = DashboardPath.withProfile("\(Self.path)/adopt", profile: profile, parameter: parameter)
        var body: [String: Any] = ["session_id": sessionID, "title": title, "via": via,
                                   "goal": String(goal.prefix(2_000))]
        // The chat the call is kept with: the Bot Chat's makes it the coordinator's own.
        if let chat, !chat.isEmpty { body["chat"] = chat }
        // A turn that ended before it was kept: the row settles with its reply.
        if let result { body["result"] = String(result.prefix(8_000)) }
        // The call's own id: its end releases only its own hold.
        if let call, !call.isEmpty { body["call"] = call }
        let response = try await request(path, "POST", body)
        guard response["ok"] as? Bool == true else { throw Failure.malformed }
        return (response["work"] as? [String: Any]).flatMap(BotWorkItem.init(row:))
    }

    /// A call kept with `chat` ended: a Bot Chat's held updates go out.
    func callEnded(chat: String, call: String? = nil) async throws {
        let path = DashboardPath.withProfile("\(Self.path)/call-ended", profile: profile, parameter: parameter)
        var body: [String: Any] = ["chat": chat]
        if let call, !call.isEmpty { body["call"] = call }
        let response = try await request(path, "POST", body)
        guard response["ok"] as? Bool == true else { throw Failure.malformed }
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

/// A bot's work settings as Edit Bot > Work shows them: whether its Bot
/// Chat coordinates work at all, what it may do itself, how many
/// workstreams run at once, what a restart does, and what its workstreams
/// ask approval for. Kept by the plugin, so every device shows the same.
struct BotWorkSettings: Equatable {
    enum Policy: String, CaseIterable {
        case off, strict, lookups
    }

    enum AfterRestart: String, CaseIterable {
        case `continue`, ask
    }

    enum Approvals: String, CaseIterable {
        /// As the bot's chats ask, by its approval mode in Hermes.
        case chats
        /// The user's own go-ahead before a step that can't be undone.
        case ask
        /// Nothing asked: Hermes' approvals are off in each workstream.
        case off
    }

    var policy: Policy
    var maxRunning: Int
    var maxRunningLimit: Int
    var afterRestart: AfterRestart
    var approvals: Approvals
    /// The bot's approval mode in Hermes ("manual", "smart" or "off").
    var chatApprovals: String
    /// The model new workstreams start on; nil for the bot's own, the one
    /// its Bot Chat uses (Eric 2026-11-03).
    var workstreamModel: Model?
    /// Why workstreams can't run on this Hermes, as the plugin says it.
    var unavailable: String?

    /// A model Hermes' `session.create` takes, as the plugin keeps it.
    struct Model: Equatable {
        var model: String
        var provider: String = ""
        var reasoningEffort: String = ""

        init(model: String, provider: String = "", reasoningEffort: String = "") {
            self.model = model
            self.provider = provider
            self.reasoningEffort = reasoningEffort
        }

        init?(_ object: Any?) {
            guard let object = object as? [String: Any],
                  let model = (object["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !model.isEmpty else { return nil }
            self.init(model: model, provider: object["provider"] as? String ?? "",
                      reasoningEffort: object["reasoning_effort"] as? String ?? "")
        }

        var body: [String: Any] {
            var body: [String: Any] = ["model": model]
            if !provider.isEmpty { body["provider"] = provider }
            if !reasoningEffort.isEmpty { body["reasoning_effort"] = reasoningEffort }
            return body
        }
    }

    var isOn: Bool { policy != .off }

    /// Edit Bot > Work's Coordinate Work toggle: turning it on comes back
    /// with lookups, the plugin's default (Eric 2026-11-03); a policy
    /// already on stays as it is.
    var isOnSetting: Bool {
        get { isOn }
        set { policy = newValue ? (policy == .off ? .lookups : policy) : .off }
    }

    init(policy: Policy = .lookups, maxRunning: Int = 2, maxRunningLimit: Int = 6,
         afterRestart: AfterRestart = .continue, approvals: Approvals = .chats,
         chatApprovals: String = "manual", workstreamModel: Model? = nil, unavailable: String? = nil) {
        self.policy = policy
        self.maxRunning = maxRunning
        self.maxRunningLimit = maxRunningLimit
        self.afterRestart = afterRestart
        self.approvals = approvals
        self.chatApprovals = chatApprovals
        self.workstreamModel = workstreamModel
        self.unavailable = unavailable
    }

    init?(response: [String: Any]) {
        guard response["ok"] as? Bool == true,
              let policy = (response["policy"] as? String).flatMap(Policy.init(rawValue:)),
              let maxRunning = response["max_running"] as? Int else { return nil }
        let limit = max(response["max_running_limit"] as? Int ?? maxRunning, 1)
        self.init(
            policy: policy,
            maxRunning: min(max(maxRunning, 1), limit),
            maxRunningLimit: limit,
            afterRestart: (response["after_restart"] as? String).flatMap(AfterRestart.init(rawValue:)) ?? .continue,
            approvals: (response["workstream_approvals"] as? String).flatMap(Approvals.init(rawValue:)) ?? .chats,
            chatApprovals: (response["chat_approvals"] as? String) ?? "manual",
            workstreamModel: Model(response["workstream_model"]),
            unavailable: (response["unavailable"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The plugin's body for what differs from `old`; empty when nothing does.
    func change(from old: BotWorkSettings) -> [String: Any] {
        var body: [String: Any] = [:]
        if policy != old.policy { body["policy"] = policy.rawValue }
        if maxRunning != old.maxRunning { body["max_running"] = maxRunning }
        if afterRestart != old.afterRestart { body["after_restart"] = afterRestart.rawValue }
        if approvals != old.approvals { body["workstream_approvals"] = approvals.rawValue }
        if workstreamModel != old.workstreamModel {
            // null: back to the bot's own.
            body["workstream_model"] = workstreamModel.map { $0.body as Any } ?? NSNull()
        }
        return body
    }
}

/// Edit Bot > Work's reads and saves, through the host's notifier plugin,
/// named like the Work panel's (`?conduit_profile=`).
final class BotWorkSettingsClient {
    static let capability = "bot-work-settings"
    static let path = "/api/plugins/conduit_push/workstreams/settings"

    private let profile: String
    private let parameter: String
    private let request: BotWorkstreamsClient.Request

    init(profile: String, parameter: String, request: @escaping BotWorkstreamsClient.Request) {
        self.profile = profile
        self.parameter = parameter
        self.request = request
    }

    private var route: String { DashboardPath.withProfile(Self.path, profile: profile, parameter: parameter) }

    @MainActor
    func load() async throws -> BotWorkSettings {
        guard let settings = BotWorkSettings(response: try await request(route, "GET", nil)) else {
            throw BotWorkstreamsClient.Failure.malformed
        }
        return settings
    }

    /// Saves `change` (the plugin's field names); the settings as they are now.
    @MainActor
    func save(_ change: [String: Any]) async throws -> BotWorkSettings {
        guard let settings = BotWorkSettings(response: try await request(route, "POST", change)) else {
            throw BotWorkstreamsClient.Failure.malformed
        }
        return settings
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

    /// Hermes Desktop's session reference the plugin puts right after each
    /// work link ("[Open W3](conduit://session/…) @session:<profile>/<id>"),
    /// which Desktop draws as a chip that opens the workstream (workstreams
    /// aren't in its list). Conduit's card opens it here, so that reference
    /// is left out with the spaces before it, only when it names that link's
    /// own session; any other reference stays a chat link
    /// (HermesSessionReference). Group 1 is the work link, group 2 its id.
    private static let desktopRef = try! NSRegularExpression(
        pattern: #"(\[(?:Open )?W\d+\]\(conduit://session/([^)?\s]+)[^)\s]*\))[ \t]*"#
            + #"(?<![\w/`@])@session:(?:[A-Za-z0-9][A-Za-z0-9_-]{0,63}/)?\2(?![A-Za-z0-9_]|[.:-][A-Za-z0-9_])"#)

    /// The reply's text without those links (and Desktop's references to
    /// them), and the links in order (each workstream once); nil when it has
    /// none.
    static func split(_ original: String) -> (text: String, links: [Link])? {
        guard original.contains("conduit://session/") else { return nil }
        var text = original
        if text.contains("@session:") {
            text = desktopRef.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
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

    /// A ref named in a reply's words ("W50 found …"), not one already a
    /// link's text, a path's or a longer word's part.
    private static let namedRef = try! NSRegularExpression(pattern: #"(?<![\w/\[])(W\d+)\b(?!\]\(|\.\w)"#)
    /// What's already a link, or part of one: a Markdown link (its text and
    /// its address), an autolink and a bare URL. A ref inside is left alone.
    private static let linkSpans = try! NSRegularExpression(
        pattern: #"!?\[[^\]\n]*\]\([^)\n]*\)|<[^>\s]+>|\b[A-Za-z][A-Za-z0-9+.-]*://[^\s)]+"#)

    /// Whether a reply could name a workstream: a cheap check before the
    /// row watches the bot's work list.
    static func mayNameWork(_ text: String) -> Bool {
        text.range(of: #"W\d"#, options: .regularExpression) != nil
    }

    /// A Bot Chat reply with each workstream it names, as the bot's work
    /// lists it, made a link to that workstream's chat (Eric 2026-11-03:
    /// the coordinator names its work, the user taps it). Code is left as
    /// written; a ref the list doesn't have stays plain.
    static func linkingNamedRefs(_ text: String, chats: (String) -> URL?) -> String {
        guard text.contains("W") else { return text }
        var out = ""
        var inCode = false
        // Backtick runs split code from prose: only the prose is linked.
        for (index, piece) in text.components(separatedBy: "`").enumerated() {
            if index > 0 { out += "`" }
            if inCode {
                out += piece
            } else {
                let ns = piece as NSString
                var linked = ""
                var last = 0
                let whole = NSRange(location: 0, length: ns.length)
                let links = linkSpans.matches(in: piece, range: whole).map(\.range)
                for match in namedRef.matches(in: piece, range: whole) {
                    guard !links.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
                    let ref = ns.substring(with: match.range(at: 1))
                    guard let url = chats(ref) else { continue }
                    linked += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                    linked += "[\(ref)](\(url.absoluteString))"
                    last = match.range.location + match.range.length
                }
                out += linked + ns.substring(from: last)
            }
            inCode.toggle()
        }
        return out
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
