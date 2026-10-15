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

                Group {
                    switch segment.wrappedValue {
                    case .board:
                        KanbanView(columnsLayout: true)
                            .padding(.horizontal, 14)
                    case .scheduled:
                        V2ScheduledList()
                    }
                }
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

/// The scheduled jobs: active ones first, each with its schedule, next run
/// and an on/off switch (Pause / Resume). Tapping a job opens its detail
/// with Run now and its run history.
struct V2ScheduledList: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var selectedJob: CronJob?

    private var jobs: [CronJob] {
        CronJobFilter.visibleJobs(appState.cronJobs, filter: .all, query: "")
    }

    var body: some View {
        ScrollView {
            if jobs.isEmpty && !appState.cronJobsLoading {
                let empty = CronJobFilter.emptyState(filter: .all, hasJobs: false, isSearching: false)
                ContentUnavailableView(empty.title, systemImage: "clock", description: Text(empty.description))
                    .padding(.top, 60)
            } else if jobs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // One glass card holds the jobs, hairlines between them.
                    VStack(spacing: 0) {
                        ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                            row(job)
                            if index < jobs.count - 1 {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.1))
                                    .frame(height: 0.5)
                            }
                        }
                    }
                    .conduitGlassSurface(cornerRadius: 24)

                    Text("Each run lands in Chats as its own conversation. Ask Hermes to add or change a schedule.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .scrollContentBackground(.hidden)
        .task(id: appState.activeProfile) { await appState.refreshCronContent() }
        .refreshable { await appState.refreshCronContent() }
        .sheet(item: $selectedJob) {
            CronJobDetailSheet(job: $0)
                .environmentObject(appState)
        }
    }

    private func row(_ job: CronJob) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                Haptics.light()
                selectedJob = job
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
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
            .accessibilityHint(AppLocalization.string("Opens the job's details and run history"))

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
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .dynamicTypeSize(...DynamicTypeSize.listRowCap)
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
