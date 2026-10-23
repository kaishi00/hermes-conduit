//
//  AppState+SyncedPreferences.swift
//  Conduit
//
//  Which preferences this device shares with its others through the
//  plugin (SyncedPreferences.swift, #1089), and when it syncs them: on
//  every connect and profile switch, a moment after a shared preference
//  changes here, and when Settings > Sync across devices opens.
//

import Foundation

extension AppState {
    /// One ledger per dashboard and profile: the host keeps one set per
    /// profile.
    var syncedPreferencesScope: String? {
        guard connection != nil, let dashboardID = activeDashboardID else { return nil }
        return "\(dashboardID.uuidString)|\(activeProfile)"
    }

    var supportsSyncedPreferences: Bool {
        notifierPlugin.reports(SyncedPreferencesEngine.capability)
    }

    func setSyncedPreferencesEnabled(_ enabled: Bool, start: SyncedPreferencesStart = .useHost) async {
        syncedPreferences.setEnabled(enabled)
        guard enabled else { return }
        await syncPreferences(start: start)
    }

    /// Replaces this host's copy with this device's preferences: the way
    /// to bring them to a new host.
    func copyPreferencesToHost() async {
        await syncPreferences(start: .useDevice)
    }

    /// Whether the host already keeps preferences from another device, so
    /// turning sync on should ask which side wins. Nil when it can't tell.
    func hostHasSyncedPreferences() async -> Bool? {
        guard supportsSyncedPreferences, let bridge = dashboardTicketBridge else { return nil }
        let path = DashboardPath.withProfile(SyncedPreferencesEngine.path, profile: activeProfile)
        guard let response = try? await bridge.requestJSON(path: path) else { return nil }
        return SyncedPreferencesEngine.hostValues(response).map { !$0.isEmpty }
    }

    /// Shares this device's changes and takes the host's. Quiet when sync
    /// is off or the host's plugin predates it. `onlyIfChanged` skips the
    /// request when nothing shared changed here (most preference writes are
    /// other keys).
    func syncPreferences(start: SyncedPreferencesStart = .useHost, onlyIfChanged: Bool = false) async {
        let controller = syncedPreferences
        controller.observeLocalChanges { [weak self] in await self?.syncPreferences(onlyIfChanged: true) }
        guard controller.isEnabled, supportsSyncedPreferences,
              let scope = syncedPreferencesScope, let bridge = dashboardTicketBridge else { return }
        guard controller.begin(start) else { return }
        defer {
            if let owed = controller.end() {
                Task { await self.syncPreferences(start: owed) }
            } else if controller.status == .syncing {
                // A sync dropped for another host or profile leaves no status behind.
                controller.status = .idle
            }
        }
        controller.keepLedgers(dashboardIDs: Set(savedDashboardRegistry.dashboards.map(\.id.uuidString)))

        let profile = activeProfile
        let path = DashboardPath.withProfile(SyncedPreferencesEngine.path, profile: profile)
        // Another host or profile by the time an answer comes: its values
        // aren't this one's.
        // Sync turned off meanwhile: nothing it brings back is applied.
        let isCurrent = { [weak self] in
            bridge === self?.dashboardTicketBridge && self?.syncedPreferencesScope == scope && controller.isEnabled
        }
        let ledger = start == .useDevice ? nil : controller.ledger(for: scope)
        let slots = syncedPreferenceSlots
        do {
            var host: [String: Any]?
            if ledger == nil, start == .useHost {
                let response = try await bridge.requestJSON(path: path)
                guard isCurrent() else { return }
                guard let values = SyncedPreferencesEngine.hostValues(response) else {
                    controller.status = .failed(AppLocalization.string("The host's answer wasn't readable."))
                    return
                }
                host = values
            }
            let before = SyncedPreferencesEngine.snapshot(slots)
            let changes = SyncedPreferencesEngine.changes(slots: slots, ledger: ledger, host: host, start: start)
            // A value held back during a call isn't owed here: syncWhenReleased
            // brings it once the call ends.
            if onlyIfChanged, ledger != nil, changes.isEmpty { return }
            controller.status = .syncing
            // Sent even with nothing to upload: the answer is the host's
            // current set, which is what gets applied.
            let response = try await bridge.requestJSON(path: path, method: "PUT", body: [
                "installation_id": agentSettings.installationID,
                "device": SyncedPreferencesController.deviceName,
                "changes": changes,
            ])
            guard isCurrent() else { return }
            guard let values = SyncedPreferencesEngine.hostValues(response) else {
                controller.status = .failed(AppLocalization.string("The host's answer wasn't readable."))
                return
            }
            let entry = SyncedPreferencesEngine.apply(
                host: values,
                slots: slots, uploaded: Set(changes.keys), ledger: ledger, before: before
            )
            controller.setLedger(entry, for: scope)
            if !(entry.held?.isEmpty ?? true) {
                controller.syncWhenReleased(isHeld: { [weak self] in self?.holdsSyncedVoicePreferences ?? false }) { [weak self] in
                    await self?.syncPreferences()
                }
            }
            controller.status = .synced(entry.syncedAt ?? Date())
        } catch {
            guard isCurrent() else { return }
            controller.status = .failed(UserFacingError.message(for: error))
        }
    }

    /// Every preference shared with the host, read and written for the
    /// active profile. Built for each sync and never stored.
    var syncedPreferenceSlots: [SyncedPreferenceSlot] {
        let defaults = syncedPreferences.defaults
        var slots: [SyncedPreferenceSlot] = [
            .defaults("app.accent", ConduitAccent.storageKey, .string, in: defaults),
            .defaults("app.chat_text_size", ChatTypography.preferenceKey, .int, in: defaults),
            .defaults("app.chat_font_style", ChatTypography.fontStylePreferenceKey, .string, in: defaults),
            .defaults("app.haptics", Haptics.preferenceKey, .bool, in: defaults),
            .defaults("app.return_key_sends", ComposerReturnKey.preferenceKey, .bool, in: defaults),
            .defaults("app.main_button_new_chat", V2MainButtonPreference.key, .bool, in: defaults),
            .defaults("app.chat_voice_button", ChatVoiceButtonAction.key, .string, in: defaults),
            .defaults("app.project_chats", ProjectChatsInChats.key, .string, in: defaults),
            .defaults("app.take_over_chats", ChatTakeoverPreference.automaticKey, .bool, in: defaults),
            .defaults("app.live_activities", LiveTurnActivities.enabledDefaultsKey, .bool, in: defaults),
            .defaults("dictation.engine", DictationEngine.preferenceKey, .string, in: defaults),
            .defaults("dictation.custom_words", DictationCustomWords.preferenceKey, .strings, in: defaults),
            .defaults("voice.read_aloud_speed", ReadAloudSpeed.preferenceKey, .double, in: defaults),
            .defaults("voice.keep_screen_awake", VoiceScreenAwake.preferenceKey, .bool, in: defaults),
            .defaults("voice.animate_call_orb", LiveVoiceOrbPower.preferenceKey, .bool, in: defaults),
        ]
        let carPlay = CarPlayPreferences.shared
        for (key, localKey, kind) in [
            ("carplay.shortcuts", CarPlayPreferences.shortcutsKey, SyncedPreferenceSlot.Kind.json),
            ("carplay.sounds", CarPlayPreferences.soundsKey, .bool),
            ("carplay.choose_chat_first", CarPlayPreferences.chooseChatFirstKey, .bool),
        ] {
            let stored = SyncedPreferenceSlot.defaults(key, localKey, kind, in: defaults)
            slots.append(SyncedPreferenceSlot(key: key, read: stored.read, write: {
                stored.write($0)
                carPlay.reload()
            }))
        }
        slots.append(voicePreferencesSlot)
        slots.append(savedDashboardsSlot)
        return slots
    }

    /// Fields of the Voice preferences that stay on this device: who pays
    /// for GPT-Live calls (chosen only after a confirmation here) and the
    /// mute of the call in progress.
    static let deviceOnlyVoicePreferenceKeys: Set<String> = [
        "outputMuted", "gptLiveBilling", "gptLiveAPIHermesCalls", "gptLiveAPIMaxMinutes",
    ]

    /// The active profile's Voice preferences (mode, voices, live style,
    /// conversation): the host already keeps one set per profile.
    private var voicePreferencesSlot: SyncedPreferenceSlot {
        SyncedPreferenceSlot(
            key: "voice.preferences",
            read: { [weak self] in
                guard let data = self?.storedActiveVoicePreferencesData,
                      var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                for key in Self.deviceOnlyVoicePreferenceKeys { object.removeValue(forKey: key) }
                return object
            },
            write: { [weak self] value in
                guard let self else { return }
                var merged = value as? [String: Any] ?? [:]
                let local = self.storedActiveVoicePreferencesData
                    .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
                for key in Self.deviceOnlyVoicePreferenceKeys {
                    merged[key] = local[key]
                }
                guard JSONSerialization.isValidJSONObject(merged),
                      let data = try? JSONSerialization.data(withJSONObject: merged),
                      let preferences = try? JSONDecoder().decode(VoiceProfilePreferences.self, from: data) else { return }
                self.adoptSyncedVoicePreferences(preferences)
            },
            canApply: { [weak self] in self?.holdsSyncedVoicePreferences == false }
        )
    }

    /// The other saved dashboards, by address only: one added on another
    /// device shows up here asking for its sign-in. Removing one here never
    /// removes it elsewhere.
    private var savedDashboardsSlot: SyncedPreferenceSlot {
        SyncedPreferenceSlot(
            key: "app.dashboards",
            read: { [weak self] in
                guard let self else { return nil }
                return self.savedDashboardRegistry.dashboards.map(\.normalizedURL).sorted()
            },
            write: { [weak self] value in
                guard let self else { return }
                for url in value as? [String] ?? [] {
                    guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(url), normalized == url,
                          self.savedDashboardRegistry.dashboard(claiming: normalized) == nil else { continue }
                    self.registerDashboard(forNormalizedURL: normalized)
                }
            },
            merge: .addOnly
        )
    }
}
