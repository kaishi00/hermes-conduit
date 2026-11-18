import SwiftUI

/// Settings > Notifications: the devices a profile's notifications go to
/// (plugin 0.178+, issue 2758), the main one first. Each is removed on its
/// own, and any can be the one calls ring (the main one, which the phone's
/// tools reach too).
struct PairedDevicesList: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var notifications = PushNotificationService.shared
    let profile: String
    /// Changes when a pairing lands, so the list reads again.
    let refreshToken: Int
    @State private var devices: [PushNotificationService.PairedDevice] = []
    @State private var working = false
    @State private var changeError: String?

    var body: some View {
        Group {
            if !devices.isEmpty {
                Text(AppLocalization.string("Devices notified", table: .settings))
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(devices) { device in
                    row(device)
                }
                if let changeError {
                    Label(changeError, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .task(id: "\(appState.activeDashboardID?.uuidString ?? "")|\(profile)|\(refreshToken)") {
            await load()
        }
    }

    private func row(_ device: PushNotificationService.PairedDevice) -> some View {
        let isThis = device.installationID.caseInsensitiveCompare(notifications.installationID ?? "") == .orderedSame
        let fallback = isThis ? AppLocalization.string("This device", table: .settings)
            : AppLocalization.string("Another device", table: .settings)
        return HStack(spacing: 10) {
            Image(systemName: device.isMain ? "phone.fill" : "bell.fill")
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // The device's own name, as it gave it when it paired.
                Text(verbatim: device.name ?? fallback)
                    .scaledFont(.subheadline)
                if isThis && device.name != nil {
                    Text(AppLocalization.string("This device", table: .settings))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                if device.isMain {
                    Text(AppLocalization.string("Calls ring here", table: .settings))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Menu {
                if !device.isMain {
                    Button {
                        change { try await appState.makeMainDevice(device.installationID, profile: profile) }
                    } label: {
                        Label(AppLocalization.string("Ring calls here", table: .settings), systemImage: "phone")
                    }
                }
                Button(role: .destructive) {
                    change { try await appState.removePairedDevice(device.installationID, profile: profile) }
                } label: {
                    Label(AppLocalization.string("Remove"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .scaledFont(.body)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(AppLocalization.string("Device options", table: .settings))
            .disabled(working)
        }
    }

    private func load() async {
        guard let read = try? await appState.pairedDevices(profile) else { return }
        devices = read
    }

    private func change(_ run: @escaping () async throws -> [PushNotificationService.PairedDevice]) {
        Task {
            working = true
            changeError = nil
            do {
                devices = try await run()
                Haptics.success()
            } catch {
                changeError = UserFacingError.message(for: error)
                Haptics.error()
            }
            working = false
        }
    }
}
