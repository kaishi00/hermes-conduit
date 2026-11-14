//
//  AppState+SignIn.swift
//  Conduit
//
//  Signing in: the client, restoring a saved connection and its
//  credentials, Face ID, the offline chat instead of sign-in, and a
//  sign-in that's required. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Signing in and restoring a saved connection

    func makeClient(connection: HermesConnection, profile: String) -> HermesClient {
        let transportFactory: @MainActor () -> any HermesWebSocketTransport = chatResumeLifecycleOperations.makeTransport ?? { URLSessionWebSocketTransport() }
        let client = HermesClient(
            connection: connection,
            profile: profile,
            cloudflareAccess: dashboardScopedCloudflareAccess(for: connection.baseUrl),
            // The current bridge's authorizer: it attaches its session
            // cookies only to its own dashboard's address.
            requestAuthorizer: dashboardTicketBridge?.requestAuthorizer,
            transportFactory: transportFactory
        )
        // A reconnect off screen (CarPlay, a locked listen) keeps the
        // background keepalive.
        client.setKeepaliveBackgrounded(!isSceneActive && hasEnteredBackgroundScenePhase)
        let epoch = UUID()
        activeClientEpoch = epoch
        client.onEvent = { [weak self, weak client] event in
            // Read while the client delivers this event: the turn it names,
            // and the queued message it ran from.
            let turnGeneration = client?.deliveringEventGeneration
            let admissionID = client?.deliveringEventAdmissionID
            Task { @MainActor in
                guard let self, self.activeClientEpoch == epoch else { return }
                self.handleStreamEvent(event, turnGeneration: turnGeneration)
                if case .messageStart(let sessionID) = event, let admissionID {
                    self.noteQueuedTurnStarted(sessionID: sessionID, admissionID: admissionID)
                }
            }
        }
        client.onDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self, self.activeClientEpoch == epoch else { return }
                self.handleDisconnect()
            }
        }
        return client
    }

    /// Cold-start restore of the saved connection. Its ticket was spent when
    /// it last opened the socket, so the dashboard bridge mints a fresh one
    /// first; the saved record is only the fallback when that mint fails.
    /// A failed mint alone never sends the user to login (requiring a freshly
    /// restored WebKit cookie before every launch was what turned a healthy
    /// saved Hermes session into login), but the fallback handshake can still
    /// be refused: `stopRecoveryForRefusedSocket` then stops recovery at the
    /// sign-in screen, while any other connect failure schedules a reconnect.
    func restoreSavedConnection(_ saved: HermesConnection, switchGeneration: UInt64? = nil, widgetLease: WidgetLaunchLease? = nil) async {
        guard widgetLease?.isCurrent != false else { return }
        // Early reads its connect didn't take (or that a restore given up
        // left) end with it.
        defer { startupReads.clear() }
        if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
            return
        }
        prepareDashboardBridge(for: saved.baseUrl)
        // Re-fence after the bridge's async setup window: never install a
        // stale switch's connection.
        if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
            return
        }
        guard widgetLease?.isCurrent != false else { return }
        // The saved ticket was spent when it last opened the socket (Hermes'
        // tickets are single-use and last 30 seconds), so a fresh one is
        // minted with the dashboard's cookies first, as the OAuth restore
        // does. A mint that fails leaves the saved record, which `connect`
        // handles like any other: a refused handshake goes to sign-in, any
        // other failure schedules a reconnect. A cancelled one (the bridge
        // torn down by a switch or a sign-out) ends this restore, as it
        // does the OAuth restore's: the spent ticket is never tried.
        var connection = saved
        do {
            let ticket = try await mintChatResumeTicket(for: saved)
            connection = HermesConnection(baseUrl: saved.baseUrl, ticket: ticket)
        } catch is CancellationError {
            if restoreOwnsFlow(switchGeneration), widgetLease?.isCurrent != false {
                isConnecting = false
                // The synchronizing state loadSavedConnection set goes too,
                // as a foreground boundary leaves an aborted recovery's: it
                // would keep the composer off with nothing left to clear it.
                if turnState == .synchronizing { setRunning(false) }
            }
            return
        } catch {}
        // Re-fence after the mint await.
        if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
            return
        }
        guard widgetLease?.isCurrent != false else { return }
        await connect(with: connection, profile: activeProfile)
        guard widgetLease?.isCurrent != false else { return }
    }

    func restoreSavedCredentials(
        _ credentials: DashboardCredentials,
        dashboardID: UUID? = nil,
        switchGeneration: UInt64? = nil,
        widgetLease: WidgetLaunchLease? = nil
    ) async {
        // A superseded dashboard switch owns the flow; this stale restore
        // must not prompt, spend network, or install its connection — and it
        // must not touch presentation state the newer switch now owns.
        if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
            return
        }
        guard widgetLease?.isCurrent != false else { return }
        let scopedDashboardID = dashboardID ?? activeDashboardID
        rememberDashboardURL(credentials.baseURL)

        // One Face ID unlock holds while Conduit runs: the offline retries
        // (each return from the Face ID sheet makes the scene active again)
        // must not ask again, or the sheet loops until the server answers,
        // and neither does a switch to another saved dashboard.
        let faceIDUnlockHeld = scopedDashboardID.map { faceIDUnlockHolds(for: $0, credentials) } ?? false
        if credentials.requiresFaceID, faceIDUnlockHeld {
            if let scopedDashboardID {
                // A retry keeps the copy already on screen.
                if offlineChatPresentation == nil {
                    presentOfflineChatIfAvailable(dashboardID: scopedDashboardID)
                }
                if offlineChatPresentation != nil {
                    showLogin = false
                    isConnecting = true
                }
            }
        } else if credentials.requiresFaceID {
            guard await unlockWithFaceID() else {
                // A superseded switch owns the flow: present nothing.
                guard restoreOwnsFlow(switchGeneration) else { return }
                guard widgetLease?.isCurrent != false else { return }
                // Face ID or Touch ID can't show off the phone screen (a call from Hermes
                // woke Conduit, or only CarPlay shows it): the saved session
                // connects, as it does when a locked phone keeps the
                // password unreadable.
                if widgetLease == nil, phoneScreenIsAway(), let scopedDashboardID,
                   restoreSavedSessionOffScreen(
                    dashboardID: scopedDashboardID,
                    baseURL: credentials.baseURL,
                    switchGeneration: switchGeneration
                   ) {
                    return
                }
                guard widgetLease?.isCurrent != false else { return }
                showLogin = true
                widgetLease?.fail(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
                return
            }
            // Re-fence after the biometric await: a superseded switch owns
            // the flow now.
            if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
                return
            }
            faceIDUnlockedThisLaunch = true
            if let scopedDashboardID {
                faceIDUnlockedDashboards[scopedDashboardID] = Self.faceIDUnlockFingerprint(credentials)
                faceIDRelockedDashboards.remove(scopedDashboardID)
            }
            // The user just unlocked the saved password for the selected
            // dashboard: the sign-in finishes even if the widget launch
            // expired meanwhile.
            if let scopedDashboardID {
                presentOfflineChatIfAvailable(dashboardID: scopedDashboardID)
                if offlineChatPresentation != nil {
                    showLogin = false
                    isConnecting = true
                }
            }
        }

        let signInStartedAt = Date()
        do {
            let access = scopedDashboardID.flatMap {
                KeychainHelper.loadCloudflareAccess(dashboardID: $0, for: credentials.baseURL)
            }
            let authenticatedConnection: NativeAuthConnection
            do {
                authenticatedConnection = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: access).connect(
                    username: credentials.username,
                    password: credentials.password
                )
                noteConnectionStep("Password sign-in and ticket", since: signInStartedAt)
            } catch {
                noteConnectionStep("Password sign-in and ticket", since: signInStartedAt, error: error)
                throw error
            }
            // Re-fence after the network await: never install a stale
            // switch's connection (its adoptDashboard would flip selection).
            if let switchGeneration, !switchGenerationIsCurrent(switchGeneration) {
                return
            }
            if let scopedDashboardID {
                authenticatedConnection.commitCookies(dashboardID: scopedDashboardID)
            }
            await connect(with: HermesConnection(baseUrl: credentials.baseURL, ticket: authenticatedConnection.ticket), profile: activeProfile)
        } catch is CancellationError {
            // A superseded connect owns the flow from here; fall back to the
            // login screen silently — but only if THIS restore still owns
            // the flow. A stale restore (a newer switch won) writes nothing.
            if restoreOwnsFlow(switchGeneration) { showLogin = true }
        } catch {
            // A rejected saved password falls back to the native login screen
            // without erasing it, allowing the user to correct the account.
            // The typed classified handoff replaces the old string write, so
            // the composer banner never inherits a stale sign-in message.
            presentCredentialRestoreFailure(
                ConnectionFailureClassifier.classify(error),
                switchGeneration: switchGeneration
            )
        }
    }

    /// Clears the dashboard's saved password and the Face ID unlock that
    /// held for it: a password saved for it again asks again.
    func clearSavedPassword(dashboardID: UUID) {
        KeychainHelper.clearCredentials(dashboardID: dashboardID)
        relockFaceID(dashboardID: dashboardID)
    }

    /// The dashboard's next sign-in with a saved password asks for Face ID
    /// again, whatever the launch's unlock.
    func relockFaceID(dashboardID: UUID) {
        faceIDUnlockedDashboards[dashboardID] = nil
        faceIDRelockedDashboards.insert(dashboardID)
    }

    /// Whether an unlock this launch covers the dashboard's saved password.
    /// A dashboard unlocked before holds while its password is the one
    /// unlocked (a different one saved later asks again); any other holds
    /// after the launch's first unlock unless it was relocked since.
    func faceIDUnlockHolds(for dashboardID: UUID, _ credentials: DashboardCredentials) -> Bool {
        if let fingerprint = faceIDUnlockedDashboards[dashboardID] {
            return fingerprint == Self.faceIDUnlockFingerprint(credentials)
        }
        return faceIDUnlockedThisLaunch && !faceIDRelockedDashboards.contains(dashboardID)
    }

    private static func faceIDUnlockFingerprint(_ credentials: DashboardCredentials) -> SHA256.Digest {
        SHA256.hash(data: Data([credentials.baseURL, credentials.username, credentials.password].joined(separator: "\u{1f}").utf8))
    }

    /// Connects with the dashboard's saved session (its ticket, renewed with
    /// its cookies) instead of the Face ID-protected password, for a restore
    /// running off the phone screen. False when there is no saved session
    /// for that address.
    private func restoreSavedSessionOffScreen(
        dashboardID: UUID,
        baseURL: String,
        switchGeneration: UInt64?
    ) -> Bool {
        guard let saved = KeychainHelper.loadConnection(dashboardID: dashboardID),
              saved.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            return false
        }
        HermesCallTrace.shared.note("Face ID can't show off screen: using the saved session")
        noteConnectionStep("Saved session (Face ID can't show off screen)")
        connection = saved
        showLogin = false
        isConnecting = true
        turnState = .synchronizing
        Task { await restoreSavedConnection(saved, switchGeneration: switchGeneration) }
        return true
    }

    /// The saved sign-in, again, now that Conduit is on screen: the attempt
    /// made in the background couldn't show Face ID or read a password the
    /// locked phone kept. A dashboard with nothing saved left just shows its
    /// sign-in, as before.
    func retrySignInFromBackground() {
        signInWaitsForForeground = false
        // Launched before the first unlock after a restart, the Keychain
        // couldn't give the saved dashboards: read them again now. An
        // upgrade that ran on a locked phone couldn't read the old saved
        // password: it joins its dashboard now.
        if savedDashboardRegistry.dashboards.isEmpty {
            let stored = SavedDashboardMigrator.loadRegistry(defaults: defaults)
            if let primary = stored.dashboards.first?.id {
                // Pre-scoping appearance and preferences belong to the first
                // dashboard (same rule as launch). Adopted before selecting
                // it, so the selection's reload reads them.
                profileAppearanceStore.adoptLegacyAppearance(into: primary)
                adoptLegacyProfilePreferences(into: primary)
                savedDashboardRegistry = stored
                // Launch ordered the cached profiles with no dashboard's order.
                profiles = orderedProfiles(profiles)
            }
        } else {
            SavedDashboardMigrator.adoptLeftoverCredentials(into: savedDashboardRegistry)
        }
        // Nothing saved to sign in with (an off-screen switch to a dashboard
        // with no reusable auth): the sign-in card keeps its explanation.
        guard let dashboardID = activeDashboardID, hasSavedSignIn(dashboardID: dashboardID) else { return }
        HermesCallTrace.shared.note("Signing in again on screen (signed out in the background)")
        // The failure belongs to the background attempt; the retry reports
        // its own.
        pendingLoginFailure = nil
        lastConnectionFailure = nil
        errorMessage = nil
        loadSavedConnection(trigger: "retry on screen")
    }

    /// Whether the dashboard has anything `loadSavedConnection` signs in
    /// with: an OAuth grant, a saved password or a saved session.
    func hasSavedSignIn(dashboardID: UUID) -> Bool {
        KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) != nil
            || KeychainHelper.loadCredentials(dashboardID: dashboardID) != nil
            || KeychainHelper.loadConnection(dashboardID: dashboardID) != nil
    }

    /// Whether a restore that started under this switch generation may still
    /// write state. Nil generations (non-switch restore paths) always own.
    func restoreOwnsFlow(_ generation: UInt64?) -> Bool {
        guard let generation else { return true }
        return switchGenerationIsCurrent(generation)
    }

    /// The fenced failure presentation for a saved-credential restore: a
    /// superseded restore (a newer dashboard switch won) must not set
    /// `showLogin`, `pendingLoginFailure`, or `lastConnectionFailure` over
    /// the winner's state. Returns whether anything was written (test seam).
    @discardableResult
    func presentCredentialRestoreFailure(
        _ failure: ConnectionFailure,
        switchGeneration: UInt64?
    ) -> Bool {
        guard restoreOwnsFlow(switchGeneration) else { return false }
        if keepOfflineChatInsteadOfSignIn(failure) { return true }
        wipeOfflineChatCacheForSignIn(after: failure, dashboardID: activeDashboardID)
        lastConnectionFailure = failure
        showLogin = true
        pendingLoginFailure = .presenting(failure)
        // The saved-password restore never resets the plugin status.
        endLockScreenTurnsForSignIn(plugin: notifierPlugin.state)
        return true
    }

    /// Server-unreachable failures that leave the saved offline copy on
    /// screen instead of sending the user to sign-in. Authentication
    /// failures always go to sign-in. A server that refuses this network
    /// (an IP allowlist, issue #2092) is unreachable from here too: signing
    /// in again can't get past it.
    static func failureKeepsOfflineChat(_ failure: ConnectionFailure) -> Bool {
        switch failure {
        case .hostNotFound, .unreachable, .connectionRefused, .timedOut, .offline, .dashboardUnavailable, .accessDenied:
            return true
        default:
            return false
        }
    }

    /// Cold-launch restore failed because the server could not be reached:
    /// keep the read-only saved copy up (composer disabled) and retry on the
    /// next foreground or explicit Retry. Returns false when there is no
    /// copy or the failure needs sign-in.
    func keepOfflineChatInsteadOfSignIn(_ failure: ConnectionFailure) -> Bool {
        guard offlineChatPresentation != nil, Self.failureKeepsOfflineChat(failure) else { return false }
        lastConnectionFailure = failure
        isConnecting = false
        isConnected = false
        // Same state the saved-ticket path reaches through connect's failure:
        // recovery is pending, not synchronizing.
        turnState = .reconnecting
        showLogin = false
        return true
    }

    /// Retry from the offline copy. With no connection yet (the cold-launch
    /// restore never completed) this re-runs the saved-dashboard restore;
    /// otherwise the normal reconnect path owns recovery.
    func retryFromOfflineChat() {
        guard offlineChatPresentation != nil, !isConnecting else { return }
        if connection == nil {
            loadSavedConnection(trigger: "retry from offline copy")
        } else {
            // Same purpose rule as a foreground recovery: with no conversation
            // selected yet (a cold launch), the automatic resume picks it.
            let purpose = foregroundRecoveryPurpose
            Task {
                cancelChatResumeTransportRecovery()
                await executeReconnect(purpose: purpose)
            }
        }
    }

    /// An authentication failure means the saved copy can no longer be tied
    /// to a signed-in account: the next sign-in may be a DIFFERENT account on
    /// the same dashboard, so the dashboard's files go too — not just the
    /// in-memory copy. Unreachable-server failures keep them (they are what
    /// the copy exists for).
    func wipeOfflineChatCacheForSignIn(after failure: ConnectionFailure, dashboardID: UUID?) {
        guard !Self.failureKeepsOfflineChat(failure), let dashboardID else { return }
        wipeOfflineChatCache(dashboardID: dashboardID)
    }

    /// Every interactive sign-in (password, dashboard web login, native
    /// OAuth) starts from no saved copy for that dashboard: the account
    /// signing in may not be the one whose conversations were saved.
    func prepareInteractiveSignIn(baseURL: String) {
        prepareInteractiveSignIn(dashboardID: resolveDashboardID(forURL: baseURL, registerIfMissing: false))
    }

    func prepareInteractiveSignIn(dashboardID: UUID?) {
        guard let dashboardID else { return }
        wipeOfflineChatCache(dashboardID: dashboardID)
    }

    /// Opens sign-in from the offline copy. The copy leaves the screen (and
    /// memory) with it; the files stay on disk.
    func signInFromOfflineChat() {
        showLogin = true
    }

    func prepareDashboardBridge(for baseUrl: String) {
        let normalized = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let access = dashboardScopedCloudflareAccess(for: normalized)
        let dashboardID = resolveDashboardID(forURL: normalized, registerIfMissing: false)
        let storedNativeOAuthTokens = dashboardID.flatMap {
            KeychainHelper.loadNativeOAuthTokens(dashboardID: $0)
        }
        if dashboardTicketBridge?.baseURL != normalized
            || dashboardTicketBridge?.cloudflareAccess != access
            || dashboardTicketBridge?.extraHeaders != CustomHeaderPolicy.sendable(CustomHeaderStore.shared.headers(forServerURL: normalized))
            || dashboardTicketBridge?.matchesNativeOAuthTokens(storedNativeOAuthTokens) != true {
            // Header or sign-in changes keep the host, so its plugin status
            // still holds; a new host is asked again on connect.
            if dashboardTicketBridge?.baseURL != normalized {
                notifierPlugin = freshNotifierPluginStatus
            }
            dashboardTicketBridge?.invalidate()
            // The selected dashboard's request authority: its native grant
            // (or cookie mode), its origin and base path, and the other saved
            // dashboards it must never authorize for, read live so adding or
            // removing one applies at once.
            let requestAuthorizer = DashboardRequestAuthorizer.forDashboard(
                baseURL: normalized,
                dashboardID: dashboardID,
                cloudflareAccess: access,
                otherDashboardURLs: { [weak self] in
                    self?.savedDashboardRegistry.dashboards
                        .filter { $0.id != dashboardID }
                        .map(\.normalizedURL) ?? []
                }
            )
            let bridge = DashboardTicketBridge(
                baseURL: normalized,
                cloudflareAccess: access,
                dashboardID: dashboardID,
                requestAuthorizer: requestAuthorizer
            )
            bridge.onPageEvent = { [weak self, weak bridge] event in
                guard let self, let bridge, self.dashboardTicketBridge === bridge else { return }
                self.noteConnectionStep(event)
            }
            // Early reads through the bridge this replaces are no one's now.
            startupReads.clear()
            dashboardTicketBridge = bridge
        } else if let bridge = dashboardTicketBridge, bridge.requiresSignIn {
            // The same dashboard's page settled on sign-in, and a connection
            // is starting again: a browser sign-in just put a fresh session
            // in this dashboard's WebKit store. Load the page again so the
            // next ticket is minted with it, not refused by the old verdict.
            bridge.reload()
        }
    }

    /// Classification seam for the silent-renewal sign-in handoff: when a
    /// saved-password re-auth was attempted and failed, that error (429
    /// throttle, 401 rejection, 503 outage) explains far more than the bare
    /// bridge signInRequired. The winning error is classified — never
    /// rendered via errorDescription. Internal for unit testing.
    static func silentRenewalSignInFailure(
        reauthError: Error?,
        bridgeError: DashboardTicketBridgeError
    ) -> ConnectionFailurePresentation {
        .presenting(reauthError.map(ConnectionFailureClassifier.classify)
            ?? ConnectionFailureClassifier.classify(bridgeError))
    }

    /// Forces the sign-in screen with a classified failure presentation.
    /// Prefer this overload whenever the failure derives from an Error — the
    /// full presentation (title, actions, help routing) reaches the login
    /// card untouched.
    func requireSignIn(failure: ConnectionFailurePresentation) {
        performSignInRequired(pendingFailure: failure)
    }

    /// Forces the sign-in screen with a human-authored notice message. Only
    /// for genuinely hand-written strings — Error-derived text must go
    /// through requireSignIn(failure:) so it is classified, never rendered
    /// raw.
    func requireSignIn(message: String) {
        performSignInRequired(pendingFailure: .notice(title: AppLocalization.string("Sign-in didn’t complete"), message: message))
    }

    /// Which of the dashboard's Lock Screen turns a required sign-in ends.
    enum SignInLockScreenTurnsEnd: Equatable {
        /// None: off the phone screen the refusal is weak evidence, retried
        /// once Conduit is on screen.
        case keepAll
        /// Those whose push token this iPhone's current relay installation
        /// didn't take: the Conduit plugin still ends the others by push,
        /// whatever Conduit's own sign-in.
        case endNotOnRelay
        /// All of them: without the plugin nothing else will.
        case endAll

        /// `liveTurnActivitiesEndDashboard`'s `keepingThoseOnRelay`, or nil
        /// when none end.
        var keepingThoseOnRelay: Bool? {
            switch self {
            case .keepAll: nil
            case .endNotOnRelay: true
            case .endAll: false
            }
        }
    }

    /// What a required sign-in does to the dashboard's Lock Screen turns.
    /// What stays open: a plugin too old to push Live Activity updates,
    /// which no capability reports yet; a turn the relay took a token for
    /// then keeps counting until the system's own limit.
    nonisolated static func signInEndsLockScreenTurns(
        screenAway: Bool,
        plugin: NotifierPluginStatus.State
    ) -> SignInLockScreenTurnsEnd {
        guard !screenAway else { return .keepAll }
        if case .reported = plugin { return .endNotOnRelay }
        return .endAll
    }

    func performSignInRequired(
        pendingFailure: ConnectionFailurePresentation,
        keepingNativeGrant: Bool = false
    ) {
        cancelChatResumeTransportRecovery()
        invalidateReconciliation()
        invalidateGroupChatState()
        cancelSecondaryProfileTitleRecovery()
        client?.disconnect()
        client = nil
        owedPostConnectBootstrap = nil
        isConnected = false
        isConnecting = false
        connectedAt = nil
        connection = nil
        dashboardTicketBridge?.invalidate()
        dashboardTicketBridge = nil
        let pluginStateBeforeSignIn = notifierPlugin.state
        notifierPlugin = freshNotifierPluginStatus
        // A forced sign-out kills the bridge mid-playback; stop the read
        // aloud and drop its gateway the same way Disconnect does.
        messageReadAloudController.stop()
        messageReadAloudController.setGateway(nil)
        readAloudGatewayBridge = nil
        readAloudSpeaker = nil
        // Forced sign-out supersedes any suspended Voice conversation (the
        // restore-time connection identity check would fail closed anyway);
        // stop the controller and drop the sheet immediately like
        // Disconnect does instead of waiting for the next scene cycle.
        suspendedVoiceConversation = nil
        voiceSheetShouldAutoListen = false
        voiceControllerSessionProfile = nil
        voiceConversationController.stop()
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        showVoiceSheet = false
        clearClassicVoiceCards()
        projects = []
        supportsProjects = false
        projectsLoading = false
        projectsLoadFailed = false
        // Off the phone screen, a renewal is refused on thinner evidence: no
        // page retries, and a locked phone can't re-sign in with the saved
        // password. The saved session and copy stay for the retry on screen
        // (signInWaitsForForeground), which retires them if the dashboard
        // refuses it there too.
        if !phoneScreenIsAway() {
            if let dashboardID = activeDashboardID {
                // Forced sign-out is scoped like Disconnect: only the active
                // dashboard's saved ticket (and cookie mirror) is retired. A
                // refused socket keeps the native grant: a refusal is never
                // a sign-out.
                if keepingNativeGrant {
                    KeychainHelper.clearSavedSession(dashboardID: dashboardID)
                } else {
                    KeychainHelper.clearConnection(dashboardID: dashboardID)
                }
            }
            wipeOfflineChatCache(dashboardID: activeDashboardID)
        }
        turnState = .idle
        retireOutstandingPreferredReturnSurfaceRequests()
        // The banner content belonged to the session being torn down; with
        // the LoginView onAppear consume gone, this is what keeps a
        // connected-era error from resurfacing stale after re-login.
        errorMessage = nil
        showLogin = true
        pendingLoginFailure = pendingFailure
        endLockScreenTurnsForSignIn(plugin: pluginStateBeforeSignIn)
    }

    /// A refused or expired sign-in of the active dashboard (required,
    /// saved password, native OAuth restore): a turn of it nothing can end
    /// now stops counting up on the Lock Screen. A cancelled Face ID isn't
    /// a refusal, and leaves them for the retry. `plugin` is the notifier
    /// plugin's state before the sign-in reset it.
    func endLockScreenTurnsForSignIn(plugin: NotifierPluginStatus.State) {
        if let keepingThoseOnRelay = Self.signInEndsLockScreenTurns(
            screenAway: phoneScreenIsAway(),
            plugin: plugin
        ).keepingThoseOnRelay {
            liveTurnActivitiesEndDashboard(activeDashboardID?.uuidString, keepingThoseOnRelay)
        }
    }
}
