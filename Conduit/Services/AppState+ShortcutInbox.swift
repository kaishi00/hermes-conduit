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

    static var pluginTooOld: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("Update the Conduit plugin on your Hermes host to log events. This one was kept on the phone and goes after the update."))
    }

    static var notConnected: ShortcutLogError {
        ShortcutLogError(message: AppLocalization.string("Conduit couldn't reach Hermes, so this was kept on the phone. It goes with the next event, or open Conduit."))
    }
}

/// What a run did with its event.
enum ShortcutLogOutcome: Equatable {
    /// Sent, with this many events in all (the ones that waited included).
    case logged(Int)
    /// It looked like a sign-in code, so it never left the phone.
    case skippedCode
}

extension AppState {
    static let shortcutInboxCapability = "shortcut-inbox"
    static let shortcutInboxLog = Logger(subsystem: "com.milim.relay", category: "shortcut-inbox")

    func logShortcutEvent(_ event: ShortcutEvent, deadline: Date) async throws -> ShortcutLogOutcome {
        guard event.carriesSomething else { throw ShortcutLogError.empty }
        if ShortcutEventFilter.looksLikeCode(event) { return .skippedCode }
        let queue = ShortcutInboxQueue(defaults: .standard)
        queue.add(event)
        // Right after a cold launch in the background the dashboard
        // connection takes a moment.
        for _ in 0..<10 where dashboardTicketBridge == nil && Date().addingTimeInterval(8) < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        guard let request = shortcutInboxRequest(deadline: deadline) else { throw ShortcutLogError.notConnected }
        if !notifierPlugin.mightSupport(Self.shortcutInboxCapability) { throw ShortcutLogError.pluginTooOld }
        let sender = ShortcutInboxSender(queue: queue, keys: .keychain, deviceName: UIDevice.current.name)
        do {
            return .logged(try await sender.send(request: request))
        } catch DashboardTicketBridgeError.http(let status, _) where status == 404 {
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

    /// The Settings page's entry: shown once the plugin keeps events, or
    /// while this iPhone has logged some there.
    var showsShortcutInboxSettings: Bool {
        notifierPlugin.reports(Self.shortcutInboxCapability) || ShortcutInboxKeyStore.keychain.load() != nil
    }

    /// Requests to the plugin's inbox over the active dashboard's own
    /// connection, for its profile; nil while not connected.
    func shortcutInboxRequest(deadline: Date? = nil) -> ShortcutInboxSender.Request? {
        guard let bridge = dashboardTicketBridge else { return nil }
        let profile = activeProfile
        return { path, method, body in
            try await bridge.requestJSON(
                path: DashboardPath.withProfile(path, profile: profile),
                method: method,
                body: body,
                timeoutMilliseconds: deadline.map { max(1_000, min(20_000, Int($0.timeIntervalSinceNow * 1_000))) } ?? 20_000
            )
        }
    }
}
