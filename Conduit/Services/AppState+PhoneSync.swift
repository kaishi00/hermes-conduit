//
//  AppState+PhoneSync.swift
//  Conduit
//
//  When calendar, reminders, Focus and phone status sync, and with which
//  connection. EventKit can't wake Conduit when the calendar changes, so a
//  pass rides every moment Conduit runs anyway: connecting to the host,
//  coming to the foreground, sending a message, the calendar changing while
//  Conduit is open, a Focus turning on or off, a background refresh, and a
//  push from the host saying Hermes asked for a change. Everything goes only
//  to the dashboard and profile sharing was turned on for, over that
//  dashboard's own connection: never through the push relay.
//

import BackgroundTasks
import Foundation
import OSLog
import UIKit

enum PhoneSyncReason: String {
    case connected
    case foreground
    case messageSent
    case calendarChanged
    case focusChanged
    case backgroundRefresh
    case push
    case answered
    case manual
    case turnedOn
    case voiceCall
}

extension AppState {
    static let phoneSyncCapability = "phone-sync"
    /// Plugin 0.30.0: alarms and timers, and picked people.
    static let phoneAlarmsCapability = "phone-alarms"
    static let phoneContactsCapability = "phone-contacts"
    static let phoneSyncTaskIdentifier = "com.milim.relay.phone-sync"
    static let phoneChangesPushType = "phone.changes"
    static let phoneSyncLog = Logger(subsystem: "com.milim.relay", category: "phone-sync")

    /// Settings shows the page once the host's plugin serves it, or while
    /// sharing is on (so it can be turned off when the plugin went away).
    var showsPhoneSettings: Bool {
        notifierPlugin.reports(Self.phoneSyncCapability) || phoneSync.preferences.isOn
    }

    /// Runs a pass when sharing is on and its dashboard is the one in use.
    @discardableResult
    func runPhoneSync(reason: PhoneSyncReason) async -> PhoneSyncEngine.Outcome {
        await finishPhoneDeletionLeftOnHost()
        let started = Date()
        let engine = phoneSync
        let preferences = engine.preferences
        guard preferences.isOn, let destination = preferences.destination else { return .off }
        if engine.state.pause == .otherDashboard,
           activeDashboardID == nil || activeDashboardID == destination.dashboardID {
            engine.note(nil)
        }
        // Frequent moments that are rarely news: a pass at most every half
        // minute, longer in Low Power or Low Data Mode (ContextUploadPolicy).
        let spacing = ContextUploadPolicy.phoneSpacing(for: reason, conditions: deviceConditions())
        guard ContextUploadPolicy.isDue(lastAttempt: engine.state.lastAttempt, spacing: spacing, now: Date()) else {
            return .unfinished
        }
        let inBackground = !PhoneScenePresence.isInForeground
        if dashboardTicketBridge == nil, inBackground {
            for _ in 0..<10 where dashboardTicketBridge == nil {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard let activeDashboardID else { return .unfinished }
        guard activeDashboardID == destination.dashboardID else {
            engine.note(.otherDashboard)
            return .paused(.otherDashboard)
        }
        guard let bridge = dashboardTicketBridge else { return .unfinished }
        let deadline = inBackground ? started.addingTimeInterval(25) : Date().addingTimeInterval(60)
        guard engine.preferences.isOn, engine.preferences.destination == destination else { return .off }
        let profile = destination.profile
        let keepalive = ContextUploadPolicy.phoneKeepalive(for: reason)
        let outcome = await engine.sync(deadline: deadline, keepalive: keepalive) { [weak self] path, method, body in
            guard let self, bridge === self.dashboardTicketBridge, self.activeDashboardID == destination.dashboardID else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(
                path: DashboardPath.withProfile(path, profile: profile),
                method: method,
                body: body,
                timeoutMilliseconds: max(1_000, min(30_000, Int(deadline.timeIntervalSinceNow * 1_000)))
            )
        }
        Self.phoneSyncLog.info("Phone sync (\(reason.rawValue, privacy: .public)): \(String(describing: outcome), privacy: .private)")
        return outcome
    }

    /// Turns sharing on for the dashboard and profile in use, with these
    /// choices. Asks iOS for calendar, reminders and motion access first.
    func turnOnPhoneSync(_ requested: PhoneSyncPreferences) async throws {
        var choices = requested
        guard let dashboardID = activeDashboardID, let baseURL = connection?.baseUrl else {
            throw DashboardTicketBridgeError.notReady
        }
        if let error = await finishPhoneDeletionLeftOnHost(), PhoneSyncPendingDeletion.owed(on: dashboardID) != nil {
            throw error
        }
        Self.phoneUpdateGeneration += 1
        try await phoneSync.calendarSource.requestAccess(calendar: choices.calendar, reminders: choices.reminders)
        if choices.status { await phoneSync.statusSource.requestMotionAccess() }
        if choices.alarms {
            // A no to alarms (or no AlarmKit) still turns on the rest the user agreed to.
            do { try await phoneSync.alarmSource.requestAccess() } catch is PhoneAlarmError { choices.alarms = false }
        }
        guard activeDashboardID == dashboardID, connection?.baseUrl == baseURL else {
            throw DashboardTicketBridgeError.notReady
        }
        var preferences = choices
        // Each voice mode is asked for on its own, after sharing is on.
        preferences.voiceReaders = nil
        preferences.destination = PhoneSyncDestination(dashboardID: dashboardID, profile: activeProfile,
                                                       host: URL(string: baseURL)?.host ?? baseURL)
        phoneSync.savePreferences(preferences)
        startPhoneObservers()
        Self.schedulePhoneSyncRefresh()
        Task { await runPhoneSync(reason: .turnedOn) }
    }

    /// Bumped by each change of what's shared, so an older one still
    /// waiting on an iOS permission prompt can't overwrite it.
    private static var phoneUpdateGeneration = 0

    /// Changes what's shared while sharing is on. New kinds ask iOS first.
    func updatePhoneSync(_ choices: PhoneSyncPreferences) async throws {
        let current = phoneSync.preferences
        guard let destination = current.destination else { return }
        Self.phoneUpdateGeneration += 1
        let mine = Self.phoneUpdateGeneration
        if choices.calendar != current.calendar || (choices.reminders && !current.reminders) {
            try await phoneSync.calendarSource.requestAccess(calendar: choices.calendar, reminders: choices.reminders)
        }
        if choices.status, !current.status { await phoneSync.statusSource.requestMotionAccess() }
        if choices.alarms, !current.alarms { try await phoneSync.alarmSource.requestAccess() }
        // A newer change, or turning sharing off, came in while iOS asked.
        guard mine == Self.phoneUpdateGeneration, phoneSync.preferences.destination == destination else { return }
        var preferences = choices
        preferences.destination = destination
        // Voice is its own switch (setPhoneVoiceUse), not one of these choices.
        preferences.voiceReaders = phoneSync.preferences.voiceReaders
        guard preferences.sharesAnything else {
            // Nothing left shared is the narrowest sharing: like any other
            // narrowing, what the host holds goes too.
            await turnOffPhoneSync(deleteFromHost: true)
            return
        }
        phoneSync.savePreferences(preferences)
        Task { await runPhoneSync(reason: .manual) }
    }

    /// Lets a live voice mode use the calendar and phone on a call, or not.
    func setPhoneVoiceUse(_ mode: LiveVoiceModeName, allowed: Bool) {
        var preferences = phoneSync.preferences
        guard preferences.isOn else { return }
        preferences.setVoiceUse(mode, allowed: allowed)
        phoneSync.savePreferences(preferences)
    }

    /// Turns sharing off. With `deleteFromHost`, this phone's data is
    /// deleted on the host first; if the host can't be reached, the next
    /// connect to that dashboard deletes it.
    @discardableResult
    func turnOffPhoneSync(deleteFromHost: Bool) async -> Bool {
        Self.phoneUpdateGeneration += 1
        let destination = phoneSync.preferences.destination
        let deviceID = phoneSync.readStateIfNeeded() ? phoneSync.state.deviceID : nil
        var request: PhoneSyncEngine.Request?
        if deleteFromHost, let destination, activeDashboardID == destination.dashboardID,
           let bridge = dashboardTicketBridge {
            request = { path, method, body in
                try await bridge.requestJSON(path: DashboardPath.withProfile(path, profile: destination.profile),
                                             method: method, body: body)
            }
        }
        phoneSync.savePreferences(PhoneSyncPreferences())
        HealthVoiceReadLog.clear(key: HealthVoiceReadLog.phoneStorageKey)
        let deleted = await phoneSync.turnOff(deleteFromHost: request)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.phoneSyncTaskIdentifier)
        if deleteFromHost, !deleted, let destination, let deviceID {
            PhoneSyncPendingDeletion(dashboardID: destination.dashboardID, profile: destination.profile,
                                     deviceID: deviceID).save()
        }
        return deleted || !deleteFromHost
    }

    @discardableResult
    func finishPhoneDeletionLeftOnHost() async -> Error? {
        guard let activeDashboardID, let pending = PhoneSyncPendingDeletion.owed(on: activeDashboardID) else { return nil }
        guard let bridge = dashboardTicketBridge else { return DashboardTicketBridgeError.notReady }
        do {
            _ = try await bridge.requestJSON(
                path: DashboardPath.withProfile("\(PhoneSyncEngine.base)/wipe", profile: pending.profile),
                method: "POST", body: ["device_id": pending.deviceID])
            pending.clear()
        } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
            pending.clear()
        } catch {
            Self.phoneSyncLog.info("Phone data deletion still pending: \(LogRedaction.redactingURLs(PhoneSyncEngine.describe(error)), privacy: .public)")
            return error
        }
        return nil
    }

    // MARK: Changes from Hermes

    /// The user's answer to a change card; reported to the host right away.
    func answerPhoneChange(_ prompt: PhoneChangePrompt, approve: Bool) async {
        await phoneSync.answer(prompt, approve: approve)
        await runPhoneSync(reason: .answered)
    }

    /// A push from the host about a change Hermes asked for. Returns once
    /// the pass is done, so a background wake can report how it went.
    @discardableResult
    func handlePhoneChangesPush(_ userInfo: [AnyHashable: Any]) async -> PhoneSyncEngine.Outcome? {
        guard Self.isPhoneChangesPush(userInfo) else { return nil }
        // The same wake carries confirmations Hermes asks to present,
        // exchanged alongside the phone sync rather than ahead of it.
        async let presented: Void = syncPresentedScreens()
        let outcome = await runPhoneSync(reason: .push)
        await presented
        return outcome
    }

    nonisolated static func isPhoneChangesPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        let routing = (userInfo["conduit"] as? [String: Any])
            ?? ((userInfo["body"] as? [String: Any])?["conduit"] as? [String: Any])
        return routing?["type"] as? String == "phone.changes"
    }

    // MARK: Observers and background refresh

    /// The calendar changing while Conduit runs, and Focus filters.
    func startPhoneObservers() {
        guard phoneSync.preferences.isOn else { return }
        phoneSync.calendarSource.startObservingChanges {
            Task { @MainActor in
                // EventKit reports a burst of changes at once.
                try? await Task.sleep(for: .seconds(5))
                await AppStateRuntimeRegistry.shared.appState.runPhoneSync(reason: .calendarChanged)
            }
        }
    }

    static func registerPhoneSyncTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: phoneSyncTaskIdentifier, using: nil) { task in
            Task { @MainActor in
                schedulePhoneSyncRefresh()
                let app = AppStateRuntimeRegistry.shared.appState
                // The expiration handler is in place before the work starts.
                let running = PhoneRefreshRun()
                task.expirationHandler = { running.expire() }
                let work = Task { await app.runPhoneSync(reason: .backgroundRefresh) }
                running.start(work)
                let outcome = await work.value
                if case .failed = outcome {
                    task.setTaskCompleted(success: false)
                } else {
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }

    static func schedulePhoneSyncRefresh() {
        guard PhoneSyncPreferences.load().isOn else { return }
        let request = BGAppRefreshTaskRequest(identifier: phoneSyncTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    func resumePhoneSyncAtLaunch() {
        guard phoneSync.preferences.isOn else { return }
        startPhoneObservers()
        Self.schedulePhoneSyncRefresh()
    }
}

/// The background refresh's pass, cancelled when iOS says time is up, even
/// if that happens before the pass started.
private final class PhoneRefreshRun: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<PhoneSyncEngine.Outcome, Never>?
    private var expired = false

    func start(_ task: Task<PhoneSyncEngine.Outcome, Never>) {
        let cancel = lock.withLock { () -> Bool in
            self.task = task
            return expired
        }
        if cancel { task.cancel() }
    }

    func expire() {
        let task = lock.withLock { () -> Task<PhoneSyncEngine.Outcome, Never>? in
            expired = true
            return self.task
        }
        task?.cancel()
    }
}
