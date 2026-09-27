//
//  VoiceBackgroundJobs.swift
//  Conduit
//
//  Background jobs started from a Voice conversation (issue #163, phase 1).
//  Each job is its own ordinary Hermes session: the voice conversation keeps
//  flowing while the job works, and its result is handed back to the voice
//  conversation when it finishes. Hermes stays the worker; Conduit only
//  starts, watches, and cancels sessions it created.
//

import Foundation

// MARK: - Spoken commands

/// A spoken background-job command recognized on a finished utterance.
enum VoiceBackgroundJobCommand: Equatable {
    case start(instructions: String)
    case status
    case cancelAll
}

/// Built-in spoken background-job commands. Matching follows the same
/// conservative rules as `VoiceSpokenCommands`: status and cancel match the
/// WHOLE utterance only, and a start command needs an explicit leading
/// phrase ("background job, …") followed by the task itself. There is no
/// semantic matching: an ordinary sentence that merely mentions a
/// background never starts a job.
enum VoiceBackgroundJobCommands {
    /// Leading phrases that start a job; the rest of the utterance is the
    /// task. Longest phrases first so "start a background job" is consumed
    /// whole rather than leaving "start a" behind.
    static let startPrefixes = [
        "start a background job",
        "start background job",
        "run in the background",
        "background job",
        "在后台运行",
        "后台任务",
    ]
    static let statusPhrases = [
        "job status",
        "background jobs",
        "background job status",
        "check background jobs",
        "后台任务状态",
    ]
    static let cancelPhrases = [
        "cancel background jobs",
        "cancel all background jobs",
        "stop background jobs",
        "取消后台任务",
    ]

    static func parse(_ utterance: String) -> VoiceBackgroundJobCommand? {
        if VoiceSpokenCommands.matches(utterance, phrases: cancelPhrases) { return .cancelAll }
        if VoiceSpokenCommands.matches(utterance, phrases: statusPhrases) { return .status }
        // Leading whitespace/punctuation dropped the same way the shared
        // canonicalizer does, but on the original text so the task keeps
        // the user's casing.
        let strip = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let trimmed = String(String.UnicodeScalarView(utterance.unicodeScalars.drop(while: { strip.contains($0) })))
        let folded = trimmed.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for prefix in startPrefixes {
            guard folded.hasPrefix(prefix) else { continue }
            let afterPrefix = trimmed.dropFirst(prefix.count)
            // Word boundary for Latin phrases: "background jobs" must not
            // read as "background job" + "s". CJK phrases have no spaces.
            if let next = afterPrefix.first, next.isLetter || next.isNumber,
               prefix.unicodeScalars.allSatisfy({ $0.isASCII }) {
                continue
            }
            let task = afterPrefix.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !task.isEmpty else { return nil }
            return .start(instructions: task)
        }
        return nil
    }
}

// MARK: - Jobs

struct VoiceBackgroundJob: Identifiable, Equatable {
    enum Status: Equatable {
        case starting
        case running
        /// Hermes is waiting on an approval or a clarification answer.
        case needsInput
        case finished
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .starting, .running, .needsInput: return true
            case .finished, .failed, .cancelled: return false
            }
        }
    }

    let id: UUID
    let title: String
    let instructions: String
    var runtimeSessionID: String?
    var storedSessionID: String?
    var status: Status
    /// The job's final assistant message, when the completion event reached
    /// Conduit. Nil when completion was only observed through the liveness
    /// poll (the chat itself still holds the answer).
    var result: String?
    let startedAt: Date
    /// Whether the terminal outcome was handed to the voice conversation.
    var outcomeDelivered = false
    /// Whether the current needs-input episode was announced.
    var inputRequestDelivered = false
    /// Consecutive liveness polls that found no registry row for the job.
    /// One miss can be transient; two settle it.
    var consecutiveMissedPolls = 0

    func owns(sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        return sessionID == runtimeSessionID || sessionID == storedSessionID
    }
}

/// What the voice conversation should do with a pending job update.
enum VoiceBackgroundJobNotice: Equatable {
    /// Speak a fixed notice locally; no Hermes turn is involved.
    case speak(String)
    /// Hand a finished job's result to the voice conversation's own Hermes
    /// session so it can summarize it aloud and keep the context for
    /// follow-up questions. `fallback` is spoken if the submission fails.
    case submit(prompt: String, fallback: String)
}

/// Hermes operations the supervisor needs. Closures (not a protocol) so
/// AppState can bind them to whichever client is current at call time and
/// tests can script them.
struct VoiceBackgroundJobBackend {
    var createSession: @MainActor () async throws -> (runtimeID: String, storedID: String?)
    var setTitle: @MainActor (_ sessionID: String, _ title: String) async -> Void
    var submit: @MainActor (_ sessionID: String, _ text: String) async throws -> Void
    var cancel: @MainActor (_ sessionID: String) async throws -> Void
    var liveSessions: @MainActor () async throws -> [LiveSessionStatus]
}

/// Seam the Voice controller uses for spoken job commands and hand-backs.
@MainActor
protocol VoiceBackgroundJobHandling: AnyObject {
    /// Runs a recognized command and returns what Voice should say.
    func performVoiceCommand(_ command: VoiceBackgroundJobCommand) async -> String
    /// Removes and returns the next update the voice conversation should
    /// deliver, or nil when nothing is pending.
    func takePendingNotice() -> VoiceBackgroundJobNotice?
}

@MainActor
final class VoiceBackgroundJobSupervisor: ObservableObject, VoiceBackgroundJobHandling {
    static let maximumActiveJobs = 3
    /// Upper bound on the finished-job text handed to the voice session.
    static let maximumResultCharacters = 6_000
    static let maximumTitleCharacters = 60
    /// Settled, already-announced jobs kept for the Voice sheet and status.
    static let maximumSettledJobs = 10
    static let missedPollsBeforeSettling = 2

    @Published private(set) var jobs: [VoiceBackgroundJob] = []

    /// Called whenever a notice becomes pending, so the host can let an
    /// idle voice conversation deliver it.
    var onNoticePending: (@MainActor () -> Void)?
    /// Called with every id of a newly created job session so the host can
    /// badge it in the session list.
    var onJobSessionCreated: (@MainActor (_ sessionIDs: [String]) -> Void)?

    private let backend: VoiceBackgroundJobBackend
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    /// Bumped by `reset()` so work started for a retired server or profile
    /// can never write into the new ledger.
    private var generation: UInt64 = 0

    init(backend: VoiceBackgroundJobBackend, pollInterval: Duration = .seconds(20)) {
        self.backend = backend
        self.pollInterval = pollInterval
    }

    deinit { pollTask?.cancel() }

    var activeJobCount: Int { jobs.filter { $0.status.isActive }.count }

    // MARK: Commands

    func performVoiceCommand(_ command: VoiceBackgroundJobCommand) async -> String {
        switch command {
        case .start(let instructions):
            return await startJob(instructions: instructions)
        case .status:
            return statusSummary()
        case .cancelAll:
            return await cancelAll()
        }
    }

    /// `onJobCreated` receives the ledger id as soon as the job is admitted
    /// (before any Hermes round trip), so a caller can correlate the job's
    /// later outcome with its own request (Gemini Live's open tool call).
    func startJob(
        instructions: String,
        onJobCreated: (@MainActor (UUID) -> Void)? = nil
    ) async -> String {
        let activeCount = activeJobCount
        guard activeCount < Self.maximumActiveJobs else {
            return AppLocalization.string("You already have \(activeCount) background jobs running. Cancel them before starting another.")
        }
        let job = VoiceBackgroundJob(
            id: UUID(),
            title: Self.title(for: instructions),
            instructions: instructions,
            status: .starting,
            startedAt: Date()
        )
        jobs.append(job)
        onJobCreated?(job.id)
        let generation = generation
        var createdSessionID: String?
        do {
            let ids = try await backend.createSession()
            createdSessionID = ids.runtimeID.isEmpty ? nil : ids.runtimeID
            guard startIsCurrent(job.id, generation: generation) else {
                return await abandonStart(job, sessionID: createdSessionID, generation: generation)
            }
            guard let runtimeID = createdSessionID else {
                throw VoiceAudioError.unavailable(AppLocalization.string("Hermes did not return a session."))
            }
            update(job.id) {
                $0.runtimeSessionID = runtimeID
                $0.storedSessionID = ids.storedID
            }
            onJobSessionCreated?([runtimeID, ids.storedID].compactMap { $0 }.filter { !$0.isEmpty })
            await backend.setTitle(runtimeID, job.title)
            guard startIsCurrent(job.id, generation: generation) else {
                return await abandonStart(job, sessionID: runtimeID, generation: generation)
            }
            try await backend.submit(runtimeID, Self.jobPrompt(for: instructions))
            // Events may legitimately move the job past .starting while
            // submit awaits; only a cancel or a reset retires it here. A
            // cancel that landed mid-submit reached Hermes before the turn
            // existed, so it is repeated now that there is one to stop.
            guard generation == self.generation, self.job(job.id)?.status != .cancelled else {
                return await abandonStart(job, sessionID: runtimeID, generation: generation)
            }
            if case .failed = self.job(job.id)?.status {
                return failedStartReply(job.id)
            }
            if self.job(job.id)?.status == .starting {
                update(job.id) { $0.status = .running }
            }
            startPollingIfNeeded()
            return AppLocalization.string("Started a background job: \(job.title).")
        } catch {
            guard generation == self.generation, self.job(job.id)?.status != .cancelled else {
                return await abandonStart(job, sessionID: createdSessionID, generation: generation)
            }
            // A lost submit acknowledgement after Hermes already started the
            // turn (its events moved the job on) is not a failed start.
            switch self.job(job.id)?.status {
            case .running?, .needsInput?, .finished?:
                startPollingIfNeeded()
                return AppLocalization.string("Started a background job: \(job.title).")
            case .failed?:
                break
            default:
                update(job.id) { $0.status = .failed(error.localizedDescription) }
                // A submit can fail after Hermes accepted the turn (a lost
                // acknowledgement). The user is told the start failed, so
                // interrupt whatever may be running rather than leave it
                // unmonitored.
                if let createdSessionID { try? await backend.cancel(createdSessionID) }
            }
            return failedStartReply(job.id)
        }
    }

    /// The start failed (or Hermes failed the turn before submit returned):
    /// the reply says so, and the same failure is not announced again later.
    private func failedStartReply(_ id: UUID) -> String {
        update(id) { $0.outcomeDelivered = true }
        pruneSettledJobs()
        return AppLocalization.string("Couldn't start the background job.")
    }

    /// A start is still wanted while its job is `.starting` in the ledger
    /// generation it began in: `cancelAll` and `reset` both retire it.
    private func startIsCurrent(_ id: UUID, generation: UInt64) -> Bool {
        generation == self.generation && job(id)?.status == .starting
    }

    /// Winds down a start that a cancel or reset overtook: whatever Hermes
    /// already created is interrupted (best effort) so a job the user heard
    /// cancelled never runs unmonitored.
    private func abandonStart(_ job: VoiceBackgroundJob, sessionID: String?, generation: UInt64) async -> String {
        if let sessionID { try? await backend.cancel(sessionID) }
        guard generation == self.generation else {
            return AppLocalization.string("Couldn't start the background job.")
        }
        return AppLocalization.string("\(job.title) was cancelled.")
    }

    func statusSummary() -> String {
        let visible = jobs.filter { $0.status.isActive || !$0.outcomeDelivered }
        guard !visible.isEmpty else {
            return AppLocalization.string("No background jobs are running.")
        }
        return visible.map { job -> String in
            let title = job.title
            switch job.status {
            case .starting, .running:
                return AppLocalization.string("\(title) is still running.")
            case .needsInput:
                return AppLocalization.string("\(title) is waiting for your input.")
            case .finished:
                return AppLocalization.string("\(title) has finished.")
            case .failed:
                return AppLocalization.string("\(title) failed.")
            case .cancelled:
                return AppLocalization.string("\(title) was cancelled.")
            }
        }.joined(separator: " ")
    }

    func cancelAll() async -> String {
        let targets = jobs.filter { $0.status.isActive }
        guard !targets.isEmpty else {
            return AppLocalization.string("There are no background jobs to cancel.")
        }
        for job in targets {
            // Mark first: the interrupt's own terminal event must read as a
            // cancellation, not a failure to announce.
            update(job.id) {
                $0.status = .cancelled
                $0.outcomeDelivered = true
            }
            if let sessionID = job.runtimeSessionID {
                try? await backend.cancel(sessionID)
            }
        }
        stopPollingIfIdle()
        pruneSettledJobs()
        let count = targets.count
        return AppLocalization.string("Cancelled \(count) background jobs.")
    }

    /// Cancels one active job. Returns what to say, or nil when no active
    /// job has that id.
    func cancel(jobID: UUID) async -> String? {
        guard let job = job(jobID), job.status.isActive else { return nil }
        update(jobID) {
            $0.status = .cancelled
            $0.outcomeDelivered = true
        }
        if let sessionID = job.runtimeSessionID {
            try? await backend.cancel(sessionID)
        }
        stopPollingIfIdle()
        pruneSettledJobs()
        return AppLocalization.string("\(job.title) was cancelled.")
    }

    /// Records that a job's terminal outcome reached the user through
    /// another channel (a Gemini Live tool response), so `takePendingNotice`
    /// never announces it a second time.
    func markOutcomeDelivered(jobID: UUID) {
        update(jobID) { $0.outcomeDelivered = true }
        pruneSettledJobs()
    }

    func job(withID id: UUID) -> VoiceBackgroundJob? { job(id) }

    /// Forgets every job without touching Hermes: the jobs keep running on
    /// the server as ordinary chats. Used at server, profile, and sign-out
    /// boundaries, where the ledger no longer belongs to the active gateway.
    func reset() {
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        jobs.removeAll()
    }

    // MARK: Events

    /// Observes every gateway event before AppState's active-session filter.
    /// Only events addressed to a job session change anything.
    func observe(_ event: StreamEvent) {
        guard let sessionID = Self.sessionID(for: event),
              let index = jobs.firstIndex(where: { $0.owns(sessionID: sessionID) }) else { return }
        let before = jobs[index]
        guard before.status.isActive else { return }
        // Any event for the job is proof of life for the liveness poll.
        jobs[index].consecutiveMissedPolls = 0
        switch event {
        case .messageStart, .messageDelta, .reasoningDelta, .toolStart, .toolComplete:
            if before.status == .needsInput || before.status == .starting {
                jobs[index].status = .running
                jobs[index].inputRequestDelivered = false
            }
        case .approval, .clarify:
            jobs[index].status = .needsInput
            jobs[index].inputRequestDelivered = false
        case .messageComplete(_, _, let content, _):
            // Contract: Hermes emits message.complete once per turn, after
            // the tool loop ends (intermediate assistant text arrives as
            // deltas around tool.start/tool.complete). Voice turns rely on
            // the same event to finish speaking, so a job treats it as final.
            jobs[index].status = .finished
            jobs[index].result = content
        case .messageError(_, let message):
            jobs[index].status = .failed(message)
        case .messageInterrupted:
            // Conduit's own cancel marks the job before interrupting, so an
            // interruption reaching an active job came from elsewhere.
            jobs[index].status = .cancelled
        default:
            return
        }
        if jobs[index] != before { noticeMayBePending() }
    }

    private static func sessionID(for event: StreamEvent) -> String? {
        switch event {
        case .messageStart(let id), .messageDelta(let id, _), .reasoningDelta(let id, _),
             .messageComplete(let id, _, _, _), .messageError(let id, _), .messageInterrupted(let id),
             .toolStart(let id, _, _, _), .toolComplete(let id, _, _, _),
             .approval(let id, _), .clarify(let id, _):
            return id
        default:
            return nil
        }
    }

    // MARK: Delivery

    func takePendingNotice() -> VoiceBackgroundJobNotice? {
        defer { pruneSettledJobs() }
        for index in jobs.indices {
            let job = jobs[index]
            if job.status == .needsInput, !job.inputRequestDelivered {
                jobs[index].inputRequestDelivered = true
                return .speak(AppLocalization.string("\(job.title) is waiting for your approval or an answer. Open it in Conduit to respond."))
            }
            guard !job.status.isActive, !job.outcomeDelivered else { continue }
            jobs[index].outcomeDelivered = true
            switch job.status {
            case .finished:
                let openChat = AppLocalization.string("\(job.title) has finished. Open it in Conduit to read the result.")
                guard let result = job.result?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !result.isEmpty else {
                    return .speak(openChat)
                }
                return .submit(prompt: Self.completionPrompt(title: job.title, result: result), fallback: openChat)
            case .failed:
                return .speak(AppLocalization.string("\(job.title) failed. Open it in Conduit for details."))
            case .cancelled:
                return .speak(AppLocalization.string("\(job.title) was cancelled."))
            case .starting, .running, .needsInput:
                continue
            }
        }
        return nil
    }

    private func noticeMayBePending() {
        stopPollingIfIdle()
        onNoticePending?()
    }

    // MARK: Liveness poll

    /// Fallback for completions the event stream never delivered (the
    /// socket reconnected mid-job, or the runtime was rebound by opening the
    /// job's chat). `session.active_list` is read-only and authoritative
    /// about absence.
    private func startPollingIfNeeded() {
        guard pollTask == nil, activeJobCount > 0 else { return }
        let generation = generation
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                await self.pollOnce()
                guard generation == self.generation else { return }
                if self.activeJobCount == 0 {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    private func stopPollingIfIdle() {
        guard activeJobCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func pollOnce() async {
        let generation = generation
        guard let rows = try? await backend.liveSessions(), generation == self.generation else { return }
        var changed = false
        for index in jobs.indices where jobs[index].status == .running || jobs[index].status == .needsInput {
            let job = jobs[index]
            let row = rows.first { job.owns(sessionID: $0.runtimeSessionId) || job.owns(sessionID: $0.storedSessionId) }
            if let row {
                jobs[index].consecutiveMissedPolls = 0
                // A listed, idle runtime is positive evidence the turn ended.
                if row.isRunning || row.status == "starting" { continue }
            } else {
                // Absence is only trusted when it repeats: a row missing
                // from one read must not discard the real completion.
                jobs[index].consecutiveMissedPolls += 1
                if jobs[index].consecutiveMissedPolls < Self.missedPollsBeforeSettling { continue }
            }
            jobs[index].status = .finished
            changed = true
        }
        if changed { noticeMayBePending() }
    }

    // MARK: Helpers

    /// Keeps the ledger bounded over a long conversation: only the most
    /// recent settled-and-announced jobs stay listed. Active jobs and
    /// outcomes still waiting to be delivered are never dropped.
    private func pruneSettledJobs() {
        let settled = jobs.filter { !$0.status.isActive && $0.outcomeDelivered }
        let excess = settled.count - Self.maximumSettledJobs
        guard excess > 0 else { return }
        let dropped = Set(settled.prefix(excess).map(\.id))
        jobs.removeAll { dropped.contains($0.id) }
    }

    private func job(_ id: UUID) -> VoiceBackgroundJob? {
        jobs.first { $0.id == id }
    }

    private func update(_ id: UUID, _ change: (inout VoiceBackgroundJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    /// A readable session title: the task itself, cut at a word boundary.
    static func title(for instructions: String) -> String {
        let collapsed = instructions
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maximumTitleCharacters else { return collapsed }
        let cut = collapsed.prefix(maximumTitleCharacters)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maximumTitleCharacters / 2 {
            return String(cut[..<space]) + "…"
        }
        return String(cut) + "…"
    }

    /// The first message of a job session. Written for the model, not shown
    /// as UI copy, so it is not localized.
    static func jobPrompt(for instructions: String) -> String {
        """
        [Background job started from a Conduit voice conversation. Nobody is watching this chat live, so work on it on your own. When you are done, end your final message with a short plain-language summary that can be read aloud.]

        \(instructions)
        """
    }

    /// The hand-back submitted to the voice conversation's own session.
    static func completionPrompt(title: String, result: String) -> String {
        let clipped: String
        if result.count > maximumResultCharacters {
            clipped = String(result.prefix(maximumResultCharacters)) + "\n[…]"
        } else {
            clipped = result
        }
        return """
        [Background job "\(title)" finished. Its final message is below. Tell me the outcome in a few spoken sentences, in the language we have been speaking.]

        \(clipped)
        """
    }
}
