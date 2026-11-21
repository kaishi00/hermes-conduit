//
//  DashboardRuntime.swift
//  Conduit
//
//  One dashboard's live state: its connection first (the client, the
//  bridge, whether it's connected, what its plugin serves), then the rest of
//  the cut list's instance rows, a slice at a time (the plan: "Dropping the
//  dashboard switch", /mnt/project-files/all-live/no-switch-plan.md).
//

import Combine
import Foundation

/// One dashboard's live state.
///
/// As with `ChatState` in stage 1, there is still one, `AppState`'s
/// `runtimeOnScreen`, refilled by a switch as AppState's own properties
/// were. Views and extensions read it through AppState's forwarders, and
/// AppState publishes its changes as its own. Once each combined dashboard
/// keeps one of its own, a switch inside the group shows another runtime
/// instead of tearing this one down and syncing the next.
///
/// Only the dashboard's own state moves here. What reacts to a change on
/// screen (the widget launch, the composer's pending send, the Watch's
/// shared context) stays in AppState's forwarding setters.
@MainActor
final class DashboardRuntime: ObservableObject {

    // MARK: Connection

    @Published var connection: HermesConnection?
    @Published var client: HermesClient?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var dashboardTicketBridge: DashboardTicketBridge?
    /// Moves on with each client, so callbacks queued by an earlier one
    /// are dropped.
    var clientEpoch = UUID()
    var connectedAt: Date?

    // MARK: Plugin

    /// What the host's notifier plugin serves.
    @Published var notifierPlugin = NotifierPluginStatus()
}
