//
//  AppState+ScheduledJobs.swift
//  Conduit
//
//  Scheduled (cron) jobs: reading them and their runs, their actions,
//  creating, updating and deleting one, and blueprints. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Scheduled jobs

    func loadCronJobs() async {
        let profile = activeProfile
        let generation = cronJobsGeneration
        // One read at a time for the list as it is, on the connection and
        // profile it is for: one an edit, a dashboard switch, a reconnect or
        // a profile change made stale since doesn't hold the next back.
        let owner = "\(generation)|\(profile)|"
            + (dashboardTicketBridge.map { "\(ObjectIdentifier($0))" } ?? client.map { "c\(ObjectIdentifier($0))" } ?? "")
        // The same list's read joins the one out: it runs on its own, so a
        // Tasks tab whose task restarted mid-read (tab away and back) still
        // sees it land, rather than finding it held and reading nothing.
        if let running = cronJobsRead, running.owner == owner {
            await running.task.value
            return
        }
        // The read's own token, as an owner comes back (A, B, then A again)
        // while an older read for it may still be out.
        let token = UUID()
        let task = Task<Void, Never> { [weak self] in
            await self?.readCronJobs(token: token, profile: profile, generation: generation)
        }
        cronJobsRead = (owner, token, task)
        cronJobsLoading = true
        await task.value
    }

    private func readCronJobs(token: UUID, profile: String, generation: Int) async {
        let startedBridge = dashboardTicketBridge
        let startedClient = client
        defer {
            if cronJobsRead?.token == token {
                cronJobsRead = nil
                cronJobsLoading = false
            }
        }

        do {
            if let dashboardTicketBridge {
                let result = try await dashboardTicketBridge.requestJSON(path: cronDashboardPath("/api/cron/jobs", profile: profile))
                let values = result["_array"] as? [Any] ?? result["jobs"] as? [Any] ?? []
                let jobs = values.compactMap(decodeCronJob)
                guard profile == activeProfile, generation == cronJobsGeneration,
                      self.dashboardTicketBridge === dashboardTicketBridge,
                      cronJobsRead?.token == token else { return }
                cronJobs = jobs.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            } else if let client {
                let jobs = try await client.listCronJobs()
                guard profile == activeProfile, self.client === client, generation == cronJobsGeneration,
                      cronJobsRead?.token == token else { return }
                cronJobs = jobs
            }
        } catch is CancellationError {
            return
        } catch {
            // A read the outgoing connection failed isn't the next one's to report.
            guard profile == activeProfile, generation == cronJobsGeneration,
                  dashboardTicketBridge === startedBridge, client === startedClient,
                  cronJobsRead?.token == token else { return }
            errorMessage = AppLocalization.string("Could not load scheduled jobs: \(UserFacingError.message(for: error))")
        }
    }

    /// The jobs listed are the outgoing dashboard's: they go, and a read
    /// still out for them commits nothing (issue 2094).
    func retireCronJobsForDashboardSwitch() {
        cronJobsGeneration += 1
        cronJobs = []
        cronJobsRead = nil
        cronJobsLoading = false
    }

    func loadCronRuns(for job: CronJob) async {
        var gateway: (@MainActor () async throws -> [CronRun]?)?
        if let client {
            gateway = { [weak self] in
                let runs = try await client.cronRuns()
                // A reconnect's new client answers for itself.
                return self?.client === client ? runs : nil
            }
        }
        await loadCronRuns(for: job, dashboard: dashboardTicketBridge, gateway: gateway)
    }

    /// A job's Run history. The dashboard's per-job route is the answer, an
    /// empty one too (a job that hasn't run yet). The gateway's `cron.runs`
    /// lists every job's runs, so it is read only without the dashboard, and
    /// only the runs it can tell are this job's are kept (#1707). The list
    /// belongs to one job: opening another clears it until its answer lands
    /// (`cronRunsLoaded`) or the read fails (`cronRunsFailure`), and only the
    /// newest read's answer is kept.
    func loadCronRuns(
        for job: CronJob,
        dashboard: (any DashboardJSONRequester)?,
        gateway: (@MainActor () async throws -> [CronRun]?)?
    ) async {
        let profile = activeProfile
        if cronRunsJobID != job.id {
            cronRuns = []
            cronRunsLoaded = false
            cronRunsFailure = nil
            cronRunsJobID = job.id
        }
        // A retry shows the spinner again, not the last read's failure.
        cronRunsFailure = nil
        cronRunsLoad += 1
        let load = cronRunsLoad
        let inProfile: (CronRun) -> Bool = { run in
            guard let owner = run.profile, !owner.isEmpty else { return true }
            return Self.profilesMatch(owner, profile)
        }
        do {
            if let dashboard {
                let path = cronDashboardPath("/api/cron/jobs/\(job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id)/runs?limit=20", profile: profile)
                let result = try await dashboard.requestJSON(
                    path: path,
                    method: "GET",
                    body: nil,
                    timeoutMilliseconds: 12_000,
                    maxResponseBytes: DataURLLimits.maxJSONResponseBytes
                )
                guard profile == activeProfile, cronRunsLoad == load else { return }
                answerCronRuns(cronRunValues(from: result).compactMap(decodeCronRun).filter(inProfile))
            } else if let gateway, let runs = try await gateway() {
                guard profile == activeProfile, cronRunsLoad == load else { return }
                answerCronRuns(runs.filter { $0.isRun(ofJob: job.id) && inProfile($0) })
            } else {
                // Nothing to ask (offline, or the client was replaced mid-read).
                guard profile == activeProfile, cronRunsLoad == load, !cronRunsLoaded else { return }
                cronRunsFailure = AppLocalization.string("Connect to Hermes to check.")
            }
        } catch {
            // A sheet closed mid-read: no failure, the next open reads again.
            if error is CancellationError || Task.isCancelled { return }
            guard profile == activeProfile, cronRunsLoad == load else { return }
            let message = AppLocalization.string("Could not load scheduled-job runs: \(UserFacingError.message(for: error))")
            if cronRunsLoaded {
                errorMessage = message
            } else {
                cronRunsFailure = message
            }
        }
    }

    private func answerCronRuns(_ runs: [CronRun]) {
        cronRuns = runs
        cronRunsLoaded = true
        cronRunsFailure = nil
    }

    func performCronAction(_ action: CronJobAction, for job: CronJob) async -> Bool {
        guard cronJobActionID == nil else { return false }
        let profile = activeProfile
        cronJobActionID = job.id
        defer { cronJobActionID = nil }
        guard let dashboardTicketBridge else { return false }

        do {
            let encodedID = job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id
            let result = try await dashboardTicketBridge.requestJSON(
                path: cronDashboardPath("/api/cron/jobs/\(encodedID)/\(action.rawValue)", profile: profile),
                method: "POST",
                body: ["profile": profile]
            )
            guard profile == activeProfile else { return false }
            if let updated = decodeCronJob(result), let index = cronJobs.firstIndex(where: { $0.id == job.id }) {
                cronJobs[index] = updated
            } else {
                await loadCronJobs()
            }
            return true
        } catch {
            // One whole sentence per action: a verb dropped into a shared
            // sentence can't be inflected in most languages.
            let reason = UserFacingError.message(for: error)
            switch action {
            case .pause: errorMessage = AppLocalization.string("Could not pause scheduled job: \(reason)")
            case .resume: errorMessage = AppLocalization.string("Could not resume scheduled job: \(reason)")
            case .trigger: errorMessage = AppLocalization.string("Could not run scheduled job: \(reason)")
            }
            return false
        }
    }

    /// Removes the job from Hermes. Chats from its past runs stay; Hermes
    /// keeps those sessions.
    func deleteCronJob(_ job: CronJob) async -> Bool {
        guard cronJobActionID == nil else { return false }
        let profile = activeProfile
        cronJobActionID = job.id
        defer { cronJobActionID = nil }

        do {
            guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            let encodedID = job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id
            _ = try await dashboardTicketBridge.requestJSON(
                path: cronDashboardPath("/api/cron/jobs/\(encodedID)", profile: profile),
                method: "DELETE"
            )
            // Gone on Hermes either way; only the list on screen needs the
            // same profile.
            cronJobsGeneration += 1
            if profile == activeProfile {
                cronJobs.removeAll { $0.id == job.id }
                cronMutedJobIDs.remove(job.id)
                cronActingJobIDs.remove(job.id)
            }
            return true
        } catch {
            errorMessage = AppLocalization.string("Could not delete scheduled job: \(UserFacingError.message(for: error))")
            return false
        }
    }

    /// Creates a job on Hermes (#819) and adds it to the list. Throws
    /// Hermes' reason (a schedule it can't read, a missing prompt) for the
    /// editor to show.
    func createCronJob(_ body: [String: Any]) async throws -> CronJob? {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = activeProfile
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/jobs", profile: profile),
            method: "POST",
            body: body
        )
        return await addCreatedCronJob(result, profile: profile)
    }

    /// Changes only the fields in `updates`; the rest of the job stays.
    func updateCronJob(_ job: CronJob, updates: [String: Any]) async throws {
        guard !updates.isEmpty else { return }
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = activeProfile
        let encodedID = job.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? job.id
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/jobs/\(encodedID)", profile: profile),
            method: "PUT",
            body: ["updates": updates]
        )
        guard profile == activeProfile else { return }
        if let updated = decodeCronJob(result), let index = cronJobs.firstIndex(where: { $0.id == job.id }) {
            // A list read already on its way predates the change.
            cronJobsGeneration += 1
            cronJobs[index] = updated
        } else {
            await loadCronJobs()
        }
    }

    /// Where a job can deliver: `local` and each connected platform.
    func loadCronDeliveryTargets() async throws -> [CronDeliveryTarget] {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/delivery-targets", profile: activeProfile)
        )
        return (result["targets"] as? [Any] ?? []).compactMap(CronDeliveryTarget.init)
    }

    /// Hermes' blueprint catalog: built-ins and the profile's plugins'.
    func loadCronBlueprints() async throws -> [CronBlueprint] {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/blueprints", profile: activeProfile)
        )
        return (result["blueprints"] as? [Any] ?? []).compactMap(CronBlueprint.init)
    }

    /// Fills a blueprint's blanks and creates its job on Hermes.
    func instantiateCronBlueprint(_ blueprint: CronBlueprint, values: [String: String]) async throws -> CronJob? {
        guard let dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        let profile = activeProfile
        let result = try await dashboardTicketBridge.requestJSON(
            path: cronDashboardPath("/api/cron/blueprints/instantiate", profile: profile),
            method: "POST",
            body: ["blueprint": blueprint.key, "values": CronBlueprint.instantiateValues(values, fields: blueprint.fields)]
        )
        return await addCreatedCronJob(result, profile: profile)
    }

    private func addCreatedCronJob(_ result: [String: Any], profile: String) async -> CronJob? {
        let created = decodeCronJob(result["job"] ?? result)
        guard profile == activeProfile else { return created }
        if let created {
            cronJobsGeneration += 1
            cronJobs.removeAll { $0.id == created.id }
            cronJobs.append(created)
            cronJobs.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } else {
            await loadCronJobs()
        }
        return created
    }

    private func cronDashboardPath(_ path: String, profile: String) -> String {
        DashboardPath.withExplicitProfile(path, profile: profile)
    }

    private func decodeCronJob(_ value: Any) -> CronJob? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(CronJob.self, from: data)
    }

    private func decodeCronRun(_ value: Any) -> CronRun? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        if let decoded = try? JSONDecoder().decode(CronRun.self, from: data) { return decoded }
        guard let rawObject = value as? [String: Any] else { return nil }
        let object = rawObject["session"] as? [String: Any] ?? rawObject
        guard
              let id = stringValue(object["id"] ?? object["session_id"] ?? object["run_id"]), !id.isEmpty else { return nil }
        return CronRun(
            id: id,
            lastActive: Self.integerValue(object["last_active"] ?? object["lastActive"]),
            model: stringValue(object["model"]),
            preview: stringValue(object["preview"] ?? object["summary"]),
            profile: stringValue(object["profile"]),
            startedAt: Self.integerValue(object["started_at"] ?? object["startedAt"]),
            title: stringValue(object["title"] ?? object["name"]),
            jobID: stringValue(object["job_id"] ?? object["cron_job_id"])
        )
    }

    private func cronRunValues(from result: [String: Any]) -> [Any] {
        if let values = result["runs"] as? [Any] ?? result["items"] as? [Any] ?? result["_array"] as? [Any] ?? result["data"] as? [Any] {
            return values
        }
        if let nested = result["data"] as? [String: Any] {
            return nested["runs"] as? [Any] ?? nested["items"] as? [Any] ?? []
        }
        if let nested = result["runs"] as? [String: Any] {
            return nested["items"] as? [Any] ?? nested["results"] as? [Any] ?? []
        }
        return []
    }

    /// A loosely typed JSON integer. Floats truncate toward zero (an epoch
    /// with a fraction), and a number no Int can hold is nil, the same as
    /// for strings, rather than NSNumber.intValue's wrapped garbage. A JSON
    /// boolean is no integer: JSONSerialization hands it back as an NSNumber
    /// that `as? Int` would read as 0 or 1.
    nonisolated static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, AnyCodable.isBoolean(number) { return nil }
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return Int(exactly: number.doubleValue.rounded(.towardZero)) }
        if let string = value as? String {
            return Int(string) ?? Double(string).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        }
        return nil
    }

    func booleanValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return false
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        let string = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
}
