//
//  ConduitPluginViews.swift
//  Conduit
//
//  The Conduit plugin on the dashboard's host: Settings > Conduit plugin
//  (version, what it powers, Update or Install), the update notice over the
//  main screen, and the update's confirmation and progress
//  (AppState+NotifierPluginUpdate.swift).
//

import SwiftUI
import UIKit

/// One-line status for the Settings home row.
enum NotifierPluginSummary {
    @MainActor
    static func detail(_ status: NotifierPluginStatus, update: NotifierPluginUpdateState) -> String {
        if update.isInProgress { return AppLocalization.string("Updating…") }
        switch status.state {
        case .unknown:
            return AppLocalization.string("Not checked yet")
        case .predatesCapabilities:
            if status.isNotServed { return AppLocalization.string("Installed but not running") }
            return AppLocalization.string("Not installed or out of date")
        case .reported:
            let version = status.runningVersion ?? status.version ?? "?"
            if status.updateAvailable { return AppLocalization.string("\(version) · Update available") }
            if status.restartPending { return AppLocalization.string("\(version) · Restart to finish updating") }
            return AppLocalization.string("\(version) · Up to date")
        }
    }
}

/// The features Conduit uses from the plugin, by capability id, and what
/// the user calls them.
enum NotifierPluginFeature: CaseIterable {
    case chatTakeover, savedCalls, liveVoiceContext, geminiLive, gptLive, grokLive
    case encryptedNotifications, pairing, hermesCalls, agentSettings, healthSync, updates

    /// Every capability id the feature needs.
    var capabilities: [String] {
        switch self {
        case .chatTakeover: return ["session-takeover", "desktop-views"]
        case .savedCalls: return ["voice-sessions", "voice-tags", "voice-summary"]
        case .liveVoiceContext: return ["memory", "personality", "web-search"]
        case .geminiLive: return ["gemini-live"]
        case .gptLive: return ["gpt-live"]
        case .grokLive: return ["grok-live"]
        case .encryptedNotifications: return ["e2e-notifications"]
        case .pairing: return ["pairing"]
        case .hermesCalls: return ["hermes-calls"]
        case .agentSettings: return ["conduit-settings"]
        case .healthSync: return ["health-sync"]
        case .updates: return [NotifierPluginUpdater.selfRestartCapability]
        }
    }

    @MainActor
    var title: String {
        switch self {
        case .chatTakeover: return AppLocalization.string("Taking chats over from Hermes Desktop")
        case .savedCalls: return AppLocalization.string("Saved voice calls")
        case .liveVoiceContext: return AppLocalization.string("Memory, personality and web search in live voice")
        case .geminiLive: return AppLocalization.string("Gemini Live")
        case .gptLive: return AppLocalization.string("GPT-Live")
        case .grokLive: return AppLocalization.string("Grok Live")
        case .encryptedNotifications: return AppLocalization.string("Encrypted notifications")
        case .pairing: return AppLocalization.string("Pairing from Conduit")
        case .hermesCalls: return AppLocalization.string("Calls from Hermes")
        case .agentSettings: return AppLocalization.string("Let Hermes change settings")
        case .healthSync: return AppLocalization.string("Health data")
        case .updates: return AppLocalization.string("Updates from Conduit")
        }
    }

    func isServed(by status: NotifierPluginStatus) -> Bool {
        capabilities.allSatisfy { status.reports($0) }
    }
}

/// Settings > Conduit plugin.
struct ConduitPluginSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var confirming = false
    @State private var showsCommands = false
    /// Starts true so the first render reads as checking, not as a failure.
    @State private var checking = true

    var body: some View {
        let status = appState.notifierPlugin
        let update = appState.activeNotifierPluginUpdate
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Conduit plugin"), symbol: "puzzlepiece.extension", tint: .conduitAura) {
                Text("The plugin on your Hermes host serves Conduit's notifications, live voice, calls from Hermes and more. Each dashboard's host has its own copy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if appState.savedDashboardRegistry.dashboards.count > 1, let label = appState.savedDashboardRegistry.activeDashboardLabel {
                    SettingsMetricRow(label: AppLocalization.string("Dashboard"), value: label, lineLimit: 1)
                }
                SettingsMetricRow(
                    label: AppLocalization.string("Version"),
                    value: status.runningVersion ?? "—",
                    valueColor: status.updateRecommended || status.restartPending ? .orange : .secondary
                )
                Text(verbatim: statusText(status))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if status.updateAvailable, let notes = NotifierPluginReleaseNotes(changelog: appState.notifierPluginChangelog, status: status) {
                    if let summary = notes.summary {
                        Text(verbatim: summary)
                            .font(.footnote)
                            .foregroundStyle(notes.hasSecurityFixes ? Color.orange : Color.secondary)
                    }
                    if !notes.changes.isEmpty {
                        DisclosureGroup {
                            NotifierPluginChangesList(changes: notes.changes)
                                .padding(.top, 8)
                        } label: {
                            Text(verbatim: AppLocalization.string("What's new in \(notes.version)"))
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("settings.plugin.whatsNew")
                    }
                }
                if showsAction(status, update: update) {
                    Button { confirming = true } label: {
                        Label(actionTitle(status), systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                    }
                    .disabled(!appState.canUpdateNotifierPlugin)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.16))
                    .accessibilityIdentifier("settings.plugin.update")
                    if let blocker = appState.notifierPluginUpdateBlocker {
                        Text(verbatim: blocker)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                NotifierPluginUpdateStatusView()
            }

            ConduitSettingsSection(title: AppLocalization.string("Update notices"), symbol: "bell.badge", tint: .conduitAccent) {
                ConduitMenuPicker(
                    value: appState.notifierPluginNoticeChannel,
                    choices: NotifierPluginNoticeChannel.allCases.map { (id: $0, title: Self.title(of: $0)) },
                    onSelect: { channel in
                        Haptics.selection()
                        appState.setNotifierPluginNoticeChannel(channel)
                    }
                ) {
                    Text("Ask to update for").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.plugin.notices")
                Text(verbatim: noticeChannelDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if case .reported = status.state {
                ConduitSettingsSection(title: AppLocalization.string("What it does here"), symbol: "checklist", tint: .conduitAccent) {
                    ForEach(NotifierPluginFeature.allCases, id: \.self) { feature in
                        let served = feature.isServed(by: status)
                        HStack(spacing: 10) {
                            Image(systemName: served ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(served ? Color.green : Color.secondary)
                                .accessibilityHidden(true)
                            Text(verbatim: feature.title)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(Text(served ? AppLocalization.string("Supported") : AppLocalization.string("Update needed")))
                    }
                }
            }

            ConduitSettingsSection(title: AppLocalization.string("Do it manually"), symbol: "terminal", tint: .conduitAura) {
                DisclosureGroup(isExpanded: $showsCommands) {
                    VStack(alignment: .leading, spacing: 12) {
                        if status.isNotServed {
                            NotificationSetupCommand(step: 1, title: AppLocalization.string("Turn on the notifier"), command: "hermes plugins enable conduit_push")
                        } else if status.offersInstall {
                            NotificationSetupCommand(step: 1, title: AppLocalization.string("Install the notifier"), command: "hermes plugins install \(NotifierPluginStatus.repository) --enable")
                        } else {
                            NotificationSetupCommand(step: 1, title: AppLocalization.string("Update the notifier"), command: "hermes plugins update conduit_push")
                        }
                        NotificationSetupCommand(step: 2, title: AppLocalization.string("Restart the gateway"), command: "hermes gateway restart")
                        Text("Then restart the Hermes dashboard, so it serves the new plugin.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Run these on the dashboard's host when Conduit can't update it, such as on an older Hermes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(Text(AppLocalization.string("Conduit plugin")))
        .notifierPluginUpdateConfirmation(isPresented: $confirming, install: isInstall(status))
        // The one-time manual update, and turning on an unserved copy: their
        // steps open by themselves.
        .onChange(of: status.needsManualUpdate(after: update) || status.isNotServed, initial: true) { _, needed in
            if needed { showsCommands = true }
        }
        // Asked again on every visit and dashboard switch.
        .task(id: appState.activeDashboardID) {
            checking = true
            await appState.refreshNotifierPluginStatus()
            if !Task.isCancelled { checking = false }
        }
    }

    private static func title(of channel: NotifierPluginNoticeChannel) -> String {
        switch channel {
        case .automatic: return AppLocalization.string("Automatic")
        case .everyVersion: return AppLocalization.string("Every new version")
        case .stableOnly: return AppLocalization.string("Stable versions only")
        }
    }

    private var noticeChannelDetail: String {
        let followsMain = appState.notifierPluginNoticeChannel.followsMain(installedFrom: appState.appInstallSource)
        let what = followsMain
            ? AppLocalization.string("Conduit asks you to update whenever a new plugin version is out.")
            : AppLocalization.string("Conduit asks you to update only when a plugin version is marked stable, or this app needs a newer one. You can still update here any time.")
        guard appState.notifierPluginNoticeChannel == .automatic else { return what }
        let source = switch appState.appInstallSource {
        case .appStore: AppLocalization.string("This copy of Conduit is from the App Store.")
        case .testFlight: AppLocalization.string("This copy of Conduit is from TestFlight.")
        case .xcode: AppLocalization.string("This copy of Conduit was built with Xcode.")
        }
        return "\(source) \(what)"
    }

    private func isInstall(_ status: NotifierPluginStatus) -> Bool {
        status.offersInstall
    }

    private func showsAction(_ status: NotifierPluginStatus, update: NotifierPluginUpdateState) -> Bool {
        guard !update.isInProgress else { return false }
        return status.updateAvailable || status.restartPending
    }

    private func actionTitle(_ status: NotifierPluginStatus) -> String {
        if isInstall(status) { return AppLocalization.string("Install or Update") }
        if status.restartPending && !status.updateAvailable { return AppLocalization.string("Finish Update") }
        return AppLocalization.string("Update to \(status.offeredVersion)")
    }

    private func statusText(_ status: NotifierPluginStatus) -> String {
        switch status.state {
        case .unknown:
            return checking
                ? AppLocalization.string("Checking this dashboard's notifier…")
                : appState.isConnected
                    ? AppLocalization.string("Couldn't reach this dashboard's notifier. Open this page again to retry.")
                    : AppLocalization.string("Connect to this dashboard to check its notifier.")
        case .predatesCapabilities:
            if status.isNotServed {
                return AppLocalization.string("Installed on this dashboard's host, but the dashboard doesn't run it. Turn it on in Hermes, then restart the gateway and the dashboard.")
            }
            return AppLocalization.string("Missing or out of date on this dashboard's host, so features like taking chats over from Hermes Desktop won't work.")
        case .reported:
            if status.updateAvailable { return AppLocalization.string("Version \(status.offeredVersion) is available.") }
            if status.restartPending { return AppLocalization.string("The new plugin is on the host. Hermes needs a restart to use it.") }
            return AppLocalization.string("Up to date on this dashboard's host")
        }
    }
}

extension View {
    /// Asks before the plugin update runs: Hermes restarts its gateway and
    /// dashboard, so chats reconnect.
    func notifierPluginUpdateConfirmation(isPresented: Binding<Bool>, install: Bool) -> some View {
        modifier(NotifierPluginUpdateConfirmation(isPresented: isPresented, install: install))
    }
}

private struct NotifierPluginUpdateConfirmation: ViewModifier {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool
    let install: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text(AppLocalization.string("Update the Conduit plugin?")),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Update and Restart Hermes")) { appState.updateNotifierPlugin(install: install) }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            if !install && appState.notifierPlugin.reports(NotifierPluginUpdater.selfUpdateCapability) {
                Text("Hermes updates the plugin on the host, then restarts its gateway and dashboard once running chats finish. You can close Conduit: you'll get a notification when it's done.")
            } else {
                Text("Hermes updates the plugin, then restarts its gateway and dashboard once running chats finish. Chats and messaging channels reconnect by themselves.")
            }
        }
    }
}

/// Where the plugin update stands. Shows nothing until one starts.
/// How far a running update is and how long it has run, so a long wait
/// (a restart, chats finishing) doesn't read as stuck.
struct NotifierPluginUpdateProgress: View {
    let step: NotifierPluginUpdateStep
    let startedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: Double(step.number), total: Double(NotifierPluginUpdateStep.count))
                .tint(Color.conduitAura)
                .accessibilityHidden(true)
            // Ticks every second: the elapsed time is the sign it's alive.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: Self.caption(step: step, elapsed: startedAt.map { context.date.timeIntervalSince($0) } ?? 0))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func caption(step: NotifierPluginUpdateStep, elapsed: TimeInterval) -> String {
        let time = Duration.seconds(max(0, elapsed.rounded(.down))).formatted(.time(pattern: .minuteSecond))
        // Ordinals, not counts: no plural rules apply.
        let current = String(step.number)
        let last = String(NotifierPluginUpdateStep.count)
        return AppLocalization.string("Step \(current) of \(last) · \(time)")
    }
}

struct NotifierPluginUpdateStatusView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let row = Self.row(for: appState.activeNotifierPluginUpdate, plugin: appState.notifierPlugin) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if let symbol = row.symbol {
                            Image(systemName: symbol).foregroundStyle(row.tint).accessibilityHidden(true)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: row.title)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            if case .updating(let step) = appState.activeNotifierPluginUpdate {
                                NotifierPluginUpdateProgress(step: step, startedAt: appState.notifierPluginUpdate.startedAt)
                            }
                            if let detail = row.detail, !detail.isEmpty {
                                Text(verbatim: detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    if row.symbol != nil {
                        Button { appState.dismissNotifierPluginUpdateOutcome() } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(AppLocalization.string("Dismiss")))
                    } else {
                        Button(AppLocalization.string("Cancel")) { appState.cancelNotifierPluginUpdate() }
                            .buttonStyle(.settings)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: appState.activeNotifierPluginUpdate) { previous, state in
            let before = Self.row(for: previous, plugin: appState.notifierPlugin)
            guard let row = Self.row(for: state, plugin: appState.notifierPlugin),
                  row.title != before?.title || row.detail != before?.detail else { return }
            AccessibilityNotification.Announcement(row.title).post()
        }
    }

    struct Row {
        var title: String
        var detail: String?
        /// Nil while the update is still going: a spinner shows instead.
        var symbol: String?
        var tint: Color = .secondary
    }

    /// `plugin` is the dashboard's plugin as last reported: an update that
    /// fails or can't run on a plugin older than one-tap updates gets the
    /// one-time manual step, not a bare error.
    @MainActor
    static func row(for state: NotifierPluginUpdateState, plugin: NotifierPluginStatus) -> Row? {
        switch state {
        case .failed(let detail) where plugin.predatesOneTapUpdate:
            return firstManualUpdateRow(plugin: plugin, hermesDetail: detail)
        case .unsupported where plugin.predatesOneTapUpdate:
            return firstManualUpdateRow(plugin: plugin, hermesDetail: nil)
        case .idle:
            return nil
        case .updating(let step):
            return Row(title: title(for: step))
        case .updated(let version):
            return Row(
                title: version.map { AppLocalization.string("Conduit plugin \($0) is ready") }
                    ?? AppLocalization.string("The Conduit plugin is up to date"),
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        case .needsDashboardRestart(let detail):
            return Row(
                title: AppLocalization.string("Restart the Hermes dashboard to finish"),
                detail: detail ?? AppLocalization.string("The new plugin is on the host, but this dashboard can't restart itself. Restart it on the host once."),
                symbol: "clock.badge.exclamationmark",
                tint: .orange
            )
        case .failed(let detail):
            return Row(
                title: AppLocalization.string("Couldn't update the Conduit plugin"),
                detail: detail,
                symbol: "exclamationmark.triangle.fill",
                tint: .red
            )
        case .runningOnHost:
            return Row(
                title: AppLocalization.string("Still updating on the host"),
                detail: AppLocalization.string("The update is still running on the host. You'll get a notification when it's done."),
                symbol: "clock",
                tint: .secondary
            )
        case .unsupported:
            return Row(
                title: AppLocalization.string("This Hermes can't update plugins from Conduit"),
                detail: AppLocalization.string("Update Hermes, or run the commands under Do it manually."),
                symbol: "exclamationmark.circle.fill",
                tint: .orange
            )
        }
    }

    @MainActor
    private static func firstManualUpdateRow(plugin: NotifierPluginStatus, hermesDetail: String?) -> Row {
        let why = plugin.version.map {
            AppLocalization.string("This dashboard's plugin (version \($0)) is older than one-tap updates. Run the steps under Do it manually on the host once. After that, Conduit updates it for you.")
        } ?? AppLocalization.string("This dashboard's plugin is missing or older than one-tap updates. Run the steps under Do it manually on the host once. After that, Conduit updates it for you.")
        let detail = hermesDetail.flatMap { $0.isEmpty ? nil : AppLocalization.string("Hermes said: \($0)") }
        return Row(
            title: AppLocalization.string("Update the plugin on the host this once"),
            detail: [why, detail].compactMap { $0 }.joined(separator: "\n\n"),
            symbol: "terminal",
            tint: .orange
        )
    }

    @MainActor
    private static func title(for step: NotifierPluginUpdateStep) -> String {
        switch step {
        case .downloading: return AppLocalization.string("Downloading the plugin…")
        case .installing: return AppLocalization.string("Installing the plugin…")
        case .restartingGateway(let stage):
            return stage == .draining
                ? AppLocalization.string("Letting running tasks finish…")
                : AppLocalization.string("Restarting the gateway…")
        case .waitingForChats(let count):
            return AppLocalization.string("Waiting for \(count) running chats to finish…")
        case .restartingDashboard: return AppLocalization.string("Restarting the dashboard…")
        }
    }
}

/// The update notice over the main screen: once per offered version, with
/// Update (after a confirmation) and Not now. While an update runs, it
/// shows its progress, then how it went.
struct NotifierPluginUpdateBanner: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var confirming = false
    @State private var showsNotes = false
    /// The notes as they were when What's New was tapped: an hourly
    /// changelog read can't empty the open sheet.
    @State private var shownNotes: NotifierPluginReleaseNotes?

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            if appState.showsNotifierPluginUpdateNotice {
                banner
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: appState.showsNotifierPluginUpdateNotice)
        .notifierPluginUpdateConfirmation(isPresented: $confirming, install: isInstall)
        .sheet(isPresented: $showsNotes) {
            if let shownNotes {
                NotifierPluginChangesSheet(notes: shownNotes)
            }
        }
    }

    private var notes: NotifierPluginReleaseNotes? {
        NotifierPluginReleaseNotes(changelog: appState.notifierPluginChangelog, status: appState.notifierPlugin)
    }

    private var isInstall: Bool { appState.notifierPlugin.offersInstall }

    private var banner: some View {
        let update = appState.activeNotifierPluginUpdate
        let status = appState.notifierPlugin
        let row = NotifierPluginUpdateStatusView.row(for: update, plugin: status)
        let offer = appState.notifierPluginNoticeOffer
        // Updated on the host already: only the restart is left.
        let restartOnly = offer == .restart
        let offerText = switch offer {
        case .restart: AppLocalization.string("\(AppLocalization.string("Conduit plugin")) · Restart to finish updating")
        // Out of date too, when the host couldn't list its plugins.
        case .install: status.hostCopy == .missing
            ? AppLocalization.string("\(AppLocalization.string("Conduit plugin")) · Not installed")
            : AppLocalization.string("\(AppLocalization.string("Conduit plugin")) · Not installed or out of date")
        case .update, .none: AppLocalization.string("Conduit plugin \(status.offeredVersion) is available")
        }
        let text = row?.title ?? offerText
        return HStack(spacing: 10) {
            if row != nil, row?.symbol == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: row?.symbol ?? "puzzlepiece.extension")
                    .foregroundStyle(row?.tint ?? Color.conduitAura)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: text)
                    .font(.subheadline)
                    .lineLimit(2)
                // When it came out and what's in it (#297, #300).
                if update == .idle, offer == .update, let notes {
                    let line = [notes.summary, notes.changes.isEmpty ? nil : AppLocalization.string("What's New")]
                        .compactMap { $0 }.joined(separator: " · ")
                    if notes.changes.isEmpty, !line.isEmpty {
                        Text(verbatim: line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if !line.isEmpty {
                        Button {
                            shownNotes = notes
                            showsNotes = true
                        } label: {
                            Text(verbatim: line)
                                .font(.footnote)
                                .foregroundStyle(notes.hasSecurityFixes ? Color.orange : Color.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pluginUpdate.whatsNew")
                    }
                }
                if case .updating(let step) = update {
                    NotifierPluginUpdateProgress(step: step, startedAt: appState.notifierPluginUpdate.startedAt)
                }
                if update == .runningOnHost, let detail = row?.detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status.needsManualUpdate(after: update) {
                Button { appState.settingsLinkRequest = .plugin } label: {
                    Text(AppLocalization.string("Show Steps"))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("pluginUpdate.showSteps")
            }
            if update == .idle {
                Button { confirming = true } label: {
                    Text(restartOnly ? AppLocalization.string("Finish Update")
                        : offer == .install ? AppLocalization.string("Install") : AppLocalization.string("Update"))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                    .font(.subheadline.weight(.semibold))
                    .disabled(!appState.canUpdateNotifierPlugin)
                    .accessibilityIdentifier("pluginUpdate.update")
            }
            // While it runs, the same button stops following it.
            Button {
                if update.isInProgress {
                    appState.cancelNotifierPluginUpdate()
                } else {
                    appState.dismissNotifierPluginUpdateNotice()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(update.isInProgress ? AppLocalization.string("Cancel")
                : update == .idle ? AppLocalization.string("Not now") : AppLocalization.string("Dismiss")))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .conduitGlassSurface(cornerRadius: 18, tint: .conduitAura.opacity(0.08))
        // The notice and how it ended are announced; each step isn't.
        .task(id: update.isInProgress ? nil : text) {
            guard !update.isInProgress else { return }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
        // A finished update leaves on its own; with VoiceOver on it stays
        // until closed.
        .task(id: update) {
            guard case .updated = update, !UIAccessibility.isVoiceOverRunning else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled, appState.activeNotifierPluginUpdate == update { appState.dismissNotifierPluginUpdateOutcome() }
        }
    }
}

extension NotifierPluginStatus {
    /// The update ended in the one-time manual update: it failed or couldn't
    /// run on a plugin older than one-tap updates.
    func needsManualUpdate(after update: NotifierPluginUpdateState) -> Bool {
        switch update {
        case .failed, .unsupported: return predatesOneTapUpdate
        default: return false
        }
    }
}

/// What an update brings, from the plugin's changelog
/// (NotifierPluginChangelog): security fixes first, then fixes, then new
/// things, each with its version.
struct NotifierPluginChangesList: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let changes: [NotifierPluginChangelog.Change]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(NotifierPluginChangelog.Kind.allCases, id: \.self) { kind in
                let items = changes.filter { $0.kind == kind }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(Self.title(of: kind), systemImage: Self.symbol(of: kind))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(kind == .security ? Color.orange : Color.primary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(items) { change in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(verbatim: change.version)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(verbatim: change.text)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func title(of kind: NotifierPluginChangelog.Kind) -> String {
        switch kind {
        case .security: return AppLocalization.string("Security fixes")
        case .fixes: return AppLocalization.string("Fixes")
        case .new: return AppLocalization.string("New and improved")
        }
    }

    private static func symbol(of kind: NotifierPluginChangelog.Kind) -> String {
        switch kind {
        case .security: return "lock.shield"
        case .fixes: return "wrench.and.screwdriver"
        case .new: return "sparkles"
        }
    }
}

/// What the update to the offered version brings, and when that version
/// came out, for the notice and Settings > Conduit plugin.
struct NotifierPluginReleaseNotes: Equatable {
    var version: String
    var released: Date?
    var changes: [NotifierPluginChangelog.Change]

    var hasSecurityFixes: Bool { changes.contains { $0.kind == .security } }

    /// Nil when the changelog isn't read yet or names neither the date nor a change.
    init?(changelog: NotifierPluginChangelog?, status: NotifierPluginStatus) {
        guard let changelog else { return nil }
        version = status.offeredVersion
        released = changelog.released(version)
        // A host whose version isn't known gets what this build's floor
        // brought on, not the whole history.
        changes = changelog.updateChanges(after: status.runningVersion ?? status.version ?? NotifierPluginStatus.recommendedVersion,
                                          through: version)
        if released == nil && changes.isEmpty { return nil }
    }

    /// "Released Oct 22, 2026", plus whether security fixes are in it.
    @MainActor
    var summary: String? {
        var parts: [String] = []
        if let released {
            let day = released.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                                                          locale: AppLocalization.formattingLocale,
                                                          timeZone: TimeZone(identifier: "UTC") ?? .current))
            parts.append(AppLocalization.string("Released \(day)"))
        }
        if hasSecurityFixes { parts.append(AppLocalization.string("Includes security fixes")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The notes in full, from the notice's What's New.
struct NotifierPluginChangesSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss
    let notes: NotifierPluginReleaseNotes

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary = notes.summary {
                        Text(verbatim: summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    NotifierPluginChangesList(changes: notes.changes)
                }
                .padding(16)
            }
            .navigationTitle(Text(verbatim: AppLocalization.string("What's new in \(notes.version)")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
