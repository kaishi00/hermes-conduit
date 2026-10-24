//
//  LocationSettingsViews.swift
//  Conduit
//
//  Settings > Location: sharing where the user is with one Hermes profile
//  (designs/location-awareness.md). Two layers, each its own opt-in with
//  its own level of detail, saved places, pause, how long the host keeps
//  history, every time Hermes read the location, the place rules it set
//  up, and deleting the host's copy. Nothing is shared until the user
//  agrees on the consent sheet, which comes before iOS asks for permission.
//

import CoreLocation
import MapKit
import SwiftUI

enum LocationSettingsText {
    static func precisionTitle(_ precision: LocationPrecision) -> String {
        switch precision {
        case .places: return AppLocalization.string("Places only")
        case .area: return AppLocalization.string("Area")
        case .precise: return AppLocalization.string("Precise")
        }
    }

    static func precisionSummary(_ precision: LocationPrecision) -> String {
        switch precision {
        case .places: return AppLocalization.string("Hermes hears only which of your saved places you're at, and your iPhone's time zone.")
        case .area: return AppLocalization.string("Your neighbourhood and city, a position to about 1 km, and distances to your saved places.")
        case .precise: return AppLocalization.string("Your position as your iPhone measures it, and distances to your saved places.")
        }
    }

    static func kindTitle(_ kind: LocationPlaceKind) -> String {
        switch kind {
        case .home: return AppLocalization.string("Home")
        case .work: return AppLocalization.string("Work")
        case .gym: return AppLocalization.string("Gym")
        case .school: return AppLocalization.string("School")
        case .other: return AppLocalization.string("Other")
        }
    }

    static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 0: return AppLocalization.string("Latest only")
        case 1: return AppLocalization.string("24 hours")
        case 7: return AppLocalization.string("7 days")
        case 30: return AppLocalization.string("30 days")
        default: return AppLocalization.string("1 year")
        }
    }

    static func readAction(_ action: String) -> String {
        // "maps search", "maps directions": the host's conduit_maps and a
        // live voice call's maps lookups alike.
        if action == "maps" || action.hasPrefix("maps ") { return AppLocalization.string("Looked something up in Apple Maps") }
        switch action {
        case "now": return AppLocalization.string("Checked where you are")
        case "places": return AppLocalization.string("Listed your places")
        case "history": return AppLocalization.string("Looked at where you've been")
        case "distance_to": return AppLocalization.string("Worked out a distance")
        case "locate": return AppLocalization.string("Asked your iPhone where you are")
        case "rules": return AppLocalization.string("Looked at place rules")
        default: return action
        }
    }

    static func radius(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))
                .locale(AppLocalization.formattingLocale))
    }

    /// A Nous-hosted agent (Hermes Cloud): someone else runs the host.
    static func isHermesCloud(host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "nousresearch.com" || lowered.hasSuffix(".nousresearch.com")
    }
}

struct LocationSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: LocationSharingController
    @ObservedObject var engine: LocationSyncEngine
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject private var notifications = PushNotificationService.shared

    private enum PendingLayer: Identifiable {
        case talking, background
        var id: Int { self == .talking ? 0 : 1 }
    }

    @State private var consentFor: PendingLayer?
    /// Whether the host offered sharing with its other profiles when the
    /// consent sheet opened: what the sheet says is what turning on records.
    @State private var consentOffersProfiles = false
    @State private var editingPlace: LocationPlaceDraft?
    @State private var showsWipe = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var hostStatus: LocationHostStatus?
    @State private var reads: [LocationRead] = []
    /// Live voice calls' maps lookups, logged on this iPhone.
    @State private var voiceMapReads: [LocationRead] = []
    @State private var rules: [LocationRule] = []
    /// Rules whose delete is on its way: their trash button is disabled.
    @State private var deletingRules: Set<String> = []
    @State private var hostUnreachable = false
    /// The voice mode waiting for the user's yes before it may read the location.
    @State private var askingVoiceMode: LiveVoiceModeName?

    private var settings: LocationSharingSettings { controller.settings }
    private var pluginServesLocation: Bool { appState.notifierPlugin.reports(LocationSharingController.capability) }
    private var canTurnOn: Bool { pluginServesLocation && appState.locationDestination != nil }
    /// The host lets its other profiles paired with this iPhone read the
    /// location (notifier #287).
    private var pluginSharesProfiles: Bool { appState.notifierPlugin.reports(LocationSharingController.profilesCapability) }

    var body: some View {
        SettingsDetailContainer {
            introSection
            if settings.isOn || pluginServesLocation {
                talkingSection
                backgroundSection
                placesSection
                if settings.isOn { pauseSection }
                retentionSection
                mapsSection
                if settings.isOn, controller.binding != nil, pluginSharesProfiles || settings.otherProfiles { profilesSection }
            }
            // Kept while a mode is allowed, even on an older plugin, so it can
            // still be turned off.
            if settings.isOn, controller.binding != nil,
               appState.notifierPlugin.servesLocationVoice || !(controller.config.voiceReaders ?? []).isEmpty {
                voiceSection
            }
            if controller.binding != nil {
                readsSection
                rulesSection
                actionSection
            }
        }
        .navigationTitle("Location")
        .task {
            // Once per appearance, not on every body re-evaluation.
            controller.readConfigIfNeeded()
            controller.retryConfigSave()
            appState.activateLocationSharing()
            controller.refreshAuthorization()
            controller.clearExpiredPause()
            await loadFromHost()
        }
        .sheet(item: $consentFor) { layer in
            LocationSharingConsentSheet(
                profile: appState.activeProfile,
                host: hostLabel,
                isHermesCloud: LocationSettingsText.isHermesCloud(host: hostLabel),
                otherProfiles: !settings.isOn
                    && LocationSharingController.otherProfiles(turningOn: settings, bound: controller.binding,
                                                                to: appState.locationDestination,
                                                                offered: consentOffersProfiles)
            ) {
                consentFor = nil
                turnOn(layer == .talking ? .talking : .background)
            } cancel: {
                consentFor = nil
            }
        }
        .sheet(item: $editingPlace) { draft in
            LocationPlaceEditor(draft: draft, canLocate: controller.fixes.canLocate) { place in
                editingPlace = nil
                Task { await controller.savePlace(place); await loadFromHost() }
            } delete: { id in
                editingPlace = nil
                Task { await controller.removePlace(id); await loadFromHost() }
            } cancel: {
                editingPlace = nil
            } locate: {
                await controller.fixes.currentFix(accuracy: kCLLocationAccuracyNearestTenMeters, maxAge: 30)
            }
        }
        .confirmationDialog(
            askingVoiceMode.map { Text(AppLocalization.string("Let \($0.displayName) read your location?")) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { askingVoiceMode != nil }, set: { if !$0 { askingVoiceMode = nil } }),
            titleVisibility: .visible,
            presenting: askingVoiceMode
        ) { mode in
            Button("Allow") { setVoiceRead(mode, allowed: true) }
            Button("Cancel", role: .cancel) {}
        } message: { mode in
            Text(AppLocalization.string("On a call, what it reads goes to \(mode.company) under its terms. You can turn this off at any time."))
        }
        .confirmationDialog("Delete location data on the host?", isPresented: $showsWipe, titleVisibility: .visible) {
            Button("Delete this iPhone's location data", role: .destructive) { wipe(everything: false) }
            Button("Delete everything, including place rules", role: .destructive) { wipe(everything: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes can no longer read what was deleted. Sharing stays as it is; turn the layers off first to stop sending.")
        }
    }

    /// Where turning on sends location: the bound host while a layer is on,
    /// else the dashboard in use.
    private var hostLabel: String {
        if settings.isOn, let binding = controller.binding { return binding.host }
        return appState.locationDestination?.host ?? controller.binding?.host ?? ""
    }

    // MARK: Intro and status

    private var introSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Location for Hermes"), symbol: "location", tint: .blue) {
            Text("Let Hermes know where you are, so it can answer “what's near me”, work out travel times and remind you at places. Your location goes straight from this iPhone to your Hermes host, sealed end to end, and never through Conduit's notification relay.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Maps lookups use Apple Maps on this iPhone, so Apple sees the start and destination.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !pluginServesLocation, !settings.isOn {
                Text("Update the Conduit plugin on your Hermes host to share your location.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if controller.configSaveFailed {
                Text("Couldn't save your location settings on this iPhone. Your changes apply while Conduit is open, and Conduit tries saving them again when you next change something or open the app.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if controller.configUnreadable {
                Text("Conduit can't read its location settings right now. Unlock your iPhone and open this page again. If this keeps happening, start over: your saved places and choices are reset.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button(AppLocalization.string("Start over"), role: .destructive) {
                    controller.startOver()
                }
                .font(.subheadline)
            } else if settings.isOn {
                statusRows
            }
        }
    }

    @ViewBuilder
    private var statusRows: some View {
        if let binding = controller.binding {
            Label(AppLocalization.string("Sharing with \(binding.profile) on \(binding.host)"), systemImage: "checkmark.shield")
                .font(.subheadline)
        }
        if let until = settings.pausedUntil, settings.isPaused(at: Date()) {
            Text(until == .distantFuture
                ? AppLocalization.string("Paused until you turn it back on.")
                : AppLocalization.string("Paused until \(until.formatted(date: .abbreviated, time: .shortened))."))
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let pause = engine.state.pause {
            Text(pause.message)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let last = engine.state.lastFixSent {
            Text(AppLocalization.string("Last sent \(last.formatted(.relative(presentation: .named)))"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Nothing sent yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        permissionRow
        if let error = engine.lastError, engine.state.pause == nil {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch controller.authorization {
        case .denied, .restricted:
            Text("Location access is off for Conduit. Allow it in the Settings app.")
                .font(.caption)
                .foregroundStyle(.orange)
            openSettingsButton
        case .authorizedWhenInUse where settings.background:
            Text("Sharing in the background needs location access set to Always. Change it in the Settings app.")
                .font(.caption)
                .foregroundStyle(.orange)
            openSettingsButton
        default:
            EmptyView()
        }
        if controller.approximate {
            Text("Precise Location is off for Conduit, so saved places and Precise aren't available. Area still works.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var openSettingsButton: some View {
        Button(AppLocalization.string("Open Settings")) {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
        .font(.subheadline)
    }

    // MARK: Layers

    private var talkingSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("While I'm talking to Hermes"), symbol: "bubble.left.and.bubble.right", tint: .conduitAccent) {
            Toggle("Share while I'm talking to Hermes", isOn: layerBinding(.talking))
                .disabled(isWorking || (!settings.talking && !canTurnOn))
                .accessibilityIdentifier("settings.location.talking")
            // Movement during a call is followed only while Conduit is open:
            // Conduit doesn't declare the `location` background mode (see
            // LocationSharingController.voiceCallStarted), so say so.
            Text("A position is sent when you send a message or start a voice call in Conduit, and as you move during a call while Conduit is open. Needs location access While Using the App.")
                .font(.caption)
                .foregroundStyle(.secondary)
            precisionPicker(.talking, value: settings.talkingPrecision)
        }
    }

    private var backgroundSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("In the background"), symbol: "location.circle", tint: .conduitAccent) {
            Toggle("Share in the background", isOn: layerBinding(.background))
                .disabled(isWorking || (!settings.background && !canTurnOn))
                .accessibilityIdentifier("settings.location.background")
            Text("Arriving at and leaving your saved places, places where you spend time, and longer moves. Lets Hermes run place rules and check where you are when it needs to. Needs location access Always.")
                .font(.caption)
                .foregroundStyle(.secondary)
            precisionPicker(.background, value: settings.backgroundPrecision)
            if settings.background,
               !appState.notifierPlugin.reports(LocationSharingController.locateCapability) || hostStatus?.locateAvailable == false {
                Text("Hermes can't ask this iPhone for a fresh position yet; it uses the last one sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if settings.background, controller.authorization == .authorizedAlways, notifications.isEnabled,
                      notifications.authorizationStatus != .denied,
                      notifications.relayMeta?.supportsLocationPush == true, !notifications.relayHasLocationToken {
                // The token goes with the next registration update; until
                // the relay has it, a locate finds nothing to wake (#287).
                Text("Hermes can't ask this iPhone for a fresh position: the notification relay doesn't have its location token yet. Keep notifications on and open Conduit again in a moment.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func precisionPicker(_ layer: LocationSharingController.Layer, value: LocationPrecision) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ConduitMenuPicker(
                value: value,
                choices: LocationPrecision.allCases.map { (id: $0, title: LocationSettingsText.precisionTitle($0)) },
                onSelect: { precision in Task { await controller.setPrecision(precision, for: layer); await loadFromHost() } }
            ) {
                Text("Detail").foregroundStyle(.secondary)
            }
            Text(LocationSettingsText.precisionSummary(value))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func layerBinding(_ layer: PendingLayer) -> Binding<Bool> {
        Binding(
            get: { layer == .talking ? settings.talking : settings.background },
            set: { on in
                if on {
                    Haptics.selection()
                    consentOffersProfiles = pluginSharesProfiles
                    consentFor = layer
                } else {
                    Task { await controller.turnOff(layer == .talking ? .talking : .background); await loadFromHost() }
                }
            }
        )
    }

    // MARK: Places

    private var placesSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Saved places"), symbol: "mappin.and.ellipse", tint: .conduitAccent) {
            ForEach(controller.places) { place in
                Button {
                    editingPlace = LocationPlaceDraft(place)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: place.kind.symbol)
                            .frame(width: 24)
                            .foregroundStyle(Color.conduitAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: place.name)
                                .foregroundStyle(.primary)
                            Text(LocationSettingsText.kindTitle(place.kind) + " · " + LocationSettingsText.radius(place.radius))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if place.isPrivate {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Private"))
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                editingPlace = LocationPlaceDraft()
            } label: {
                Label("Add a place", systemImage: "plus")
            }
            .disabled(controller.places.count >= LocationSharingController.maxPlaces)
            .accessibilityIdentifier("settings.location.add-place")
            Text("Up to 20. Where they are stays on this iPhone: Hermes gets only their names, and at a private place only “at a private place”. Saved places need background sharing to report arriving and leaving.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Pause and history

    private var pauseSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Pause"), symbol: "pause.circle", tint: .orange) {
            if settings.isPaused(at: Date()) {
                Button {
                    Task { await controller.pause(until: nil); await loadFromHost() }
                } label: {
                    Label("Resume sharing", systemImage: "play.fill")
                }
            } else {
                Menu {
                    Button("For 1 hour") { pause(for: .hour) }
                    Button("Until tomorrow") { pause(for: .tomorrow) }
                    Button("Until I turn it back on") { pause(for: .indefinitely) }
                } label: {
                    Label("Pause sharing", systemImage: "pause.fill")
                }
                .accessibilityIdentifier("settings.location.pause")
            }
            Text("While paused nothing is sent, Hermes is told sharing is paused, and place rules don't run.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private enum PauseLength { case hour, tomorrow, indefinitely }

    private func pause(for length: PauseLength) {
        let now = Date()
        let until: Date
        switch length {
        case .hour:
            until = now.addingTimeInterval(3_600)
        case .tomorrow:
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            until = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .indefinitely:
            until = .distantFuture
        }
        Task { await controller.pause(until: until); await loadFromHost() }
    }

    private var retentionSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("History on the host"), symbol: "clock.arrow.circlepath", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: settings.retentionDays,
                choices: LocationSharingSettings.retentionChoices.map { (id: $0, title: LocationSettingsText.retentionTitle($0)) },
                onSelect: { days in Task { await controller.setRetention(days); await loadFromHost() } }
            ) {
                Text("Keep places visited for").foregroundStyle(.secondary)
            }
            Text("How long the host keeps the places you've been. Your latest position is always kept until you delete it; there is never a record of every position.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Maps

    private var mapsSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Maps"), symbol: "map", tint: .conduitAccent) {
            Toggle("Keep maps lookups on this iPhone", isOn: Binding(
                get: { !settings.mapsHost },
                set: { on in
                    Haptics.selection()
                    Task { await controller.setMapsHost(!on) }
                }
            ))
            .disabled(isWorking)
            .accessibilityIdentifier("settings.location.maps-on-iphone")
            Text("Hermes looks up places and routes only through this iPhone, never from your Hermes server. Lookups don't work while the iPhone can't be reached.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profilesSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Other profiles"), symbol: "person.2", tint: .conduitAccent) {
            Toggle("Share with this host's other profiles", isOn: Binding(
                get: { settings.otherProfiles },
                set: { on in
                    Haptics.selection()
                    Task { await controller.setOtherProfiles(on) }
                }
            ))
            .disabled(isWorking)
            .accessibilityIdentifier("settings.location.other-profiles")
            Text(AppLocalization.string("When this is on, other Hermes profiles on \(hostLabel) that are paired with this iPhone can read your location and ask for a fresh one. Place rules stay with \(controller.binding?.profile ?? appState.activeProfile)."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Live voice calls

    /// Which live voice modes may read the shared location on a call. Each
    /// is its own yes: what it reads goes to that mode's company.
    private var voiceSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Live voice calls"), symbol: "waveform", tint: .conduitAccent) {
            ForEach(LiveVoiceModeName.all, id: \.storageID) { mode in
                Toggle(isOn: voiceReadBinding(mode)) {
                    Text(verbatim: "\(mode.displayName) (\(mode.company))")
                }
                .accessibilityIdentifier("settings.location.voice.\(mode.storageID)")
            }
            if controller.isPaused() {
                Text("Nothing reads your location by voice while sharing is paused.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Let a live voice call read your location when you ask about it, straight from your Hermes host: the saved place you're at, your area and distances to your saved places, never coordinates. What it reads goes to the company that runs that voice mode, under its terms. Each read is listed under When Hermes read your location. Classic voice is Hermes itself and needs nothing here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func voiceReadBinding(_ mode: LiveVoiceModeName) -> Binding<Bool> {
        Binding(
            get: { controller.allowsVoiceRead(mode) },
            set: { on in
                if on {
                    askingVoiceMode = mode
                } else {
                    setVoiceRead(mode, allowed: false)
                }
            }
        )
    }

    private func setVoiceRead(_ mode: LiveVoiceModeName, allowed: Bool) {
        Haptics.selection()
        Task { await controller.setVoiceRead(mode, allowed: allowed) }
    }

    // MARK: From the host

    private var readsSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("When Hermes read your location"), symbol: "eye", tint: .conduitAccent) {
            if let hostStatus, !hostUnreachable {
                Text(AppLocalization.string("Reads in the last 24 hours: \(String(hostStatus.readsToday))"))
                    .font(.subheadline)
            }
            if hostUnreachable {
                // Shown over older rows too, so they don't pass as current.
                Text(AppLocalization.string("Couldn't reach the host."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if displayedReads.isEmpty {
                if !hostUnreachable {
                    Text("Hermes hasn't read your location yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(displayedReads.prefix(50)) { read in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocationSettingsText.readAction(read.action))
                            .font(.subheadline)
                        Text(readDetail(read))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Every time Hermes reads your location it's listed here, for 30 days. The list never holds the location itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The host's reads and this iPhone's voice maps lookups, newest first.
    private var displayedReads: [LocationRead] {
        guard !voiceMapReads.isEmpty else { return reads }
        // Each date parsed once; ties keep their order so rows don't swap.
        let dated = (reads + voiceMapReads).enumerated().map { (index: $0.offset, date: $0.element.date ?? .distantPast, read: $0.element) }
        return dated.sorted { $0.date != $1.date ? $0.date > $1.date : $0.index < $1.index }.map(\.read)
    }

    private func loadVoiceMapReads() {
        let formatter = ISO8601DateFormatter()
        voiceMapReads = HealthVoiceReadLog.load(key: HealthVoiceReadLog.locationStorageKey).entries.reversed().enumerated().map { index, entry in
            var read = LocationRead(at: formatter.string(from: entry.at), action: entry.action, sessionTitle: nil, platform: entry.modeName)
            // Apart from the host's reads and from each other.
            read.occurrence = 1_000 + index
            return read
        }
    }

    private func readDetail(_ read: LocationRead) -> String {
        var parts: [String] = []
        if let date = read.date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) } else { parts.append(read.at) }
        if let title = read.sessionTitle, !title.isEmpty { parts.append(title) }
        if let platform = read.platform, !platform.isEmpty { parts.append(platform) }
        return parts.joined(separator: " · ")
    }

    private var rulesSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Place rules"), symbol: "list.bullet.rectangle", tint: .conduitAccent) {
            if rules.isEmpty {
                Text("No place rules. Teach Hermes what to do at your places, for example: “When I get to the gym, remind me to log my workout.”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: rule.what)
                                .font(.subheadline)
                            Text(ruleDetail(rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            deleteRule(rule)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(Text(AppLocalization.string("Delete rule")))
                        .disabled(deletingRules.contains(rule.id))
                    }
                }
            }
        }
    }

    /// For example "Any saved place · arrive or leave · every time".
    private func ruleDetail(_ rule: LocationRule) -> String {
        var parts: [String] = []
        if rule.isAnySavedPlace {
            parts.append(AppLocalization.string("Any saved place"))
        } else if let name = rule.placeName, !name.isEmpty {
            parts.append(name)
        } else {
            parts.append(AppLocalization.string("A saved place"))
        }
        switch rule.event {
        case "arrive": parts.append(AppLocalization.string("arrive"))
        case "leave": parts.append(AppLocalization.string("leave"))
        case "either": parts.append(AppLocalization.string("arrive or leave"))
        default: if !rule.event.isEmpty { parts.append(rule.event) }
        }
        switch rule.repeatMode {
        case "daily": parts.append(AppLocalization.string("once a day"))
        case "every": parts.append(AppLocalization.string("every time"))
        default: break
        }
        if let days = rule.days { parts.append(days) }
        if let hours = rule.hours { parts.append(hours) }
        if rule.calls { parts.append(AppLocalization.string("Calls you")) }
        return parts.joined(separator: " · ")
    }

    private var actionSection: some View {
        VStack(spacing: 10) {
            Button {
                showsWipe = true
            } label: {
                Label(AppLocalization.string("Delete location data on \(controller.binding?.host ?? hostLabel)"), systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6).frame(minHeight: 48)
            }
            .disabled(isWorking)
            .conduitGlassControl(cornerRadius: 17, tint: .red.opacity(0.18), prominent: false)
            .accessibilityIdentifier("settings.location.wipe")
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Actions

    private func loadFromHost() async {
        loadVoiceMapReads()
        guard controller.binding != nil, let request = await controller.hostRequest() else {
            hostUnreachable = controller.binding != nil
            return
        }
        do {
            // A device id the host would refuse isn't asked about.
            let deviceID = controller.config.deviceID
            if LocationIDs.isValidWireID(deviceID) {
                hostStatus = try await controller.engine.status(deviceID: deviceID, request: request)
            } else {
                hostStatus = nil
            }
            reads = try await controller.engine.reads(request: request)
            rules = try await controller.engine.rules(request: request)
            hostUnreachable = false
        } catch {
            hostUnreachable = true
        }
    }

    private func turnOn(_ layer: LocationSharingController.Layer) {
        guard let destination = appState.locationDestination else {
            errorMessage = LocationSharingError.noDashboard.errorDescription
            return
        }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await controller.turnOn(layer, destination: destination, otherProfiles: consentOffersProfiles)
                // A first turn-on was just bound: store the host pass now, so
                // a locate or background send doesn't wait for a reconnect.
                await appState.locationHostConnected()
                Haptics.success()
                await loadFromHost()
            } catch {
                errorMessage = Self.bannerMessage(for: error)
                Haptics.error()
            }
            isWorking = false
        }
    }

    /// The banner under the settings when turning sharing on, deleting a
    /// rule or deleting location data fails: what happened and what to do,
    /// never NSURLErrorDomain text.
    static func bannerMessage(for error: Error) -> String {
        UserFacingError.message(for: error)
    }

    private func deleteRule(_ rule: LocationRule) {
        guard !deletingRules.contains(rule.id) else { return }
        deletingRules.insert(rule.id)
        Task {
            defer { deletingRules.remove(rule.id) }
            guard let request = await controller.hostRequest() else {
                errorMessage = LocationSharingError.noDashboard.errorDescription
                return
            }
            do {
                try await controller.engine.deleteRule(rule.id, request: request)
                rules.removeAll { $0.id == rule.id }
            } catch {
                errorMessage = Self.bannerMessage(for: error)
            }
        }
    }

    private func wipe(everything: Bool) {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await controller.wipe(everything: everything)
                reads = []
                if everything { rules = [] }
                Haptics.success()
                await loadFromHost()
            } catch {
                errorMessage = Self.bannerMessage(for: error)
            }
            isWorking = false
        }
    }
}

/// What the user agrees to before iOS asks for location permission. App
/// Review 5.1.2(i) asks for this before personal data reaches a third-party AI.
struct LocationSharingConsentSheet: View {
    let profile: String
    let host: String
    let isHermesCloud: Bool
    /// Turning on also shares with the host's other profiles paired with
    /// this iPhone.
    let otherProfiles: Bool
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "location.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("Share your location with Hermes?")
                        .font(.title2.weight(.semibold))
                    Label(AppLocalization.string("Conduit sends your location, at the detail you choose, to the \(profile) profile on \(host), sealed end to end. It never goes through Conduit's notification relay, and Conduit's developer can't see it."), systemImage: "lock.shield")
                    if otherProfiles {
                        Label(AppLocalization.string("Other Hermes profiles on \(host) that are paired with this iPhone can read it too. You can turn this off in Settings > Location."), systemImage: "person.2")
                    }
                    Label("Your iPhone's time zone is always sent too, at every level of detail, so Hermes knows your local time. At Area and Precise, so are distances to your saved places, except private ones.", systemImage: "clock")
                    Label("Your agent reads it when you ask, or when a task or place rule needs it. Whatever it reads goes to the AI model provider your Hermes uses, under that provider's terms.", systemImage: "sparkles")
                    if isHermesCloud {
                        Label("This Hermes runs on Hermes Cloud, so Nous Research hosts what Conduit sends.", systemImage: "cloud")
                            .foregroundStyle(.orange)
                    } else {
                        Label("If your Hermes is hosted by someone else, such as Hermes Cloud, they can read it too.", systemImage: "cloud")
                    }
                    Label("Every read is listed in Settings > Location. You can pause sharing, turn it off and delete what was sent at any time.", systemImage: "eye")
                    Label("Your location is never used for advertising and isn't stored in iCloud by Conduit.", systemImage: "hand.raised")
                }
                .font(.subheadline)
                .padding(20)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(action: accept) {
                        Text("Continue")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6).frame(minHeight: 48)
                            .foregroundStyle(Color.white)
                    }
                    .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent, prominent: true)
                    .accessibilityIdentifier("settings.location.consent.continue")
                    Button("Cancel", action: cancel)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .presentationDetents([.large])
    }
}

/// A saved place being added or edited.
struct LocationPlaceDraft: Identifiable {
    let id: String
    var isNew: Bool
    var name: String
    var kind: LocationPlaceKind
    var isPrivate: Bool
    var coordinate: CLLocationCoordinate2D?
    var radius: Double

    init() {
        id = LocationSavedPlace.newID()
        isNew = true
        name = ""
        kind = .home
        isPrivate = false
        coordinate = nil
        radius = LocationSavedPlace.defaultRadius
    }

    init(_ place: LocationSavedPlace) {
        id = place.id
        isNew = false
        name = place.name
        kind = place.kind
        isPrivate = place.isPrivate
        coordinate = place.coordinate
        radius = place.radius
    }

    var place: LocationSavedPlace? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let coordinate, !trimmed.isEmpty else { return nil }
        return LocationSavedPlace(id: id, name: trimmed, kind: kind, isPrivate: isPrivate,
                                  latitude: coordinate.latitude, longitude: coordinate.longitude, radius: radius)
    }
}

/// Adds or edits a saved place: the current position or an address found
/// with Apple Maps search, a name, a kind, a radius and Private.
struct LocationPlaceEditor: View {
    @State var draft: LocationPlaceDraft
    let canLocate: Bool
    let save: (LocationSavedPlace) -> Void
    let delete: (String) -> Void
    let cancel: () -> Void
    let locate: () async -> CLLocation?

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var isLocating = false
    @State private var message: String?
    @State private var camera: MapCameraPosition = .automatic

    init(draft: LocationPlaceDraft, canLocate: Bool, save: @escaping (LocationSavedPlace) -> Void,
         delete: @escaping (String) -> Void, cancel: @escaping () -> Void, locate: @escaping () async -> CLLocation?) {
        _draft = State(initialValue: draft)
        self.canLocate = canLocate
        self.save = save
        self.delete = delete
        self.cancel = cancel
        self.locate = locate
        if let coordinate = draft.coordinate {
            _camera = State(initialValue: .region(MKCoordinateRegion(center: MapDatum.toMap(coordinate), latitudinalMeters: 1_200, longitudinalMeters: 1_200)))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .onChange(of: draft.name) { _, name in
                            if name.count > LocationSavedPlace.maxNameLength { draft.name = String(name.prefix(LocationSavedPlace.maxNameLength)) }
                        }
                    Picker("Kind", selection: $draft.kind) {
                        ForEach(LocationPlaceKind.allCases) { kind in
                            Text(LocationSettingsText.kindTitle(kind)).tag(kind)
                        }
                    }
                    Toggle("Private", isOn: $draft.isPrivate)
                } footer: {
                    Text("At a private place Hermes hears only “at a private place”, never its name or where it is, and your visits there aren't kept.")
                }
                Section {
                    if let coordinate = draft.coordinate.map(MapDatum.toMap) {
                        // The draft is WGS-84 like the fixes; the map draws it where Apple Maps puts it.
                        Map(position: $camera) {
                            MapCircle(center: coordinate, radius: draft.radius)
                                .foregroundStyle(Color.blue.opacity(0.2))
                                .stroke(Color.blue, lineWidth: 1)
                            Marker(draft.name, coordinate: coordinate)
                        }
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                        // The caption below says the radius; the map adds nothing for VoiceOver.
                        .accessibilityHidden(true)
                    }
                    if canLocate {
                        Button {
                            useCurrentLocation()
                        } label: {
                            Label(isLocating ? AppLocalization.string("Finding you…") : AppLocalization.string("Use my current location"), systemImage: "location.fill")
                        }
                        .disabled(isLocating)
                    }
                    TextField("Search for an address", text: $query)
                        .textInputAutocapitalization(.words)
                        .onSubmit(search)
                    if isSearching { ProgressView() }
                    ForEach(results, id: \.self) { item in
                        Button {
                            choose(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.name ?? "")
                                Text(verbatim: item.placemark.title ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Where")
                }
                Section {
                    Slider(value: $draft.radius, in: LocationSavedPlace.minRadius...LocationSavedPlace.maxRadius, step: 25)
                        .accessibilityLabel(Text("Radius"))
                        .accessibilityValue(Text(verbatim: LocationSettingsText.radius(draft.radius)))
                    Text(AppLocalization.string("Radius: \(LocationSettingsText.radius(draft.radius))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Arriving and leaving count once you cross this circle. A larger circle notices you sooner but can miss short visits.")
                }
                if !draft.isNew {
                    Section {
                        Button("Delete place", role: .destructive) { delete(draft.id) }
                    }
                }
            }
            .navigationTitle(draft.isNew ? AppLocalization.string("Add a place") : AppLocalization.string("Edit place"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let place = draft.place { save(place) }
                    }
                    .disabled(draft.place == nil)
                }
            }
        }
    }

    private func setCoordinate(_ coordinate: CLLocationCoordinate2D) {
        draft.coordinate = coordinate
        camera = .region(MKCoordinateRegion(center: MapDatum.toMap(coordinate), latitudinalMeters: 1_200, longitudinalMeters: 1_200))
    }

    private func useCurrentLocation() {
        isLocating = true
        message = nil
        Task {
            if let location = await locate() {
                setCoordinate(location.coordinate)
            } else {
                message = AppLocalization.string("Couldn't find your position. Try searching for the address.")
            }
            isLocating = false
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSearching = true
        message = nil
        Task {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = text
            do {
                results = Array(try await MKLocalSearch(request: request).start().mapItems.prefix(8))
                if results.isEmpty { message = AppLocalization.string("No matches.") }
            } catch {
                results = []
                message = AppLocalization.string("Couldn't search Apple Maps. Try again.")
            }
            isSearching = false
        }
    }

    private func choose(_ item: MKMapItem) {
        // In mainland China Apple Maps answers in GCJ-02; the place is kept in WGS-84 like the fixes (#1122).
        setCoordinate(MapDatum.fromMap(item.placemark.coordinate))
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let name = item.name {
            draft.name = String(name.prefix(LocationSavedPlace.maxNameLength))
        }
        results = []
    }
}
