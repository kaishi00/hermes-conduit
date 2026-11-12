//
//  AuthorityQueue.swift
//  Conduit
//
//  A chat's queue on the gateway's own listener (the Webapp, `hermes
//  webapp`): every send joins it, a send into a running turn waits there as
//  `queued`, and a turn a gateway restart cut off is `unknown` and holds
//  every later message until someone discards it. Hermes lists it as the
//  chat's `pending` (in `session.resume` and in the `session.info` it pushes
//  on every change); `hermes dashboard` has no such list.
//

import Combine
import Foundation

/// One row of a chat's `pending` list (Hermes' PendingAdmission).
struct QueuedPrompt: Equatable, Identifiable {
    enum Status: String {
        /// Waiting its turn.
        case queued
        /// Its turn runs now (or it went into the running turn).
        case started
        /// Its turn was cut off by a gateway restart: nothing after it runs
        /// until it is discarded.
        case unknown
        /// Settled.
        case terminal
    }

    /// Hermes' id for the admission, which the queue verbs name.
    let admissionID: String
    /// The id the send went with (Conduit's `submission_id`).
    let inputID: String
    let text: String
    let status: Status
    /// The turn it ran as; a lost turn's discard names it.
    let executionGeneration: Int?
    /// Place in line.
    let sequence: Int
    /// `prompt.steer_queued` (Send now) is served for it.
    let canSendNow: Bool
    /// `prompt.replace_queued` (Edit) is served for it.
    let canEdit: Bool
    /// On its way into the running turn.
    let steering: Bool

    var id: String { admissionID }

    init(
        admissionID: String, inputID: String = "", text: String, status: Status,
        executionGeneration: Int? = nil, sequence: Int = 0,
        canSendNow: Bool = false, canEdit: Bool = false, steering: Bool = false
    ) {
        self.admissionID = admissionID
        self.inputID = inputID
        self.text = text
        self.status = status
        self.executionGeneration = executionGeneration
        self.sequence = sequence
        self.canSendNow = canSendNow
        self.canEdit = canEdit
        self.steering = steering
    }

    init?(object: [String: AnyCodable]) {
        guard let admissionID = object["admission_id"]?.stringValue, !admissionID.isEmpty,
              let status = object["status"]?.stringValue.flatMap(Status.init(rawValue:)) else { return nil }
        let controls = Set((object["controls"]?.arrayValue ?? []).compactMap(\.stringValue))
        self.init(
            admissionID: admissionID,
            inputID: object["input_id"]?.stringValue ?? "",
            text: object["text"]?.stringValue ?? "",
            status: status,
            executionGeneration: HermesClient.exactIntValue(object["execution_generation"]),
            sequence: HermesClient.exactIntValue(object["sequence"]) ?? 0,
            canSendNow: controls.contains("steer"),
            canEdit: controls.contains("replace"),
            steering: object["steering"]?.boolValue == true
        )
    }

    /// The chat's queue from a snapshot's `pending`, oldest first; nil when
    /// the snapshot has no such list (the dashboard's, or a `session.info`
    /// that isn't about the queue), which says nothing about it.
    static func list(from value: AnyCodable?) -> [QueuedPrompt]? {
        guard let rows = value?.arrayValue else { return nil }
        return rows.compactMap { $0.objectValue.flatMap(QueuedPrompt.init(object:)) }
            .sorted { $0.sequence < $1.sequence }
    }
}

/// What a queue verb's receipt says (Hermes' AdmissionReceipt).
struct QueuedPromptReceipt: Equatable {
    let admissionID: String
    let status: QueuedPrompt.Status?
    /// `cancelled`, `interrupted`, … once settled.
    let outcome: String?

    init(object: [String: AnyCodable]) {
        admissionID = object["admission_id"]?.stringValue ?? ""
        status = object["status"]?.stringValue.flatMap(QueuedPrompt.Status.init(rawValue:))
        outcome = object["outcome"]?.stringValue
    }
}

/// The open chat's queue, for the dock above the composer. Kept apart from
/// AppState so a queue change redraws the dock, not the chat.
@MainActor
final class AuthorityQueueStore: ObservableObject {
    /// The chat the rows belong to (its runtime id).
    @Published private(set) var sessionID: String?
    /// Every row Hermes listed, oldest first.
    @Published private(set) var rows: [QueuedPrompt] = []
    /// Rows with an action on its way: their buttons wait.
    @Published private(set) var working: Set<String> = []
    /// Why the last action didn't go, until the next action or another chat.
    @Published var notice: String?

    /// Messages waiting their turn.
    var queued: [QueuedPrompt] { rows.filter { $0.status == .queued && !$0.steering } }
    /// Turns a restart cut off.
    var lost: [QueuedPrompt] { rows.filter { $0.status == .unknown } }
    var isEmpty: Bool { queued.isEmpty && lost.isEmpty }

    func apply(_ rows: [QueuedPrompt], for sessionID: String) {
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            working = []
            notice = nil
        }
        guard self.rows != rows else { return }
        self.rows = rows
        // A row Hermes no longer lists has nothing left to wait for.
        working.formIntersection(Set(rows.map(\.admissionID)))
    }

    /// Another chat opened, or the socket isn't the authority's.
    func clear() {
        guard sessionID != nil || !rows.isEmpty || notice != nil else { return }
        sessionID = nil
        rows = []
        working = []
        notice = nil
    }

    func row(_ admissionID: String) -> QueuedPrompt? {
        rows.first { $0.admissionID == admissionID }
    }

    func setWorking(_ admissionID: String, _ isWorking: Bool) {
        if isWorking { working.insert(admissionID) } else { working.remove(admissionID) }
    }

    /// A row the user just acted on leaves the dock at once; the next push
    /// from Hermes is the truth either way.
    func drop(_ admissionID: String) {
        rows.removeAll { $0.admissionID == admissionID }
        working.remove(admissionID)
    }
}
