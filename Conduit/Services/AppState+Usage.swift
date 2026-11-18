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
    /// id, in the profile it runs under (a Bot Chat's is its bot's).
    func loadOpenChatUsage() async -> SessionUsageReadout? {
        guard let runtimeID = activeSessionId else { return nil }
        let sessionID = canonicalSessionID(for: runtimeID) ?? runtimeID
        return await loadSessionUsage(sessionID: sessionID, profile: conversationIdentityProfile, dashboardID: nil)
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
        do {
            if let dashboardID {
                guard let runtime = keptDashboardRuntimes[dashboardID] else { return nil }
                guard let capabilities = await combinedDashboardCapabilities(dashboardID, runtime) else { return .failed }
                guard capabilities.contains(SessionUsage.capability) else { return .needsPluginUpdate }
                response = try await readKeptDashboardJSON(runtime.bridge, path: path)
            } else {
                guard isConnected, let owner = currentDashboardRuntimeOwner() else { return nil }
                switch notifierPlugin.state {
                case .unknown: return .failed
                case .predatesCapabilities: return .needsPluginUpdate
                case .reported(_, let capabilities):
                    guard capabilities.contains(SessionUsage.capability) else { return .needsPluginUpdate }
                }
                response = try await owner.bridge.requestJSON(path: path)
                guard ownsDashboardRuntime(owner) else { return nil }
            }
        } catch DashboardTicketBridgeError.http(status: 404, detail: _) {
            // The route is listed, so a 404 is Hermes having no row for the
            // chat yet: nothing has run in it.
            return .nothingYet
        } catch is CancellationError {
            return nil
        } catch {
            return .failed
        }
        return .loaded(SessionUsage(response: response))
    }
}
