//
//  HermesUpdate.swift
//  Conduit
//
//  Update Hermes from Settings > Connection, as Hermes Desktop updates the
//  backend it's connected to: Hermes' dashboard says whether its host is
//  behind (GET /api/hermes/update/check), runs `hermes update` on the host
//  (POST /api/hermes/update), and Conduit follows that action's log
//  (/api/actions/hermes-update/status) through the restart that ends it.
//  An install the dashboard can't update in place (Docker, Nix, a package
//  manager, a managed host) says how to update instead.
//

import Foundation

/// `GET /api/hermes/update/check`.
struct HermesUpdateCheck: Equatable {
    struct Commit: Equatable, Identifiable {
        let sha: String
        let summary: String
        var id: String { sha }
    }

    var installMethod: String
    var currentVersion: String
    /// Commits behind: 0 is current, nil when the check couldn't run.
    var behind: Int?
    var updateAvailable: Bool
    /// Whether the dashboard can update this install itself.
    var canApply: Bool
    var updateCommand: String?
    /// Hermes' own words: why it can't update here, or that it's current.
    var message: String?
    /// The release a stable install moves to.
    var sourceVersion: String?
    /// Set when updating moves a newer build back to a release.
    var rollbackTo: String?
    var commits: [Commit]

    init(installMethod: String = "git", currentVersion: String = "", behind: Int? = 0, updateAvailable: Bool = false,
         canApply: Bool = true, updateCommand: String? = nil, message: String? = nil, sourceVersion: String? = nil,
         rollbackTo: String? = nil, commits: [Commit] = []) {
        self.installMethod = installMethod
        self.currentVersion = currentVersion
        self.behind = behind
        self.updateAvailable = updateAvailable
        self.canApply = canApply
        self.updateCommand = updateCommand
        self.message = message
        self.sourceVersion = sourceVersion
        self.rollbackTo = rollbackTo
        self.commits = commits
    }

    init?(json: [String: Any]) {
        guard json["update_available"] != nil || json["current_version"] != nil else { return nil }
        func text(_ key: String) -> String? {
            guard let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        self.init(
            installMethod: text("install_method") ?? "unknown",
            currentVersion: text("current_version") ?? "",
            behind: json["behind"] as? Int,
            updateAvailable: json["update_available"] as? Bool ?? false,
            canApply: json["can_apply"] as? Bool ?? false,
            updateCommand: text("update_command"),
            message: text("message"),
            sourceVersion: text("source_version"),
            rollbackTo: text("rollback_to"),
            commits: (json["commits"] as? [Any] ?? []).compactMap { row in
                guard let row = row as? [String: Any], let sha = row["sha"] as? String else { return nil }
                return Commit(sha: sha, summary: (row["summary"] as? String) ?? "")
            }
        )
    }

    /// Whether Update Hermes can run from here.
    var canUpdateHere: Bool { updateAvailable && canApply }
}

/// Where Update Hermes stands, for Settings > Connection.
enum HermesUpdateState: Equatable {
    case idle
    case checking
    case checked(HermesUpdateCheck)
    /// `detail` is the newest line of Hermes' update log, verbatim.
    case updating(HermesUpdateStep, detail: String?)
    /// Done: the host runs `version` now (nil when the check after it
    /// couldn't say).
    case updated(version: String?)
    /// Hermes turned the update down or it failed; `detail` is its words.
    case failed(detail: String?)
    /// The check itself didn't get an answer; nothing was updated.
    case checkFailed(detail: String?)
    /// This install updates another way: Hermes' words and the command to
    /// run on the host, when there is one.
    case manual(message: String, command: String?)
    /// The dashboard didn't come back while Conduit watched.
    case notBackYet
    /// This Hermes has no update routes on its dashboard.
    case unsupported

    var isInProgress: Bool {
        switch self {
        case .checking, .updating: return true
        default: return false
        }
    }
}

enum HermesUpdateStep: Equatable {
    /// The request is on its way.
    case starting
    /// `hermes update` runs: pulling, installing, migrating.
    case updating
    /// The dashboard went quiet: Hermes is restarting on the new version.
    case restarting
}

/// Runs one check or one update against the dashboard.
@MainActor
struct HermesUpdater {
    typealias Request = @MainActor (_ path: String, _ method: String) async throws -> [String: Any]

    static let checkPath = "/api/hermes/update/check"
    static let updatePath = "/api/hermes/update"
    static func statusPath(_ action: String) -> String {
        "/api/actions/\(DashboardPath.encodedQueryComponent(action) ?? action)/status?lines=40"
    }

    /// Hermes Desktop's limits: an update (backups, dependency installs,
    /// builds) may take minutes, and the restart after it a few more.
    static let updateLimit: TimeInterval = 360
    static let comeBackLimit: TimeInterval = 240

    let request: Request
    var pollInterval: Duration = .milliseconds(1_500)
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: @MainActor () -> Date = { Date() }

    /// `force` asks Hermes to look again rather than answer from its
    /// day-long cache.
    func check(force: Bool) async -> HermesUpdateState {
        do {
            let json = try await request(Self.checkPath + (force ? "?force=true" : ""), "GET")
            guard let check = HermesUpdateCheck(json: json) else { return .checkFailed(detail: nil) }
            return .checked(check)
        } catch {
            if Task.isCancelled { return .idle }
            if case .failed(let detail) = Self.outcome(forRequestError: error) { return .checkFailed(detail: detail) }
            return Self.outcome(forRequestError: error)
        }
    }

    /// Reports each step to `progress` and returns how it ended. Returns
    /// `.idle` when cancelled.
    func run(progress: (HermesUpdateState) -> Void) async -> HermesUpdateState {
        progress(.updating(.starting, detail: nil))
        let started: [String: Any]
        do {
            started = try await request(Self.updatePath, "POST")
        } catch {
            if Task.isCancelled { return .idle }
            return Self.outcome(forRequestError: error)
        }
        if started["ok"] as? Bool == false {
            let message = (started["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let command = (started["update_command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .manual(message: message.isEmpty ? AppLocalization.string("Hermes can't update itself here.", table: .connection) : message,
                           command: command.isEmpty ? nil : command)
        }
        let action = (started["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "hermes-update"
        let actionID = started["action_id"] as? String
        let startedAt = now()
        var deadline = startedAt.addingTimeInterval(Self.updateLimit)
        var restarting = false
        var latestLine: String?
        progress(.updating(.updating, detail: nil))

        while true {
            do { try await sleep(pollInterval) } catch { return .idle }
            if Task.isCancelled { return .idle }
            let json: [String: Any]
            do {
                json = try await request(Self.statusPath(action), "GET")
            } catch {
                if Task.isCancelled { return .idle }
                // The dashboard restarting on the new version answers
                // nothing for a while.
                if !restarting {
                    restarting = true
                    deadline = max(deadline, now().addingTimeInterval(Self.comeBackLimit))
                }
                if now() >= deadline { return .notBackYet }
                progress(.updating(.restarting, detail: latestLine))
                continue
            }
            let status = GatewayRestartActionStatus(json: json) ?? GatewayRestartActionStatus(running: false)
            latestLine = status.latestLine ?? latestLine
            switch Self.verdict(status, receipt: json["receipt"] as? [String: Any], actionID: actionID) {
            case .running:
                restarting = false
                if now() >= deadline { return .notBackYet }
                progress(.updating(.updating, detail: latestLine))
            case .succeeded:
                return .updated(version: await updatedVersion())
            case .failed:
                return .failed(detail: latestLine)
            case .unknown:
                // Not running and no exit code: a dashboard that restarted
                // forgot the action until its log or receipt says. It gets
                // the same time to come back as one that answers nothing.
                if !restarting {
                    restarting = true
                    deadline = max(deadline, now().addingTimeInterval(Self.comeBackLimit))
                }
                if now() >= deadline { return .notBackYet }
                progress(.updating(.restarting, detail: latestLine))
            }
        }
    }

    enum Verdict: Equatable { case running, succeeded, failed, unknown }

    /// How the action stands: exit 0, Hermes' completion line for this
    /// action, or this action's receipt (`success`, `partial`: the update
    /// committed) mean it's done.
    static func verdict(_ status: GatewayRestartActionStatus, receipt: [String: Any]?, actionID: String?) -> Verdict {
        if status.running { return .running }
        if let actionID, status.lines.contains("=== hermes-update completed \(actionID) ===") { return .succeeded }
        // Only this action's receipt: without an id, an older update's
        // receipt could settle this one.
        if let receipt, let outcome = receipt["outcome"] as? String,
           let actionID, (receipt["action_id"] as? String) == actionID {
            switch outcome {
            case "success", "partial": return .succeeded
            case "failed": return .failed
            default: break
            }
        }
        guard let exitCode = status.exitCode else { return .unknown }
        return exitCode == 0 ? .succeeded : .failed
    }

    private func updatedVersion() async -> String? {
        guard case .checked(let check) = await self.check(force: true), !check.currentVersion.isEmpty else { return nil }
        return check.currentVersion
    }

    static func outcome(forRequestError error: Error) -> HermesUpdateState {
        switch GatewayRestarter.httpStatus(of: error) {
        case 404, 405, 501: return .unsupported
        default: return .failed(detail: UserFacingError.message(for: error))
        }
    }
}
