//
//  VoiceConversationSheet.swift
//  Conduit
//

import SwiftUI

/// The sheet is deliberately presentation-only. AppState remains responsible
/// for submitting, interrupting, and rendering the associated Hermes turn.
struct VoiceConversationSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @ObservedObject var controller: VoiceConversationController
    @ObservedObject var backgroundJobs: VoiceBackgroundJobSupervisor
    let profile: String
    /// The chat the conversation talks in, for V2's call header.
    var chatTitle: String? = nil
    /// Handed to V2's job result sheet, which reads it from the
    /// environment. A plain reference: the sheet never redraws for it.
    var appState: AppState? = nil
    let onClose: () -> Void
    /// One-shot gate armed by a fresh `openVoiceConversation` and consumed
    /// exactly once. A restored suspended conversation deliberately does NOT
    /// auto-listen: the gate stays disarmed even if SwiftUI recreates this
    /// view's identity while the presentation binding survives.
    let shouldAutoListen: () -> Bool
    var startsListening: Bool = true

    @State private var didRequestStart = false
    /// V2 draws the conversation as a call screen, like the live modes.
    @AppStorage(V2ShellPreference.key) private var usesV2 = V2ShellPreference.defaultValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsTranscript = false
    /// When the sheet opened, for V2's call clock.
    @State private var openedAt = Date()
    /// The job whose result V2 shows over the conversation.
    @State private var selectedJob: SelectedJob?
    /// The job chat to open once the result sheet has gone.
    @State private var pendingJobChat: String?
    @Environment(\.openURL) private var openURL

    private struct SelectedJob: Identifiable {
        let id: UUID
    }

    var body: some View {
        Group {
            if usesV2 {
                v2Body
            } else {
                v1Body
            }
        }
        .task {
            guard startsListening, !didRequestStart else { return }
            didRequestStart = true
            guard shouldAutoListen() else { return }
            await controller.startListening()
        }
        .accessibilityElement(children: .contain)
    }

    private var v1Body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(spacing: 22) {
                        statusCard
                        conversationCard
                        backgroundJobsCard
                        controlsCard
                        Text("Your conversation also continues in chat. Close ends this voice session.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Voice conversation"), close: close)
            }
        }
    }

    private var statusCard: some View {
        ConduitSettingsSection(title: AppLocalization.string("\(profileDisplayName) voice"), symbol: stateSymbol, tint: stateTint) {
            HStack(spacing: 12) {
                Image(systemName: stateSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(stateTint)
                    .frame(width: 44, height: 44)
                    .background(stateTint.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Voice status: \(statusTitle). \(statusDetail)")
            HStack(spacing: 8) {
                Text("Mic input")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VoiceInputLevelMeter(level: inputMeterLevel, isActive: isInputMeterActive)
                    .frame(height: 20)
                    .accessibilityHint(Text(isInputMeterActive
                        ? AppLocalization.string("Shows audio reaching Conduit while the microphone is live.")
                        : AppLocalization.string("The microphone is not capturing right now.")))
                Spacer(minLength: 0)
            }
        }
    }

    private var conversationCard: some View {
        ConduitSettingsSection(title: AppLocalization.string("Conversation"), symbol: "text.bubble", tint: .conduitAura) {
            if controller.conversationTranscript.isEmpty, controller.liveTranscript.isEmpty {
                Text("Your spoken words and Hermes' replies will appear here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .accessibilityLabel("No voice conversation messages yet")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.conversationTranscript) { entry in
                        VoiceConversationTranscriptBubble(entry: entry)
                    }
                    // Words Hermes has heard so far, while the user is
                    // still talking (live speech-to-text).
                    if !controller.liveTranscript.isEmpty {
                        VoiceConversationTranscriptBubble(
                            entry: VoiceConversationTranscriptEntry(speaker: .user, text: controller.liveTranscript)
                        )
                        .opacity(0.6)
                        .accessibilityHint("Still listening")
                    }
                }
            }
        }
    }

    private var backgroundJobsCard: some View {
        ConduitSettingsSection(title: AppLocalization.string("Background jobs"), symbol: "square.stack.3d.up", tint: .conduitAccent) {
            if backgroundJobs.backgroundJobs.isEmpty {
                Text("Say “background job” and then a task to run it as its own chat while you keep talking.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(backgroundJobs.backgroundJobs.reversed()) { job in
                        HStack(spacing: 10) {
                            Image(systemName: Self.jobSymbol(job.status))
                                .foregroundStyle(Self.jobTint(job.status))
                                .frame(width: 22)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.title)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                Text(Self.jobStatusLabel(job.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("Each job is its own chat in your session list. Say “job status” or “cancel background jobs” at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func jobSymbol(_ status: VoiceBackgroundJob.Status) -> String {
        switch status {
        case .starting, .running: return "hourglass"
        case .needsInput: return "exclamationmark.bubble"
        case .finished: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .cancelled: return "minus.circle"
        }
    }

    private static func jobTint(_ status: VoiceBackgroundJob.Status) -> Color {
        switch status {
        case .starting, .running: return .conduitAccent
        case .needsInput: return .orange
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    private static func jobStatusLabel(_ status: VoiceBackgroundJob.Status) -> String {
        switch status {
        case .starting: return AppLocalization.string("Starting")
        case .running: return AppLocalization.string("Running")
        case .needsInput: return AppLocalization.string("Waiting for your input")
        case .finished: return AppLocalization.string("Finished")
        case .failed: return AppLocalization.string("Failed")
        case .cancelled: return AppLocalization.string("Cancelled")
        }
    }

    private var controlsCard: some View {
        ConduitSettingsSection(title: AppLocalization.string("Microphone and audio"), symbol: "slider.horizontal.3", tint: .conduitAccent) {
            AdaptiveStack(spacing: 10) {
                Button { microphoneTapped() } label: {
                    Label(microphoneLabel, systemImage: microphoneSymbol)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 48)
                }
                .conduitGlassControl(cornerRadius: 17, tint: .conduitAccent.opacity(0.16))
                .accessibilityHint(microphoneHint)
                .disabled(controller.state == .transcribing)

                Button { controller.setOutputMuted(!controller.isOutputMuted) } label: {
                    Label(controller.isOutputMuted ? AppLocalization.string("Unmute") : AppLocalization.string("Mute"), systemImage: controller.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6).frame(minHeight: 48)
                }
                .conduitGlassControl(cornerRadius: 17, tint: controller.isOutputMuted ? .orange.opacity(0.18) : .conduitAura.opacity(0.14))
                .accessibilityHint("Mutes assistant audio without changing chat messages")
            }
            Text("Pause only affects the microphone. Close ends the voice session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileDisplayName: String {
        profile == "default" ? AppLocalization.string("Default profile") : profile.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Automatic speaker-safe suspension while Hermes audibly speaks on an
    /// open-speaker route: the mic control becomes Interrupt instead of a
    /// pause, so this never reads as a user-selected mic pause. An explicit
    /// user pause keeps precedence — the sheet stays in the paused state,
    /// and its Listen tap routes through `resumeMicrophone`, which acts as
    /// an interrupt while playback is suspended.
    private var isInterruptAvailable: Bool {
        controller.isPlaybackCaptureSuspended && !controller.isMicrophonePaused
    }

    /// The input meter is live exactly when microphone capture is live:
    /// listening, and (on headset routes) the thinking/speaking/muted
    /// windows where barge-in monitoring is actually armed. A user-paused
    /// mic, transcribing, and #146 speaker-safe suspension all read as
    /// inactive/zero — there, the status text explains why (e.g. "Hermes is
    /// speaking / Tap Interrupt to speak."), so a zero meter never implies
    /// malfunction.
    private var isInputMeterActive: Bool {
        guard !controller.isMicrophonePaused, !controller.isPlaybackCaptureSuspended else { return false }
        switch controller.state {
        case .listening, .thinking, .speaking, .muted: return true
        case .idle, .transcribing, .failed: return false
        }
    }

    private var inputMeterLevel: Float {
        isInputMeterActive ? controller.microphoneLevel : 0
    }

    private var microphoneLabel: String {
        if controller.state == .transcribing { return AppLocalization.string("Transcribing") }
        if isInterruptAvailable { return AppLocalization.string("Interrupt") }
        return microphoneIsActive ? AppLocalization.string("Pause mic") : AppLocalization.string("Listen")
    }

    private var microphoneSymbol: String {
        if controller.state == .transcribing { return "waveform" }
        if isInterruptAvailable { return "stop.fill" }
        return microphoneIsActive ? "mic.slash.fill" : "mic.fill"
    }

    private var microphoneHint: String {
        if isInterruptAvailable { return AppLocalization.string("Stops Hermes' speech and starts listening right away") }
        return microphoneIsActive ? AppLocalization.string("Pauses microphone capture while keeping the voice session open") : AppLocalization.string("Starts or resumes microphone capture")
    }

    private var microphoneIsActive: Bool {
        guard !controller.isMicrophonePaused else { return false }
        switch controller.state {
        case .listening, .thinking, .speaking, .muted: return true
        case .idle, .transcribing, .failed: return false
        }
    }

    private var statusTitle: String {
        if isInterruptAvailable { return AppLocalization.string("Hermes is speaking") }
        if controller.isMicrophonePaused { return AppLocalization.string("Microphone paused") }
        if controller.isSteeringTurn, controller.state == .listening || controller.state == .transcribing {
            return AppLocalization.string("Steering Hermes")
        }
        switch controller.state {
        case .idle: return AppLocalization.string("Ready to listen")
        case .listening: return AppLocalization.string("Listening")
        case .transcribing: return AppLocalization.string("Transcribing")
        case .thinking: return AppLocalization.string("Hermes is thinking")
        case .speaking: return AppLocalization.string("Hermes is speaking")
        case .muted: return AppLocalization.string("Assistant audio muted")
        case .failed: return AppLocalization.string("Voice needs attention")
        }
    }

    private var statusDetail: String {
        if isInterruptAvailable { return AppLocalization.string("Tap Interrupt to speak.") }
        if controller.isMicrophonePaused { return AppLocalization.string("Tap Listen when you are ready to resume.") }
        if controller.isSteeringTurn, controller.state == .listening || controller.state == .transcribing {
            return AppLocalization.string("Hermes keeps working with your words added.")
        }
        switch controller.state {
        case .idle: return AppLocalization.string("Tap Listen when you are ready.")
        case .listening: return AppLocalization.string("Pause the microphone whenever you need a break.")
        case .transcribing: return AppLocalization.string("Sending your speech to Hermes.")
        case .thinking: return AppLocalization.string("Speak to steer Hermes while it works.")
        case .speaking: return AppLocalization.string("Speak over Hermes to start a new turn.")
        case .muted: return AppLocalization.string("Assistant text is still continuing in chat.")
        case .failed(let detail): return detail
        }
    }

    private var stateSymbol: String {
        if controller.isMicrophonePaused { return "mic.slash" }
        switch controller.state {
        case .idle: return "mic"
        case .listening: return "waveform"
        case .transcribing: return "text.badge.checkmark"
        case .thinking: return "ellipsis.message"
        case .speaking: return "speaker.wave.3"
        case .muted: return "speaker.slash"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var stateTint: Color {
        if controller.isMicrophonePaused { return .orange }
        switch controller.state {
        case .failed: return .red
        case .muted: return .orange
        case .listening, .speaking: return .conduitAccent
        default: return .conduitAura
        }
    }

    private func microphoneTapped() {
        if isInterruptAvailable {
            Task { await controller.interruptAssistantPlayback() }
        } else if microphoneIsActive {
            controller.pauseMicrophone()
        } else {
            Task { await controller.resumeMicrophone() }
        }
    }

    private func close() {
        onClose()
    }
}

// MARK: - V2

/// V2 draws classic voice as the live modes' call screen: the last two
/// lines large at the top, thirty level bars that rise with the microphone,
/// the state under them, and the round controls with End in red. Closing
/// still ends the conversation: classic voice doesn't minimise.
extension VoiceConversationSheet {
    fileprivate var v2Body: some View {
        ZStack {
            ConduitBackdrop()
            VStack(spacing: 0) {
                v2Header
                if showsTranscript {
                    v2TranscriptList
                } else if dynamicTypeSize >= .xxLarge {
                    // Large text can outgrow a small screen.
                    ScrollView { v2Stage }
                        .scrollBounceBehavior(.basedOnSize)
                } else {
                    v2Stage
                }
                v2Controls
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsTranscript)
        // VoiceOver hears the conversation change state, not every word.
        .onChange(of: callPhase) { _, _ in
            AccessibilityNotification.Announcement(statusTitle).post()
        }
        .sheet(item: $selectedJob, onDismiss: {
            // Leaving for the job's chat ends the voice conversation, as
            // closing it does.
            guard let chatID = pendingJobChat else { return }
            pendingJobChat = nil
            close()
            openURL(ConduitAppLink.session(id: chatID).url)
        }) { selected in
            if let appState {
                LiveVoiceJobResultSheet(jobs: backgroundJobs, jobID: selected.id) { chatID in
                    pendingJobChat = chatID
                    selectedJob = nil
                }
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
            }
        }
    }

    /// The conversation as the call screen's bars draw it.
    fileprivate var callPhase: LiveVoiceCallPhase {
        if controller.isMicrophonePaused { return .muted }
        switch controller.state {
        case .idle: return .idle
        case .listening: return .listening
        // Working: a slow blue, like a call connecting.
        case .transcribing, .thinking: return .connecting
        case .speaking: return .speaking
        case .muted: return .muted
        case .failed: return .failed
        }
    }

    private var v2Title: String {
        let title = chatTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? AppLocalization.string("Voice conversation") : title
    }

    private func v2Subtitle(at now: Date) -> String {
        [profileDisplayName, AppLocalization.string("Classic voice"), V2CallHeaderTitle.clock(max(0, now.timeIntervalSince(openedAt)))]
            .joined(separator: " · ")
    }

    private var v2Header: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .conduitGlassControl(cornerRadius: 22)
            .accessibilityLabel(Text("Close"))
            // Unlike a live call's chevron, this ends the conversation.
            .accessibilityHint(Text("Your conversation also continues in chat. Close ends this voice session."))

            VStack(spacing: 2) {
                Text(verbatim: v2Title)
                    .font(.headline)
                    .lineLimit(1)
                    // VoiceOver hears the profile and mode, not the clock.
                    .accessibilityValue(Text(verbatim: "\(profileDisplayName), \(AppLocalization.string("Classic voice"))"))
                TimelineView(.animation(minimumInterval: 1)) { context in
                    Text(verbatim: v2Subtitle(at: context.date))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            // Balances the close button so the title stays centred.
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// The last two lines said, as the live calls caption them.
    private var v2CaptionLines: [VoiceConversationTranscriptEntry] {
        LiveVoiceCallSheet.captionLines(from: controller.conversationTranscript)
    }

    private func v2Label(for entry: VoiceConversationTranscriptEntry) -> String {
        entry.speaker == .user
            ? AppLocalization.string("You: \(entry.text)")
            : "\(AppLocalization.string("Hermes")): \(entry.text)"
    }

    private var v2Stage: some View {
        VStack(spacing: 0) {
            V2CallCaptions(
                lines: v2CaptionLines,
                pending: controller.liveTranscript.isEmpty ? nil : controller.liveTranscript,
                label: v2Label(for:)
            )
            .padding(.horizontal, 24)
            .padding(.top, 20)
            Spacer(minLength: 16)
            V2CallLevelBars(
                phase: callPhase,
                inputFraction: isInputMeterActive ? VoiceLevelMeterMath.displayFraction(forLevel: controller.microphoneLevel) : nil
            )
            .frame(height: 96)
            .padding(.horizontal, 28)
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(statusTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(statusDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 16)
            v2JobStrip
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .transition(.opacity)
    }

    /// The newest background job, with how many more there are.
    @ViewBuilder
    private var v2JobStrip: some View {
        let jobs = backgroundJobs.backgroundJobs
        if let latest = jobs.last {
            VStack(spacing: 6) {
                LiveVoiceJobCard(job: latest) { selectJob(latest.id) }
                if jobs.count > 1 {
                    Text("\(jobs.count - 1) more in the transcript")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func selectJob(_ id: UUID) {
        // Without the app state the result sheet can't open; the
        // transcript lists every job instead.
        if appState == nil {
            showsTranscript = true
        } else {
            selectedJob = SelectedJob(id: id)
        }
    }

    private var v2TranscriptList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if controller.conversationTranscript.isEmpty, controller.liveTranscript.isEmpty {
                    Text("What you and the assistant say will appear here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
                ForEach(controller.conversationTranscript) { entry in
                    VoiceConversationTranscriptBubble(entry: entry)
                }
                if !controller.liveTranscript.isEmpty {
                    VoiceConversationTranscriptBubble(
                        entry: VoiceConversationTranscriptEntry(speaker: .user, text: controller.liveTranscript)
                    )
                    .opacity(0.6)
                    .accessibilityHint("Still listening")
                }
                ForEach(backgroundJobs.backgroundJobs) { job in
                    LiveVoiceJobCard(job: job) { selectJob(job.id) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .transition(.opacity)
    }

    private var v2Controls: some View {
        HStack(alignment: .top, spacing: 0) {
            LiveVoiceCallButton(
                symbol: microphoneSymbol,
                title: microphoneLabel,
                style: controller.isMicrophonePaused ? .selected : .normal,
                voiceOverHint: microphoneHint,
                action: microphoneTapped
            )
            .disabled(controller.state == .transcribing)
            LiveVoiceCallButton(
                symbol: controller.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                title: controller.isOutputMuted ? AppLocalization.string("Sound on") : AppLocalization.string("Silence"),
                style: controller.isOutputMuted ? .selected : .normal,
                voiceOverLabel: controller.isOutputMuted
                    ? AppLocalization.string("Turn the assistant's sound back on")
                    : AppLocalization.string("Silence the assistant"),
                action: { controller.setOutputMuted(!controller.isOutputMuted) }
            )
            LiveVoiceCallButton(
                symbol: "text.bubble.fill",
                title: AppLocalization.string("Transcript"),
                style: showsTranscript ? .selected : .normal,
                action: { showsTranscript.toggle() }
            )
            .accessibilityAddTraits(showsTranscript ? .isSelected : [])
            LiveVoiceCallButton(
                symbol: "phone.down.fill",
                title: AppLocalization.string("End"),
                style: .destructive,
                voiceOverLabel: AppLocalization.string("End call"),
                voiceOverHint: AppLocalization.string("Hangs up the call"),
                action: close
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

private struct VoiceConversationTranscriptBubble: View {
    let entry: VoiceConversationTranscriptEntry

    private var isUser: Bool { entry.speaker == .user }
    /// Hermes' `@session:<id>` chat links read as the chat's name; the reply
    /// in the chat links them.
    private var shownText: String { isUser ? entry.text : HermesSessionReference.plain(entry.text) }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(isUser ? AppLocalization.string("You") : AppLocalization.string("Hermes"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(shownText)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .multilineTextAlignment(isUser ? .trailing : .leading)
        }
        .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
        .padding(12)
        .background((isUser ? Color.conduitAccent : Color.conduitAura).opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isUser ? AppLocalization.string("You") : AppLocalization.string("Hermes")): \(shownText)")
    }
}
