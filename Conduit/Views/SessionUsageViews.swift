//
//  SessionUsageViews.swift
//  Conduit
//
//  One chat's tokens and cost (issue 2699): the Usage card the Context
//  sheet shows for the open chat, and Usage Details, the same card for a
//  chat picked from a list's long-press menu.
//

import SwiftUI

/// The Usage card: what Hermes recorded for the chat, its compressions and
/// subagent runs included. A number Hermes didn't report says so rather
/// than showing 0 or $0.00.
struct SessionUsageSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// Nil while it loads.
    let readout: SessionUsageReadout?

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Usage", table: .settings), symbol: "dollarsign.circle", tint: .conduitAccent) {
            switch readout {
            case nil:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            case .loaded(let usage):
                SettingsMetricRow(label: AppLocalization.string("Input"), value: tokens(usage.input))
                SettingsMetricRow(label: AppLocalization.string("Output"), value: tokens(usage.output))
                if usage.cacheRead > 0 {
                    SettingsMetricRow(label: AppLocalization.string("Cache reads", table: .settings), value: tokens(usage.cacheRead))
                }
                SettingsMetricRow(
                    label: usage.costStatus == .estimated
                        ? AppLocalization.string("Estimated cost", table: .settings)
                        : AppLocalization.string("Cost", table: .settings),
                    value: cost(usage)
                )
                SettingsMetricRow(label: AppLocalization.string("API calls", table: .settings), value: count(usage.apiCalls))
                if usage.compressions > 0 || usage.subagentRuns > 0 {
                    caption(AppLocalization.string("Includes the chat's compressions and the agents it started."))
                }
            case .nothingYet:
                caption(AppLocalization.string("Nothing has run in this chat yet."))
            case .needsPluginUpdate:
                caption(AppLocalization.string("Update the Conduit plugin on this host to see this chat's tokens and cost."))
            case .failed:
                caption(AppLocalization.string("Couldn't load this chat's usage."))
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func cost(_ usage: SessionUsage) -> String {
        switch usage.costStatus {
        case .unknown:
            return AppLocalization.string("Not reported by this host")
        case .included:
            return AppLocalization.string("Included in your plan")
        case .partial:
            let amount = Self.money(usage.costUSD ?? 0)
            return AppLocalization.string("At least \(amount)")
        case .actual, .estimated:
            return usage.costUSD.map(Self.money) ?? AppLocalization.string("Not reported by this host")
        }
    }

    private func tokens(_ value: Int) -> String {
        value.formatted(.number.locale(AppLocalization.formattingLocale))
    }

    private func count(_ value: Int) -> String {
        value.formatted(.number.locale(AppLocalization.formattingLocale))
    }

    /// Hermes keeps cost in USD; small sums keep more digits, as Settings >
    /// Usage shows them.
    static func money(_ value: Double) -> String {
        let digits = value > 0 && value < 1 ? 2...4 : 2...2
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)).locale(AppLocalization.formattingLocale))
    }
}

/// Usage Details: a listed chat's Usage card, from its long-press menu.
struct SessionUsageSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject var appState: AppState
    let session: SessionSummary
    @State private var readout: SessionUsageReadout?

    var body: some View {
        NavigationStack {
            SettingsDetailContainer(compact: true) {
                SessionUsageSection(readout: readout)
                if case .loaded(let usage) = readout, !usage.model.isEmpty {
                    ConduitSettingsSection(title: session.title, symbol: "bubble.left", tint: .conduitAura) {
                        SettingsMetricRow(label: AppLocalization.string("Model"), value: usage.model, lineLimit: 1)
                    }
                }
            }
            .navigationTitle(Text("Usage Details"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(id: session.id) {
            readout = nil
            readout = await appState.loadSessionUsage(for: session) ?? .failed
        }
    }
}
