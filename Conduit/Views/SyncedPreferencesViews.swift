//
//  SyncedPreferencesViews.swift
//  Conduit
//
//  Settings > Sync across devices (#1089): the switch, what it shares, and
//  how to bring the set to another host.
//

import SwiftUI

struct SyncedPreferencesSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: SyncedPreferencesController
    /// Asked when turning sync on finds preferences from another device.
    @State private var choosingStart = false
    @State private var confirmingCopy = false
    @State private var checkingHost = false
    @State private var turningOn: Task<Void, Never>?

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Sync across devices"), symbol: "arrow.triangle.2.circlepath", tint: .conduitAccent) {
                Text("Your iPhone and iPad share Conduit's preferences through the Conduit plugin on your Hermes host: appearance, chat and voice settings, CarPlay, and your other saved dashboards (their addresses only).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle(AppLocalization.string("Sync with this Hermes"), isOn: Binding(
                    // Holds on while the host is checked, so the tap reads as taken.
                    get: { controller.isEnabled || checkingHost },
                    set: { enabled in
                        Haptics.selection()
                        if enabled {
                            turnOn()
                        } else {
                            Task { await appState.setSyncedPreferencesEnabled(false) }
                        }
                    }
                ))
                .tint(.conduitAccent)
                .disabled(!appState.supportsSyncedPreferences || checkingHost)
                .accessibilityIdentifier("settings.sync.enabled")
                if !appState.supportsSyncedPreferences {
                    Text("Needs Conduit plugin 0.54 or later on this host.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if controller.isEnabled {
                    SettingsMetricRow(label: AppLocalization.string("Status"), value: statusText, lineLimit: 2)
                    Button {
                        Task { await appState.syncPreferences() }
                    } label: {
                        Label(AppLocalization.string("Sync now"), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                    }
                    .disabled(controller.status == .syncing)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAccent.opacity(0.16))
                    .accessibilityIdentifier("settings.sync.now")
                }
                Text("Passwords, sign-ins, Cloudflare tokens and custom headers stay on each device, and so does your OK for live voice providers and how GPT-Live is paid for. When two devices change the same setting, the later change wins.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if appState.supportsSyncedPreferences && controller.isEnabled {
                ConduitSettingsSection(title: AppLocalization.string("Another host"), symbol: "server.rack", tint: .conduitAura) {
                    Text("Each Hermes profile keeps its own copy. To bring yours to a new host or profile, connect to it and copy this device's settings there.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button {
                        confirmingCopy = true
                    } label: {
                        Label(AppLocalization.string("Copy this device's settings here"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .frame(minHeight: 44)
                    }
                    .disabled(controller.status == .syncing)
                    .conduitGlassControl(cornerRadius: 16, tint: .conduitAura.opacity(0.16))
                    .accessibilityIdentifier("settings.sync.copy")
                    Text("On the host, `hermes conduit-push prefs export` and `prefs import` move the same set between hosts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Sync turns on after the host is checked, so the rows and the
        // "Another host" section it reveals animate on the value.
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: controller.isEnabled)
        .navigationTitle(AppLocalization.string("Sync across devices"))
        .onDisappear {
            turningOn?.cancel()
            checkingHost = false
        }
        .task(id: appState.activeDashboardID) {
            await appState.syncPreferences()
        }
        .confirmationDialog(
            AppLocalization.string("This Hermes already has settings from another device"),
            isPresented: $choosingStart,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Use the ones on Hermes")) {
                Task { await appState.setSyncedPreferencesEnabled(true, start: .useHost) }
            }
            Button(AppLocalization.string("Use this device's")) {
                Task { await appState.setSyncedPreferencesEnabled(true, start: .useDevice) }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            AppLocalization.string("Replace this Hermes' copy with this device's settings?"),
            isPresented: $confirmingCopy,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Copy settings")) {
                Task { await appState.copyPreferencesToHost() }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text("Your other devices on this host take these settings when they next connect.")
        }
    }

    private func turnOn() {
        checkingHost = true
        turningOn = Task {
            let hostHasValues = await appState.hostHasSyncedPreferences()
            checkingHost = false
            // Left the page meanwhile: sync stays off.
            guard !Task.isCancelled else { return }
            if hostHasValues == true {
                choosingStart = true
            } else {
                // An empty host takes all of this device's values either way;
                // one another device filled meanwhile, or one that couldn't
                // be read, keeps its own.
                await appState.setSyncedPreferencesEnabled(true, start: .useHost)
            }
        }
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return AppLocalization.string("Not synced yet")
        case .syncing: return AppLocalization.string("Syncing…")
        case .synced(let date):
            return AppLocalization.string("Synced \(date.formatted(.relative(presentation: .named).locale(AppLocalization.formattingLocale)))")
        case .failed(let message): return message
        }
    }
}
