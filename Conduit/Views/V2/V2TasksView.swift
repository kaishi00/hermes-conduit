//
//  V2TasksView.swift
//  Conduit
//
//  Tasks: a glass segmented control over the Kanban board (its lanes as
//  side-by-side columns) and the scheduled jobs (schedule, next run, and an
//  on/off switch). Each scheduled run lands in Chats as its own
//  conversation.
//

import SwiftUI

struct V2TasksView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.v2Shell) private var shell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("conduit.v2.tasksSegment") private var segmentRaw = Segment.board.rawValue

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

    /// Under Reduce Motion the pages only crossfade.
    private func pageTransition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    var body: some View {
        ZStack {
            V2Backdrop()
            VStack(spacing: 10) {
                V2SegmentedControl(
                    selection: segment,
                    options: [
                        (value: Segment.board, title: AppLocalization.string("Board")),
                        (value: Segment.scheduled, title: AppLocalization.string("Scheduled"))
                    ]
                )
                .padding(.horizontal, 16)

                ZStack {
                    // Board sits left of Scheduled, as in the control: each
                    // slides in from its own side.
                    switch segment.wrappedValue {
                    case .board:
                        KanbanView(columnsLayout: true)
                            .padding(.horizontal, 14)
                            .transition(pageTransition(from: .leading))
                    case .scheduled:
                        V2ScheduledList()
                            .transition(pageTransition(from: .trailing))
                    }
                }
                .clipped()
                .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: segmentRaw)
                .opacity(shell.contentFaded ? 0 : 1)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            V2TopBar()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MinimisedLiveVoiceBar()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationTitle(V2Tab.tasks.title)
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
    @State private var selectedJob: CronJob?
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
                    ContentUnavailableView(empty.title, systemImage: "clock", description: Text(empty.description))
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
        .task(id: appState.activeProfile) { await appState.refreshCronContent() }
        .refreshable { await appState.refreshCronContent() }
        .sheet(item: $selectedJob) {
            CronJobDetailSheet(job: $0)
                .environmentObject(appState)
        }
    }

    private var listFooter: some View {
        Text(AppLocalization.string("Each run lands in Chats as its own conversation. Ask Hermes to add or change a schedule."))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
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
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.conduitAccent)
                                .accessibilityLabel(AppLocalization.string("Pinned"))
                        }
                        Text(job.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(job.scheduleDisplay ?? job.schedule?.display ?? job.schedule?.expr ?? AppLocalization.string("No schedule"))
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.58))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.caption.weight(.semibold))
                            .conduitFixedGlyph()
                            .accessibilityHidden(true)
                        Text(nextRunLine(job))
                            .lineLimit(1)
                    }
                    .font(.footnote)
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

    /// "Next run in 3 hours", the job's state when it won't run again.
    private func nextRunLine(_ job: CronJob) -> String {
        guard job.isActive else { return job.statusLabel }
        guard let raw = job.nextRunAt, !raw.isEmpty else { return job.statusLabel }
        guard let date = Self.parseDate(raw) else {
            return AppLocalization.string("Next run \(raw)")
        }
        let formatter = Self.relativeFormatter
        formatter.locale = AppLocalization.formattingLocale
        return AppLocalization.string("Next run \(formatter.localizedString(for: date, relativeTo: Date()))")
    }

    // Shared per list; rows read them on the main actor only.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISOFormatter = ISO8601DateFormatter()

    private static func parseDate(_ raw: String) -> Date? {
        if let date = fractionalISOFormatter.date(from: raw) { return date }
        if let date = plainISOFormatter.date(from: raw) { return date }
        if let seconds = Double(raw) { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        return nil
    }
}
