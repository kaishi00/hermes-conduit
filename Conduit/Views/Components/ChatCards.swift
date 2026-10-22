//
//  ChatCards.swift
//  Conduit
//
//  The agent's plan, docked above the composer (docs/PLAN_CARD.md): one
//  slim line ("Tasks 2/5" and the current item) that opens upward into the
//  whole card. ChatCardsModel decides when; this only draws it.
//

import SwiftUI

struct ChatPlanDock: View {
    @ObservedObject var cards: ChatCardsModel
    /// Someone is typing: the plan keeps to its one line.
    let isCompact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsPlanSheet = false
    @State private var pulses = false

    var body: some View {
        Group {
            if let plan = cards.plan, cards.showsPlan {
                if cards.planExpanded, !isCompact {
                    PlanCard(
                        plan: plan,
                        pinned: cards.pinsPlan,
                        togglePin: { cards.setPinsPlan(!cards.pinsPlan) },
                        collapse: { cards.setPlanExpanded(false) },
                        showAll: { showsPlanSheet = true }
                    )
                    .transition(openTransition)
                } else {
                    PlanStrip(plan: plan, pulses: pulses) { cards.setPlanExpanded(true) }
                        .transition(popTransition)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: cards.plan)
        .animation(ConduitMotion.overshoot(reduceMotion: reduceMotion), value: cards.planExpanded)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: cards.planRetired)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: isCompact)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        // A new plan announces itself on the line, without opening over
        // the chat: a pulse, and a light tap.
        .onChange(of: cards.announcement) {
            Haptics.light()
            guard !reduceMotion else { return }
            withAnimation(ConduitMotion.overshoot(reduceMotion: false)) { pulses = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                withAnimation(ConduitMotion.ease(reduceMotion: false)) { pulses = false }
            }
        }
        .sheet(isPresented: $showsPlanSheet) {
            PlanSheet(cards: cards)
        }
    }

    /// The line pops up from the composer.
    private var popTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity)
    }

    /// The card opens upward from the line.
    private var openTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.9, anchor: .bottom).combined(with: .opacity)
    }
}

// MARK: - Plan

/// A small square button on a card's header.
private struct CardIconButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isOn ? Color.conduitAccent : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct PlanCard: View {
    let plan: AgentPlan
    let pinned: Bool
    let togglePin: () -> Void
    let collapse: () -> Void
    let showAll: () -> Void

    var body: some View {
        let window = AgentPlanWindow(plan: plan)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button(action: showAll) {
                    HStack(spacing: 6) {
                        Image(systemName: plan.isFinished ? "checkmark.circle.fill" : "checklist")
                            .foregroundStyle(plan.isFinished ? Color.green : Color.conduitAccent)
                        Text("Tasks")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(PlanText.count(plan))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: PlanText.spoken(plan)))
                .accessibilityHint(Text("Shows the whole plan"))
                Spacer(minLength: 4)
                CardIconButton(systemImage: pinned ? "pin.fill" : "pin",
                               label: pinned ? "Unpin" : "Pin", isOn: pinned, action: togglePin)
                CardIconButton(systemImage: "chevron.down", label: "Collapse", action: collapse)
            }
            ProgressView(value: plan.progress)
                .tint(plan.isFinished ? .green : .conduitAccent)
                .scaleEffect(x: 1, y: 0.7, anchor: .center)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if window.before > 0 {
                    PlanFoldRow(
                        text: window.beforeAreDone
                            ? PlanText.doneAbove(window.before)
                            : PlanText.earlier(window.before),
                        systemImage: window.beforeAreDone ? "checkmark" : "ellipsis",
                        action: showAll
                    )
                }
                ForEach(window.rows) { item in
                    PlanItemRow(item: item, depth: plan.depth(of: item), lineLimit: 2)
                }
                if window.after > 0 {
                    PlanFoldRow(text: PlanText.more(window.after), systemImage: "ellipsis", action: showAll)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassControl(cornerRadius: 20, interactive: false)
        .contextMenu {
            Button(action: showAll) { Label("Show All", systemImage: "list.bullet") }
            Button(action: togglePin) {
                pinned ? Label("Unpin", systemImage: "pin.slash") : Label("Pin", systemImage: "pin")
            }
        }
    }
}

private struct PlanFoldRow: View {
    let text: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                    .frame(width: 16)
                Text(verbatim: text)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Shows the whole plan"))
    }
}

struct PlanItemRow: View {
    let item: AgentPlanItem
    let depth: Int
    var lineLimit: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .modifier(PulsesWhileActive(isOn: item.status == .inProgress))
            Text(verbatim: item.content)
                .font(.footnote.weight(item.status == .inProgress ? .semibold : .regular))
                .foregroundStyle(item.status.isOpen ? Color.primary : Color.secondary)
                .strikethrough(item.status == .cancelled)
                .lineLimit(lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(item.content), \(PlanText.status(item.status))"))
    }

    private var symbol: String {
        switch item.status {
        case .pending: return "circle"
        case .inProgress: return "circle.inset.filled"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private var tint: Color {
        switch item.status {
        case .pending, .cancelled: return .secondary
        case .inProgress: return .conduitAccent
        case .completed: return .green
        }
    }
}

/// The item in progress breathes, as the chat's running tool does.
private struct PulsesWhileActive: ViewModifier {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isOn, !reduceMotion {
            content.symbolEffect(.pulse, options: .repeating)
        } else {
            content
        }
    }
}

/// The folded plan: one line above the composer with its progress, a
/// "Tasks 2/5" count and the item in progress. A tap opens the card.
private struct PlanStrip: View {
    let plan: AgentPlan
    let pulses: Bool
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                if plan.isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    PlanRing(progress: plan.progress)
                        .frame(width: 16, height: 16)
                }
                Text("Tasks")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(verbatim: PlanText.fraction(plan))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let current = plan.current {
                    Text(verbatim: current.content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .conduitGlassControl(cornerRadius: 20, tint: pulses ? Color.conduitAccent.opacity(0.25) : .clear)
            .scaleEffect(pulses ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(verbatim: PlanText.spoken(plan)))
        .accessibilityHint(Text("Shows the plan"))
    }
}

private struct PlanRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Color.conduitAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// The whole plan, from the card's header or its folded rows.
private struct PlanSheet: View {
    @ObservedObject var cards: ChatCardsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let plan = cards.plan {
                    List {
                        Section {
                            ProgressView(value: plan.progress) {
                                Text(PlanText.count(plan))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .tint(plan.isFinished ? .green : .conduitAccent)
                        }
                        Section {
                            ForEach(plan.items) { item in
                                PlanItemRow(item: item, depth: plan.depth(of: item, cap: 4))
                            }
                        }
                    }
                } else {
                    // The plan went (another chat opened): nothing to list.
                    Color.clear.onAppear { dismiss() }
                }
            }
            .navigationTitle(Text("Tasks"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        cards.setPinsPlan(!cards.pinsPlan)
                    } label: {
                        cards.pinsPlan ? Label("Unpin", systemImage: "pin.fill") : Label("Pin", systemImage: "pin")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

enum PlanText {
    /// "3 of 5 done".
    static func count(_ plan: AgentPlan) -> String {
        AppLocalization.string("\(String(plan.completedCount)) of \(String(plan.countedTotal)) done")
    }

    /// "3/5", for the line.
    static func fraction(_ plan: AgentPlan) -> String {
        "\(plan.completedCount)/\(plan.countedTotal)"
    }

    static func doneAbove(_ count: Int) -> String {
        AppLocalization.string("\(count) done")
    }

    static func earlier(_ count: Int) -> String {
        AppLocalization.string("\(count) earlier")
    }

    static func more(_ count: Int) -> String {
        AppLocalization.string("\(count) more")
    }

    static func status(_ status: AgentPlanItem.Status) -> String {
        switch status {
        case .pending: return AppLocalization.string("To do")
        case .inProgress: return AppLocalization.string("In progress")
        case .completed: return AppLocalization.string("Done")
        case .cancelled: return AppLocalization.string("Cancelled")
        }
    }

    /// What VoiceOver reads for the card and the line.
    static func spoken(_ plan: AgentPlan) -> String {
        var parts = [AppLocalization.string("Tasks"), count(plan)]
        if let current = plan.current {
            parts.append(AppLocalization.string("Now: \(current.content)"))
        }
        return parts.joined(separator: ", ")
    }
}
