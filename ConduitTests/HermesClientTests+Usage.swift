//
//  HermesClientTests+Usage.swift
//  ConduitTests
//
//  Settings > Usage (#813): the dashboard's analytics answers and
//  `model.options`' quota rows, in the shapes upstream Hermes sends them.
//

import Foundation
import XCTest
@testable import Conduit

extension HermesClientTests {
    private static let usageResponse: [String: Any] = [
        "period_days": 7,
        "daily": [[String: Any]]([
            ["day": "2026-10-20", "input_tokens": 1200, "output_tokens": 300, "estimated_cost": 0.02, "actual_cost": 0, "sessions": 2, "api_calls": 5] as [String: Any],
            ["day": "2026-10-18", "input_tokens": 800, "output_tokens": NSNull(), "estimated_cost": 0.01, "sessions": 1, "api_calls": 2] as [String: Any],
            ["day": "2026-10-20", "input_tokens": 9, "output_tokens": 9] as [String: Any],
            ["day": "not a day", "input_tokens": 5] as [String: Any],
        ]),
        "by_model": [
            ["model": "claude-sonnet", "input_tokens": 2000, "output_tokens": 300, "estimated_cost": 0.03, "sessions": 3, "api_calls": 7] as [String: Any],
        ] as [[String: Any]],
        "totals": [
            "total_input": 2000, "total_output": 300, "total_cache_read": 50, "total_reasoning": NSNull(),
            "total_estimated_cost": 0.03, "total_actual_cost": 0, "total_sessions": 3, "total_api_calls": 7,
        ] as [String: Any],
    ]

    func testUsageReportReadsTotalsAndDaysInOrder() {
        let report = UsageReport.parse(usage: Self.usageResponse, models: nil, days: 30)

        XCTAssertEqual(report.days, 7)
        XCTAssertEqual(report.totals.input, 2000)
        XCTAssertEqual(report.totals.output, 300)
        XCTAssertEqual(report.totals.cacheRead, 50)
        XCTAssertEqual(report.totals.reasoning, 0)
        XCTAssertEqual(report.totals.sessions, 3)
        XCTAssertEqual(report.totals.apiCalls, 7)
        XCTAssertEqual(report.totals.cost, 0.03, accuracy: 0.0001)
        XCTAssertTrue(report.totals.costIsEstimate)
        // The unparseable day is dropped; the rest are oldest first.
        XCTAssertEqual(report.daily.map { UsageReport.dayFormatter.string(from: $0.date) }, ["2026-10-18", "2026-10-20"])
        XCTAssertEqual(report.daily.first?.usage.total, 800)
        // A repeated day keeps its first row, so the chart's ids stay unique.
        XCTAssertEqual(report.daily.last?.usage.total, 1500)
    }

    func testUsageReportPrefersTheModelsRouteAndFallsBackToByModel() {
        let fallback = UsageReport.parse(usage: Self.usageResponse, models: nil, days: 7)
        XCTAssertEqual(fallback.models.map(\.model), ["claude-sonnet"])
        XCTAssertEqual(fallback.models.first?.provider, "")

        let models: [String: Any] = ["models": [[String: Any]]([
            ["model": "small", "provider": "openrouter", "input_tokens": 10, "output_tokens": 5, "estimated_cost": 0, "actual_cost": 0] as [String: Any],
            ["model": "claude-sonnet", "provider": "anthropic", "input_tokens": 1500, "output_tokens": 200, "estimated_cost": 0.02, "actual_cost": 0.025] as [String: Any],
            ["model": "claude-sonnet", "provider": "anthropic", "input_tokens": 1, "output_tokens": 1] as [String: Any],
            ["model": "  ", "provider": "x", "input_tokens": 99] as [String: Any],
        ])]
        let report = UsageReport.parse(usage: Self.usageResponse, models: models, days: 7)

        // Biggest first, duplicates and nameless rows dropped.
        XCTAssertEqual(report.models.map(\.id), ["anthropic/claude-sonnet", "openrouter/small"])
        XCTAssertEqual(report.models.first?.usage.cost ?? 0, 0.025, accuracy: 0.0001)
        XCTAssertEqual(report.models.first?.usage.costIsEstimate, false)
        // The billed model plus the free one: the whole is billed.
        XCTAssertEqual(report.cost, 0.025, accuracy: 0.0001)
        XCTAssertFalse(report.costIsEstimate)

        // One billed, one estimated: the total is the sum and says it's estimated.
        let mixed = UsageReport.parse(usage: Self.usageResponse, models: ["models": [
            ["model": "billed", "provider": "p", "input_tokens": 10, "estimated_cost": 0.5, "actual_cost": 0.4] as [String: Any],
            ["model": "guessed", "provider": "p", "input_tokens": 5, "estimated_cost": 0.2, "actual_cost": 0] as [String: Any],
        ] as [[String: Any]]], days: 7)
        XCTAssertEqual(mixed.cost, 0.6, accuracy: 0.0001)
        XCTAssertTrue(mixed.costIsEstimate)
    }

    func testUsageReportPathCarriesPeriodAndProfile() {
        // The route the page keeps its answers under, and the profile the request adds.
        XCTAssertEqual(UsageReport.route(UsageReport.usagePath, days: 30), "/api/analytics/usage?days=30")
        XCTAssertEqual(DashboardPath.withProfile(UsageReport.route(UsageReport.usagePath, days: 30), profile: "default"), "/api/analytics/usage?days=30")
        XCTAssertEqual(DashboardPath.withProfile(UsageReport.route(UsageReport.modelsPath, days: 7), profile: "work"), "/api/analytics/models?days=7&profile=work")
    }

    func testProviderQuotaReadsWindowsAccountsAndLimits() {
        let options: [String: Any] = ["providers": [
            ["slug": "openrouter", "name": "OpenRouter"] as [String: Any],
            [
                "slug": "anthropic", "name": "Anthropic",
                "usage": ["windows": [
                    ["label": "Session", "used_percent": 42.5, "resets_at": "2026-10-22T03:00:00.000000+00:00", "scope": "account"] as [String: Any],
                    ["label": "Opus weekly", "used_percent": 130, "resets_at": NSNull(), "scope": "model"] as [String: Any],
                    ["label": "Broken", "used_percent": NSNull()] as [String: Any],
                ] as [[String: Any]]] as [String: Any],
            ] as [String: Any],
            [
                "slug": "openai-codex", "name": "",
                "usage": ["accounts": [
                    ["id": "a1", "label": "Work", "windows": [] as [[String: Any]], "state": "limited", "resets_at": "2026-10-23T00:00:00+00:00"] as [String: Any],
                    ["id": "", "label": "", "windows": [] as [[String: Any]], "state": "something-new"] as [String: Any],
                    ["id": "a1", "label": "Twin", "windows": [] as [[String: Any]], "state": "ready"] as [String: Any],
                    ["id": "account-4", "label": "Shaped like a fallback", "windows": [] as [[String: Any]], "state": "ready"] as [String: Any],
                    ["id": "", "label": "", "windows": [] as [[String: Any]], "state": "ready"] as [String: Any],
                    ["id": "account-6", "label": "", "windows": [] as [[String: Any]], "state": "ready"] as [String: Any],
                    ["id": "account-6", "label": "Repeats its own fallback", "windows": [] as [[String: Any]], "state": "ready"] as [String: Any],
                ] as [[String: Any]]] as [String: Any],
                "limit": ["scope": "models", "models": ["gpt-x": "2026-10-22T05:00:00+00:00"]] as [String: Any],
            ] as [String: Any],
            ["slug": "nous", "name": "Nous", "limit": ["scope": "account"]] as [String: Any],
        ] as [[String: Any]]]

        let quotas = ProviderQuota.list(from: options)

        XCTAssertEqual(quotas.map(\.slug), ["anthropic", "openai-codex", "nous"])
        let anthropic = quotas[0]
        XCTAssertEqual(anthropic.title, "Anthropic")
        XCTAssertEqual(anthropic.windows.map(\.label), ["Session", "Opus weekly"])
        XCTAssertEqual(anthropic.windows[0].fraction, 0.425, accuracy: 0.0001)
        XCTAssertEqual(anthropic.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-10-22T03:00:00Z"))
        XCTAssertEqual(anthropic.windows[1].fraction, 1)
        XCTAssertTrue(anthropic.windows[1].modelScoped)
        XCTAssertNil(anthropic.windows[1].resetsAt)

        let codex = quotas[1]
        XCTAssertEqual(codex.title, "openai-codex")
        XCTAssertEqual(codex.accounts.map(\.id), ["a1", "account-1", "account-2", "account-4", "account-4-2", "account-6", "account-6-2"])
        XCTAssertEqual(codex.accounts.map(\.state), [.limited, .unknown, .ready, .ready, .ready, .ready, .ready])
        XCTAssertNotNil(codex.accounts[0].resetsAt)
        guard case .models(let limited) = codex.limit else { return XCTFail("expected a per-model limit") }
        XCTAssertEqual(limited.map(\.model), ["gpt-x"])

        XCTAssertEqual(quotas[2].limit, .account(resetsAt: nil))
    }
}
