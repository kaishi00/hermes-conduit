//
//  LiveVoiceCallSheet.swift
//  Conduit
//
//  The expanded sheet every live voice engine shares: a call screen with an
//  orb that moves with the call's phase, the last lines as captions, and a
//  row of round controls with hang-up next to mute, in the minimised bar's
//  order. The chevron (or a swipe down) minimises; End hangs up.
//

import SwiftUI

/// What the call is doing, as the sheet draws it.
enum LiveVoiceCallPhase: Equatable {
    case idle
    case connecting
    case listening
    case speaking
    case muted
    case ending
    case failed
}

struct LiveVoiceCallSheet: View {
    let title: String
    /// Who pays for the call, under the title for as long as it runs (a
    /// GPT-Live call's ChatGPT plan or API key). Nil shows nothing.
    var billingBadge: GPTLiveBilling? = nil
    let phase: LiveVoiceCallPhase
    /// Up before its call opens, for a widget's Talk or Siri waiting on
    /// Hermes. There is no call yet to minimise: Close hangs up, as End
    /// does, and the screen doesn't swipe away.
    var waitsToStart = false
    let statusText: String
    var note: String?
    let transcript: [VoiceConversationTranscriptEntry]
    /// The VoiceOver label for one of the assistant's lines.
    let assistantLabel: (String) -> String
    /// Observed only by the small views that show the attached chat, so job
    /// progress doesn't redraw the whole call.
    let jobs: VoiceBackgroundJobSupervisor
    /// Handed to the job and screen-card sheets, which read it from the
    /// environment. A plain reference, not an observed one: the call never
    /// redraws for app-wide state changes.
    let appState: AppState
    let isMicrophoneMuted: Bool
    /// The assistant's voice is silenced (#487); the call carries on.
    let isSpeakerMuted: Bool
    let canMute: Bool
    let canInterrupt: Bool
    let onToggleMute: () -> Void
    let onToggleSpeaker: () -> Void
    /// Nil for an engine that is only interrupted by speaking over it: the
    /// sheet then has no Interrupt button.
    var onInterrupt: (() -> Void)?
    let onEnd: () -> Void
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var showsTranscript = false
    /// V2 draws the call as level bars and large captions instead of the orb.
    @AppStorage(V2ShellPreference.key) private var usesV2 = V2ShellPreference.defaultValue
    @State private var selection: Selection?
    /// The job chat to open once the result sheet has gone, so the call
    /// sheet isn't dismissed while its child is still animating out.
    @State private var pendingJobChat: String?
    /// The cards that opened by themselves, so each opens only once.
    @State private var autoOpenedCardIDs: Set<UUID> = []
    /// Whether what's open opened by itself, so a newer card may replace it.
    @State private var selectionIsAutomatic = false

    /// What the sheet over the call shows.
    private enum Selection: Identifiable {
        case job(UUID)
        case screen(VoiceScreenCard)

        /// A live card keeps its sheet open as it's brought up to date.
        var id: String {
            switch self {
            case .job(let id): return "job-\(id)"
            case .screen(let card):
                return card.liveNames.min().map { "live-\($0)" } ?? "screen-\(card.id)"
            }
        }
    }

    /// How recent a card must be to open by itself, so reopening a
    /// minimised call doesn't bring back an old one.
    private static let screenCardFreshness: TimeInterval = 5

    var body: some View {
        ZStack {
            ConduitBackdrop()
            VStack(spacing: 0) {
                header
                if showsTranscript {
                    transcriptList
                } else if usesV2 {
                    if dynamicTypeSize >= .xxLarge {
                        // Large text can outgrow a small screen.
                        ScrollView { v2Stage }
                            .scrollBounceBehavior(.basedOnSize)
                    } else {
                        v2Stage
                    }
                } else if dynamicTypeSize >= .xxLarge {
                    // Large text can outgrow a small screen.
                    ScrollView { stage }
                        .scrollBounceBehavior(.basedOnSize)
                } else {
                    stage
                }
                controls
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsTranscript)
        .interactiveDismissDisabled(waitsToStart)
        .sheet(item: $selection, onDismiss: {
            // Leaving for the job's chat minimises the call.
            guard let chatID = pendingJobChat else { return }
            pendingJobChat = nil
            dismiss()
            openURL(ConduitAppLink.session(id: chatID).url)
        }) { selected in
            Group {
                switch selected {
                case .job(let jobID):
                    LiveVoiceJobResultSheet(jobs: jobs, jobID: jobID) { chatID in
                        pendingJobChat = chatID
                        selection = nil
                    }
                case .screen(let card):
                    LiveVoiceScreenCardSheet(card: card)
                }
            }
            .environmentObject(appState)
            .presentationDetents([.medium, .large])
        }
        .onReceive(jobs.$screenCards) { cards in
            showNewScreenCard(cards)
        }
        // VoiceOver hears the call change state (listening, speaking,
        // muted), not every status word in between.
        .onChange(of: phase) { _, _ in
            AccessibilityNotification.Announcement(statusText).post()
        }
    }

    /// Nothing is open, or only a card that opened by itself: what the
    /// user opened stays until they close it.
    private var canReplaceSelection: Bool {
        selection == nil || selectionIsAutomatic
    }

    private func selectJob(_ jobID: UUID) {
        selectionIsAutomatic = false
        selection = .job(jobID)
    }

    private func selectScreen(_ card: VoiceScreenCard) {
        selectionIsAutomatic = false
        selection = .screen(card)
    }

    /// Opens what the voice model just put on screen; the model tells the
    /// user it's there. Something the user opened, or a chat being opened,
    /// isn't replaced: the card waits in the strip and the transcript.
    private func showNewScreenCard(_ cards: [VoiceScreenCard]) {
        // An open live card follows its updates, whoever opened it.
        if case .screen(let open) = selection, let card = cards.last, card.id != open.id,
           card.callAnchor.callID == jobs.liveCallID, open.isUpdated(by: card) {
            autoOpenedCardIDs.insert(card.id)
            selection = .screen(card)
            return
        }
        guard let card = cards.last,
              pendingJobChat == nil,
              canReplaceSelection,
              card.callAnchor.callID == jobs.liveCallID,
              !autoOpenedCardIDs.contains(card.id),
              Date().timeIntervalSince(card.shownAt) < Self.screenCardFreshness else { return }
        autoOpenedCardIDs.insert(card.id)
        selectionIsAutomatic = true
        selection = .screen(card)
    }

    /// Only a running call minimises; dismissing any other closes it.
    private var isMinimisable: Bool {
        guard !waitsToStart else { return false }
        switch phase {
        case .idle, .failed: return false
        case .connecting, .listening, .speaking, .muted, .ending: return true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                // The sheet's dismissal minimises a running call; a waiting
                // one hangs up.
                if waitsToStart { onEnd() } else { dismiss() }
            } label: {
                Image(systemName: isMinimisable ? "chevron.down" : "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .conduitGlassControl(cornerRadius: 22)
            // A call that isn't running closes instead of minimising.
            .accessibilityLabel(isMinimisable ? Text("Minimise call") : Text("Close"))

            VStack(spacing: 2) {
                if usesV2 {
                    V2CallHeaderTitle(
                        jobs: jobs,
                        engine: title,
                        profile: appState.profileDisplayName(appState.activeProfile),
                        onOpenChat: openAttachedChat
                    )
                } else {
                    Text(verbatim: title)
                        .font(.headline)
                        .lineLimit(1)
                }
                if let billingBadge {
                    LiveVoiceBillingBadge(billing: billingBadge)
                        // The chat link's tap area reaches under the badge.
                        .allowsHitTesting(false)
                }
                if !usesV2 {
                    LiveVoiceCallThreadLabel(jobs: jobs, onOpenChat: openAttachedChat)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if isMinimisable {
                LiveVoiceAskFirstButton(jobs: jobs)
            } else {
                // Balances the chevron so the title stays centred.
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// The chat name in the header opens the chat the call works in. The
    /// call goes on minimised, as it does when a job's chat opens.
    private func openAttachedChat(_ link: ConduitAppLink) {
        dismiss()
        openURL(link.url)
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            LiveVoiceOrb(phase: phase)
                // Shrinks to make room when large text needs the height.
                .frame(minWidth: 88, maxWidth: 184, minHeight: 88, maxHeight: 184)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(statusText)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            LiveVoiceQuickHint(jobs: jobs)
                .padding(.horizontal, 24)
            LiveVoiceCallJobStrip(jobs: jobs, onSelectJob: selectJob, onSelectScreen: selectScreen)
                .padding(.horizontal, 24)
            captions
        }
        .transition(.opacity)
    }

    /// V2: the last two lines large at the top, thirty level bars in the
    /// call's colour over a breathing glow, and the state under them.
    private var v2Stage: some View {
        VStack(spacing: 0) {
            v2Captions
                .padding(.horizontal, 24)
                .padding(.top, 20)
            Spacer(minLength: 16)
            V2CallLevelBars(phase: phase)
                .frame(height: 96)
                .padding(.horizontal, 28)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 16)
            LiveVoiceQuickHint(jobs: jobs)
                .padding(.horizontal, 24)
            LiveVoiceCallJobStrip(jobs: jobs, onSelectJob: selectJob, onSelectScreen: selectScreen)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
        .transition(.opacity)
    }

    private var v2Captions: some View {
        V2CallCaptions(lines: Self.captionLines(from: transcript), label: label(for:))
    }

    private var captions: some View {
        let lines = Self.captionLines(from: transcript)
        return VStack(spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, entry in
                let isLatest = index == lines.count - 1
                Text(entry.text)
                    .font(isLatest ? .body : .subheadline)
                    .foregroundStyle(isLatest ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(isLatest ? 4 : 2)
                    .truncationMode(.head)
                    .accessibilityLabel(label(for: entry))
            }
        }
        // Room for the first lines is kept from the start, so the orb
        // doesn't jump when speech arrives.
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .bottom)
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: lines.map(\.id))
    }

    /// The captions under the orb: the last two lines said.
    static func captionLines(from transcript: [VoiceConversationTranscriptEntry]) -> [VoiceConversationTranscriptEntry] {
        Array(transcript.suffix(2))
    }

    // MARK: Transcript

    private var transcriptList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                LiveVoiceOrb(phase: phase, animates: false)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .accessibilityElement(children: .combine)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if transcript.isEmpty {
                        Text("What you and the assistant say will appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    LiveVoiceCallTimeline(
                        transcript: transcript,
                        jobs: jobs,
                        line: { entry in LiveVoiceTranscriptBubble(entry: entry, label: label(for: entry)) },
                        onSelectJob: selectJob,
                        onSelectScreen: selectScreen
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
        }
        .transition(.opacity)
    }

    private func label(for entry: VoiceConversationTranscriptEntry) -> String {
        entry.speaker == .user
            ? AppLocalization.string("You: \(entry.text)")
            : assistantLabel(entry.text)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .top, spacing: 0) {
            if phase == .failed {
                LiveVoiceCallButton(symbol: "arrow.clockwise", title: AppLocalization.string("Try again"), action: onRetry)
            } else {
                LiveVoiceCallButton(
                    symbol: isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
                    title: isMicrophoneMuted ? AppLocalization.string("Unmute") : AppLocalization.string("Mute"),
                    style: isMicrophoneMuted ? .selected : .normal,
                    voiceOverLabel: isMicrophoneMuted ? AppLocalization.string("Unmute microphone") : AppLocalization.string("Mute microphone"),
                    action: onToggleMute
                )
                .disabled(!canMute)
                LiveVoiceCallButton(
                    symbol: isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: isSpeakerMuted ? AppLocalization.string("Sound on") : AppLocalization.string("Silence"),
                    style: isSpeakerMuted ? .selected : .normal,
                    voiceOverLabel: isSpeakerMuted
                        ? AppLocalization.string("Turn the assistant's sound back on")
                        : AppLocalization.string("Silence the assistant"),
                    action: onToggleSpeaker
                )
                .disabled(!canMute)
                // On an open speaker the mic is closed while the assistant
                // talks, so this is the way to cut in.
                if let onInterrupt {
                    LiveVoiceCallButton(
                        // Not a hand: that is asking first's (#451).
                        symbol: "stop.fill",
                        title: AppLocalization.string("Interrupt"),
                        voiceOverHint: canInterrupt
                            ? AppLocalization.string("Stops the assistant so you can speak")
                            : AppLocalization.string("Available while the assistant is speaking"),
                        action: onInterrupt
                    )
                    .disabled(!canInterrupt)
                }
            }
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
                action: onEnd
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}

/// Who pays for a GPT-Live call. The API key stands out in orange: it is
/// billed per minute, unlike the ChatGPT plan.
struct LiveVoiceBillingBadge: View {
    let billing: GPTLiveBilling

    var body: some View {
        let tint: Color = billing == .api ? .orange : .secondary
        Label {
            Text(verbatim: billing.badge)
        } icon: {
            Image(systemName: billing == .api ? "creditcard" : "person.crop.circle")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.15)))
        .lineLimit(1)
    }
}

/// "Working in <chat>" under the title while the call is attached to one.
/// Tapping it opens that chat.
private struct LiveVoiceCallThreadLabel: View {
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    let onOpenChat: (ConduitAppLink) -> Void

    var body: some View {
        if let thread = jobs.liveThread {
            CallChatTitleLink(link: thread.appLink, onOpenChat: onOpenChat) {
                Text(verbatim: thread.title)
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// The attached chat's name in a call's header, as a link to that chat
/// (#698): a small chevron says it opens. Plain text when there is no
/// chat to open.
private struct CallChatTitleLink<Title: View>: View {
    let link: ConduitAppLink?
    let onOpenChat: ((ConduitAppLink) -> Void)?
    @ViewBuilder let label: () -> Title

    var body: some View {
        if let link, let onOpenChat {
            Button {
                onOpenChat(link)
            } label: {
                HStack(spacing: 3) {
                    label().lineLimit(1)
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                // A 44 pt tap target without moving the header: the padding
                // widens the hit area and the negative padding takes the
                // space back.
                .padding(.vertical, 14)
                .contentShape(Rectangle())
                .padding(.vertical, -14)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
            // The header reads as one element; this keeps the link reachable.
            .accessibilityAction(named: Text(verbatim: AppLocalization.string("Open chat"))) { onOpenChat(link) }
        } else {
            label().lineLimit(1)
        }
    }
}

/// Asking first for this call (#451). It shows the call's own setting, so a
/// switch the user asked for by voice shows here too. A raised hand reads
/// as "hold it for my OK"; a short caption says what it means whenever it
/// switches, and the first time it shows.
private struct LiveVoiceAskFirstButton: View {
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    @AppStorage("conduit.liveVoiceAskFirstHintShown") private var hintShown = false
    @State private var caption: String?
    @State private var captionTask: Task<Void, Never>?

    var body: some View {
        let isOn = jobs.asksBeforeSending
        Button {
            jobs.setAsksBeforeSending(!isOn)
        } label: {
            Image(systemName: isOn ? "hand.raised.fill" : "hand.raised.slash")
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Color.conduitAccent : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .conduitGlassControl(cornerRadius: 22, tint: isOn ? .conduitAccent.opacity(0.14) : .clear)
        .accessibilityLabel(Text("Ask before sending to Hermes"))
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        // Below the button, over the stage: it never moves the header.
        .overlay(alignment: .topTrailing) {
            if let caption {
                Text(verbatim: caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    // Wraps rather than running off the leading edge, at
                    // large text sizes and in longer languages. Capped since
                    // it sits over the stage: larger, it would cover the orb
                    // (the button itself says the same to VoiceOver).
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .conduitGlassControl(cornerRadius: 16, interactive: false)
                    .frame(width: 280, alignment: .trailing)
                    .offset(y: 52)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: isOn) { _, on in
            // Switched it: they've seen what it means.
            hintShown = true
            showCaption(for: on)
        }
        .onAppear {
            guard !hintShown else { return }
            showCaption(for: isOn)
        }
        .onDisappear { captionTask?.cancel() }
    }

    private func showCaption(for on: Bool) {
        captionTask?.cancel()
        let text = on
            ? AppLocalization.string("Asking before sending to Hermes")
            : AppLocalization.string("Sending straight to Hermes")
        withAnimation(.easeOut(duration: 0.2)) { caption = text }
        // The caption itself is hidden from VoiceOver: said once instead.
        AccessibilityNotification.Announcement(text).post()
        captionTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            // The first-time hint counts once it was on screen in full.
            hintShown = true
            withAnimation(.easeIn(duration: 0.3)) { caption = nil }
        }
    }
}

/// One of the call screen's round controls, the icon over its name. Classic
/// voice's V2 screen uses the same row.
struct LiveVoiceCallButton: View {
    enum Style {
        case normal
        case selected
        case destructive
    }

    let symbol: String
    let title: String
    var style: Style = .normal
    var voiceOverLabel: String?
    var voiceOverHint: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .title3) private var scaledDiameter: CGFloat = 62
    /// Capped so five buttons still fit across a phone at the largest
    /// text sizes; the glyph inside keeps scaling.
    private var diameter: CGFloat { min(scaledDiameter, 66) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                icon
                Text(verbatim: title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    // A fifth of the width can't hold larger titles;
                    // touch and hold shows the name large.
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityShowsLargeContentViewer {
            Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(verbatim: voiceOverLabel ?? title))
        .accessibilityHint(Text(verbatim: voiceOverHint ?? ""))
    }

    @ViewBuilder
    private var icon: some View {
        let glyph = Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .frame(width: diameter, height: diameter)
        switch style {
        case .normal:
            glyph
                .foregroundStyle(.primary)
                .conduitGlassControl(cornerRadius: diameter / 2)
        case .selected:
            glyph
                .foregroundStyle(Color(.systemBackground))
                .background(Circle().fill(Color.primary))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        case .destructive:
            glyph
                .foregroundStyle(.white)
                .background(Circle().fill(Color.red))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        }
    }
}

struct LiveVoiceTranscriptBubble: View {
    let entry: VoiceConversationTranscriptEntry
    let label: String

    private var isUser: Bool { entry.speaker == .user }

    var body: some View {
        Text(entry.text)
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                (isUser ? Color.conduitAccent : Color.conduitAura).opacity(0.16),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .frame(maxWidth: 320, alignment: isUser ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
    }
}

/// The call's orb. Where Metal is available it is the liquid glass orb (see
/// LiquidOrbView): calm and grey-gold at rest, a slow cool blue while the
/// call listens, fast bright gold swelling as the assistant speaks; the small
/// accessory orb is a still frame of the same look. Otherwise, and for a
/// failed call, it is a soft sphere drawn from gradients that breathes and
/// pulses the same way. Phase decides colour and motion; there is no audio
/// level feed common to every engine.
struct LiveVoiceOrb: View {
    let phase: LiveVoiceCallPhase
    /// Off for a small accessory orb: it keeps its colour but stays still.
    var animates = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LiveVoiceOrbPower.preferenceKey) private var motionEnabled = true
    @ObservedObject private var power = DevicePowerState.shared

    /// Whether this orb moves: also off when the user turned the motion
    /// off or the phone runs hot (see LiveVoiceOrbPower).
    private var isMoving: Bool {
        LiveVoiceOrbPower.animates(
            requested: animates,
            enabled: motionEnabled,
            reduceMotion: reduceMotion,
            thermalState: power.thermalState
        )
    }

    struct Motion: Equatable {
        /// Scale swing either side of 1.
        var amplitude: Double
        /// Radians per second of the main swing.
        var speed: Double
        var opacity: Double
    }

    static func motion(for phase: LiveVoiceCallPhase) -> Motion {
        switch phase {
        case .connecting: return Motion(amplitude: 0.05, speed: 1.4, opacity: 0.65)
        case .listening: return Motion(amplitude: 0.035, speed: 1.9, opacity: 1)
        case .speaking: return Motion(amplitude: 0.06, speed: 4.6, opacity: 1)
        case .idle, .muted: return Motion(amplitude: 0, speed: 0, opacity: 0.8)
        case .ending: return Motion(amplitude: 0.02, speed: 1, opacity: 0.6)
        case .failed: return Motion(amplitude: 0, speed: 0, opacity: 0.9)
        }
    }

    struct LiquidLook: Equatable {
        var state: LiquidOrbState
        /// How strongly it swells as if speaking, 0...1.
        var speech: Float
    }

    static func liquidLook(for phase: LiveVoiceCallPhase) -> LiquidLook {
        switch phase {
        case .connecting, .listening: return LiquidLook(state: .listening, speech: 0)
        case .speaking: return LiquidLook(state: .speaking, speech: 1)
        case .idle, .muted, .ending, .failed: return LiquidLook(state: .idle, speech: 0)
        }
    }

    private var tint: Color {
        switch phase {
        case .connecting, .listening: return .conduitAura
        case .speaking: return .conduitAccent
        case .idle, .muted, .ending: return Color(.systemGray)
        case .failed: return .red
        }
    }

    var body: some View {
        // A failed call keeps the red gradient orb, the clearest failure signal.
        if phase != .failed, let pipeline = LiquidOrbPipeline.shared {
            liquidOrb(pipeline)
        } else {
            gradientOrb
        }
    }

    private func liquidOrb(_ pipeline: LiquidOrbPipeline) -> some View {
        let look = Self.liquidLook(for: phase)
        return GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            // The sphere fills 72% of its canvas and the glow the rest: draw
            // it larger than the frame so the sphere itself keeps the old
            // orb's size, without the glow taking layout space.
            LiquidOrbView(
                pipeline: pipeline,
                state: look.state,
                speech: look.speech,
                animates: isMoving,
                framesPerSecond: LiveVoiceOrbPower.framesPerSecond(speaking: look.state == .speaking, lowPowerMode: power.isLowPowerModeEnabled)
            )
                .frame(width: size * 1.3, height: size * 1.3)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .opacity(Self.motion(for: phase).opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: phase)
    }

    @ViewBuilder
    private var gradientOrb: some View {
        let motion = Self.motion(for: phase)
        let moves = isMoving && motion.amplitude > 0
        // 30 fps is plenty for a slow swell and spares ProMotion's 120 Hz.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moves)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Two sines a little out of step read as breathing, not a metronome.
            let swing = moves
                ? motion.amplitude * (0.7 * sin(t * motion.speed) + 0.3 * sin(t * motion.speed * 1.7 + 1))
                : 0
            GeometryReader { proxy in
                let size = min(proxy.size.width, proxy.size.height)
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.45))
                        .blur(radius: size * 0.18)
                        .scaleEffect(1.02 + swing * 2.2)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.85), tint, tint.opacity(0.75), Color.black.opacity(0.55)],
                                center: UnitPoint(x: 0.34, y: 0.28),
                                startRadius: 0,
                                endRadius: size * 0.78
                            )
                        )
                        .overlay {
                            // A slow sheen keeps a resting orb from looking flat.
                            Circle()
                                .fill(
                                    AngularGradient(
                                        colors: [.clear, Color.white.opacity(0.28), .clear, tint.opacity(0.4), .clear],
                                        center: .center,
                                        angle: .radians(moves ? t * 0.6 : 0)
                                    )
                                )
                                .blendMode(.plusLighter)
                                .blur(radius: size * 0.04)
                        }
                        .clipShape(Circle())
                        .scaleEffect(1 + swing)
                }
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .opacity(motion.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: phase)
    }
}

/// V2's call header: the chat the call works in (or "Voice call"), and
/// under it the profile, the engine and how long the call has run.
struct V2CallHeaderTitle: View {
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor
    let engine: String
    let profile: String
    /// Opens the attached chat when its name is tapped; nil leaves it text.
    var onOpenChat: ((ConduitAppLink) -> Void)? = nil

    var body: some View {
        VStack(spacing: 2) {
            CallChatTitleLink(link: jobs.liveThread?.appLink, onOpenChat: onOpenChat) {
                Text(verbatim: jobs.liveThread?.title ?? AppLocalization.string("Voice call"))
                    .font(.headline)
            }
            // The subtitle is hidden below; VoiceOver still hears the
            // profile and engine, just not the ticking clock.
            .accessibilityValue(Text(verbatim: [profile, engine].filter { !$0.isEmpty }.joined(separator: ", ")))
            // Ticks once a second while the call runs; nothing redraws
            // before it starts or after it ends.
            TimelineView(.animation(minimumInterval: 1, paused: jobs.liveCallStartedAt == nil)) { context in
                Text(verbatim: subtitle(at: context.date))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // The header reads as one element: a label changing every second
            // would keep VoiceOver from settling on it. The state is announced.
            .accessibilityHidden(true)
            // The chat link's tap area reaches under this line.
            .allowsHitTesting(false)
        }
    }

    private func subtitle(at now: Date) -> String {
        var parts = [profile, engine]
        if let started = jobs.liveCallStartedAt {
            parts.append(Self.clock(max(0, now.timeIntervalSince(started))))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 0:12, 4:05, 1:02:09.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// V2's call captions: the line before at 19 pt, faded; the line being
/// said at 28 pt. `pending` is speech still being recognised, drawn after
/// them at 38%.
struct V2CallCaptions: View {
    let lines: [VoiceConversationTranscriptEntry]
    var pending: String? = nil
    /// The VoiceOver label for a line.
    let label: (VoiceConversationTranscriptEntry) -> String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var currentLineSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var previousLineSize: CGFloat = 19

    var body: some View {
        // With words still arriving, the last said line is the previous one.
        let shown = pending == nil ? lines : Array(lines.suffix(1))
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                let isLatest = pending == nil && index == shown.count - 1
                Text(verbatim: entry.text)
                    .font(isLatest ? .system(size: currentLineSize, weight: .semibold) : .system(size: previousLineSize))
                    .foregroundStyle(Color.primary.opacity(isLatest ? 1 : 0.42))
                    .lineLimit(isLatest ? 5 : 2)
                    .truncationMode(.head)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(label(entry))
            }
            if let pending {
                Text(verbatim: pending)
                    .font(.system(size: currentLineSize, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.38))
                    .lineLimit(5)
                    .truncationMode(.head)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(verbatim: AppLocalization.string("You: \(pending)")))
                    .accessibilityHint(Text("Still listening"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .bottomLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: shown.map(\.id))
    }
}

/// V2's call level: thirty thin bars over a soft glow, coloured by state
/// (blue listening, gold speaking, grey muted, red failed). No engine feeds
/// a common audio level, so the bars move with the phase, like the orb did.
/// They hold still under Reduce Motion, with the orb's motion setting off,
/// and when the phone runs hot.
struct V2CallLevelBars: View {
    let phase: LiveVoiceCallPhase
    /// Five for the minimised bar's small version.
    var barCount = 30
    var glows = true
    /// The microphone's level, 0...1, where the engine has one (classic
    /// voice): while listening the bars rise with the user's voice.
    var inputFraction: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(LiveVoiceOrbPower.preferenceKey) private var motionEnabled = true
    @ObservedObject private var power = DevicePowerState.shared

    private var tint: Color {
        switch phase {
        case .connecting, .listening: return .conduitAura
        case .speaking: return .conduitAccent
        case .idle, .muted, .ending: return Color(.systemGray)
        case .failed: return .red
        }
    }

    private var moves: Bool {
        let motion = LiveVoiceOrb.motion(for: phase)
        return motion.amplitude > 0 && LiveVoiceOrbPower.animates(
            requested: true,
            enabled: motionEnabled,
            reduceMotion: reduceMotion,
            thermalState: power.thermalState
        )
    }

    var body: some View {
        let motion = LiveVoiceOrb.motion(for: phase)
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moves)) { context in
            let t = moves ? context.date.timeIntervalSinceReferenceDate : 0
            GeometryReader { proxy in
                let breath = moves ? 0.5 + 0.5 * sin(t * 1.3) : 0.5
                ZStack {
                    if glows {
                        Ellipse()
                            .fill(tint.opacity(0.18 + 0.14 * breath))
                            .blur(radius: 28)
                            .frame(width: proxy.size.width * 0.9, height: proxy.size.height * 0.8)
                    }
                    HStack(alignment: .center, spacing: barCount > 10 ? 3 : 2) {
                        ForEach(0..<barCount, id: \.self) { index in
                            Capsule()
                                .fill(tint)
                                .frame(height: proxy.size.height * level(index, time: t, motion: motion))
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .opacity(motion.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: phase)
    }

    /// A bar's height, 0...1: an arch across the row (taller in the
    /// middle) that ripples faster and higher while the assistant speaks.
    private func level(_ index: Int, time: TimeInterval, motion: LiveVoiceOrb.Motion) -> CGFloat {
        let position = Double(index) / Double(max(1, barCount - 1))
        let arch = 0.25 + 0.5 * sin(position * .pi)
        guard moves else { return CGFloat(phase == .muted || phase == .idle ? 0.08 : arch * 0.6) }
        let swing = motion.amplitude * 8
        if phase == .listening, let inputFraction {
            // Low and gently rippling in silence, up to the full arch at speech.
            let ripple = 0.5 + 0.5 * sin(time * motion.speed * 2 + position * 9)
            let lift = 0.2 + 0.8 * inputFraction
            return CGFloat(max(0.06, min(1, arch * lift * (0.75 + 0.25 * ripple))))
        }
        let ripple = 0.6 * sin(time * motion.speed * 2 + position * 9) + 0.4 * sin(time * motion.speed * 3.1 + position * 23)
        return CGFloat(max(0.06, min(1, arch + ripple * swing * arch)))
    }
}
