//
//  HermesCallSettingsViews.swift
//  Conduit
//
//  Settings › Calls from Hermes (#449): whether Hermes may call, whether
//  "call me when it's done" works, whether Hermes may decide to call and
//  call about approvals and questions (plugin 0.14+), the user's note on
//  what's worth such a call (plugin 0.16+), the profile's limits, a test
//  call and how to use calls. The settings live with the notifier plugin
//  on the Hermes host, per profile.
//  Design: /mnt/project-files/designs/hermes-calls-teaching.md
//

import SwiftUI

/// What Settings needs to show the profile's call settings.
struct HermesCallSettingsModel {
    var profile: String
    /// Nil until read from the host.
    var status: HermesCallsStatus?
    /// Reads them again; false when the host couldn't answer.
    var load: () async -> Bool
    /// The settings last read from the host, as they are now.
    var current: @MainActor () -> HermesCallSettings?
    /// Saves every setting; false when the host didn't take them.
    var save: (HermesCallSettings) async -> Bool
}

/// Formats for the call settings, in the app's language.
enum HermesCallSettingsFormat {
    /// The spacing choices offered, inside the host's bounds, with the
    /// current one kept even when it isn't a usual step.
    static func gapChoices(bounds: ClosedRange<Int>, current: Int) -> [Int] {
        let steps = [30, 60, 120, 300, 600, 1_800, 3_600].filter(bounds.contains)
        return Array(Set(steps + [current])).sorted()
    }

    /// "2 minutes", "1 hour, 30 minutes".
    static func gap(seconds: Int, locale: Locale = AppLocalization.formattingLocale) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds)"
    }

    /// What the test call sends, in the app's language.
    static var testCallPrompt: String { AppLocalization.string("Call me now to test calls.") }

    /// What Have Hermes watch for this sends: a scheduled check for what
    /// the call note describes, the note as the host keeps it.
    static func watchPrompt(_ note: String) -> String {
        AppLocalization.string("Set up a scheduled check that calls me when this happens:\n\(rules(note))")
    }

    /// The note as the host keeps it: each line trimmed, no empty lines.
    static func rules(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The host counts characters as Unicode scalars (Python), so a note
    /// is held to its limit in those, not in what Swift counts. Whole
    /// characters only: cut inside one (a family emoji, a flag), half of it
    /// would stay.
    static func limitRules(_ text: String, to max: Int) -> String? {
        guard text.unicodeScalars.count > max else { return nil }
        var kept = ""
        var count = 0
        for character in text {
            let scalars = character.unicodeScalars.count
            guard count + scalars <= max else { break }
            kept.append(character)
            count += scalars
        }
        return kept
    }
}

/// Settings › Calls from Hermes.
struct HermesCallsSettingsPage: View {
    let model: HermesCallSettingsModel
    /// Whether the host hears about calls the user declined or missed.
    let hearsMissedCalls: Bool
    let startTestCall: () -> Void
    /// Opens a chat asking Hermes to watch for what the note describes.
    let startWatch: (String) -> Void
    @ObservedObject var appLanguage = AppLanguageStore.shared

    var body: some View {
        SettingsDetailContainer {
            HermesCallSettingsSection(model: model, startTestCall: startTestCall, startWatch: startWatch)
            HermesCallsHowToSection(settings: model.status?.settings, hearsMissedCalls: hearsMissedCalls)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// What to say to get a call, and what else to know.
struct HermesCallsHowToSection: View {
    /// The host's settings, which say what it can do; nil until read.
    let settings: HermesCallSettings?
    let hearsMissedCalls: Bool

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("How to use calls"), symbol: "text.bubble", tint: .conduitAccent) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Ask in any chat or voice call: “Call me when the tests finish.” Your iPhone rings once the job is done, and answering opens voice in that chat.", systemImage: "phone.arrow.down.left")
                if settings?.decides != nil {
                    Label("To be called when something happens, ask Hermes to watch for it: “Check my homelab every 5 minutes and call me if it's down for more than 10 minutes.” Hermes sets up a scheduled check that calls you.", systemImage: "binoculars")
                }
                if settings?.rules != nil {
                    Label("To let Hermes call on its own, turn on Hermes decides when to call and write what's worth a call. Hermes checks your note before each call it decides to make.", systemImage: "sparkles")
                } else if settings?.decides != nil {
                    Label("To let Hermes call on its own when news can't wait, turn on Hermes decides when to call.", systemImage: "sparkles")
                }
                if hearsMissedCalls {
                    Label("If you decline or miss a call, Hermes knows the next time you write in that chat.", systemImage: "phone.down")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct HermesCallSettingsSection: View {
    let model: HermesCallSettingsModel
    var startTestCall: (() -> Void)?
    var startWatch: ((String) -> Void)?
    @State private var draft: HermesCallSettings
    /// The note as typed; saved when the field lets go of the keyboard.
    @State private var rulesText: String
    @FocusState private var rulesFocused: Bool
    /// This iPhone's own setting, not the host's.
    @AppStorage(HermesNativeCalls.ringsKey) private var ringsLikeCall = true
    @State private var loadFailed = false
    @State private var saveTask: Task<Void, Never>?

    init(model: HermesCallSettingsModel, startTestCall: (() -> Void)? = nil, startWatch: ((String) -> Void)? = nil) {
        self.model = model
        self.startTestCall = startTestCall
        self.startWatch = startWatch
        let settings = model.status?.settings ?? HermesCallSettings()
        _draft = State(initialValue: settings)
        _rulesText = State(initialValue: settings.rules ?? "")
    }

    /// Saved once the user stops tapping, so a stepper run is one save.
    /// Saves go one at a time, so the newest change lands last; one the host
    /// didn't take puts back what it holds.
    private func change(_ edit: (inout HermesCallSettings) -> Void) {
        edit(&draft)
        let previous = saveTask
        previous?.cancel()
        let settings = draft
        let save = model.save
        let current = model.current
        let editTimeSettings = model.status?.settings
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            await previous?.value
            guard !Task.isCancelled else { return }
            let saved = await save(settings)
            guard !Task.isCancelled else { return }
            saveTask = nil
            // What the host holds now, including saves since this edit.
            if !saved, let hostSettings = current() ?? editTimeSettings { draft = hostSettings }
        }
    }

    /// Saves the note if it changed. Calls you ask for don't read it.
    private func commitRules() {
        guard draft.rules != nil else { return }
        let rules = HermesCallSettingsFormat.rules(rulesText)
        guard rules != draft.rules else { return }
        change { $0.rules = rules }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<HermesCallSettings, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in change { $0[keyPath: keyPath] = value } }
        )
    }

    /// A setting only newer hosts have: shown only when the host has it.
    private func optionalBinding(_ keyPath: WritableKeyPath<HermesCallSettings, Bool?>) -> Binding<Bool> {
        Binding(
            get: { draft[keyPath: keyPath] ?? false },
            set: { value in change { $0[keyPath: keyPath] = value } }
        )
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Calls from Hermes"), symbol: "phone.arrow.down.left", tint: .green) {
            if let status = model.status {
                Toggle("Hermes can call me", isOn: binding(\.enabled))
                    .disabled(!status.paired)
                Text("When a job you asked about is done, Hermes calls you so you can talk it through. Your iPhone rings like a phone call; where it can't, a “Hermes wants to talk” notification comes instead: tap Talk to answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !status.paired {
                    Text("Turn on notifications for this profile first, in Settings under Notifications: Hermes calls you through them.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if draft.enabled {
                    if HermesNativeCalls.offersRinging {
                        Toggle("Ring like a phone call", isOn: $ringsLikeCall)
                            .onChange(of: ringsLikeCall) { _, _ in HermesNativeCalls.shared.ringingSettingChanged() }
                        Text("On this iPhone and your Apple Watch. Off, a “Hermes wants to talk” notification comes instead: tap Talk to answer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Call when I ask", isOn: binding(\.whenAsked))
                    Text("Say “call me when it's done” during a live call, or ask Hermes in a chat to call you. Hermes calls about that job once the call has ended; if it finishes while you're still talking, you hear about it in the call instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // The call tool came with plugin 0.14, as did "decides".
                    if let startTestCall, status.paired, draft.whenAsked, draft.decides != nil {
                        testCallRow(startTestCall)
                    }
                    if draft.decides != nil {
                        Toggle("Hermes decides when to call", isOn: optionalBinding(\.decides))
                        Text("Hermes may also call on its own when news can't wait, within your limits. It never calls for routine updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if draft.decides == true, draft.rules != nil {
                        rulesField(max: status.rulesMax)
                        // A check's calls are ones the user asked for.
                        if let startWatch, status.paired, draft.whenAsked,
                           !HermesCallSettingsFormat.rules(rulesText).isEmpty {
                            watchRow { startWatch(rulesText) }
                        }
                    }
                    if draft.alerts != nil {
                        Toggle("Call about approvals and questions", isOn: optionalBinding(\.alerts))
                        Text("Hermes calls when it has waited a minute for your OK or an answer, or when a request fails. In a live call you can answer out loud.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ConduitMenuPicker(
                        value: draft.minGapSeconds,
                        choices: HermesCallSettingsFormat.gapChoices(bounds: status.minGapBounds, current: draft.minGapSeconds)
                            .map { (id: $0, title: HermesCallSettingsFormat.gap(seconds: $0)) },
                        onSelect: { seconds in change { $0.minGapSeconds = seconds } }
                    ) {
                        Text("Time between calls").foregroundStyle(.secondary)
                    }
                    Stepper(value: binding(\.perHour), in: status.perHourBounds) {
                        Text(AppLocalization.string("Calls per hour: \(String(draft.perHour))"))
                    }
                    Stepper(value: binding(\.perDay), in: status.perDayBounds) {
                        Text(AppLocalization.string("Calls per day: \(String(draft.perDay))"))
                    }
                    Text("Past a limit, a finished job sends its usual notification instead of calling. These settings are this profile's, kept on your Hermes host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if loadFailed {
                Text("Couldn't read Hermes' call settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(AppLocalization.string("Try again")) {
                    Task { await load() }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading call settings…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: model.profile) { await load() }
        .onChange(of: model.status) { _, newValue in
            // The host's answer, unless a change of this view is on its way.
            // (A change still waiting when the view goes is saved anyway:
            // its task outlives the view.)
            guard saveTask == nil, let settings = newValue?.settings else { return }
            draft = settings
        }
        // The host's note, unless the user is writing one.
        .onChange(of: draft.rules) { _, rules in
            guard !rulesFocused else { return }
            rulesText = rules ?? ""
        }
        .onChange(of: rulesFocused) { _, focused in
            if !focused { commitRules() }
        }
        .onDisappear { commitRules() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { rulesFocused = false }
            }
        }
    }

    private func testCallRow(_ start: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: start) {
                Label(AppLocalization.string("Try a test call"), systemImage: "phone.fill")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings.hermesCallsTest")
            Text(AppLocalization.string("Opens a new chat with “\(HermesCallSettingsFormat.testCallPrompt)” ready to send. Send it, and your iPhone rings when Hermes replies."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func watchRow(_ start: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: start) {
                Label(AppLocalization.string("Have Hermes watch for this"), systemImage: "binoculars.fill")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings.hermesCallsWatch")
            Text("Hermes doesn't check for what your note describes on its own. This opens a new chat asking it to set up a scheduled check that calls you when it happens.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rulesField(max: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's worth a call")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            TextField(
                AppLocalization.string("For example: only if production is down or a deploy fails. Never before 9 am."),
                text: $rulesText,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(3...8)
            .focused($rulesFocused)
            .accessibilityLabel(Text(AppLocalization.string("What's worth a call")))
            .accessibilityIdentifier("settings.hermesCallsRules")
            .onChange(of: rulesText) { _, text in
                if let limited = HermesCallSettingsFormat.limitRules(text, to: max) { rulesText = limited }
            }
            // Kept in the layout, so the caption below doesn't jump as the
            // field gains and loses focus.
            Text(verbatim: "\(rulesText.unicodeScalars.count)/\(max)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(rulesFocused ? 1 : 0)
                .accessibilityHidden(!rulesFocused)
            Text("Hermes reads this before each call it decides to make, and calls only if the news fits. Calls you ask for don't depend on it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        loadFailed = false
        loadFailed = !(await model.load())
    }
}
