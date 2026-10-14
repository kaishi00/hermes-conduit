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
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HermesTurnPhaseIcon(state: state)
                        .font(.title2)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HermesTurnElapsed(attributes: attributes, state: state)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .frame(maxWidth: 72, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: attributes.chatTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .privacySensitive()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: HermesTurnCopy.status(state, language: attributes.language))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HermesTurnDetails(attributes: attributes, state: state)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HermesTurnPhaseIcon(state: state)
            } compactTrailing: {
                HermesTurnElapsed(attributes: attributes, state: state)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: 48)
            } minimal: {
                HermesTurnPhaseIcon(state: state)
            }
            .widgetURL(attributes.link)
            .keylineTint(HermesTurnPhaseIcon.tint(for: state.turnPhase))
        }
    }
}

private struct HermesTurnLockScreenView: View {
    let attributes: HermesTurnAttributes
    let state: HermesTurnAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HermesTurnPhaseIcon(state: state)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: attributes.chatTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .privacySensitive()
                Text(verbatim: HermesTurnCopy.status(state, language: attributes.language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HermesTurnDetails(attributes: attributes, state: state)
            }
            Spacer(minLength: 0)
            HermesTurnElapsed(attributes: attributes, state: state)
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(maxWidth: 88, alignment: .trailing)
        }
        .padding(16)
        .opacity(isStale && !state.turnPhase.isFinished ? 0.6 : 1)
    }
}

/// Tool count and context use, when there is something to say.
private struct HermesTurnDetails: View {
    let attributes: HermesTurnAttributes
    let state: HermesTurnAttributes.ContentState

    var body: some View {
        let parts = [
            state.tools > 0 ? HermesTurnCopy.tools(state.tools, language: attributes.language) : nil,
            state.context.map { HermesTurnCopy.context($0, language: attributes.language) },
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(verbatim: parts.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
            Text(verbatim: "")
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
            .foregroundStyle(Self.tint(for: state.turnPhase))
            .accessibilityHidden(true)
    }

    static func tint(for phase: HermesTurnPhase) -> Color {
        switch phase {
        case .approval, .input: .orange
        case .failed: .red
        case .done: .green
        case .stopped: .secondary
        case .thinking, .writing, .tool: .accentColor
        }
    }

    static func symbol(for state: HermesTurnAttributes.ContentState) -> String {
        switch state.turnPhase {
        case .thinking: "sparkles"
        case .writing: "text.cursor"
        case .approval: "hand.raised.fill"
        case .input: "questionmark.bubble.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle.fill"
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
