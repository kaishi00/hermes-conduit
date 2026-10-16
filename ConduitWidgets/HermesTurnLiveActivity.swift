import ActivityKit
import SwiftUI
import WidgetKit

/// A running Hermes turn on the Lock Screen and in the Dynamic Island
/// (#605): what Hermes is doing, how long the turn has run, how many tools
/// it used and how full its context is. Tapping it opens the chat.
struct HermesTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HermesTurnAttributes.self) { context in
            HermesTurnLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .widgetURL(context.attributes.link)
                .activityBackgroundTint(HermesTurnStyle.glass)
                .activitySystemActionForegroundColor(HermesTurnStyle.gold)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HermesTurnPhaseDisc(state: state, size: 40)
                        .padding(.leading, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HermesTurnElapsed(attributes: attributes, state: state)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(HermesTurnStyle.timerTint(for: state.turnPhase))
                        .frame(maxWidth: 76, alignment: .trailing)
                        .padding(.trailing, 2)
                }
                DynamicIslandExpandedRegion(.center) {
                    HermesTurnHeadline(attributes: attributes, state: state)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.colorScheme, .dark)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if HermesTurnFooter.hasContent(state) {
                        HermesTurnFooter(attributes: attributes, state: state)
                            .padding(.horizontal, 2)
                            .padding(.top, 4)
                            .environment(\.colorScheme, .dark)
                    }
                }
            } compactLeading: {
                HermesTurnPhaseIcon(state: state)
                    .font(.footnote.weight(.semibold))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: HermesTurnCopy.status(state, language: attributes.language)))
            } compactTrailing: {
                HermesTurnElapsed(attributes: attributes, state: state)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(HermesTurnStyle.timerTint(for: state.turnPhase))
                    .frame(maxWidth: 48)
            } minimal: {
                HermesTurnPhaseIcon(state: state)
                    .font(.footnote.weight(.semibold))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: HermesTurnCopy.status(state, language: attributes.language)))
            }
            .widgetURL(attributes.link)
            .keylineTint(HermesTurnStyle.tint(for: state.turnPhase))
        }
    }
}

/// V2's colors, here because the widget extension doesn't build Theme.swift.
/// The card is always dark glass, so these are the dark values of
/// Theme.swift's conduitAdaptiveAccent (gold), conduitAdaptiveAccentSoft,
/// conduitAdaptiveAttention and conduitAdaptiveSuccess: keep them in step.
enum HermesTurnStyle {
    static let gold = Color(red: 0.88, green: 0.67, blue: 0.28)
    static let goldSoft = Color(red: 0.98, green: 0.83, blue: 0.48)
    static let attention = Color(red: 0.96, green: 0.65, blue: 0.24)
    static let success = Color(red: 0.38, green: 0.80, blue: 0.50)
    static let failure = Color(red: 0.96, green: 0.42, blue: 0.40)
    static let glass = Color(red: 0.09, green: 0.075, blue: 0.08).opacity(0.62)

    static func tint(for phase: HermesTurnPhase) -> Color {
        switch phase {
        case .approval, .input: attention
        case .failed: failure
        case .done: success
        case .stopped: .secondary
        case .thinking, .writing, .tool: gold
        }
    }

    /// The timer stays gold while the turn runs and turns plain once it ends.
    static func timerTint(for phase: HermesTurnPhase) -> Color {
        if phase.isFinished { return .primary }
        return phase.waitsOnUser ? attention : gold
    }

    /// The glow behind the card: the profile's color while Hermes works,
    /// the phase's color once it needs you or is done.
    static func glow(_ attributes: HermesTurnAttributes, phase: HermesTurnPhase) -> Color {
        switch phase {
        case .thinking, .writing, .tool:
            if let rgb = attributes.glowColor { return Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
            return gold
        case .stopped: return .gray
        case .approval, .input, .done, .failed: return tint(for: phase)
        }
    }
}

private struct HermesTurnLockScreenView: View {
    let attributes: HermesTurnAttributes
    let state: HermesTurnAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                HermesTurnPhaseDisc(state: state, size: 40)
                HermesTurnHeadline(attributes: attributes, state: state)
                Spacer(minLength: 0)
                HermesTurnElapsed(attributes: attributes, state: state)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(HermesTurnStyle.timerTint(for: state.turnPhase))
                    .frame(maxWidth: 88, alignment: .trailing)
            }
            if HermesTurnFooter.hasContent(state) {
                HermesTurnFooter(attributes: attributes, state: state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(alignment: .leading) {
            // The V2 backdrop glow, rising from behind the status disc.
            GeometryReader { proxy in
                RadialGradient(
                    colors: [HermesTurnStyle.glow(attributes, phase: state.turnPhase).opacity(0.34), .clear],
                    center: UnitPoint(x: 0.08, y: 0.35),
                    startRadius: 0,
                    endRadius: proxy.size.width * 0.62
                )
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .opacity(isStale && !state.turnPhase.isFinished ? 0.6 : 1)
    }
}

/// The profile and chat on one quiet line, the status under it.
private struct HermesTurnHeadline: View {
    let attributes: HermesTurnAttributes
    let state: HermesTurnAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            whoLine
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: HermesTurnCopy.status(state, language: attributes.language))
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var whoLine: some View {
        if let name = attributes.profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            (Text(verbatim: name).fontWeight(.semibold).foregroundStyle(.primary)
                + Text(verbatim: " · ")
                + Text(verbatim: attributes.chatTitle))
                .privacySensitive()
        } else {
            Text(verbatim: attributes.chatTitle)
                .privacySensitive()
        }
    }
}

/// Under the headline: what to do when Hermes waits on you, else the tool
/// count and a context meter. The pill is a hint, not a button: tapping
/// the card opens the chat, where the approval or answer happens.
private struct HermesTurnFooter: View {
    let attributes: HermesTurnAttributes
    let state: HermesTurnAttributes.ContentState

    static func hasContent(_ state: HermesTurnAttributes.ContentState) -> Bool {
        state.turnPhase.waitsOnUser || state.tools > 0 || state.context != nil
    }

    var body: some View {
        if state.turnPhase.waitsOnUser {
            Text(verbatim: WidgetLocalization.string(state.turnPhase == .approval ? "Review" : "Open chat", language: attributes.language))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(HermesTurnStyle.attention, in: Capsule())
        } else if state.tools > 0 || state.context != nil {
            HStack(spacing: 10) {
                if state.tools > 0 {
                    Text(verbatim: HermesTurnCopy.tools(state.tools, language: attributes.language))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.10), in: Capsule())
                        .fixedSize()
                }
                if let context = state.context {
                    HermesTurnContextMeter(percent: context, isFinished: state.turnPhase.isFinished)
                    Text(verbatim: HermesTurnCopy.context(context, language: attributes.language))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    Spacer(minLength: 0)
                }
            }
            .lineLimit(1)
        }
    }
}

/// How full the context is, as a thin gold bar (grey once the turn ended).
private struct HermesTurnContextMeter: View {
    let percent: Int
    let isFinished: Bool

    var body: some View {
        let fraction = Double(max(0, min(100, percent))) / 100
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                if fraction > 0 {
                    Capsule()
                        .fill(isFinished
                            ? AnyShapeStyle(Color.secondary)
                            : AnyShapeStyle(LinearGradient(colors: [HermesTurnStyle.gold, HermesTurnStyle.goldSoft], startPoint: .leading, endPoint: .trailing)))
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// The status symbol on a faint disc of its color, like a V2 chat row.
private struct HermesTurnPhaseDisc: View {
    let state: HermesTurnAttributes.ContentState
    let size: CGFloat

    var body: some View {
        let tint = HermesTurnStyle.tint(for: state.turnPhase)
        HermesTurnPhaseIcon(state: state)
            .font(.system(size: size * 0.45, weight: .semibold))
            .frame(width: size, height: size)
            .background(tint.opacity(0.18), in: Circle())
    }
}

/// The turn's running time: a live timer while it runs, the final time once
/// it ended.
private struct HermesTurnElapsed: View {
    let attributes: HermesTurnAttributes
    let state: HermesTurnAttributes.ContentState

    var body: some View {
        if let ended = state.endDate, ended > attributes.startedAt {
            Text(timerInterval: attributes.startedAt...ended, pauseTime: ended, countsDown: false)
                .multilineTextAlignment(.trailing)
        } else if state.turnPhase.isFinished {
            EmptyView()
        } else {
            Text(timerInterval: attributes.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct HermesTurnPhaseIcon: View {
    let state: HermesTurnAttributes.ContentState

    var body: some View {
        Image(systemName: Self.symbol(for: state))
            .foregroundStyle(HermesTurnStyle.tint(for: state.turnPhase))
            .accessibilityHidden(true)
    }

    static func symbol(for state: HermesTurnAttributes.ContentState) -> String {
        switch state.turnPhase {
        case .thinking: "sparkles"
        case .writing: "text.cursor"
        case .approval: "hand.raised.fill"
        case .input: "questionmark.bubble.fill"
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.fill"
        case .tool: toolSymbol(state.toolCategory ?? .tool)
        }
    }

    private static func toolSymbol(_ category: HermesToolCategory) -> String {
        switch category {
        case .terminal: "terminal"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .files: "doc.text"
        case .web: "globe"
        case .browser: "safari"
        case .agents: "person.2"
        case .memory: "brain"
        case .images: "photo"
        case .audio: "waveform"
        case .planning: "checklist"
        case .schedule: "calendar.badge.clock"
        case .messages: "paperplane"
        case .skills: "book"
        case .connector: "puzzlepiece.extension"
        case .phone: "iphone"
        case .home: "house"
        case .tool: "wrench.and.screwdriver"
        }
    }
}
