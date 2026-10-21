//
//  AppState+HealthSync.swift
//  Conduit
//
//  When health data syncs, and with which connection.
//  A pass runs when Conduit connects to the host or comes to the
//  foreground, when Apple Health wakes Conduit with new data (background
//  delivery, about hourly), on a background refresh, and on "Sync now".
//  It goes only to the dashboard and profile sharing was turned on for, over
//  that dashboard's own connection: never through the push relay.
//

import BackgroundTasks
import Foundation
import OSLog
import UIKit

enum HealthSyncReason: String {
    case connected
    case foreground
    case healthChanged
    case backgroundRefresh
    case manual
    case turnedOn
    /// A live voice call that may read health data is starting.
    case voiceCall
}

extension AppState {
    static let healthSyncCapability = "health-sync"
    static let healthSyncTaskIdentifier = "com.milim.relay.health-sync"
    static let healthSyncLog = Logger(subsystem: "com.milim.relay", category: "health-sync")

    /// Settings shows Health once the host's plugin serves it, or while
    /// sharing is on (so it can be turned off when the plugin went away).
    var showsHealthSettings: Bool {
        notifierPlugin.reports(Self.healthSyncCapability) || healthSyncPreferences.isOn
    }

    /// Runs a pass when sharing is on and its dashboard is the one in use.
    @discardableResult
    func runHealthSync(reason: HealthSyncReason) async -> HealthSyncEngine.Outcome {
        await finishHealthDeletionLeftOnHost()
        let started = Date()
        let preferences = healthSyncPreferences
        guard preferences.isOn, let destination = preferences.destination else { return .off }
        let engine = healthSync
        // "Switch back to it" holds only while another dashboard is in use.
        if engine.state.pause == .otherDashboard,
           activeDashboardID == nil || activeDashboardID == destination.dashboardID {
            engine.note(nil)
        }
        // Coming back to the app often isn't news; Apple Health's own wakes
        // and the background refresh cover the rest. A voice call reuses a
        // pass from the last few minutes, and Low Power or Low Data Mode
        // spaces routine passes further (ContextUploadPolicy).
        // An Apple Health wake spaced behind another pass isn't dropped:
        // close to its turn it waits for it, otherwise the next pass, for
        // any reason, runs at once.
        let conditions = deviceConditions()
        let spacing = ContextUploadPolicy.healthSpacing(for: reason, conditions: conditions)
        if !engine.changesWaiting,
           let wait = ContextUploadPolicy.remainingSpacing(lastAttempt: engine.state.lastAttempt, spacing: spacing, now: Date()) {
            guard reason == .healthChanged else { return .unfinished }
            engine.changesWaiting = true
            guard wait <= ContextUploadPolicy.healthTrailingWait else { return .unfinished }
            try? await Task.sleep(for: .seconds(wait))
            // Another pass took the new data meanwhile.
            guard engine.changesWaiting else { return .unfinished }
        }
        let options = ContextUploadPolicy.healthPass(for: reason, conditions: conditions)
        let inBackground = !PhoneScenePresence.isInForeground
        // A background launch connects on its own; give it a moment.
        if dashboardTicketBridge == nil, inBackground {
            for _ in 0..<10 where dashboardTicketBridge == nil {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // No dashboard in use yet: nothing to switch back to, try later.
        guard let activeDashboardID else { return .unfinished }
        guard activeDashboardID == destination.dashboardID else {
            engine.note(.otherDashboard)
            return .paused(.otherDashboard)
        }
        guard let bridge = dashboardTicketBridge else { return .unfinished }
        // About half a minute in the background in all, waiting for the
        // connection included, as iOS allows; longer on screen so a first
        // sync can bring in a good part of the history.
        let deadline = inBackground ? started.addingTimeInterval(25) : Date().addingTimeInterval(120)
        // Sharing may have been turned off while this waited.
        guard healthSyncPreferences.isOn, healthSyncPreferences.destination == destination else { return .off }
        let profile = destination.profile
        engine.changesWaiting = false
        let outcome = await engine.sync(preferences: preferences, deadline: deadline, options: options) { [weak self] path, method, body in
            // A dashboard swapped mid-pass belongs to someone else's data.
            guard let self, bridge === self.dashboardTicketBridge, self.activeDashboardID == destination.dashboardID else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(
                path: DashboardPath.withProfile(path, profile: profile),
                method: method,
                body: body,
                // Never past the pass's own deadline.
                timeoutMilliseconds: max(1_000, min(30_000, Int(deadline.timeIntervalSinceNow * 1_000)))
            )
        }
        Self.healthSyncLog.info("Health sync (\(reason.rawValue, privacy: .public)): \(String(describing: outcome), privacy: .private)")
        return outcome
    }

    /// Turns sharing on for the dashboard and profile in use. Asks Apple
    /// Health for read access first; the system sheet lists each type.
    func turnOnHealthSync(categories: Set<HealthCategory>, detailed: Set<HealthCategory>,
                          history: HealthHistoryDepth) async throws {
        guard let dashboardID = activeDashboardID, let baseURL = connection?.baseUrl else {
            throw DashboardTicketBridgeError.notReady
        }
        // A deletion still owed on this dashboard runs first: afterwards it
        // would take the new data with it. One owed elsewhere waits there.
        if let error = await finishHealthDeletionLeftOnHost(),
           HealthSyncPendingDeletion.owed(on: dashboardID) != nil {
            throw error
        }
        try await healthSync.source.requestAuthorization(for: categories, detailed: detailed)
        // The dashboard changed while this waited: its profile isn't the one asked for.
        guard activeDashboardID == dashboardID, connection?.baseUrl == baseURL else {
            throw DashboardTicketBridgeError.notReady
        }
        var preferences = healthSyncPreferences
        preferences.destination = HealthSyncDestination(
            dashboardID: dashboardID, profile: activeProfile,
            host: URL(string: baseURL)?.host ?? baseURL)
        preferences.categories = categories
        preferences.detailed = detailed.intersection(categories)
        preferences.history = history
        saveHealthSyncPreferences(preferences)
        // Not waited on: turning on is done once the choice is saved, and
        // background delivery can take its time.
        Task { await startHealthObservers() }
        Self.scheduleHealthSyncRefresh()
        Task { await runHealthSync(reason: .turnedOn) }
    }

    /// Bumped by each change of what's shared, so an older one still
    /// waiting on Apple Health can't overwrite it.
    private static var healthUpdateGeneration = 0

    /// Changes what's shared. New categories ask Apple Health first.
    func updateHealthSync(categories: Set<HealthCategory>, detailed: Set<HealthCategory>,
                          history: HealthHistoryDepth) async throws {
        guard healthSyncPreferences.destination != nil, !categories.isEmpty else { return }
        Self.healthUpdateGeneration += 1
        let mine = Self.healthUpdateGeneration
        let added = categories.subtracting(healthSyncPreferences.categories)
        if !added.isEmpty {
            try await healthSync.source.requestAuthorization(for: categories, detailed: detailed)
        }
        // A newer change, or turning sharing off, came in while this waited.
        var preferences = healthSyncPreferences
        guard mine == Self.healthUpdateGeneration, preferences.destination != nil else { return }
        preferences.categories = categories
        preferences.detailed = detailed.intersection(categories)
        preferences.history = history
        saveHealthSyncPreferences(preferences)
        await startHealthObservers()
        Task { await runHealthSync(reason: .manual) }
    }

    /// Turns sharing off. With `deleteFromHost`, this phone's health data
    /// and key are deleted on the host first. False when the host couldn't
    /// be reached: the deletion then runs the next time Conduit connects to
    /// that dashboard.
    @discardableResult
    func turnOffHealthSync(deleteFromHost: Bool) async -> Bool {
        let destination = healthSyncPreferences.destination
        // Unknown until the state file can be read (never while unlocked in practice).
        let deviceID = healthSync.readStateIfNeeded() ? healthSync.state.deviceID : nil
        var request: HealthSyncEngine.Request?
        if deleteFromHost, let destination, activeDashboardID == destination.dashboardID,
           let bridge = dashboardTicketBridge {
            request = { path, method, body in
                try await bridge.requestJSON(path: DashboardPath.withProfile(path, profile: destination.profile),
                                             method: method, body: body)
            }
        }
        // Off before anything waits, so a pass queued meanwhile finds it off
        // and can't send data after the deletion.
        saveHealthSyncPreferences(HealthSyncPreferences())
        HealthVoiceReadLog.clear()
        let deleted = await healthSync.turnOff(deleteFromHost: request)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.healthSyncTaskIdentifier)
        if deleteFromHost, !deleted, let destination, let deviceID {
            HealthSyncPendingDeletion(dashboardID: destination.dashboardID, profile: destination.profile,
                                      deviceID: deviceID).save()
        }
        return deleted || !deleteFromHost
    }

    /// Deletes what this phone left on a host when sharing was turned off
    /// while that host couldn't be reached.
    /// Why a deletion owed on the active dashboard couldn't run, or nil.
    @discardableResult
    func finishHealthDeletionLeftOnHost() async -> Error? {
        guard let activeDashboardID, let pending = HealthSyncPendingDeletion.owed(on: activeDashboardID) else { return nil }
        guard let bridge = dashboardTicketBridge else { return DashboardTicketBridgeError.notReady }
        do {
            _ = try await bridge.requestJSON(
                path: DashboardPath.withProfile("\(HealthSyncEngine.base)/wipe", profile: pending.profile),
                method: "POST", body: ["device_id": pending.deviceID])
            pending.clear()
        } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
            // No health sync on this host any more: nothing left to delete.
            pending.clear()
        } catch {
            Self.healthSyncLog.info("Health deletion still pending: \(LogRedaction.redactingURLs(HealthSyncEngine.describe(error)), privacy: .public)")
            return error
        }
        return nil
    }

    /// Lets a live voice mode read the shared data on a call, or stops it.
    func setHealthVoiceRead(_ mode: LiveVoiceModeName, allowed: Bool) {
        var preferences = healthSyncPreferences
        guard preferences.isOn else { return }
        preferences.setVoiceRead(mode, allowed: allowed)
        saveHealthSyncPreferences(preferences)
    }

    private func saveHealthSyncPreferences(_ preferences: HealthSyncPreferences) {
        preferences.save()
        healthSyncPreferences = preferences
    }

    /// Apple Health wakes Conduit when shared data changes. Observers last
    /// for the process, so this runs at every launch while sharing is on.
    func startHealthObservers() async {
        let categories = healthSyncPreferences.categories
        guard healthSyncPreferences.isOn else {
            await healthSync.source.stopObserving()
            return
        }
        await healthSync.source.observe(categories) { done in
            Task { @MainActor in
                let app = AppStateRuntimeRegistry.shared.appState
                await app.runHealthSync(reason: .healthChanged)
                done()
            }
        }
    }

    // MARK: Background refresh

    /// Registered before launch finishes, as BGTaskScheduler requires.
    static func registerHealthSyncTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: healthSyncTaskIdentifier, using: nil) { task in
            Task { @MainActor in
                scheduleHealthSyncRefresh()
                let app = AppStateRuntimeRegistry.shared.appState
                let run = Task { await app.runHealthSync(reason: .backgroundRefresh) }
                task.expirationHandler = { run.cancel() }
                let outcome = await run.value
                if case .failed = outcome {
                    task.setTaskCompleted(success: false)
                } else {
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }

    static func scheduleHealthSyncRefresh() {
        guard HealthSyncPreferences.load().isOn else { return }
        let request = BGAppRefreshTaskRequest(identifier: healthSyncTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(2 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// At launch: observers and the refresh, when sharing is on.
    func resumeHealthSyncAtLaunch() {
        guard healthSyncPreferences.isOn else { return }
        Task {
            await startHealthObservers()
            Self.scheduleHealthSyncRefresh()
        }
    }
}
