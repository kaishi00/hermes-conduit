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
    let phase: LiveVoiceCallPhase
    let statusText: String
    var note: String?
    let transcript: [VoiceConversationTranscriptEntry]
    /// The VoiceOver label for one of the assistant's lines.
    let assistantLabel: (String) -> String
    /// Observed only by the small views that show the attached chat, so job
    /// progress doesn't redraw the whole call.
    let jobs: VoiceBackgroundJobSupervisor
    let isMicrophoneMuted: Bool
    let canMute: Bool
    let canInterrupt: Bool
    let onToggleMute: () -> Void
    /// Nil for an engine that is only interrupted by speaking over it: the
    /// sheet then has no Interrupt button.
    var onInterrupt: (() -> Void)?
    let onEnd: () -> Void
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsTranscript = false

    var body: some View {
        ZStack {
            ConduitBackdrop()
            VStack(spacing: 0) {
                header
                if showsTranscript {
                    transcriptList
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
    }

    /// Only a running call minimises; dismissing any other closes it.
    private var isMinimisable: Bool {
        switch phase {
        case .idle, .failed: return false
        case .connecting, .listening, .speaking, .muted, .ending: return true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                // The sheet's dismissal minimises a running call.
                dismiss()
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
                Text(verbatim: title)
                    .font(.headline)
                    .lineLimit(1)
                LiveVoiceCallThreadLabel(jobs: jobs)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            // Balances the chevron so the title stays centred.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
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
            captions
        }
        .transition(.opacity)
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
                    ForEach(transcript) { entry in
                        LiveVoiceTranscriptBubble(entry: entry, label: label(for: entry))
                    }
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
                // On an open speaker the mic is closed while the assistant
                // talks, so this is the way to cut in.
                if let onInterrupt {
                    LiveVoiceCallButton(
                        symbol: "hand.raised.fill",
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

/// "Working in <chat>" under the title while the call is attached to one.
private struct LiveVoiceCallThreadLabel: View {
    @ObservedObject var jobs: VoiceBackgroundJobSupervisor

    var body: some View {
        if let thread = jobs.liveThread?.title {
            Text(verbatim: thread)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct LiveVoiceCallButton: View {
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
    /// Capped so four buttons still fit across a phone at the largest
    /// text sizes; the glyph inside keeps scaling.
    private var diameter: CGFloat { min(scaledDiameter, 78) }

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
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private struct LiveVoiceTranscriptBubble: View {
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
/// LiquidOrbView): calm and grey-gold at rest, lit while the call listens,
/// swelling as the assistant speaks. Otherwise, for a failed call, and for
/// the small still accessory orb, it is a soft sphere drawn from gradients that breathes and
/// pulses the same way. Phase decides colour and motion; there is no audio
/// level feed common to every engine.
struct LiveVoiceOrb: View {
    let phase: LiveVoiceCallPhase
    /// Off for a small accessory orb: it keeps its colour but stays still.
    var animates = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        case .connecting, .listening: return LiquidLook(state: .active, speech: 0)
        case .speaking: return LiquidLook(state: .active, speech: 1)
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
        if animates, phase != .failed, let pipeline = LiquidOrbPipeline.shared {
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
            LiquidOrbView(pipeline: pipeline, state: look.state, speech: look.speech, animates: !reduceMotion)
                .frame(width: size * 1.3, height: size * 1.3)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .opacity(Self.motion(for: phase).opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: phase)
    }

    @ViewBuilder
    private var gradientOrb: some View {
        let motion = Self.motion(for: phase)
        let moves = animates && !reduceMotion && motion.amplitude > 0
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
