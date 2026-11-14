//
//  AppState+Connection.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Connection; Connection
//  management; Connection Repair (Round 6); Reconnect and scene lifecycle.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Connection

    /// For status words and dots only: connecting now, or between the first
    /// few retries after a dropped connection. A drop waits a few seconds
    /// before each early retry with `isConnecting` false, which would
    /// otherwise read as "Disconnected" on every short network blip. After
    /// three failed retries the gateway is likely down, and the words say
    /// so; without a network at all they say so at once.
    var isRecoveringConnection: Bool {
        isConnecting
            || (networkPathUsable && !isConnected && connection != nil
                && turnState == .reconnecting && reconnectAttempts < Self.quietReconnectAttempts)
    }

    /// The retries after a drop that still read as reconnecting, before
    /// the status says the gateway is likely down and a failed sign-in
    /// refresh shows its banner.
    static let quietReconnectAttempts = 3

    /// What a failure kept quiet would show, for a Siri launch that is
    /// waiting on the connection: it fails at once on it, as before.
    var quietReconnectFailureClass: ConnectionFailure? {
        quietReconnectFailure.map { ConnectionFailureClassifier.classify($0) }
    }

    /// As when the socket fails: the first retries run quietly (a
    /// resume's first request often fails before the network is back). The
    /// banner and the classified failure, which offers Repair, wait until
    /// they have failed too, when the status already says the dashboard
    /// looks down (#1624).
    private func retryQuietlyAfterFailedRenewal(_ error: Error) {
        isConnected = false
        isConnecting = false
        turnState = .reconnecting
        noteQuietRenewalFailure(error)
        scheduleReconnectAfterFailedSync()
    }

    /// Keeps a renewal's failure quiet, or shows it once the quiet retries
    /// are spent.
    private func noteQuietRenewalFailure(_ error: Error) {
        quietReconnectFailure = error
        quietRenewalFailures += 1
        // Quiet only on screen: off screen (CarPlay, a locked call, the
        // Watch) it reports at once, as before, since the quiet is for
        // coming back to the app.
        if surfacesRenewalFailureAtOnce
            || !isSceneActive
            || quietRenewalFailures > Self.quietReconnectAttempts {
            surfaceQuietReconnectFailure()
        }
    }

    /// Which silent re-auth failures retry quietly instead of asking to
    /// sign in: those the network cut off. Any answer from the server,
    /// a 5xx included, still asks, as before #1624.
    static func reauthFailureRetriesQuietly(_ error: Error) -> Bool {
        DictationUploadRetry.isTransient(error)
    }

    private func surfaceQuietReconnectFailure() {
        guard let error = quietReconnectFailure else { return }
        quietReconnectFailure = nil
        lastConnectionFailure = ConnectionFailureClassifier.classify(error)
        errorMessage = AppLocalization.string("Failed to refresh the dashboard session: \(UserFacingError.message(for: error))")
    }

    /// Just back on screen and reconnecting: the header stays quiet, since
    /// the reconnect usually lands before anyone could read the words.
    /// Never without a network: that shows at once.
    var hidesBriefReconnect: Bool {
        isReturningQuietly && networkPathUsable && isRecoveringConnection
    }

    static let defaultSessionFilterOrder: [SessionSource] =
        [.chat, .voice, .voiceJob, .discord, .telegram] + SessionSource.gatewayPlatforms + [.api, .webhook, .cron, .other]

    /// Stable per-profile gateway-media resolver for settled row content.
    /// Created lazily on first read and reused while the active profile is
    /// unchanged, so ChatView's first body pass already has a resolver
    /// identity (no nil → resolver invalidation sweep over the settled
    /// transcript) and rows' Equatable gates only open on genuine profile
    /// changes. The resolver holds this AppState weakly, so caching it here
    /// creates no retain cycle.
    var gatewayMediaResolver: GatewayMediaDataURLResolver {
        if let cached = cachedGatewayMediaResolver,
           cached.profile == activeProfile,
           cached.resolver.dashboardID == activeDashboardID {
            return cached.resolver
        }
        let resolver = GatewayMediaDataURLResolver(appState: self, profile: activeProfile)
        cachedGatewayMediaResolver = (activeProfile, resolver)
        return resolver
    }

    /// A stable resolver for another profile's media (a Live Voice job that
    /// ran there), cached so views read the same instance on every pass.
    func gatewayMediaResolver(for profile: String) -> GatewayMediaDataURLResolver {
        if profile == activeProfile { return gatewayMediaResolver }
        if let cached = otherProfileGatewayMediaResolvers[profile],
           cached.dashboardID == activeDashboardID { return cached }
        let resolver = GatewayMediaDataURLResolver(appState: self, profile: profile)
        otherProfileGatewayMediaResolvers[profile] = resolver
        return resolver
    }

    /// The dashboard a connection currently belongs to (the selected target).
    var activeDashboardID: UUID? { savedDashboardRegistry.activeDashboardID }

    // MARK: - Connection management

#if DEBUG
    /// UI-test-only connected state: a snapshot connection with no client and
    /// no transport. Reconnect paths refuse to run while it is active (see
    /// `reconnectForRetry`), so the stubbed session is inert by construction
    /// and Settings-UI tests never touch a network or a real dashboard.
    private static func uiTestConnectedStub() -> HermesConnection? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD"),
              index + 1 < arguments.count else { return nil }
        return HermesConnection(baseUrl: arguments[index + 1], ticket: "ui-test-stub")
    }

    /// UI-test-only FAILED-connection state (Round 6): a snapshot connection
    /// with a surfaced, classified stable failure so the Repair Connection
    /// entry is visible. Inert by construction under the same reconnect
    /// suppression as the connected stub. `-CONDUIT_UI_TEST_FAILURE_KIND
    /// none` retains no failure, so the repair entry opens straight on the
    /// staged test.
    private static func uiTestFailedConnectionStub() -> HermesConnection? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CONDUIT_UI_TEST_FAILED_CONNECTION"),
              index + 1 < arguments.count else { return nil }
        return HermesConnection(baseUrl: arguments[index + 1], ticket: "ui-test-stub")
    }

    private static func uiTestFailureKind() -> ConnectionFailure? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CONDUIT_UI_TEST_FAILURE_KIND"),
              index + 1 < arguments.count else { return .hostNotFound }
        return arguments[index + 1] == "none" ? nil : .hostNotFound
    }

    /// UI-test-only profile roster: `-CONDUIT_UI_TEST_PROFILES "work,staging"`
    /// (comma-separated). Needed because the connection-scoped reset that runs
    /// before this seeds nothing back — it clears `profiles` — and a stub has no
    /// transport for `/api/profiles` discovery to repopulate it from, so a
    /// profile-scoped UI test would otherwise only ever see `default`. The names
    /// go through the same `orderedProfiles` the launch hydration uses, so a
    /// seeded roster behaves exactly like a discovered one (active profile and
    /// `default` are unioned in, order included).
    private static func uiTestSeededProfiles() -> [String]? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CONDUIT_UI_TEST_PROFILES"),
              index + 1 < arguments.count else { return nil }
        let names = arguments[index + 1]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return names.isEmpty ? nil : names
    }
#endif

    /// The setting behind Ask Which Dashboard at Launch (#1908).
    static let asksWhichDashboardAtLaunchKey = "conduit.askDashboardAtLaunch"

    /// The launch's own sign-in. With Ask Which Dashboard at Launch on and
    /// more than one dashboard saved, a plain open leaves the dashboard
    /// list up for a tap; otherwise the last dashboard used signs in, as
    /// it always has.
    func beginLaunchSignIn() {
        guard defaults.bool(forKey: Self.asksWhichDashboardAtLaunchKey),
              savedDashboardRegistry.dashboards.count > 1,
              let activeID = savedDashboardRegistry.activeDashboardID,
              hasSavedSignIn(dashboardID: activeID) else {
            loadSavedConnection()
            return
        }
        lifecycleLog.notice("Launch waits for a dashboard to be picked (Ask Which Dashboard at Launch)")
        serverSignOutQueue.retryPending()
        launchAwaitsDashboardChoice = true
        // Opened in the background (the Watch, a call from Hermes, a place
        // or Health data woke it), no phone screen comes: what woke Conduit
        // needs Hermes, and nobody is there to pick.
        let grace = launchDashboardChoiceGrace
        launchDashboardChoiceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: grace) } catch { return }
            guard let self else { return }
            self.launchDashboardChoiceTask = nil
            guard self.launchAwaitsDashboardChoice, !self.sceneHasBeenActive, self.phoneScreenIsAway() else { return }
            // Nothing waits for a pick now: a release has this sign-in to
            // go on. One that can't finish here (Face ID can't show off
            // screen) leaves the list up on screen, not a retry
            // (holdLaunchDashboardChoiceOnScreen).
            self.launchAwaitsDashboardChoice = false
            self.launchSignsInInBackground = true
            self.loadSavedConnection(trigger: "launch in the background")
        }
    }

    /// Something this launch came for needs Hermes: it signs in to the
    /// last dashboard used, as a launch without the setting does, and the
    /// open goes on from there (switching dashboards if it is another's).
    func releaseLaunchDashboardChoice(for reason: String) {
        if launchSignsInInBackground {
            // The background launch's sign-in is under way, or waits for the
            // screen, where its usual retry runs: a second one would race it.
            launchSignsInInBackground = false
            return
        }
        guard launchAwaitsDashboardChoice else { return }
        endLaunchDashboardChoice()
        // The background launch's sign-in is still under way, or went in.
        guard showLogin, !isConnecting, !isConnected else { return }
        lifecycleLog.notice("Launch dashboard choice released: \(reason, privacy: .public)")
        pendingLoginFailure = nil
        lastConnectionFailure = nil
        errorMessage = nil
        loadSavedConnection(trigger: "launch for \(reason)")
    }

    func endLaunchDashboardChoice() {
        launchAwaitsDashboardChoice = false
        launchSignsInInBackground = false
        launchDashboardChoiceTask?.cancel()
        launchDashboardChoiceTask = nil
    }

    /// Conduit came on screen with the launch's dashboard still to pick:
    /// the list stays up, with no saved sign-in retried. False when there
    /// is nothing to pick (signed in, signing in, or a shared draft that
    /// needs Hermes is waiting).
    func holdLaunchDashboardChoiceOnScreen() -> Bool {
        if launchSignsInInBackground {
            launchSignsInInBackground = false
            // Only a background sign-in that ended waiting for the screen
            // goes back to the list; one still under way finishes.
            guard showLogin, signInWaitsForForeground, !isConnecting, !isConnected else { return false }
            launchAwaitsDashboardChoice = true
        }
        guard launchAwaitsDashboardChoice else { return false }
        launchDashboardChoiceTask?.cancel()
        launchDashboardChoiceTask = nil
        guard showLogin, !isConnecting, !isConnected else {
            endLaunchDashboardChoice()
            return false
        }
        if let inbox = shareDraftInbox, !inbox.pending().isEmpty {
            releaseLaunchDashboardChoice(for: "a shared draft")
            return true
        }
        if signInWaitsForForeground {
            // A background attempt's failure (Face ID can't show off
            // screen) isn't news on a list waiting for a tap.
            signInWaitsForForeground = false
            pendingLoginFailure = nil
            lastConnectionFailure = nil
            errorMessage = nil
        }
        return true
    }

    /// `trigger` names what started the restore in the connection
    /// timeline and the call trace.
    func loadSavedConnection(trigger: String = "cold launch") {
        #if DEBUG
        if let stub = Self.uiTestFailedConnectionStub() {
            let failureKind = Self.uiTestFailureKind()
            lifecycleLog.notice("UI-test failed-connection stub active: repair surface visible, transport inert")
            connection = stub
            isConnected = false
            isConnecting = false
            turnState = .reconnecting
            lastConnectionFailure = failureKind
            errorMessage = AppLocalization.string("The connection to Hermes was lost. (UI test stub)")
            showLogin = false
            return
        }
        if let stub = Self.uiTestConnectedStub() {
            lifecycleLog.notice("UI-test connected stub active: no transport will be created and reconnects are inert")
            connection = stub
            isConnected = true
            isConnecting = false
            showLogin = false
            if let seededProfiles = Self.uiTestSeededProfiles() {
                lifecycleLog.notice("UI-test profile roster seeded: \(seededProfiles.count, privacy: .public) profiles")
                profiles = orderedProfiles(seededProfiles + [activeProfile, "default"])
            }
            return
        }
        #endif
        // A sign-out that couldn't reach Hermes tries again.
        serverSignOutQueue.retryPending()
        guard let activeID = savedDashboardRegistry.activeDashboardID,
              let dashboard = dashboardForSignIn(activeID) else {
            // No saved dashboards (clean install) or none selected: present
            // the sign-in / add-dashboard flow.
            showLogin = true
            return
        }
        rememberDashboardURL(dashboard.normalizedURL)
        // A dashboard switch made while this restore runs (the sign-in
        // retried on screen, then the user picked another dashboard) owns
        // the flow.
        let switchGeneration = dashboardSwitchGeneration
        if KeychainHelper.loadNativeOAuthTokens(dashboardID: activeID) != nil {
            beginConnectionTimeline("\(trigger), browser sign-in (OAuth)")
            presentOfflineChatIfAvailable(dashboardID: activeID)
            showLogin = false
            isConnecting = true
            turnState = .synchronizing
            Task {
                await restoreNativeOAuthConnection(
                    baseURL: dashboard.normalizedURL,
                    dashboardID: activeID,
                    switchGeneration: switchGeneration
                )
            }
        } else if let credentials = KeychainHelper.loadCredentials(dashboardID: activeID) {
            beginConnectionTimeline(
                credentials.requiresFaceID
                    ? "\(trigger), password sign-in with Face ID"
                    : "\(trigger), password sign-in"
            )
            // A Face ID-protected dashboard reveals its saved copy only after
            // this launch's Face ID succeeds (restoreSavedCredentials).
            if !credentials.requiresFaceID {
                presentOfflineChatIfAvailable(dashboardID: activeID)
                if offlineChatPresentation != nil {
                    showLogin = false
                    isConnecting = true
                }
            }
            Task {
                await restoreSavedCredentials(
                    credentials,
                    dashboardID: activeID,
                    switchGeneration: switchGeneration
                )
            }
        } else if let saved = KeychainHelper.loadConnection(dashboardID: activeID) {
            beginConnectionTimeline("\(trigger), browser sign-in (saved ticket)")
            presentOfflineChatIfAvailable(dashboardID: activeID)
            // Keep the authenticated app shell in place while WebKit restores
            // its cookie process. A cold WebKit launch is not evidence that the
            // dashboard sign-in expired.
            connection = saved
            showLogin = false
            isConnecting = true
            turnState = .synchronizing
            Task { await restoreSavedConnection(saved, switchGeneration: switchGeneration) }
        } else {
            // The selected dashboard has no reusable auth left (signed out or
            // removed on another surface): present its sign-in, seeded with
            // its own address.
            showLogin = true
        }
    }

    func restoreNativeOAuthConnection(
        baseURL: String,
        dashboardID: UUID,
        switchGeneration: UInt64? = nil,
        widgetLease: WidgetLaunchLease? = nil
    ) async {
        guard widgetLease?.isCurrent != false else { return }
        // Early reads its connect didn't take (or that a restore given up
        // left) end with it.
        defer { startupReads.clear() }
        do {
            let ticket = try await mintChatResumeTicket(for: HermesConnection(baseUrl: baseURL, ticket: ""))
            // A dashboard switch made meanwhile owns the flow.
            guard restoreOwnsFlow(switchGeneration) else { return }
            // So does a newer widget launch, or the expiry of this one.
            guard widgetLease?.isCurrent != false else { return }
            await connect(with: HermesConnection(baseUrl: baseURL, ticket: ticket), profile: activeProfile)
            if isConnected {
                clearSavedPassword(dashboardID: dashboardID)
                KeychainHelper.clearDashboardCookies(dashboardID: dashboardID)
            }
        } catch is CancellationError {
            if restoreOwnsFlow(switchGeneration) {
                isConnecting = false
                // As for the saved-ticket restore: no synchronizing state
                // left with nothing to clear it.
                if turnState == .synchronizing { setRunning(false) }
            }
        } catch {
            guard restoreOwnsFlow(switchGeneration) else { return }
            // A rejected grant can clear storage while the bridge still owns
            // its old in-memory session. Tear it down before presenting login.
            dashboardTicketBridge?.invalidate()
            dashboardTicketBridge = nil
            let pluginStateBeforeSignIn = notifierPlugin.state
            notifierPlugin = freshNotifierPluginStatus
            let failure = ConnectionFailureClassifier.classify(error)
            if keepOfflineChatInsteadOfSignIn(failure) { return }
            wipeOfflineChatCacheForSignIn(after: failure, dashboardID: dashboardID)
            isConnecting = false
            isConnected = false
            showLogin = true
            pendingLoginFailure = .presenting(ConnectionFailureClassifier.classify(error))
            endLockScreenTurnsForSignIn(plugin: pluginStateBeforeSignIn)
        }
    }

    func connect(with conn: HermesConnection, profile: String = "default") async {
        await connect(
            with: conn,
            profile: profile,
            syncPurpose: .automaticReturn,
            cancelsResumeRestoration: true
        )
    }

    func connect(
        with conn: HermesConnection,
        profile: String,
        syncPurpose: ChatResumeSyncPurpose,
        cancelsResumeRestoration: Bool,
        automaticWorkToken existingAutomaticWorkToken: ChatResumeAutomaticWorkToken? = nil,
        automaticReconnectOperationID: UUID? = nil,
        isRenewal: Bool = false
    ) async {
        if cancelsResumeRestoration {
            cancelChatResumeTransportRecovery()
        }
        // Preserve which URL-policy rule failed instead of reporting every
        // normalization failure as insecure transport, and hand the login
        // card a typed classified presentation rather than a string.
        let normalizedBaseURL: String
        do {
            normalizedBaseURL = try ConnectionURLPolicy.normalizedBaseURL(conn.baseUrl)
        } catch {
            isConnecting = false
            isConnected = false
            showLogin = true
            pendingLoginFailure = .presenting(ConnectionFailureClassifier.classify(error))
            return
        }
        // Adoption resolves the saved dashboard this connection belongs to
        // (registering it when new) BEFORE the server-change boundary runs,
        // so the boundary's identity is the dashboard UUID and the bridge
        // built below can read this dashboard's scoped Cloudflare token.
        let adoptedDashboardID = adoptDashboard(forNormalizedURL: normalizedBaseURL)
        prepareChatResumeForConnection(to: normalizedBaseURL, dashboardID: adoptedDashboardID)
        let automaticWorkToken = syncPurpose == .automaticReturn
            ? (existingAutomaticWorkToken ?? beginAutomaticChatResumeWork())
            : nil
        let ownedAutomaticReconnectOperationID = automaticReconnectOperationID == nil
            ? beginAutomaticReconnectOperation(for: automaticWorkToken)
            : nil
        let transportOperationID = automaticReconnectOperationID
            ?? ownedAutomaticReconnectOperationID
        var handedOffAutomaticIntent = false
        defer {
            if ownedAutomaticReconnectOperationID != nil {
                finishAutomaticReconnectOperation(
                    id: ownedAutomaticReconnectOperationID,
                    restoringBaseline: !handedOffAutomaticIntent
                        && !automaticChatResumeWorkIsCurrent(
                            automaticWorkToken,
                            reconnectOperationID: transportOperationID
                        )
                )
            }
        }
        // The early reads are this connection's steps' alone: what any other
        // screen reads after the connection settled (a pull to refresh, the
        // profile list after a new bot) is read fresh.
        defer { startupReads.clear() }
        guard automaticChatResumeWorkIsCurrent(
            automaticWorkToken,
            reconnectOperationID: transportOperationID
        ) else { return }
        rememberDashboardURL(conn.baseUrl)
        cancelScheduledReconnect()
        isConnecting = true
        showLogin = false
        connection = conn
        if activeProfile != profile {
            // Hard profile boundary for this forward transition: cancel the
            // debounced stream flush and write synchronously while the
            // current profile still owns the in-memory transcript. Mirrors
            // switchProfile(to:reusing:).
            flushPendingPresentationCache()
            sessions = []
            cronSessions = []
            archivedSessions = []
            slashCommands = Self.builtInSlashCommands
            slashSubcommands = Self.conduitSlashSubcommands
        }
        // Fence deferred presentation-cache writes created under the
        // previous profile before transcripts change over.
        setActiveProfile(profile)
        restoreActiveSessionState(for: profile)
        restorePinnedSessions(for: profile)
        persistActiveProfile(profile)
        turnState = .synchronizing
        continueConnectionTimeline("sign-in")
        noteConnectionStep("Connecting")
        prepareDashboardBridge(for: conn.baseUrl)
        if chatResumeLifecycleOperations.connectClient == nil {
            sendStartupReads(profile: profile)
        }

        let previousClient = client
        let client = makeClient(connection: conn, profile: profile)
        // The same dashboard (a silent re-auth's reconnect, say): a Bot Chat
        // this client hasn't opened again still names the bot's profile
        // (issue 2277). Another dashboard's chats are its own.
        if let previousClient,
           (try? ConnectionURLPolicy.normalizedBaseURL(previousClient.connection.baseUrl)) == normalizedBaseURL {
            client.inheritSessionProfiles(from: previousClient)
        }
        self.client = client
        previousClient?.disconnect()

        do {
            try await connectChatResumeClient(client)
            if self.client === client {
                owedPostConnectBootstrap = OwedPostConnectBootstrap(
                    client: client,
                    purpose: syncPurpose,
                    automaticWorkToken: automaticWorkToken
                )
            }
            guard let continuation = transportContinuation(
                    purpose: syncPurpose,
                    automaticWorkToken: automaticWorkToken,
                    automaticReconnectOperationID: transportOperationID
                  ),
                  let activeClient = self.client, activeClient === client else { return }
            var continuationPurpose = continuation.purpose
            var continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = continuation.handedOffAutomaticIntent
            followOwedPostConnectBootstrapPurpose(continuationPurpose, for: client)
            isConnected = true
            isConnecting = false
            // A fresh healthy session never inherits an older banner error;
            // a failed send's reason stays until the next send or its chat.
            if errorMessage == nil || errorMessage != sendFailureShown { errorMessage = nil }
            lastConnectionFailure = nil
            reconnectAttempts = 0
            connectedAt = Date()
            KeychainHelper.saveConnection(conn, dashboardID: adoptedDashboardID)
            botRosterVerifiedForCurrentConnection = false

            // Bot Mode evidence must exist before the sync below decides which
            // conversation this workspace was in — loaded CONCURRENTLY with
            // the profile list so the decision never pays two round trips.
            async let profilesLoad: Void = loadChatResumeProfiles()
            async let rosterLoad: Void = loadChatResumeBotRoster()
            _ = await (profilesLoad, rosterLoad)
            // One continuation guard covers both loads: it re-reads the
            // continuation AFTER the suspension, so a superseded transport is
            // caught here without a second, identical evaluation.
            guard let continuation = transportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: transportOperationID
            ) else { return }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            followOwedPostConnectBootstrapPurpose(continuationPurpose, for: client)
            guard let continuation = await synchronizeTransportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: transportOperationID,
                client: client,
                profile: profile
            ) else { return }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            // Two independent reads, each guarding its own answer against a
            // switch while it was out: sent together, so the connect waits
            // one round trip for them, not two (issue 1727).
            async let busyInputModeRead: Void = loadChatResumeBusyInputMode(using: client)
            async let displayPreferencesRead: Void = loadChatResumeProfileDisplayPreferences()
            _ = await (busyInputModeRead, displayPreferencesRead)
            guard let activeClient = self.client, activeClient === client,
                  let continuation = transportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: transportOperationID
            ) else { return }
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            Task { await loadChatResumeSlashCommands() }
            Task { await refreshNotifierPluginStatus() }
        } catch {
            guard let continuation = transportContinuation(
                    purpose: syncPurpose,
                    automaticWorkToken: automaticWorkToken,
                    automaticReconnectOperationID: transportOperationID
                  ),
                  let activeClient = self.client, activeClient === client else { return }
            handedOffAutomaticIntent = continuation.handedOffAutomaticIntent
            if stopRecoveryForRefusedSocket(error) { return }
            isConnecting = false
            isConnected = false
            turnState = .reconnecting
            if isRenewal {
                // A socket after a renewal's silent re-auth: quiet like the
                // renewal itself (#1624).
                noteQuietRenewalFailure(error)
            } else {
                errorMessage = UserFacingError.message(for: error)
                // The typed classification is retained for Repair Connection's
                // seeding and routing; the raw error never reaches the UI.
                lastConnectionFailure = ConnectionFailureClassifier.classify(error)
            }
            // Only an explicit dashboard 401/403 may return the user to the
            // sign-in screen. A transient gateway or WebKit startup failure
            // must retain the saved dashboard session and retry.
            showLogin = false
            if continuation.purpose == .preserveCurrent {
                recoverySequence.complete()
                scheduleReconnect(purpose: continuation.purpose)
            } else {
                scheduleReconnectAfterFailedSync()
            }
        }
    }

    // MARK: - Connection Repair (Round 6)

    /// Builds the Repair seed from the configuration that actually failed:
    /// the active (failed) connection's exact URL, safely available
    /// credentials for it, and the origin-matched Cloudflare token. Nil when
    /// there is no failed target — a healthy connected session is never a
    /// repair candidate.
    func makeConnectionRepairContext() -> ConnectionRepairContext? {
        guard let failedURL = connection?.baseUrl, !isConnected else { return nil }
        return repairContext(for: failedURL)
    }

    /// Repair seed for a failed SAVED-credential reconnect (login screen):
    /// the failed target is the saved record's dashboard, and the record
    /// itself — kept intact by the failure path — supplies the seed under
    /// the normal seeding rules (a Face ID-protected record surrenders its
    /// username only).
    func makeSavedConnectionRepairContext() -> ConnectionRepairContext? {
        guard let activeID = activeDashboardID,
              let credentials = KeychainHelper.loadCredentials(dashboardID: activeID) else { return nil }
        return repairContext(for: credentials.baseURL)
    }

    private func repairContext(for failedURL: String) -> ConnectionRepairContext {
        let scopedCredentials = activeDashboardID.flatMap { KeychainHelper.loadCredentials(dashboardID: $0) }
        let seeded = ConnectionSetupSeeding.wizardCredentials(
            for: failedURL,
            saved: scopedCredentials
        )
        return ConnectionRepairContext(
            draft: ConnectionSetupDraft(
                existingServerURL: failedURL,
                username: seeded?.username ?? "",
                password: seeded?.password ?? ""
            ),
            cloudflareAccess: dashboardScopedCloudflareAccess(for: failedURL),
            cloudflareOriginURL: failedURL,
            failure: lastConnectionFailure
        )
    }

    /// Repair entry for a failed SAVED-credential reconnect (login screen).
    /// Like the composer entry, this is an explicit user takeover: any
    /// outstanding automatic recovery loses authority before the wizard
    /// opens, so it can never install a connection underneath the repair.
    @discardableResult
    func beginSavedConnectionRepair() -> ConnectionRepairContext? {
        repairRegisteredDashboardIDs = []
        guard let context = makeSavedConnectionRepairContext() else { return nil }
        cancelChatResumeTransportRecovery()
        return context
    }

    /// Round 6: Repair Connection appears only once the connection is
    /// actually down AND a failed attempt has surfaced — through the typed
    /// classified failure or the visible error banner — never while the
    /// first automatic attempts are still quiet, and never uninvited. It
    /// stays between the retries that follow a surfaced failure. Offered by
    /// the composer and, in V2, at the top of Chats, where the app opens.
    var showsConnectionRepair: Bool {
        connection != nil
            && !isConnected
            && (lastConnectionFailure != nil
                || (!(errorMessage ?? "").isEmpty && !isHoldingQuietReconnectFailure
                    // A failed send's reason isn't the connection's.
                    && errorMessage != sendFailureShown))
    }

    /// A failed renewal is being kept quiet: an older, unrelated message
    /// left on screen doesn't offer Repair meanwhile (#1624).
    var isHoldingQuietReconnectFailure: Bool {
        quietReconnectFailure != nil && lastConnectionFailure == nil
    }

    /// Entering Repair is an explicit user takeover of connection recovery:
    /// outstanding automatic recovery — the scheduled reconnect timer, its
    /// operations, and its automatic work — loses authority here, so a stale
    /// automatic reconnect can never install a connection or select a
    /// session over the user's explicit repair. Dismissal does not silently
    /// restart the loop; the user is left in the stable disconnected state.
    @discardableResult
    func beginConnectionRepair() -> ConnectionRepairContext? {
        repairRegisteredDashboardIDs = []
        guard let context = makeConnectionRepairContext() else { return nil }
        cancelChatResumeTransportRecovery()
        return context
    }

    /// The wizard's activation handler for the Repair entry: runs the
    /// explicit reconnect through the authoritative connection path and
    /// persists the tested configuration only after activation succeeds.
    func connectionRepairActivationHandler(
    ) -> (ConnectionRepairHandoff) async -> ConnectionRepairActivationOutcome {
        let activator = AppStateConnectionRepairActivator(appState: self)
        return { handoff in await activator.activate(handoff) }
    }

    /// The explicit repair activation behind Reconnect Now / Sign In to
    /// Reconnect. Revokes outstanding automatic recovery authority first,
    /// commits the validated transaction's cookies (native only — browser
    /// sign-in publishes its own cookies through the AuthWebView flow), then
    /// connects with `.preserveCurrent`: the server confirms the preserved
    /// session identity, never automatic-return selection.
    func performConnectionRepair(
        _ handoff: ConnectionRepairHandoff
    ) async -> ConnectionRepairActivationOutcome {
        // The PRE-activation target anchors persistence: it decides whether
        // the tested URL counts as changed (remember it) and whether the
        // Cloudflare token needs a same-origin re-bind.
        let failedTarget = connection?.baseUrl
        // A sign-in's address was checked before its sheet registered it
        // (ConnectionSetupView.beginRepairSignIn); a tested password
        // reconnect is checked here, before its cookies are committed.
        if case .native = handoff, let owner = repairAddressOwner(handoff.baseURL, repairing: failedTarget) {
            return .addressBelongsToDashboard(id: owner.id, label: owner.label)
        }
        cancelChatResumeTransportRecovery()
        let outcome: ConnectionRepairActivationOutcome
        switch handoff {
        case .native(let candidate):
            // The one-shot candidate is consumed here, whether activation
            // succeeds or fails: its cookies are committed exactly once, and
            // a failed activation requires a fresh test, never a retry of a
            // spent transaction. If activation fails after the commit, the
            // committed cookies belong to a genuinely authenticated session
            // (login and ticket mint both succeeded first) — they are
            // naturally superseded by the next explicit test or sign-in and
            // are deliberately not rolled back.
            if let dashboardID = registerRepairDashboard(forURL: candidate.configuration.serverURL) {
                candidate.nativeConnection.commitCookies(dashboardID: dashboardID)
            }
            outcome = await activateRepairedConnection(with: HermesConnection(
                baseUrl: candidate.configuration.serverURL,
                ticket: candidate.nativeConnection.ticket
            ))
        case .browserSignIn(let ticket, let baseURL, _):
            outcome = await activateRepairedConnection(with: HermesConnection(
                baseUrl: baseURL,
                ticket: ticket
            ))
        case .nativeOAuth(let result, let baseURL, _):
            guard let dashboardID = registerRepairDashboard(forURL: baseURL) else {
                return .failed(.unexpectedServerResponse)
            }
            let storedTokens = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID)
            let previousTokens = storedTokens == result.tokens ? result.previousTokens : storedTokens
            KeychainHelper.saveNativeOAuthTokens(result.tokens, dashboardID: dashboardID)
            guard KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) == result.tokens else {
                restoreNativeOAuthTokens(previousTokens, dashboardID: dashboardID, baseURL: baseURL)
                return .failed(.unexpectedServerResponse)
            }
            outcome = await activateRepairedConnection(with: HermesConnection(
                baseUrl: baseURL,
                ticket: result.ticket
            ))
            if outcome != .activated {
                // The candidate did not become the active connection. Restore
                // the exact prior bearer state and force bridge reconstruction
                // so a same-mode previous session is not left shadowed by the
                // failed candidate's in-memory tokens.
                restoreNativeOAuthTokens(previousTokens, dashboardID: dashboardID, baseURL: baseURL)
            }
        }
        guard outcome == .activated else { return outcome }
        // Connected: what this repair registered is a dashboard of its own
        // now, and a later repair starts without it.
        repairRegisteredDashboardIDs = []
        persistActivatedRepair(handoff, failedTarget: failedTarget)
        return outcome
    }

    /// The saved dashboard other than the one being repaired that already
    /// has this address, if any. Repair never writes onto it: its saved
    /// password, Face ID choice, Cloudflare token and sign-in cookies stay
    /// its own, as in Edit Connection.
    func repairAddressOwner(_ baseURL: String, repairing failedTarget: String?) -> SavedDashboard? {
        let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL))
            ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let owner = savedDashboardRegistry.dashboard(claiming: normalized),
              !repairRegisteredDashboardIDs.contains(owner.id) else { return nil }
        let repairing = failedTarget.flatMap { resolveDashboardID(forURL: $0, registerIfMissing: false) }
            ?? activeDashboardID
        return owner.id == repairing ? nil : owner
    }

    /// Registers a repair's address: a sign-in's before its sheet opens, a
    /// password reconnect's before its cookies are committed. One it newly
    /// registers stays the repair's own, so a later try at that address
    /// (after a failed activation, say) isn't refused as another
    /// dashboard's.
    func registerRepairDashboard(forURL baseURL: String) -> UUID? {
        let existing = resolveDashboardID(forURL: baseURL, registerIfMissing: false)
        guard let id = existing ?? resolveDashboardID(forURL: baseURL, registerIfMissing: true) else { return nil }
        if existing == nil { repairRegisteredDashboardIDs.insert(id) }
        return id
    }

    /// Activates a normal-login native OAuth result transactionally. The
    /// broker grant is already durable so a transient ticket failure is
    /// retryable, but a failed socket activation must restore whichever auth
    /// mode was authoritative before the user started this sign-in.
    func connectWithNativeOAuth(_ result: NativeOAuthLoginResult, baseURL: String) async -> Bool {
        guard let dashboardID = resolveDashboardID(forURL: baseURL, registerIfMissing: true) else {
            return false
        }
        prepareInteractiveSignIn(dashboardID: dashboardID)
        let storedTokens = KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID)
        let previousTokens = storedTokens == result.tokens ? result.previousTokens : storedTokens
        KeychainHelper.saveNativeOAuthTokens(result.tokens, dashboardID: dashboardID)
        guard KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardID) == result.tokens else {
            restoreNativeOAuthTokens(previousTokens, dashboardID: dashboardID, baseURL: baseURL)
            return false
        }
        rememberDashboardURL(baseURL)
        await connect(with: HermesConnection(baseUrl: baseURL, ticket: result.ticket))
        guard isConnected else {
            restoreNativeOAuthTokens(previousTokens, dashboardID: dashboardID, baseURL: baseURL)
            return false
        }
        clearSavedPassword(dashboardID: dashboardID)
        KeychainHelper.clearDashboardCookies(dashboardID: dashboardID)
        return true
    }

    private func restoreNativeOAuthTokens(
        _ tokens: NativeOAuthTokenSet?,
        dashboardID: UUID,
        baseURL: String
    ) {
        cancelScheduledReconnect()
        if let tokens {
            KeychainHelper.saveNativeOAuthTokens(tokens, dashboardID: dashboardID)
        } else {
            KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
        }
        dashboardTicketBridge?.invalidate()
        dashboardTicketBridge = nil
        notifierPlugin = freshNotifierPluginStatus
        prepareDashboardBridge(for: baseURL)
    }

    /// The profile a repaired connection opens. A repair that moves to an
    /// address belonging to a DIFFERENT saved dashboard (or to a new one)
    /// opens that dashboard's own remembered profile, never the outgoing
    /// dashboard's: profile names are not shared between servers.
    private func repairTargetProfile(for baseURL: String) -> String {
        let targetID = resolveDashboardID(forURL: baseURL, registerIfMissing: false)
        guard let current = activeDashboardID, targetID != current else { return activeProfile }
        return targetID.flatMap(rememberedActiveProfile(for:)) ?? "default"
    }

    /// The authoritative activation step. A test success is not a guarantee
    /// the world is unchanged; if the websocket activation fails, the
    /// failure is classified, the reconnect `connect` armed is cancelled (no
    /// automatic retry), the remembered dashboard URL is restored, and the
    /// caller stays in Repair.
    private func activateRepairedConnection(
        with conn: HermesConnection
    ) async -> ConnectionRepairActivationOutcome {
        // connect() remembers the URL it attempts by design; a FAILED
        // activation must not move the remembered dashboard (the saved
        // connection and credentials are untouched by the failure path
        // already).
        let rememberedURL = defaults.string(forKey: dashboardURLKey)
        await connect(
            with: conn,
            profile: repairTargetProfile(for: conn.baseUrl),
            syncPurpose: .preserveCurrent,
            cancelsResumeRestoration: false
        )
        guard isConnected else {
            if let rememberedURL { defaults.set(rememberedURL, forKey: dashboardURLKey) }
            // connect() armed an automatic retry in its failure path; the
            // explicit repair owns recovery, so the loop stays stopped until
            // the user tests and reconnects again.
            cancelChatResumeTransportRecovery()
            return .failed(lastConnectionFailure ?? .unknown)
        }
        return .activated
    }

    /// Persists the tested configuration ONLY after successful activation.
    /// Reuses the Round-5 apply plan (replace-never-create credentials,
    /// same-origin Cloudflare rewrites) anchored at the failed target so a
    /// changed URL is remembered and a path-only move re-binds the token.
    private func persistActivatedRepair(
        _ handoff: ConnectionRepairHandoff,
        failedTarget: String?
    ) {
        switch handoff {
        case .native(let candidate):
            let anchor = failedTarget ?? candidate.configuration.serverURL
            let plan = ConnectionSetupApplication.plan(
                result: candidate.configuration,
                currentDashboardURL: anchor,
                savedCredentials: savedCredentialsForDashboard(at: anchor),
                savedCloudflareAccess: dashboardScopedCloudflareAccess(for: anchor)
            )
            // Already connected at the tested address, as that address's
            // dashboard: nothing is left to move.
            plan.perform(appState: self, movingSavedDashboard: false)
        case .browserSignIn(_, let baseURL, _):
            // Existing browser-auth semantics: no reusable password exists,
            // stale native credentials are cleared, the activated dashboard
            // is remembered, and same-origin Cloudflare rules are untouched.
            rememberDashboardURL(baseURL)
            if let dashboardID = resolveDashboardID(forURL: baseURL, registerIfMissing: false) {
                clearSavedPassword(dashboardID: dashboardID)
                KeychainHelper.clearNativeOAuthTokens(dashboardID: dashboardID)
            }
        case .nativeOAuth(_, let baseURL, _):
            rememberDashboardURL(baseURL)
            if let dashboardID = resolveDashboardID(forURL: baseURL, registerIfMissing: false) {
                clearSavedPassword(dashboardID: dashboardID)
                KeychainHelper.clearDashboardCookies(dashboardID: dashboardID)
            }
        }
    }

    func disconnect() {
        // A switch to it still signing in loses the flow: its answer must
        // not connect it again (Disconnect, Sign Out) or add it back and
        // select it (removal). A switch runs to its end whatever cancels
        // its caller, so the generation is what stops it.
        dashboardSwitchGeneration &+= 1
        // Its waits belong to the signed-out user (issue 1705).
        needsYou.reset(dashboardID: nil)
        // So does a Restart now that failed.
        gatewayRestartNowFailure = nil
        // The next sign-in to it asks for Face ID again.
        if let activeDashboardID { relockFaceID(dashboardID: activeDashboardID) }
        // Its turns' Lock Screen progress has nothing left to follow.
        liveTurnActivitiesEndDashboard(activeDashboardID?.uuidString, false)
        // Drafts shared for this dashboard belong to the signed-out user,
        // including one whose chat was opening.
        sharedDraftLaunch = nil
        if let activeDashboardID { discardSharedDrafts(forDashboard: activeDashboardID) }
        widgetLaunchCoordinator.supersede()
        cancelExplicitSessionOpen()
        dismissChatTakeover()
        chatResumeCoordinator.clearResumeState()
        cancelOwnedAutomaticOperations()
        activeAutomaticChatResumeWork = nil
        cancelScheduledReconnect()
        recoverySequence.cancel()
        chatResumeRestorationRequest = nil
        invalidateReconciliation()
        invalidateServerCompactionState()
        // Sign-out ends the room surface too: its poller, transcript, and
        // pending outbox belong to the outgoing session. A same-dashboard
        // sign-in never crosses the server-identity boundary, so without
        // this the previous session's room would be restored as it was.
        invalidateGroupChatState()
        // And the boards its replies named, with any read still out.
        resetLineBoards()
        botRosterRetry.succeeded()
        // Background jobs keep running on the server as ordinary chats; the
        // signed-out ledger just stops following them.
        retireVoiceBackgroundJobs()
        // Unsent drafts belong to the signed-out user; AppState owns the
        // store (it outlives the composer view), so sign-out must clear it.
        composerDraftStore.removeAll()
        // So do words on their way back to a draft.
        composerRestoreRequests = []
        composerNotice = nil
        // So do screenshots waiting for a question.
        discardScreenQuestions()
        // A restart already handed to Hermes carries on there; Conduit
        // stops following it.
        stopFollowingGatewayRestart()
        stopFollowingHermesUpdate()
        stopFollowingNotifierPluginUpdate()
        automaticPairingAttempts.removeAll()
        cancelScenePhaseAttempt()
        owedPostConnectBootstrap = nil
        lastConnectionFailure = nil
        client?.disconnect()
        isConnected = false
        isConnecting = false
        connectedAt = nil
        // Sign Out of This Dashboard: only the active dashboard's reusable
        // auth is cleared. Its SavedDashboard metadata and every other
        // dashboard's records are untouched. The dashboard identity is
        // captured BEFORE any state is nulled so the web/native session is
        // cleared even when there is no live connection.
        let signingOutDashboardID = activeDashboardID
        widgetSettledCatalogOwner = nil
        if let signingOutDashboardID { removeWidgetSnapshot(dashboardID: signingOutDashboardID) }
        wipeOfflineChatCache(dashboardID: signingOutDashboardID)
        if let dashboardID = signingOutDashboardID {
            endServerSignIn(
                dashboardID: dashboardID,
                baseURL: connection?.baseUrl ?? savedDashboardRegistry.dashboard(with: dashboardID)?.normalizedURL
            )
            KeychainHelper.clearConnection(dashboardID: dashboardID)
            keepUsernameForNextSignIn(dashboardID: dashboardID)
            clearSavedPassword(dashboardID: dashboardID)
            // Log to Hermes events waiting for it belong to the signed-out user.
            ShortcutInboxQueue.forgetDashboard(dashboardID)
            // The Cloudflare Access token stays, like the address and the
            // extra headers: it reaches the server, it doesn't sign in.
            // Remove Dashboard deletes it.
        }
        // The Keychain mirror of the dashboard cookies is cleared above, but
        // the live session cookies live on in WebKit's persistent default data
        // store and the shared Foundation cookie store. Without removing them,
        // Disconnect is not equivalent to logging out: a still-valid server
        // session could be silently resumed on the next authentication flow.
        // Capture the origin before nulling `connection` and purge both stores.
        let dashboardBaseURL = connection?.baseUrl
            ?? signingOutDashboardID.flatMap { savedDashboardRegistry.dashboard(with: $0)?.normalizedURL }
        connection = nil
        client = nil
        dashboardTicketBridge?.invalidate()
        dashboardTicketBridge = nil
        notifierPlugin = freshNotifierPluginStatus
        voiceConversationController.stop()
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        messageReadAloudController.stop()
        // The bridge is invalidated above; a gateway built against it can
        // never open a stream again, so it must not survive the re-login.
        messageReadAloudController.setGateway(nil)
        readAloudGatewayBridge = nil
        readAloudSpeaker = nil
        suspendedVoiceConversation = nil
        voiceSheetShouldAutoListen = false
        voiceControllerSessionProfile = nil
        showVoiceSheet = false
        clearClassicVoiceCards()
        voiceCapabilitySnapshot = .unavailable
        isVoiceEnabled = false
        voiceTranscriptionMode = .hermes
        continuousConversationEnabled = true
        keepVoiceListeningWhenLocked = false
        voicePushToTalkEnabled = false
        chatVoiceButtonOverride = nil
        voiceCallSaveBlockedKeys = []
        pendingVoiceCallSaves = 0
        voiceCallSavesBlocked = false
        voiceCallSaveNowResult = nil
        voiceCallSaveNowResultState = nil
        appleSpeechAvailability = AppleOnDeviceSpeechTranscriber.currentAvailability()
        retireOutstandingPreferredReturnSurfaceRequests()
        showLogin = true
        sessions = []
        archivedSessions = []
        cronSessions = []
        // Sessions can be deleted from another client while signed out; a
        // stale catalog cache would show those rows again after re-sign-in
        // (and the full-history marker would suppress the reload that could
        // correct them).
        sessionCatalogCache.removeAll()
        archivedCallsReads.removeAll()
        // Signed out: the next sign-in's list loads before it says anything.
        sessionCatalogLoadState.reset()
        pinnedSessionIDs = []
        messages = []
        clearAuthorityQueueState()
        persistedTranscriptWindow = nil
        setActiveSessionState(id: nil, title: AppLocalization.string("New conversation"))
        keepDelegateAgents(of: [])
        clearStreamingText()
        resetReasoningTurn()
        turnState = .idle
        defaults.removeObject(forKey: activeSessionTitlesByProfileKey)
        defaults.removeObject(forKey: pinnedSessionIDsByProfileKey)
        defaults.removeObject(forKey: voiceJobSessionIDsByProfileKey)
        activeSessionTitlesByProfile = [:]
        pinnedSessionIDsByProfile = [:]
        resetHostPins()
        sessionStars = SessionStars()
        defaults.removeObject(forKey: SessionStars.storageKey)
        pinnedChatOrder = PinnedChatOrder()
        defaults.removeObject(forKey: PinnedChatOrder.storageKey)
        defaults.removeObject(forKey: PinnedChatOrder.mixedStorageKey)
        botOrder = BotOrder()
        defaults.removeObject(forKey: BotOrder.storageKey)
        groupRoomOrder = BotOrder.rooms
        defaults.removeObject(forKey: BotOrder.roomStorageKey)
        allProfilesCatalogTask?.cancel()
        allProfilesCatalogTask = nil
        allProfilesCatalog = AllProfilesCatalog()
        clearPinnedReplies()
        voiceJobSessionIDsByProfile = [:]
        defaults.removeObject(forKey: activeProfileKey)
        if let signingOutDashboardID { forgetActiveProfile(for: signingOutDashboardID) }
        clearDashboardWebSession(dashboardID: signingOutDashboardID, baseURL: dashboardBaseURL)
    }

    /// Clears a dashboard's web session at Sign Out / Remove. With a
    /// dashboard identity the session is DASHBOARD-OWNED (#148): the
    /// identified WebKit store is removed entirely and the dashboard's native
    /// jar is wiped (plus exact-host residue in the shared jar — parent-domain
    /// cookies shared with a sibling dashboard are never touched). Without an
    /// identity (legacy/test shapes) the origin-scoped default-store cleanup
    /// remains.
    private func clearDashboardWebSession(dashboardID: UUID?, baseURL: String?) {
        if let dashboardID {
            DashboardCookiePersistence.scheduleWebKitSessionClear(for: dashboardID)
            if let baseURL {
                DashboardCookiePersistence.clearNativeCookies(dashboardID: dashboardID, baseURL: baseURL)
            }
            return
        }
        guard let baseURL else { return }
        DashboardCookiePersistence.clearNativeCookies(for: baseURL)
        if let url = URL(string: baseURL) {
            // Ordered: the next default-store sign-in waits for this clear
            // (#788).
            DashboardCookiePersistence.clearDefaultStore(for: url)
        }
    }

    // MARK: - Reconnect and scene lifecycle

    /// Server-side compaction claims and their scheduled expiry tasks are
    /// gateway-owned lifecycle state: deliberate teardown boundaries
    /// (sign-out, server replacement, socket loss) invalidate them together —
    /// a `compacted` edge may never arrive across them. Local RPC claims
    /// (`compressingSessionIDs`) are untouched: they are bounded by their own
    /// request timeout.
    func invalidateServerCompactionState() {
        serverCompactingSessionIDs.removeAll()
        serverCompactionClaimExpiryTasks.values.forEach { $0.cancel() }
        serverCompactionClaimExpiryTasks.removeAll()
        serverCompactionClaims.removeAll()
    }

    #if DEBUG
    /// Test seam: the chat socket closing under the app.
    func handleDisconnectForTesting() {
        handleDisconnect()
    }
    #endif

    func handleDisconnect() {
        let wasRunning = isBusy
        isConnected = false
        // Gateway compaction lifecycle state is unverifiable across a socket
        // loss (the orphan reaper may have torn the compressing session
        // down, and a `compacted` edge may never arrive): never keep a
        // spinner alive on state we can no longer trust. Local RPC claims
        // survive — they are bounded by their own request timeout.
        invalidateServerCompactionState()
        guard connection != nil else { return }
        turnState = .reconnecting
        noteConnectionStep("Socket closed")

        if let connectedAt, Date().timeIntervalSince(connectedAt) > 10 {
            reconnectAttempts = 0
        }
        // A reply on its way reconnects at once, but only over a usable
        // path: without one no attempt can work, and the path coming back
        // reconnects at once anyway (networkPathChanged). The gate is here,
        // not in scheduleReconnect: a path change's own immediate reconnect
        // runs before the path monitor's current value has the new path.
        scheduleReconnect(
            immediately: wasRunning && deviceConditions().pathSatisfied,
            purpose: chatResumePurposeForDisconnect()
        )
    }

    func scheduleReconnect(
        immediately: Bool = false,
        purpose: ChatResumeSyncPurpose = .preserveCurrent
    ) {
        guard connection != nil else { return }
        // A cycle scheduled while the scene is inactive can never run, so
        // don't arm a timer or consume the queued reconnect purpose just to
        // discard them when it fires. When reconnect work is deferred while
        // the scene is inactive, handleScenePhase(.active) owns recovery when
        // the app returns: if a visible conversation identity exists, foreground
        // recovery repairs that same conversation using .preserveCurrent;
        // .automaticReturn is used only when there is no current visible session
        // identity to preserve. A connected CarPlay Voice surface keeps the
        // app on screen while the phone is locked, so it admits recovery too,
        // as do the other surfaces canRunTransportRecovery lists (locked
        // voice, Watch and CallKit calls, a running shortcut send).
        guard canRunTransportRecovery else { return }
        if reconnectTask == nil {
            recoverySequence.clearQueuedReconnect()
        }
        let decision = planChatResumeReconnect(purpose: purpose)
        switch decision {
        case .keepExisting:
            return
        case .replace:
            reconnectTask?()
            reconnectTask = nil
        case .schedule:
            break
        }
        // Exponential with jitter, capped at 8 s while Conduit is on screen
        // and 60 s off it. Without a usable path no attempt can work: the
        // timer only stands in for a path report that never comes, and the
        // path coming back reconnects at once (networkPathChanged).
        let pathSatisfied = deviceConditions().pathSatisfied
        let onScreen = reconnectIsWatched
        let delay = immediately
            ? 0.1
            : pathSatisfied
                ? PollCadence.reconnectDelay(attempt: reconnectAttempts, random: reconnectJitter(), onScreen: onScreen)
                : PollCadence.reconnectCap
        noteConnectionStep(pathSatisfied || immediately
            ? "Reconnect scheduled in \(ConnectionTimeline.seconds(delay))"
            : "No network; reconnect waits for it (at most \(ConnectionTimeline.seconds(delay)))")
        // The backoff step is consumed only when the cycle actually runs.
        // A timer canceled by scene backgrounding — or a cycle dropped for
        // scene inactivity before execution — never counts as a gateway
        // failure, so background/foreground cycling cannot ratchet the
        // retry delay toward its cap without a real failure.
        let incrementsBackoff = !immediately

        reconnectTask = reconnectScheduler(delay) { [weak self] in
            guard let self else { return }
            self.reconnectTask = nil
            let purpose = self.recoverySequence.takeQueuedReconnectPurpose()
                ?? .preserveCurrent
            guard self.canRunTransportRecovery else { return }
            let generation = self.reconnectCycleGeneration
            if incrementsBackoff { self.reconnectAttempts += 1 }
            // On screen, a backed-off step asks the gateway cheaply first: a
            // gateway still restarting costs one HEAD, not a ticket, an
            // upgrade and its timeout.
            if incrementsBackoff, self.reconnectIsWatched,
               let probe = self.gatewayReadinessProbe,
               let baseURL = self.connection?.baseUrl {
                let answered = await probe(baseURL)
                guard self.reconnectCycleGeneration == generation,
                      self.reconnectTask == nil, !self.isConnected, !self.isConnecting,
                      self.connection?.baseUrl == baseURL, self.canRunTransportRecovery else { return }
                if !answered {
                    self.noteConnectionStep("Gateway not answering yet")
                    if self.reconnectAttempts >= Self.quietReconnectAttempts {
                        self.surfaceQuietReconnectFailure()
                    }
                    self.scheduleReconnect(purpose: purpose)
                    return
                }
            }
            await self.executeReconnect(purpose: purpose)
        }
    }

    /// Someone is looking at Conduit (the phone's screen or CarPlay's): a
    /// returning gateway should show within seconds.
    private var reconnectIsWatched: Bool {
        isSceneActive || isCarPlayVoiceSurfaceActive
    }

    func scheduleReconnectAfterFailedSync() {
        // Once an automatic sync fails with a visible conversation, repair
        // around that conversation. On a truly cold launch there is no
        // visible identity to preserve, so retain automatic return to the
        // saved conversation instead of selecting an arbitrary catalog row.
        let retryPurpose: ChatResumeSyncPurpose = activeSessionId == nil
            ? .automaticReturn
            : .preserveCurrent
        cancelScheduledReconnect()
        recoverySequence.complete()
        scheduleReconnect(purpose: retryPurpose)
    }

    func reconnect() async {
        // The dashboard already said sign-in is required and automatic
        // recovery stopped: another reconnect would only be refused again,
        // which looks like Reconnect doing nothing. It opens sign-in.
        // A refusal is never a sign-out, so the native grant stays, as on
        // the refused-socket path that stopped recovery.
        if signInRequiredForReconnect {
            performSignInRequired(pendingFailure: .signInExpired, keepingNativeGrant: true)
            return
        }
        cancelChatResumeTransportRecovery()
        surfacesRenewalFailureAtOnce = true
        defer { surfacesRenewalFailureAtOnce = false }
        await executeReconnect(purpose: .preserveCurrent)
    }

    /// Whether the active dashboard is known to need sign-in before any
    /// reconnect can work: the last failure was a sign-in the server asked
    /// for, and nothing has connected since.
    var signInRequiredForReconnect: Bool {
        !isConnected && lastConnectionFailure == .loginRequired
    }

    func executeReconnect(purpose: ChatResumeSyncPurpose) async {
        // A reconnect cycle mints a ticket, reloads the session catalog, and
        // mutates a series of @Published properties — each driving SwiftUI
        // transactions on the main thread. On a flaky link that churn can
        // saturate the main thread, and a backgrounded scene update then
        // misses its 10s watchdog deadline. Drop the attempt here instead;
        // handleScenePhase(.active) re-establishes the transport on return.
        // This also makes the public reconnect() a no-op while the scene is
        // inactive/backgrounded — the retry is picked up on the next .active.
        // A connected CarPlay Voice surface is a foreground surface of its
        // own (the phone is usually locked in a car), so it admits the cycle,
        // as do the other surfaces canRunTransportRecovery lists (locked
        // voice, Watch and CallKit calls, a running shortcut send).
        guard canRunTransportRecovery else { return }
        if let reconnectExecutor {
            await reconnectExecutor(purpose)
        } else {
            await reconnectForRetry(purpose: purpose)
        }
    }

    func reconnectForRetry(purpose requestedPurpose: ChatResumeSyncPurpose) async {
        #if DEBUG
        // The UI-test stubbed sessions have no transport to restore; every
        // automatic or explicit reconnect is a deterministic no-op for them.
        guard Self.uiTestConnectedStub() == nil,
              Self.uiTestFailedConnectionStub() == nil else { return }
        #endif
        guard let savedConnection = connection else { return }
        // As on every connect: a follow-up's turn may have ended unseen.
        stopWaitingForPredictiveFollowUp()
        // The renewal's ownership is captured BEFORE any await: the renewed
        // ticket belongs to exactly this dashboard and this switch
        // generation. After the mint (or the silent re-auth), the fences
        // below reject a superseded renewal — a dashboard switch that ran
        // meanwhile owns the flow, and the stale ticket must neither install
        // nor resolve against the now-changed selection.
        let renewalDashboardID = resolveDashboardID(forURL: savedConnection.baseUrl, registerIfMissing: false)
            ?? activeDashboardID
        let renewalSwitchGeneration = dashboardSwitchGeneration
        let purpose = beginChatResumeRecovery(purpose: requestedPurpose)
        let automaticWorkToken = purpose == .automaticReturn
            ? beginAutomaticChatResumeWork()
            : nil
        guard automaticChatResumeWorkIsCurrent(automaticWorkToken) else { return }
        let automaticOperationID = beginAutomaticReconnectOperation(for: automaticWorkToken)
        var continuationPurpose = purpose
        var continuationAutomaticWorkToken = automaticWorkToken
        var handedOffAutomaticIntent = false
        func refreshTransportContinuation() -> Bool {
            guard let continuation = transportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: automaticOperationID
            ) else { return false }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            if let client = self.client {
                followOwedPostConnectBootstrapPurpose(continuationPurpose, for: client)
            }
            return true
        }
        defer {
            // Its early reads are its own steps', as connect's are.
            startupReads.clear()
            finishAutomaticReconnectOperation(
                id: automaticOperationID,
                restoringBaseline: !handedOffAutomaticIntent
                    && !automaticChatResumeWorkIsCurrent(
                        automaticWorkToken,
                        reconnectOperationID: automaticOperationID
                    )
            )
        }
        if purpose == .automaticReturn, reconnectTask != nil {
            cancelScheduledReconnect()
        }
        // The old socket died: turn edges may have been missed while the
        // transport was down. The sync this cycle runs will re-confirm the
        // state from the authoritative resume snapshot and clear the flag.
        turnStateIsStale = true
        isConnecting = true
        turnState = .reconnecting
        continueConnectionTimeline("reconnect")
        noteConnectionStep("Reconnecting")

        let connection: HermesConnection
        do {
            let ticket = try await mintChatResumeTicket(for: savedConnection)
            guard refreshTransportContinuation() else { return }
            // Re-fence after the mint await: never install a stale renewal
            // under a newer dashboard switch, and never resolve its owner
            // from the now-changed selection.
            guard switchGenerationIsCurrent(renewalSwitchGeneration),
                  activeDashboardID == renewalDashboardID else { return }
            connection = HermesConnection(baseUrl: savedConnection.baseUrl, ticket: ticket)
            self.connection = connection
            // Only the latest step's failure may surface later.
            quietReconnectFailure = nil
            quietRenewalFailures = 0
            if let dashboardID = renewalDashboardID {
                KeychainHelper.saveConnection(connection, dashboardID: dashboardID)
            }
        } catch {
            guard refreshTransportContinuation() else { return }
            if let bridgeError = error as? DashboardTicketBridgeError, case .signInRequired = bridgeError {
                var silentRenewalReauthError: Error?
                let scopedCredentials = activeDashboardID.flatMap { KeychainHelper.loadCredentials(dashboardID: $0) }
                if let credentials = scopedCredentials,
                   credentials.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == savedConnection.baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
                    do {
                        let access = activeDashboardID.flatMap {
                            KeychainHelper.loadCloudflareAccess(dashboardID: $0, for: credentials.baseURL)
                        }
                        let authenticatedConnection = try await NativeAuthClient(baseURL: credentials.baseURL, cloudflareAccess: access).connect(
                            username: credentials.username,
                            password: credentials.password
                        )
                        guard refreshTransportContinuation() else { return }
                        // Re-fence after the re-auth network await: a
                        // superseded renewal must not commit cookies into
                        // (or reload a bridge for) the wrong dashboard.
                        guard switchGenerationIsCurrent(renewalSwitchGeneration),
                              activeDashboardID == renewalDashboardID else { return }
                        if let renewalDashboardID {
                            authenticatedConnection.commitCookies(dashboardID: renewalDashboardID)
                        }
                        // URLSession and WebKit have separate cookie stores.
                        // Reload the bridge so it receives the fresh session.
                        dashboardTicketBridge?.reload()
                        await connect(
                            with: HermesConnection(baseUrl: credentials.baseURL, ticket: authenticatedConnection.ticket),
                            profile: activeProfile,
                            syncPurpose: continuationPurpose,
                            cancelsResumeRestoration: false,
                            automaticWorkToken: continuationAutomaticWorkToken,
                            automaticReconnectOperationID: automaticOperationID,
                            isRenewal: true
                        )
                        guard refreshTransportContinuation() else { return }
                        return
                    } catch is CancellationError {
                        // A superseded reconnect owns the flow from here; do
                        // not force the user to the sign-in card for an
                        // intentional cancellation.
                        return
                    } catch {
                        guard refreshTransportContinuation() else { return }
                        // A re-auth the network cut off (a slow link just
                        // after a resume) says nothing about the sign-in:
                        // retry quietly, as a failed ticket does (#1624).
                        if Self.reauthFailureRetriesQuietly(error) {
                            retryQuietlyAfterFailedRenewal(error)
                            return
                        }
                        // An answer from the server (429 throttle, 401
                        // rejection, 503 outage…) asks to sign in, as before.
                        // The silent re-auth failure is the most diagnostic
                        // explanation for the forced sign-in; carry it to the
                        // classifier. This only determines whether recovery
                        // can be silent. Preserve the saved credentials for
                        // the login screen.
                        silentRenewalReauthError = error
                    }
                }
                guard refreshTransportContinuation() else { return }
                // The dashboard's session is gone (sign-in required): the
                // typed classification routes Repair toward browser sign-in.
                // This connection worked before, so without a re-auth error
                // that explains more, the card says the sign-in expired.
                lastConnectionFailure = .loginRequired
                requireSignIn(
                    failure: silentRenewalReauthError == nil
                        ? .signInExpired
                        : Self.silentRenewalSignInFailure(
                            reauthError: silentRenewalReauthError,
                            bridgeError: bridgeError
                        )
                )
            } else {
                guard refreshTransportContinuation() else { return }
                retryQuietlyAfterFailedRenewal(error)
            }
            return
        }

        let previousClient = client
        guard refreshTransportContinuation() else { return }
        let profile = activeProfile
        let client = makeClient(connection: connection, profile: profile)
        // The same dashboard: a Bot Chat this client hasn't opened again
        // still names the bot's profile.
        if let previousClient { client.inheritSessionProfiles(from: previousClient) }
        self.client = client
        previousClient?.disconnect()

        do {
            try await connectChatResumeClient(client)
            if self.client === client {
                owedPostConnectBootstrap = OwedPostConnectBootstrap(
                    client: client,
                    purpose: continuationPurpose,
                    automaticWorkToken: continuationAutomaticWorkToken
                )
            }
            guard refreshTransportContinuation(),
                  let activeClient = self.client, activeClient === client else { return }
            isConnected = true
            isConnecting = false
            // A fresh healthy session never inherits an older banner error —
            // including the typed classification Repair Connection seeds
            // from: a successful reconnect makes any previous failure stale,
            // so a LATER unrelated failure must route repair from itself.
            // A failed send's reason stays: its words are back in the
            // composer, and it goes with the next send or its chat.
            if errorMessage == nil || errorMessage != sendFailureShown { errorMessage = nil }
            chatErrorBehindRoom = nil
            lastConnectionFailure = nil
            reconnectAttempts = 0
            connectedAt = Date()
            // Bot Mode evidence before the sync: a reconnect re-runs the same
            botRosterVerifiedForCurrentConnection = false
            // resume decision as a cold launch, and a server-identity boundary
            // clears the roster. Without the reload, a canonical chat whose
            // title no longer reads "Bot Chat" would be eligible as this
            // workspace's conversation again.
            await loadChatResumeBotRoster()
            guard refreshTransportContinuation() else { return }
            guard let continuation = await synchronizeTransportContinuation(
                purpose: continuationPurpose,
                automaticWorkToken: continuationAutomaticWorkToken,
                automaticReconnectOperationID: automaticOperationID,
                client: client,
                profile: profile
            ) else { return }
            continuationPurpose = continuation.purpose
            continuationAutomaticWorkToken = continuation.automaticWorkToken
            handedOffAutomaticIntent = handedOffAutomaticIntent
                || continuation.handedOffAutomaticIntent
            // Three independent reads, each guarding its own answer against a
            // switch while it was out: sent together, so the reconnect tail
            // waits one round trip for them, not three (issue 1727). The
            // check that follows is the connection's own.
            async let busyInputModeRead: Void = loadChatResumeBusyInputMode(using: client)
            async let profilesRead: Void = loadChatResumeProfiles()
            async let displayPreferencesRead: Void = loadChatResumeProfileDisplayPreferences()
            _ = await (busyInputModeRead, profilesRead, displayPreferencesRead)
            guard refreshTransportContinuation(),
                  let activeClient = self.client, activeClient === client else { return }
            Task { await loadChatResumeSlashCommands() }
            Task { await refreshNotifierPluginStatus() }
        } catch {
            guard refreshTransportContinuation(),
                  let activeClient = self.client, activeClient === client else { return }
            if stopRecoveryForRefusedSocket(error) { return }
            isConnected = false
            isConnecting = false
            turnState = .reconnecting
            scheduleReconnectAfterFailedSync()
        }
    }

    /// A dashboard socket the server refused in a way no reconnect changes:
    /// a redirected upgrade is the sign-in service in front of the dashboard
    /// sending Conduit to sign in, so its session expired. Reconnecting
    /// would only repeat it, so automatic recovery stops and the sign-in
    /// screen says why. A native grant is kept: a refusal is never a
    /// sign-out. False for any other error, which the reconnect path
    /// retries.
    private func stopRecoveryForRefusedSocket(_ error: Error) -> Bool {
        guard let refusal = error as? DashboardSocketHandshakeError else { return false }
        noteConnectionStep("Socket refused", error: refusal)
        lastConnectionFailure = ConnectionFailureClassifier.classify(refusal)
        performSignInRequired(pendingFailure: .signInExpired, keepingNativeGrant: true)
        return true
    }
}
