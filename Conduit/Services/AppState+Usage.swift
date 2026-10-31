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
        // without it: the usage route has its own per-model rows.
        let modelsResponse = try? await readKeepingAnswer(UsageReport.route(UsageReport.modelsPath, days: days), profile: profile, owner: owner)
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
            try await client.providerQuotaAnswer()
        }
        return answer.map(ProviderQuota.list(from:))
    }

    /// The quota as the page last showed it, or nil when none is kept.
    func keptProviderQuotas() -> [ProviderQuota]? {
        keptAnswer(KeptRoute.providerQuotas).map(ProviderQuota.list(from:))
    }
}
