//
//  UsageSettingsViews.swift
//  Conduit
//
//  Settings > Usage (#813): the profile's tokens and cost over 7, 30 or 90
//  days, a bar per day, a row per model, and each provider's quota. Read
//  only, from what Hermes already keeps (UsageReport.swift); refreshed by
//  hand, never polled. Opens on the numbers it showed last, kept on the
//  phone, while Hermes is asked again (#1533).
//

import Charts
import SwiftUI

struct UsageSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var days = 30
    @State private var report: UsageReport?
    @State private var quotas: [ProviderQuota]?
    @State private var failure: UsageLoadError?
    @State private var isLoading = false
    /// Bumped by the Refresh button, which reruns the page's load task.
    @State private var refreshes = 0
    /// What `report` and `quotas` were loaded for: another period, profile
    /// or dashboard's numbers never stay up under this one. Offline, the
    /// numbers stay, saying to connect to update them.
    @State private var scope: Scope?
    /// The newest load. The page's task and a pull-down can overlap; only
    /// the newest one writes its answer.
    @State private var generation = 0

    private static let dayName = "Day"
    private static let tokensName = "Tokens"

    private struct Scope: Equatable {
        let days: Int
        let profile: String
        let dashboardID: UUID?
    }

    private struct LoadKey: Equatable {
        let days: Int
        let profile: String
        let dashboardID: UUID?
        /// Connecting again asks again.
        let connected: Bool
        let refreshes: Int
    }

    private var shownScope: Scope {
        Scope(days: days, profile: appState.activeProfile, dashboardID: appState.activeDashboardID)
    }

    var body: some View {
        SettingsDetailContainer {
            Picker(AppLocalization.string("Period"), selection: $days) {
                ForEach(UsageReport.periods, id: \.self) { period in
                    Text(periodLabel(period)).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.usage.period")

            if report != nil, let failure {
                // A failed refresh says so over the numbers it couldn't renew,
                // the kept ones too.
                let text = failure == .notConnected
                    ? AppLocalization.string("Connect to Hermes to update these numbers.") : failureText(failure)
                Label(text, systemImage: "exclamationmark.triangle")
                    .scaledFont(.footnote)
                    .foregroundStyle(.orange)
            }

            if let report {
                totalsSection(report)
                if report.daily.contains(where: { $0.usage.total > 0 }) {
                    dailySection(report)
                }
                if !report.models.isEmpty {
                    modelsSection(report)
                }
            } else if let failure {
                ConduitSettingsSection(title: AppLocalization.string("Usage"), symbol: "chart.bar", tint: .conduitAccent) {
                    Text(failureText(failure))
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }

            if let quotas {
                quotaSection(quotas)
            }
        }
        .navigationTitle(AppLocalization.string("Usage"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.selection()
                    refreshes += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel(AppLocalization.string("Refresh"))
                .accessibilityIdentifier("settings.usage.refresh")
            }
        }
        .refreshable { await load() }
        // The numbers it showed last, before the first frame; Hermes'
        // answer follows.
        .onAppear(perform: showKept)
        .task(id: LoadKey(
            days: days,
            profile: appState.activeProfile,
            dashboardID: appState.activeDashboardID,
            connected: appState.isConnected,
            refreshes: refreshes
        )) {
            await load()
        }
    }

    /// Another period, profile or dashboard: its own numbers as the page
    /// last showed them, or the loader when none are kept.
    private func showKept() {
        let wanted = shownScope
        guard scope != wanted else { return }
        report = appState.keptUsageReport(days: wanted.days)
        quotas = appState.keptProviderQuotas()
        failure = nil
        scope = wanted
    }

    private func load() async {
        generation += 1
        let mine = generation
        let wanted = shownScope
        isLoading = true
        defer {
            if generation == mine { isLoading = false }
        }
        showKept()
        let result: Result<UsageReport, UsageLoadError>
        do {
            let loaded = try await appState.loadUsageReport(days: wanted.days)
            result = .success(loaded)
        } catch is CancellationError {
            return
        } catch {
            result = .failure(error as? UsageLoadError ?? .failed)
        }
        guard generation == mine, !Task.isCancelled else { return }
        switch result {
        case .success(let loaded):
            report = loaded
            failure = nil
        case .failure(let error):
            failure = error
        }
        // The report is in: Refresh works again while the quota comes.
        isLoading = false
        // Offline, the kept quota stays under the line saying to connect.
        if case .failure(.notConnected) = result { return }
        let loadedQuotas = await appState.loadProviderQuotas()
        guard generation == mine, !Task.isCancelled else { return }
        // A quota that couldn't be read goes rather than stay up as current.
        quotas = loadedQuotas
    }

    // MARK: Totals

    private func totalsSection(_ report: UsageReport) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Totals"), symbol: "sum", tint: .conduitAccent) {
            if report.totals.sessions == 0 && report.totals.total == 0 {
                Text("No usage in this period.")
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                SettingsMetricRow(
                    label: report.costIsEstimate ? AppLocalization.string("Estimated cost") : AppLocalization.string("Cost"),
                    value: money(report.cost)
                )
                SettingsMetricRow(label: AppLocalization.string("Input"), value: tokens(report.totals.input))
                SettingsMetricRow(label: AppLocalization.string("Output"), value: tokens(report.totals.output))
                if report.totals.cacheRead > 0 {
                    SettingsMetricRow(label: AppLocalization.string("Cache reads"), value: tokens(report.totals.cacheRead))
                }
                if report.totals.reasoning > 0 {
                    SettingsMetricRow(label: AppLocalization.string("Reasoning"), value: tokens(report.totals.reasoning))
                }
                SettingsMetricRow(label: AppLocalization.string("Chats"), value: count(report.totals.sessions))
                SettingsMetricRow(label: AppLocalization.string("API calls"), value: count(report.totals.apiCalls))
                if report.costIsEstimate {
                    Text("Costs are Hermes' estimates from each model's prices, unless the provider reports what it billed.")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Per day

    private func dailySection(_ report: UsageReport) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Tokens per day"), symbol: "chart.bar", tint: .conduitAura) {
            Chart(report.daily) { day in
                BarMark(
                    x: .value(Self.dayName, day.date, unit: .day),
                    y: .value(Self.tokensName, day.usage.total)
                )
                .foregroundStyle(Color.conduitAccent)
                .cornerRadius(3)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Int.self) {
                            Text(verbatim: tokens(amount))
                        }
                    }
                }
            }
            .environment(\.locale, AppLocalization.formattingLocale)
            .frame(height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppLocalization.string("Tokens per day"))
            .accessibilityValue(dailySummary(report))
        }
    }

    /// The chart for VoiceOver: the busiest day and the period's total.
    private func dailySummary(_ report: UsageReport) -> String {
        guard let busiest = report.daily.max(by: { $0.usage.total < $1.usage.total }) else { return "" }
        let day = busiest.date.formatted(.dateTime.month().day().locale(AppLocalization.formattingLocale))
        let amount = tokens(busiest.usage.total)
        return AppLocalization.string("Busiest day \(day), \(amount) tokens")
    }

    // MARK: By model

    private func modelsSection(_ report: UsageReport) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("By model"), symbol: "cpu", tint: .conduitAccent) {
            ForEach(report.models) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: entry.model)
                            .scaledFont(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(modelDetail(entry))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if entry.usage.cost > 0 {
                        Text(verbatim: money(entry.usage.cost))
                            .scaledFont(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func modelDetail(_ entry: ModelUsage) -> String {
        let flow = AppLocalization.string("\(tokens(entry.usage.input)) in · \(tokens(entry.usage.output)) out")
        return entry.provider.isEmpty ? flow : "\(entry.provider) · \(flow)"
    }

    // MARK: Quota

    private func quotaSection(_ quotas: [ProviderQuota]) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Provider quota"), symbol: "gauge.with.dots.needle.50percent", tint: .conduitAura) {
            ForEach(quotas) { quota in
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: quota.title)
                        .scaledFont(.subheadline.weight(.semibold))
                    if let limit = quota.limit {
                        limitView(limit)
                    }
                    ForEach(quota.windows) { window in
                        windowView(window)
                    }
                    ForEach(Array(quota.accounts.enumerated()), id: \.element.id) { index, account in
                        accountView(account, number: index + 1)
                    }
                }
            }
            Text("Shown for providers that report a quota, such as subscription sign-ins. Hermes checks it in the background, so refresh if one is missing.")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func windowView(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: window.label)
                    .scaledFont(.footnote)
                Spacer(minLength: 8)
                Text(AppLocalization.string("\(percent(window.usedPercent / 100)) used"))
                    .scaledFont(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: window.fraction)
                .tint(window.fraction >= 1 ? .red : (window.fraction >= 0.8 ? .orange : .conduitAccent))
            if let resetsAt = window.resetsAt {
                Text(AppLocalization.string("Resets \(relative(resetsAt))"))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func accountView(_ account: QuotaAccount, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: account.label.isEmpty ? AppLocalization.string("Account \(String(number))") : account.label)
                    .scaledFont(.footnote.weight(.medium))
                Spacer(minLength: 8)
                if let state = accountState(account) {
                    Text(state)
                        .scaledFont(.caption)
                        .foregroundStyle(account.state == .limited ? Color.orange : Color.secondary)
                }
            }
            ForEach(account.windows) { window in
                windowView(window)
            }
        }
        .padding(.leading, 8)
    }

    private func accountState(_ account: QuotaAccount) -> String? {
        switch account.state {
        case .ready:
            return nil
        case .limited:
            guard let resetsAt = account.resetsAt else { return AppLocalization.string("Limited") }
            return AppLocalization.string("Limited until \(absolute(resetsAt))")
        case .unknown:
            return account.windows.isEmpty ? AppLocalization.string("Not reported yet") : nil
        case .unavailable:
            return AppLocalization.string("Signed out")
        }
    }

    @ViewBuilder
    private func limitView(_ limit: ProviderRateLimit) -> some View {
        switch limit {
        case .account(let resetsAt):
            Label(
                resetsAt.map { AppLocalization.string("Rate limited until \(absolute($0))") } ?? AppLocalization.string("Rate limited"),
                systemImage: "exclamationmark.triangle"
            )
            .scaledFont(.footnote)
            .foregroundStyle(.orange)
        case .models(let models):
            ForEach(models) { model in
                Label(
                    model.resetsAt.map { AppLocalization.string("\(model.model) limited until \(absolute($0))") }
                        ?? AppLocalization.string("\(model.model) limited"),
                    systemImage: "exclamationmark.triangle"
                )
                .scaledFont(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Text

    private func periodLabel(_ days: Int) -> String {
        switch days {
        case 7: return AppLocalization.string("7 days")
        case 90: return AppLocalization.string("90 days")
        default: return AppLocalization.string("30 days")
        }
    }

    private func failureText(_ failure: UsageLoadError) -> String {
        switch failure {
        case .notConnected: return AppLocalization.string("Connect to Hermes to see usage.")
        case .unsupported: return AppLocalization.string("This Hermes doesn't report usage. Update Hermes to see it here.")
        case .signInRequired: return AppLocalization.string("Sign in to this dashboard again to see usage.")
        case .failed: return AppLocalization.string("Couldn't load usage. Pull down to try again.")
        }
    }

    private func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(AppLocalization.formattingLocale))
    }

    private func count(_ value: Int) -> String {
        value.formatted(.number.locale(AppLocalization.formattingLocale))
    }

    /// Hermes keeps cost in USD (`estimated_cost_usd`, `actual_cost_usd`).
    private func money(_ value: Double) -> String {
        // Cents hide most of a light month's spend; small sums keep more.
        let digits = value > 0 && value < 1 ? 2...4 : 2...2
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)).locale(AppLocalization.formattingLocale))
    }

    private func percent(_ fraction: Double) -> String {
        // A window barely touched reads 0.4%, not 0%.
        let digits = fraction > 0 && fraction < 0.1 ? 0...1 : 0...0
        return fraction.formatted(.percent.precision(.fractionLength(digits)).locale(AppLocalization.formattingLocale))
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named).locale(AppLocalization.formattingLocale))
    }

    private func absolute(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(AppLocalization.formattingLocale))
    }
}
