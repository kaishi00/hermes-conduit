//
//  SavedDashboardsView.swift
//  Conduit
//
//  Settings > Connection > Saved Dashboards (#148): the multi-dashboard
//  management surface. Rows show each saved dashboard with its live state;
//  per-row actions are Switch (reusable auth exists), Sign In (none), and —
//  via the context menu — Sign Out of This Dashboard and Remove Dashboard.
//  Add Dashboard opens the Add a dashboard sheet (Views/Login).
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
    @State private var showsAddDashboard = false

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
                        .padding(.vertical, 6).frame(minHeight: 44)
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
        // Adding a dashboard is a sheet over this page: Cancel leaves the
        // current dashboard and chat as they were.
        .sheet(isPresented: $showsAddDashboard) {
            AddDashboardSheet(onSignedIn: { close() })
                .environmentObject(appState)
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
            SavedDashboardRowLabel(row: row, isSwitching: isSwitchingTo == row.dashboard.id)
                .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.isActive || isSwitchingTo != nil)
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

    // MARK: - Actions

    /// Rebuilds the row models. Keychain reads stay off the render path —
    /// this runs on task and registry/connection changes, mirroring the
    /// SettingsHome seeding pattern.
    private func rebuildRows() {
        rows = SavedDashboardRowModel.rows(appState)
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
        showsAddDashboard = true
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

/// One saved dashboard as the switch lists show it (Settings > Saved
/// Dashboards and the Profiles sheet, #288 in the notifier repo).
struct SavedDashboardRowModel: Identifiable {
    let dashboard: SavedDashboard
    let isActive: Bool
    let hasReusableAuth: Bool
    var id: UUID { dashboard.id }

    /// Reads the Keychain: build these on task and on registry/connection
    /// changes, not while rendering.
    @MainActor
    static func rows(_ appState: AppState) -> [SavedDashboardRowModel] {
        appState.savedDashboardRegistry.dashboards.map { dashboard in
            let id = dashboard.id
            let hasAuth = id == appState.activeDashboardID
                || KeychainHelper.loadCredentials(dashboardID: id) != nil
                || KeychainHelper.loadConnection(dashboardID: id) != nil
                || KeychainHelper.loadNativeOAuthTokens(dashboardID: id) != nil
            return SavedDashboardRowModel(
                dashboard: dashboard,
                isActive: id == appState.activeDashboardID,
                hasReusableAuth: hasAuth
            )
        }
    }
}

/// A saved dashboard row's contents: status dot, name, address, status
/// line, then a checkmark (active), a spinner (switching there) or the
/// action it takes (Switch / Sign In).
struct SavedDashboardRowLabel: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var notifications = PushNotificationService.shared
    let row: SavedDashboardRowModel
    let isSwitching: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: row.dashboard.label)
                        .font(.subheadline.weight(.semibold))
                    if notificationsEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(AppLocalization.string("Notifications end-to-end encrypted"))
                    }
                }
                Text(verbatim: row.dashboard.normalizedURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 8)
            if row.isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.conduitAccent)
                    .accessibilityLabel(AppLocalization.string("Active dashboard"))
            } else if isSwitching {
                ProgressView()
            } else {
                Text(actionText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.conduitAccent)
            }
        }
    }

    private var statusText: String {
        if row.isActive {
            if isSwitching || appState.isConnecting { return AppLocalization.string("Connecting…") }
            return appState.isConnected
                ? AppLocalization.string("Connected")
                : AppLocalization.string("Disconnected")
        }
        return row.hasReusableAuth
            ? AppLocalization.string("Saved")
            : AppLocalization.string("Sign In required")
    }

    /// Every pairing of this dashboard's hosts is end-to-end encrypted with
    /// a key the host confirmed (the details are in Settings >
    /// Notifications).
    private var notificationsEncrypted: Bool {
        guard notifications.isEnabled else { return false }
        let gatewayIDs = appState.relayGatewayIDs(of: row.dashboard.id)
        return !gatewayIDs.isEmpty && gatewayIDs.allSatisfy { gatewayID in
            if case .ensured = notifications.encryptionAssurance(gatewayID: gatewayID) { return true }
            return false
        }
    }

    private var actionText: String {
        row.hasReusableAuth
            ? AppLocalization.string("Switch")
            : AppLocalization.string("Sign In")
    }

    private var statusColor: Color {
        if row.isActive {
            if isSwitching || appState.isConnecting { return .orange }
            return appState.isConnected ? .green : .red
        }
        return row.hasReusableAuth ? .secondary : .orange
    }
}
