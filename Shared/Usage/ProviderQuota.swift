//
//  ProviderQuota.swift
//  Conduit
//
//  Each signed-in provider's subscription quota, as Hermes reports it on
//  `model.options` rows (and their REST twin, `/api/model/options`): its
//  windows (a 5-hour session, a weekly cap), a pool's accounts, and a rate
//  limit. Settings > Usage, every provider row and the Plan limits widget
//  (issue 2796) read it, so it's in Shared/ for the widget to compile.
//

import Foundation

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

/// A provider's quota in one line, for its row in a Model list.
struct ProviderQuotaSummary: Equatable {
    /// 0 through 1 of the tightest window left; nil when limited outright.
    let left: Double?
    let resetsAt: Date?

    var isLimited: Bool { left == nil || left == 0 }
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
            guard let quota = ProviderQuota(row: row), seen.insert(quota.slug).inserted else { return nil }
            return quota
        }
    }

    /// What a provider's row in a Model list says of its quota: how much
    /// is left of its tightest window, or that it's limited. A pool counts
    /// the account Hermes can still use with the most left, as Hermes
    /// moves to it; a window on one model family counts only when the
    /// provider has no other. Nil when nothing usable is reported yet.
    var summary: ProviderQuotaSummary? {
        if case .account(let resetsAt) = limit {
            return ProviderQuotaSummary(left: nil, resetsAt: resetsAt)
        }
        if let tightest = Self.tightest(windows) { return tightest }
        let usable = accounts.filter { $0.state == .ready || $0.state == .unknown }.compactMap { Self.tightest($0.windows) }
        // Of two as full, the one that resets sooner, as it frees first.
        if let best = usable.max(by: { ($0.left ?? 0, -($0.resetsAt?.timeIntervalSince1970 ?? .infinity)) < ($1.left ?? 0, -($1.resetsAt?.timeIntervalSince1970 ?? .infinity)) }) {
            return best
        }
        // Every account Hermes could use is limited: the pool is, until the first frees.
        let signedIn = accounts.filter { $0.state != .unavailable }
        if !signedIn.isEmpty, signedIn.allSatisfy({ $0.state == .limited }) {
            return ProviderQuotaSummary(left: nil, resetsAt: signedIn.compactMap(\.resetsAt).min())
        }
        return nil
    }

    private static func tightest(_ windows: [QuotaWindow]) -> ProviderQuotaSummary? {
        let accountWide = windows.filter { !$0.modelScoped }
        let counted = accountWide.isEmpty ? windows : accountWide
        // The fullest window; of two as full, the one that resets later holds longer.
        guard let window = counted.max(by: {
            ($0.fraction, $0.resetsAt?.timeIntervalSince1970 ?? 0) < ($1.fraction, $1.resetsAt?.timeIntervalSince1970 ?? 0)
        }) else { return nil }
        return ProviderQuotaSummary(left: 1 - window.fraction, resetsAt: window.resetsAt)
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
        return HermesTimestamp.parse(text)
    }
}

extension ProviderQuota {
    /// One `model.options` provider row's quota, or nil when it reports
    /// none: the Model lists read it from the row they show.
    init?(row: [String: Any]) {
        // Spelled as ProviderInfo reads a row, so every row it lists can carry one.
        guard let slug = (row["slug"] as? String ?? row["id"] as? String ?? row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !slug.isEmpty else { return nil }
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
                resetsAt: Self.date(account["resets_at"])
            )
        }
        let limit = Self.limit(row["limit"])
        guard !windows.isEmpty || !accounts.isEmpty || limit != nil else { return nil }
        let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(slug: slug, title: name.isEmpty ? slug : name, windows: windows, accounts: accounts, limit: limit)
    }
}
