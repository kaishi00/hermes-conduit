//
//  V2TasksView.swift
//  Conduit
//
//  Tasks: a glass segmented control over the Kanban board (its lanes as
//  side-by-side columns) and the scheduled jobs (schedule, next run, and an
//  on/off switch). Each scheduled run is its own conversation, listed in
//  Chats under the Scheduled filter.
//

import SwiftUI

struct V2TasksView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage("conduit.v2.tasksSegment") private var segmentRaw = Segment.board.rawValue
    /// How far a page slides: the pages' own width.
    @State private var pageWidth: CGFloat = 0

    enum Segment: String, Hashable {
        case board
        case scheduled
    }

    private var segment: Binding<Segment> {
        Binding(
            get: { Segment(rawValue: segmentRaw) ?? .board },
            set: { segmentRaw = $0.rawValue }
        )
    }

    var body: some View {
        let selected = segment.wrappedValue
        ZStack {
            V2Backdrop()
            // Both pages stay laid out full size, Board left of Scheduled as
            // in the control, and slide side by side: a switch moves two
            // layers instead of building the other page again, and the Board
            // keeps its scroll position. The page out of sight stops loading
            // (`isTabActive`), takes no touches and is hidden from
            // VoiceOver.
            ZStack {
                page(.board, selected: selected) {
                    KanbanView(columnsLayout: true)
                        .padding(.horizontal, 14)
                }
                page(.scheduled, selected: selected) {
                    V2ScheduledList()
                }
            }
            .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: selected)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                if abs(width - pageWidth) > 0.5 { pageWidth = width }
            }
            .v2ProfileSwitchContent()
        }
        // The control rides in the header, so the pages scroll under one
        // soft edge, as a chat does under its header, instead of stopping
        // at a hard line below the control.
        .v2EdgeBar(.top) {
            VStack(spacing: 2) {
                V2TopBar()
                V2SegmentedControl(
                    selection: segment,
                    options: [
                        (value: Segment.board, title: AppLocalization.string("Board")),
                        (value: Segment.scheduled, title: AppLocalization.string("Scheduled"))
                    ]
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MinimisedLiveVoiceBar()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(V2Tab.tasks.title)
        // A task to show (a Pulse card's) is on the Board.
        .onChange(of: appState.kanbanTaskOpenRequest, initial: true) { _, request in
            if request != nil { segmentRaw = Segment.board.rawValue }
        }
    }

    /// Under Reduce Motion the pages only crossfade.
    private func page<Content: View>(
        _ page: Segment,
        selected: Segment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isShown = page == selected
        // -1 before the shown page, 1 after it; an offset doesn't mirror on
        // its own, so right to left the Board sits on the right.
        let leading: CGFloat = layoutDirection == .rightToLeft ? 1 : -1
        let side: CGFloat = isShown ? 0 : (page == .board ? leading : -leading)
        // Until the width is known the other page hides instead.
        let slides = !reduceMotion && pageWidth > 0
        return content()
            .transformEnvironment(\.v2Shell) { $0.isTabActive = $0.isTabActive && isShown }
            .offset(x: slides ? side * pageWidth : 0)
            .opacity(isShown || slides ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}

/// The scheduled jobs: pinned ones first, then active ones, each with its
/// schedule, next run and an on/off switch (Pause / Resume). Tapping a job
/// opens its detail with Run now and its run history; touch and hold or a
/// swipe gives the same actions as a chat row (Pin, Run now, Pause/Resume).
struct V2ScheduledList: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.v2Shell) private var shell
    @State private var selectedJob: CronJob?
    @State private var jobPendingDeletion: CronJob?
    @State private var editorTarget: CronJobEditorSheet.Target?
    @State private var showingBlueprints = false
    /// A job a blueprint just made, opened once the gallery has closed.
    @State private var createdJob: CronJob?
    /// Pinned jobs, per profile: "profile\tjobID" lines. Kept on the phone;
    /// Hermes has no pin for a job.
    @AppStorage("conduit.v2.pinnedCronJobs") private var pinnedRaw = ""

    private var jobs: [CronJob] {
        CronJobFilter.visibleJobs(appState.cronJobs, filter: .all, query: "")
    }

    private func pinKey(_ job: CronJob) -> String {
        "\(appState.activeProfile)\t\(job.id)"
    }

    private var pinKeys: [String] {
        pinnedRaw.split(separator: "\n").map(String.init)
    }


    private func togglePin(_ job: CronJob) {
        Haptics.light()
        let key = pinKey(job)
        var keys = pinKeys
        if keys.contains(key) {
            keys.removeAll { $0 == key }
        } else {
            keys.append(key)
        }
        pinnedRaw = keys.joined(separator: "\n")
    }

    var body: some View {
        let all = jobs
        // In the order they were pinned.
        var seen = Set<String>()
        let pinned = pinKeys.compactMap { key in
            seen.insert(key).inserted ? all.first { pinKey($0) == key } : nil
        }
        // Parsed once per pass; each row is told whether it is pinned.
        let pins = Set(pinKeys)
        let others = all.filter { !pins.contains(pinKey($0)) }
        Group {
            if all.isEmpty && !appState.cronJobsLoading {
                let empty = CronJobFilter.emptyState(filter: .all, hasJobs: false, isSearching: false)
                ScrollView {
                    ContentUnavailableView {
                        Label(empty.title, systemImage: "clock")
                    } description: {
                        Text(empty.description)
                    } actions: {
                        createButtons
                    }
                    .padding(.top, 60)
                }
            } else if all.isEmpty {
                // In a scroll view so pull to refresh still works while loading.
                ScrollView {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 140)
                }
            } else {
                List {
                    Section {
                        createButtons
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                    if !pinned.isEmpty {
                        Section {
                            ForEach(pinned) { row($0, pinned: true) }
                        } header: {
                            sectionHeader(AppLocalization.string("Pinned"))
                        }
                    }
                    // A "Jobs" header only when it separates the jobs from
                    // pins; otherwise the section starts without a gap.
                    // Both shapes carry one identity, but a first pin or last
                    // unpin still swaps the section between them.
                    if pinned.isEmpty || others.isEmpty {
                        Section {
                            ForEach(others) { row($0, pinned: false) }
                        } footer: {
                            listFooter
                        }
                        .id("jobs")
                    } else {
                        Section {
                            ForEach(others) { row($0, pinned: false) }
                        } header: {
                            sectionHeader(AppLocalization.string("Jobs"))
                        } footer: {
                            listFooter
                        }
                        .id("jobs")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 1)
                .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: pinnedRaw)
            }
        }
        // A hidden Tasks tab stays mounted; it loads when shown, like Chats.
        .task(id: "\(appState.activeProfile)|\(appState.isConnected)|\(shell.isTabActive)") {
            guard shell.isTabActive else { return }
            await appState.refreshCronContent()
        }
        .refreshable { await appState.refreshCronContent() }
        .sheet(item: $selectedJob) {
            CronJobDetailSheet(job: $0)
                .environmentObject(appState)
        }
        .sheet(item: $editorTarget) {
            CronJobEditorSheet(target: $0)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showingBlueprints, onDismiss: {
            if let createdJob {
                self.createdJob = nil
                selectedJob = createdJob
            }
        }) {
            CronBlueprintGallerySheet { createdJob = $0 }
                .environmentObject(appState)
        }
        .alert("Delete scheduled job?", isPresented: Binding(
            get: { jobPendingDeletion != nil },
            set: { if !$0 { jobPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let job = jobPendingDeletion else { return }
                jobPendingDeletion = nil
                let key = pinKey(job)
                Task {
                    let deleted = await appState.deleteCronJob(job)
                    Haptics.mutationCompleted(deleted)
                    if deleted {
                        pinnedRaw = pinKeys.filter { $0 != key }.joined(separator: "\n")
                    }
                }
            }
            Button("Cancel", role: .cancel) { jobPendingDeletion = nil }
        } message: {
            Text(AppLocalization.string("This removes \(jobPendingDeletion?.displayName ?? "") from Hermes, so it won't run again. Chats from its past runs are kept."))
        }
    }

    /// New job and From a blueprint, over the list (or in its empty state).
    private var createButtons: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.light()
                editorTarget = .create
            } label: {
                Label(AppLocalization.string("New job"), systemImage: "plus")
            }
            .buttonStyle(.settingsPrimary)
            Button {
                Haptics.light()
                showingBlueprints = true
            } label: {
                Label(AppLocalization.string("From a blueprint"), systemImage: "square.grid.2x2")
            }
            .buttonStyle(.settings)
        }
        .disabled(appState.dashboardTicketBridge == nil)
    }

    /// Runs are kept out of the All list in Chats, so a job running every
    /// few minutes doesn't bury the conversations; the Scheduled filter
    /// there lists them, one tap away.
    private var listFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string("Each run is saved as its own conversation. Chats lists them under the Scheduled filter. Ask Hermes to add or change a schedule."))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Haptics.light()
                shell.showScheduledRuns()
            } label: {
                Label(AppLocalization.string("Show runs in Chats"), systemImage: "bubble.left.and.bubble.right")
                    .scaledFont(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(.conduitAccent)
        }
        .padding(.top, 6)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .scaledFont(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func actions(_ job: CronJob, pinned: Bool) -> some View {
        Button {
            togglePin(job)
        } label: {
            Label(
                pinned ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"),
                systemImage: pinned ? "pin.slash" : "pin"
            )
        }
        if !job.isFinished {
            Button {
                Haptics.medium()
                Task { _ = await appState.performCronAction(.trigger, for: job) }
            } label: {
                Label(AppLocalization.string("Run now"), systemImage: "play.fill")
            }
            .disabled(appState.cronJobActionID != nil)
            Button {
                Haptics.selection()
                Task { _ = await appState.performCronAction(job.enabled ? .pause : .resume, for: job) }
            } label: {
                Label(
                    job.enabled ? AppLocalization.string("Pause") : AppLocalization.string("Resume"),
                    systemImage: job.enabled ? "pause" : "play"
                )
            }
            .disabled(appState.cronJobActionID != nil)
        }
        Button {
            selectedJob = job
        } label: {
            Label(AppLocalization.string("Details"), systemImage: "info.circle")
        }
        Button {
            editorTarget = .edit(job)
        } label: {
            Label(AppLocalization.string("Edit"), systemImage: "pencil")
        }
        .disabled(appState.dashboardTicketBridge == nil)
        Button(role: .destructive) {
            jobPendingDeletion = job
        } label: {
            Label(AppLocalization.string("Delete"), systemImage: "trash")
        }
        .disabled(appState.cronJobActionID != nil)
    }

    private func row(_ job: CronJob, pinned: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                Haptics.light()
                selectedJob = job
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if pinned {
                            Image(systemName: "pin.fill")
                                .scaledFont(.caption2.weight(.bold))
                                .foregroundStyle(Color.conduitAccent)
                                .accessibilityLabel(AppLocalization.string("Pinned"))
                        }
                        Text(job.displayName)
                            .scaledFont(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(CronScheduleText.describe(job, zoneLabel: scheduleZoneLabel) ?? AppLocalization.string("No schedule"))
                        .scaledFont(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .scaledFont(.caption.weight(.semibold))
                            .conduitFixedGlyph()
                            .accessibilityHidden(true)
                        Text(nextRunLine(job))
                            .lineLimit(1)
                    }
                    .scaledFont(.footnote)
                    .foregroundStyle(job.isActive ? Color.conduitScheduled : Color.primary.opacity(0.45))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(AppLocalization.string("Opens the job's details and run history. Touch and hold for more actions."))

            if !job.isFinished {
                Toggle(isOn: Binding(
                    get: { job.enabled },
                    set: { on in
                        Haptics.selection()
                        Task { _ = await appState.performCronAction(on ? .resume : .pause, for: job) }
                    }
                )) {
                    Text(job.displayName)
                }
                .labelsHidden()
                .accessibilityLabel(Text(job.displayName))
                .tint(.conduitAccent)
                .disabled(appState.cronJobActionID != nil)
            }
        }
        .padding(.vertical, 4)
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
        .listRowBackground(Color.primary.opacity(0.06))
        .contextMenu { actions(job, pinned: pinned) }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                togglePin(job)
            } label: {
                Label(
                    pinned ? AppLocalization.string("Unpin") : AppLocalization.string("Pin"),
                    systemImage: pinned ? "pin.slash" : "pin"
                )
            }
            .tint(.conduitAccent)
            // On the side away from Run now, so it isn't hit by accident.
            // Not a destructive role: that removes the row before the
            // confirmation is answered.
            Button {
                Haptics.light()
                jobPendingDeletion = job
            } label: {
                Label(AppLocalization.string("Delete"), systemImage: "trash")
            }
            .tint(.red)
            .disabled(appState.cronJobActionID != nil)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !job.isFinished {
                Button {
                    Haptics.medium()
                    Task { _ = await appState.performCronAction(.trigger, for: job) }
                } label: {
                    Label(AppLocalization.string("Run now"), systemImage: "play.fill")
                }
                .tint(.conduitScheduled)
                .disabled(appState.cronJobActionID != nil)
                Button {
                    Haptics.selection()
                    Task { _ = await appState.performCronAction(job.enabled ? .pause : .resume, for: job) }
                } label: {
                    Label(
                        job.enabled ? AppLocalization.string("Pause") : AppLocalization.string("Resume"),
                        systemImage: job.enabled ? "pause" : "play"
                    )
                }
                .tint(.orange)
                .disabled(appState.cronJobActionID != nil)
            }
        }
    }

    /// The profile zone Hermes runs schedules in, when it isn't this
    /// iPhone's (a schedule's times are that zone's wall clock).
    private var scheduleZoneLabel: String? {
        ProfileTimeZone.scheduleZoneLabel(profileSetting: appState.activeProfileTimeZoneSetting)
    }

    /// "Next run in 3 hours" or "Next run Monday 8:00 AM", the job's state
    /// when it won't run again.
    private func nextRunLine(_ job: CronJob) -> String {
        guard job.isActive else { return job.statusLabel }
        guard let raw = job.nextRunAt, !raw.isEmpty else { return job.statusLabel }
        guard let date = CronScheduleText.parseDate(raw) else {
            return AppLocalization.string("Next run \(raw)")
        }
        return AppLocalization.string("Next run \(CronScheduleText.runTimeText(date))")
    }
}
