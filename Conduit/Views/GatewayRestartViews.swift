//
//  GatewayRestartViews.swift
//  Conduit
//
//  Restart Gateway's confirmation and progress, shared by the chat's Gateway
//  sheet and Settings > Gateway (AppState+GatewayRestart.swift).
//

import SwiftUI

extension View {
    /// Asks before Restart Gateway runs: the gateway serves every messaging
    /// channel, and a shared one every profile on the host.
    func gatewayRestartConfirmation(isPresented: Binding<Bool>) -> some View {
        modifier(GatewayRestartConfirmation(isPresented: isPresented))
    }
}

private struct GatewayRestartConfirmation: ViewModifier {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog("Restart the gateway?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Restart Gateway", role: .destructive) { appState.restartGateway() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes restarts its gateway process. Messaging channels, running sessions and any profiles that share this gateway reconnect once it's back.")
        }
    }
}

/// Where Restart Gateway stands: what Hermes is doing while the gateway
/// comes back, then how it went. Shows nothing until a restart starts.
struct GatewayRestartStatusView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let row = Self.row(for: appState.activeGatewayRestart) {
                rowView(row)
            }
        }
        // VoiceOver hears each step and the outcome as they land, once per
        // step: a new log line under the same step isn't announced.
        .onChange(of: appState.activeGatewayRestart) { previous, state in
            guard let row = Self.row(for: state), row.title != Self.row(for: previous)?.title else { return }
            AccessibilityNotification.Announcement(row.title).post()
        }
    }

    private struct GatewayRestartRow {
        var title: String
        var detail: String?
        /// The detail is Hermes' own words, shown verbatim.
        var logDetail = false
        /// Nil while the restart is still going: a spinner shows instead,
        /// and there's nothing to dismiss.
        var symbol: String?
        var tint: Color = .secondary
    }

    private static func row(for state: GatewayRestartState) -> GatewayRestartRow? {
        switch state {
        case .idle:
            return nil
        case .requesting:
            return GatewayRestartRow(title: AppLocalization.string("Asking Hermes to restart the gateway…"))
        case .restarting(let stage, let detail):
            return GatewayRestartRow(title: title(for: stage), detail: detail, logDetail: true)
        case .restarted(let sharedProfiles):
            return GatewayRestartRow(
                title: AppLocalization.string("Gateway restarted"),
                detail: sharedProfiles.isEmpty ? nil : AppLocalization.string("Profiles on this gateway: \(list(sharedProfiles))"),
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        case .failed(let detail):
            return GatewayRestartRow(
                title: AppLocalization.string("Couldn't restart the gateway"),
                detail: detail,
                logDetail: true,
                symbol: "exclamationmark.triangle.fill",
                tint: .red
            )
        case .failedToStart:
            return GatewayRestartRow(
                title: AppLocalization.string("The gateway didn't start"),
                detail: AppLocalization.string("Run hermes gateway status on the host to see why."),
                symbol: "exclamationmark.triangle.fill",
                tint: .red
            )
        case .notBackYet:
            return GatewayRestartRow(
                title: AppLocalization.string("The gateway isn't back yet"),
                detail: AppLocalization.string("It may still be finishing running tasks. Run hermes gateway status on the host to check."),
                symbol: "clock.badge.exclamationmark",
                tint: .orange
            )
        case .unsupported:
            return GatewayRestartRow(
                title: AppLocalization.string("This Hermes can't restart its gateway from Conduit"),
                detail: AppLocalization.string("Update Hermes, or run hermes gateway restart on the host."),
                symbol: "exclamationmark.circle.fill",
                tint: .orange
            )
        }
    }

    private func rowView(_ row: GatewayRestartRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The icon and text read as one VoiceOver element; the dismiss
            // button beside them stays its own.
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
                    if let detail = row.detail, !detail.isEmpty {
                        // A log line is at most 240 characters, so it wraps
                        // in full at any text size.
                        Text(verbatim: detail)
                            .font(row.logDetail ? .caption.monospaced() : .footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if row.symbol != nil {
                Button { appState.dismissGatewayRestartOutcome() } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func title(for stage: GatewayRestartStage) -> String {
        switch stage {
        case .draining: return AppLocalization.string("Letting running tasks finish…")
        case .stopping: return AppLocalization.string("Stopping the gateway…")
        case .starting: return AppLocalization.string("Starting the gateway…")
        }
    }

    private static func list(_ names: [String]) -> String {
        names.formatted(.list(type: .and, width: .narrow).locale(AppLocalization.formattingLocale))
    }
}
