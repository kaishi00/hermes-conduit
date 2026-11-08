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
    /// What the last sign-in or change said, per app.
    private(set) var notes: [String: String] = [:]
    /// The profile and client the snapshot belongs to.
    @ObservationIgnored private var scope: String?
    @ObservationIgnored private var reads = 0
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var browserClosedAt: Date?

    static let pollInterval: Duration = .seconds(2)
    /// How long a closed Safari is given for Hermes to see the account.
    static let closedGrace: TimeInterval = 6

    /// Opens on the kept apps for `scope` (the dashboard, profile and
    /// client), and drops another scope's.
    func show(scope: String, kept: HostedAppsSnapshot?) {
        guard scope != self.scope else { return }
        cancelSignIn()
        self.scope = scope
        snapshot = kept
        showsKept = kept != nil
        error = nil
        errorMessage = nil
        notes = [:]
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
        guard signingIn == nil, browser == nil else { return }
        signingIn = slug
        notes[slug] = nil
        browserClosedAt = nil
        let scope = self.scope
        signInTask = Task { [weak self] in
            await self?.runSignIn(slug, alias: alias, repairing: connectionID, scope: scope, appState: appState)
        }
    }

    /// Safari went away: by Done, or because the sign-in finished.
    func browserClosed() {
        browser = nil
        if signingIn != nil, browserClosedAt == nil { browserClosedAt = Date() }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signingIn = nil
        browser = nil
        browserClosedAt = nil
    }

    private func runSignIn(_ slug: String, alias: String?, repairing: String?, scope: String?, appState: AppState) async {
        var operation: HostedAppOperation?
        defer {
            if scope == self.scope, signingIn == slug {
                signingIn = nil
                signInTask = nil
                browser = nil
                browserClosedAt = nil
            }
        }
        do {
            var current = try await appState.connectHostedApp(slug, alias: alias, repairing: repairing)
            operation = current
            guard !Task.isCancelled, scope == self.scope else { return }
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
                guard scope == self.scope else { return }
                if browserClosedAt != nil, !wokeHermes {
                    wokeHermes = true
                    try? await appState.wakeHostedAppOperation(current.id)
                }
                current = try await appState.hostedAppOperation(current.id).carryingLink(from: current)
                operation = current
                guard scope == self.scope else { return }
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
            if scope == self.scope, let operation {
                Task { try? await appState.stopHostedAppSignIn(operation) }
            }
        } catch {
            guard scope == self.scope else { return }
            notes[slug] = UserFacingError.message(for: error)
            if let operation { try? await appState.stopHostedAppSignIn(operation) }
        }
    }

    private func finished(_ slug: String, appState: AppState) async {
        browser = nil
        Haptics.success()
        notes[slug] = AppLocalization.string("Connected. Hermes can use it in new chats.")
        await reload(appState)
    }
}
