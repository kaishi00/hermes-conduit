//
//  AppState+Dashboards.swift
//  Conduit
//
//  Saved dashboards: registering, adopting, switching, signing out of and
//  removing one, and what each dashboard keeps apart (display
//  preferences, relay gateway ids, model visibility). Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Dashboard-scoped presentation (#148)

    static func dashboardPreferenceBucket(_ dashboardID: UUID?) -> String {
        dashboardID?.uuidString ?? "unscoped"
    }

    /// Re-reads everything profile-presentational for the newly selected
    /// dashboard. Runs whenever the selection changes (switch intent,
    /// adoption, removal), so dashboard B never renders A's label, photos,
    /// or hidden models, even while B is still connecting. Profile order is
    /// applied by `orderedProfiles` when B's profiles are discovered. The
    /// photo scan lists one small per-dashboard folder, only on a deliberate
    /// selection change.
    func reloadDashboardScopedPresentation() {
        let dashboardID = activeDashboardID
        defaultProfileName = profileAppearanceStore.loadDefaultName(dashboardID: dashboardID)
        profileAvatarURLs = profileAppearanceStore.loadAvatarURLs(dashboardID: dashboardID)
        profileGlowPicks = profileAppearanceStore.loadGlowColors(dashboardID: dashboardID)
        profileDeviceNames = profileAppearanceStore.loadDeviceNames(dashboardID: dashboardID)
        profileBotTitles = profileAppearanceStore.loadBotTitles(dashboardID: dashboardID)
        profileHermesNames = profileAppearanceStore.loadHermesNames(dashboardID: dashboardID)
        modelVisibility = scopedModelVisibility(dashboardID: dashboardID)
        modelQuickPicks = storedModelQuickPicks()[Self.dashboardPreferenceBucket(dashboardID)] ?? ModelQuickPicks()
        restoreDisplayPreferences()
    }

    private static let displayPreferencesByProfileKey = "profileDisplayPreferencesByDashboard"

    private static func displayPreferencesKey(dashboardID: UUID?, profile: String) -> String {
        "\(dashboardPreferenceBucket(dashboardID)).\(profile)"
    }

    /// The preferences last read or set for this dashboard's profile.
    func storedDisplayPreferences(dashboardID: UUID?, profile: String) -> ProfileDisplayPreferences? {
        let stored = defaults.dictionary(forKey: Self.displayPreferencesByProfileKey) as? [String: Data] ?? [:]
        guard let data = stored[Self.displayPreferencesKey(dashboardID: dashboardID, profile: profile)] else { return nil }
        return try? JSONDecoder().decode(ProfileDisplayPreferences.self, from: data)
    }

    func rememberDisplayPreferences() {
        guard let data = try? JSONEncoder().encode(displayPreferences) else { return }
        var stored = defaults.dictionary(forKey: Self.displayPreferencesByProfileKey) as? [String: Data] ?? [:]
        stored[Self.displayPreferencesKey(dashboardID: activeDashboardID, profile: activeProfile)] = data
        defaults.set(stored, forKey: Self.displayPreferencesByProfileKey)
    }

    /// Another dashboard or profile: its last known preferences until its
    /// config is read, Hermes' defaults for one never read here.
    func restoreDisplayPreferences() {
        displayPreferences = storedDisplayPreferences(dashboardID: activeDashboardID, profile: activeProfile)
            ?? ProfileDisplayPreferences()
    }

    /// One-time move of the pre-scoping global profile order and model
    /// visibility into the registry's first dashboard (the one they were set
    /// on). A later dashboard starts from its own defaults.
    func adoptLegacyProfilePreferences(into primary: UUID?) {
        guard let primary else { return }
        let bucket = Self.dashboardPreferenceBucket(primary)
        if let legacyOrder = defaults.stringArray(forKey: profileOrderKey) {
            var orders = defaults.dictionary(forKey: profileOrderByDashboardKey) as? [String: [String]] ?? [:]
            if orders[bucket] == nil {
                orders[bucket] = legacyOrder
                defaults.set(orders, forKey: profileOrderByDashboardKey)
            }
            defaults.removeObject(forKey: profileOrderKey)
        }
        if let data = defaults.data(forKey: modelVisibilityKey) {
            if let legacy = try? JSONDecoder().decode(ModelVisibility.self, from: data) {
                var visibilities = storedModelVisibilities()
                if visibilities[bucket] == nil {
                    visibilities[bucket] = legacy
                    persistModelVisibilities(visibilities)
                }
            }
            defaults.removeObject(forKey: modelVisibilityKey)
        }
    }

    private func storedModelVisibilities() -> [String: ModelVisibility] {
        guard let data = defaults.data(forKey: modelVisibilityByDashboardKey),
              let stored = try? JSONDecoder().decode([String: ModelVisibility].self, from: data) else { return [:] }
        return stored
    }

    private func persistModelVisibilities(_ visibilities: [String: ModelVisibility]) {
        if let data = try? JSONEncoder().encode(visibilities) {
            defaults.set(data, forKey: modelVisibilityByDashboardKey)
        }
    }

    func scopedModelVisibility(dashboardID: UUID?) -> ModelVisibility {
        storedModelVisibilities()[Self.dashboardPreferenceBucket(dashboardID)] ?? ModelVisibility()
    }

    func storedModelQuickPicks() -> [String: ModelQuickPicks] {
        guard let data = defaults.data(forKey: modelQuickPicksByDashboardKey),
              let stored = try? JSONDecoder().decode([String: ModelQuickPicks].self, from: data) else { return [:] }
        return stored
    }

    private func persistModelQuickPicks(_ picks: [String: ModelQuickPicks]) {
        if let data = try? JSONEncoder().encode(picks) {
            defaults.set(data, forKey: modelQuickPicksByDashboardKey)
        }
    }

    /// Changes the active dashboard's Quick picks and keeps them.
    func updateModelQuickPicks(_ change: (inout ModelQuickPicks) -> Void) {
        var picks = modelQuickPicks
        change(&picks)
        guard picks != modelQuickPicks else { return }
        modelQuickPicks = picks
        var stored = storedModelQuickPicks()
        stored[Self.dashboardPreferenceBucket(activeDashboardID)] = picks
        persistModelQuickPicks(stored)
    }

    func rememberedActiveProfile(for dashboardID: UUID) -> String? {
        let map = defaults.dictionary(forKey: activeProfileByDashboardKey) as? [String: String] ?? [:]
        guard let profile = map[dashboardID.uuidString]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty else { return nil }
        return profile
    }

    func rememberActiveProfile(_ profile: String, for dashboardID: UUID) {
        var map = defaults.dictionary(forKey: activeProfileByDashboardKey) as? [String: String] ?? [:]
        map[dashboardID.uuidString] = profile
        defaults.set(map, forKey: activeProfileByDashboardKey)
    }

    func forgetActiveProfile(for dashboardID: UUID) {
        var map = defaults.dictionary(forKey: activeProfileByDashboardKey) as? [String: String] ?? [:]
        guard map.removeValue(forKey: dashboardID.uuidString) != nil else { return }
        defaults.set(map, forKey: activeProfileByDashboardKey)
    }

    /// Records the active profile both as the cold-launch value and as the
    /// active dashboard's own choice, so switching back to a dashboard lands
    /// on its profile instead of whichever one the outgoing dashboard used.
    func persistActiveProfile(_ profile: String) {
        // Per-dashboard entry first, global key last: cold launch opens the
        // global key and mirrors it into the active dashboard's entry, so
        // an interrupted write can only lose the change, never split them.
        if let dashboardID = activeDashboardID {
            rememberActiveProfile(profile, for: dashboardID)
        }
        defaults.set(profile, forKey: activeProfileKey)
    }

    /// Drops every dashboard-scoped presentation choice of a removed
    /// dashboard.
    private func removeDashboardScopedPresentation(_ id: UUID) {
        profileAppearanceStore.removeAll(dashboardID: id)
        if dashboardsFinishingSetup.contains(id) { dashboardsFinishingSetup.remove(id) }
        // The Watch forgets its main profile name.
        shareWatchCallVoices()
        forgetActiveProfile(for: id)
        let bucket = Self.dashboardPreferenceBucket(id)
        var orders = defaults.dictionary(forKey: profileOrderByDashboardKey) as? [String: [String]] ?? [:]
        if orders.removeValue(forKey: bucket) != nil {
            defaults.set(orders, forKey: profileOrderByDashboardKey)
        }
        var visibilities = storedModelVisibilities()
        if visibilities.removeValue(forKey: bucket) != nil {
            persistModelVisibilities(visibilities)
        }
        var quickPicks = storedModelQuickPicks()
        if quickPicks.removeValue(forKey: bucket) != nil {
            persistModelQuickPicks(quickPicks)
        }
        forgetPulseHome(of: id)
        forgetPulseFoldedBriefs(of: id)
    }

    // MARK: Relay gateways each dashboard's host reported

    /// Per dashboard, each profile's gateway: `[dashboard id: [profile: gateway id]]`.
    private static let relayGatewayIDsByDashboardKey = "conduit.relayGatewayIDsByDashboardProfile"

    /// The relay gateway ids the active dashboard's host said its profiles
    /// pair this iPhone through. A push stamped with one of them came from
    /// that host, whatever dashboard its pairing was bound to.
    var activeDashboardRelayGatewayIDs: Set<String> {
        guard let activeDashboardID else { return [] }
        return relayGatewayIDs(of: activeDashboardID)
    }

    func relayGatewayIDs(of dashboardID: UUID) -> Set<String> {
        Set(storedRelayGatewayIDs()[dashboardID.uuidString]?.values.map { $0 } ?? [])
    }

    /// Every relay gateway a saved dashboard's host said it pairs this
    /// iPhone through.
    var knownRelayGatewayIDs: Set<String> {
        Set(storedRelayGatewayIDs().values.flatMap(\.values))
    }

    /// Nil unless every pairing of this dashboard's hosts is end-to-end
    /// encrypted with a key the host confirmed; true when every one is also
    /// quantum-safe (the details are in Settings > Notifications). Drawn on
    /// dashboard rows and shared with the Watch.
    func notificationsEncryption(of dashboardID: UUID) -> Bool? {
        let notifications = PushNotificationService.shared
        guard notifications.isEnabled else { return nil }
        let gatewayIDs = relayGatewayIDs(of: dashboardID)
        guard !gatewayIDs.isEmpty else { return nil }
        var allQuantumSafe = true
        for gatewayID in gatewayIDs {
            guard case .ensured(_, _, let quantumSafe) = notifications.encryptionAssurance(gatewayID: gatewayID) else { return nil }
            allQuantumSafe = allQuantumSafe && quantumSafe
        }
        return allQuantumSafe
    }

    /// Remembers that `dashboardID`'s host pairs `profile` with this iPhone
    /// through `gatewayID`, as that host said over its signed-in connection.
    /// The profile's last report replaces its earlier one, so a re-pairing
    /// (or another host now at that address) leaves no stale id behind.
    func recordRelayGatewayID(_ gatewayID: String, for dashboardID: UUID, profile: String) {
        let gatewayID = gatewayID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gatewayID.isEmpty, gatewayID.count <= 80 else { return }
        var stored = storedRelayGatewayIDs()
        guard stored[dashboardID.uuidString]?[profile] != gatewayID else { return }
        stored[dashboardID.uuidString, default: [:]][profile] = gatewayID
        saveRelayGatewayIDs(stored)
    }

    func forgetRelayGatewayID(for dashboardID: UUID, profile: String) {
        var stored = storedRelayGatewayIDs()
        guard stored[dashboardID.uuidString]?.removeValue(forKey: profile) != nil else { return }
        saveRelayGatewayIDs(stored)
    }

    func forgetRelayGatewayIDs(of dashboardID: UUID) {
        var stored = storedRelayGatewayIDs()
        guard stored.removeValue(forKey: dashboardID.uuidString) != nil else { return }
        saveRelayGatewayIDs(stored)
    }

    /// Settings > Notifications sorts pairings by these, so it redraws; and
    /// Pulse pushes from a host's gateways offer Quiet for today by them.
    private func saveRelayGatewayIDs(_ stored: [String: [String: String]]) {
        objectWillChange.send()
        defaults.set(stored, forKey: Self.relayGatewayIDsByDashboardKey)
        sharePulseQuiet()
    }

    private func storedRelayGatewayIDs() -> [String: [String: String]] {
        defaults.dictionary(forKey: Self.relayGatewayIDsByDashboardKey) as? [String: [String: String]] ?? [:]
    }

    /// The All pill stays fixed; the remaining session categories are local UI preference.
    func moveSessionFilters(fromOffsets: IndexSet, toOffset: Int) {
        sessionFilterOrder.move(fromOffsets: fromOffsets, toOffset: toOffset)
        defaults.set(sessionFilterOrder.map(\.rawValue), forKey: sessionFilterOrderKey)
    }

    /// The dashboard location is harmless preference data, unlike the one-time
    /// ticket stored in Keychain. Keep it after sign-out so the next login does
    /// not require re-entering a server address.
    var lastDashboardURL: String {
        defaults.string(forKey: dashboardURLKey) ?? connection?.baseUrl ?? ""
    }

    func rememberDashboardURL(_ url: String) {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(url) else { return }
        defaults.set(normalized, forKey: dashboardURLKey)
    }

    func saveModelVisibility(_ visibility: ModelVisibility) {
        let normalized = ModelVisibility(
            hiddenProviders: Array(Set(visibility.hiddenProviders.filter { !$0.isEmpty })).sorted(),
            hiddenModels: Array(Set(visibility.hiddenModels.filter { !$0.isEmpty })).sorted()
        )
        modelVisibility = normalized
        var visibilities = storedModelVisibilities()
        visibilities[Self.dashboardPreferenceBucket(activeDashboardID)] = normalized
        persistModelVisibilities(visibilities)
    }

    // MARK: - Saved dashboards (#148)

    /// Resolves the saved dashboard reached at this URL. Normalized URLs are
    /// unique in the registry; `registerIfMissing` creates (but does not
    /// activate) an entry, for pre-connection writes such as the browser
    /// sign-in's Cloudflare token save.
    @discardableResult
    func resolveDashboardID(forNormalizedURL normalized: String, registerIfMissing: Bool) -> UUID? {
        if let existing = savedDashboardRegistry.dashboardID(atNormalizedURL: normalized) {
            return existing
        }
        guard registerIfMissing else { return nil }
        return registerDashboard(forNormalizedURL: normalized)
    }

    /// Registers a saved dashboard for this address (if missing) and returns
    /// its UUID — never optional, so adoption and pre-connection writes have
    /// one non-failable registration path.
    @discardableResult
    func registerDashboard(forNormalizedURL normalized: String) -> UUID {
        if let existing = savedDashboardRegistry.dashboardID(atNormalizedURL: normalized) {
            return existing
        }
        // The selected dashboard's own edited address is that dashboard,
        // moved, for every pre-connection write as for adoption. While it's
        // in use the move waits, and a dashboard added here is a new one.
        if let activeID = activeDashboardID,
           savedDashboardRegistry.dashboard(with: activeID)?.pendingURL == normalized,
           dashboardForSignIn(activeID)?.normalizedURL == normalized {
            return activeID
        }
        // A dashboard added here is its own, even at an address another
        // saved dashboard was moving to: that dashboard stays where it is.
        dropPendingDashboardMoves(toNormalizedURL: normalized)
        var registry = savedDashboardRegistry
        let id = UUID()
        let label = SavedDashboardLabel.derive(from: normalized, existingLabels: registry.dashboards.map(\.label))
        let isFirstDashboard = registry.dashboards.isEmpty
        registry.dashboards.append(SavedDashboard(id: id, label: label, normalizedURL: normalized))
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
        // Its first connection offers Finish setting up on Chats.
        dashboardsFinishingSetup.insert(id)
        if isFirstDashboard {
            // Pre-scoping appearance/preferences with no dashboard to own
            // them yet belong to the first one (same rule as launch).
            profileAppearanceStore.adoptLegacyAppearance(into: id)
            adoptLegacyProfilePreferences(into: id)
            // No reload: a registered dashboard is not selected yet, and
            // selecting it (adoptDashboard/switch) reloads through didSet.
        }
        return id
    }

    func resolveDashboardID(forURL baseURL: String, registerIfMissing: Bool) -> UUID? {
        let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolveDashboardID(forNormalizedURL: normalized, registerIfMissing: registerIfMissing)
    }

    /// Connection adoption: resolves the dashboard this connection belongs
    /// to (registering it when new) and makes it the active/selected target.
    /// Idempotent for reconnects. When the stored chat-resume identity still
    /// names this server by URL (the pre-adoption boundary ran before the
    /// dashboard existed), it is relabeled to the UUID so the next
    /// connection to this dashboard is recognized as same-server.
    @discardableResult
    func adoptDashboard(forNormalizedURL normalized: String) -> UUID {
        // The selected dashboard connecting at the address edited for it
        // in Settings is that dashboard, moved, not a second one.
        if savedDashboardRegistry.dashboardID(atNormalizedURL: normalized) == nil,
           let activeID = savedDashboardRegistry.activeDashboardID,
           savedDashboardRegistry.dashboard(with: activeID)?.pendingURL == normalized {
            settlePendingDashboardMove(activeID)
        }
        let id = registerDashboard(forNormalizedURL: normalized)
        if savedDashboardRegistry.activeDashboardID != id {
            var registry = savedDashboardRegistry
            registry.activeDashboardID = id
            savedDashboardRegistry = registry
            SavedDashboardRegistryStore.save(registry)
        }
        if let stored = defaults.string(forKey: Self.chatResumeServerIdentityKey),
           let normalizedStored = Self.normalizedChatResumeServerIdentity(stored),
           normalizedStored == normalized {
            defaults.set(id.uuidString, forKey: Self.chatResumeServerIdentityKey)
        }
        return id
    }

    /// Saves an address edited in Settings for the dashboard's next sign-in
    /// (`SavedDashboard.pendingURL`). Its current address cancels a move
    /// saved before; a password saved for the address it no longer moves to
    /// goes too, or its next sign-in would reach that address as a second
    /// dashboard.
    func stageDashboardMove(_ id: UUID, toNormalizedURL url: String) {
        guard let index = savedDashboardRegistry.dashboards.firstIndex(where: { $0.id == id }) else { return }
        if let previous = savedDashboardRegistry.dashboards[index].pendingURL, previous != url,
           let credentials = KeychainHelper.loadCredentials(dashboardID: id),
           Self.normalizedDashboardURL(credentials.baseURL) == previous {
            clearSavedPassword(dashboardID: id)
        }
        var registry = savedDashboardRegistry
        registry.dashboards[index].pendingURL = url == registry.dashboards[index].normalizedURL ? nil : url
        guard registry != savedDashboardRegistry else { return }
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
    }

    /// The saved dashboard as its next sign-in reaches it: an address edited
    /// in Settings takes effect now, unless it's the dashboard in use.
    func dashboardForSignIn(_ id: UUID) -> SavedDashboard? {
        if id == activeDashboardID && (isConnected || isConnecting) {
            return savedDashboardRegistry.dashboard(with: id)
        }
        return settlePendingDashboardMove(id)
    }

    /// Moves the dashboard to the address saved for it in Settings. What the
    /// old address signed in with can't reconnect at the new one: its ticket
    /// and cookie mirror go, so does a password saved for it, and a browser
    /// grant from another origin. A same-origin Cloudflare token follows
    /// (the plan's path-move rule). Keychain first, registry last: a move
    /// cut short is retried. An address another dashboard took meanwhile
    /// keeps it, and this one stays where it is.
    @discardableResult
    func settlePendingDashboardMove(_ id: UUID) -> SavedDashboard? {
        guard let dashboard = savedDashboardRegistry.dashboard(with: id) else { return nil }
        guard let newURL = dashboard.pendingURL else { return dashboard }
        if savedDashboardRegistry.dashboard(atNormalizedURL: newURL) != nil {
            dropPendingDashboardMoves(toNormalizedURL: newURL)
            return savedDashboardRegistry.dashboard(with: id)
        }
        let oldURL = dashboard.normalizedURL
        let sameOrigin = LoginCloudflareHandoff.sameOrigin(oldURL, newURL)
        KeychainHelper.clearSavedSession(dashboardID: id)
        if !sameOrigin {
            KeychainHelper.clearNativeOAuthTokens(dashboardID: id)
        }
        if let credentials = KeychainHelper.loadCredentials(dashboardID: id),
           Self.normalizedDashboardURL(credentials.baseURL) != newURL {
            clearSavedPassword(dashboardID: id)
        }
        if sameOrigin,
           let access = KeychainHelper.loadCloudflareAccess(dashboardID: id, for: oldURL), access.isConfigured {
            KeychainHelper.saveCloudflareAccess(access, origin: newURL, dashboardID: id)
        }
        guard let index = savedDashboardRegistry.dashboards.firstIndex(where: { $0.id == id }) else { return nil }
        var registry = savedDashboardRegistry
        registry.dashboards[index].normalizedURL = newURL
        registry.dashboards[index].pendingURL = nil
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
        // The old address's host reported them; the new one reports its own.
        forgetRelayGatewayIDs(of: id)
        // Who manages the plugin goes with the host: a moved entry's new host
        // says for itself. Signing out keeps it (same host).
        NotifierPluginStatus.Remembered.remember(nil, for: id, in: defaults)
        return registry.dashboards[index]
    }

    /// Cancels the moves saved for this address. The password saved for a
    /// move would send that dashboard's next sign-in here: it goes too.
    private func dropPendingDashboardMoves(toNormalizedURL url: String) {
        var registry = savedDashboardRegistry
        for index in registry.dashboards.indices where registry.dashboards[index].pendingURL == url {
            let id = registry.dashboards[index].id
            if let credentials = KeychainHelper.loadCredentials(dashboardID: id),
               Self.normalizedDashboardURL(credentials.baseURL) == url {
                clearSavedPassword(dashboardID: id)
            }
            registry.dashboards[index].pendingURL = nil
        }
        guard registry != savedDashboardRegistry else { return }
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
    }

    private static func normalizedDashboardURL(_ url: String) -> String {
        (try? ConnectionURLPolicy.normalizedBaseURL(url)) ?? url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The origin-matched Cloudflare token for the dashboard reached at this
    /// URL, read from that dashboard's scoped record only.
    func dashboardScopedCloudflareAccess(for baseURL: String?) -> CloudflareAccessCredentials? {
        guard let baseURL else { return nil }
        let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dashboardID = resolveDashboardID(forNormalizedURL: normalized, registerIfMissing: false) else { return nil }
        return KeychainHelper.loadCloudflareAccess(dashboardID: dashboardID, for: baseURL)
    }

    /// Saved password credentials for the dashboard reached at this URL.
    func savedCredentialsForDashboard(at baseURL: String) -> DashboardCredentials? {
        guard let dashboardID = resolveDashboardID(forURL: baseURL, registerIfMissing: false) else { return nil }
        return KeychainHelper.loadCredentials(dashboardID: dashboardID)
    }

    /// How a saved dashboard can sign in without typing, for the sign-in
    /// screen's list. Reads the Keychain: call it off the render path.
    func savedSignIn(for id: UUID) -> SavedSignInKind {
        if let credentials = KeychainHelper.loadCredentials(dashboardID: id) {
            return credentials.requiresFaceID ? .biometric : .password
        }
        if KeychainHelper.loadConnection(dashboardID: id) != nil
            || KeychainHelper.loadNativeOAuthTokens(dashboardID: id) != nil {
            return .session
        }
        return .signInNeeded
    }

    /// Records the username that just signed in to this dashboard, so a
    /// later sign-in starts with it filled in.
    func rememberDashboardUsername(_ username: String, dashboardID: UUID) {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = savedDashboardRegistry.dashboards.firstIndex(where: { $0.id == dashboardID }),
              savedDashboardRegistry.dashboards[index].username != trimmed else { return }
        var registry = savedDashboardRegistry
        registry.dashboards[index].username = trimmed
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
    }

    /// Sign Out deletes the saved password but keeps its username on the
    /// dashboard, for sign-ins saved before the registry recorded it.
    func keepUsernameForNextSignIn(dashboardID: UUID) {
        guard let credentials = KeychainHelper.loadCredentials(dashboardID: dashboardID) else { return }
        rememberDashboardUsername(credentials.username, dashboardID: dashboardID)
    }

    /// Switch to a saved dashboard. Switching is NOT disconnecting: the
    /// outgoing dashboard stays saved with its auth intact, but its runtime
    /// ownership (client, sessions, speech) is retired IMMEDIATELY through
    /// the authoritative `prepareChatResumeForConnection` boundary — a
    /// switch that then fails to authenticate must not leave the outgoing
    /// server streaming behind the new target's sign-in surface. The target
    /// becomes the selected dashboard BEFORE connecting, so a failed switch
    /// leaves it selected; no other dashboard is auto-connected.
    ///
    /// A switch runs to its end even when the task that asked for it is
    /// cancelled: by the time it signs in to the target it has already
    /// retired the outgoing connection, so stopping there leaves neither
    /// dashboard connected. A newer switch supersedes it by generation,
    /// never by cancellation. A notification's tap is the case in point:
    /// its route restarts when `isConnected` flips, which the retirement
    /// does, and that cancelled the target's sign-in halfway, leaving
    /// Conduit on the login screen "connecting" to it (issue 1888).
    func switchDashboard(to id: UUID, widgetLease: WidgetLaunchLease? = nil) async {
        await Task { @MainActor in
            await self.runDashboardSwitch(to: id, widgetLease: widgetLease)
        }.value
    }

    private func runDashboardSwitch(to id: UUID, widgetLease: WidgetLaunchLease?) async {
        // A pick from the list, or a launch's own switch (a widget, a draft).
        endLaunchDashboardChoice()
        if widgetLease == nil { widgetLaunchCoordinator.supersede() }
        guard widgetLease?.isCurrent != false else { return }
        widgetAwaitingInteractiveAuthenticationDashboardID = nil
        guard savedDashboardRegistry.dashboard(with: id) != nil else { return }
        if id == activeDashboardID && (isConnected || isConnecting) {
            // Already there: a same-dashboard reconnect is not a switch.
            return
        }
        guard let dashboard = dashboardForSignIn(id) else { return }
        // Another dashboard's waits never show on this one's chips.
        needsYou.reset(dashboardID: id)
        dashboardSwitchGeneration &+= 1
        let generation = dashboardSwitchGeneration
        let previousDashboardID = activeDashboardID
        // The outgoing dashboard's chat and Chats list as they show now are
        // what the next visit there opens to.
        recordOfflineChatCopy()
        keepBotChatCopy()
        // The owner taken for the chat on screen is this dashboard's.
        outgoingBotChatCopyOwner = nil
        recordSavedChatList()
        selectDashboardTarget(id)
        // Pulse's badge, marks and chat are the outgoing dashboard's.
        pulseUnseen = 0
        pulseSources = [:]
        pulseHomeChatID = nil
        // The Pulse widget stops reading the outgoing dashboard's feed; this
        // one's pass comes once it has connected.
        if let previousDashboardID, previousDashboardID != id { removePulseWidget(dashboardID: previousDashboardID) }
        rememberDashboardURL(dashboard.normalizedURL)
        let crossedServer = prepareChatResumeForConnection(to: dashboard.normalizedURL, dashboardID: id)
        retireConnectionRuntimeForDashboardSwitch()
        if crossedServer || previousDashboardID != id {
            // Resume on the target's own profile, not the outgoing
            // dashboard's: profile names are not shared between servers.
            // The boundary above already retired the outgoing profile's
            // speech, transcript, and catalogs. Checked against the
            // selection too: with no stored server identity (first switch
            // after a fresh install) the boundary reports no change.
            let targetProfile = rememberedActiveProfile(for: id) ?? "default"
            setActiveProfile(targetProfile)
            persistActiveProfile(targetProfile)
            restoreActiveSessionState(for: targetProfile)
            restorePinnedSessions(for: targetProfile)
        }
        // Mirrors cold launch: the target's own saved copy and Chats list,
        // kept while another dashboard was in use, show until it answers.
        // A browser sign-in's OAuth grant comes first, as it does there: it
        // mints a fresh ticket, where a saved one may already be spent, and
        // it is all a dashboard has left once a refused session was cleared.
        if KeychainHelper.loadNativeOAuthTokens(dashboardID: id) != nil {
            presentOfflineChatIfAvailable(dashboardID: id)
            showLogin = false
            isConnecting = true
            turnState = .synchronizing
            await restoreNativeOAuthConnection(
                baseURL: dashboard.normalizedURL,
                dashboardID: id,
                switchGeneration: generation,
                widgetLease: widgetLease
            )
            settleExpiredWidgetDashboardSwitch(generation: generation, widgetLease: widgetLease)
            return
        }
        if let credentials = KeychainHelper.loadCredentials(dashboardID: id) {
            if !credentials.requiresFaceID {
                presentOfflineChatIfAvailable(dashboardID: id)
                if offlineChatPresentation != nil {
                    showLogin = false
                    isConnecting = true
                }
            }
            await restoreSavedCredentials(credentials, dashboardID: id, switchGeneration: generation, widgetLease: widgetLease)
            settleExpiredWidgetDashboardSwitch(generation: generation, widgetLease: widgetLease)
            return
        }
        if let saved = KeychainHelper.loadConnection(dashboardID: id) {
            presentOfflineChatIfAvailable(dashboardID: id)
            // Cookie/ticket-based resume: keep the app shell up while the
            // bridge restores the dashboard's own cookie mirror.
            connection = saved
            showLogin = false
            isConnecting = true
            turnState = .synchronizing
            await restoreSavedConnection(saved, switchGeneration: generation, widgetLease: widgetLease)
            settleExpiredWidgetDashboardSwitch(generation: generation, widgetLease: widgetLease)
            return
        }
        // No reusable auth: present the sign-in surface seeded for this
        // dashboard's address.
        turnState = .idle
        if widgetLease != nil { widgetAwaitingInteractiveAuthenticationDashboardID = id }
        showLogin = true
    }

    /// A widget launch that expired while its dashboard switch was restoring
    /// stopped before connecting. The target is already selected and the
    /// outgoing connection retired, so it gets the sign-in surface a failed
    /// restore shows, not a connecting state nothing will finish.
    private func settleExpiredWidgetDashboardSwitch(generation: UInt64, widgetLease: WidgetLaunchLease?) {
        guard widgetLease?.isCurrent == false,
              switchGenerationIsCurrent(generation),
              !isConnected, client == nil else { return }
        isConnecting = false
        turnState = .idle
        showLogin = true
    }

    /// Runtime-only teardown of the live connection when switching
    /// dashboards. `prepareChatResumeForConnection` (called just before) owns
    /// the server-replacement state retirement; this retires the transport
    /// and connection-scoped surfaces it does not touch. Deliberately NOT
    /// disconnect(): no saved auth, cookie mirror, or registry state is
    /// cleared — the outgoing dashboard stays signed in while saved.
    private func retireConnectionRuntimeForDashboardSwitch() {
        // A plugin update follows one dashboard; Hermes finishes it alone.
        stopFollowingNotifierPluginUpdate()
        cancelChatResumeTransportRecovery()
        cancelScenePhaseAttempt()
        cancelScheduledReconnect()
        owedPostConnectBootstrap = nil
        lastConnectionFailure = nil
        pendingLoginFailure = nil
        errorMessage = nil
        client?.disconnect()
        client = nil
        // Fence already-queued callbacks from the outgoing server: they are
        // epoch-gated, and no new client is created on the authless path.
        activeClientEpoch = UUID()
        connection = nil
        isConnected = false
        isConnecting = false
        connectedAt = nil
        dashboardTicketBridge?.invalidate()
        dashboardTicketBridge = nil
        notifierPlugin = freshNotifierPluginStatus
        // A flush scheduled under the outgoing server must not write through
        // after the switch; the boundary already cleared the cache it would
        // resurrect content into.
        presentationCacheFlushTask?.cancel()
        presentationCacheFlushTask = nil
        messageReadAloudController.setGateway(nil)
        readAloudGatewayBridge = nil
        readAloudSpeaker = nil
        voiceConversationController.setGateway(nil)
        voiceCapabilitySnapshot = .unavailable
        isVoiceEnabled = false
        retireCapabilitySnapshot()
        retireOutstandingPreferredReturnSurfaceRequests()
        // An open call transcript is the outgoing dashboard's, and its fetch
        // still in flight must not open one over the next.
        dismissChatCallTranscript()
        retireCronJobsForDashboardSwitch()
    }

    /// The dashboard a request was sent to, through which bridge. Its
    /// result is applied only while both are still the current ones: a
    /// switch replaces the bridge, so a late answer from the dashboard
    /// switched away from changes nothing on the one now showing.
    struct DashboardRuntimeOwner {
        let dashboardID: UUID?
        let bridge: DashboardTicketBridge
    }

    /// The current dashboard and its bridge; nil without a bridge.
    func currentDashboardRuntimeOwner() -> DashboardRuntimeOwner? {
        dashboardTicketBridge.map { DashboardRuntimeOwner(dashboardID: activeDashboardID, bridge: $0) }
    }

    func ownsDashboardRuntime(_ owner: DashboardRuntimeOwner) -> Bool {
        owner.bridge === dashboardTicketBridge && owner.dashboardID == activeDashboardID
    }

    func switchGenerationIsCurrent(_ generation: UInt64) -> Bool {
        generation == dashboardSwitchGeneration
    }

    /// Marks a dashboard as the selected target without connecting. A failed
    /// switch leaves the target selected — retry/repair is presented for it,
    /// and no other dashboard is auto-connected.
    func selectDashboardTarget(_ id: UUID) {
        guard savedDashboardRegistry.dashboard(with: id) != nil else { return }
        guard savedDashboardRegistry.activeDashboardID != id else { return }
        var registry = savedDashboardRegistry
        registry.activeDashboardID = id
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
    }

    /// Sign Out of This Dashboard: clears the dashboard's reusable
    /// auth/session/cookie material — and nothing else. SavedDashboard
    /// metadata and every other dashboard's state are untouched. For the
    /// active dashboard this is the full Disconnect teardown, scoped.
    func signOutDashboard(_ id: UUID) {
        guard let dashboard = savedDashboardRegistry.dashboard(with: id) else { return }
        // The host signed in next reports its own gateways.
        forgetRelayGatewayIDs(of: id)
        // Drafts shared for this dashboard belong to the signed-out user.
        discardSharedDrafts(forDashboard: id)
        if id == activeDashboardID {
            // The signed-out user's waits leave the chips with them.
            needsYou.reset(dashboardID: nil)
            disconnect()
            return
        }
        removeWidgetSnapshot(dashboardID: id)
        liveTurnActivitiesEndDashboard(id.uuidString, false)
        endServerSignIn(dashboardID: id, baseURL: dashboard.normalizedURL)
        KeychainHelper.clearConnection(dashboardID: id)
        keepUsernameForNextSignIn(dashboardID: id)
        clearSavedPassword(dashboardID: id)
        wipeOfflineChatCache(dashboardID: id)
        ShortcutInboxQueue.forgetDashboard(id)
        // The dashboard is not connected, but its OWN web session may still
        // hold live cookies from an earlier session; sign-out removes the
        // identified WebKit store and the dashboard's native jar (plus
        // exact-host shared-jar residue). Sibling dashboards sharing a parent
        // domain are untouched.
        DashboardCookiePersistence.scheduleWebKitSessionClear(for: id)
        DashboardCookiePersistence.clearNativeCookies(dashboardID: id, baseURL: dashboard.normalizedURL)
    }

    /// Hands the dashboard's refresh tokens to Hermes' logout before its
    /// sign-in is deleted, so the server ends it too (#889). Call before
    /// `KeychainHelper.clearConnection`: it reads the native grant and the
    /// cookie mirror.
    func endServerSignIn(dashboardID: UUID, baseURL: String?) {
        guard let baseURL else { return }
        let cookies = DashboardCookiePersistence.mirroredCookies(dashboardID: dashboardID)
            + (DashboardCookiePersistence.nativeCookieStorage(for: dashboardID).cookies ?? [])
        serverSignOutQueue.signOut(
            dashboardID: dashboardID,
            baseURL: baseURL,
            refreshTokens: ServerSignOut.refreshTokens(
                native: KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID),
                cookies: cookies,
                baseURL: baseURL
            ),
            cloudflare: KeychainHelper.loadCloudflareAccess(dashboardID: dashboardID, for: baseURL)
        )
    }

    /// Remove Dashboard: deletes the SavedDashboard and clears ONLY its
    /// secure state. Removing the active dashboard leaves Conduit
    /// disconnected with the dashboard selection/add flow presented — no
    /// other saved dashboard is auto-connected.
    func removeDashboard(_ id: UUID) {
        guard let removed = savedDashboardRegistry.dashboard(with: id) else { return }
        let wasActive = id == activeDashboardID
        if wasActive {
            // Full scoped teardown of the active dashboard's auth and live
            // session (including its origin's cookies).
            disconnect()
        } else {
            signOutDashboard(id)
        }
        // Sign Out keeps the Cloudflare token; forgetting the dashboard
        // doesn't.
        KeychainHelper.clearCloudflareAccess(dashboardID: id)
        var registry = savedDashboardRegistry
        registry.dashboards.removeAll { $0.id == id }
        if registry.activeDashboardID == id { registry.activeDashboardID = nil }
        // Extra proxy headers are server configuration, not session auth:
        // sign-out keeps them, forgetting the server drops them — unless
        // another saved dashboard is still reached through the same origin.
        let removedOrigin = CustomHeaderPolicy.origin(forServerURL: removed.normalizedURL)
        if removedOrigin != nil,
           !registry.dashboards.contains(where: { CustomHeaderPolicy.origin(forServerURL: $0.normalizedURL) == removedOrigin }) {
            CustomHeaderStore.shared.removeHeaders(forServerURL: removed.normalizedURL)
        }
        savedDashboardRegistry = registry
        SavedDashboardRegistryStore.save(registry)
        removeDashboardScopedPresentation(id)
        forgetRelayGatewayIDs(of: id)
        // Who manages the plugin goes with the host: a moved entry's new host
        // says for itself. Signing out keeps it (same host).
        NotifierPluginStatus.Remembered.remember(nil, for: id, in: defaults)
        // Log to Hermes events waiting for it, and its inbox keys.
        ShortcutInboxQueue.forgetDashboard(id)
        // Location, health and phone sharing bound to it.
        endSharingWithRemovedDashboards()
        if wasActive {
            showLogin = true
        }
    }

    /// Location, health and phone sharing each go only to the dashboard they
    /// were turned on for. Once it's no longer saved, nothing can switch back
    /// to it, so sharing with it ends here, as turning it off without
    /// deleting would, and the next turn-on binds to the dashboard in use
    /// (issue 1800). Run when a dashboard is removed, and on each connect for
    /// one removed before this ran: connected, the saved dashboards were
    /// read for sure (before the first unlock they may not be, and an empty
    /// list then isn't a removal).
    func endSharingWithRemovedDashboards(saved: Set<UUID>? = nil) {
        let saved = saved ?? Set(savedDashboardRegistry.dashboards.map(\.id))
        LocationSharingController.shared.endSharing(unlessBoundTo: saved)
        // Each turn-off checks that sharing still goes there when it runs:
        // a turn-on for the dashboard in use may have come first.
        if let destination = healthSyncPreferences.destination, !saved.contains(destination.dashboardID) {
            Task {
                guard healthSyncPreferences.destination == destination else { return }
                await turnOffHealthSync(deleteFromHost: false)
            }
        }
        if let destination = phoneSync.preferences.destination, !saved.contains(destination.dashboardID) {
            Task {
                guard phoneSync.preferences.destination == destination else { return }
                await turnOffPhoneSync(deleteFromHost: false)
            }
        }
    }
}
