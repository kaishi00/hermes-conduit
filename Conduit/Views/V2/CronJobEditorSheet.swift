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

    private var editedJob: CronJob? {
        if case .edit(let job) = target { return job }
        return nil
    }

    private var hasChanges: Bool {
        editedJob == nil || !draft.updates(from: original).isEmpty
    }

    private var zoneLabel: String? {
        ProfileTimeZone.scheduleZoneLabel(profileSetting: appState.activeProfileTimeZoneSetting)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error, !error.isEmpty {
                    Section {
                        Text(error)
                            .scaledFont(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    TextField(AppLocalization.string("Name, like Morning brief"), text: $draft.name)
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text(AppLocalization.string("Name"))
                }
                Section {
                    TextField(AppLocalization.string("What Hermes should do each time"), text: $draft.prompt, axis: .vertical)
                        .lineLimit(3...10)
                } header: {
                    Text(AppLocalization.string("Prompt"))
                }
                CronScheduleEditor(schedule: $draft.schedule, zoneLabel: zoneLabel)
                deliverySection
            }
            .scrollDismissesKeyboard(.interactively)
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
        .interactiveDismissDisabled(isSaving || (seeded && draft != original))
        .task { await seed() }
    }

    private var deliverySection: some View {
        let choices = CronDeliveryTarget.choices(targets, keeping: draft.deliver)
        let selected = choices.first { $0.id == draft.deliver }
        return Section {
            Picker(AppLocalization.string("Deliver to"), selection: $draft.deliver) {
                ForEach(choices) { target in
                    Text(verbatim: CronDeliveryTarget.title(target)).tag(target.id)
                }
            }
        } header: {
            Text(AppLocalization.string("Delivery"))
        } footer: {
            if selected?.homeTargetSet == false {
                Text(AppLocalization.string("This platform has no home channel yet. Set one in Hermes, or the run is only saved."))
            } else {
                Text(AppLocalization.string("Each run is also saved as its own conversation."))
            }
        }
    }

    private func seed() async {
        if !seeded {
            if let job = editedJob {
                draft = CronJobDraft(job: job)
            }
            original = draft
            seeded = true
        }
        // The list Hermes offers; without it the picker keeps Local and the
        // job's own target.
        targets = (try? await appState.loadCronDeliveryTargets()) ?? []
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                if let job = editedJob {
                    try await appState.updateCronJob(job, updates: draft.updates(from: original))
                } else if let body = draft.createBody {
                    _ = try await appState.createCronJob(body)
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
        Section {
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
                    .autocorrectionDisabled()
            }
        } header: {
            Text(AppLocalization.string("Schedule"))
        } footer: {
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
                    }
                } else if blueprints.isEmpty {
                    ContentUnavailableView(
                        AppLocalization.string("No blueprints"),
                        systemImage: "square.grid.2x2",
                        description: Text(AppLocalization.string("This Hermes doesn't offer any ready-made jobs."))
                    )
                } else {
                    List {
                        ForEach(categories, id: \.self) { category in
                            Section {
                                ForEach(blueprints.filter { $0.category == category }) { blueprint in
                                    NavigationLink {
                                        CronBlueprintForm(blueprint: blueprint, targets: targets) { job in
                                            onCreated(job)
                                            dismiss()
                                        }
                                    } label: {
                                        blueprintRow(blueprint)
                                    }
                                }
                            } header: {
                                if !category.isEmpty {
                                    Text(verbatim: category.prefix(1).uppercased() + category.dropFirst())
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
        } catch {
            self.error = UserFacingError.message(for: error)
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

    init(blueprint: CronBlueprint, targets: [CronDeliveryTarget], onCreated: @escaping (CronJob?) -> Void) {
        self.blueprint = blueprint
        self.targets = targets
        self.onCreated = onCreated
        _values = State(initialValue: blueprint.defaultValues)
    }

    var body: some View {
        Form {
            if !blueprint.summary.isEmpty {
                Section {
                    Text(verbatim: blueprint.summary)
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if let error, !error.isEmpty {
                Section {
                    Text(error)
                        .scaledFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
            ForEach(blueprint.fields) { field in
                Section {
                    control(field)
                } header: {
                    Text(verbatim: field.label)
                } footer: {
                    if !field.help.isEmpty {
                        Text(verbatim: field.help)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
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
                AppLocalization.string("Time"),
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
            Picker(selection: binding(field)) {
                if field.optional {
                    Text(AppLocalization.string("None")).tag("")
                }
                ForEach(options(field), id: \.self) { option in
                    Text(verbatim: optionTitle(option, field: field)).tag(option)
                }
            } label: {
                Text(verbatim: field.label)
            }
        case .text:
            TextField(field.label, text: binding(field), axis: .vertical)
                .lineLimit(1...6)
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
                let job = try await appState.instantiateCronBlueprint(blueprint, values: values)
                Haptics.mutationCompleted(true)
                onCreated(job)
            } catch {
                Haptics.mutationCompleted(false)
                self.error = UserFacingError.message(for: error)
            }
        }
    }
}
