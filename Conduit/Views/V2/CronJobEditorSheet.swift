//
//  CronJobEditorSheet.swift
//  Conduit
//
//  New and Edit for a scheduled job (#819): name, prompt, schedule and
//  delivery, saved through the dashboard's POST/PUT /api/cron/jobs. The
//  schedule is picked as a time on chosen days, a repeat, one run, or
//  typed as Hermes reads it, with the plain-words line the Scheduled list
//  shows. The blueprint gallery fills one of Hermes' ready-made jobs and
//  creates it on the server.
//

import SwiftUI

struct CronJobEditorSheet: View {
    enum Target: Identifiable {
        case create
        case edit(CronJob)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let job): return "edit:\(job.id)"
            }
        }
    }

    let target: Target
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var draft = CronJobDraft()
    @State private var original = CronJobDraft()
    @State private var targets: [CronDeliveryTarget] = []
    @State private var seeded = false
    @State private var isSaving = false
    @State private var error: String?
    /// "Let the bot act on it" for a job delivered to a Bot Chat; off, its
    /// report just shows there (cron_bot_chat).
    @State private var botActs = false
    @State private var originalBotActs = false

    private var editedJob: CronJob? {
        if case .edit(let job) = target { return job }
        return nil
    }

    private var hasChanges: Bool {
        editedJob == nil || !draft.updates(from: original).isEmpty || botChoiceChanged
    }

    /// The job goes to a Bot Chat on a host whose plugin keeps the choice.
    private var offersBotChoice: Bool {
        appState.offersCronBotChatChoice && CronDeliveryTarget.deliversToBotChat(draft.deliver)
    }

    private var botChoiceChanged: Bool {
        offersBotChoice && botActs != originalBotActs
    }

    private var zoneLabel: String? {
        ProfileTimeZone.scheduleZoneLabel(profileSetting: appState.activeProfileTimeZoneSetting)
    }

    var body: some View {
        NavigationStack {
            // Settings' own page, as Edit Bot (Eric 2026-11-05).
            SettingsDetailContainer {
                if let error, !error.isEmpty {
                    Text(error)
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
                ConduitSettingsSection(title: AppLocalization.string("Name"), symbol: "textformat", tint: .conduitAccent) {
                    TextField(AppLocalization.string("Name, like Morning brief"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.sentences)
                }
                ConduitSettingsSection(title: AppLocalization.string("Prompt"), symbol: "text.bubble", tint: .blue) {
                    TextField(AppLocalization.string("What Hermes should do each time"), text: $draft.prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...10)
                }
                CronScheduleEditor(schedule: $draft.schedule, zoneLabel: zoneLabel)
                deliverySection
                if offersBotChoice {
                    botChoiceSection
                }
            }
            .tint(.conduitAccent)
            .navigationTitle(editedJob == nil ? AppLocalization.string("New scheduled job") : AppLocalization.string("Edit scheduled job"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(editedJob == nil ? AppLocalization.string("Create") : AppLocalization.string("Save")) {
                            save()
                        }
                        .disabled(!draft.canSave || !hasChanges)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving || (seeded && (draft != original || botChoiceChanged)))
        .task { await seed() }
    }

    private var deliverySection: some View {
        let choices = CronDeliveryTarget.choices(targets, keeping: draft.deliver)
        let selected = choices.first { $0.id == draft.deliver }
        return ConduitSettingsSection(title: AppLocalization.string("Delivery"), symbol: "paperplane", tint: .green) {
            ConduitMenuPicker(
                value: draft.deliver,
                choices: choices.map { (id: $0.id, title: CronDeliveryTarget.title($0)) },
                onSelect: { draft.deliver = $0 }
            ) {
                Text(AppLocalization.string("Deliver to")).foregroundStyle(.secondary)
            }
            if selected?.homeTargetSet == false {
                Text(AppLocalization.string("This platform has no home channel yet. Set one in Hermes, or the run is only saved."))
                    .settingsCaption()
            } else {
                Text(AppLocalization.string("Each run is also saved as its own conversation."))
                    .settingsCaption()
            }
        }
    }

    private var botChoiceSection: some View {
        CronBotChoiceSection(botActs: $botActs)
    }

    private func seed() async {
        if !seeded {
            if let job = editedJob {
                draft = CronJobDraft(job: job)
                botActs = appState.cronJobLetsBotAct(job.id)
                originalBotActs = botActs
            }
            original = draft
            seeded = true
        }
        // The list Hermes offers; without it the picker keeps Local and the
        // job's own target.
        targets = (try? await appState.loadCronDeliveryTargets()) ?? []
        // Whether this Hermes shows a Bot Chat job's report without a turn,
        // and the job's choice, when the Cron tab hasn't read them yet.
        if !appState.offersCronBotChatChoice, appState.supportsCronBotChatReports {
            await appState.refreshCronNotifications()
            if let job = editedJob, !botChoiceChanged {
                botActs = appState.cronJobLetsBotAct(job.id)
                originalBotActs = botActs
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                let profile = appState.activeProfile
                var jobID: String?
                if let job = editedJob {
                    try await appState.updateCronJob(job, updates: draft.updates(from: original))
                    jobID = job.id
                } else if let body = draft.createBody {
                    jobID = try await appState.createCronJob(body)?.id
                }
                // A new job just shows by default, so only "act" is sent for
                // it, which needs the id Hermes gave it.
                if offersBotChoice, editedJob == nil, botActs, jobID == nil {
                    Haptics.mutationCompleted(false)
                    appState.errorMessage = AppLocalization.string("The job is saved, but not whether the bot acts on it: \(HermesError.invalidResponse.localizedDescription)")
                    dismiss()
                    return
                }
                if offersBotChoice, let jobID, editedJob == nil ? botActs : botChoiceChanged {
                    do {
                        try await appState.setCronJobLetsBotAct(botActs, jobID: jobID, profile: profile)
                    } catch {
                        // The job itself is saved, so the sheet closes (a
                        // second Create would make it twice); the banner says
                        // what wasn't.
                        Haptics.mutationCompleted(false)
                        appState.errorMessage = AppLocalization.string("The job is saved, but not whether the bot acts on it: \(UserFacingError.message(for: error))")
                        dismiss()
                        return
                    }
                }
                Haptics.mutationCompleted(true)
                dismiss()
            } catch {
                Haptics.mutationCompleted(false)
                self.error = UserFacingError.message(for: error)
            }
        }
    }
}

extension CronDeliveryTarget {
    /// Whether a job's `deliver` names a Bot Chat (`bot-chat`, or
    /// `bot-chat:<profile>`), alone or among other targets.
    static func deliversToBotChat(_ deliver: String) -> Bool {
        deliver.split(separator: ",").contains { part in
            let token = part.trimmingCharacters(in: .whitespaces).lowercased()
            return token == "bot-chat" || token.hasPrefix("bot-chat:")
        }
    }

    /// A target's name in the pickers: Local and the blueprint's "origin"
    /// in words, a platform by the name Hermes gives it.
    static func title(_ target: CronDeliveryTarget) -> String {
        title(id: target.id, name: target.name)
    }

    static func title(id: String, name: String? = nil) -> String {
        switch id {
        case "local": return AppLocalization.string("Save only")
        case "origin": return AppLocalization.string("Home channel")
        default:
            if let name, !name.isEmpty, name != id { return name }
            return id.prefix(1).uppercased() + id.dropFirst()
        }
    }
}

/// The schedule part of the editor: how it repeats, its controls, and the
/// result in plain words.
private struct CronScheduleEditor: View {
    @Binding var schedule: CronScheduleDraft
    let zoneLabel: String?

    private var preview: String {
        guard let text = schedule.scheduleString else {
            return schedule.mode == .time
                ? AppLocalization.string("Pick at least one day.")
                : AppLocalization.string("Not a schedule yet.")
        }
        if let preview = schedule.previewSchedule,
           let words = CronScheduleText.describe(preview, zoneLabel: zoneLabel) {
            return words
        }
        return text
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Schedule"), symbol: "calendar.badge.clock", tint: .orange) {
            Picker(AppLocalization.string("Repeats"), selection: $schedule.mode) {
                Text(AppLocalization.string("At a time")).tag(CronScheduleDraft.Mode.time)
                Text(AppLocalization.string("Every…")).tag(CronScheduleDraft.Mode.interval)
                Text(AppLocalization.string("Once")).tag(CronScheduleDraft.Mode.once)
                Text(AppLocalization.string("Custom")).tag(CronScheduleDraft.Mode.custom)
            }
            .pickerStyle(.segmented)
            switch schedule.mode {
            case .time:
                DatePicker(AppLocalization.string("Time"), selection: timeBinding, displayedComponents: .hourAndMinute)
                CronWeekdayPicker(days: $schedule.days)
            case .interval:
                Stepper(value: $schedule.intervalValue, in: 1...999) {
                    Text(verbatim: String(schedule.intervalValue))
                        .monospacedDigit()
                }
                // "Every 2 hours" rather than a bare "2".
                .accessibilityValue(Text(preview))
                Picker(AppLocalization.string("Unit"), selection: $schedule.intervalUnit) {
                    Text(AppLocalization.string("Minutes")).tag(CronScheduleDraft.IntervalUnit.minutes)
                    Text(AppLocalization.string("Hours")).tag(CronScheduleDraft.IntervalUnit.hours)
                    Text(AppLocalization.string("Days")).tag(CronScheduleDraft.IntervalUnit.days)
                }
                .pickerStyle(.segmented)
            case .once:
                // A run that already passed stays as it was instead of
                // clamping to now on the first touch.
                DatePicker(AppLocalization.string("Runs at"), selection: $schedule.runAt, in: min(schedule.runAt, Date())..., displayedComponents: [.date, .hourAndMinute])
            case .custom:
                TextField(AppLocalization.string("0 9 * * 1 or every monday 9am"), text: $schedule.custom)
                    .scaledFont(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(preview)
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(schedule.scheduleString == nil ? Color.red : Color.conduitScheduled)
                if schedule.mode == .custom {
                    Text(AppLocalization.string("A cron expression, or a phrase Hermes reads, like every 2h or weekdays at 9am."))
                } else if schedule.mode == .time, let zoneLabel {
                    Text(AppLocalization.string("Times are in \(zoneLabel), the profile's time zone."))
                }
            }
        }
    }

    /// The time of day as a picker date: today at that wall-clock time.
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                schedule.hour = parts.hour ?? schedule.hour
                schedule.minute = parts.minute ?? schedule.minute
            }
        )
    }
}

/// Seven day toggles in the locale's week order.
private struct CronWeekdayPicker: View {
    @Binding var days: Set<Int>

    var body: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let names = calendar.weekdaySymbols
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 }
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { day in
                let isOn = days.contains(day)
                Button {
                    Haptics.selection()
                    if isOn { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(verbatim: symbols[day])
                        .scaledFont(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(isOn ? Color.conduitAccent : Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: names[day]))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Blueprints

/// Hermes' ready-made jobs. Picking one asks for its few blanks; Create
/// makes the job on Hermes and hands it back, so the list can open it.
struct CronBlueprintGallerySheet: View {
    let onCreated: (CronJob?) -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var blueprints: [CronBlueprint] = []
    @State private var targets: [CronDeliveryTarget] = []
    @State private var loading = true
    @State private var loadInFlight = false
    @State private var error: String?

    private var categories: [String] {
        var seen = Set<String>()
        return blueprints.map(\.category).filter { seen.insert($0).inserted }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && blueprints.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error, blueprints.isEmpty {
                    ContentUnavailableView {
                        Label(AppLocalization.string("Couldn’t load blueprints"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(AppLocalization.string("Try Again")) { Task { await load() } }
                            .buttonStyle(.settings)
                    }
                } else if blueprints.isEmpty {
                    ContentUnavailableView(
                        AppLocalization.string("No blueprints"),
                        systemImage: "square.grid.2x2",
                        description: Text(AppLocalization.string("This Hermes doesn't offer any ready-made jobs."))
                    )
                } else {
                    SettingsDetailContainer {
                        ForEach(categories, id: \.self) { category in
                            ConduitSettingsSection(
                                title: category.isEmpty ? AppLocalization.string("Blueprints") : category.prefix(1).uppercased() + category.dropFirst(),
                                symbol: "square.grid.2x2",
                                tint: .conduitAccent
                            ) {
                                ForEach(blueprints.filter { $0.category == category }) { blueprint in
                                    NavigationLink {
                                        CronBlueprintForm(blueprint: blueprint, targets: targets) { job in
                                            onCreated(job)
                                            dismiss()
                                        }
                                    } label: {
                                        HStack {
                                            blueprintRow(blueprint)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            SettingsChevron()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .tint(.conduitAccent)
            .navigationTitle(AppLocalization.string("Blueprints"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func blueprintRow(_ blueprint: CronBlueprint) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: blueprint.title)
                .scaledFont(.body.weight(.semibold))
            if !blueprint.summary.isEmpty {
                Text(verbatim: blueprint.summary)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !blueprint.scheduleText.isEmpty {
                Label {
                    Text(verbatim: blueprint.scheduleText)
                } icon: {
                    Image(systemName: "clock")
                }
                .scaledFont(.footnote)
                .foregroundStyle(Color.conduitScheduled)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        // Try Again tapped twice runs one load.
        guard !loadInFlight else { return }
        loadInFlight = true
        loading = true
        error = nil
        defer {
            loading = false
            loadInFlight = false
        }
        do {
            blueprints = try await appState.loadCronBlueprints()
            // Only widens the delivery choices; the blueprint's own stay.
            targets = (try? await appState.loadCronDeliveryTargets()) ?? []
            // Whether a blueprint delivered to a Bot Chat offers "When it
            // runs", when the Cron tab hasn't read it yet.
            if !appState.offersCronBotChatChoice, appState.supportsCronBotChatReports {
                await appState.refreshCronNotifications()
            }
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }
}

/// A Bot Chat job's "When it runs": Just show it (no turn, the default)
/// or Let the bot act on it (Hermes' turn). The editor's and a
/// blueprint's.
struct CronBotChoiceSection: View {
    @Binding var botActs: Bool

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("When it runs"), symbol: "person.crop.circle.badge.checkmark", tint: .purple) {
            Picker(AppLocalization.string("When it runs"), selection: $botActs) {
                Text(AppLocalization.string("Just show it")).tag(false)
                Text(AppLocalization.string("Let the bot act on it")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(botActs
                 ? AppLocalization.string("The bot reads each report, acts on what needs it and answers in its Bot Chat. Each run costs a reply from its model.")
                 : AppLocalization.string("Each report shows in the bot's Bot Chat as it is, with no reply. The bot sees it the next time you write."))
                .settingsCaption()
        }
    }
}

/// One blueprint's blanks, filled and sent to Hermes, which writes the
/// job's prompt and schedule from them.
private struct CronBlueprintForm: View {
    let blueprint: CronBlueprint
    let targets: [CronDeliveryTarget]
    let onCreated: (CronJob?) -> Void
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @State private var values: [String: String] = [:]
    @State private var isSaving = false
    @State private var error: String?
    /// "Let the bot act on it", for a blueprint delivered to a Bot Chat.
    @State private var botActs = false

    /// A Bot Chat delivery offers "When it runs", as the editor does.
    private var offersBotChoice: Bool {
        appState.offersCronBotChatChoice && CronDeliveryTarget.deliversToBotChat(values["deliver"] ?? "")
    }

    init(blueprint: CronBlueprint, targets: [CronDeliveryTarget], onCreated: @escaping (CronJob?) -> Void) {
        self.blueprint = blueprint
        self.targets = targets
        self.onCreated = onCreated
        _values = State(initialValue: blueprint.defaultValues)
    }

    var body: some View {
        SettingsDetailContainer {
            if !blueprint.summary.isEmpty {
                Text(verbatim: blueprint.summary)
                    .scaledFont(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            if let error, !error.isEmpty {
                Text(error)
                    .scaledFont(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            SettingsCard {
                ForEach(blueprint.fields) { field in
                    control(field)
                    if !field.help.isEmpty {
                        Text(verbatim: field.help)
                            .settingsCaption()
                    }
                }
            }
            if offersBotChoice {
                CronBotChoiceSection(botActs: $botActs)
            }
        }
        .navigationTitle(Text(verbatim: blueprint.title))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSaving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(AppLocalization.string("Create")) { create() }
                }
            }
        }
    }

    private func binding(_ field: CronBlueprint.Field) -> Binding<String> {
        Binding(
            get: { values[field.name] ?? "" },
            set: { values[field.name] = $0 }
        )
    }

    @ViewBuilder
    private func control(_ field: CronBlueprint.Field) -> some View {
        switch field.kind {
        case .time:
            DatePicker(
                field.label,
                selection: Binding(
                    get: {
                        let clock = CronBlueprint.clock(values[field.name] ?? "") ?? (hour: 8, minute: 0)
                        return Calendar.current.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: Date()) ?? Date()
                    },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        values[field.name] = CronBlueprint.clockText(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                    }
                ),
                displayedComponents: .hourAndMinute
            )
        case .weekdays, .choice:
            ConduitMenuPicker(
                value: values[field.name] ?? "",
                choices: (field.optional ? [(id: "", title: AppLocalization.string("None"))] : [])
                    + options(field).map { (id: $0, title: optionTitle($0, field: field)) },
                onSelect: { values[field.name] = $0 }
            ) {
                Text(verbatim: field.label).foregroundStyle(.secondary)
            }
        case .text:
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: field.label)
                    .scaledFont(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(field.label, text: binding(field), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
            }
        }
    }

    /// A field's choices; the delivery field lists this Hermes' platforms,
    /// and a value that isn't listed stays selectable.
    private func options(_ field: CronBlueprint.Field) -> [String] {
        var options = field.options
        if field.name == "deliver" {
            for target in targets where !options.contains(target.id) {
                options.append(target.id)
            }
        }
        if let current = values[field.name], !current.isEmpty, !options.contains(current) {
            options.append(current)
        }
        return options
    }

    private func optionTitle(_ option: String, field: CronBlueprint.Field) -> String {
        if field.kind == .weekdays {
            switch option {
            case "everyday": return AppLocalization.string("Every day")
            case "weekdays": return AppLocalization.string("Weekdays")
            case "weekends": return AppLocalization.string("Weekends")
            default: return option
            }
        }
        if field.name == "deliver" {
            return CronDeliveryTarget.title(id: option, name: targets.first { $0.id == option }?.name)
        }
        return option
    }

    private func create() {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                let profile = appState.activeProfile
                let acts = offersBotChoice && botActs
                let job = try await appState.instantiateCronBlueprint(blueprint, values: values)
                // A new job just shows by default, so only "act" is sent.
                if acts {
                    do {
                        guard let id = job?.id else { throw HermesError.invalidResponse }
                        try await appState.setCronJobLetsBotAct(true, jobID: id, profile: profile)
                    } catch {
                        // The job is made, so the form closes (a second
                        // Create would make it twice); the banner says what wasn't.
                        Haptics.mutationCompleted(false)
                        appState.errorMessage = AppLocalization.string("The job is saved, but not whether the bot acts on it: \(UserFacingError.message(for: error))")
                        onCreated(job)
                        return
                    }
                }
                Haptics.mutationCompleted(true)
                onCreated(job)
            } catch {
                Haptics.mutationCompleted(false)
                self.error = UserFacingError.message(for: error)
            }
        }
    }
}
