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
        switch appState.activeGatewayRestart {
        case .idle:
            EmptyView()
        case .requesting:
            gatewayRestartRow(AppLocalization.string("Asking Hermes to restart the gateway…"), detail: nil)
        case .restarting(let stage, let detail):
            gatewayRestartRow(Self.title(for: stage), detail: detail, logDetail: true)
        case .restarted(let sharedProfiles):
            gatewayRestartRow(
                AppLocalization.string("Gateway restarted"),
                detail: sharedProfiles.isEmpty ? nil : AppLocalization.string("Profiles on this gateway: \(Self.list(sharedProfiles))"),
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        case .failed(let detail):
            gatewayRestartRow(
                AppLocalization.string("Couldn't restart the gateway"),
                detail: detail,
                logDetail: true,
                symbol: "exclamationmark.triangle.fill",
                tint: .red
            )
        case .failedToStart:
            gatewayRestartRow(
                AppLocalization.string("The gateway didn't start"),
                detail: AppLocalization.string("Run hermes gateway status on the host to see why."),
                symbol: "exclamationmark.triangle.fill",
                tint: .red
            )
        case .notBackYet:
            gatewayRestartRow(
                AppLocalization.string("The gateway isn't back yet"),
                detail: AppLocalization.string("It may still be finishing running tasks. Run hermes gateway status on the host to check."),
                symbol: "clock.badge.exclamationmark",
                tint: .orange
            )
        case .unsupported:
            gatewayRestartRow(
                AppLocalization.string("This Hermes can't restart its gateway from Conduit"),
                detail: AppLocalization.string("Update Hermes, or run hermes gateway restart on the host."),
                symbol: "exclamationmark.circle.fill",
                tint: .orange
            )
        }
    }

    /// One status row. Without `symbol` it shows a spinner (still going);
    /// with one, a finished outcome the user can dismiss. A `logDetail` is
    /// Hermes' own log line, shown verbatim.
    private func gatewayRestartRow(
        _ title: String,
        detail: String?,
        logDetail: Bool = false,
        symbol: String? = nil,
        tint: Color = .secondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(logDetail ? .caption.monospaced() : .footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(logDetail ? 3 : nil)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if symbol != nil {
                Button { appState.dismissGatewayRestartOutcome() } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
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
