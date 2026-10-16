//
//  AgentSettingsViews.swift
//  Conduit
//
//  What the user sees of Hermes changing Conduit settings
//  (AgentSettings.swift): a banner over the chat when Hermes asked for a
//  change or just made a small one, the sheet where the user approves or
//  dismisses each change, and the "Let Hermes change settings" choice in
//  Voice settings.
//

import SwiftUI
import UIKit

/// The banner over the main screen and the review sheet it opens.
struct AgentSettingsBanner: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var sync: AgentSettingsSync
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @State private var reviewing = false
    /// Review requests whose banner the user closed; a new request brings
    /// it back. They stay waiting, reachable from Voice settings.
    @State private var hiddenReviewIDs: Set<String> = []

    var body: some View {
        let review = appState.agentSettingsReview
        let visible = review.filter { !hiddenReviewIDs.contains($0.id) }
        // Nothing to show: a zero-size overlay, so it never takes a touch.
        // The sheet hangs off this stable view, so it closes normally when
        // the last banner goes.
        ZStack(alignment: .top) {
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            if sync.applied != nil || !visible.isEmpty {
                banners(review: review, visible: visible)
            }
        }
        .sheet(isPresented: $reviewing) {
            AgentSettingsReviewSheet(sync: sync)
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
        }
    }

    private func banners(review: [AgentSettingsReviewItem], visible: [AgentSettingsReviewItem]) -> some View {
        VStack(spacing: 8) {
            if let notice = sync.applied {
                bannerRow(
                    symbol: "slider.horizontal.3",
                    text: notice.message,
                    action: AppLocalization.string("Undo"),
                    identifier: "agentSettings.undo",
                    perform: { appState.undoAgentSettings(notice) },
                    close: { sync.applied = nil }
                )
                .task(id: notice.id) {
                    UIAccessibility.post(notification: .announcement, argument: notice.message)
                    // With VoiceOver on, the Undo stays until closed.
                    guard !UIAccessibility.isVoiceOverRunning else { return }
                    try? await Task.sleep(for: .seconds(10))
                    if sync.applied == notice { sync.applied = nil }
                }
            }
            if let first = visible.first {
                let text = visible.count == 1
                    ? AppLocalization.string("Hermes wants to change \(first.title)")
                    : AppLocalization.string("Hermes wants to change \(visible.count) settings")
                bannerRow(
                    symbol: "checkmark.shield",
                    text: text,
                    action: AppLocalization.string("Review"),
                    identifier: "agentSettings.review",
                    perform: { reviewing = true },
                    close: { hiddenReviewIDs.formUnion(review.map(\.id)) }
                )
                .task(id: visible.map(\.id)) {
                    UIAccessibility.post(notification: .announcement, argument: text)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(.snappy, value: review.map(\.id))
        .animation(.snappy, value: sync.applied?.id)
    }

    private func bannerRow(
        symbol: String, text: String, action: String, identifier: String,
        perform: @escaping () -> Void, close: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.conduitAura)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform)
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier(identifier)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text(AppLocalization.string("Close")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.08))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Each change Hermes asked for, with its reason, to apply or dismiss.
struct AgentSettingsReviewSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sync: AgentSettingsSync
    @ObservedObject var appLanguage = AppLanguageStore.shared

    var body: some View {
        let items = appState.agentSettingsReview
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Hermes asked to change these settings. Nothing changes until you apply it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(items) { item in
                        row(item)
                    }
                }
                .padding(16)
            }
            .navigationTitle(Text(AppLocalization.string("Changes from Hermes")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Dismiss All")) {
                        appState.resolveAgentSettings(items, apply: false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Apply All")) {
                        appState.resolveAgentSettings(items, apply: true)
                        dismiss()
                    }
                    .accessibilityIdentifier("agentSettings.applyAll")
                }
            }
            .onChange(of: items.isEmpty) { _, empty in
                if empty { dismiss() }
            }
        }
    }

    private func row(_ item: AgentSettingsReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: item.title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                Text(verbatim: item.oldValue)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: item.newValue)
                    .fontWeight(.medium)
            }
            .font(.subheadline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: AppLocalization.string("From \(item.oldValue) to \(item.newValue)")))
            if !item.request.reason.isEmpty {
                // The reason is Hermes' own words: shown as a quote, never
                // as Conduit's.
                Text(verbatim: "“\(item.request.reason)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(AppLocalization.string("Apply")) {
                    appState.resolveAgentSettings([item], apply: true)
                }
                .buttonStyle(.settingsPrimary)
                Button(AppLocalization.string("Dismiss")) {
                    appState.resolveAgentSettings([item], apply: false)
                }
                .buttonStyle(.settings)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.06))
    }
}

/// "Let Hermes change settings" in Voice settings, on this device.
struct AgentSettingsModeSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @State private var reviewing = false
    @AppStorage(AgentSettingsMode.storageKey) private var storedMode = AgentSettingsMode.defaultMode.rawValue
    /// Shares the new mode with Hermes.
    var onChange: () -> Void = {}

    private var mode: AgentSettingsMode { AgentSettingsMode(rawValue: storedMode) ?? AgentSettingsMode.defaultMode }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Hermes and your settings"), symbol: "slider.horizontal.3", tint: .conduitAura) {
            ConduitMenuPicker(
                value: mode,
                choices: AgentSettingsMode.allCases.map { (id: $0, title: $0.title) },
                onSelect: { picked in
                    storedMode = picked.rawValue
                    onChange()
                }
            ) {
                Text("Let Hermes change settings").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("voice.agentSettingsMode")
            if !appState.agentSettingsReview.isEmpty {
                // Requests whose banner was closed are still here.
                Button(AppLocalization.string("Review changes from Hermes")) { reviewing = true }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("voice.agentSettingsReview")
            }
            Text(verbatim: mode.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Hermes never sees your keys, wake phrase, call permissions or Apple Watch access, and can't change this choice.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $reviewing) {
            AgentSettingsReviewSheet(sync: appState.agentSettings)
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
        }
    }
}
