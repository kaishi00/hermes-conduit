//
//  GeminiLiveToolBridge.swift
//  Conduit
//
//  Gemini Live's tools: background jobs on Hermes, run through the same
//  VoiceBackgroundJobSupervisor the classic Voice mode uses. Hermes stays
//  the worker; the live model only starts, lists, and cancels jobs.
//
//  start_job is NON_BLOCKING (3.8's default): its call stays open while the
//  job runs, and the finished result is sent back on that call with
//  WHEN_IDLE scheduling, so the model reports it once it has finished
//  speaking — never over the user. list_jobs and cancel_job are quick local
//  answers and BLOCKING. Approvals and clarifications are never answered by
//  voice: a job that needs input tells the user to open it in Conduit.
//
//  web_search (offered only when lookups run on the Hermes host) and
//  recall_memory are NON_BLOCKING too, answered with WHEN_IDLE scheduling.
//  A BLOCKING call pauses the whole server stream until it is answered:
//  the user's transcript and the model's "let me check" stalled behind
//  the lookup, then everything arrived at once with the result.
//
//  Grok Live has no NON_BLOCKING calls, so its bridge answers start_job
//  as soon as the job is running (`holdsJobCalls` false); the outcome
//  arrives later as a text update, like a withdrawn call's.
//

import Foundation

@MainActor
protocol GeminiLiveJobSupervising: AnyObject {
    var jobs: [VoiceBackgroundJob] { get }
    func startJob(instructions: String, profile: String?, onJobCreated: (@MainActor (UUID) -> Void)?) async -> String
    func statusSummary() -> String
    func cancelAll() async -> String
    func cancel(jobID: UUID) async -> String?
    func markOutcomeDelivered(jobID: UUID)
    func takePendingNoticeForJob() -> (notice: VoiceBackgroundJobNotice, jobID: UUID)?
    func returnUndeliveredNotice(jobID: UUID)
    func noticeSent(jobID: UUID)
    /// The chat the call is attached to, if any.
    var liveThread: VoiceThreadTarget? { get }
    func startThreadTurn(request: String) -> (jobID: UUID?, refusal: String?)
    func lastThreadReply() async -> String?
    @discardableResult
    func showOnScreen(title: String, markdown: String) -> VoiceScreenCard?
    /// Exchanges typed in the attached chat, for the call to keep quietly.
    func takePendingChatContext() -> String?
}

extension VoiceBackgroundJobSupervisor: GeminiLiveJobSupervising {}

@MainActor
final class GeminiLiveToolBridge {
    enum Tool: String {
        case startJob = "start_job"
        case listJobs = "list_jobs"
        case cancelJob = "cancel_job"
        case webSearch = "web_search"
        case recallMemory = "recall_memory"
        case endConversation = "end_conversation"
        case askThread = "ask_thread"
        case readLastReply = "read_last_reply"
        case showOnScreen = "show_on_screen"
    }

    /// What the bridge asks the session to send.
    enum Outgoing: Equatable {
        /// A function response on an open call.
        case toolResponse(id: String, name: String, result: [String: String], scheduling: GeminiLiveProtocol.Scheduling?)
        /// A text turn for an update with no open call to answer on. The
        /// host sends it only while the conversation is idle.
        case textWhenIdle(String)
        /// Context the model keeps without answering (a typed exchange in
        /// the attached chat). Also sent only while idle.
        case contextWhenIdle(String)
        /// Close the conversation once the model's goodbye has played.
        case endConversation

        /// Whether this answers the function call `id`.
        func answers(_ id: String) -> Bool {
            if case .toolResponse(let responseID, _, _, _) = self { return responseID == id }
            return false
        }
    }

    /// The declarations for a session, with web_search when its lookups run
    /// on the Hermes host and recall_memory when its memory provider can be
    /// searched.
    static func declarations(webSearch: Bool, memoryRecall: Bool = false, thread: Bool = false) -> [GeminiLiveProtocol.FunctionDeclaration] {
        functionDeclarations
            + (webSearch ? [webSearchDeclaration] : [])
            + (memoryRecall ? [recallMemoryDeclaration] : [])
            + (thread ? threadDeclarations : [])
    }

    /// Offered only while the call is attached to a Hermes chat.
    static let threadDeclarations: [GeminiLiveProtocol.FunctionDeclaration] = [
        .init(
            name: Tool.askThread.rawValue,
            description: "Send the user's request to Hermes as the next message in the chat this call is attached to. Use it for work that needs Hermes: questions about the chat, follow-ups, and real work. Not for quick facts from the web, or requests the user starts with \"quick\". Hermes' reply arrives later on this call; summarize it unless the user asks to hear it in full. Don't guess the reply.",
            parameters: [
                "type": "OBJECT",
                "properties": [
                    "request": [
                        "type": "STRING",
                        "description": "The request for Hermes, in the user's words plus any context it needs.",
                    ],
                ],
                "required": ["request"],
            ],
            behavior: .nonBlocking
        ),
        .init(
            name: Tool.readLastReply.rawValue,
            description: "Get Hermes' latest reply in the attached chat without asking Hermes anything new. Use it when the user asks you to read the last reply; read it word for word.",
            parameters: ["type": "OBJECT", "properties": [String: Any]()],
            behavior: .nonBlocking
        ),
    ]

    static let showOnScreenDeclaration = GeminiLiveProtocol.FunctionDeclaration(
        name: Tool.showOnScreen.rawValue,
        description: "Show something on the user's phone screen during the call. Use it for anything better seen than heard: charts, tables, forecasts, recipes and other step-by-step instructions, lists, comparisons, images and links, and whenever the user asks to see, show or chart something. Write Markdown: tables for data, numbered lists for steps, ```mermaid blocks for charts (xychart-beta for bar and line charts, pie for shares), ![description](url) for images using only direct image URLs you actually found, and [title](url) for links. Then tell the user in a sentence that it's on their screen and give the gist; don't read it out. If it says the screen isn't available, tell the user instead and don't retry the same thing; the screen can come back later in the call.",
        parameters: [
            "type": "OBJECT",
            "properties": [
                "title": [
                    "type": "STRING",
                    "description": "A short heading, a few words.",
                ],
                "markdown": [
                    "type": "STRING",
                    "description": "What to show, as Markdown.",
                ],
            ],
            "required": ["title", "markdown"],
        ],
        behavior: .blocking
    )

    static let recallMemoryDeclaration = GeminiLiveProtocol.FunctionDeclaration(
        name: Tool.recallMemory.rawValue,
        description: "Search the user's Hermes memory: what Hermes knows about them, their preferences, projects and past conversations. Use it when the user mentions something from before that you don't know, or asks what Hermes remembers. Answer from it naturally; don't read it out.",
        parameters: [
            "type": "OBJECT",
            "properties": [
                "query": [
                    "type": "STRING",
                    "description": "What to look up, in a few words.",
                ],
            ],
            "required": ["query"],
        ],
        behavior: .nonBlocking
    )

    static let webSearchDeclaration = GeminiLiveProtocol.FunctionDeclaration(
        name: Tool.webSearch.rawValue,
        description: "Search the web for current information: weather, news, sports, prices, and other quick facts. Returns titles, snippets and URLs. Answer from them in a sentence or two; don't read URLs aloud.",
        parameters: [
            "type": "OBJECT",
            "properties": [
                "query": [
                    "type": "STRING",
                    "description": "A short web search query.",
                ],
            ],
            "required": ["query"],
        ],
        behavior: .nonBlocking
    )

    static let functionDeclarations: [GeminiLiveProtocol.FunctionDeclaration] = [
        .init(
            name: Tool.startJob.rawValue,
            description: "Start a background job on the user's Hermes agent for work that takes more than a moment (research, coding, checking systems, anything needing Hermes' tools). Only call this when the user asks for such work; in a call attached to a chat, also for quick work the user starts with \"quick\" that needs Hermes' tools. The job runs in its own Hermes chat; its result arrives later on this call. Do not describe job progress unless asked.",
            parameters: [
                "type": "OBJECT",
                "properties": [
                    "instructions": [
                        "type": "STRING",
                        "description": "The complete task for Hermes, in the user's words plus any needed context.",
                    ],
                    "profile": [
                        "type": "STRING",
                        "description": "Only when the user asks for the job to run on another of their Hermes profiles or bots: that profile or bot name, as the user said it. Omit it otherwise.",
                    ],
                ],
                "required": ["instructions"],
            ],
            behavior: .nonBlocking
        ),
        .init(
            name: Tool.listJobs.rawValue,
            description: "List the user's background jobs and their status. Call only when the user asks about their jobs.",
            parameters: ["type": "OBJECT", "properties": [String: Any]()],
            behavior: .blocking
        ),
        .init(
            name: Tool.cancelJob.rawValue,
            description: "Cancel a background job when the user asks. Pass job_id from list_jobs to cancel one job, or omit it to cancel every running job.",
            parameters: [
                "type": "OBJECT",
                "properties": [
                    "job_id": [
                        "type": "STRING",
                        "description": "The job's id from list_jobs. Omit to cancel all running jobs.",
                    ],
                ],
            ],
            behavior: .blocking
        ),
        showOnScreenDeclaration,
        .init(
            name: Tool.endConversation.rawValue,
            description: "End this voice conversation and close it. Call only when the user says goodbye or asks to end, hang up, or close the conversation, after you have said a short goodbye. Background jobs keep running on Hermes.",
            parameters: ["type": "OBJECT", "properties": [String: Any]()],
            behavior: .blocking
        ),
    ]

    private let supervisor: GeminiLiveJobSupervising
    private let webSearch: GeminiLiveWebSearching?
    private let memory: GeminiLiveMemoryRecalling?
    /// Whether a start_job call stays open until its job settles (Gemini's
    /// NON_BLOCKING calls). Without it the call is answered once the job
    /// runs, and the outcome goes out as a text update.
    private let holdsJobCalls: Bool
    /// Open start_job calls, keyed by the job they started.
    private var openCalls: [UUID: String] = [:]
    /// Calls the model withdrew before their start_job finished starting.
    private var withdrawnCallIDs: Set<String> = []

    init(
        supervisor: GeminiLiveJobSupervising,
        webSearch: GeminiLiveWebSearching? = nil,
        memory: GeminiLiveMemoryRecalling? = nil,
        holdsJobCalls: Bool = true
    ) {
        self.supervisor = supervisor
        self.webSearch = webSearch
        self.memory = memory
        self.holdsJobCalls = holdsJobCalls
    }

    var openCallCount: Int { openCalls.count }

    // MARK: Calls

    func handle(_ call: GeminiLiveProtocol.FunctionCall) async -> [Outgoing] {
        switch Tool(rawValue: call.name) {
        case .startJob:
            let instructions = call.arguments["instructions"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !instructions.isEmpty else {
                return [.toolResponse(id: call.id, name: call.name, result: ["error": "instructions is required"], scheduling: .whenIdle)]
            }
            var createdJobID: UUID?
            // The call is registered the moment the job exists, so a
            // withdrawal arriving during Hermes' session setup is honored.
            let reply = await supervisor.startJob(instructions: instructions, profile: call.arguments["profile"]) { [weak self] jobID in
                createdJobID = jobID
                guard self?.isEnding == false else { return }
                self?.openCalls[jobID] = call.id
            }
            if isEnding {
                // Ending while it started: its outcome stays pending.
                if let jobID = createdJobID { openCalls[jobID] = nil }
                return []
            }
            guard let jobID = createdJobID else {
                // Refused (too many jobs): answer now.
                return [.toolResponse(id: call.id, name: call.name, result: ["status": "not_started", "message": reply], scheduling: .whenIdle)]
            }
            if withdrawnCallIDs.remove(call.id) != nil || openCalls[jobID] != call.id {
                // Withdrawn while starting: its outcome arrives later as a
                // text update instead.
                if openCalls[jobID] == call.id { openCalls[jobID] = nil }
                return []
            }
            // Already settled (it failed, or even finished, while starting):
            // settleOpenCalls answers it with the full outcome, result
            // included. Still running: the call stays open, or, without
            // held calls, is answered now and the outcome follows as text.
            let settled = settleOpenCalls()
            guard !holdsJobCalls, openCalls[jobID] == call.id else { return settled }
            openCalls[jobID] = nil
            let title = supervisor.jobs.first(where: { $0.id == jobID })?.title ?? ""
            return settled + [.toolResponse(id: call.id, name: call.name, result: [
                "job_id": jobID.uuidString,
                "title": title,
                "status": "started",
                "message": "The job is running on Hermes. Its result will arrive later as a message; don't wait for it.",
            ], scheduling: nil)]
        case .askThread:
            let request = call.arguments["request"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !request.isEmpty else {
                return [.toolResponse(id: call.id, name: call.name, result: ["error": "request is required"], scheduling: .whenIdle)]
            }
            guard !isEnding else { return [] }
            let sent = supervisor.startThreadTurn(request: request)
            guard let jobID = sent.jobID else {
                return [.toolResponse(id: call.id, name: call.name, result: ["status": "not_sent", "message": sent.refusal ?? ""], scheduling: .whenIdle)]
            }
            openCalls[jobID] = call.id
            // Without held calls it's answered now and the reply follows as
            // a text update, like start_job's outcome.
            guard !holdsJobCalls else { return settleOpenCalls() }
            openCalls[jobID] = nil
            return [.toolResponse(id: call.id, name: call.name, result: [
                "status": "sent",
                "message": "Sent to the chat. Hermes' reply will arrive later as a message; don't guess it.",
            ], scheduling: nil)]
        case .readLastReply:
            guard !isEnding else { return [] }
            let reply = await supervisor.lastThreadReply()
            guard !isEnding else { return [] }
            guard let reply else {
                return [.toolResponse(id: call.id, name: call.name, result: ["error": "Hermes hasn't replied in this chat yet."], scheduling: .whenIdle)]
            }
            return [.toolResponse(id: call.id, name: call.name, result: ["reply": Self.clipped(reply)], scheduling: .whenIdle)]
        case .showOnScreen:
            guard !isEnding else { return [] }
            let markdown = call.arguments["markdown"] ?? ""
            guard supervisor.showOnScreen(title: call.arguments["title"] ?? "", markdown: markdown) != nil else {
                let reason = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "markdown is required"
                    : "The screen isn't available right now; tell the user instead."
                return [.toolResponse(id: call.id, name: call.name, result: ["error": reason], scheduling: nil)]
            }
            var shown = [
                "status": "shown",
                "message": "It's on the user's screen. Say so in a sentence and give the gist; don't read it out.",
            ]
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).count > VoiceBackgroundJobSupervisor.maximumScreenCardCharacters {
                shown["message"] = "Only the start of it fit on the user's screen. Say it's on their screen, give the gist, and offer to show the rest separately."
            }
            return [.toolResponse(id: call.id, name: call.name, result: shown, scheduling: nil)]
        case .listJobs:
            return [.toolResponse(id: call.id, name: call.name, result: listResult(), scheduling: nil)]
        case .cancelJob:
            let reply: String
            if let rawID = call.arguments["job_id"], !rawID.isEmpty {
                if let id = UUID(uuidString: rawID), let message = await supervisor.cancel(jobID: id) {
                    reply = message
                } else {
                    reply = AppLocalization.string("There are no background jobs to cancel.")
                }
            } else {
                reply = await supervisor.cancelAll()
            }
            var outgoing: [Outgoing] = [.toolResponse(id: call.id, name: call.name, result: ["message": reply], scheduling: nil)]
            // Close the open start_job calls of what was just cancelled.
            outgoing += settleOpenCalls()
            return outgoing
        case .webSearch:
            return [.toolResponse(id: call.id, name: call.name, result: await searchResult(call.arguments["query"]), scheduling: .whenIdle)]
        case .recallMemory:
            return [.toolResponse(id: call.id, name: call.name, result: await recallResult(call.arguments["query"]), scheduling: .whenIdle)]
        case .endConversation:
            // Deliberately unanswered: a response would prompt another turn
            // after the goodbye, and the connection closes anyway.
            return [.endConversation]
        case nil:
            return [.toolResponse(id: call.id, name: call.name, result: ["error": "unknown function"], scheduling: .whenIdle)]
        }
    }

    /// The model withdrew these calls (typically the user interrupted). The
    /// jobs keep running; their results arrive later as a text update.
    func cancelCalls(_ ids: [String]) {
        let withdrawn = Set(ids)
        let known = Set(openCalls.values)
        openCalls = openCalls.filter { !withdrawn.contains($0.value) }
        // A withdrawal can overtake a start_job still waiting on Hermes.
        withdrawnCallIDs.formUnion(withdrawn.subtracting(known))
    }

    /// A new connection replaced the one these calls were opened on: they
    /// can no longer be answered, so results go out as text updates.
    func connectionReplaced() {
        openCalls.removeAll()
        withdrawnCallIDs.removeAll()
        isEnding = false
    }

    /// The conversation is ending: open calls are dropped and nothing is
    /// settled, so every outcome stays pending (and unannounced) for
    /// Hermes to report. Cleared by the next connection.
    func beginEnding() {
        openCalls.removeAll()
        withdrawnCallIDs.removeAll()
        isEnding = true
    }

    private(set) var isEnding = false

    // MARK: Job updates

    /// Everything that became deliverable since the last call: finished
    /// start_job calls (WHEN_IDLE), then any other pending job notice as a
    /// text update.
    func pendingUpdates() -> [Outgoing] {
        var outgoing = settleOpenCalls()
        guard !isEnding else { return outgoing }
        while let item = supervisor.takePendingNoticeForJob() {
            let text: String
            switch item.notice {
            case .speak(let spoken): text = Self.relayPrompt(spoken)
            case .submit(let prompt, _): text = prompt
            }
            queuedNotices.append((text, item.jobID))
            outgoing.append(.textWhenIdle(text))
        }
        while let context = supervisor.takePendingChatContext() {
            outgoing.append(.contextWhenIdle(context))
        }
        return outgoing
    }

    /// Job notices handed out as text updates but not yet sent, so they can
    /// be handed back if the conversation closes first.
    private var queuedNotices: [(text: String, jobID: UUID)] = []

    /// A queued text update is being sent. Returns the job whose notice it
    /// carries, if any: the supervisor keeps that job until the send is
    /// confirmed (`textUpdateDelivered`) or fails and is handed back.
    @discardableResult
    func textUpdateSending(_ text: String) -> UUID? {
        guard let index = queuedNotices.firstIndex(where: { $0.text == text }) else { return nil }
        return queuedNotices.remove(at: index).jobID
    }

    /// The socket took the update: its job notice is spoken for.
    func textUpdateDelivered(jobID: UUID?) {
        guard let jobID else { return }
        supervisor.noticeSent(jobID: jobID)
    }

    /// A send that failed: the text waits again for the next connection.
    func textUpdateRequeued(_ text: String, jobID: UUID?) {
        guard let jobID else { return }
        queuedNotices.insert((text, jobID), at: 0)
    }

    /// A job notice that will never be sent becomes pending again.
    func returnNotice(jobID: UUID?) {
        guard let jobID else { return }
        supervisor.returnUndeliveredNotice(jobID: jobID)
    }

    /// The conversation is closing with these text updates unsent: any job
    /// notice among them becomes pending again for Hermes to report.
    func returnUnsent(_ texts: [String]) {
        for text in texts {
            guard let index = queuedNotices.firstIndex(where: { $0.text == text }) else { continue }
            supervisor.returnUndeliveredNotice(jobID: queuedNotices.remove(at: index).jobID)
        }
    }

    private func settleOpenCalls() -> [Outgoing] {
        guard !isEnding else { return [] }
        var outgoing: [Outgoing] = []
        for (jobID, callID) in openCalls.sorted(by: { $0.value < $1.value }) {
            guard let job = supervisor.jobs.first(where: { $0.id == jobID }) else {
                openCalls[jobID] = nil
                continue
            }
            guard !job.status.isActive else { continue }
            openCalls[jobID] = nil
            let alreadyAnnounced = job.outcomeDelivered
            supervisor.markOutcomeDelivered(jobID: jobID)
            var result: [String: String] = ["job_id": jobID.uuidString, "title": job.title, "status": Self.statusName(job.status)]
            switch job.status {
            case .finished:
                if let text = job.result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    result["result"] = Self.clipped(text)
                } else {
                    result["result"] = AppLocalization.string("\(job.title) has finished. Open it in Conduit to read the result.")
                }
            case .failed(let message):
                result["error"] = message
            default:
                break
            }
            // A cancel the user just heard confirmed (cancel_job) needs no
            // second report; everything else — including a start that failed
            // — is told once the conversation is quiet.
            let scheduling: GeminiLiveProtocol.Scheduling = job.status == .cancelled && alreadyAnnounced ? .silent : .whenIdle
            let name = job.isThreadTurn ? Tool.askThread.rawValue : Tool.startJob.rawValue
            outgoing.append(.toolResponse(id: callID, name: name, result: result, scheduling: scheduling))
        }
        return outgoing
    }

    private func searchResult(_ rawQuery: String?) async -> [String: String] {
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return ["error": "query is required"] }
        guard let webSearch else { return ["error": "web search is not available"] }
        do {
            let results = try await webSearch.webSearch(query: query)
            guard !results.isEmpty else { return ["results": "No results."] }
            return ["results": Self.searchSummary(results)]
        } catch {
            // The host's own reason ("No web search provider configured…")
            // lets the model tell the user what's wrong.
            return ["error": error.localizedDescription]
        }
    }

    private func recallResult(_ rawQuery: String?) async -> [String: String] {
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return ["error": "query is required"] }
        guard let memory else { return ["error": "Hermes memory is not available"] }
        do {
            let results = try await memory.recallMemory(query: query)
            return ["results": results.isEmpty ? "Nothing in memory about that." : results]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Results as numbered lines for the model. Not UI copy.
    static func searchSummary(_ results: [GeminiLiveWebResult]) -> String {
        results.enumerated().map { index, result in
            "\(index + 1). \(result.title): \(result.snippet) (\(result.url))"
        }.joined(separator: "\n")
    }

    private func listResult() -> [String: String] {
        let visible = supervisor.jobs.filter { !$0.isThreadTurn && ($0.status.isActive || !$0.outcomeDelivered) }
        var result: [String: String] = ["summary": supervisor.statusSummary()]
        for (index, job) in visible.enumerated() {
            result["job_\(index + 1)"] = "id=\(job.id.uuidString); title=\(job.title); status=\(Self.statusName(job.status))"
        }
        return result
    }

    // MARK: Helpers

    static func statusName(_ status: VoiceBackgroundJob.Status) -> String {
        switch status {
        case .starting: return "starting"
        case .running: return "running"
        case .needsInput: return "needs_input_in_conduit"
        case .finished: return "finished"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    static func clipped(_ text: String) -> String {
        let limit = VoiceBackgroundJobSupervisor.maximumResultCharacters
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[…]"
    }

    /// Wraps a fixed notice for the model. Not UI copy, so not localized.
    static func relayPrompt(_ notice: String) -> String {
        "[Background job update. Tell the user this in one short sentence, in the language we have been speaking, then stop: \(notice)]"
    }
}
