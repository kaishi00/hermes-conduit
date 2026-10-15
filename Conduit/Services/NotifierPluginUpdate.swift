//
//  NotifierPluginUpdate.swift
//  Conduit
//
//  Update (or install) the Conduit plugin on the dashboard's host with one
//  tap: Hermes' own plugin route pulls it (POST
//  /api/dashboard/agent-plugins/conduit_push/update, or /install when it
//  isn't there), the gateway restarts so its hooks, tools and skills load
//  (GatewayRestart.swift), and then the dashboard restarts itself through
//  the plugin (POST /api/plugins/conduit_push/self/restart, plugin 0.24+),
//  since Hermes imports a plugin's routes once per dashboard process.
//

import Foundation

/// Where a plugin update stands, for Settings > Conduit plugin and the
/// update notice.
enum NotifierPluginUpdateState: Equatable {
    case idle
    case updating(NotifierPluginUpdateStep)
    /// Done: the dashboard runs `version` now.
    case updated(version: String?)
    /// The new plugin is on the host, but this dashboard can't restart
    /// itself (the plugin that was running predates the restart route, or
    /// Hermes refused it). `detail` is Hermes' own words when it gave any.
    case needsDashboardRestart(detail: String?)
    case failed(detail: String?)
    /// This Hermes has no plugin routes on its dashboard.
    case unsupported

    var isInProgress: Bool {
        if case .updating = self { return true }
        return false
    }
}

enum NotifierPluginUpdateStep: Equatable {
    /// Hermes is pulling the new plugin.
    case downloading
    /// Hermes is installing the plugin for the first time.
    case installing
    /// The gateway restarts to load the plugin's hooks, tools and skills.
    case restartingGateway(GatewayRestartStage?)
    /// The dashboard waits for chats it is running to finish first.
    case waitingForChats(count: Int)
    /// The dashboard restarts to load the plugin's routes.
    case restartingDashboard

    /// Where the step falls in the update, for "Step 2 of 3".
    static let count = 3
    var number: Int {
        switch self {
        case .downloading, .installing: return 1
        case .restartingGateway: return 2
        case .waitingForChats, .restartingDashboard: return 3
        }
    }
}

/// The update's state and the dashboard it belongs to: an update on one
/// dashboard shows nothing on another. Each run has its own id, so a step
/// from an older run never lands on a newer one.
struct NotifierPluginUpdateSlot: Equatable {
    private(set) var state: NotifierPluginUpdateState = .idle
    private(set) var dashboardID: UUID?
    /// When the running update began, for its elapsed time.
    private(set) var startedAt: Date?
    private var runID: UUID?

    func state(on activeDashboardID: UUID?) -> NotifierPluginUpdateState {
        dashboardID == activeDashboardID ? state : .idle
    }

    mutating func start(on dashboardID: UUID?) -> UUID {
        let id = UUID()
        runID = id
        self.dashboardID = dashboardID
        startedAt = Date()
        state = .updating(.downloading)
        return id
    }

    mutating func update(_ newState: NotifierPluginUpdateState, run id: UUID) {
        guard runID == id else { return }
        state = newState
    }

    /// Keeps the outcome only while its dashboard is still the one in use.
    mutating func finish(_ outcome: NotifierPluginUpdateState, run id: UUID, activeDashboardID: UUID?) {
        guard runID == id else { return }
        if outcome != .idle, dashboardID == activeDashboardID {
            state = outcome
        } else {
            clear()
        }
    }

    mutating func dismiss() {
        guard !state.isInProgress else { return }
        clear()
    }

    private mutating func clear() {
        state = .idle
        dashboardID = nil
        startedAt = nil
        runID = nil
    }
}

/// Runs one plugin update from the request to the restarted dashboard.
@MainActor
struct NotifierPluginUpdater {
    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    static let updatePath = "/api/dashboard/agent-plugins/conduit_push/update"
    static let installPath = "/api/dashboard/agent-plugins/install"
    static let selfRestartPath = "/api/plugins/conduit_push/self/restart"
    static let selfRestartCapability = "self-restart"

    /// How long Conduit waits for running chats before the dashboard
    /// restarts. The update is already in place by then.
    static let chatsWaitLimit: TimeInterval = 600
    /// How long the dashboard has to come back after restarting.
    static let comeBackLimit: TimeInterval = 120

    let request: Request
    /// Install rather than update: the plugin isn't on the host.
    var install = false
    /// Signs in to the dashboard again with the saved password. A host
    /// without a fixed dashboard sign-in secret signs everyone out when the
    /// dashboard restarts. Returns whether it worked.
    var renewSignIn: (@MainActor () async -> Bool)?
    /// How many times one run may sign in again.
    static let signInRenewalLimit = 3
    var pollInterval: Duration = .milliseconds(2_000)
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @MainActor () -> Date = { Date() }

    /// Reports each step to `progress` and returns how it ended. Returns
    /// `.idle` when cancelled.
    func run(progress: (NotifierPluginUpdateState) -> Void) async -> NotifierPluginUpdateState {
        let request = renewingSignIn(self.request)
        // 1. The new plugin onto the host.
        progress(.updating(install ? .installing : .downloading))
        do {
            var installs = install
            var replaces = false
            if !installs {
                do {
                    try Self.check(try await request(Self.updatePath, "POST", nil))
                } catch let error where Self.isNotInstalled(error) {
                    installs = true
                } catch let error where Self.needsReinstall(error) {
                    installs = true
                    replaces = true
                }
            }
            if installs {
                progress(.updating(.installing))
                var body: [String: Any] = ["identifier": NotifierPluginStatus.repository, "enable": true]
                // Replacing the copy on disk takes force. The plugin keeps its
                // state in the Hermes home, not in its own folder.
                if replaces { body["force"] = true }
                try Self.check(try await request(Self.installPath, "POST", body))
            }
        } catch {
            if Task.isCancelled { return .idle }
            return Self.outcome(forRequestError: error)
        }
        if Task.isCancelled { return .idle }

        // 2. The gateway, for the plugin's hooks, tools and skills.
        progress(.updating(.restartingGateway(nil)))
        let restarter = GatewayRestarter(
            request: { path, method in try await request(path, method, nil) },
            pollInterval: pollInterval,
            sleep: sleep,
            now: now
        )
        let gateway = await restarter.run { state in
            if case .restarting(let stage, _) = state { progress(.updating(.restartingGateway(stage))) }
        }
        switch gateway {
        case .idle:
            return .idle
        case .restarted, .unsupported:
            // Unsupported isn't reached today: every Hermes that serves the
            // agent-plugins update route also serves /api/gateway/restart.
            break
        case .failed(let detail):
            return .failed(detail: detail)
        case .failedToStart, .notBackYet, .requesting, .restarting:
            return .failed(detail: AppLocalization.string("The plugin is updated, but the gateway didn't come back. Run hermes gateway status on the host."))
        }

        // 3. The dashboard, for the plugin's routes.
        // Right after the gateway restart a read can fail once; ask again.
        var fetched: [String: Any]?
        for attempt in 0..<3 {
            do {
                fetched = try await request(NotifierPluginStatus.path, "GET", nil)
                break
            } catch DashboardTicketBridgeError.signInRequired {
                // Signing in again didn't work: asking again won't either.
                return Self.outcome(forRequestError: DashboardTicketBridgeError.signInRequired)
            } catch {}
            if Task.isCancelled { return .idle }
            if attempt < 2 { do { try await sleep(pollInterval) } catch { return .idle } }
        }
        guard let before = fetched else { return .needsDashboardRestart(detail: nil) }
        let runtime = NotifierPluginStatus.runtime(from: before)
        // A plugin that predates the running-version report also predates
        // the restart route: the old code is still serving.
        guard let runtime else { return .needsDashboardRestart(detail: nil) }
        // A first install is mounted as it lands; nothing old is running.
        guard runtime.restartNeeded else { return .updated(version: runtime.loadedVersion) }
        let capabilities = before["capabilities"] as? [String] ?? []
        guard capabilities.contains(Self.selfRestartCapability) else { return .needsDashboardRestart(detail: nil) }

        let waitStarted = now()
        while true {
            do {
                _ = try await request(Self.selfRestartPath, "POST", nil)
                break
            } catch {
                if Task.isCancelled { return .idle }
                switch Self.httpStatus(of: error) {
                case 409:
                    guard now().timeIntervalSince(waitStarted) < Self.chatsWaitLimit else {
                        return .needsDashboardRestart(detail: Self.detail(of: error))
                    }
                    progress(.updating(.waitingForChats(count: Self.runningChats(in: Self.detail(of: error)))))
                    do { try await sleep(pollInterval) } catch { return .idle }
                case 404, 405, 501:
                    return .needsDashboardRestart(detail: Self.detail(of: error))
                default:
                    return .failed(detail: UserFacingError.message(for: error))
                }
            }
        }

        progress(.updating(.restartingDashboard))
        let restartStarted = now()
        while now().timeIntervalSince(restartStarted) < Self.comeBackLimit {
            do { try await sleep(pollInterval) } catch { return .idle }
            if Task.isCancelled { return .idle }
            // Requests fail while the dashboard is down; the next poll asks
            // again. A refused sign-in means it is back.
            let json: [String: Any]
            do {
                json = try await request(NotifierPluginStatus.path, "GET", nil)
            } catch DashboardTicketBridgeError.signInRequired {
                return Self.outcome(forRequestError: DashboardTicketBridgeError.signInRequired)
            } catch {
                continue
            }
            guard let after = NotifierPluginStatus.runtime(from: json),
                  after.bootID != runtime.bootID else { continue }
            return after.restartNeeded ? .needsDashboardRestart(detail: nil) : .updated(version: after.loadedVersion)
        }
        return .failed(detail: AppLocalization.string("The dashboard hasn't come back yet. Check that Hermes is running on the host."))
    }

    /// Hermes answers some refusals with 200 and `ok: false` (a catalog
    /// re-pin that needs the user's consent): those are failures here.
    private static func check(_ response: [String: Any]) throws {
        guard response["ok"] as? Bool == false else { return }
        let detail = response["error"] as? String
            ?? AppLocalization.string("Hermes didn't apply the update. Update the plugin from the Hermes dashboard.")
        throw DashboardTicketBridgeError.http(status: 400, detail: detail)
    }

    /// Hermes' update answers 400 "Plugin 'conduit_push' was not found…"
    /// when the plugin isn't installed yet.
    static func isNotInstalled(_ error: Error) -> Bool {
        guard httpStatus(of: error) == 400, let detail = detail(of: error) else { return false }
        return detail.localizedCaseInsensitiveContains("not found")
    }

    /// Hermes updates only a plugin it cloned and recorded itself; one copied
    /// in or installed by an older Hermes answers 400 "…has no owned Git
    /// checkout; reinstall from its source."
    static func needsReinstall(_ error: Error) -> Bool {
        guard httpStatus(of: error) == 400, let detail = detail(of: error) else { return false }
        return detail.localizedCaseInsensitiveContains("no owned Git checkout")
    }

    /// `request`, tried once more after signing in again when the dashboard
    /// answers that the sign-in has expired.
    private func renewingSignIn(_ request: @escaping Request) -> Request {
        guard let renewSignIn else { return request }
        let renewals = SignInRenewals(left: Self.signInRenewalLimit)
        return { path, method, body in
            do {
                return try await request(path, method, body)
            } catch DashboardTicketBridgeError.signInRequired where renewals.left > 0 {
                renewals.left -= 1
                guard await renewSignIn() else { throw DashboardTicketBridgeError.signInRequired }
                return try await request(path, method, body)
            }
        }
    }

    /// "2 chat turns still running…" → 2; 1 when the count can't be read.
    static func runningChats(in detail: String?) -> Int {
        guard let detail, let first = detail.split(separator: " ").first, let count = Int(first), count > 0 else { return 1 }
        return count
    }

    static func outcome(forRequestError error: Error) -> NotifierPluginUpdateState {
        switch httpStatus(of: error) {
        case 404, 405, 501: return .unsupported
        case 400: return .failed(detail: detail(of: error))
        default: return .failed(detail: UserFacingError.message(for: error))
        }
    }

    static func httpStatus(of error: Error) -> Int? {
        if case DashboardTicketBridgeError.http(let status, _) = error { return status }
        return nil
    }

    static func detail(of error: Error) -> String? {
        guard case DashboardTicketBridgeError.http(_, let detail) = error else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
private final class SignInRenewals {
    var left: Int
    init(left: Int) { self.left = left }
}
