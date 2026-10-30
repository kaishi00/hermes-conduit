//
//  V2FinishSetupCard.swift
//  Conduit
//
//  Finish setting up, at the top of Chats after the first connection to a
//  dashboard (AppState+FinishSetup.swift): the Conduit plugin, notifications
//  and voice, each with the one button that gets it done. A done step keeps
//  its row with a check until the last one is done.
//

import SwiftUI
import UIKit

struct V2FinishSetupCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject private var notifications = PushNotificationService.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var status: FinishSetupStatus {
        FinishSetupStatus(
            plugin: FinishSetupStatus.plugin(appState.notifierPlugin, updating: appState.activeNotifierPluginUpdate.isInProgress),
            notifications: FinishSetupStatus.notifications(
                enabled: notifications.isEnabled,
                authorization: notifications.authorizationStatus
            ),
            voiceReady: appState.canStartPhoneVoiceConversation
        )
    }

    var body: some View {
        let status = status
        VStack(alignment: .leading, spacing: 6) {
            header
            VStack(spacing: 0) {
                pluginRow(status.plugin)
                notificationsRow(status.notifications)
                    .overlay(alignment: .top) { V2RowDivider(leadingInset: 56) }
                voiceRow(ready: status.voiceReady)
                    .overlay(alignment: .top) { V2RowDivider(leadingInset: 56) }
            }
            .settingsCard()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("finish-setup.card")
        .onChange(of: status.isComplete, initial: true) { _, complete in
            guard complete else { return }
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { appState.endFinishSetup() }
        }
        .task { await notifications.refresh() }
        // Back from iPhone Settings: notifications may be allowed now.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await notifications.refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .scaledFont(.caption.weight(.bold))
                .conduitFixedGlyph()
                .foregroundStyle(Color.conduitAccent)
                .accessibilityHidden(true)
            Text("Finish setting up")
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button {
                Haptics.selection()
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { appState.endFinishSetup() }
            } label: {
                Text("Not now")
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("finish-setup.not-now")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
    }

    // MARK: - Rows

    @ViewBuilder
    private func pluginRow(_ plugin: FinishSetupStatus.Plugin) -> some View {
        let title = AppLocalization.string("Conduit plugin")
        let icon = "puzzlepiece.extension"
        switch plugin {
        case .unknown:
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Needed for notifications and calls from Hermes"), identifier: "finish-setup.plugin") {
                actionButton(AppLocalization.string("Check"), action: openPluginPage)
            }
        case .updating:
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Updating…"), identifier: "finish-setup.plugin") {
                // The detail already says it.
                ProgressView()
                    .accessibilityHidden(true)
            }
        case .install:
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Needed for notifications and calls from Hermes"), identifier: "finish-setup.plugin") {
                actionButton(AppLocalization.string("Install"), action: openPluginPage)
            }
        case .update:
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Version \(appState.notifierPlugin.offeredVersion) is available."), identifier: "finish-setup.plugin") {
                actionButton(AppLocalization.string("Update"), action: openPluginPage)
            }
        case .restart:
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("The new plugin is on the host. Hermes needs a restart to use it."), identifier: "finish-setup.plugin") {
                actionButton(AppLocalization.string("Finish Update"), action: openPluginPage)
            }
        case .notRunning:
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Installed but not running"), identifier: "finish-setup.plugin") {
                actionButton(AppLocalization.string("Show Steps"), action: openPluginPage)
            }
        case .done:
            FinishSetupRow(icon: icon, title: title, detail: pluginDoneDetail, identifier: "finish-setup.plugin") {
                doneMark
            }
        }
    }

    private var pluginDoneDetail: String {
        switch FinishSetupStatus.pluginDoneNote(appState.notifierPlugin) {
        case .upToDate: return AppLocalization.string("Up to date on this dashboard's host")
        case .newerVersionWaits: return AppLocalization.string("Works with this app. Newer versions wait in Settings.")
        case .featuresWait: return AppLocalization.string("Works with this app. Some features need the newer version in Settings.")
        }
    }

    @ViewBuilder
    private func notificationsRow(_ state: FinishSetupStatus.Notifications) -> some View {
        let title = AppLocalization.string("Notifications")
        let icon = "bell.badge"
        switch state {
        case .off:
            if notifications.isWorking {
                FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Turning on…"), identifier: "finish-setup.notifications") {
                    ProgressView()
                        .accessibilityHidden(true)
                }
            } else {
                FinishSetupRow(
                    icon: icon,
                    title: title,
                    detail: notifications.lastError ?? AppLocalization.string("Hear back when Hermes replies"),
                    detailIsWarning: notifications.lastError != nil,
                    identifier: "finish-setup.notifications"
                ) {
                    actionButton(AppLocalization.string("Turn on")) {
                        Task { await appState.turnOnNotificationsFromSetup() }
                    }
                    .disabled(notifications.isPairing)
                }
            }
        case .denied:
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Notifications are off for Conduit in iPhone Settings."), identifier: "finish-setup.notifications") {
                actionButton(AppLocalization.string("Open Settings")) {
                    guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        case .done:
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("On"), identifier: "finish-setup.notifications") {
                doneMark
            }
        }
    }

    @ViewBuilder
    private func voiceRow(ready: Bool) -> some View {
        let title = AppLocalization.string("Voice")
        let icon = "waveform"
        if ready {
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Ready"), identifier: "finish-setup.voice") {
                doneMark
            }
        } else {
            FinishSetupRow(icon: icon, title: title, detail: AppLocalization.string("Talk to Hermes hands-free"), identifier: "finish-setup.voice") {
                actionButton(AppLocalization.string("Set up")) {
                    appState.settingsLinkRequest = .voice
                }
            }
        }
    }

    // MARK: - Pieces

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(verbatim: title)
        }
        .buttonStyle(FinishSetupActionStyle())
    }

    private var doneMark: some View {
        Image(systemName: "checkmark.circle.fill")
            .scaledFont(.title3)
            .conduitFixedGlyph()
            .foregroundStyle(Color.green)
            .accessibilityLabel(AppLocalization.string("Done"))
    }

    /// The plugin's own page installs, updates or finishes it, and has the
    /// manual steps when Conduit can't.
    private func openPluginPage() {
        appState.settingsLinkRequest = .plugin
    }
}

/// One step: a gold icon, what it is and where it stands, and its button
/// or check. At the largest text sizes the button goes under the text.
private struct FinishSetupRow<Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let title: String
    let detail: String
    var detailIsWarning = false
    let identifier: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .scaledFont(.body.weight(.medium))
                .conduitFixedGlyph()
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 26)
                .accessibilityHidden(true)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    text
                    trailing()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                text
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .frame(minHeight: 64)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: title)
                .scaledFont(.callout.weight(.semibold))
                .foregroundStyle(.primary)
            Text(verbatim: detail)
                .scaledFont(.footnote)
                .foregroundStyle(detailIsWarning ? Color.orange : Color.primary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The canvas's gold-tinted capsule.
private struct FinishSetupActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(.subheadline.weight(.semibold))
            .foregroundStyle(Color.conduitAccent)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Color.conduitAccent.opacity(0.14), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.conduitAccent.opacity(0.3), lineWidth: 1) }
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
            .contentShape(Capsule())
    }
}
