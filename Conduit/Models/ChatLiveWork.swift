//
//  ChatLiveWork.swift
//  Conduit
//
//  The open chat's turn running in the gateway, as `hermes dashboard`
//  can't show it (Eric, 2026-11-27): an API chat's turn, another app's on the
//  Webapp, one a send of this phone's was forwarded behind. The dashboard
//  hands a message sent into such a turn to the gateway's queue and keeps
//  no queue of its own, and the turn's progress, its delegate agents'
//  included, streams only to the client that started it. The notifier
//  plugin reads both where they are (`GET /sessions/live-work`, plugin
//  0.202.11+): whether a turn runs there, its step and its delegate agents'
//  own steps, and the messages queued behind it.
//

import Foundation

struct ChatLiveWork: Equatable {
    static let capability = "chat-live-work"
    static let path = "/api/plugins/conduit_push/sessions/live-work"
    /// Between two reads while a turn runs there or a message waits.
    static let refreshInterval: Duration = .seconds(5)

    /// One of the running turn's delegate agents.
    struct Agent: Equatable, Identifiable {
        /// Its own session.
        let id: String
        let goal: String
        let step: BotLiveStep
        /// When it started (Unix seconds).
        let started: Double?
    }

    /// A turn of the chat runs in the gateway.
    var running = false
    /// What it does now.
    var step: BotLiveStep?
    var agents: [Agent] = []
    /// The messages waiting behind it (and a turn a restart cut off),
    /// oldest first. The dashboard serves none of the queue's verbs, so
    /// they carry none.
    var queued: [QueuedPrompt] = []
    /// The admissions whose turn runs now: a message that left the queue
    /// for one started; any other was withdrawn or its turn already ended.
    var startedAdmissions: Set<String> = []

    /// Something still to follow: a turn running there, or a message waiting.
    var isActive: Bool { running || !queued.isEmpty }

    /// The route for one chat, without its profile, which the request adds
    /// (`DashboardPath.withProfile`).
    static func route(sessionID: String) -> String? {
        guard let id = DashboardPath.encodedQueryComponent(sessionID) else { return nil }
        return "\(path)?session_id=\(id)"
    }

    init(running: Bool = false, step: BotLiveStep? = nil, agents: [Agent] = [], queued: [QueuedPrompt] = [],
         startedAdmissions: Set<String> = []) {
        self.running = running
        self.step = step
        self.agents = agents
        self.queued = queued
        self.startedAdmissions = startedAdmissions
    }

    init(response: [String: Any]) {
        running = (response["running"] as? Bool) == true
        step = (response["step"] as? [String: Any]).flatMap(Self.step(from:))
        agents = (response["agents"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, let step = Self.step(from: row) else { return nil }
            let goal = (row["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Agent(id: id, goal: goal, step: step, started: (row["started"] as? NSNumber)?.doubleValue)
        }
        queued = (response["queued"] as? [[String: Any]] ?? []).compactMap { row in
            guard let admissionID = row["admission_id"] as? String, !admissionID.isEmpty,
                  let status = (row["status"] as? String).flatMap(QueuedPrompt.Status.init(rawValue:)),
                  status == .queued || status == .unknown else { return nil }
            return QueuedPrompt(
                admissionID: admissionID,
                inputID: row["input_id"] as? String ?? "",
                text: row["text"] as? String ?? "",
                status: status,
                sequence: (row["sequence"] as? NSNumber)?.intValue ?? 0
            )
        }
        .sorted { $0.sequence < $1.sequence }
        startedAdmissions = Set((response["started"] as? [String] ?? []).filter { !$0.isEmpty })
    }

    /// A step as GET /live-steps writes it; nil for a phase it doesn't know.
    static func step(from entry: [String: Any]) -> BotLiveStep? {
        BotLiveStep.steps(listed: ["steps": ["step": entry]])?["step"]
    }
}
