//
//  AppState+CombinedDashboards.swift
//  Conduit
//
//  The combined group (multi-instance stage 3): dashboards switched on under
//  Settings > Saved Dashboards > Combine Dashboards. A combined dashboard
//  left while connected keeps its socket and bridge, so a switch back takes
//  them up again: no new ticket, no new socket, only the usual sync.
//  Lists stay per dashboard until stage 4.
//

import Foundation

/// A combined dashboard's live connection, kept while another dashboard is
/// on screen. Its events are fenced (the client epoch moved on), so nothing
/// of it reaches the dashboard showing; the sync on taking it up brings its
/// chat current.
struct KeptDashboardRuntime {
    let client: HermesClient
    let bridge: DashboardTicketBridge
    let connection: HermesConnection
    let keptAt: Date
}

extension AppState {
    /// Live dashboards at once in the group, the one on screen included
    /// (stage 0's cap). Past it, the one kept longest is let go.
    static let combinedLiveDashboardCap = 4

    /// Whether this dashboard is in the combined group.
    func isInCombinedGroup(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return savedDashboardRegistry.combinedGroupIDs.contains(id)
    }

    /// Switches a dashboard in or out of the group. Leaving it, or a group
    /// that falls to one, lets the kept connections go.
    func setDashboardCombined(_ id: UUID, _ combined: Bool) {
        guard let index = savedDashboardRegistry.dashboards.firstIndex(where: { $0.id == id }),
              savedDashboardRegistry.dashboards[index].isCombined != combined else { return }
        var registry = savedDashboardRegistry
        registry.dashboards[index].combined = combined ? true : nil
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
        let group = registry.combinedGroupIDs
        for keptID in keptDashboardRuntimes.keys where !group.contains(keptID) {
            dropKeptDashboardRuntime(keptID)
        }
    }

    /// Before a switch retires the connection: a combined dashboard that is
    /// connected keeps its client and bridge instead of closing them. The
    /// retirement then finds neither and closes nothing.
    func keepOutgoingDashboardRuntimeIfCombined(_ outgoingID: UUID?, switchingTo targetID: UUID) {
        guard let outgoingID, outgoingID != targetID,
              isInCombinedGroup(outgoingID),
              let client, keptClientIsOpen(client),
              let bridge = dashboardTicketBridge,
              let connection else { return }
        dropKeptDashboardRuntime(outgoingID)
        keptDashboardRuntimes[outgoingID] = KeptDashboardRuntime(
            client: client,
            bridge: bridge,
            connection: connection,
            keptAt: Date()
        )
        self.client = nil
        dashboardTicketBridge = nil
        // The one on screen counts too.
        while keptDashboardRuntimes.count > Self.combinedLiveDashboardCap - 1,
              let oldest = keptDashboardRuntimes.min(by: { $0.value.keptAt < $1.value.keptAt })?.key {
            dropKeptDashboardRuntime(oldest)
        }
    }

    /// The dashboard's kept connection, taken out of the kept set, when it
    /// is still open and on the profile the switch resumes. One that
    /// dropped, or is on another profile, is let go and the switch signs in
    /// as before.
    func takeKeptDashboardRuntime(_ id: UUID, profile: String) -> KeptDashboardRuntime? {
        guard let kept = keptDashboardRuntimes.removeValue(forKey: id) else { return nil }
        guard isInCombinedGroup(id),
              keptClientIsOpen(kept.client),
              (kept.client.profile ?? "default") == profile else {
            release(kept)
            return nil
        }
        return kept
    }

    func dropKeptDashboardRuntime(_ id: UUID) {
        guard let kept = keptDashboardRuntimes.removeValue(forKey: id) else { return }
        release(kept)
    }

    /// Every kept connection goes: Conduit left the screen (iOS would
    /// suspend the sockets anyway), or everything was signed out.
    func dropAllKeptDashboardRuntimes() {
        for id in Array(keptDashboardRuntimes.keys) {
            dropKeptDashboardRuntime(id)
        }
    }

    private func keptClientIsOpen(_ client: HermesClient) -> Bool {
        client.isConnected
    }

    private func release(_ kept: KeptDashboardRuntime) {
        kept.client.disconnect()
        kept.bridge.invalidate()
    }
}
