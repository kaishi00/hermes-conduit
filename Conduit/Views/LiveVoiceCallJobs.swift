//
//  LiveVoiceCallJobs.swift
//  Conduit
//
//  The jobs a live call starts, on the call screen: the latest one above
//  the captions, each one in the transcript where it started, and its full
//  result in a sheet over the call. The voice model only reads a summary
//  aloud; the result is already on the phone, so nothing is written to the
//  host mid-call.
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

/// The latest job of the call, above the captions, with how many more
/// there are. Observes the jobs itself so their progress doesn't redraw
/// the whole call.
struct LiveVoiceCallJobStrip: View {
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    let onSelect: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let callJobs = jobs.callJobs(jobs.liveCallID)
        if let latest = callJobs.last {
            VStack(spacing: 6) {
                LiveVoiceJobCard(job: latest) { onSelect(latest.id) }
                if callJobs.count > 1 {
                    Text("\(callJobs.count - 1) more in the transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: latest)
        }
    }
}

/// The call's transcript with each job placed where it started.
struct LiveVoiceCallTimeline<Line: View>: View {
    let transcript: [VoiceConversationTranscriptEntry]
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    let line: (VoiceConversationTranscriptEntry) -> Line
    let onSelectJob: (UUID) -> Void

    enum Item: Identifiable, Equatable {
        case line(VoiceConversationTranscriptEntry)
        case job(VoiceBackgroundJob)

        var id: UUID {
            switch self {
            case .line(let entry): return entry.id
            case .job(let job): return job.id
            }
        }
    }

    var body: some View {
        ForEach(Self.items(transcript: transcript, jobs: jobs.callJobs(jobs.liveCallID))) { item in
            switch item {
            case .line(let entry):
                line(entry)
            case .job(let job):
                LiveVoiceJobCard(job: job) { onSelectJob(job.id) }
                    .frame(maxWidth: 320, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Lines in order, each job after the line it started after (by id,
    /// else by count); a job anchored past the end goes last.
    static func items(transcript: [VoiceConversationTranscriptEntry], jobs: [VoiceBackgroundJob]) -> [Item] {
        var positions: [UUID: Int] = [:]
        for (index, entry) in transcript.enumerated() where positions[entry.id] == nil {
            positions[entry.id] = index
        }
        struct Placed {
            let order: Int
            let job: VoiceBackgroundJob
            let position: Int
        }
        var placed: [Placed] = []
        for (order, job) in jobs.enumerated() {
            var position = job.callAnchor?.transcriptIndex ?? 0
            if let after = job.callAnchor?.afterEntryID, let index = positions[after] {
                position = index + 1
            }
            placed.append(Placed(order: order, job: job, position: position))
        }
        placed.sort { lhs, rhs in
            lhs.position == rhs.position ? lhs.order < rhs.order : lhs.position < rhs.position
        }
        var items: [Item] = []
        var next = 0
        for (index, entry) in transcript.enumerated() {
            while next < placed.count, placed[next].position <= index {
                items.append(.job(placed[next].job))
                next += 1
            }
            items.append(.line(entry))
        }
        for remaining in placed[next...] {
            items.append(.job(remaining.job))
        }
        return items
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
                if let id = job.flatMap(Self.chatID) {
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
