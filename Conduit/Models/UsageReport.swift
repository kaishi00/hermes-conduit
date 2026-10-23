//
//  UsageReport.swift
//  Conduit
//
//  Settings > Usage (#813): what the profile spent over a period, read from
//  the dashboard's analytics routes (`/api/analytics/usage` for the totals
//  and days, `/api/analytics/models` for the per-model rows), and each
//  signed-in provider's subscription quota from `model.options`. Hermes
//  keeps all of it; Conduit only reads it, on open and on refresh.
//

import Foundation

struct UsageTokens: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var reasoning = 0
    var estimatedCost = 0.0
    var actualCost = 0.0
    var sessions = 0
    var apiCalls = 0

    var total: Int { input + output }

    /// What the provider billed when Hermes knows it, else Hermes' estimate.
    /// Hermes sums a missing billed cost as 0 (COALESCE), so a reported $0
    /// and an unreported one look the same; both fall back to the estimate.
    var cost: Double { actualCost > 0 ? actualCost : estimatedCost }
    var costIsEstimate: Bool { actualCost <= 0 }

    /// One `daily`, `by_model` or `models` row: the same column names on
    /// both routes.
    init(row: [String: Any]) {
        input = UsageReport.int(row["input_tokens"])
        output = UsageReport.int(row["output_tokens"])
        cacheRead = UsageReport.int(row["cache_read_tokens"])
        reasoning = UsageReport.int(row["reasoning_tokens"])
        estimatedCost = UsageReport.double(row["estimated_cost"])
        actualCost = UsageReport.double(row["actual_cost"])
        sessions = UsageReport.int(row["sessions"])
        apiCalls = UsageReport.int(row["api_calls"])
    }

    /// The `totals` object, whose columns carry a `total_` prefix.
    init(totals: [String: Any]) {
        input = UsageReport.int(totals["total_input"])
        output = UsageReport.int(totals["total_output"])
        cacheRead = UsageReport.int(totals["total_cache_read"])
        reasoning = UsageReport.int(totals["total_reasoning"])
        estimatedCost = UsageReport.double(totals["total_estimated_cost"])
        actualCost = UsageReport.double(totals["total_actual_cost"])
        sessions = UsageReport.int(totals["total_sessions"])
        apiCalls = UsageReport.int(totals["total_api_calls"])
    }

    init() {}
}

struct UsageDay: Equatable, Identifiable {
    /// The host's local calendar day, as Hermes groups it.
    let date: Date
    let usage: UsageTokens
    var id: Date { date }
}

struct ModelUsage: Equatable, Identifiable {
    let model: String
    /// The billing provider; empty when Hermes didn't record one.
    let provider: String
    let usage: UsageTokens
    var id: String { "\(provider)/\(model)" }
}

struct UsageReport: Equatable {
    let days: Int
    let totals: UsageTokens
    let daily: [UsageDay]
    let models: [ModelUsage]

    /// The period's cost. With per-model rows, their sum: Hermes' billed
    /// total covers only the models a provider billed, so a period that
    /// mixes billed and estimated models must not show it as the whole.
    var cost: Double {
        models.isEmpty ? totals.cost : models.reduce(0) { $0 + $1.usage.cost }
    }

    /// True when any of that cost is Hermes' estimate.
    var costIsEstimate: Bool {
        guard !models.isEmpty else { return totals.costIsEstimate }
        return models.allSatisfy(\.usage.costIsEstimate)
            || models.contains { $0.usage.costIsEstimate && $0.usage.cost > 0 }
    }

    /// The periods the page offers: the presets Hermes' own dashboard has.
    static let periods = [7, 30, 90]
    static let usagePath = "/api/analytics/usage"
    static let modelsPath = "/api/analytics/models"

    static func path(_ route: String, days: Int, profile: String) -> String {
        DashboardPath.withProfile("\(route)?days=\(days)", profile: profile)
    }

    /// `usage` is `/api/analytics/usage`'s answer; `models`, when the host
    /// has that route, is `/api/analytics/models`'s. Its rows split a chat
    /// that switched models between them, so they're preferred over the
    /// usage route's `by_model`, which credits a chat to its last model.
    static func parse(usage: [String: Any], models: [String: Any]?, days: Int) -> UsageReport {
        let totals = (usage["totals"] as? [String: Any]).map(UsageTokens.init(totals:)) ?? UsageTokens()
        var seenDays = Set<Date>()
        let daily = (usage["daily"] as? [[String: Any]] ?? []).compactMap { row -> UsageDay? in
            guard let day = row["day"] as? String, let date = dayFormatter.date(from: day),
                  seenDays.insert(date).inserted else { return nil }
            return UsageDay(date: date, usage: UsageTokens(row: row))
        }
        .sorted { $0.date < $1.date }
        let modelRows = (models?["models"] as? [[String: Any]]) ?? (usage["by_model"] as? [[String: Any]]) ?? []
        var seen = Set<String>()
        let perModel = modelRows.compactMap { row -> ModelUsage? in
            let name = (row["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let provider = (row["provider"] as? String ?? row["billing_provider"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = ModelUsage(model: name, provider: provider, usage: UsageTokens(row: row))
            return seen.insert(entry.id).inserted ? entry : nil
        }
        .sorted { $0.usage.total > $1.usage.total }
        return UsageReport(
            days: int(usage["period_days"]) > 0 ? int(usage["period_days"]) : days,
            totals: totals,
            daily: daily,
            models: perModel
        )
    }

    /// SQLite's `date(…, 'localtime')`: the host's day, read here as a
    /// calendar day in this device's zone so the chart's bars land on it.
    /// Main-actor use only, like CronScheduleText's formatters.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// JSON numbers arrive as NSNumber; SQLite's SUM over no rows is null.
    static func int(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber:
            let double = number.doubleValue
            return double.isFinite ? Int(max(0, min(double, Double(Int.max / 2)))) : 0
        case let text as String: return Int(text) ?? 0
        default: return 0
        }
    }

    static func double(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber:
            let double = number.doubleValue
            return double.isFinite ? max(0, double) : 0
        case let text as String: return Double(text).flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0
        default: return 0
        }
    }
}

// MARK: - Provider quota

/// One subscription window: e.g. a 5-hour session or a weekly cap.
struct QuotaWindow: Equatable, Identifiable {
    /// Hermes' own name for the window ("Session", "Weekly").
    let label: String
    /// 0 through 100.
    let usedPercent: Double
    let resetsAt: Date?
    /// The window caps one model family, not the whole account.
    let modelScoped: Bool
    var id: String { label }

    var fraction: Double { min(max(usedPercent / 100, 0), 1) }
}

struct QuotaAccount: Equatable, Identifiable {
    enum State: String {
        case ready, limited, unknown, unavailable
    }

    let id: String
    /// May be empty: the page then numbers the account.
    let label: String
    let windows: [QuotaWindow]
    let state: State
    let resetsAt: Date?
}

/// A provider's rate limit from its credential pool.
enum ProviderRateLimit: Equatable {
    /// The whole login is limited, until `resetsAt` when Hermes knows it.
    case account(resetsAt: Date?)
    /// Only these models are, each until its time.
    case models([LimitedModel])

    struct LimitedModel: Equatable, Identifiable {
        let model: String
        let resetsAt: Date?
        var id: String { model }
    }
}

struct ProviderQuota: Equatable, Identifiable {
    let slug: String
    let title: String
    /// A single-account provider's windows.
    let windows: [QuotaWindow]
    /// A multi-account pool's accounts, each with its own windows.
    let accounts: [QuotaAccount]
    let limit: ProviderRateLimit?
    var id: String { slug }

    /// `model.options`' providers that report a quota or a limit, in the
    /// catalog's order. Hermes answers from its cache (stale snapshots are
    /// left out there) and refreshes it in the background.
    static func list(from options: [String: Any]) -> [ProviderQuota] {
        let rows = options["providers"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return rows.compactMap { row -> ProviderQuota? in
            guard let slug = (row["slug"] as? String ?? row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !slug.isEmpty, seen.insert(slug).inserted else { return nil }
            let usage = row["usage"] as? [String: Any] ?? [:]
            let windows = Self.windows(usage["windows"])
            var accountIDs = Set<String>()
            let accounts = (usage["accounts"] as? [[String: Any]] ?? []).enumerated().compactMap { index, account -> QuotaAccount? in
                // Ids name rows on screen, so a missing or repeated one gets its position.
                let given = (account["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                var id = given.flatMap { accountIDs.contains($0) ? nil : $0 } ?? "account-\(index)"
                var suffix = 1
                while !accountIDs.insert(id).inserted {
                    suffix += 1
                    id = "account-\(index)-\(suffix)"
                }
                return QuotaAccount(
                    id: id,
                    label: (account["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    windows: Self.windows(account["windows"]),
                    state: QuotaAccount.State(rawValue: account["state"] as? String ?? "") ?? .unknown,
                    resetsAt: date(account["resets_at"])
                )
            }
            let limit = Self.limit(row["limit"])
            guard !windows.isEmpty || !accounts.isEmpty || limit != nil else { return nil }
            let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderQuota(slug: slug, title: name.isEmpty ? slug : name, windows: windows, accounts: accounts, limit: limit)
        }
    }

    private static func windows(_ value: Any?) -> [QuotaWindow] {
        var seen = Set<String>()
        return (value as? [[String: Any]] ?? []).compactMap { window in
            guard let label = (window["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty, seen.insert(label).inserted,
                  let used = window["used_percent"] as? NSNumber, used.doubleValue.isFinite else { return nil }
            return QuotaWindow(
                label: label,
                usedPercent: used.doubleValue,
                resetsAt: date(window["resets_at"]),
                modelScoped: window["scope"] as? String == "model"
            )
        }
    }

    private static func limit(_ value: Any?) -> ProviderRateLimit? {
        guard let limit = value as? [String: Any] else { return nil }
        switch limit["scope"] as? String {
        case "account":
            return .account(resetsAt: date(limit["resets_at"]))
        case "models":
            let models = (limit["models"] as? [String: Any] ?? [:])
                .map { ProviderRateLimit.LimitedModel(model: $0.key, resetsAt: date($0.value)) }
                .sorted { $0.model < $1.model }
            return models.isEmpty ? nil : .models(models)
        default:
            return nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return CronScheduleText.parseDate(text)
    }
}
