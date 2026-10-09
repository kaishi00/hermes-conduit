//
//  GatewayRestart.swift
//  Conduit
//
//  Restart Gateway: asks the dashboard for its own restart action
//  (POST /api/gateway/restart, which runs `hermes gateway restart` on the
//  host) and watches the gateway come back through that action's log
//  (/api/actions/gateway-restart/status) and /api/status, the way Hermes'
//  dashboard and Desktop do.
//

import Foundation

/// Where a Restart Gateway request stands, shown in the chat's Gateway sheet
/// and in Settings > Gateway.
enum GatewayRestartState: Equatable {
    case idle
    /// The restart request is on its way to the dashboard.
    case requesting
    /// Hermes took the request and Conduit is watching the gateway come
    /// back. `detail` is the newest line of Hermes' restart log, verbatim.
    case restarting(GatewayRestartStage, detail: String?)
    /// The gateway is back. `sharedProfiles` names every profile a shared
    /// gateway serves (two or more), since all of them reconnected.
    case restarted(sharedProfiles: [String])
    /// Hermes turned the request down or the restart failed. `detail` is
    /// Hermes' own words when it gave any.
    case failed(detail: String?)
    /// The restart finished but the gateway reports that it failed to start.
    case failedToStart
    /// The gateway didn't report back while Conduit watched.
    case notBackYet
    /// This Hermes has no restart action on its dashboard.
    case unsupported

    var isInProgress: Bool {
        switch self {
        case .requesting, .restarting: return true
        default: return false
        }
    }
}

/// Restart Gateway's state and the dashboard it belongs to. A restart
/// belongs to the dashboard it started on, and every other dashboard sees
/// nothing. Each restart gets its own id, so a step or an outcome from an
/// older restart never lands on a newer one.
struct GatewayRestartSlot: Equatable {
    private(set) var state: GatewayRestartState = .idle
    private(set) var dashboardID: UUID?
    private var restartID: UUID?

    func state(on activeDashboardID: UUID?) -> GatewayRestartState {
        dashboardID == activeDashboardID ? state : .idle
    }

    /// Starts a restart on `dashboardID` and returns its id.
    mutating func start(on dashboardID: UUID?) -> UUID {
        let id = UUID()
        restartID = id
        self.dashboardID = dashboardID
        state = .requesting
        return id
    }

    mutating func update(_ newState: GatewayRestartState, restart id: UUID) {
        guard restartID == id else { return }
        state = newState
    }

    /// How restart `id` ended. When another dashboard is in use by then, or
    /// the restart was dropped (`.idle`), nothing is kept: going back to
    /// that dashboard mustn't find a restart stuck in progress.
    mutating func finish(_ outcome: GatewayRestartState, restart id: UUID, activeDashboardID: UUID?) {
        guard restartID == id else { return }
        if outcome != .idle, dashboardID == activeDashboardID {
            state = outcome
        } else {
            clear()
        }
    }

    /// Clears a finished restart's outcome. A restart in progress stays.
    mutating func dismiss() {
        guard !state.isInProgress else { return }
        clear()
    }

    private mutating func clear() {
        state = .idle
        dashboardID = nil
        restartID = nil
    }
}

enum GatewayRestartStage: Equatable {
    /// The old gateway is finishing running work before it stops.
    case draining
    /// The old gateway is still up.
    case stopping
    /// The old gateway is gone and Hermes is starting a new one.
    case starting
}

/// The gateway fields of `/api/status` a restart watches.
struct GatewayRestartGatewayStatus: Equatable {
    var running: Bool
    var state: String?
    /// Only reported on a loopback or `--insecure` dashboard.
    var pid: Int?
    /// Every profile a shared gateway serves, when it serves two or more.
    var sharedProfiles: [String]

    init(running: Bool, state: String? = nil, pid: Int? = nil, sharedProfiles: [String] = []) {
        self.running = running
        self.state = state
        self.pid = pid
        self.sharedProfiles = sharedProfiles
    }

    init?(json: [String: Any]) {
        guard let running = json["gateway_running"] as? Bool else { return nil }
        self.init(
            running: running,
            state: json["gateway_state"] as? String,
            pid: json["gateway_pid"] as? Int,
            sharedProfiles: Self.sharedProfiles(from: json["gateway_shared_with"])
        )
    }

    /// Up and serving: running, and neither starting, failed, nor draining
    /// for a restart. A degraded gateway (some channels offline) is up.
    var isServing: Bool {
        guard running else { return false }
        switch state?.lowercased() {
        case "starting", "stopped", "startup_failed", "draining": return false
        default: return true
        }
    }

    /// `gateway_shared_with` as Hermes' dashboard shows it: unique names,
    /// default first, the rest sorted; empty unless two or more share it.
    static func sharedProfiles(from value: Any?) -> [String] {
        guard let raw = value as? [Any] else { return [] }
        var seen = Set<String>()
        let names = raw
            .map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard names.count >= 2 else { return [] }
        return names.sorted { lhs, rhs in
            if lhs == "default" { return rhs != "default" }
            if rhs == "default" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

/// `/api/actions/gateway-restart/status`: the restart child and its log.
struct GatewayRestartActionStatus: Equatable {
    var running: Bool
    var exitCode: Int?
    var lines: [String]

    init(running: Bool, exitCode: Int? = nil, lines: [String] = []) {
        self.running = running
        self.exitCode = exitCode
        self.lines = lines
    }

    init?(json: [String: Any]) {
        guard let running = json["running"] as? Bool else { return nil }
        self.init(
            running: running,
            exitCode: json["exit_code"] as? Int,
            lines: (json["lines"] as? [Any] ?? []).map { String(describing: $0) }
        )
    }

    /// The newest log line worth showing, skipping blanks and the
    /// dashboard's `=== gateway-restart started … ===` banners.
    var latestLine: String? {
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("===") else { continue }
            return trimmed.count > 240 ? String(trimmed.prefix(240)) + "…" : trimmed
        }
        return nil
    }
}

/// Decides, poll by poll, whether a restarted gateway is back.
///
/// Hermes' own rule is that the restart child exiting 0 is success, and a
/// child still running after a short wait is too: with no service manager
/// it becomes the gateway and never exits. Conduit also wants the gateway
/// serving in `/api/status` before it says so, and takes the gateway going
/// down, or a new PID, as the restart having happened.
struct GatewayRestartMonitor {
    enum Verdict: Equatable {
        case waiting(GatewayRestartStage)
        case back(GatewayRestartGatewayStatus)
        case failed(detail: String?)
        case failedToStart
        case notBackYet
    }

    /// After this long, a serving gateway counts as back even though the
    /// restart child is still running (Hermes' dashboard waits about 22 s).
    static let runningChildGrace: TimeInterval = 30
    /// How long a gateway has to come back once the restart child is done.
    static let comeBackWindow: TimeInterval = 90
    /// When Conduit stops watching however the restart is going. Hermes
    /// lets running turns finish first, which can take minutes.
    static let watchLimit: TimeInterval = 600

    let before: GatewayRestartGatewayStatus?
    private(set) var sawDown = false
    private(set) var childFinishedAt: TimeInterval?

    init(before: GatewayRestartGatewayStatus?) {
        self.before = before
    }

    /// `action` and `gateway` are nil when that read failed or isn't
    /// available; `elapsed` counts from when Hermes took the request.
    mutating func observe(
        action: GatewayRestartActionStatus?,
        gateway: GatewayRestartGatewayStatus?,
        elapsed: TimeInterval
    ) -> Verdict {
        if let action, !action.running, let exitCode = action.exitCode {
            if exitCode != 0 { return .failed(detail: action.latestLine) }
            if childFinishedAt == nil { childFinishedAt = elapsed }
        }
        if before?.running == false || gateway?.running == false { sawDown = true }

        if let gateway, gateway.isServing {
            if childFinishedAt != nil || sawDown || hasNewProcess(gateway) || elapsed >= Self.runningChildGrace {
                return .back(gateway)
            }
        }

        let outOfTime = elapsed >= Self.watchLimit
            || childFinishedAt.map { elapsed - $0 >= Self.comeBackWindow } == true
        if outOfTime {
            return gateway?.state?.lowercased() == "startup_failed" ? .failedToStart : .notBackYet
        }
        if sawDown || childFinishedAt != nil { return .waiting(.starting) }
        return .waiting(gateway?.state?.lowercased() == "draining" ? .draining : .stopping)
    }

    private func hasNewProcess(_ gateway: GatewayRestartGatewayStatus) -> Bool {
        guard let oldPID = before?.pid, let newPID = gateway.pid else { return false }
        return oldPID != newPID
    }
}

/// Runs one Restart Gateway: the request, then polls until the gateway is
/// back, the restart fails, or Conduit stops watching.
@MainActor
struct GatewayRestarter {
    typealias Request = @MainActor (_ path: String, _ method: String) async throws -> [String: Any]

    static let restartPath = "/api/gateway/restart"
    static let actionStatusPath = "/api/actions/gateway-restart/status?lines=20"
    static let statusPath = "/api/status"

    let request: Request
    var pollInterval: Duration = .milliseconds(1_500)
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @MainActor () -> Date = { Date() }

    /// Reports each step to `progress` and returns how it ended. Returns
    /// `.idle` when cancelled.
    func run(progress: (GatewayRestartState) -> Void) async -> GatewayRestartState {
        progress(.requesting)
        let before = await gatewayStatus()
        do {
            _ = try await self.request(Self.restartPath, "POST")
        } catch {
            if Task.isCancelled { return .idle }
            return Self.outcome(forRequestError: error)
        }

        let started = self.now()
        var monitor = GatewayRestartMonitor(before: before)
        var actionLogAvailable = true
        var latestLine: String?
        progress(.restarting(.stopping, detail: nil))
        while true {
            do { try await self.sleep(pollInterval) } catch { return .idle }
            if Task.isCancelled { return .idle }

            var action: GatewayRestartActionStatus?
            if actionLogAvailable {
                do {
                    let json = try await self.request(Self.actionStatusPath, "GET")
                    action = GatewayRestartActionStatus(json: json)
                } catch {
                    // A Hermes without the action log still restarts; watch
                    // /api/status alone. Anything else is a missed poll.
                    if Self.httpStatus(of: error) == 404 { actionLogAvailable = false }
                }
            }
            let gateway = await gatewayStatus()
            if Task.isCancelled { return .idle }
            latestLine = action?.latestLine ?? latestLine

            let elapsed = self.now().timeIntervalSince(started)
            switch monitor.observe(action: action, gateway: gateway, elapsed: elapsed) {
            case .waiting(let stage):
                progress(.restarting(stage, detail: latestLine))
            case .back(let status):
                return .restarted(sharedProfiles: status.sharedProfiles)
            case .failed(let detail):
                return .failed(detail: detail)
            case .failedToStart:
                return .failedToStart
            case .notBackYet:
                return .notBackYet
            }
        }
    }

    private func gatewayStatus() async -> GatewayRestartGatewayStatus? {
        guard let json = try? await self.request(Self.statusPath, "GET") else { return nil }
        return GatewayRestartGatewayStatus(json: json)
    }

    /// A refused restart request: a dashboard without the route predates
    /// the action, anything else is Hermes' own failure.
    static func outcome(forRequestError error: Error) -> GatewayRestartState {
        switch httpStatus(of: error) {
        case 404, 405, 501: return .unsupported
        default: return .failed(detail: UserFacingError.message(for: error))
        }
    }

    static func httpStatus(of error: Error) -> Int? {
        if case DashboardTicketBridgeError.http(let status, _) = error { return status }
        return nil
    }
}
