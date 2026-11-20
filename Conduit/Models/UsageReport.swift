//
//  UsageReport.swift
//  Conduit
//
//  Settings > Usage (#813): what the profile spent over a period, read from
//  the dashboard's analytics routes (`/api/analytics/usage` for the totals
//  and days, `/api/analytics/models` for the per-model rows). Each
//  signed-in provider's subscription quota from `model.options` is in
//  Shared/Usage/ProviderQuota.swift, which the Plan limits widget reads
//  too. Hermes keeps all of it; Conduit only reads it, on open and on
//  refresh.
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

    /// Every token the period counted: input, output and cache reads.
    /// Reasoning is already inside output, so it isn't added again.
    var allTokens: Int { input + output + cacheRead }

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

    /// A route for the period, without its profile, which the request
    /// adds (`DashboardPath.withProfile`): the page's answers are kept
    /// under it.
    static func route(_ path: String, days: Int) -> String {
        "\(path)?days=\(days)"
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

    /// The most one count can hold: a quarter of Int.max, so adding up to
    /// three counts (`allTokens`) can never overflow, whatever Hermes sends.
    static let countCap = Int.max / 4

    /// JSON numbers arrive as NSNumber; SQLite's SUM over no rows is null.
    static func int(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber:
            let double = number.doubleValue
            // Double(countCap) rounds up to 2^61, one past the cap, so cap the Int too.
            return double.isFinite ? min(Int(max(0, min(double, Double(countCap)))), countCap) : 0
        case let text as String: return Int(text).map { max(0, min($0, countCap)) } ?? 0
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
