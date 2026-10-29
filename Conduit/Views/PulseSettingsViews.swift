//
//  PulseSettingsViews.swift
//  Conduit
//
//  Settings > Pulse (beta), on TestFlight and Xcode builds: Pulse on or
//  off; when it speaks up (how often, the times it looks through your
//  chats, the morning brief, private reminders on the Lock Screen); what it
//  reads (profiles, memory, deadlines from Shortcuts, looking things up,
//  where you are, older chats); its model; and behind the scenes, its time
//  zone, token budgets, a look now and latest checks (PulseSettings.swift).
//  Every change goes to the plugin and the page shows the state it answers
//  with.
//

import SwiftUI

struct PulseSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject private var location = LocationSharingController.shared

    @State private var state: PulseState?
    @State private var loadError: String?
    /// The step holding the page's one request slot; a switch of dashboard
    /// cancels it and frees the slot at once.
    @State private var workingID: UUID?
    /// Steps started, so a load answered after one began doesn't undo it.
    @State private var stepsStarted = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var dayCount = 30
    @State private var seededDays = false
    @State private var estimate: PulseBackfillEstimate?
    @State private var showsRecent = false
    /// Report times being edited, saved a moment after the last change.
    @State private var draftTimes: [String]?
    @State private var timesSave: Task<Void, Never>?
    /// The models Hermes offers, for the Model picker.
    @State private var providers: [ProviderInfo] = []
    /// The note to Pulse as it's being edited; nil shows the plugin's.
    @State private var noteDraft: String?
    @FocusState private var noteFocused: Bool
    /// Turning off deadlines from Shortcuts forgets the ones kept, so it asks first.
    @State private var confirmsInboxOff = false

    private var client: PulseClient { appState.pulseClient }
    private var working: Bool { workingID != nil }

    var body: some View {
        SettingsDetailContainer {
            if let state {
                overviewSection(state)
                if state.homeChat == nil { homeChatSection(state) }
                if state.enabled {
                    let budgets = appState.notifierPlugin.reports(PulseClient.nudgeCapability)
                    speakUpSection(state, budgets: budgets)
                    let quiet = appState.notifierPlugin.reports(PulseClient.quietCapability)
                    let hours = appState.notifierPlugin.reports(PulseClient.hoursCapability)
                    if quiet || hours { quietSection(state, quiet: quiet, hours: hours) }
                    if appState.notifierPlugin.reports(PulseClient.noteCapability) { noteSection(state) }
                    readsSection(state)
                    if state.memory || state.backfill.phase != .none {
                        backfillSection(state)
                    }
                    if appState.notifierPlugin.reports(PulseClient.modelCapability) { modelSection(state) }
                    behindTheScenesSection(state, budgets: budgets)
                }
            } else if let loadError {
                ConduitSettingsSection(title: AppLocalization.string("Pulse"), symbol: "waveform.path.ecg", tint: .conduitAura) {
                    Text("Couldn't read Pulse's settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(verbatim: loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button(AppLocalization.string("Try again")) {
                        Task { await load() }
                    }
                    .buttonStyle(.settings)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading Pulse…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
        }
        .navigationTitle(Text(AppLocalization.string("Pulse (beta)")))
        // Read on every visit, also back from What Pulse remembers, whose
        // counts may have changed.
        .task(id: appState.activeDashboardID) { await load() }
        .onChange(of: appState.activeDashboardID) { _, _ in
            // Another dashboard's host: nothing of this one's carries over.
            // A save of report times still waiting is the old host's too;
            // leaving the page only (What Pulse remembers) lets it finish.
            timesSave?.cancel()
            timesSave = nil
            actionTask?.cancel()
            actionTask = nil
            workingID = nil
            state = nil
            loadError = nil
            errorMessage = nil
            notice = nil
            seededDays = false
            estimate = nil
            draftTimes = nil
            noteDraft = nil
            providers = []
            showsRecent = false
            // Turning deadlines off was asked of the old host; answered now, it would act on the new one.
            confirmsInboxOff = false
        }
    }

    // MARK: Sections

    private func overviewSection(_ state: PulseState) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Pulse"), symbol: "waveform.path.ecg", tint: .conduitAura) {
            Text("Pulse reads your chats, keeps track of what you and Hermes said you'd do, and brings things up as cards on the Pulse screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Pulse", isOn: Binding(
                get: { state.enabled },
                set: { on in changeWatching(["enabled": on]) { $0.enabled = on } }
            ))
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.enabled")
            if state.enabled {
                if state.running {
                    Label(AppLocalization.string("Pulse is running on the dashboard."), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The dashboard isn't running Pulse. Restart it after updating the plugin.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if state.staleBuild {
                Text("The dashboard is running an older copy of Pulse. Restart it to use the update.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let chat = state.homeChat {
                // Shown whether Pulse is on or off: where its cards come from.
                SettingsMetricRow(label: AppLocalization.string("Pulse chat"), value: chat.title, lineLimit: 1)
            }
            if state.homeChat != nil, !state.homeProblem.isEmpty {
                // Something wrong with the Pulse chat, in the plugin's own
                // words (English); kept out of Behind the scenes so it shows.
                Text(verbatim: state.homeProblem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func homeChatSection(_ state: PulseState) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Pulse chat"), symbol: "pin", tint: .conduitAccent) {
            Text(AppLocalization.string("Pulse sends its reports to a pinned chat titled “\(state.homeTitle)” in the dashboard's default profile."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(AppLocalization.string("Create Pulse chat")) {
                let title = state.homeTitle
                run { _ in
                    try await appState.createPulseHomeChat(title: title)
                    return nil
                }
            }
            .buttonStyle(.settingsPrimary)
            .disabled(working || appState.client == nil)
            .accessibilityIdentifier("settings.pulse.create-chat")
            if !state.homeProblem.isEmpty {
                // The plugin's own words, in English.
                Text(verbatim: state.homeProblem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// How often Pulse nudges, when it looks through the chats, the
    /// morning brief's time, and whether private reminders hide their words
    /// on the Lock Screen.
    private func speakUpSection(_ state: PulseState, budgets: Bool) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("When Pulse speaks up"), symbol: "bell.badge", tint: .conduitAccent) {
            if budgets {
                Picker(AppLocalization.string("How often"), selection: Binding(
                    get: { PulseNudge.levels.contains(state.nudge) ? state.nudge : PulseNudge.defaultLevel },
                    set: { picked in
                        guard picked != state.nudge else { return }
                        Haptics.selection()
                        change(["nudge": picked]) { $0.nudge = picked }
                    }
                )) {
                    ForEach(PulseNudge.levels, id: \.self) { level in
                        Text(verbatim: PulseNudge.title(level)).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(working)
                .accessibilityIdentifier("settings.pulse.nudge")
                Text(verbatim: PulseNudge.detail(state.nudge))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Look through your chats", isOn: Binding(
                get: { state.dailyReport },
                set: { on in change(["daily_report": on]) { $0.dailyReport = on } }
            ))
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.report")
            if state.dailyReport {
                reportTimes(state)
            }
            // The plugin takes the brief's time with the Pulse screen (0.55.0).
            if appState.notifierPlugin.reports(PulseClient.feedCapability) { briefTime(state) }
            // Before 0.76.0 the brief only came with news held for it.
            Group {
                if appState.notifierPlugin.reports(PulseClient.dailyBriefCapability) {
                    Text("Each look that finds something sends one notification. The morning brief comes every day at its time with what's still open, today's calendar and reminders, and anything you've asked to hear less often.")
                } else {
                    Text("Each look that finds something sends one notification. Things you've asked to hear less often wait for the morning brief instead.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if appState.pulseHidesPrivate, let hides = state.privatePushes {
                Text("A reminder for a place, or one that can't wait, comes as Time Sensitive, at most three a day. While you're busy, Pulse's notifications go quietly to Notification Center.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Hide private reminders on the Lock Screen", isOn: Binding(
                    get: { hides },
                    set: { on in change(["private_pushes": on]) { $0.privatePushes = on } }
                ))
                .disabled(working)
                .accessibilityIdentifier("settings.pulse.private")
                Text("A Pulse notification about a birthday, an anniversary, a gift, a surprise, health or money says only “Pulse has something for you.”, even with Show previews on. Its card shows everything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Quiet times (0.80.2, `quiet`): the days of the week Pulse keeps to
    /// itself, and a vacation until a day. Quiet for today is on the Pulse
    /// screen and on a Pulse notification; it shows here as a vacation back
    /// tomorrow. From 0.86.0 (`hours`), the night.
    private func quietSection(_ state: PulseState, quiet: Bool, hours: Bool) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Quiet times"), symbol: "moon.zzz", tint: .conduitAccent) {
            if quiet { quietRows(state) }
            if hours { nightRows(state) }
        }
    }

    @ViewBuilder
    private func quietRows(_ state: PulseState) -> some View {
        // Days as the plugin keeps them: in its time zone, Gregorian on the wire.
        let host = PulseQuiet.calendar(zone: state.timeZone)
        Text("Quiet days")
            .font(.subheadline.weight(.semibold))
        PulseQuietDaysPicker(days: Set(state.quietDays)) { days in
            change(["quiet_days": days]) { $0.quietDays = days }
        }
        .disabled(working)
        .accessibilityIdentifier("settings.pulse.quiet-days")
        Toggle("Vacation", isOn: Binding(
            get: { state.quietUntil != nil },
            set: { on in
                if on {
                    let back = PulseQuiet.defaultReturn(calendar: host)
                    change(["quiet_until": PulseQuiet.dayText(back, calendar: host)]) { $0.quietUntil = back }
                } else {
                    change(["quiet_until": NSNull()]) { $0.quietUntil = nil }
                }
            }
        ))
        .disabled(working)
        .accessibilityIdentifier("settings.pulse.vacation")
        if let back = state.quietUntil {
            DatePicker(
                AppLocalization.string("Back on"),
                selection: Binding(
                    get: { back },
                    set: { day in
                        let text = PulseQuiet.dayText(day, calendar: host)
                        guard text != PulseQuiet.dayText(back, calendar: host) else { return }
                        let start = host.startOfDay(for: day)
                        change(["quiet_until": text]) { $0.quietUntil = start }
                    }
                ),
                in: PulseQuiet.returnDays(calendar: host),
                displayedComponents: .date
            )
            // The days in the plugin's time zone, so the one shown is the one kept.
            .environment(\.timeZone, host.timeZone)
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.vacation-end")
        }
        Text("On quiet days and on vacation, Pulse sends nothing on its own: no report and no morning brief, and follow-ups wait for the first brief after. It keeps remembering, and Do it still checks.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The night (0.86.0): Pulse's notifications wait for the morning brief
    /// then, unless they can't wait. Its times are in Pulse's time zone, as
    /// the brief's is.
    @ViewBuilder
    private func nightRows(_ state: PulseState) -> some View {
        Toggle("Night", isOn: Binding(
            get: { state.night != nil },
            set: { on in
                let night = on ? PulseNight.default : nil
                change(["night": night?.setting ?? []]) { $0.night = night }
            }
        ))
        .disabled(working)
        .accessibilityIdentifier("settings.pulse.night")
        if let night = state.night {
            nightTime(AppLocalization.string("Night starts"), minutes: night.start, other: night.end) {
                PulseNight(start: $0, end: night.end)
            }
            .accessibilityIdentifier("settings.pulse.night-start")
            nightTime(AppLocalization.string("Night ends"), minutes: night.end, other: night.start) {
                PulseNight(start: night.start, end: $0)
            }
            .accessibilityIdentifier("settings.pulse.night-end")
        }
        if state.night != nil {
            Text("At night, Pulse's notifications wait for the morning brief unless they can't.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("During an event on your calendar, while you drive, or while a Focus holds Hermes' calls, Pulse's notifications wait until you're free.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// One end of the night. The same time at both ends would be no night,
    /// so the picker doesn't take the other end's.
    private func nightTime(_ label: String, minutes: Int, other: Int,
                           night: @escaping (Int) -> PulseNight) -> some View {
        DatePicker(
            label,
            selection: Binding(
                get: { PulseReportTime.date(PulseReportTime.text(minutes: minutes)) },
                set: { date in
                    guard let picked = PulseReportTime.minutes(PulseReportTime.text(from: date)),
                          picked != minutes, picked != other else { return }
                    let next = night(picked)
                    change(["night": next.setting]) { $0.night = next }
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .disabled(working)
    }

    /// What the user wants from Pulse, in their own words: the plugin's
    /// reports, morning brief and follow-up checks read it before their own
    /// rules (0.78.2). Saved on Save, so a half-typed note never goes out;
    /// a save that fails keeps the draft on screen, like the report times.
    private func noteSection(_ state: PulseState) -> some View {
        let shown = noteDraft ?? state.note
        let trimmed = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        // Counted as the plugin counts it (code points), so what fits here fits there.
        let tooLong = trimmed.unicodeScalars.count > PulseNote.limit
        let changed = noteDraft != nil && trimmed != state.note
        let limit = AppLocalization.string("At most \(PulseNote.limit.formatted(.number)) characters.")
        return ConduitSettingsSection(title: AppLocalization.string("What you want from Pulse"), symbol: "text.quote", tint: .conduitAccent) {
            TextField(AppLocalization.string("What to always bring up, what to leave out"), text: Binding(
                get: { shown },
                set: { noteDraft = $0 }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...8)
            .focused($noteFocused)
            .disabled(working)
            .accessibilityLabel(Text(AppLocalization.string("Note to Pulse")))
            .accessibilityHint(Text(limit))
            .accessibilityIdentifier("settings.pulse.note")
            if tooLong {
                Text(verbatim: limit)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .onAppear { AccessibilityNotification.Announcement(limit).post() }
            }
            if changed {
                HStack {
                    Spacer()
                    Button(AppLocalization.string("Cancel")) {
                        noteFocused = false
                        noteDraft = nil
                    }
                    .buttonStyle(.settings)
                    Button(AppLocalization.string("Save")) {
                        noteFocused = false
                        saveNote(trimmed)
                    }
                    .buttonStyle(.settingsPrimary)
                    .disabled(working || tooLong)
                    .accessibilityIdentifier("settings.pulse.note-save")
                }
            }
            Text("Pulse reads it before every report, morning brief and reminder. Where it says what to bring up or leave out, it comes before Pulse's own rules.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func readsSection(_ state: PulseState) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("What Pulse reads"), symbol: "brain.head.profile", tint: .conduitAccent) {
            if state.offersProfileChoice {
                ConduitMenuPicker(
                    value: state.reportProfiles,
                    choices: [
                        (id: "all", title: AppLocalization.string("Every profile")),
                        (id: "this", title: AppLocalization.string("This profile only")),
                    ],
                    onSelect: { picked in
                        Haptics.selection()
                        change(["report_profiles": picked]) { $0.reportProfiles = picked }
                    }
                ) {
                    Text("Profiles").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.pulse.profiles")
            }
            Toggle("Memory", isOn: Binding(
                get: { state.memory },
                set: { on in change(["memory": on]) { $0.memory = on } }
            ))
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.memory")
            NavigationLink {
                PulseMemoryList()
                    .v2TabBarClearance()
            } label: {
                HStack {
                    Label(AppLocalization.string("What Pulse remembers"), systemImage: "list.bullet.rectangle")
                    Spacer(minLength: 8)
                    if state.memory {
                        Text(verbatim: state.memoryCounts.values.reduce(0, +).formatted())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("settings.pulse.remembers")
            Text("Pulse keeps short notes on promises, plans and dates, so it can bring them up later. You can remove any of them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.pulseKeepsInboxDeadlines, let deadlines = state.inboxDeadlines {
                Toggle("Deadlines from Shortcuts", isOn: Binding(
                    get: { deadlines },
                    set: { on in
                        if on {
                            change(["inbox_deadlines": true]) { $0.inboxDeadlines = true }
                        } else {
                            confirmsInboxOff = true
                        }
                    }
                ))
                // Read with memory: off with it, there's nothing to switch.
                .disabled(working || !state.memory)
                .accessibilityHint(state.memory ? Text(verbatim: "") : Text(AppLocalization.string("Turn on Pulse's memory first.")))
                .accessibilityIdentifier("settings.pulse.inbox-deadlines")
                .confirmationDialog(AppLocalization.string("Turn off deadlines from Shortcuts?"),
                                    isPresented: $confirmsInboxOff, titleVisibility: .visible) {
                    Button(AppLocalization.string("Turn off"), role: .destructive) {
                        change(["inbox_deadlines": false]) { $0.inboxDeadlines = false }
                    }
                    Button(AppLocalization.string("Cancel"), role: .cancel) {}
                } message: {
                    Text("Pulse forgets the deadlines it kept from your Shortcuts inbox.")
                }
                Text("With memory on, Pulse also looks for deadlines in what your Shortcuts automations log, like a trial ending or a bill due, and brings each up a week ahead and the day before. Turning this off forgets the ones it kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.pulseLooksFirst, let lookFirst = state.lookFirst {
                Toggle("Look things up first", isOn: Binding(
                    get: { lookFirst },
                    set: { on in change(["look_first": on]) { $0.lookFirst = on } }
                ))
                .disabled(working)
                .accessibilityIdentifier("settings.pulse.look-first")
                Text(verbatim: appState.pulseSuggests
                    ? AppLocalization.string("Before Pulse writes to you, it can check your calendar, reminders, contacts and alarms, look up places in Maps, and search the web when it follows up on a promise. It never changes anything itself: an event or reminder worth adding comes as a suggestion you add with a tap.")
                    : AppLocalization.string("Before Pulse writes to you, it can check your calendar, reminders, contacts and alarms, look up places in Maps, and search the web when it follows up on a promise. It never changes anything on your phone."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if appState.pulseReadsWhere, let whereOn = state.whereYouAre {
                Toggle("Where you are", isOn: Binding(
                    get: { whereOn },
                    set: { on in changeWatching(["where": on]) { $0.whereYouAre = on } }
                ))
                .disabled(working)
                .accessibilityIdentifier("settings.pulse.where")
                Text("Pulse can remind you of what you said you'd do at one of your saved places as you get there or leave, bring up something it saved for that moment, and use where you are when it looks things up. It reads your location only while this is on and Conduit shares it in the background. Each read is listed under When Hermes read your location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if whereOn, !state.whereReady {
                    Text("Pulse can't read where you are yet: in Settings > Location, turn on Share in the background, or Resume sharing if it's paused.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if whereOn, let walking = state.walkingPast {
                    Toggle("Walking past", isOn: Binding(
                        get: { walking },
                        set: { on in changeWatching(["spots": on]) { $0.walkingPast = on } }
                    ))
                    .disabled(working)
                    .accessibilityIdentifier("settings.pulse.walking-past")
                    Text("Pulse can ask Conduit to watch for a few kinds of shop near you, like a florist before an anniversary or a shop you said you'd stop at. Conduit searches Apple Maps on this iPhone and tells your gateway the shop's name, when you came near it, how close, how accurate that was and how fast you were moving, never where the shop is. Only while Conduit shares your precise location in the background. Turning this off deletes the shops your gateway kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if walking, state.whereReady, !location.watchesSpots {
                        Text("This iPhone isn't watching shops: in Settings > Location, share in the background at Precise, and allow Conduit's location Always, with Precise Location on.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if walking, state.whereReady, location.places.count >= PulseSpotWatcher.conditionLimit {
                        Text("This iPhone isn't watching shops: your saved places use all the places iOS lets Conduit watch. Remove one in Settings > Location to make room.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    /// The rest, folded: the time zone, a look through the chats now, token
    /// budgets, Pulse's chat and its latest checks.
    private func behindTheScenesSection(_ state: PulseState, budgets: Bool) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Behind the scenes"), symbol: "gearshape.2", tint: .conduitAura) {
            DisclosureGroup(isExpanded: $showsRecent) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsMetricRow(label: AppLocalization.string("Time zone"), value: state.timeZone, lineLimit: 1)
                    let phoneZone = TimeZone.current.identifier
                    if phoneZone != state.timeZone {
                        Button(AppLocalization.string("Use this iPhone's time zone (\(phoneZone))")) {
                            change(["time_zone": phoneZone])
                        }
                        .buttonStyle(.settings)
                        .accessibilityIdentifier("settings.pulse.time-zone")
                        .disabled(working)
                    }
                    if state.dailyReport, let next = state.nextReportAt {
                        SettingsMetricRow(
                            label: AppLocalization.string("Next look"),
                            value: next.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                    Button(AppLocalization.string("Look through my chats now")) {
                        run { client in
                            try await client.sendReport()
                            if isShown(client) {
                                notice = AppLocalization.string("Pulse will report shortly. Anything it notices shows up as cards.")
                            }
                            return nil
                        }
                    }
                    .buttonStyle(.settings)
                    .disabled(working)
                    .accessibilityIdentifier("settings.pulse.report-now")
                    if let notice {
                        Text(verbatim: notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    budgetRows(state, budgets: budgets)
                    if !state.recent.isEmpty {
                        recentChecks(state)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Budgets, memory, next look, time zone, a look through your chats now and recent checks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Memory's and follow-ups' tokens today, and their daily budgets.
    @ViewBuilder
    private func budgetRows(_ state: PulseState, budgets: Bool) -> some View {
        if state.memory {
            ForEach(PulseMemoryKind.sorted(state.memoryCounts.keys), id: \.self) { kind in
                SettingsMetricRow(label: PulseMemoryKind.title(kind), value: String(state.memoryCounts[kind] ?? 0))
            }
            let used = state.tokensToday.formatted()
            let cap = state.dailyTokens.formatted()
            SettingsMetricRow(label: AppLocalization.string("Tokens today"), value: AppLocalization.string("\(used) of \(cap)"))
            if budgets {
                ConduitMenuPicker(
                    value: state.dailyTokens,
                    choices: PulseNudge.budgets(PulseNudge.memoryBudgets, current: state.dailyTokens)
                        .map { (id: $0, title: $0.formatted()) },
                    onSelect: { picked in
                        Haptics.selection()
                        change(["memory_daily_tokens": picked]) { $0.dailyTokens = picked }
                    }
                ) {
                    Text("Memory tokens a day").foregroundStyle(.secondary)
                }
                .disabled(working)
                .accessibilityIdentifier("settings.pulse.memory-budget")
            }
        }
        if budgets, state.followups || state.followupTokensToday > 0 {
            ConduitMenuPicker(
                value: state.followupDailyTokensSet ? state.followupDailyTokens : 0,
                choices: Self.followupBudgetChoices(state),
                onSelect: { picked in
                    Haptics.selection()
                    change(["followup_daily_tokens": picked == 0 ? NSNull() as Any : picked as Any])
                }
            ) {
                Text("Follow-up tokens a day").foregroundStyle(.secondary)
            }
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.followup-budget")
            let used = state.followupTokensToday.formatted()
            let cap = state.followupDailyTokens.formatted()
            SettingsMetricRow(label: AppLocalization.string("Follow-up tokens today"),
                              value: AppLocalization.string("\(used) of \(cap)"))
        }
    }

    /// The morning brief: every day at this time, what's still open and the cards held for it, with one push.
    @ViewBuilder
    private func briefTime(_ state: PulseState) -> some View {
        DatePicker(
            AppLocalization.string("Morning brief"),
            selection: Binding(
                get: { PulseReportTime.date(state.briefTime) },
                set: { date in
                    let time = PulseReportTime.text(from: date)
                    guard time != state.briefTime else { return }
                    change(["brief_time": time]) { $0.briefTime = time }
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .disabled(working)
        .accessibilityIdentifier("settings.pulse.brief-time")
    }

    @ViewBuilder
    private func reportTimes(_ state: PulseState) -> some View {
        let times = draftTimes ?? state.reportTimes
        Text("Looks through your chats at")
            .font(.subheadline.weight(.semibold))
        ForEach(Array(times.enumerated()), id: \.offset) { index, time in
            HStack(spacing: 10) {
                DatePicker(
                    AppLocalization.string("Report time"),
                    selection: Binding(
                        get: { PulseReportTime.date(time) },
                        set: { date in
                            var next = times
                            guard next.indices.contains(index) else { return }
                            next[index] = PulseReportTime.text(from: date)
                            editTimes(next)
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .accessibilityLabel(Text(AppLocalization.string("Report time")))
                Spacer(minLength: 8)
                Button {
                    var next = times
                    guard next.indices.contains(index) else { return }
                    next.remove(at: index)
                    editTimes(next)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(times.count <= 1)
                .accessibilityLabel(Text(AppLocalization.string("Remove \(time)")))
            }
        }
        Button(AppLocalization.string("Add a time")) {
            editTimes(times + [PulseReportTime.next(after: times)])
        }
        .buttonStyle(.settings)
        .disabled(times.count >= PulseReportTime.maxCount)
        .accessibilityIdentifier("settings.pulse.add-time")
    }

    private func modelSection(_ state: PulseState) -> some View {
        let selection = state.model.map { VoiceJobModelSettingsSection.tag(provider: $0.provider, model: $0.model) } ?? ""
        return ConduitSettingsSection(title: AppLocalization.string("Model"), symbol: "cpu", tint: .conduitAccent) {
            ConduitMenuPicker(
                value: selection,
                choices: VoiceJobModelSettingsSection.modelChoices(
                    defaultTitle: AppLocalization.string("Same as the Pulse chat"),
                    defaultTag: "",
                    selection: selection,
                    providers: providers
                ),
                onSelect: { tag in
                    guard tag != selection else { return }
                    let pick = tag.isEmpty ? nil : VoiceJobModelSettingsSection.parse(tag)
                    setModel(pick.map { PulseModel(provider: $0.provider ?? "", model: $0.model) })
                }
            ) {
                Text("Model").foregroundStyle(.secondary)
            }
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.model")
            Text("Pulse's reports, morning brief, follow-ups and memory run on this model. A fast, cheap model is plenty.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: appState.activeDashboardID) {
            let dashboard = appState.activeDashboardID
            let loaded = await appState.loadVoiceJobModelProviders()
            if appState.activeDashboardID == dashboard { providers = loaded }
        }
    }

    /// The turns' model first, as Pulse checks it, then memory's slot. A
    /// refused slot puts the turns back, so the two never part.
    private func setModel(_ model: PulseModel?) {
        guard !working, var shown = state else { return }
        let previous = shown.model
        shown.model = model
        state = shown
        run { client in
            let next = try await client.update(["model": model?.setting ?? NSNull()])
            guard isShown(client) else { return nil }
            do {
                try await appState.setPulseMemoryModel(model)
            } catch {
                if isShown(client) { _ = try? await client.update(["model": previous?.setting ?? NSNull()]) }
                throw error
            }
            return next
        }
    }

    /// 0 is the nudge level's budget, named with its amount while it's in use.
    private static func followupBudgetChoices(_ state: PulseState) -> [(id: Int, title: String)] {
        let set = state.followupDailyTokensSet
        let byLevel = set ? AppLocalization.string("With nudging")
            : AppLocalization.string("With nudging (\(state.followupDailyTokens.formatted()))")
        let budgets = PulseNudge.budgets(PulseNudge.followupBudgets, current: set ? state.followupDailyTokens : 0)
        return [(id: 0, title: byLevel)] + budgets.map { (id: $0, title: $0.formatted()) }
    }

    private func backfillSection(_ state: PulseState) -> some View {
        let backfill = state.backfill
        return ConduitSettingsSection(title: AppLocalization.string("Older chats"), symbol: "clock.arrow.circlepath", tint: .conduitAccent) {
            Text("Pulse's memory can read back through older chats, a day's token budget at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let line = backfillStatus(backfill) {
                Text(verbatim: line)
                    .font(.subheadline)
            }
            if backfill.narrow {
                Text("Other profiles' older chats aren't read yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !backfill.unreadable.isEmpty {
                Text(AppLocalization.string("Couldn't read: \(Self.list(backfill.unreadable))"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            switch backfill.phase {
            case .reading:
                HStack(spacing: 10) {
                    Button(AppLocalization.string("Pause")) { backfillStep(.stop) }
                        .buttonStyle(.settings)
                        .accessibilityIdentifier("settings.pulse.backfill-pause")
                    Button(AppLocalization.string("Cancel")) { backfillStep(.cancel) }
                        .buttonStyle(.settings)
                        .accessibilityIdentifier("settings.pulse.backfill-cancel")
                }
                .disabled(working)
            case .paused:
                HStack(spacing: 10) {
                    Button(AppLocalization.string("Carry on")) { backfillStep(.start) }
                        .buttonStyle(.settingsPrimary)
                        .accessibilityIdentifier("settings.pulse.backfill-carry-on")
                    Button(AppLocalization.string("Cancel")) { backfillStep(.cancel) }
                        .buttonStyle(.settings)
                        .accessibilityIdentifier("settings.pulse.backfill-cancel")
                }
                .disabled(working)
            case .none, .done, .cancelled:
                Stepper(value: $dayCount, in: 1...PulseBackfillEstimate.maxDays) {
                    HStack {
                        Text("Days to read")
                        Spacer(minLength: 8)
                        Text(verbatim: String(dayCount))
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: dayCount) { _, _ in estimate = nil }
                .accessibilityIdentifier("settings.pulse.days")
                if let estimate, estimate.days == dayCount {
                    SettingsMetricRow(label: AppLocalization.string("Chats"), value: estimate.chats.formatted())
                    SettingsMetricRow(label: AppLocalization.string("Tokens"), value: estimate.tokens.formatted())
                    SettingsMetricRow(label: AppLocalization.string("Days needed"), value: estimate.daysNeeded.formatted())
                    if !estimate.unreadable.isEmpty {
                        Text(AppLocalization.string("Couldn't read: \(Self.list(estimate.unreadable))"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button(AppLocalization.string("Start")) { backfillStep(.start, days: dayCount) }
                        .buttonStyle(.settingsPrimary)
                        .disabled(working)
                        .accessibilityIdentifier("settings.pulse.backfill-start")
                } else {
                    Button(AppLocalization.string("Estimate")) {
                        let days = dayCount
                        run { client in
                            let next = try await client.estimate(days: days)
                            if isShown(client) { estimate = next }
                            return nil
                        }
                    }
                    .buttonStyle(.settings)
                    .disabled(working)
                    .accessibilityIdentifier("settings.pulse.estimate")
                }
            }
        }
    }

    private func recentChecks(_ state: PulseState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pulse's latest checks and reports")
                .font(.subheadline.weight(.semibold))
            ForEach(state.recent.prefix(5)) { attempt in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verbatim: "\(Self.kindTitle(attempt.kind)) · \(attempt.state)")
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        Text(attempt.at.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !attempt.detail.isEmpty {
                        Text(verbatim: attempt.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Text

    private func backfillStatus(_ backfill: PulseBackfill) -> String? {
        if backfill.phase == .cancelled {
            return AppLocalization.string("Cancelled. What Pulse read stays in its memory.")
        }
        guard let from = backfill.from, let to = backfill.to else { return nil }
        let start = from.formatted(date: .abbreviated, time: .omitted)
        let end = to.formatted(date: .abbreviated, time: .omitted)
        switch backfill.phase {
        case .reading: return AppLocalization.string("Reading chats from \(start) to \(end).")
        case .paused: return AppLocalization.string("Paused while reading chats from \(start) to \(end).")
        case .done: return AppLocalization.string("Read chats from \(start) to \(end).")
        case .none, .cancelled: return nil
        }
    }

    private static func kindTitle(_ kind: String) -> String {
        switch kind {
        case "report": return AppLocalization.string("Report")
        case "probe": return AppLocalization.string("Chat check")
        case "followup": return AppLocalization.string("Follow-up")
        case "brief": return AppLocalization.string("Morning brief")
        // A pick the look ahead held for a place, brought up there (0.103.0).
        case "moment": return AppLocalization.string("At a place")
        default: return kind
        }
    }

    private static func list(_ names: [String]) -> String {
        names.formatted(.list(type: .and).locale(AppLocalization.formattingLocale))
    }

    // MARK: Actions

    private func load() async {
        let client = self.client
        let steps = stepsStarted
        do {
            let next = try await client.state()
            guard isShown(client), !Task.isCancelled, stepsStarted == steps else { return }
            apply(next)
            loadError = nil
        } catch {
            guard isShown(client), !Task.isCancelled else { return }
            if state == nil { loadError = PulseRefusal.message(for: error) }
        }
    }

    private func reload() async {
        let client = self.client
        guard let next = try? await client.state(), isShown(client) else { return }
        apply(next)
    }

    private func apply(_ next: PulseState) {
        if !seededDays {
            dayCount = next.backfillDays
            seededDays = true
        }
        state = next
        // Pulse, Where you are or Walking past off, here or elsewhere: this
        // iPhone stops watching shops for this dashboard now.
        if location.binding?.dashboardID == appState.activeDashboardID,
           !next.enabled || next.walkingPast == false || next.whereYouAre == false {
            location.forgetSpots()
        }
    }

    /// One step at a time: shows its error, then the state Pulse answers
    /// with (or reads it again).
    /// The step gets the client of the dashboard shown when it was asked
    /// for: its requests fail rather than go out after a switch, and the
    /// step writes the page only while that dashboard is still shown
    /// (`isShown`).
    private func run(_ step: @escaping @MainActor (PulseClient) async throws -> PulseState?) {
        guard !working else { return }
        let id = UUID()
        workingID = id
        stepsStarted += 1
        errorMessage = nil
        notice = nil
        let dashboard = appState.activeDashboardID
        let client = self.client
        actionTask = Task {
            defer { if workingID == id { workingID = nil } }
            guard appState.activeDashboardID == dashboard else { return }
            do {
                let next = try await step(client)
                // An answer from the dashboard this page showed before a switch isn't this one's.
                guard appState.activeDashboardID == dashboard else { return }
                if let next {
                    apply(next)
                } else {
                    await reload()
                }
                Haptics.success()
            } catch {
                guard appState.activeDashboardID == dashboard else { return }
                errorMessage = PulseRefusal.message(for: error)
                Haptics.error()
                await reload()
            }
        }
    }

    /// Whether the client's dashboard is the one this page shows now.
    private func isShown(_ client: PulseClient) -> Bool {
        client.dashboardID == appState.activeDashboardID
    }

    /// A settings change, shown at once and then as Pulse has it.
    /// The note goes out as typed; the draft stays until the plugin took
    /// it, so a refusal or a dropped connection leaves it there to fix.
    private func saveNote(_ note: String) {
        run { client in
            let next = try await client.update(["note": note])
            if noteDraft?.trimmingCharacters(in: .whitespacesAndNewlines) == note { noteDraft = nil }
            return next
        }
    }

    private func change(_ changes: [String: Any], optimistic: ((inout PulseState) -> Void)? = nil) {
        guard !working else { return }
        if let optimistic, var shown = state {
            optimistic(&shown)
            state = shown
        }
        run { client in try await client.update(changes) }
    }

    /// A change to Pulse, Where you are or Walking past: once the host has
    /// all on, a send now brings back the shops to watch (`apply` stops
    /// watching when one is off).
    private func changeWatching(_ changes: [String: Any], optimistic: @escaping (inout PulseState) -> Void) {
        guard !working else { return }
        if var shown = state {
            optimistic(&shown)
            state = shown
        }
        run { client in
            let next = try await client.update(changes)
            if location.binding?.dashboardID == client.dashboardID,
               next.enabled, next.walkingPast == true, next.whereYouAre == true, location.watchesSpots {
                Task { await location.flush(settingsOnly: true) }
            }
            return next
        }
    }

    private func backfillStep(_ action: PulseBackfillAction, days: Int? = nil) {
        run { client in
            let next = try await client.backfill(action, days: days)
            if isShown(client) { estimate = nil }
            return next
        }
    }

    /// Saves the times a moment after the last change, so turning a picker
    /// doesn't send each step.
    private func editTimes(_ times: [String]) {
        draftTimes = times
        timesSave?.cancel()
        let dashboard = appState.activeDashboardID
        let client = self.client
        timesSave = Task {
            try? await Task.sleep(for: .milliseconds(800))
            // One request at a time: wait for a step already on its way.
            while working, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled, appState.activeDashboardID == dashboard else { return }
            let id = UUID()
            workingID = id
            defer { if workingID == id { workingID = nil } }
            errorMessage = nil
            do {
                let next = try await client.update(["report_times": PulseReportTime.normalized(times)])
                guard appState.activeDashboardID == dashboard else { return }
                if draftTimes == times { draftTimes = nil }
                apply(next)
            } catch {
                // Cancelled by a newer edit, which saves again, or by a switch.
                guard !(error is CancellationError), !Task.isCancelled,
                      appState.activeDashboardID == dashboard else { return }
                errorMessage = PulseRefusal.message(for: error)
                if draftTimes == times { draftTimes = nil }
                await reload()
            }
        }
    }
}

/// Settings > Pulse's quiet days: seven toggles in the user's week order,
/// drawn like the scheduled job editor's days. `days` are the plugin's
/// (Monday 0 to Sunday 6).
private struct PulseQuietDaysPicker: View {
    let days: Set<Int>
    let pick: ([Int]) -> Void

    var body: some View {
        // The week's order from the user's region, the names in the App Language.
        var named = Calendar.current
        named.locale = AppLocalization.formattingLocale
        let symbols = named.veryShortStandaloneWeekdaySymbols
        let names = named.standaloneWeekdaySymbols
        return HStack(spacing: 6) {
            ForEach(PulseQuiet.weekOrder(), id: \.self) { day in
                let isOn = days.contains(day)
                let index = PulseQuiet.calendarIndex(pluginDay: day)
                Button {
                    Haptics.selection()
                    var next = days
                    if isOn { next.remove(day) } else { next.insert(day) }
                    pick(next.sorted())
                } label: {
                    Text(verbatim: symbols[index])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(isOn ? Color.conduitAccent : Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: names[index]))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }
}

/// Settings > Pulse > What Pulse remembers: the open items by kind; swipe
/// one to forget it.
struct PulseMemoryList: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @State private var items: [PulseMemoryItem] = []
    @State private var loaded = false
    @State private var forgetting = false

    /// Whether the client's dashboard is still the one shown: after a
    /// switch its answers are the old host's.
    private func isShown(_ client: PulseClient) -> Bool { client.dashboardID == appState.activeDashboardID }
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if loaded, items.isEmpty, errorMessage == nil {
                Text("Pulse doesn't remember anything yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(PulseMemoryKind.sorted(items.map(\.kind)), id: \.self) { kind in
                Section {
                    ForEach(items.filter { $0.kind == kind }) { item in
                        row(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    forget(item)
                                } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(verbatim: PulseMemoryKind.title(kind))
                }
            }
        }
        .overlay {
            if !loaded { ProgressView() }
        }
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
        .navigationTitle(Text(AppLocalization.string("What Pulse remembers")))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        // Read again for another dashboard's host; nothing of the old one's stays.
        .task(id: appState.activeDashboardID) { await load() }
        .onChange(of: appState.activeDashboardID) { _, _ in
            items = []
            loaded = false
            errorMessage = nil
        }
    }

    private func row(_ item: PulseMemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: item.text)
                .font(.subheadline)
            if !item.evidence.isEmpty {
                // The chat's own words, or the logged event's.
                Text(verbatim: "“\(item.evidence)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !item.due.isEmpty {
                Text(AppLocalization.string("Due: \(item.due)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let yearly = item.everyYearText() {
                Text(verbatim: yearly)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let place = item.place {
                // Said for a place: it waits for the user to get there or leave.
                Label(place.text, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let saved = place.savedText {
                    Text(verbatim: saved)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let logged = item.loggedText() {
                // A deadline from the Shortcuts inbox: who it's from, not a chat.
                Text(verbatim: logged)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let mentioned = item.mentionedAt {
                Text(AppLocalization.string("Last mentioned \(mentioned.formatted(.relative(presentation: .named)))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        let client = appState.pulseClient
        do {
            let next = try await client.memory()
            guard isShown(client), !Task.isCancelled else { return }
            items = next
            errorMessage = nil
        } catch {
            guard isShown(client), !Task.isCancelled else { return }
            errorMessage = PulseRefusal.message(for: error)
        }
        loaded = true
    }

    private func forget(_ item: PulseMemoryItem) {
        guard !forgetting else { return }
        forgetting = true
        let client = appState.pulseClient
        Task {
            defer { forgetting = false }
            do {
                _ = try await client.forget(id: item.id)
                guard isShown(client) else { return }
                items.removeAll { $0.id == item.id }
                errorMessage = nil
                Haptics.success()
            } catch {
                guard isShown(client) else { return }
                errorMessage = PulseRefusal.message(for: error)
                Haptics.error()
            }
            await load()
        }
    }
}
