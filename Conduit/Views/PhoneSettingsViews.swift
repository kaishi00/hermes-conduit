//
//  PhoneSettingsViews.swift
//  Conduit
//
//  Settings > Calendar & phone: opt-in sharing of the calendar, reminders,
//  Focus and phone status with one Hermes profile, and how Hermes' calendar
//  changes are handled. Also the card that asks the user about a change
//  Hermes wants, and the banner after one went in without asking.
//

import SwiftUI
import UIKit

struct PhoneSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var engine: PhoneSyncEngine
    @ObservedObject var appLanguage = AppLanguageStore.shared

    @State private var choices = PhoneSyncPreferences(calendar: .full, reminders: true, status: true, focus: true)
    @State private var loadedPreferences = false
    @State private var showsConsent = false
    @State private var showsTurnOff = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var calendars: [PhoneCalendarRow] = []
    @State private var showsCalendars = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The voice mode whose switch is waiting on the user's yes.
    @State private var askingVoiceMode: LiveVoiceModeName?
    /// Loaded on appear (loading prunes and saves).
    @State private var voiceUses = HealthVoiceReadLog()

    private var preferences: PhoneSyncPreferences { engine.preferences }
    private var pluginServes: Bool { appState.notifierPlugin.reports(AppState.phoneSyncCapability) }
    /// An older plugin takes no alarms or people: their switches wait for it.
    /// A switch left on stays visible so it can be turned off.
    private var showsAlarms: Bool {
        (engine.alarmSource.isSupported || choices.alarms)
            && (appState.notifierPlugin.reports(AppState.phoneAlarmsCapability) || choices.alarms)
    }
    private var showsPeople: Bool {
        appState.notifierPlugin.reports(AppState.phoneContactsCapability) || choices.contacts
    }

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Calendar & phone for Hermes"), symbol: "calendar", tint: .red) {
                Text("Share your calendar, reminders, Focus and phone status with Hermes so your agent can plan around your day, keep your reminders and pick good moments to reach you. It goes straight from this iPhone to your Hermes host, sealed end to end, and never through Conduit's notification relay.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                if preferences.isOn {
                    statusRows
                } else if !pluginServes {
                    Text("Update the Conduit plugin on your Hermes host to share your calendar and phone status.")
                        .scaledFont(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if preferences.isOn || pluginServes {
                calendarSection
                if choices.takesChanges { changesSection }
                phoneSection
                if showsAlarms { alarmsSection }
                if showsPeople { peopleSection }
                if preferences.isOn { voiceSection }
                actionSection
            }
        }
        .navigationTitle("Calendar & phone")
        // Sharing turns on after its consent sheet, so the rows it reveals
        // animate on the value rather than in a setter.
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: preferences.isOn)
        .onAppear(perform: load)
        .sheet(isPresented: $showsConsent) {
            PhoneSharingConsentSheet(profile: appState.activeProfile, host: hostLabel) {
                showsConsent = false
                turnOn()
            } cancel: {
                showsConsent = false
            }
        }
        .confirmationDialog(
            Text(AppLocalization.string("Let \(askingVoiceMode?.displayName ?? "") use your calendar and reminders?")),
            isPresented: Binding(get: { askingVoiceMode != nil }, set: { if !$0 { askingVoiceMode = nil } }),
            titleVisibility: .visible,
            presenting: askingVoiceMode
        ) { mode in
            Button("Allow") { setVoiceUse(mode, allowed: true) }
            Button("Cancel", role: .cancel) {}
        } message: { mode in
            Text(AppLocalization.string("On a call, what it reads goes to \(mode.company) under its terms. You can turn this off at any time."))
        }
        .confirmationDialog("Turn off sharing?", isPresented: $showsTurnOff, titleVisibility: .visible) {
            Button("Turn off and delete from the host", role: .destructive) { turnOff(delete: true) }
            Button("Turn off, keep data on the host") { turnOff(delete: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Conduit stops sending your calendar, reminders, Focus and phone status, and Hermes can't ask for calendar changes. Deleting removes what this iPhone sent from the host.")
        }
    }

    private var hostLabel: String {
        if let host = appState.connection?.baseUrl, let url = URL(string: host), let name = url.host { return name }
        return appState.connection?.baseUrl ?? ""
    }

    // MARK: Status

    @ViewBuilder
    private var statusRows: some View {
        if let destination = preferences.destination {
            Label(AppLocalization.string("Sharing with \(destination.profile) on \(destination.host)"), systemImage: "checkmark.shield")
                .scaledFont(.subheadline)
        }
        if engine.isSyncing {
            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        } else if let pause = engine.state.pause {
            Text(pause.message)
                .scaledFont(.caption)
                .foregroundStyle(.orange)
        } else if let last = engine.state.lastSync {
            Text(AppLocalization.string("Last synced \(last.formatted(.relative(presentation: .named)))"))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Not synced yet.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        if let error = engine.lastError, engine.state.pause == nil {
            Text(error)
                .scaledFont(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: Calendar and reminders

    private var calendarSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Calendar and reminders"), symbol: "calendar", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: choices.calendar,
                choices: PhoneCalendarAccess.allCases.map { (id: $0, title: $0.title) },
                onSelect: { binding(\.calendar).wrappedValue = $0 }
            ) {
                Text("Calendar").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settings.phone.calendar")
            Text(calendarCaption)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            if choices.calendar.reads {
                ConduitMenuPicker(
                    value: choices.window,
                    choices: PhoneCalendarWindow.allCases.map { (id: $0, title: $0.title) },
                    onSelect: { binding(\.window).wrappedValue = $0 }
                ) {
                    Text("Share").foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: binding(\.reminders)) {
                Label("Reminders", systemImage: "checklist")
            }
            .accessibilityIdentifier("settings.phone.reminders")
            if choices.reminders {
                Toggle("Read only", isOn: binding(\.remindersReadOnly))
                    .scaledFont(.subheadline)
                    .padding(.leading, 28)
                    .accessibilityLabel(Text("Reminders read only"))
                    .accessibilityHint(Text(AppLocalization.string("Hermes reads your reminders but can't add, change, complete or delete any.")))
                    .accessibilityIdentifier("settings.phone.reminders-read-only")
                Text(choices.remindersReadOnly
                     ? AppLocalization.string("Hermes reads your reminders but can't add, change, complete or delete any.")
                     : AppLocalization.string("Hermes reads your reminders and can ask to add, change or complete them."))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
            if choices.calendar.reads || choices.reminders {
                Toggle("Include notes and attendees", isOn: binding(\.details))
                if choices.details, choices.calendar.reads {
                    Toggle("Include attendees' email addresses", isOn: binding(\.attendeeEmails))
                        .scaledFont(.subheadline)
                        .padding(.leading, 28)
                }
                Text("Without these, Hermes gets titles, times, places and lists, not what's written in notes or who's invited.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if preferences.isOn, !calendars.isEmpty {
                // Not a DisclosureGroup: outside a List it indents its rows
                // without narrowing them, so their switches ran off the card.
                Button {
                    withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { showsCalendars.toggle() }
                } label: {
                    HStack {
                        Text(verbatim: AppLocalization.string("Calendars and lists"))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .scaledFont(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsCalendars ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(showsCalendars ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed")))
                .accessibilityIdentifier("settings.phone.calendars")
                if showsCalendars {
                    ForEach(calendars) { row in
                        Toggle(isOn: calendarBinding(row)) {
                            Text(row.title)
                        }
                        .scaledFont(.subheadline)
                    }
                }
            }
        }
    }

    private var calendarCaption: String {
        switch choices.calendar {
        case .full:
            return AppLocalization.string("Hermes reads events from the last week and the time ahead you choose, and can ask to add or change them.")
        case .readOnly:
            return AppLocalization.string("Hermes reads events from the last week and the time ahead you choose, but can't add, change or delete any. Good for calendars you share with other people.")
        case .writeOnly:
            return AppLocalization.string("Hermes can ask to add events but can't read your calendar.")
        case .off:
            return AppLocalization.string("Hermes doesn't see your calendar.")
        }
    }

    private var changesSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Changes from Hermes"), symbol: "calendar.badge.plus", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: choices.autoAdd,
                choices: [
                    (id: false, title: AppLocalization.string("Ask me each time")),
                    (id: true, title: AppLocalization.string("Add without asking"))
                ],
                onSelect: { binding(\.autoAdd).wrappedValue = $0 }
            ) {
                Text("New events and reminders").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settings.phone.auto-add")
            Text("Hermes always asks before it changes or deletes anything. Without asking, new items go in when Conduit next runs, with Undo. In a voice call, Hermes asks you out loud.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var phoneSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Focus and phone status"), symbol: "iphone", tint: .conduitAccent) {
            Toggle(isOn: binding(\.focus)) {
                Label("Focus", systemImage: "moon")
            }
            .accessibilityIdentifier("settings.phone.focus")
            Text("Add Conduit to a Focus in Settings > Focus > Focus Filters, give it a name for Hermes such as Work, and choose whether Hermes holds its calls while it's on.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            Toggle(isOn: binding(\.status)) {
                Label("Phone status", systemImage: "battery.75percent")
            }
            .accessibilityIdentifier("settings.phone.status")
            Text("Battery and charging, whether CarPlay or headphones are connected, Wi-Fi or cellular, and whether you're walking, driving or still. Only the latest state is kept.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Alarms and people

    private var alarmsSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Alarms and timers"), symbol: "alarm", tint: .conduitAccent) {
            Toggle(isOn: binding(\.alarms)) {
                Label("Let Hermes set alarms and timers", systemImage: "alarm")
            }
            .accessibilityIdentifier("settings.phone.alarms")
            Text("They ring like the Clock app's, even in Silent mode or a Focus. Hermes asks each time unless new items go in without asking, and always asks before cancelling one. Hermes sees only the alarms it set.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var peopleSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("People"), symbol: "person.2", tint: .conduitAccent) {
            Toggle(isOn: binding(\.contacts)) {
                Label("Share the people you pick", systemImage: "person.2")
            }
            .accessibilityIdentifier("settings.phone.contacts")
            Text("Pick the people Hermes should know, and say who they are to you, such as wife or boss, so \"text my wife\" or \"Mum's birthday\" just works. Hermes gets their name, phone numbers, email addresses and birthday. Conduit doesn't read your contacts: only the people you pick here.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            Text("Their nickname and company go too, when the contact has them.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            if appState.pulseBringsUpBirthdays {
                Text("With Pulse and its memory on, it brings up their birthdays two weeks ahead, the day before and on the day.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if choices.contacts {
                ForEach(engine.people) { person in
                    PhonePersonRow(person: person) { relation in
                        var people = engine.people
                        guard let index = people.firstIndex(where: { $0.id == person.id }) else { return }
                        people[index].relation = relation.isEmpty ? nil : String(relation.prefix(PhonePerson.relationLength))
                        engine.savePeople(people)
                        syncPeople()
                    } remove: {
                        Haptics.selection()
                        engine.savePeople(engine.people.filter { $0.id != person.id })
                        syncPeople()
                    }
                }
                Button {
                    Haptics.selection()
                    PhoneContactPicker.present { contacts in
                        let picked = contacts.compactMap { PhonePerson(contact: $0) }
                        engine.savePeople(PhonePeopleStore.merging(picked, into: engine.people))
                        syncPeople()
                    }
                } label: {
                    Label("Add people", systemImage: "person.badge.plus")
                }
                .disabled(engine.people.count >= PhonePerson.maximum)
                .accessibilityIdentifier("settings.phone.contacts.add")
            }
        }
    }

    private func syncPeople() {
        guard preferences.isOn, preferences.contacts else { return }
        Task { await appState.runPhoneSync(reason: .manual) }
    }

    // MARK: Voice

    /// Which live voice modes may use the calendar and phone on a call. Each
    /// is its own yes: what it reads goes to that mode's company.
    private var voiceSection: some View {
        ConduitSettingsSection(title: AppLocalization.string("Live voice calls"), symbol: "waveform", tint: .conduitAccent) {
            ForEach(LiveVoiceModeName.all, id: \.storageID) { mode in
                Toggle(isOn: voiceBinding(mode)) {
                    Text(verbatim: "\(mode.displayName) (\(mode.company))")
                }
                .accessibilityIdentifier("settings.phone.voice.\(mode.storageID)")
            }
            Text("Let a live voice call read what you share here when you ask, add events and reminders you ask for, and ask you out loud about Hermes' changes. What it reads goes to the company that runs that voice mode, under its terms. Classic voice is Hermes itself and needs nothing here.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            if !voiceUses.entries.isEmpty {
                Text("Read by voice in the last 7 days")
                    .scaledFont(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(voiceUses.entries.suffix(20).reversed()) { entry in
                    HStack {
                        Text(verbatim: "\(entry.modeName): \(entry.action)")
                        Spacer()
                        Text(entry.at.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                    .scaledFont(.caption)
                }
            }
        }
    }

    private func voiceBinding(_ mode: LiveVoiceModeName) -> Binding<Bool> {
        Binding(
            get: { preferences.letsVoiceUse(mode) },
            set: { on in
                if on {
                    askingVoiceMode = mode
                } else {
                    setVoiceUse(mode, allowed: false)
                }
            }
        )
    }

    private func setVoiceUse(_ mode: LiveVoiceModeName, allowed: Bool) {
        Haptics.selection()
        appState.setPhoneVoiceUse(mode, allowed: allowed)
    }

    private var actionSection: some View {
        VStack(spacing: 10) {
            if preferences.isOn {
                Button {
                    Haptics.selection()
                    Task {
                        await appState.runPhoneSync(reason: .manual)
                        errorMessage = appState.dashboardTicketBridge == nil || appState.activeDashboardID == nil
                            ? DashboardTicketBridgeError.notReady.errorDescription : nil
                        loadCalendars()
                    }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 48)
                }
                .disabled(engine.isSyncing || isWorking)
                .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent.opacity(0.18))
                .accessibilityIdentifier("settings.phone.sync-now")
                Button {
                    showsTurnOff = true
                } label: {
                    Label("Turn off sharing", systemImage: "calendar.badge.minus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 48)
                }
                .disabled(isWorking)
                .conduitGlassControl(cornerRadius: 17, tint: .red.opacity(0.18), prominent: false)
                .accessibilityIdentifier("settings.phone.turn-off")
            } else {
                Button {
                    Haptics.selection()
                    showsConsent = true
                } label: {
                    Label(isWorking ? AppLocalization.string("Turning on…") : AppLocalization.string("Turn on sharing"), systemImage: "calendar")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 48)
                        .foregroundStyle(Color.white)
                }
                .disabled(!choices.sharesAnything || isWorking || appState.activeDashboardID == nil)
                .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent, prominent: true)
                .accessibilityIdentifier("settings.phone.turn-on")
            }
            if let errorMessage {
                Text(errorMessage)
                    .scaledFont(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<PhoneSyncPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { choices[keyPath: keyPath] },
            set: { value in
                var next = choices
                next[keyPath: keyPath] = value
                if preferences.isOn && !next.sharesAnything {
                    showsTurnOff = true
                    return
                }
                // Animated: Reminders and the details switch reveal rows.
                withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { choices = next }
                applyIfOn()
            }
        )
    }

    /// A calendar or list is shared unless the user left it out; the list
    /// has hashed ids, so it's matched the way the engine hashes them.
    private func calendarBinding(_ row: PhoneCalendarRow) -> Binding<Bool> {
        let eventKitID = row.eventKitID
        return Binding(
            get: { eventKitID.map { !choices.hiddenCalendars.contains($0) } ?? true },
            set: { shown in
                guard let eventKitID else { return }
                if shown { choices.hiddenCalendars.remove(eventKitID) } else { choices.hiddenCalendars.insert(eventKitID) }
                applyIfOn()
            }
        )
    }

    // MARK: Actions

    private func load() {
        voiceUses = HealthVoiceReadLog.load(key: HealthVoiceReadLog.phoneStorageKey)
        guard !loadedPreferences else { return }
        loadedPreferences = true
        if preferences.isOn { choices = preferences }
        loadCalendars()
    }

    private func loadCalendars() {
        guard preferences.isOn else { return }
        let source = engine.calendarSource
        // EventKit ids are looked up once here, not on every redraw.
        calendars = source.calendars(eventsReadable: source.eventAccess == .full, reminders: source.remindersAuthorized)
            .compactMap { entry in
                guard let id = entry["id"] as? String else { return nil }
                return PhoneCalendarRow(id: id, title: entry["title"] as? String ?? "",
                                        eventKitID: source.eventKitCalendarID(forShared: id))
            }
    }

    private func applyIfOn() {
        guard preferences.isOn else { return }
        let choices = choices
        Task {
            do {
                try await appState.updatePhoneSync(choices)
                errorMessage = nil
                loadCalendars()
            } catch {
                errorMessage = PhoneSyncEngine.describe(error)
                // Not applied (a permission was refused): show what's in effect.
                if preferences.isOn { self.choices = preferences }
            }
        }
    }

    private func turnOn() {
        isWorking = true
        errorMessage = nil
        let choices = choices
        Task {
            do {
                try await appState.turnOnPhoneSync(choices)
                // What was saved: a no to alarms leaves that switch off.
                self.choices = preferences
                Haptics.success()
                loadCalendars()
            } catch {
                errorMessage = PhoneSyncEngine.describe(error)
                Haptics.error()
            }
            isWorking = false
        }
    }

    private func turnOff(delete: Bool) {
        isWorking = true
        errorMessage = nil
        Task {
            let done = await appState.turnOffPhoneSync(deleteFromHost: delete)
            if !done {
                errorMessage = AppLocalization.string("Sharing is off. The host couldn't be reached, so Conduit deletes the data there the next time it connects.")
            }
            choices = PhoneSyncPreferences(calendar: .full, reminders: true, status: true, focus: true)
            voiceUses = HealthVoiceReadLog()
            calendars = []
            isWorking = false
        }
    }
}

/// One picked person in Settings: who they are to the user, editable.
struct PhonePersonRow: View {
    let person: PhonePerson
    let save: (String) -> Void
    let remove: () -> Void
    @State private var relation = ""

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name)
                    .scaledFont(.subheadline)
                TextField("Who they are to you", text: $relation)
                    .scaledFont(.caption)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .accessibilityLabel(Text(AppLocalization.string("Relation to \(person.name)")))
                    .onSubmit { save(relation.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            Spacer(minLength: 4)
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(AppLocalization.string("Remove \(person.name)")))
        }
        .onAppear { relation = person.relation ?? "" }
        .onChange(of: person.relation) { _, value in relation = value ?? "" }
        .onChange(of: relation) { _, value in
            // No longer than the host keeps.
            if value.count > PhonePerson.relationLength { relation = String(value.prefix(PhonePerson.relationLength)) }
        }
        .onDisappear {
            let typed = relation.trimmingCharacters(in: .whitespacesAndNewlines)
            if typed != (person.relation ?? "") { save(typed) }
        }
    }
}

/// What the user agrees to before anything leaves the phone (App Review 5.1.2(i)).
struct PhoneSharingConsentSheet: View {
    let profile: String
    let host: String
    let accept: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "calendar")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text("Share your calendar and phone with Hermes?")
                        .scaledFont(.title2.weight(.semibold))
                    Label(AppLocalization.string("Conduit sends what you chose to the \(profile) profile on \(host), sealed end to end. It never goes through Conduit's notification relay, and Conduit's developer can't see it."), systemImage: "lock.shield")
                    Label("Your agent reads it when you ask, or when a task you set up needs it. Whatever it reads goes to the AI model provider your Hermes uses, under that provider's terms. If your Hermes is hosted by someone else, such as Hermes Cloud, they can read it too.", systemImage: "sparkles")
                    Label("Events can include other people's names. Notes, attendees and email addresses stay on this iPhone unless you turn them on.", systemImage: "person.2")
                    Label("Hermes can only ask for calendar changes. You approve each one unless you choose to let new items in without asking, and changes or deletions always ask.", systemImage: "hand.raised")
                    Label("Alarms and timers Hermes sets ring even in Silent mode or a Focus. People are shared only if you pick them.", systemImage: "alarm")
                    Label("You can turn sharing off at any time in Settings > Calendar & phone and delete what was sent from the host.", systemImage: "calendar.badge.minus")
                }
                .scaledFont(.subheadline)
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
                    .accessibilityIdentifier("settings.phone.consent.continue")
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

// MARK: - Changes from Hermes

/// What a change does, in words, for the card and for voice.
enum PhoneChangeWording {
    static func headline(_ change: PhoneChange) -> String {
        switch change.kind {
        case .addEvent: return AppLocalization.string("Hermes wants to add an event")
        case .updateEvent: return AppLocalization.string("Hermes wants to change an event")
        case .deleteEvent: return AppLocalization.string("Hermes wants to delete an event")
        case .addReminder: return AppLocalization.string("Hermes wants to add a reminder")
        case .updateReminder: return AppLocalization.string("Hermes wants to change a reminder")
        case .completeReminder:
            return change.fields.completed == false
                ? AppLocalization.string("Hermes wants to reopen a reminder")
                : AppLocalization.string("Hermes wants to mark a reminder done")
        case .deleteReminder: return AppLocalization.string("Hermes wants to delete a reminder")
        case .setAlarm: return AppLocalization.string("Hermes wants to set an alarm")
        case .setTimer: return AppLocalization.string("Hermes wants to start a timer")
        case .cancelAlarm: return AppLocalization.string("Hermes wants to cancel an alarm")
        }
    }

    /// An alarm or timer in a line: "Wake up · 06:30 weekdays", "Pasta · 10 min".
    static func alarmSummary(_ fields: PhoneChangeFields, kind: PhoneChange.Kind) -> String {
        var parts: [String] = []
        if let label = fields.label { parts.append(label) }
        if kind == .setTimer, let seconds = fields.seconds {
            parts.append(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
        } else if let at = fields.at {
            parts.append(at.formatted(date: .abbreviated, time: .shortened))
        } else if let time = fields.time {
            let clock = Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date())
                .map { $0.formatted(date: .omitted, time: .shortened) } ?? time.text
            parts.append([clock, days(fields.repeats)].compactMap { $0 }.joined(separator: " "))
        }
        if parts.isEmpty {
            parts.append(kind == .setTimer ? AppLocalization.string("Timer") : AppLocalization.string("Alarm"))
        }
        return parts.joined(separator: " · ")
    }

    /// The days a repeating alarm rings, in words.
    static func days(_ repeats: [String]?) -> String? {
        guard let repeats, !repeats.isEmpty else { return nil }
        let set = Set(repeats)
        if set.count == 7 { return AppLocalization.string("every day") }
        if set == ["mon", "tue", "wed", "thu", "fri"] { return AppLocalization.string("weekdays") }
        if set == ["sat", "sun"] { return AppLocalization.string("weekends") }
        let symbols = Calendar.current.shortWeekdaySymbols
        return PhoneChangeFields.weekdays.enumerated().compactMap { index, day in
            // shortWeekdaySymbols starts on Sunday.
            set.contains(day) ? symbols[(index + 1) % 7] : nil
        }.joined(separator: ", ")
    }

    /// The item's title and time, as far as the change says.
    static func detail(_ change: PhoneChange) -> String {
        if change.kind == .setAlarm || change.kind == .setTimer { return alarmSummary(change.fields, kind: change.kind) }
        var parts: [String] = []
        if let title = change.fields.title, !title.isEmpty { parts.append(title) }
        let allDay = change.fields.allDay ?? false
        if let start = change.fields.start {
            if allDay {
                parts.append(start.formatted(date: .abbreviated, time: .omitted))
            } else if let end = change.fields.end {
                parts.append(start.formatted(date: .abbreviated, time: .shortened) + "–" + end.formatted(date: .omitted, time: .shortened))
            } else {
                parts.append(start.formatted(date: .abbreviated, time: .shortened))
            }
        }
        if let due = change.fields.due {
            let dueAllDay = change.fields.dueAllDay ?? (change.fields.dueText?.count == 10)
            parts.append(dueAllDay ? due.formatted(date: .abbreviated, time: .omitted) : due.formatted(date: .abbreviated, time: .shortened))
        }
        if let location = change.fields.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    static func approveTitle(_ change: PhoneChange) -> String {
        switch change.kind {
        case .addEvent, .addReminder: return AppLocalization.string("Add")
        case .deleteEvent, .deleteReminder: return AppLocalization.string("Delete")
        case .completeReminder: return AppLocalization.string("Mark done")
        case .updateEvent, .updateReminder: return AppLocalization.string("Change")
        case .setAlarm: return AppLocalization.string("Set")
        case .setTimer: return AppLocalization.string("Start")
        case .cancelAlarm: return AppLocalization.string("Cancel alarm")
        }
    }

    static func symbol(_ kind: PhoneChange.Kind) -> String {
        if kind == .setTimer { return "timer" }
        if kind.isAlarm { return "alarm" }
        return kind.isEvent ? "calendar.badge.plus" : "checklist"
    }

    /// Changes whose approve button is the red one.
    static func isRemoval(_ kind: PhoneChange.Kind) -> Bool {
        kind == .deleteEvent || kind == .deleteReminder || kind == .cancelAlarm
    }
}

/// The card over the app for the oldest change waiting on the user.
struct PhoneChangeCard: View {
    let prompt: PhoneChangePrompt
    let waiting: Int
    let answer: (Bool) -> Void

    var body: some View {
        let change = prompt.change
        VStack(alignment: .leading, spacing: 10) {
            Label(PhoneChangeWording.headline(change), systemImage: PhoneChangeWording.symbol(change.kind))
                .scaledFont(.subheadline.weight(.semibold))
            let detail = prompt.alarmTitle ?? PhoneChangeWording.detail(change)
            if !detail.isEmpty {
                Text(detail)
                    .scaledFont(.subheadline)
            }
            if let calendar = prompt.calendarTitle, change.kind.isAddition {
                Text(AppLocalization.string("In \(calendar)"))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = change.reason, !reason.isEmpty {
                Text(reason)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    Haptics.selection()
                    answer(false)
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 40)
                }
                .conduitGlassControl(cornerRadius: 14, tint: .secondary.opacity(0.15), prominent: false)
                .accessibilityIdentifier("phone.change.dismiss")
                Button(role: PhoneChangeWording.isRemoval(change.kind) ? .destructive : nil) {
                    Haptics.success()
                    answer(true)
                } label: {
                    Text(PhoneChangeWording.approveTitle(change))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 40)
                        .foregroundStyle(Color.white)
                }
                .conduitGlassControl(cornerRadius: 14, tint: PhoneChangeWording.isRemoval(change.kind) ? .red : .conduitAccent, prominent: true)
                .accessibilityIdentifier("phone.change.approve")
            }
            if waiting > 1 {
                Text(AppLocalization.string("\(Int(waiting - 1)) more waiting"))
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }
}

/// One calendar or reminder list in Settings, by its shared id.
struct PhoneCalendarRow: Identifiable {
    let id: String
    let title: String
    let eventKitID: String?
}

/// Shown after an addition went in without asking, with Undo.
struct PhoneAutoAddedBanner: View {
    let added: PhoneAutoAdded
    let undo: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: added.isAlarm ? "alarm" : added.isEvent ? "calendar.badge.checkmark" : "checklist.checked")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(added.isAlarm ? AppLocalization.string("Hermes set \(added.title)")
                     : added.calendarTitle.map { AppLocalization.string("Hermes added \(added.title) to \($0)") }
                     ?? AppLocalization.string("Hermes added \(added.title)"))
                    .scaledFont(.subheadline)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Undo", action: undo)
                .scaledFont(.subheadline.weight(.semibold))
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("Close"))
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(.horizontal, 12)
    }
}

/// The card and banner over the app, fed by the phone sync engine.
struct PhoneChangeOverlay: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var engine: PhoneSyncEngine

    var body: some View {
        VStack(spacing: 8) {
            if let prompt = engine.prompts.first {
                PhoneChangeCard(prompt: prompt, waiting: engine.prompts.count) { approve in
                    Task { await appState.answerPhoneChange(prompt, approve: approve) }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let added = engine.autoAdded {
                PhoneAutoAddedBanner(added: added) {
                    Task { await engine.undo(added) }
                } close: {
                    engine.autoAdded = nil
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: added.id) {
                    try? await Task.sleep(for: .seconds(8))
                    if engine.autoAdded == added { engine.autoAdded = nil }
                }
            }
        }
        // Nothing showing takes no room: a call screen stacks it in its top inset.
        .padding(.top, engine.prompts.isEmpty && engine.autoAdded == nil ? 0 : 6)
        .animation(.spring(duration: 0.3), value: engine.prompts.first?.id)
        .animation(.spring(duration: 0.3), value: engine.autoAdded?.id)
        .onChange(of: engine.prompts.first?.id) { _, id in
            // The card isn't modal: tell VoiceOver users Hermes is waiting.
            guard id != nil, let change = engine.prompts.first?.change else { return }
            let spoken = [PhoneChangeWording.headline(change), PhoneChangeWording.detail(change)].filter { !$0.isEmpty }
            UIAccessibility.post(notification: .announcement, argument: spoken.joined(separator: ". "))
        }
    }
}
