//
//  SavedDashboardsView.swift
//  Conduit
//
//  Settings > Connection > Saved Dashboards (#148): the multi-dashboard
//  management surface. Rows show each saved dashboard with its live state;
//  per-row actions are Switch (reusable auth exists), Sign In (none), and —
//  via the context menu — Sign Out of This Dashboard and Remove Dashboard.
//  All connection work is delegated to AppState.switchDashboard /
//  signOutDashboard / removeDashboard; this view owns no auth logic.
//

import SwiftUI

struct SavedDashboardsSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    let close: () -> Void

    @State private var rows: [SavedDashboardRowModel] = []
    @State private var isSwitchingTo: UUID?
    @State private var pendingRemoval: SavedDashboardRowModel?

    struct SavedDashboardRowModel: Identifiable {
        let dashboard: SavedDashboard
        let isActive: Bool
        let hasReusableAuth: Bool
        var id: UUID { dashboard.id }
    }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(
                title: AppLocalization.string("Saved Dashboards"),
                symbol: "server.rack",
                tint: .conduitAura
            ) {
                Text("Switch between your saved Hermes dashboards. Each dashboard keeps its own sign-in and cookies on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    rowView(row)
                }
                Button {
                    Haptics.selection()
                    addDashboard()
                } label: {
                    Label(AppLocalization.string("Add Dashboard"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.12))
                .accessibilityIdentifier("settings.add-dashboard")
            }
        }
        .navigationTitle("Saved Dashboards")
        .task { rebuildRows() }
        .onChange(of: appState.savedDashboardRegistry) { _, _ in rebuildRows() }
        .onChange(of: appState.isConnected) { _, _ in rebuildRows() }
        .onChange(of: appState.isConnecting) { _, _ in rebuildRows() }
        .confirmationDialog(
            AppLocalization.string("Remove Dashboard?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: Visibility.visible
        ) {
            Button(AppLocalization.string("Remove Dashboard"), role: .destructive) {
                if let row = pendingRemoval {
                    removeDashboard(row)
                }
                pendingRemoval = nil
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text("This dashboard's saved sign-in and cookies will be deleted from this device. Other dashboards are not affected.")
        }
    }

    // MARK: - Rows

    private func rowView(_ row: SavedDashboardRowModel) -> some View {
        Button {
            Haptics.selection()
            if !row.isActive {
                switchTo(row)
            }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor(row))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.dashboard.label)
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: row.dashboard.normalizedURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(statusText(row))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor(row))
                }
                Spacer(minLength: 8)
                if row.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.conduitAccent)
                        .accessibilityLabel(AppLocalization.string("Active dashboard"))
                } else if isSwitchingTo == row.dashboard.id {
                    ProgressView()
                } else {
                    Text(actionText(row))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.conduitAccent)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.isActive)
        .accessibilityIdentifier("settings.dashboard.row")
        .contextMenu {
            Button {
                Haptics.selection()
                signOut(row)
            } label: {
                Label(AppLocalization.string("Sign Out of This Dashboard"), systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button(role: .destructive) {
                pendingRemoval = row
            } label: {
                Label(AppLocalization.string("Remove Dashboard"), systemImage: "trash")
            }
        }
    }

    private func statusText(_ row: SavedDashboardRowModel) -> String {
        if row.isActive {
            if isSwitchingTo == row.dashboard.id || appState.isConnecting { return AppLocalization.string("Connecting…") }
            return appState.isConnected
                ? AppLocalization.string("Connected")
                : AppLocalization.string("Disconnected")
        }
        return row.hasReusableAuth
            ? AppLocalization.string("Saved")
            : AppLocalization.string("Sign In required")
    }

    private func actionText(_ row: SavedDashboardRowModel) -> String {
        row.hasReusableAuth
            ? AppLocalization.string("Switch")
            : AppLocalization.string("Sign In")
    }

    private func statusColor(_ row: SavedDashboardRowModel) -> Color {
        if row.isActive {
            if isSwitchingTo == row.dashboard.id || appState.isConnecting { return .orange }
            return appState.isConnected ? .green : .red
        }
        return row.hasReusableAuth ? .secondary : .orange
    }

    // MARK: - Actions

    /// Rebuilds the row models. Keychain reads stay off the render path —
    /// this runs on task and registry/connection changes, mirroring the
    /// SettingsHome seeding pattern.
    private func rebuildRows() {
        rows = appState.savedDashboardRegistry.dashboards.map { dashboard in
            let id = dashboard.id
            let hasAuth = id == appState.activeDashboardID
                || KeychainHelper.loadCredentials(dashboardID: id) != nil
                || KeychainHelper.loadConnection(dashboardID: id) != nil
            return SavedDashboardRowModel(
                dashboard: dashboard,
                isActive: id == appState.activeDashboardID,
                hasReusableAuth: hasAuth
            )
        }
    }

    private func switchTo(_ row: SavedDashboardRowModel) {
        let id = row.dashboard.id
        isSwitchingTo = id
        Task {
            await appState.switchDashboard(to: id)
            isSwitchingTo = nil
            // A switch that ends in the sign-in surface hands control to the
            // login card behind this sheet; dismiss so it is visible.
            if appState.showLogin { close() }
        }
    }

    private func addDashboard() {
        appState.showLogin = true
        close()
    }

    private func signOut(_ row: SavedDashboardRowModel) {
        let wasActive = row.isActive
        appState.signOutDashboard(row.dashboard.id)
        rebuildRows()
        if wasActive { close() }
    }

    private func removeDashboard(_ row: SavedDashboardRowModel) {
        let wasActive = row.isActive
        appState.removeDashboard(row.dashboard.id)
        rebuildRows()
        if wasActive { close() }
    }
}
