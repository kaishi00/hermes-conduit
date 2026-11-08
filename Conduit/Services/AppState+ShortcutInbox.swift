//
//  AppState+ShortcutInbox.swift
//  Conduit
//
//  Binds the "Log to Hermes" Shortcuts action (LogToHermesIntent) to the
//  dashboard and profile in use. The event goes over that dashboard's own
//  connection to the plugin's inbox, never through the push relay, and
//  starts no chat. One that can't go now waits on the phone for the next
//  run (ShortcutInboxQueue).
//

import Foundation
import OSLog
import UIKit

struct ShortcutLogError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static var empty: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("There's nothing to log. Give Log to Hermes some details."))
    }

    /// Kept on the phone: the host keeps events, but this plugin answered
    /// without its inbox.
    static var pluginTooOld: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("Update the Conduit plugin on your Hermes host to log events. This one was kept on the phone and goes after the update."))
    }

    /// Kept on the phone: the profile turned the plugin off. `remedy` says
    /// how to turn it on (issue 1671).
    static func pluginOff(_ remedy: String) -> ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("\(remedy) This one was kept on the phone and goes once the plugin is on."))
    }

    /// Not kept: the plugin doesn't keep events, so nothing on the phone
    /// would show or delete it.
    static var pluginMissing: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("Update the Conduit plugin on your Hermes host to log events. This one wasn't kept."))
    }

    /// Kept on the phone: it goes with the next event, or when Conduit
    /// next connects (AppState.drainShortcutInbox).
    static var notConnected: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("Conduit couldn't reach Hermes, so this was kept on the phone. It goes with the next event, or open Conduit."))
    }

    /// Not kept: no connection, and this profile's host isn't known to keep
    /// events yet.
    static var notReachable: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("Conduit couldn't reach Hermes, so this wasn't kept. Open Conduit once, then try again."))
    }

    /// Not kept: dated before the days the host keeps.
    static var tooOld: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("This event is older than the 30 days Hermes keeps, so it wasn't logged."))
    }

    /// Not kept: the phone couldn't store it (not unlocked since restart).
    static var notStored: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("Conduit couldn't keep this on the phone. Unlock your iPhone, then try again."))
    }
}

/// What a run did with its event.
enum ShortcutLogOutcome: Equatable {
    /// Sent, with this many events in all (the ones that waited included).
    case logged(Int)
    /// It looked like a sign-in code, so it never left the phone.
    case skippedCode
}

/// Whether the host in use keeps Log to Hermes events.
enum ShortcutInboxSupport: Equatable {
    case yes, no, unknown
}

extension AppState {
    static let shortcutInboxCapability = "shortcut-inbox"
    static let shortcutInboxLog = Logger(subsystem: "com.milim.relay", category: "shortcut-inbox")
    /// Sends, key agreement and deletes, one at a time across runs.
    static let shortcutInboxGate = ShortcutInboxGate()
    /// How long a drain on connect may hold the gate.
    static let shortcutInboxDrainSeconds: TimeInterval = 10

    /// The dashboard and profile in use: an event is logged for them, and
    /// only ever sent to them.
    var shortcutInboxScope: ShortcutInboxScope? {
        activeDashboardID.map { ShortcutInboxScope(dashboardID: $0, profile: activeProfile) }
    }

    func logShortcutEvent(_ event: ShortcutEvent, deadline: Date) async throws -> ShortcutLogOutcome {
        guard event.carriesSomething else { throw ShortcutLogError.empty }
        guard event.at >= Date().addingTimeInterval(-Double(ShortcutInboxQueue.keepDays) * 86_400) else {
            throw ShortcutLogError.tooOld
        }
        if ShortcutEventFilter.looksLikeCode(event) { return .skippedCode }
        // Right after a cold launch in the background the dashboard
        // connection takes a moment.
        for _ in 0..<10 where dashboardTicketBridge == nil && Date().addingTimeInterval(8) < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        guard let scope = shortcutInboxScope else { throw ShortcutLogError.notReachable }
        let keys = ShortcutInboxKeyStore.keychain(scope)
        // Kept only where the host keeps events: it says so, or this inbox
        // already agreed a key there. Anything else would wait where no
        // Settings page shows or deletes it.
        switch await shortcutInboxSupport(deadline: deadline) {
        case .yes: break
        case .no: throw ShortcutLogError.pluginMissing
        case .unknown: guard keys.load() != nil else { throw ShortcutLogError.notReachable }
        }
        let queue = ShortcutInboxQueue.standard(scope)
        guard queue.add(event) else { throw ShortcutLogError.notStored }
        guard let request = shortcutInboxRequest(for: scope, deadline: deadline) else { throw ShortcutLogError.notConnected }
        let sender = ShortcutInboxSender(queue: queue, keys: keys, deviceName: UIDevice.current.name)
        do {
            return .logged(try await Self.shortcutInboxGate.run { try await sender.send(request: request) })
        } catch DashboardTicketBridgeError.http(let status, let detail) where status == 404 {
            // The profile turned the plugin off: the event waits for it.
            if let remedy = DashboardTicketBridgeError.pluginOffDetail(of: DashboardTicketBridgeError.http(status: status, detail: detail)) {
                throw ShortcutLogError.pluginOff(remedy)
            }
            // A plugin without /inbox: the event waits for the update.
            throw ShortcutLogError.pluginTooOld
        } catch DashboardTicketBridgeError.http(let status, let detail) where status == 409 && HostKeyConflict.isNewerPluginStore(detail) {
            // The inbox was written by a newer plugin: the event waits for the update.
            throw ShortcutLogError.pluginTooOld
        } catch {
            Self.shortcutInboxLog.info("Log to Hermes kept the event for later: \(String(describing: error), privacy: .private)")
            throw ShortcutLogError.notConnected
        }
    }

    /// Sends what waited for the dashboard and profile in use, once its host
    /// says it keeps events: on every connect, so opening Conduit delivers it.
    func drainShortcutInbox() async {
        // Known before Settings draws, so drawing never reads the disk.
        if let scope = shortcutInboxScope { ShortcutInboxLocalState.shared.load(scope) }
        // Bounded: a Log to Hermes run that starts meanwhile waits at most
        // this long for the gate, well inside its own half minute.
        let deadline = Date().addingTimeInterval(Self.shortcutInboxDrainSeconds)
        guard notifierPlugin.reports(Self.shortcutInboxCapability), let scope = shortcutInboxScope,
              let request = shortcutInboxRequest(for: scope, deadline: deadline) else { return }
        let queue = ShortcutInboxQueue.standard(scope)
        guard !queue.pending().isEmpty else { return }
        let sender = ShortcutInboxSender(queue: queue, keys: .keychain(scope), deviceName: UIDevice.current.name)
        do {
            let sent = try await Self.shortcutInboxGate.run { try await sender.send(request: request) }
            Self.shortcutInboxLog.info("Log to Hermes sent \(sent) waiting events on connect")
        } catch {
            Self.shortcutInboxLog.info("Log to Hermes events still wait: \(String(describing: error), privacy: .private)")
        }
    }

    /// Whether the host keeps events, asking it when this launch hasn't yet.
    private func shortcutInboxSupport(deadline: Date) async -> ShortcutInboxSupport {
        var state = notifierPlugin.state
        let remaining = Int(deadline.timeIntervalSinceNow * 1_000)
        if state == .unknown, let bridge = dashboardTicketBridge, remaining > 0 {
            do {
                state = NotifierPluginStatus.state(
                    from: try await bridge.requestJSON(path: NotifierPluginStatus.path, timeoutMilliseconds: min(5_000, remaining)))
            } catch {
                state = NotifierPluginStatus.state(from: error)
            }
        }
        switch state {
        case .unknown: return .unknown
        case .predatesCapabilities: return .no
        case .reported(_, let capabilities): return capabilities.contains(Self.shortcutInboxCapability) ? .yes : .no
        }
    }

    /// The Settings page's entry: shown once the plugin keeps events, or
    /// while this dashboard and profile have events there or waiting here.
    /// Never reads the disk: an inbox not known yet is read after this
    /// draw, and the Settings home redraws when it is (it observes
    /// ShortcutInboxLocalState).
    var showsShortcutInboxSettings: Bool {
        if notifierPlugin.reports(Self.shortcutInboxCapability) { return true }
        guard let scope = shortcutInboxScope else { return false }
        if let known = ShortcutInboxLocalState.shared.hasLocalData(scope) { return known }
        Task { @MainActor in ShortcutInboxLocalState.shared.load(scope) }
        return false
    }

    /// Requests to the plugin's inbox for `scope`, over its dashboard's own
    /// connection; nil while that dashboard isn't the connected one. Never
    /// past `deadline`: once it passes, the run keeps what's left for later.
    func shortcutInboxRequest(for scope: ShortcutInboxScope, deadline: Date? = nil) -> ShortcutInboxSender.Request? {
        guard let bridge = dashboardTicketBridge, activeDashboardID == scope.dashboardID else { return nil }
        return { [weak self] path, method, body in
            // A dashboard swapped mid-run belongs to another inbox.
            guard let self, bridge === self.dashboardTicketBridge, self.activeDashboardID == scope.dashboardID else {
                throw ShortcutInboxUnavailable.otherDashboard
            }
            var timeout = 20_000
            if let deadline {
                let remaining = Int(deadline.timeIntervalSinceNow * 1_000)
                guard remaining > 0 else { throw ShortcutInboxUnavailable.outOfTime }
                timeout = min(timeout, remaining)
            }
            let send: ShortcutInboxSender.Request = { path, method, body in
                try await bridge.requestJSON(
                    path: DashboardPath.withProfile(path, profile: scope.profile),
                    method: method,
                    body: body,
                    timeoutMilliseconds: timeout
                )
            }
            // The transport's own timeout, and the deadline whatever it does.
            return try await (deadline.map { ShortcutInboxDeadline.bounded(send, until: $0) } ?? send)(path, method, body)
        }
    }
}
