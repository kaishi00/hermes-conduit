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
        letGoKeptRuntimesOutsideTheGroup()
    }

    /// A dashboard left the group, was removed, or the group fell to one:
    /// every kept connection no longer in it goes.
    func letGoKeptRuntimesOutsideTheGroup() {
        let group = savedDashboardRegistry.combinedGroupIDs
        for keptID in Array(keptDashboardRuntimes.keys) where !group.contains(keptID) {
            dropKeptDashboardRuntime(keptID)
        }
    }

    /// Before a switch retires the connection: a combined dashboard that is
    /// connected keeps its client and bridge instead of closing them. The
    /// retirement then finds neither and closes nothing.
    func keepOutgoingDashboardRuntimeIfCombined(_ outgoingID: UUID?, switchingTo targetID: UUID) {
        guard let outgoingID, outgoingID != targetID,
              isInCombinedGroup(outgoingID),
              // An edited address not yet taken up: this connection is to
              // the old one.
              savedDashboardRegistry.dashboard(with: outgoingID)?.pendingURL == nil,
              let client, keptClientIsOpen(client),
              let bridge = dashboardTicketBridge,
              let connection else { return }
        dropKeptDashboardRuntime(outgoingID)
        keep(KeptDashboardRuntime(
            client: client,
            bridge: bridge,
            connection: connection,
            keptAt: Date()
        ), for: outgoingID)
        self.client = nil
        dashboardTicketBridge = nil
        // The one on screen counts too, and the target, if kept, is about
        // to be taken up rather than let go: it leaves the kept set itself.
        let allowed = Self.combinedLiveDashboardCap - 1 + (keptDashboardRuntimes[targetID] == nil ? 0 : 1)
        while keptDashboardRuntimes.count > allowed,
              let oldest = keptDashboardRuntimes
                .filter({ $0.key != targetID })
                .min(by: { $0.value.keptAt < $1.value.keptAt })?.key {
            dropKeptDashboardRuntime(oldest)
        }
    }

    /// Puts a connection in the kept set. Its socket dropping lets it go at
    /// once, so the row and the next switch never count on a dead one;
    /// taking it up points its events back at the screen.
    func keep(_ kept: KeptDashboardRuntime, for id: UUID) {
        keptDashboardRuntimes[id] = kept
        kept.client.onDisconnected = { [weak self, weak client = kept.client] in
            Task { @MainActor in
                guard let self, let client,
                      self.keptDashboardRuntimes[id]?.client === client else { return }
                self.dropKeptDashboardRuntime(id)
            }
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
              (kept.client.profile ?? "default") == profile,
              // Still the dashboard's address (an edit since lets it go).
              let dashboard = savedDashboardRegistry.dashboard(with: id),
              kept.connection.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == dashboard.normalizedURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            release(kept)
            return nil
        }
        return kept
    }

    func dropKeptDashboardRuntime(_ id: UUID) {
        guard let kept = keptDashboardRuntimes.removeValue(forKey: id) else { return }
        release(kept)
    }

    /// Every kept connection goes: Conduit has been off screen past the
    /// background grace (iOS would suspend the sockets anyway). Signing
    /// out of one dashboard lets only its own go.
    func dropAllKeptDashboardRuntimes() {
        // A quiet sign-in still out keeps nothing it finishes.
        keptDashboardRuntimesGeneration &+= 1
        for id in Array(keptDashboardRuntimes.keys) {
            dropKeptDashboardRuntime(id)
        }
    }

    // MARK: - Every combined dashboard live (stage 3b)

    /// Conduit left the screen: the kept connections hold for the same
    /// grace the one on screen gets, so a quick trip to another app keeps
    /// them, then go (iOS suspends their sockets).
    func dropKeptDashboardRuntimesAfterGrace() {
        keptDashboardRuntimesGraceTask?.cancel()
        // A quiet sign-in still out keeps nothing it finishes off screen.
        keptDashboardRuntimesGeneration &+= 1
        guard !keptDashboardRuntimes.isEmpty else {
            keptDashboardRuntimesGraceTask = nil
            return
        }
        let window = BackgroundConnectionGrace.window
        keptDashboardRuntimesGraceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(window)) } catch { return }
            guard let self, !self.isSceneActive else { return }
            self.keptDashboardRuntimesGraceTask = nil
            self.dropAllKeptDashboardRuntimes()
        }
    }

    /// Once the dashboard on screen has connected and synced (at launch, on
    /// a return to Conduit, after a switch): every other combined dashboard
    /// not yet kept signs in quietly beside it, up to the cap. One that
    /// needs typing, or a Face ID unlock this launch hasn't had, is left
    /// for a tap.
    func connectOtherCombinedDashboards() {
        // Beside any dashboard on screen, one left out of the group
        // included: the group connects when Conduit opens.
        guard isSceneActive, isConnected,
              let activeID = activeDashboardID,
              !savedDashboardRegistry.combinedGroupIDs.isEmpty else { return }
        // Registry order: the Saved Dashboards list as the user sees it.
        // One whose address was edited signs in on its next switch, which
        // settles the move first.
        for dashboard in savedDashboardRegistry.dashboards
        where isInCombinedGroup(dashboard.id) && dashboard.id != activeID && dashboard.pendingURL == nil {
            let id = dashboard.id
            guard keptDashboardRuntimes[id] == nil,
                  !combinedSignInsUnderWay.contains(id),
                  // The one on screen counts too.
                  keptDashboardRuntimes.count + combinedSignInsUnderWay.count < Self.combinedLiveDashboardCap - 1,
                  combinedDashboardSignsInQuietly(id) else { continue }
            combinedSignInsUnderWay.insert(id)
            let generation = keptDashboardRuntimesGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.signInCombinedDashboardQuietly(id)
                self.combinedSignInsUnderWay.remove(id)
                // Conduit left and came back while it was out: the return's
                // own pass skipped it, so it goes again. A plain failure
                // waits for its switch.
                if generation != self.keptDashboardRuntimesGeneration {
                    self.connectOtherCombinedDashboards()
                }
            }
        }
    }

    /// Whether a combined dashboard can sign in with nobody there: a
    /// browser sign-in's grant, a saved session, or a saved password (one
    /// behind Face ID only once this launch's unlock covers it).
    func combinedDashboardSignsInQuietly(_ id: UUID) -> Bool {
        if KeychainHelper.loadNativeOAuthTokens(dashboardID: id) != nil { return true }
        if let credentials = KeychainHelper.loadCredentials(dashboardID: id) {
            return !credentials.requiresFaceID || faceIDUnlockHolds(for: id, credentials)
        }
        return KeychainHelper.loadConnection(dashboardID: id) != nil
    }

    /// Signs one combined dashboard in off screen and keeps it as a switch
    /// would have left it: its own bridge and client, the socket open, its
    /// events fenced until a switch takes it up. Nothing on screen changes,
    /// and a failure leaves it to sign in on its next switch, as today.
    private func signInCombinedDashboardQuietly(_ id: UUID) async {
        guard let dashboard = savedDashboardRegistry.dashboard(with: id) else { return }
        let generation = keptDashboardRuntimesGeneration
        let baseURL = dashboard.normalizedURL
        let profile = rememberedActiveProfile(for: id) ?? "default"
        let access = KeychainHelper.loadCloudflareAccess(dashboardID: id, for: baseURL)
        let bridge = makeDashboardBridge(normalizedURL: baseURL, dashboardID: id, access: access)
        var client: HermesClient?
        // Signed out, moved to another address or removed meanwhile: what
        // it finishes isn't wanted (a sign-out clears what it signs in with).
        func stillWanted() -> Bool {
            guard let current = savedDashboardRegistry.dashboard(with: id) else { return false }
            return generation == keptDashboardRuntimesGeneration
                && isSceneActive
                && isInCombinedGroup(id)
                && id != activeDashboardID
                && keptDashboardRuntimes[id] == nil
                && current.normalizedURL == baseURL
                && current.pendingURL == nil
                && combinedDashboardSignsInQuietly(id)
        }
        do {
            let ticket: String
            if KeychainHelper.loadNativeOAuthTokens(dashboardID: id) == nil,
               let credentials = KeychainHelper.loadCredentials(dashboardID: id) {
                guard !credentials.requiresFaceID || faceIDUnlockHolds(for: id, credentials) else {
                    bridge.invalidate()
                    return
                }
                let signedIn = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: access)
                    .connect(username: credentials.username, password: credentials.password)
                guard stillWanted() else {
                    bridge.invalidate()
                    return
                }
                signedIn.commitCookies(dashboardID: id)
                ticket = signedIn.ticket
            } else if let mintTicket = chatResumeLifecycleOperations.mintTicket {
                ticket = try await mintTicket(baseURL)
            } else {
                ticket = try await bridge.mintTicket()
            }
            guard stillWanted() else {
                bridge.invalidate()
                return
            }
            let connection = HermesConnection(baseUrl: baseURL, ticket: ticket)
            let transportFactory: @MainActor () -> any HermesWebSocketTransport = chatResumeLifecycleOperations.makeTransport ?? { URLSessionWebSocketTransport() }
            let opened = HermesClient(
                connection: connection,
                profile: profile,
                cloudflareAccess: access,
                requestAuthorizer: bridge.requestAuthorizer,
                transportFactory: transportFactory
            )
            client = opened
            try await opened.connect()
            // A switch meanwhile may have kept the dashboard it left: the
            // cap holds, the one on screen counted.
            guard stillWanted(), opened.isConnected,
                  keptDashboardRuntimes.count < Self.combinedLiveDashboardCap - 1 else {
                opened.disconnect()
                bridge.invalidate()
                return
            }
            KeychainHelper.saveConnection(connection, dashboardID: id)
            keep(KeptDashboardRuntime(
                client: opened,
                bridge: bridge,
                connection: connection,
                keptAt: Date()
            ), for: id)
            lifecycleLog.notice("Combined dashboard connected in the background")
        } catch {
            client?.disconnect()
            bridge.invalidate()
            lifecycleLog.notice("Combined dashboard background sign-in failed: \(error.localizedDescription, privacy: .private)")
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
