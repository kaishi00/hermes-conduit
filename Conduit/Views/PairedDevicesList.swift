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
    @State private var loadError: String?
    /// Bumped by each change, so a read that started before it can't put
    /// back the list the change replaced.
    @State private var generation = 0
    /// Bumped by each read, so only the newest one lands: a Try Again and
    /// the read after a pairing can overlap.
    @State private var readToken = 0

    var body: some View {
        Group {
            // A failed read shows above the rows it couldn't refresh, too.
            if let loadError {
                HStack(spacing: 8) {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(AppLocalization.string("Try Again")) { Task { await load() } }
                        .scaledFont(.footnote)
                }
            }
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
        // Read again when a pairing ends, the one Conduit makes on connect too.
        .task(id: "\(appState.activeDashboardID?.uuidString ?? "")|\(profile)|\(refreshToken)|\(notifications.isPairing)") {
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
                if device.relayRejected {
                    // The relay refused its last push: it gets nothing until paired again.
                    Text(AppLocalization.string("The relay no longer knows this device. Pair it again.", table: .settings))
                        .scaledFont(.caption)
                        .foregroundStyle(.orange)
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
            .accessibilityLabel(AppLocalization.string("Options for \(device.name ?? fallback)", table: .settings))
            .disabled(working)
        }
    }

    private func load() async {
        let started = generation
        readToken += 1
        let token = readToken
        do {
            let read = try await appState.pairedDevices(profile)
            guard started == generation, token == readToken, !Task.isCancelled else { return }
            devices = read
            loadError = nil
        } catch {
            guard started == generation, token == readToken, !Task.isCancelled else { return }
            loadError = UserFacingError.message(for: error)
        }
    }

    private func change(_ run: @escaping () async throws -> [PushNotificationService.PairedDevice]) {
        Task {
            working = true
            changeError = nil
            generation += 1
            do {
                devices = try await run()
                loadError = nil
                Haptics.success()
            } catch {
                changeError = UserFacingError.message(for: error)
                Haptics.error()
            }
            working = false
        }
    }
}
