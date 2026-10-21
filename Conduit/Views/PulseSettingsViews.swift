//
//  PulseSettingsViews.swift
//  Conduit
//
//  Settings > Pulse (beta), on TestFlight and Xcode builds: Pulse on or
//  off, its chat, the shadow report's times, memory, reading older chats
//  and its latest checks (PulseSettings.swift). Every change goes to the
//  plugin and the page shows the state it answers with.
//

import SwiftUI

struct PulseSettingsPage: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var appLanguage = AppLanguageStore.shared

    @State private var state: PulseState?
    @State private var loadError: String?
    /// The step holding the page's one request slot; a switch of dashboard
    /// cancels it and frees the slot at once.
    @State private var workingID: UUID?
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

    private var client: PulseClient { appState.pulseClient }
    private var working: Bool { workingID != nil }

    var body: some View {
        SettingsDetailContainer {
            if let state {
                overviewSection(state)
                homeChatSection(state)
                if state.enabled {
                    reportSection(state)
                    memorySection(state)
                    if state.memory || state.backfill.phase != .none {
                        backfillSection(state)
                    }
                    if !state.recent.isEmpty {
                        recentSection(state)
                    }
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
        }
    }

    // MARK: Sections

    private func overviewSection(_ state: PulseState) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Pulse"), symbol: "waveform.path.ecg", tint: .conduitAura) {
            Text("Pulse watches your chats. For now it only sends a shadow report to its own chat at the times you set, listing what it would have brought up. Rate each line yes or no there to help tune it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle("Pulse", isOn: Binding(
                get: { state.enabled },
                set: { on in change(["enabled": on]) { $0.enabled = on } }
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
            if let notice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            if let chat = state.homeChat {
                SettingsMetricRow(label: AppLocalization.string("Chat"), value: chat.title, lineLimit: 1)
                if !chat.pinned {
                    Button(AppLocalization.string("Pin it")) {
                        run { _ in
                            try await appState.pinPulseHomeChat(id: chat.id)
                            return nil
                        }
                    }
                    .buttonStyle(.settings)
                    .disabled(working)
                    .accessibilityIdentifier("settings.pulse.pin")
                }
            } else {
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
            }
            if !state.homeProblem.isEmpty {
                // The plugin's own words, in English.
                Text(verbatim: state.homeProblem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func reportSection(_ state: PulseState) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Shadow report"), symbol: "doc.text.magnifyingglass", tint: .conduitAccent) {
            Toggle("Send shadow reports", isOn: Binding(
                get: { state.dailyReport },
                set: { on in change(["daily_report": on]) { $0.dailyReport = on } }
            ))
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.report")
            if state.dailyReport {
                reportTimes(state)
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
                if let next = state.nextReportAt {
                    SettingsMetricRow(
                        label: AppLocalization.string("Next report"),
                        value: next.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
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
                    Text("Report on").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings.pulse.profiles")
            }
            Button(AppLocalization.string("Send a report now")) {
                run { client in
                    try await client.sendReport()
                    if isShown(client) {
                        notice = AppLocalization.string("Pulse will send a report to its chat shortly.")
                    }
                    return nil
                }
            }
            .buttonStyle(.settings)
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.report-now")
        }
    }

    @ViewBuilder
    private func reportTimes(_ state: PulseState) -> some View {
        let times = draftTimes ?? state.reportTimes
        Text("Report times")
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

    private func memorySection(_ state: PulseState) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Memory"), symbol: "brain.head.profile", tint: .conduitAccent) {
            Toggle("Memory", isOn: Binding(
                get: { state.memory },
                set: { on in change(["memory": on]) { $0.memory = on } }
            ))
            .disabled(working)
            .accessibilityIdentifier("settings.pulse.memory")
            Text("Pulse keeps short notes on commitments, plans and interests from your chats, so its reports can bring them up later.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.memory {
                ForEach(PulseMemoryKind.sorted(state.memoryCounts.keys), id: \.self) { kind in
                    SettingsMetricRow(label: PulseMemoryKind.title(kind), value: String(state.memoryCounts[kind] ?? 0))
                }
                let used = state.tokensToday.formatted()
                let cap = state.dailyTokens.formatted()
                SettingsMetricRow(label: AppLocalization.string("Tokens today"), value: AppLocalization.string("\(used) of \(cap)"))
            }
            NavigationLink {
                PulseMemoryList()
                    .v2TabBarClearance()
            } label: {
                Label(AppLocalization.string("What Pulse remembers"), systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("settings.pulse.remembers")
        }
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

    private func recentSection(_ state: PulseState) -> some View {
        ConduitSettingsSection(title: AppLocalization.string("Recent checks"), symbol: "list.bullet.clipboard", tint: .conduitAura) {
            DisclosureGroup(isExpanded: $showsRecent) {
                VStack(alignment: .leading, spacing: 10) {
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
                .padding(.top, 8)
            } label: {
                Text("Pulse's latest checks and reports")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        default: return kind
        }
    }

    private static func list(_ names: [String]) -> String {
        names.formatted(.list(type: .and).locale(AppLocalization.formattingLocale))
    }

    // MARK: Actions

    private func load() async {
        let client = self.client
        do {
            let next = try await client.state()
            guard isShown(client), !Task.isCancelled else { return }
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
    private func change(_ changes: [String: Any], optimistic: ((inout PulseState) -> Void)? = nil) {
        guard !working else { return }
        if let optimistic, var shown = state {
            optimistic(&shown)
            state = shown
        }
        run { client in try await client.update(changes) }
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
                // The chat's own words.
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
            if let mentioned = item.mentionedAt {
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
