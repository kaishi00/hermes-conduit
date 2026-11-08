//
//  SavedVoiceJob.swift
//  Conduit
//
//  A voice call's background job as the ledger keeps it across a relaunch
//  (Bot workstreams M5b): the job runs on in its own Hermes session while
//  the app is closed, and the next run follows it from where it was.
//

import Foundation

struct SavedVoiceJob: Codable, Equatable {
    enum State: String, Codable {
        case running, finished, failed, cancelled
    }

    var id: UUID
    var title: String
    var instructions: String
    var profile: String?
    var profileLabel: String?
    var runtimeSessionID: String
    var storedSessionID: String?
    var state: State
    var failure: String?
    var result: String?
    var startedAt: Date
    var number: Int
    var callsBackWhenDone: Bool
    var callChatIDs: [String]
    var ledgerKey: String?

    init?(_ job: VoiceBackgroundJob) {
        guard let runtimeID = job.runtimeSessionID, !runtimeID.isEmpty else { return nil }
        switch job.status {
        case .starting, .running, .needsInput: state = .running
        case .finished: state = .finished
        case .failed(let message): state = .failed; failure = message
        case .cancelled: state = .cancelled
        }
        id = job.id
        title = job.title
        instructions = job.instructions
        profile = job.profile
        profileLabel = job.profileLabel
        runtimeSessionID = runtimeID
        storedSessionID = job.storedSessionID
        result = job.result
        startedAt = job.startedAt
        number = job.number
        callsBackWhenDone = job.callsBackWhenDone
        callChatIDs = job.callChatIDs
        ledgerKey = job.ledgerKey
    }

    /// The job as the ledger takes it back: running until the poll or an
    /// event settles it (a question it waited on is asked again by Hermes'
    /// own events), its outcome not yet heard, and no call back asked.
    var job: VoiceBackgroundJob? {
        let status: VoiceBackgroundJob.Status
        switch state {
        case .running: status = .running
        case .finished: status = .finished
        case .failed: status = .failed(failure ?? "")
        case .cancelled: status = .cancelled
        }
        var job = VoiceBackgroundJob(
            id: id,
            title: title,
            instructions: instructions,
            profile: profile,
            profileLabel: profileLabel,
            runtimeSessionID: runtimeSessionID,
            storedSessionID: storedSessionID,
            status: status,
            result: result,
            startedAt: startedAt
        )
        job.number = number
        job.requestSent = true
        // Hermes' watch for a call back lapsed with the run that asked.
        job.callsBackWhenDone = false
        job.callChatIDs = callChatIDs
        job.ledgerKey = ledgerKey
        job.isRestored = true
        return job
    }

    static func decode(_ data: Data?) -> [SavedVoiceJob] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([SavedVoiceJob].self, from: data)) ?? []
    }
}
