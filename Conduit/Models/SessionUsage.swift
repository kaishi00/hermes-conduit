//
//  SessionUsage.swift
//  Conduit
//
//  One chat's tokens and cost (issue 2699), for the Context sheet and the
//  chat list's Usage Details. The notifier plugin reads them from Hermes'
//  sessions table (`GET /sessions/usage`, plugin 0.177.34+): the chat's row,
//  the rows its compressions continued it into, and the subagent runs it
//  started. Hermes keeps the numbers; Conduit only reads them.
//

import Foundation

struct SessionUsage: Equatable {
    /// How Hermes priced the chat, from each row's `cost_status`.
    enum CostStatus: String, Equatable {
        /// What the provider billed.
        case actual
        /// Hermes' estimate from its pricing table.
        case estimated
        /// A plan that doesn't bill per token.
        case included
        /// Some calls were priced and some weren't: the cost is a floor.
        case partial
        /// No call was priced. Never shown as $0.
        case unknown
    }

    static let capability = "session-usage"
    static let path = "/api/plugins/conduit_push/sessions/usage"

    var input = 0
    var output = 0
    var cacheRead = 0
    var reasoning = 0
    var apiCalls = 0
    var toolCalls = 0
    var compressions = 0
    var subagentRuns = 0
    var model = ""
    var startedAt: Date?
    /// Nil when no call was priced (`unknown`).
    var costUSD: Double?
    var costStatus: CostStatus = .unknown

    /// The route for one chat, without its profile, which the request adds
    /// (`DashboardPath.withProfile`).
    static func route(sessionID: String) -> String? {
        guard let id = DashboardPath.encodedQueryComponent(sessionID) else { return nil }
        return "\(path)?session_id=\(id)"
    }

    init(response: [String: Any]) {
        input = UsageReport.int(response["input_tokens"])
        output = UsageReport.int(response["output_tokens"])
        cacheRead = UsageReport.int(response["cache_read_tokens"])
        reasoning = UsageReport.int(response["reasoning_tokens"])
        apiCalls = UsageReport.int(response["api_call_count"])
        toolCalls = UsageReport.int(response["tool_call_count"])
        compressions = UsageReport.int(response["compressions"])
        subagentRuns = UsageReport.int(response["subagent_runs"])
        model = (response["model"] as? String) ?? ""
        if let started = (response["started_at"] as? NSNumber)?.doubleValue, started.isFinite, started > 0 {
            startedAt = Date(timeIntervalSince1970: started)
        }
        costStatus = (response["cost_status"] as? String).flatMap(CostStatus.init(rawValue:)) ?? .unknown
        // A number only where Hermes priced something: an unknown cost stays
        // nil even if a host ever sends 0 with it.
        if costStatus != .unknown, let cost = response["cost_usd"] as? NSNumber, cost.doubleValue.isFinite {
            costUSD = cost.doubleValue
        }
    }

    init() {}
}

/// What a read of one chat's usage came to.
enum SessionUsageReadout: Equatable {
    case loaded(SessionUsage)
    /// Hermes has no row for the chat yet: nothing has run in it.
    case nothingYet
    /// The host's plugin predates the route.
    case needsPluginUpdate
    /// Why it can't be read, in words the user can act on (the plugin
    /// turned off for the chat's profile).
    case unavailable(String)
    case failed
}

extension SessionUsageReadout {
    /// The notifier's answer for a chat with no row (session_usage.py).
    static let missingSessionDetail = "Session not found"

    /// What a 404 from the usage route means, by its detail.
    static func notFound(detail: String, path: String) -> SessionUsageReadout {
        // Hermes has no row for the chat yet: nothing has run in it.
        if detail.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(missingSessionDetail) == .orderedSame {
            return .nothingYet
        }
        // The plugin turned off for the profile the read named: its remedy.
        if let remedy = DashboardTicketBridgeError.pluginOffDetail(
            of: DashboardTicketBridgeError.http(status: 404, detail: detail), path: path
        ) {
            return .unavailable(remedy)
        }
        // No such route on the host that answered (another profile's plugin
        // host can be older than the dashboard's report).
        return .needsPluginUpdate
    }
}
