//
//  AppState+FarLiveStatus.swift
//  Conduit
//
//  Running and approval status on another combined dashboard's rows in the
//  Chats list (no-switch stage 4b): its registry, read by profile through
//  its kept connection beside the list's own poll, its Needs you waits,
//  and its chat open in place's own turn.
//

import Foundation

/// Another combined dashboard's registries, by profile, as read through
/// its kept connection: another connection's are stale.
struct FarLiveStatus: Equatable {
    var statuses = OtherProfilesLiveStatus()
    var readAt: Date?
}

extension AppState {
    /// How often the other dashboards' registries are read while the list
    /// polls: more seldom than the one on screen's, since each read goes to
    /// another Hermes over a socket its chats also use.
    static let farLiveStatusInterval: TimeInterval = 8

    /// Reads, through each kept and connected combined dashboard's
    /// connection, the registry of every profile its listed rows name, at
    /// most every `farLiveStatusInterval`. A failed read keeps what that
    /// profile showed; a dashboard whose rows left the list goes.
    func refreshFarLiveSessionStatusesIfDue(now: Date = Date()) async {
        guard !farLiveStatusReading else { return }
        guard isInCombinedGroup(activeDashboardID) else {
            if !farLiveStatus.isEmpty { farLiveStatus = [:] }
            return
        }
        farLiveStatusReading = true
        defer { farLiveStatusReading = false }
        let probe = chatResumeLifecycleOperations.probeProfileActiveSessions
        for id in combinedDashboardChats.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard id != dashboardIDOnScreen, let kept = keptDashboardRuntimes[id], kept.runtime.isConnected,
                  kept.client.isConnected else { continue }
            if let at = farLiveStatus[id]?.readAt, now.timeIntervalSince(at) < Self.farLiveStatusInterval,
               farLiveStatus[id]?.statuses.client == ObjectIdentifier(kept.client) { continue }
            let client = kept.client
            var seen = Set<String>()
            let profiles = (combinedDashboardChats[id]?.sessions ?? []).map { $0.profile ?? "default" }
                .filter { seen.insert(OtherProfilesLiveStatus.key($0)).inserted }
            var next = farLiveStatus[id] ?? FarLiveStatus()
            for profile in profiles {
                guard let rows = try? await (probe.map { try await $0(client, profile) }
                                             ?? client.activeSessions(inProfile: profile)) else { continue }
                // Let go or replaced while the read was out: not this one's.
                guard keptDashboardRuntimes[id]?.client === client else { break }
                next.statuses.set(SessionLiveStatusIndex(rows: rows), for: profile, client: ObjectIdentifier(client))
            }
            guard keptDashboardRuntimes[id]?.client === client else { continue }
            next.statuses.keep(profiles)
            next.readAt = now
            var all = farLiveStatus
            all[id] = next
            // Assigned only on a change: every publish redraws the lists.
            if all != farLiveStatus { farLiveStatus = all }
        }
        let listed = farLiveStatus.filter { combinedDashboardChats[$0.key] != nil && $0.key != dashboardIDOnScreen }
        if listed != farLiveStatus { farLiveStatus = listed }
    }

    /// Another combined dashboard's row: waiting when its Needs you holds a
    /// wait for it, working or waiting as its registry last read it through
    /// its kept connection, and, while it's the chat open in place, working
    /// as its working line says. Nothing while that connection is down.
    func farSessionLiveStatus(_ session: SessionSummary, in far: UUID) -> SessionLiveStatus? {
        guard let kept = keptDashboardRuntimes[far], kept.runtime.isConnected else { return nil }
        let profile = session.profile ?? "default"
        let ids = Set([session.id, session.storedSessionId, session.lineageRootId].compactMap { $0 } + session.alternateIds)
        if needsYou.otherDashboards[far]?.contains(where: {
            $0.roomID == nil && Self.profilesMatch($0.profile, profile) && !ids.isDisjoint(with: $0.sessionIDs)
        }) == true {
            return .needsInput
        }
        let registry = farLiveStatus[far]?.statuses.index(for: profile, client: ObjectIdentifier(kept.client))?
            .status(for: session)
        // Its chat open in place: the chat on screen's own turn, as the
        // dashboard on screen's open chat says it (`sessionLiveStatus`).
        if farChat?.dashboardID == far, let open = activeSessionId, ids.contains(open) {
            if registry == .needsInput { return .needsInput }
            if isBusy { return .working }
            let localIdleKnown = !turnStateIsStale && turnState == .idle
            return localIdleKnown ? nil : registry
        }
        return registry
    }
}
