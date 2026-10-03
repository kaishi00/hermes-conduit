//
//  LiveVoiceCallJobs.swift
//  Conduit
//
//  The jobs a live call starts and what its voice model puts on screen, on
//  the call screen: the latest one above the captions, each one in the
//  transcript where it started, and its full content in a sheet over the
//  call. The voice model only reads a summary aloud; the content is already
//  on the phone, so nothing is written to the host mid-call.
//

import SwiftUI

/// One job's card: what it is, how it is going, and a tap to read it.
struct LiveVoiceJobCard: View {
    let job: VoiceBackgroundJob
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                statusIcon
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: job.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: Self.statusText(for: job))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .conduitGlassControl(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(job.title), \(Self.statusText(for: job))"))
        .accessibilityHint(Text("Shows the full result"))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .starting, .running:
            ProgressView()
                .controlSize(.small)
        case .needsInput:
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(.orange)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.conduitAccent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    static func statusText(for job: VoiceBackgroundJob) -> String {
        switch job.status {
        case .starting, .running: return AppLocalization.string("Working…")
        case .needsInput: return AppLocalization.string("Waiting for you")
        case .finished:
            return hasResult(job) ? AppLocalization.string("Ready") : AppLocalization.string("Done")
        case .failed: return AppLocalization.string("Failed")
        case .cancelled: return AppLocalization.string("Cancelled")
        }
    }

    static func hasResult(_ job: VoiceBackgroundJob) -> Bool {
        !(job.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The newest job or screen card of the call, above the captions, with how
/// many more there are. Observes the jobs itself so their progress doesn't
/// redraw the whole call.
struct LiveVoiceCallJobStrip: View {
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    let onSelectJob: (UUID) -> Void
    let onSelectScreen: (VoiceScreenCard) -> Void

    var body: some View {
        let callJobs = jobs.callJobs(jobs.liveCallID)
        let cards = jobs.callScreenCards(jobs.liveCallID)
        let count = callJobs.count + cards.count
        if count > 0 {
            VStack(spacing: 6) {
                if let card = cards.last, card.shownAt >= (callJobs.last?.startedAt ?? .distantPast) {
                    LiveVoiceScreenCardRow(card: card) { onSelectScreen(card) }
                } else if let latest = callJobs.last {
                    LiveVoiceJobCard(job: latest) { onSelectJob(latest.id) }
                }
                if count > 1 {
                    Text("\(count - 1) more in the transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A card the voice model put on screen, as a row to open it again.
struct LiveVoiceScreenCardRow: View {
    let card: VoiceScreenCard
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(Color.conduitAccent)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.title(for: card))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("On screen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .conduitGlassControl(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.title(for: card)))
        .accessibilityHint(Text("Shows it again"))
        .accessibilityAddTraits(.isButton)
    }

    static func title(for card: VoiceScreenCard) -> String {
        card.title.isEmpty ? AppLocalization.string("On screen") : card.title
    }
}

/// One row of a live call's transcript panel.
enum LiveVoiceCallItem: Identifiable, Equatable {
    case line(VoiceConversationTranscriptEntry)
    case job(VoiceBackgroundJob)
    case screen(VoiceScreenCard)

    var id: UUID {
        switch self {
        case .line(let entry): return entry.id
        case .job(let job): return job.id
        case .screen(let card): return card.id
        }
    }
}

/// The call's transcript with each job and screen card placed where it
/// started.
struct LiveVoiceCallTimeline<Line: View>: View {
    let transcript: [VoiceConversationTranscriptEntry]
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    let line: (VoiceConversationTranscriptEntry) -> Line
    let onSelectJob: (UUID) -> Void
    let onSelectScreen: (VoiceScreenCard) -> Void

    typealias Item = LiveVoiceCallItem

    var body: some View {
        let items = Self.items(
            transcript: transcript,
            jobs: jobs.callJobs(jobs.liveCallID),
            screens: jobs.callScreenCards(jobs.liveCallID)
        )
        ForEach(items) { item in
            switch item {
            case .line(let entry):
                line(entry)
            case .job(let job):
                LiveVoiceJobCard(job: job) { onSelectJob(job.id) }
                    .frame(maxWidth: 320, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .screen(let card):
                LiveVoiceScreenCardRow(card: card) { onSelectScreen(card) }
                    .frame(maxWidth: 320, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Lines in order, each job or card after the line it started after
    /// (by id, else by count), earlier ones first; one anchored past the
    /// end goes last.
    static func items(
        transcript: [VoiceConversationTranscriptEntry],
        jobs: [VoiceBackgroundJob],
        screens: [VoiceScreenCard] = []
    ) -> [Item] {
        var positions: [UUID: Int] = [:]
        for (index, entry) in transcript.enumerated() where positions[entry.id] == nil {
            positions[entry.id] = index
        }
        func position(of anchor: VoiceJobCallAnchor?) -> Int {
            if let after = anchor?.afterEntryID, let index = positions[after] {
                return index + 1
            }
            return anchor?.transcriptIndex ?? 0
        }
        var placed: [LiveVoiceTimelinePlacement] = []
        for job in jobs {
            placed.append(LiveVoiceTimelinePlacement(
                order: placed.count, item: .job(job), position: position(of: job.callAnchor), time: job.startedAt
            ))
        }
        for card in screens {
            placed.append(LiveVoiceTimelinePlacement(
                order: placed.count, item: .screen(card), position: position(of: card.callAnchor), time: card.shownAt
            ))
        }
        placed.sort(by: LiveVoiceTimelinePlacement.precedes)
        var items: [Item] = []
        var next = 0
        for (index, entry) in transcript.enumerated() {
            while next < placed.count, placed[next].position <= index {
                items.append(placed[next].item)
                next += 1
            }
            items.append(.line(entry))
        }
        for remaining in placed[next...] {
            items.append(remaining.item)
        }
        return items
    }
}

/// A job or card and the transcript position it goes before.
private struct LiveVoiceTimelinePlacement {
    let order: Int
    let item: LiveVoiceCallItem
    let position: Int
    let time: Date

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        return lhs.order < rhs.order
    }
}

/// What the voice model put on screen, over the call.
struct LiveVoiceScreenCardSheet: View {
    let card: VoiceScreenCard

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                // Hermes' own images (MEDIA: paths) load through the gateway.
                let profile = appState.activeProfile
                MarkdownText(source: card.markdown, gatewayMediaDataURL: { path in
                    await appState.gatewayMediaDataURL(for: path, profile: profile)
                })
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(LiveVoiceScreenCardRow.title(for: card))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A job's full result over the call. Follows the job, so it fills in when
/// the job finishes while open.
struct LiveVoiceJobResultSheet: View {
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    let jobID: UUID
    let onOpenChat: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// The job as last seen, so a job the ledger prunes while open (it only
    /// keeps the latest settled ones) stays readable.
    @State private var lastSeen: VoiceBackgroundJob?

    private var job: VoiceBackgroundJob? { jobs.jobs.first { $0.id == jobID } ?? lastSeen }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let job {
                        content(for: job)
                    } else {
                        Text("The full result is in its chat.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(job?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { lastSeen = job }
            .onChange(of: jobs.jobs.first { $0.id == jobID }) { _, current in
                if let current { lastSeen = current }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                // A job on another profile opens from that profile; the
                // link only reaches chats on the one in use.
                if let job, job.profile == nil || job.profile == appState.activeProfile,
                   let id = Self.chatID(job) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Open chat") { onOpenChat(id) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(for job: VoiceBackgroundJob) -> some View {
        Label {
            Text(verbatim: LiveVoiceJobCard.statusText(for: job))
        } icon: {
            if job.status.isActive { ProgressView().controlSize(.small) }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        if let result = job.result, LiveVoiceJobCard.hasResult(job) {
            // Hermes' own images (MEDIA: paths) load through the gateway,
            // from the profile the job ran in.
            let profile = job.profile ?? appState.activeProfile
            MarkdownText(source: result, gatewayMediaDataURL: { path in
                await appState.gatewayMediaDataURL(for: path, profile: profile)
            })
        } else if job.status.isActive {
            Text("Hermes is still working on this. The result will show here.")
                .foregroundStyle(.secondary)
        } else if case .failed(let reason) = job.status {
            Text(verbatim: reason)
                .foregroundStyle(.secondary)
        } else if job.status == .cancelled {
            Text("This job was cancelled.")
                .foregroundStyle(.secondary)
        } else {
            Text("The full result is in its chat.")
                .foregroundStyle(.secondary)
        }
    }

    static func chatID(_ job: VoiceBackgroundJob) -> String? {
        [job.storedSessionID, job.runtimeSessionID].compactMap { $0 }.first { !$0.isEmpty }
    }
}
