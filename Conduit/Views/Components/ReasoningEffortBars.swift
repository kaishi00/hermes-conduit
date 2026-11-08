//
//  ReasoningEffortBars.swift
//  Conduit
//
//  The model sheet's reasoning control: one bar per level, rising from Off
//  to Ultra (Eric, 2026-11-08). A finger slides across the strip and the
//  level follows the column it's in, with a selection tick each time it
//  crosses into another bar; the level is sent once, when the finger lifts.
//  A tap picks a bar too. A drag that starts up or down scrolls the sheet.
//

import SwiftUI

struct ReasoningEffortBars: View {
    /// The runtime's effort word ("none" when off).
    let effort: String
    let disabled: Bool
    /// The levels offered, lowest first: a setting Hermes takes fewer
    /// levels for (a helper's slot has no Ultra) shows only those.
    var levels: [ReasoningEffortLevel] = ReasoningEffortLevel.allCases
    /// What an empty `effort` means where it isn't Off: a setting that
    /// follows another one's reasoning ("Same as chats"). No bar is lit.
    var unsetTitle: String? = nil
    /// The level the finger lifted on, or VoiceOver stepped to.
    let onCommit: (ReasoningEffortLevel) -> Void

    @Environment(\.colorScheme) private var colorScheme
    /// The level under the finger while it slides.
    @State private var dragLevel: ReasoningEffortLevel?
    /// This drag started up or down: it's the sheet's scroll, not a slide.
    @State private var dragIsScroll = false

    static let stripHeight: CGFloat = 50

    /// The level whose column holds `x` across a strip `width` wide: each
    /// level owns an equal column, the full strip high, and a finger past
    /// either end stays on the end level.
    static func level(atX x: CGFloat, width: CGFloat, levels: [ReasoningEffortLevel] = ReasoningEffortLevel.allCases) -> ReasoningEffortLevel {
        guard width > 0 else { return levels[0] }
        let index = Int((x / width * CGFloat(levels.count)).rounded(.down))
        return levels[min(max(index, 0), levels.count - 1)]
    }

    /// The level VoiceOver's swipe up or down lands on. A level Conduit
    /// doesn't list steps from Medium.
    static func level(stepping current: ReasoningEffortLevel?, by step: Int, levels: [ReasoningEffortLevel] = ReasoningEffortLevel.allCases) -> ReasoningEffortLevel {
        let index = current.flatMap { levels.firstIndex(of: $0) } ?? levels.firstIndex(of: .medium) ?? 0
        return levels[min(max(index + step, 0), levels.count - 1)]
    }

    /// The effort follows another setting's: nothing of its own is lit.
    private var isUnset: Bool {
        unsetTitle != nil && effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shownLevel: ReasoningEffortLevel? {
        dragLevel ?? (isUnset ? nil : ReasoningEffortLevel(runtimeEffort: effort))
    }

    private var shownTitle: String {
        if let dragLevel { return dragLevel.title }
        if isUnset, let unsetTitle { return unsetTitle }
        return ReasoningEffortLevel.displayTitle(for: effort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(Color.conduitAura)
                    .accessibilityHidden(true)
                Text(AppLocalization.string("Reasoning"))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: shownTitle)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.conduitAccent)
                    .contentTransition(.numericText())
            }
            .scaledFont(.subheadline)

            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(levels.enumerated()), id: \.element) { index, level in
                        bar(index: index, level: level, columnWidth: proxy.size.width / CGFloat(levels.count))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                // Every column is the strip's full height, gaps included,
                // so a finger anywhere in it counts.
                .contentShape(Rectangle())
                // A tap picks the bar's column at once.
                .onTapGesture(coordinateSpace: .local) { location in
                    guard !disabled else { return }
                    Haptics.selection()
                    onCommit(Self.level(atX: location.x, width: proxy.size.width, levels: levels))
                }
                // A slide, alongside the sheet's scroll: a drag that starts
                // up or down is left to the scroll and picks nothing.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .local)
                        .onChanged { value in
                            guard !disabled else { return }
                            if dragLevel == nil, !dragIsScroll,
                               abs(value.translation.height) > abs(value.translation.width) {
                                dragIsScroll = true
                            }
                            guard !dragIsScroll else { return }
                            let level = Self.level(atX: value.location.x, width: proxy.size.width, levels: levels)
                            guard level != dragLevel else { return }
                            dragLevel = level
                            Haptics.selection()
                        }
                        .onEnded { value in
                            let slid = !dragIsScroll && dragLevel != nil
                            dragIsScroll = false
                            dragLevel = nil
                            guard slid, !disabled else { return }
                            onCommit(Self.level(atX: value.location.x, width: proxy.size.width, levels: levels))
                        }
                )
            }
            .frame(height: Self.stripHeight)
            .animation(ConduitMotion.response, value: shownLevel)

            HStack {
                Text((levels.first ?? .off).title)
                Spacer()
                Text((levels.last ?? .ultra).title)
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .opacity(disabled && dragLevel == nil ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AppLocalization.string("Reasoning")))
        .accessibilityValue(Text(verbatim: shownTitle))
        .accessibilityAdjustableAction { direction in
            guard !disabled else { return }
            switch direction {
            case .increment:
                Haptics.selection()
                onCommit(Self.level(stepping: shownLevel, by: 1, levels: levels))
            case .decrement:
                Haptics.selection()
                onCommit(Self.level(stepping: shownLevel, by: -1, levels: levels))
            @unknown default: break
            }
        }
        .accessibilityIdentifier("modelPicker.reasoningBars")
    }

    private func bar(index: Int, level: ReasoningEffortLevel, columnWidth: CGFloat) -> some View {
        let shown = shownLevel.flatMap { levels.firstIndex(of: $0) }
        let fill: Color = {
            guard let shown else { return Color.primary.opacity(0.14) }
            if index == shown { return .conduitAccent }
            if index < shown { return Color.conduitAccent.opacity(colorScheme == .dark ? 0.5 : 0.4) }
            return Color.primary.opacity(0.14)
        }()
        let rise = CGFloat(index) / CGFloat(max(levels.count - 1, 1))
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fill)
            .frame(width: min(24, columnWidth * 0.6), height: 10 + rise * (Self.stripHeight - 14))
            .frame(width: columnWidth, height: Self.stripHeight, alignment: .bottom)
    }
}
