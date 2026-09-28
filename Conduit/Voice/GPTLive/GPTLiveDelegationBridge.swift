//
//  GPTLiveDelegationBridge.swift
//  Conduit
//
//  GPT-Live has no tools of its own on the subscription: when the user asks
//  for real work, the model emits a delegation and waits for the client's
//  answer. Conduit runs each delegation as a Hermes background job through
//  the same VoiceBackgroundJobSupervisor as the other voice modes, answers
//  the delegation with quiet progress ("commentary"), and hands the job's
//  outcome back on it as "speakable" context once it settles. Hermes stays
//  the worker; approvals are never given by voice.
//
//  Job updates with no delegation left to answer (a job started before a
//  reconnect, a job waiting for input) go out as session context, only
//  while the conversation is idle.
//

import Foundation

@MainActor
final class GPTLiveDelegationBridge {
    /// What the bridge asks the conversation to send.
    enum Outgoing: Equatable {
        /// An answer on an open delegation.
        case delegationReply(delegationID: String, text: String, channel: GPTLiveProtocol.Channel)
        /// Session-wide context. `whenIdle` ones wait until nobody speaks.
        case sessionContext(text: String, channel: GPTLiveProtocol.Channel, whenIdle: Bool)
    }

    private let supervisor: GeminiLiveJobSupervising
    /// Open delegations, keyed by the job answering them.
    private var openDelegations: [UUID: String] = [:]
    /// Delegations already seen, so a repeated event never starts a second job.
    private var seenDelegations: Set<String> = []
    private(set) var isEnding = false

    init(supervisor: GeminiLiveJobSupervising) {
        self.supervisor = supervisor
    }

    var openDelegationCount: Int { openDelegations.count }

    // MARK: Delegations

    /// Starts the Hermes job for a delegation. `request` is the work, from
    /// the delegation itself or the user's recent words.
    func handleDelegation(id: String, request: String) async -> [Outgoing] {
        guard seenDelegations.insert(id).inserted, !isEnding else { return [] }
        let instructions = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else {
            return [.delegationReply(delegationID: id, text: Self.relay("Hermes didn't get a request to work on. Ask the user what they want done."), channel: .speakable)]
        }
        var createdJobID: UUID?
        let reply = await supervisor.startJob(instructions: instructions) { [weak self] jobID in
            createdJobID = jobID
            guard self?.isEnding == false else { return }
            self?.openDelegations[jobID] = id
        }
        if isEnding {
            // Ending while it started: its outcome stays pending for Hermes.
            if let jobID = createdJobID { openDelegations[jobID] = nil }
            return []
        }
        guard let jobID = createdJobID else {
            // Refused (too many jobs): tell the user now.
            return [.delegationReply(delegationID: id, text: Self.relay(reply), channel: .speakable)]
        }
        guard openDelegations[jobID] == id else { return [] }
        var outgoing: [Outgoing] = []
        if let job = supervisor.jobs.first(where: { $0.id == jobID }), job.status.isActive {
            outgoing.append(.delegationReply(
                delegationID: id,
                text: "Hermes is working on this as a background job (\"\(job.title)\"). Its result will follow on this delegation; don't guess it.",
                channel: .commentary
            ))
        }
        return outgoing + settleOpenDelegations()
    }

    /// The call ended or was replaced: open delegations can no longer be
    /// answered, so their outcomes go out as session context later.
    func connectionReplaced() {
        openDelegations.removeAll()
        seenDelegations.removeAll()
        isEnding = false
    }

    /// The conversation is ending: nothing is settled, so every outcome
    /// stays pending (and unannounced) for Hermes to report.
    func beginEnding() {
        openDelegations.removeAll()
        isEnding = true
    }

    // MARK: Job updates

    /// Everything deliverable now: settled delegations first, then any other
    /// pending job notice as idle session context.
    func pendingUpdates() -> [Outgoing] {
        var outgoing = settleOpenDelegations()
        guard !isEnding else { return outgoing }
        while let item = supervisor.takePendingNoticeForJob() {
            let text: String
            switch item.notice {
            case .speak(let spoken): text = Self.relay(spoken)
            case .submit(let prompt, _): text = prompt
            }
            queuedNotices.append((text, item.jobID))
            outgoing.append(.sessionContext(text: text, channel: .speakable, whenIdle: true))
        }
        return outgoing
    }

    /// Job notices handed out but not yet sent, so they can be handed back
    /// if the conversation closes first.
    private var queuedNotices: [(text: String, jobID: UUID)] = []

    /// A queued notice went out: its job is spoken for.
    func contextDelivered(_ text: String) {
        guard let index = queuedNotices.firstIndex(where: { $0.text == text }) else { return }
        supervisor.noticeSent(jobID: queuedNotices.remove(at: index).jobID)
    }

    /// These notices will never be sent: their jobs become pending again.
    func returnUnsent(_ texts: [String]) {
        for text in texts {
            guard let index = queuedNotices.firstIndex(where: { $0.text == text }) else { continue }
            supervisor.returnUndeliveredNotice(jobID: queuedNotices.remove(at: index).jobID)
        }
    }

    /// A delegation answer that never reached GPT-Live: its outcome becomes
    /// pending again, for the next conversation or Hermes to report.
    func replyUndelivered(delegationID: String) {
        guard let jobID = deliveredReplies.removeValue(forKey: delegationID) else { return }
        supervisor.returnUndeliveredNotice(jobID: jobID)
    }

    /// A delegation answer reached GPT-Live.
    func replyDelivered(delegationID: String) {
        deliveredReplies[delegationID] = nil
    }

    /// Settled delegations whose answer is on its way, by delegation.
    private var deliveredReplies: [String: UUID] = [:]

    private func settleOpenDelegations() -> [Outgoing] {
        guard !isEnding else { return [] }
        var outgoing: [Outgoing] = []
        for (jobID, delegationID) in openDelegations.sorted(by: { $0.value < $1.value }) {
            guard let job = supervisor.jobs.first(where: { $0.id == jobID }) else {
                openDelegations[jobID] = nil
                continue
            }
            guard !job.status.isActive else { continue }
            openDelegations[jobID] = nil
            supervisor.markOutcomeDelivered(jobID: jobID)
            deliveredReplies[delegationID] = jobID
            outgoing.append(.delegationReply(delegationID: delegationID, text: Self.outcome(of: job), channel: .speakable))
        }
        return outgoing
    }

    /// A settled job's outcome, for the model to say in its own words.
    static func outcome(of job: VoiceBackgroundJob) -> String {
        switch job.status {
        case .finished:
            if let text = job.result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return VoiceBackgroundJobSupervisor.completionPrompt(title: job.title, result: GeminiLiveToolBridge.clipped(text))
            }
            return relay(AppLocalization.string("\(job.title) has finished. Open it in Conduit to read the result."))
        case .failed(let message):
            return relay(AppLocalization.string("\(job.title) failed. Open it in Conduit for details.") + " (\(message))")
        case .cancelled:
            return relay(AppLocalization.string("\(job.title) was cancelled."))
        case .starting, .running, .needsInput:
            return relay(AppLocalization.string("\(job.title) is waiting for your approval or an answer. Open it in Conduit to respond."))
        }
    }

    /// The jobs' state as quiet context, so the model can answer "how's it
    /// going" itself. Not UI copy.
    func statusContext() -> String {
        let visible = supervisor.jobs.filter { $0.status.isActive || !$0.outcomeDelivered }
        guard !visible.isEmpty else { return "[Background jobs: none running.]" }
        let lines = visible.map { "\($0.title): \(GeminiLiveToolBridge.statusName($0.status))" }
        return "[Background jobs on Hermes: " + lines.joined(separator: "; ") + ".]"
    }

    /// Wraps a fixed notice for the model. Not UI copy, so not localized.
    static func relay(_ notice: String) -> String {
        GeminiLiveToolBridge.relayPrompt(notice)
    }
}
