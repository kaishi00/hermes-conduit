//
//  HermesUpdateViews.swift
//  Conduit
//
//  Settings > Connection's Hermes section: the host's Hermes version,
//  whether it's behind, what's new, and Update Hermes, which runs
//  `hermes update` on the host and follows it through the restart
//  (AppState+HermesUpdate.swift).
//

import SwiftUI

struct HermesUpdateSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var confirming = false
    /// The last check's answer, kept while an update runs so the version
    /// stays shown.
    @State private var lastCheck: HermesUpdateCheck?

    private var state: HermesUpdateState { appState.activeHermesUpdate }

    var body: some View {
        ConduitSettingsSection(title: "Hermes", symbol: "arrow.down.circle", tint: .conduitAccent) {
            if let version = lastCheck?.currentVersion, !version.isEmpty {
                SettingsMetricRow(label: AppLocalization.string("Version"), value: version, lineLimit: 1)
            }
            statusRow
            if case .checked(let check) = state, check.canUpdateHere {
                if !check.commits.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLocalization.string("What's new", table: .connection))
                            .scaledFont(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(check.commits.prefix(6)) { commit in
                            Text(verbatim: "• " + commit.summary)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { confirming = true } label: {
                    Label(AppLocalization.string("Update Hermes", table: .connection), systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 44)
                }
                .disabled(!appState.canUpdateHermes)
                .conduitGlassControl(cornerRadius: 16, tint: Color.conduitAccent.opacity(0.14))
                .accessibilityIdentifier("settings.hermes.update")
            }
            Button {
                appState.checkHermesUpdate(force: true)
            } label: {
                Label(AppLocalization.string("Check for Updates"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity).padding(.vertical, 6).frame(minHeight: 44)
            }
            .disabled(!appState.canUpdateHermes)
            .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.12))
            .accessibilityIdentifier("settings.hermes.check")
            Text(AppLocalization.string("Update Hermes runs hermes update on your host. Hermes restarts on the new version, and Conduit reconnects when it's back.", table: .connection))
                .scaledFont(.footnote).foregroundStyle(.secondary)
        }
        .confirmationDialog(AppLocalization.string("Update Hermes on your host?", table: .connection), isPresented: $confirming, titleVisibility: .visible) {
            Button(AppLocalization.string("Update Hermes", table: .connection)) { appState.updateHermes() }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .task(id: appState.activeDashboardID) {
            // Hermes answers from its cache, so opening the page is cheap.
            if appState.activeHermesUpdate == .idle { appState.checkHermesUpdate(force: false) }
        }
        .onChange(of: state, initial: true) { previous, state in
            if case .checked(let check) = state { lastCheck = check }
            if case .updated(let version) = state {
                if let version { lastCheck?.currentVersion = version } else { lastCheck = nil }
            }
            // Each step and the outcome once: a new log line under the same
            // step isn't announced again.
            if let title = Self.announcement(for: state), title != Self.announcement(for: previous) {
                AccessibilityNotification.Announcement(title).post()
            }
        }
    }

    private var confirmMessage: String {
        var lines = [AppLocalization.string("Hermes pulls the new version and restarts. Chats and messaging channels pause until it's back.", table: .connection)]
        if case .checked(let check) = state, let release = check.rollbackTo {
            lines.append(AppLocalization.string("This host is newer than the \(release) release; updating moves it back to that release.", table: .connection))
        }
        return lines.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var statusRow: some View {
        switch state {
        case .idle:
            EmptyView()
        case .checking:
            progressRow(AppLocalization.string("Checking for updates…", table: .connection), detail: nil)
        case .checked(let check):
            if check.canUpdateHere {
                outcomeRow(Self.availableTitle(check), detail: nil, symbol: "arrow.down.circle.fill", tint: .conduitAccent)
            } else if check.updateAvailable {
                // An install this dashboard can't update in place.
                outcomeRow(Self.availableTitle(check), detail: check.message, command: check.updateCommand, symbol: "info.circle.fill", tint: .orange)
            } else if check.behind == nil, !check.canApply, let command = check.updateCommand, !command.isEmpty {
                // Docker or pip: Hermes can't tell from here, so how to update
                // on the host.
                outcomeRow(AppLocalization.string("Update Hermes on the host", table: .connection), detail: check.message, command: command, symbol: "info.circle.fill", tint: .orange)
            } else if check.behind == nil {
                outcomeRow(AppLocalization.string("Couldn't check for updates", table: .connection), detail: check.message, symbol: "exclamationmark.circle.fill", tint: .orange)
            } else {
                outcomeRow(AppLocalization.string("Hermes is up to date", table: .connection), detail: check.message, symbol: "checkmark.circle.fill", tint: .green)
            }
        case .updating(let step, let detail):
            progressRow(Self.stepTitle(step), detail: detail)
        case .updated(let version):
            outcomeRow(version.map { AppLocalization.string("Hermes updated to \($0)", table: .connection) } ?? AppLocalization.string("Hermes updated", table: .connection),
                       detail: nil, symbol: "checkmark.circle.fill", tint: .green)
        case .failed(let detail):
            outcomeRow(AppLocalization.string("Couldn't update Hermes", table: .connection), detail: detail, symbol: "exclamationmark.triangle.fill", tint: .red)
        case .manual(let message, let command):
            outcomeRow(AppLocalization.string("Update Hermes on the host", table: .connection), detail: message, command: command, symbol: "info.circle.fill", tint: .orange)
        case .notBackYet:
            outcomeRow(AppLocalization.string("Hermes isn't back yet", table: .connection),
                       detail: AppLocalization.string("The update may still be running. Run hermes update on the host to check.", table: .connection),
                       symbol: "clock.badge.exclamationmark", tint: .orange)
        case .unsupported:
            outcomeRow(AppLocalization.string("This Hermes can't update from Conduit", table: .connection),
                       detail: AppLocalization.string("Run hermes update on the host.", table: .connection),
                       symbol: "exclamationmark.circle.fill", tint: .orange)
        }
    }

    private func progressRow(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).scaledFont(.subheadline.weight(.semibold))
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail).scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func outcomeRow(_ title: String, detail: String?, command: String? = nil, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).scaledFont(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail).scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let command, !command.isEmpty {
                    Text(verbatim: command)
                        .scaledFont(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func availableTitle(_ check: HermesUpdateCheck) -> String {
        if let version = check.sourceVersion {
            return AppLocalization.string("Hermes \(version) is available", table: .connection)
        }
        return AppLocalization.string("An update is available", table: .connection)
    }

    static func stepTitle(_ step: HermesUpdateStep) -> String {
        switch step {
        case .starting: return AppLocalization.string("Asking Hermes to update…", table: .connection)
        case .updating: return AppLocalization.string("Updating Hermes…", table: .connection)
        case .restarting: return AppLocalization.string("Hermes is restarting on the new version…", table: .connection)
        }
    }

    /// What VoiceOver hears as the update moves: each step, then the outcome.
    static func announcement(for state: HermesUpdateState) -> String? {
        switch state {
        case .updating(let step, _): return stepTitle(step)
        case .updated(let version): return version.map { AppLocalization.string("Hermes updated to \($0)", table: .connection) } ?? AppLocalization.string("Hermes updated", table: .connection)
        case .failed: return AppLocalization.string("Couldn't update Hermes", table: .connection)
        default: return nil
        }
    }
}
