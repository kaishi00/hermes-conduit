//
//  AppState+Usage.swift
//  Conduit
//
//  Settings > Usage (#813): the active profile's spend over a period and
//  its providers' quota. Asked when the page opens, when its period
//  changes, and on refresh; never polled, since a provider's quota check
//  can be rate-limited on the host. Each answer is kept on the phone, so
//  the page opens on the numbers it showed last (#1533).
//

import Foundation

enum UsageLoadError: Error, Equatable {
    case notConnected
    /// This Hermes has no analytics routes.
    case unsupported
    /// The dashboard's sign-in lapsed; pulling down won't bring it back.
    case signInRequired
    case failed
}

extension AppState {
    func loadUsageReport(days: Int) async throws -> UsageReport {
        guard isConnected, let owner = currentDashboardRuntimeOwner() else { throw UsageLoadError.notConnected }
        let profile = activeProfile
        let usageResponse: [String: Any]
        do {
            usageResponse = try await readKeepingAnswer(UsageReport.route(UsageReport.usagePath, days: days), profile: profile, owner: owner)
        } catch let error as DashboardTicketBridgeError where GeminiLiveTokenClient.isMissingRoute(error) {
            throw UsageLoadError.unsupported
        } catch DashboardTicketBridgeError.signInRequired {
            throw UsageLoadError.signInRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageLoadError.failed
        }
        // The per-model route is the better split, but the page stands
        // without it: the usage route has its own per-model rows. A read
        // that fails is kept as none, so the page opens on the rows it
        // showed, never on an older split (and its cost) beside newer totals.
        let modelsRoute = UsageReport.route(UsageReport.modelsPath, days: days)
        let modelsResponse = try await keepingAnswer(profile: profile, owner: owner, keptAs: { _ in modelsRoute }) {
            (try? await owner.bridge.requestJSON(path: DashboardPath.withProfile(modelsRoute, profile: profile))) ?? [:]
        }
        return UsageReport.parse(usage: usageResponse, models: modelsResponse, days: days)
    }

    /// The period's numbers as the page last showed them for the active
    /// profile, kept on the phone, or nil when none are.
    func keptUsageReport(days: Int) -> UsageReport? {
        guard let usage = keptAnswer(UsageReport.route(UsageReport.usagePath, days: days)) else { return nil }
        return UsageReport.parse(usage: usage, models: keptAnswer(UsageReport.route(UsageReport.modelsPath, days: days)), days: days)
    }

    /// Nil when it couldn't be asked: the page then leaves the quota out
    /// rather than saying there is none.
    func loadProviderQuotas() async -> [ProviderQuota]? {
        guard let client, let owner = currentDashboardRuntimeOwner() else { return nil }
        let answer = try? await keepingAnswer(profile: activeProfile, owner: owner, keptAs: { _ in KeptRoute.providerQuotas }) {
            try await client.modelOptionsAnswer()
        }
        return answer.map(ProviderQuota.list(from:))
    }

    /// The quota as the page last showed it, or nil when none is kept.
    func keptProviderQuotas() -> [ProviderQuota]? {
        keptAnswer(KeptRoute.providerQuotas).map(ProviderQuota.list(from:))
    }
}

// MARK: - One chat's usage (issue 2699)

extension AppState {
    /// The open chat's tokens and cost, for the Context sheet: its durable
    /// id, in the profile it runs under (a Bot Chat's is its bot's). Nil
    /// when the open chat can't be told apart from another (issue 2739).
    func loadOpenChatUsage() async -> SessionUsageReadout? {
        guard activeSessionId != nil else { return nil }
        guard let sessionID = openChatUsageSessionID() else {
            // Not asked, not failed: say why (#2751 review).
            return .unavailable(AppLocalization.string("Another chat here goes by this chat's id, so its usage can't be told apart."))
        }
        return await loadSessionUsage(sessionID: sessionID, profile: conversationIdentityProfile, dashboardID: nil)
    }

    /// The id Hermes stores the open chat under, which the plugin reads by,
    /// as Usage Details asks for a listed row (`storedSessionId ?? id`):
    /// the runtime-to-durable binding the open confirmed, then a Bot Chat's
    /// registry row, then the row that owns the id. An id two rows carry is
    /// neither's, so it isn't asked about (issue 2739). With no row and no
    /// binding (a chat not listed yet) the open id is asked as it is.
    func openChatUsageSessionID() -> String? {
        guard let runtimeID = activeSessionId else { return nil }
        let profile = conversationIdentityProfile
        if let durable = conversationIdentityIndex.durableID(forRuntime: runtimeID, profile: profile) { return durable }
        if let bot = activeBotChatProfile,
           let chat = shownBotRoster.first(where: { $0.name.caseInsensitiveCompare(bot) == .orderedSame })?.canonicalSessionID {
            return chat
        }
        let rows = Array([sessions, cronSessions].joined()).filter { sessionBelongsToProfile($0, profile: profile) }
        if let own = rows.first(where: { $0.id == runtimeID || $0.storedSessionId == runtimeID }) {
            return own.storedSessionId ?? own.id
        }
        let borrowers = rows.filter { $0.alternateIds.contains(runtimeID) }
        if borrowers.count == 1, let row = borrowers.first { return row.storedSessionId ?? row.id }
        return borrowers.isEmpty ? runtimeID : nil
    }

    /// A listed chat's tokens and cost, for Usage Details: another combined
    /// dashboard's row is read through its kept connection.
    func loadSessionUsage(for session: SessionSummary) async -> SessionUsageReadout? {
        let sessionID = session.storedSessionId ?? session.id
        if let dashboardID = combinedChatDashboard(session) {
            return await loadSessionUsage(sessionID: sessionID, profile: session.profile ?? "default", dashboardID: dashboardID)
        }
        return await loadSessionUsage(sessionID: sessionID, profile: rowProfile(session), dashboardID: nil)
    }

    /// Nil when it can't be asked now (no connection, or the dashboard
    /// changed while the read was out): the sheet then shows nothing rather
    /// than another dashboard's numbers.
    private func loadSessionUsage(sessionID: String, profile: String, dashboardID: UUID?) async -> SessionUsageReadout? {
        guard let route = SessionUsage.route(sessionID: sessionID) else { return .failed }
        let path = DashboardPath.withProfile(route, profile: profile)
        let response: [String: Any]
        var stillAsked: () -> Bool = { true }
        do {
            if let dashboardID {
                guard let runtime = keptDashboardRuntimes[dashboardID] else { return nil }
                guard let capabilities = await combinedDashboardCapabilities(dashboardID, runtime) else { return .failed }
                guard capabilities.contains(SessionUsage.capability) else { return .needsPluginUpdate }
                // The answer is about this kept connection: let go, or kept
                // anew, while the read was out, it says nothing (issue 2740).
                stillAsked = {
                    self.keptDashboardRuntimes[dashboardID]?.bridge === runtime.bridge
                        && self.keptDashboardRuntimes[dashboardID]?.keptAt == runtime.keptAt
                }
                response = try await readKeptDashboardJSON(runtime.bridge, path: path)
            } else {
                guard isConnected, let owner = currentDashboardRuntimeOwner() else { return nil }
                switch notifierPlugin.state {
                // Not reported yet (just connected): ask anyway, and a bare
                // 404 below says the route is missing.
                case .unknown: break
                case .predatesCapabilities: return .needsPluginUpdate
                case .reported(_, let capabilities):
                    guard capabilities.contains(SessionUsage.capability) else { return .needsPluginUpdate }
                }
                stillAsked = { self.ownsDashboardRuntime(owner) }
                response = try await owner.bridge.requestJSON(path: path)
            }
        } catch {
            // The same fence as the answer's: what the dashboard left says,
            // failure or not, isn't said about what's on screen now.
            guard stillAsked() else { return nil }
            if case DashboardTicketBridgeError.http(status: 404, detail: let detail) = error {
                return SessionUsageReadout.notFound(detail: detail, path: path)
            }
            return UserFacingError.isCancellation(error) ? nil : .failed
        }
        guard stillAsked() else { return nil }
        return .loaded(SessionUsage(response: response))
    }
}
