//
//  HostedAppsModel.swift
//  Conduit
//
//  What Capabilities > Connectors' Apps section and its pages share: the
//  apps as Hermes last gave them, and an app's sign-in while it runs. A
//  sign-in opens the app's own page in Safari, then asks Hermes how far it
//  got every two seconds until the account is connected; closing Safari
//  first wakes Hermes to read the accounts, and if the account still isn't
//  connected a few seconds later the sign-in is given up, so no half-made
//  account stays behind.
//

import Foundation
import Observation

@MainActor
@Observable
final class HostedAppsModel {
    private(set) var snapshot: HostedAppsSnapshot?
    /// The snapshot on screen is the kept one: Hermes hasn't answered yet.
    private(set) var showsKept = false
    private(set) var loading = false
    private(set) var error: HostedAppsError?
    private(set) var errorMessage: String?
    /// The app whose sign-in runs; one at a time.
    private(set) var signingIn: String?
    /// Safari over the page, for the sign-in.
    var browser: BotMcpBrowserPage?
    /// A sign-in ended with Safari up and its cover is still going away
    /// (that's asynchronous): a new one waits, or its Safari would never
    /// show.
    private(set) var browserClosing = false
    /// What the last sign-in or change said, per app.
    private(set) var notes: [String: String] = [:]
    /// The profile and client the snapshot belongs to.
    @ObservationIgnored private var scope: String?
    /// The Hermes a sign-in runs on: the dashboard and profile, whatever
    /// connection carries them. A reconnect keeps it.
    @ObservationIgnored private var hermes: String?
    /// Which sign-in is the latest: one given up while Hermes started it
    /// runs on, and never touches a newer one's state.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var browserClosedAt: Date?
    /// Which close the fallback below belongs to: an earlier one's timer
    /// never ends a later close.
    @ObservationIgnored private var browserCloseGeneration = 0

    static let pollInterval: Duration = .seconds(2)
    /// How long a closed Safari is given for Hermes to see the account.
    static let closedGrace: TimeInterval = 6

    /// Opens on the kept apps for `scope` (the dashboard, profile and
    /// client), and drops another scope's. A sign-in and what the section
    /// said go only with the Hermes (`hermes`, the dashboard and profile):
    /// a connection that drops and comes back mid-sign-in keeps asking
    /// the same Hermes, so the account it started is finished or given up
    /// there, never left half-made (issue 1997).
    func show(_ appState: AppState) {
        show(scope: appState.hostedAppsScope, hermes: appState.hostedAppsHermes, kept: appState.keptHostedApps())
    }

    func show(scope: String, hermes: String, kept: HostedAppsSnapshot?) {
        guard scope != self.scope else { return }
        if hermes != self.hermes {
            cancelSignIn()
            notes = [:]
        }
        self.scope = scope
        self.hermes = hermes
        snapshot = kept
        showsKept = kept != nil
        error = nil
        errorMessage = nil
    }

    func reload(_ appState: AppState) async {
        let scope = self.scope
        reads += 1
        let read = reads
        loading = true
        defer { if read == reads { loading = false } }
        do {
            let fresh = try await appState.loadHostedApps()
            guard read == reads, scope == self.scope else { return }
            snapshot = fresh
            showsKept = false
            HostedAppLogoLoader.retryFailed()
            error = nil
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard read == reads, scope == self.scope else { return }
            self.error = error as? HostedAppsError
            errorMessage = UserFacingError.message(for: error)
        }
    }

    func note(_ slug: String, _ text: String?) {
        notes[slug] = text
    }

    /// Takes Hermes' copy of the rules after a change.
    func take(policy: HostedAppPolicy) {
        snapshot?.policy = policy
        snapshot?.rulesFailed = nil
    }

    func take(account: HostedAppAccount) {
        snapshot?.accounts = snapshot?.accounts.map { $0.connectionID == account.connectionID ? account : $0 } ?? []
    }

    func drop(account id: String) {
        snapshot?.accounts.removeAll { $0.connectionID == id }
    }

    // MARK: Sign-in

    /// Connects `slug`: a new account (named `alias`), or `repairing` one.
    func signIn(_ slug: String, alias: String? = nil, repairing connectionID: String? = nil, appState: AppState) {
        guard signingIn == nil, browser == nil, !browserClosing else { return }
        signingIn = slug
        notes[slug] = nil
        browserClosedAt = nil
        let hermes = self.hermes
        attempt += 1
        let attempt = self.attempt
        signInTask = Task { [weak self] in
            await self?.runSignIn(slug, alias: alias, repairing: connectionID, hermes: hermes, attempt: attempt, appState: appState)
        }
    }

    /// Safari went away: by Done, or because the sign-in finished.
    func browserClosed() {
        closeBrowser()
        if signingIn != nil, browserClosedAt == nil { browserClosedAt = Date() }
    }

    /// Safari's cover is gone from the screen.
    func browserDismissed() {
        browserClosing = false
        browserClosed()
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signingIn = nil
        closeBrowser()
        browserClosedAt = nil
    }

    private func closeBrowser() {
        if browser != nil {
            browserClosing = true
            browserCloseGeneration += 1
            let generation = browserCloseGeneration
            // Also when no cover was up to say it went (its page was left).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, self.browserCloseGeneration == generation else { return }
                self.browserClosing = false
            }
        }
        browser = nil
    }

    private func runSignIn(_ slug: String, alias: String?, repairing: String?, hermes: String?, attempt: Int, appState: AppState) async {
        var operation: HostedAppOperation?
        var isLatest: Bool { hermes == self.hermes && attempt == self.attempt }
        defer {
            if isLatest, signingIn == slug {
                signingIn = nil
                signInTask = nil
                closeBrowser()
                browserClosedAt = nil
            }
        }
        do {
            // Left while Hermes starts it, the sign-in is still given up
            // once it has an id: the start runs on, uncancelled.
            var current = try await Task { try await appState.connectHostedApp(slug, alias: alias, repairing: repairing) }.value
            operation = current
            try Task.checkCancellation()
            guard isLatest else { return }
            if current.target(slug)?.connected == true {
                await finished(slug, appState: appState)
                return
            }
            guard let url = current.target(slug)?.connectURL else {
                notes[slug] = current.target(slug)?.detail ?? AppLocalization.string("Hermes couldn't open the sign-in page. Try again.")
                try? await appState.stopHostedAppSignIn(current)
                return
            }
            browser = BotMcpBrowserPage(url: url)
            var wokeHermes = false
            while true {
                try await Task.sleep(for: Self.pollInterval)
                guard isLatest else { return }
                if browserClosedAt != nil, !wokeHermes {
                    wokeHermes = true
                    try? await appState.wakeHostedAppOperation(current.id)
                }
                do {
                    current = try await appState.hostedAppOperation(current.id).carryingLink(from: current)
                } catch let error where Self.isConnectionBlip(error, appState: appState) {
                    // Asked again once the connection is back: the
                    // sign-in lives on Hermes, and Safari stays up.
                    continue
                }
                operation = current
                guard isLatest else { return }
                let target = current.target(slug)
                if target?.connected == true {
                    await finished(slug, appState: appState)
                    return
                }
                if target?.retryable == true || current.settled {
                    notes[slug] = target?.detail ?? AppLocalization.string("The sign-in didn't finish. Try again.")
                    try? await appState.stopHostedAppSignIn(current)
                    await reload(appState)
                    return
                }
                if let closedAt = browserClosedAt, Date().timeIntervalSince(closedAt) >= Self.closedGrace {
                    notes[slug] = AppLocalization.string("The sign-in wasn't finished.")
                    try? await appState.stopHostedAppSignIn(current)
                    await reload(appState)
                    return
                }
            }
        } catch is CancellationError {
            // Left the page: give it up there, never on a Hermes switched to.
            // A task of its own, since this one's calls are cancelled.
            if hermes == self.hermes, let operation {
                Task { try? await appState.stopHostedAppSignIn(operation) }
            }
        } catch {
            guard isLatest else { return }
            notes[slug] = UserFacingError.message(for: error)
            if let operation { try? await appState.stopHostedAppSignIn(operation) }
        }
    }

    /// The connection, not Hermes, failed the ask: no connection, another
    /// client took over, or it dropped on the way. A timeout isn't one:
    /// that Hermes may be stuck, and the sign-in says so.
    static func isConnectionBlip(_ error: Error, appState: AppState) -> Bool {
        if !appState.isConnected { return true }
        switch error {
        case HostedAppsError.notConnected, HostedAppsError.superseded: return true
        case HermesError.notConnected, HermesError.connectionClosed: return true
        case is URLError: return true
        default: return false
        }
    }

    private func finished(_ slug: String, appState: AppState) async {
        closeBrowser()
        Haptics.success()
        notes[slug] = AppLocalization.string("Connected. Hermes can use it in new chats.")
        await reload(appState)
    }
}
