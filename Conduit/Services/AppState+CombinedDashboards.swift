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

/// Why a combined dashboard beside the one on screen isn't connected.
enum CombinedDashboardTrouble: Equatable {
    /// Its last quiet sign-in failed on the way (the network, the server):
    /// it's tried again while Conduit is on screen.
    case down
    /// It has nothing to sign in with quietly, or its sign-in was refused:
    /// it waits for a tap.
    case signInNeeded
}

/// What the Saved Dashboards row and the dashboard menu say of a combined
/// dashboard other than the one on screen (stage 3c).
enum CombinedDashboardStatus: Equatable {
    case live
    case connecting
    case down
    case signInNeeded

    /// The row's and the menu's words for it.
    var label: String {
        switch self {
        case .live: return AppLocalization.string("Connected in the background")
        case .connecting: return AppLocalization.string("Connecting…")
        case .down: return AppLocalization.string("Can't connect. Trying again.", table: .connection)
        case .signInNeeded: return AppLocalization.string("Sign In required", table: .connection)
        }
    }
}

/// A down combined dashboard's retries in a row, and the one waiting.
struct CombinedDashboardRetry {
    var attempt: Int
    var task: Task<Void, Never>?
}

/// How a quiet sign-in ended.
enum CombinedSignInOutcome {
    case connected
    /// Not wanted any more (signed out, moved, Conduit left): nothing to say.
    case dropped
    case failed(CombinedDashboardTrouble)
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
        // Turned on: the group signs in now, not first on the next connect
        // or a switch to it (Eric, 2026-11-16).
        if combined { Task { @MainActor [weak self] in await self?.signInCombinedGroupNow() } }
    }

    /// The person just turned combine on: each dashboard of the group
    /// whose saved password waits on Face ID this launch hasn't had asks
    /// for it now, once, rather than waiting for a switch to it, and the
    /// group signs in beside the one on screen. One with nothing saved
    /// still waits for a tap, and says so.
    func signInCombinedGroupNow() async {
        for dashboard in savedDashboardRegistry.dashboards
        where isInCombinedGroup(dashboard.id) && dashboard.id != activeDashboardID
            && keptDashboardRuntimes[dashboard.id] == nil && !combinedDashboardSignsInQuietly(dashboard.id) {
            // Nothing saved behind Face ID: that one waits for a tap, the
            // rest still ask.
            guard KeychainHelper.loadCredentials(dashboardID: dashboard.id)?.requiresFaceID == true else { continue }
            // Cancelled, or no Face ID to be had: the rest wait for a tap.
            guard await unlockCombinedDashboardWithFaceID(dashboard.id) else { break }
        }
        connectOtherCombinedDashboards()
    }

    /// A dashboard left the group, was removed, or the group fell to one:
    /// every kept connection no longer in it goes.
    func letGoKeptRuntimesOutsideTheGroup() {
        let group = savedDashboardRegistry.combinedGroupIDs
        for keptID in Array(keptDashboardRuntimes.keys) where !group.contains(keptID) {
            dropKeptDashboardRuntime(keptID)
        }
        // Lists that stood through a drop go with the group too.
        for id in Set(combinedDashboardChats.keys).union(combinedDashboardBots.keys).union(combinedDashboardPulse.keys)
        where !group.contains(id) {
            forgetCombinedDashboardLists(id)
        }
        pruneCombinedBotsHomeOrder()
        // Nor is anything said of it, or tried again.
        for id in Set(combinedDashboardTrouble.keys).union(combinedDashboardRetries.keys) where !group.contains(id) {
            clearCombinedDashboardTrouble(id)
        }
    }

    /// Before a switch retires the connection: a combined dashboard that is
    /// connected keeps its client and bridge instead of closing them. The
    /// retirement then finds neither and closes nothing.
    /// `roster`: the outgoing dashboard's bots as it showed them, taken
    /// before the switch's preparation clears Bot Mode's state; `work`
    /// their work by lowercased name, and `pluginCapabilities` what its
    /// plugin serves, taken then too.
    func keepOutgoingDashboardRuntimeIfCombined(
        _ outgoingID: UUID?, switchingTo targetID: UUID, roster: [BotProfile],
        profiles: [String] = [], chats: [SessionSummary] = [],
        work: [String: BotWorkSnapshot] = [:], pluginCapabilities: Set<String>? = nil,
        glows: [String: ProfileGlowRGB]? = nil
    ) {
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
        // Its bots stay on Bots Home from the switch on, read off the
        // roster it had, so the grid never loses them waiting for a read.
        seedCombinedDashboardBots(outgoingID, from: roster, client: client, glows: glows)
        // Their pills too, from the work it read (and what its plugin
        // serves, so the next read needs no second ask). With none read on
        // this visit, what was seeded before it goes: a pill from before the
        // visit (a wait answered meanwhile) never shows until the next read.
        if !work.isEmpty {
            combinedDashboardBotWork[outgoingID] = work
        } else if combinedDashboardBotWork[outgoingID] != nil {
            combinedDashboardBotWork.removeValue(forKey: outgoingID)
        }
        if let pluginCapabilities {
            combinedDashboardPluginCapabilities[outgoingID] = (ObjectIdentifier(bridge), pluginCapabilities)
        }
        // Its profiles stay on Chats' strip too, from the list it had, and
        // its chats are read for All at once rather than on the next poll
        // (Eric, 2026-11-16, who saw the strip lose them after a switch).
        // Marked as read long ago, so the next pass still asks its Hermes
        // for the list (one made or deleted there meanwhile shows).
        if !profiles.isEmpty {
            keptDashboardProfiles[outgoingID] = (ObjectIdentifier(bridge), profiles, .distantPast)
        }
        // An entry even with no chats listed, so its profiles outlast the
        // kept connection dropping; one not listed yet keeps the chats it
        // had (#2644 review).
        if !chats.isEmpty || !profiles.isEmpty {
            let rows = chats.isEmpty
                ? (combinedDashboardChats[outgoingID]?.sessions ?? [])
                : chats.map { row in
                    var row = row
                    row.combinedDashboardID = outgoingID
                    return row
                }
            // Marked as read long ago, so the next pass reads them anew;
            // a read started before now can't overwrite them.
            combinedDashboardChats[outgoingID] = CombinedDashboardChats(
                bridge: ObjectIdentifier(bridge),
                profiles: profiles.isEmpty ? Array(Set(chats.compactMap(\.profile))).sorted() : profiles,
                sessions: rows,
                at: .distantPast,
                seededAt: Date()
            )
        }
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
                self.dropKeptDashboardRuntime(id, keepingLists: true)
                // Dropped on its own (the network, the server restarting):
                // down, and tried again while Conduit is on screen.
                self.noteCombinedDashboardFailed(id, .down)
            }
        }
        clearCombinedDashboardTrouble(id)
    }

    /// The dashboard's kept connection, taken out of the kept set, when it
    /// is still open and on the profile the switch resumes. One that
    /// dropped, or is on another profile, is let go and the switch signs in
    /// as before.
    func takeKeptDashboardRuntime(_ id: UUID, profile: String) -> KeptDashboardRuntime? {
        guard let kept = keptDashboardRuntimes.removeValue(forKey: id) else { return nil }
        guard isInCombinedGroup(id),
              keptClientIsOpen(kept.client),
              // On another profile, its socket is handed to a client on this
              // one (`keptClient(_:on:)`), as a profile switch keeps it.
              (kept.client.profile ?? "default") == profile || kept.client.canHandOffSocket,
              // Still the dashboard's address (an edit since lets it go).
              let dashboard = savedDashboardRegistry.dashboard(with: id),
              kept.connection.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == dashboard.normalizedURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            release(kept)
            return nil
        }
        return kept
    }

    /// The client a kept connection is taken up with on `profile`: its own,
    /// or, on another profile, a new one its socket is handed to, as a
    /// profile switch keeps the socket. So a pick of another dashboard's
    /// profile lands there at once, never first on the profile it last used
    /// (Eric, 2026-11-16). Nil, with the connection let go, when the socket
    /// can't be handed on; the switch then signs in as before. Sets the
    /// kept bridge as the dashboard's, which the new client authorizes by.
    func keptClient(_ kept: KeptDashboardRuntime, on profile: String) -> HermesClient? {
        dashboardTicketBridge = kept.bridge
        guard (kept.client.profile ?? "default") != profile else { return kept.client }
        let next = makeClient(connection: kept.connection, profile: profile)
        next.inheritSessionProfiles(from: kept.client)
        guard kept.client.handOffSocket(to: next) else {
            dashboardTicketBridge = nil
            next.disconnect()
            release(kept)
            return nil
        }
        noteConnectionStep("Kept socket taken up on another profile")
        return next
    }

    /// Signed out of or moved: its kept connection goes, and a quiet sign-in
    /// still out for it keeps nothing it finishes.
    func letGoCombinedDashboard(_ id: UUID) {
        if combinedSignInsUnderWay.contains(id) { combinedSignInsCalledOff.insert(id) }
        combinedSignInBridges.removeValue(forKey: id)?.invalidate()
        dropKeptDashboardRuntime(id)
        // Its lists go too, even when its connection had already dropped
        // (they stand through a drop, below).
        forgetCombinedDashboardLists(id)
        // The next pass says what it waits for now.
        clearCombinedDashboardTrouble(id)
    }

    /// `keepingLists`: a connection that dropped by itself (the network, the
    /// server restarting, Conduit off screen past the grace) leaves its
    /// chats, bots and Pulse chip listed as last read until it's back, so
    /// they don't come and go with each blip (Eric, 2026-11-16); a tap
    /// signs in as a switch does. Its waits go either way: a stale one
    /// would ask for an answer that may be given.
    func dropKeptDashboardRuntime(_ id: UUID, keepingLists: Bool = false) {
        guard let kept = keptDashboardRuntimes.removeValue(forKey: id) else { return }
        release(kept)
        // Nothing more of its own in Needs you (stage 4a), nor its profiles.
        keptDashboardProfiles.removeValue(forKey: id)
        if !keepingLists { forgetCombinedDashboardLists(id) }
        if id != activeDashboardID {
            needsYou.forgetOtherDashboards(otherThan: Set(keptDashboardRuntimes.keys))
        }
    }

    /// A combined dashboard's chats in the Chats list (stage 4b), bots on
    /// Bots Home (stage 4c) and chip on Pulse (stage 4d) go.
    func forgetCombinedDashboardLists(_ id: UUID) {
        if combinedDashboardChats[id] != nil { combinedDashboardChats.removeValue(forKey: id) }
        if combinedDashboardBots[id] != nil { combinedDashboardBots.removeValue(forKey: id) }
        if combinedDashboardBotWork[id] != nil { combinedDashboardBotWork.removeValue(forKey: id) }
        combinedDashboardPluginCapabilities.removeValue(forKey: id)
        if combinedDashboardPulse[id] != nil { combinedDashboardPulse.removeValue(forKey: id) }
        // Its artifact file readers too (#2644 review).
        let prefix = "\(id.uuidString)|"
        keptGatewayMediaResolvers = keptGatewayMediaResolvers.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Every kept connection goes: Conduit has been off screen past the
    /// background grace (iOS would suspend the sockets anyway). Signing
    /// out of one dashboard lets only its own go.
    func dropAllKeptDashboardRuntimes(keepingLists: Bool = false) {
        // A quiet sign-in still out keeps nothing it finishes.
        keptDashboardRuntimesGeneration &+= 1
        for id in Array(keptDashboardRuntimes.keys) {
            dropKeptDashboardRuntime(id, keepingLists: keepingLists)
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
            // Their lists stand until the return reconnects them.
            self.dropAllKeptDashboardRuntimes(keepingLists: true)
        }
    }

    /// Once the dashboard on screen has connected and synced (at launch, on
    /// a return to Conduit, after a switch): every other combined dashboard
    /// not yet kept signs in quietly beside it, up to the cap. One that
    /// needs typing, or a Face ID unlock this launch hasn't had, is left
    /// for a tap.
    /// `only`: a down dashboard's own retry tries it alone, so another's
    /// retry never cuts its wait short.
    func connectOtherCombinedDashboards(only: UUID? = nil) {
        // Beside any dashboard on screen, one left out of the group
        // included: the group connects when Conduit opens.
        guard combinedDashboardsCanConnect, let activeID = activeDashboardID else { return }
        // The one on screen connected: nothing to say of it or try again.
        clearCombinedDashboardTrouble(activeID)
        // Registry order: the Saved Dashboards list as the user sees it.
        // One whose address was edited signs in on its next switch, which
        // settles the move first.
        for dashboard in savedDashboardRegistry.dashboards
        where isInCombinedGroup(dashboard.id) && dashboard.id != activeID && dashboard.pendingURL == nil
            && (only == nil || dashboard.id == only) {
            let id = dashboard.id
            guard keptDashboardRuntimes[id] == nil,
                  !combinedSignInsUnderWay.contains(id),
                  // Its sign-in was refused: it waits for a tap (opening
                  // it), never asked again on its own.
                  !combinedSignInsRefused.contains(id) else { continue }
            // The one on screen counts too. One down past the cap says
            // nothing until its turn: no "trying again" with no retry waiting.
            guard keptDashboardRuntimes.count + combinedSignInsUnderWay.count < Self.combinedLiveDashboardCap - 1 else {
                // Its backoff stands: when its turn comes, a failure waits
                // on from where it was.
                standDownCombinedDashboardRetry(id)
                continue
            }
            guard combinedDashboardSignsInQuietly(id) else {
                // Waits for a tap, and says so.
                noteCombinedDashboardFailed(id, .signInNeeded)
                continue
            }
            combinedSignInsUnderWay.insert(id)
            // This pass is its retry: the one waiting goes.
            combinedDashboardRetries[id]?.task?.cancel()
            combinedDashboardRetries[id]?.task = nil
            let generation = keptDashboardRuntimesGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                let outcome = await self.signInCombinedDashboardQuietly(id)
                self.combinedSignInsUnderWay.remove(id)
                self.combinedSignInsCalledOff.remove(id)
                self.combinedSignInBridges.removeValue(forKey: id)
                if case .failed(let trouble) = outcome, self.isInCombinedGroup(id) {
                    self.noteCombinedDashboardFailed(id, trouble)
                    if trouble == .signInNeeded { self.combinedSignInsRefused.insert(id) }
                }
                // Dropped (past the cap meanwhile, or no longer wanted) with
                // no retry waiting: no "trying again" either (issue 2615).
                if case .dropped = outcome, self.keptDashboardRuntimes[id] == nil,
                   self.combinedDashboardRetries[id]?.task == nil {
                    self.standDownCombinedDashboardRetry(id)
                }
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
    private func signInCombinedDashboardQuietly(_ id: UUID) async -> CombinedSignInOutcome {
        guard let dashboard = savedDashboardRegistry.dashboard(with: id) else { return .dropped }
        // Called off between the pass and this start: nothing is asked of
        // the old address.
        guard !combinedSignInsCalledOff.contains(id) else { return .dropped }
        let generation = keptDashboardRuntimesGeneration
        let baseURL = dashboard.normalizedURL
        let profile = rememberedActiveProfile(for: id) ?? "default"
        let access = KeychainHelper.loadCloudflareAccess(dashboardID: id, for: baseURL)
        let bridge = makeDashboardBridge(normalizedURL: baseURL, dashboardID: id, access: access)
        combinedSignInBridges[id] = bridge
        var client: HermesClient?
        // Signed out, moved to another address or removed meanwhile: what
        // it finishes isn't wanted. Sign Out and a move call it off; a
        // removal takes it out of the registry. No Keychain reads here: it
        // runs on the main actor at each step.
        func stillWanted() -> Bool {
            guard let current = savedDashboardRegistry.dashboard(with: id) else { return false }
            return generation == keptDashboardRuntimesGeneration
                && !combinedSignInsCalledOff.contains(id)
                && isSceneActive
                && isInCombinedGroup(id)
                && id != activeDashboardID
                && keptDashboardRuntimes[id] == nil
                && current.normalizedURL == baseURL
                && current.pendingURL == nil
        }
        do {
            let ticket: String
            if KeychainHelper.loadNativeOAuthTokens(dashboardID: id) == nil,
               let credentials = KeychainHelper.loadCredentials(dashboardID: id) {
                guard !credentials.requiresFaceID || faceIDUnlockHolds(for: id, credentials) else {
                    bridge.invalidate()
                    return .failed(.signInNeeded)
                }
                let signedIn = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: access)
                    .connect(username: credentials.username, password: credentials.password)
                guard stillWanted() else {
                    bridge.invalidate()
                    return .dropped
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
                return .dropped
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
                // Over the cap is no failure: it waits for its turn, as
                // the pass leaves one past the cap.
                return .dropped
            }
            KeychainHelper.saveConnection(connection, dashboardID: id)
            keep(KeptDashboardRuntime(
                client: opened,
                bridge: bridge,
                connection: connection,
                keptAt: Date()
            ), for: id)
            lifecycleLog.notice("Combined dashboard connected in the background")
            return .connected
        } catch {
            client?.disconnect()
            bridge.invalidate()
            lifecycleLog.notice("Combined dashboard background sign-in failed: \(error.localizedDescription, privacy: .private)")
            guard stillWanted() else { return .dropped }
            return .failed(Self.troubleAfterCombinedSignIn(error))
        }
    }

    // MARK: - Status and retries (stage 3c)

    /// What the Saved Dashboards row and the dashboard menu say of a
    /// combined dashboard other than the one on screen; nil for the one on
    /// screen, one outside the group, or one past the cap waiting its turn.
    func combinedDashboardStatus(_ id: UUID) -> CombinedDashboardStatus? {
        guard isInCombinedGroup(id), id != activeDashboardID else { return nil }
        if keptDashboardRuntimes[id] != nil { return .live }
        if combinedSignInsUnderWay.contains(id) { return .connecting }
        switch combinedDashboardTrouble[id] {
        case .down: return .down
        case .signInNeeded: return .signInNeeded
        case nil: return nil
        }
    }

    /// The longest wait between retries of a down dashboard.
    static let combinedDashboardRetryMaxDelay: TimeInterval = 300

    /// The wait before retry `attempt` (from 1): `base`, doubling each
    /// time, to `combinedDashboardRetryMaxDelay` at most.
    nonisolated static func combinedDashboardRetryDelay(attempt: Int, base: TimeInterval) -> TimeInterval {
        min(base * pow(2, Double(min(max(attempt, 1) - 1, 16))), max(combinedDashboardRetryMaxDelay, base))
    }

    /// A quiet sign-in refused (the password or the grant turned down) waits
    /// for a tap; anything else on the way is down and tried again.
    nonisolated static func troubleAfterCombinedSignIn(_ error: Error) -> CombinedDashboardTrouble {
        switch error {
        case DashboardTicketBridgeError.signInRequired:
            return .signInNeeded
        case AuthClientError.loginFailed(let status, _), AuthClientError.ticketFailed(let status, _):
            return status == 401 || status == 403 ? .signInNeeded : .down
        case DashboardTicketBridgeError.http(let status, _) where status == 401 || status == 403:
            return .signInNeeded
        default:
            return .down
        }
    }

    /// A combined dashboard couldn't connect: the rows and the menu say
    /// why, and one that's down is tried again after a wait that doubles
    /// each time, while Conduit is on screen (a return to Conduit tries
    /// it at once).
    func noteCombinedDashboardFailed(_ id: UUID, _ trouble: CombinedDashboardTrouble) {
        guard isInCombinedGroup(id), id != activeDashboardID else { return }
        if combinedDashboardTrouble[id] != trouble { combinedDashboardTrouble[id] = trouble }
        guard trouble == .down else {
            combinedDashboardRetries.removeValue(forKey: id)?.task?.cancel()
            return
        }
        let attempt = (combinedDashboardRetries[id]?.attempt ?? 0) + 1
        let delay = Self.combinedDashboardRetryDelay(attempt: attempt, base: combinedDashboardRetryBaseDelay)
        combinedDashboardRetries[id]?.task?.cancel()
        let task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.combinedDashboardRetries[id]?.task = nil
            // Off screen, or the one on screen not connected: no pass can
            // try it, so it stops saying "trying again"; the pass that
            // comes once it can (a return, a connect, a reconnect) tries it
            // at once, from where its backoff stood (issue 2615).
            guard self.combinedDashboardsCanConnect else {
                self.standDownCombinedDashboardRetry(id)
                return
            }
            self.connectOtherCombinedDashboards(only: id)
        }
        combinedDashboardRetries[id] = CombinedDashboardRetry(attempt: attempt, task: task)
    }

    /// A pass can sign the others in: Conduit on screen, the one on screen
    /// connected, and a group. Beside any dashboard on screen, one left out
    /// of the group included: the group connects when Conduit opens.
    var combinedDashboardsCanConnect: Bool {
        isSceneActive && isConnected && activeDashboardID != nil && !savedDashboardRegistry.combinedGroupIDs.isEmpty
    }

    /// A down dashboard no retry can try for now says nothing ("trying
    /// again" stands only with a retry waiting); its backoff stands, so a
    /// failure when its turn comes waits on from where it was.
    func standDownCombinedDashboardRetry(_ id: UUID) {
        guard combinedDashboardTrouble[id] == .down else { return }
        combinedDashboardTrouble.removeValue(forKey: id)
        combinedDashboardRetries[id]?.task?.cancel()
        combinedDashboardRetries[id]?.task = nil
    }

    /// Connected, on screen, signed out of, or out of the group: nothing
    /// to say of it, and no retry.
    func clearCombinedDashboardTrouble(_ id: UUID) {
        if combinedDashboardTrouble[id] != nil { combinedDashboardTrouble.removeValue(forKey: id) }
        combinedSignInsRefused.remove(id)
        combinedDashboardRetries.removeValue(forKey: id)?.task?.cancel()
    }

    private func keptClientIsOpen(_ client: HermesClient) -> Bool {
        client.isConnected
    }

    private func release(_ kept: KeptDashboardRuntime) {
        kept.client.disconnect()
        kept.bridge.invalidate()
    }
}
