//
//  HermesCallSettingsViews.swift
//  Conduit
//
//  Voice settings for Hermes calls you (#449): whether Hermes may call,
//  whether "call me when it's done" works, and the profile's limits. The
//  settings live with the notifier plugin on the Hermes host, per profile.
//

import SwiftUI

/// What Voice settings needs to show the profile's call settings.
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
}

struct HermesCallSettingsSection: View {
    let model: HermesCallSettingsModel
    @State private var draft: HermesCallSettings
    @State private var loadFailed = false
    @State private var saveTask: Task<Void, Never>?

    init(model: HermesCallSettingsModel) {
        self.model = model
        _draft = State(initialValue: model.status?.settings ?? HermesCallSettings())
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

    private func binding<Value>(_ keyPath: WritableKeyPath<HermesCallSettings, Value>) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in change { $0[keyPath: keyPath] = value } }
        )
    }

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Calls from Hermes"), symbol: "phone.arrow.down.left", tint: .green) {
            if let status = model.status {
                Toggle("Hermes can call me", isOn: binding(\.enabled))
                    .disabled(!status.paired)
                Text("When a job you asked about is done, Hermes calls you so you can talk it through. For now the call arrives as a “Hermes wants to talk” notification: tap Talk to answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !status.paired {
                    Text("Turn on notifications for this profile first, in Settings under Notifications: Hermes calls you through them.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if draft.enabled {
                    Toggle("Call when I ask", isOn: binding(\.whenAsked))
                    Text("Say “call me when it's done” during a live call. Hermes calls about that job once the call has ended; if it finishes while you're still talking, you hear about it in the call instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Time between calls", selection: binding(\.minGapSeconds)) {
                        ForEach(HermesCallSettingsFormat.gapChoices(bounds: status.minGapBounds, current: draft.minGapSeconds), id: \.self) { seconds in
                            Text(verbatim: HermesCallSettingsFormat.gap(seconds: seconds)).tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
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
    }

    private func load() async {
        loadFailed = false
        loadFailed = !(await model.load())
    }
}
