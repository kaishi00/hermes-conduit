//
//  AppState+Usage.swift
//  Conduit
//
//  Settings > Usage (#813): the active profile's spend over a period and
//  its providers' quota. Asked when the page opens, when its period
//  changes, and on refresh; never polled, since a provider's quota check
//  can be rate-limited on the host.
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
        guard isConnected, let bridge = dashboardTicketBridge else { throw UsageLoadError.notConnected }
        let profile = activeProfile
        let usageResponse: [String: Any]
        do {
            usageResponse = try await bridge.requestJSON(path: UsageReport.path(UsageReport.usagePath, days: days, profile: profile))
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
        let modelsResponse = try? await bridge.requestJSON(path: UsageReport.path(UsageReport.modelsPath, days: days, profile: profile))
        return UsageReport.parse(usage: usageResponse, models: modelsResponse, days: days)
    }

    /// Nil when it couldn't be asked: the page then leaves the quota out
    /// rather than saying there is none.
    func loadProviderQuotas() async -> [ProviderQuota]? {
        guard let client else { return nil }
        return try? await client.providerQuotas()
    }
}
