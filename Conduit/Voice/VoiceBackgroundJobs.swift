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

    func startJob(instructions: String) async -> String {
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
        let generation = generation
        do {
            let ids = try await backend.createSession()
            guard generation == self.generation else { throw CancellationError() }
            guard !ids.runtimeID.isEmpty else {
                throw VoiceAudioError.unavailable(AppLocalization.string("Hermes did not return a session."))
            }
            update(job.id) {
                $0.runtimeSessionID = ids.runtimeID
                $0.storedSessionID = ids.storedID
            }
            onJobSessionCreated?([ids.runtimeID, ids.storedID].compactMap { $0 }.filter { !$0.isEmpty })
            await backend.setTitle(ids.runtimeID, job.title)
            guard generation == self.generation else { throw CancellationError() }
            try await backend.submit(ids.runtimeID, Self.jobPrompt(for: instructions))
            guard generation == self.generation else { throw CancellationError() }
            // An event may already have settled the job while submit awaited.
            if self.job(job.id)?.status == .starting {
                update(job.id) { $0.status = .running }
            }
            startPollingIfNeeded()
            return AppLocalization.string("Started a background job: \(job.title).")
        } catch {
            guard generation == self.generation else {
                return AppLocalization.string("Couldn't start the background job.")
            }
            update(job.id) {
                $0.status = .failed(error.localizedDescription)
                // The user heard the failure right here; don't announce it again.
                $0.outcomeDelivered = true
            }
            return AppLocalization.string("Couldn't start the background job.")
        }
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
        let count = targets.count
        return AppLocalization.string("Cancelled \(count) background jobs.")
    }

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
            if let row, row.isRunning || row.status == "starting" { continue }
            jobs[index].status = .finished
            changed = true
        }
        if changed { noticeMayBePending() }
    }

    // MARK: Helpers

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
