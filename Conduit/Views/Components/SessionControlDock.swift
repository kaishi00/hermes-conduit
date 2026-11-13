//
//  SessionControlDock.swift
//  Conduit
//
//  Above the composer: the chat's standing goal, loop and heartbeat, as
//  Hermes keeps them (issue 821), each with pause or resume and an end,
//  the goal's extra criteria removable one by one. They are set with
//  `/goal`, `/loop`, `/heartbeat` and `/subgoal`, which Hermes runs.
//  SessionControl.swift holds the state, AppState+SessionControl.swift
//  what the buttons do.
//

import SwiftUI

struct SessionControlDock: View {
    @ObservedObject var store: SessionControlStore
    let appState: AppState
    /// The open chat: passed so the dock redraws when another opens.
    let openChatID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirming: SessionControlAction?

    private var shows: Bool {
        openChatID != nil && appState.sessionControlIsOpenChat(store.sessionID)
            && (!store.snapshot.isEmpty || store.notice != nil)
    }

    var body: some View {
        Group {
            if shows {
                VStack(alignment: .leading, spacing: 6) {
                    if let goal = store.snapshot.goal { goalRow(goal) }
                    if let loop = store.snapshot.loop { loopRow(loop) }
                    if let heartbeat = store.snapshot.heartbeat { heartbeatRow(heartbeat) }
                    if let notice = store.notice {
                        Text(verbatim: notice)
                            .scaledFont(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 12)
        .padding(.bottom, shows ? 6 : 0)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: store.snapshot)
        // A confirmation asked in one chat never runs in the next.
        .onChange(of: openChatID) { confirming = nil }
        .onChange(of: store.notice) {
            if let notice = store.notice { UIAccessibility.post(notification: .announcement, argument: notice) }
        }
        .confirmationDialog(
            confirming.map(Self.confirmTitle) ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let action = confirming {
                Button(Self.confirmButton(action), role: .destructive) {
                    confirming = nil
                    Task { await appState.runSessionControl(action) }
                }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) { confirming = nil }
        } message: {
            Text(verbatim: confirming.map(Self.confirmMessage) ?? "")
        }
    }

    // MARK: - Rows

    private func goalRow(_ goal: SessionControlSnapshot.Goal) -> some View {
        row(
            symbol: goal.isDone ? "checkmark.seal" : "target",
            caption: Self.goalCaption(goal),
            text: goal.title,
            detail: goal.subgoals.isEmpty ? nil : AppLocalization.string("Also: \(goal.subgoals.joined(separator: "; "))", table: .chat),
            paused: goal.isPaused
        ) {
            if !goal.isDone {
                if goal.isPaused {
                    actionButton(.goalResume, AppLocalization.string("Resume Goal", table: .chat), "play.circle")
                } else {
                    actionButton(.goalPause, AppLocalization.string("Pause Goal", table: .chat), "pause.circle")
                }
            }
            if !goal.subgoals.isEmpty {
                Menu {
                    ForEach(Array(goal.subgoals.enumerated()), id: \.offset) { index, subgoal in
                        Button(role: .destructive) {
                            Task { await appState.runSessionControl(.subgoalRemove(index: index + 1, criterion: subgoal)) }
                        } label: {
                            Text(verbatim: subgoal)
                        }
                    }
                    Divider()
                    Button(role: .destructive) { confirming = .subgoalClear } label: {
                        Label(AppLocalization.string("Remove All", table: .chat), systemImage: "xmark.circle")
                    }
                } label: {
                    Label(AppLocalization.string("Remove a Criterion", table: .chat), systemImage: "minus.circle")
                }
            }
            Button(role: .destructive) { confirming = .goalClear } label: {
                Label(AppLocalization.string("Clear Goal", table: .chat), systemImage: "xmark.circle")
            }
        }
    }

    private func loopRow(_ loop: SessionControlSnapshot.Loop) -> some View {
        row(
            symbol: "repeat",
            caption: Self.loopCaption(loop),
            text: loop.prompt,
            detail: loop.until.isEmpty ? nil : AppLocalization.string("Until \(loop.until)", table: .chat),
            paused: loop.isPaused
        ) {
            if loop.isPaused {
                actionButton(.loopResume, AppLocalization.string("Resume Loop", table: .chat), "play.circle")
            } else {
                actionButton(.loopPause, AppLocalization.string("Pause Loop", table: .chat), "pause.circle")
            }
            Button(role: .destructive) { confirming = .loopStop } label: {
                Label(AppLocalization.string("Stop Loop", table: .chat), systemImage: "stop.circle")
            }
        }
    }

    private func heartbeatRow(_ heartbeat: SessionControlSnapshot.Heartbeat) -> some View {
        row(
            symbol: "waveform.path.ecg",
            caption: Self.heartbeatCaption(heartbeat),
            text: heartbeat.prompt,
            detail: nil,
            paused: heartbeat.isPaused
        ) {
            if heartbeat.isPaused {
                actionButton(.heartbeatResume, AppLocalization.string("Resume Heartbeat", table: .chat), "play.circle")
            } else {
                actionButton(.heartbeatPause, AppLocalization.string("Pause Heartbeat", table: .chat), "pause.circle")
            }
            Button(role: .destructive) { confirming = .heartbeatClear } label: {
                Label(AppLocalization.string("Clear Heartbeat", table: .chat), systemImage: "xmark.circle")
            }
        }
    }

    private func actionButton(_ action: SessionControlAction, _ title: String, _ symbol: String) -> some View {
        Button {
            Task { await appState.runSessionControl(action) }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private func row<Actions: View>(
        symbol: String,
        caption: String,
        text: String,
        detail: String?,
        paused: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .scaledFont(.footnote.weight(.semibold))
                .foregroundStyle(paused ? Color.secondary : Color.conduitAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: caption)
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: text)
                    .scaledFont(.subheadline)
                    .foregroundStyle(paused ? .secondary : .primary)
                    .lineLimit(2)
                if let detail {
                    Text(verbatim: detail)
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if store.working != nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
            } else {
                Menu {
                    actions()
                } label: {
                    Image(systemName: "ellipsis")
                        .scaledFont(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(verbatim: AppLocalization.string("\(caption) options", table: .chat)))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .conduitGlassControl(cornerRadius: 20, interactive: false)
    }

    // MARK: - Words

    static func goalCaption(_ goal: SessionControlSnapshot.Goal) -> String {
        if goal.isDone { return AppLocalization.string("Goal met", table: .chat) }
        if goal.isPaused { return AppLocalization.string("Goal · paused", table: .chat) }
        if goal.maxTurns > 0 {
            return AppLocalization.string("Goal · turn \(String(goal.turnsUsed)) of \(String(goal.maxTurns))", table: .chat)
        }
        return AppLocalization.string("Goal", table: .chat)
    }

    static func loopCaption(_ loop: SessionControlSnapshot.Loop) -> String {
        let every = SessionControlSnapshot.everyText(seconds: loop.intervalSeconds)
        if loop.isPaused { return AppLocalization.string("Loop · paused", table: .chat) }
        if loop.deferredByGoal { return AppLocalization.string("Loop · waiting for the goal", table: .chat) }
        if loop.maxTicks > 0 {
            return AppLocalization.string("Loop · \(every) · run \(String(loop.ticksFired)) of \(String(loop.maxTicks))", table: .chat)
        }
        return AppLocalization.string("Loop · \(every)", table: .chat)
    }

    static func heartbeatCaption(_ heartbeat: SessionControlSnapshot.Heartbeat) -> String {
        if heartbeat.isPaused { return AppLocalization.string("Heartbeat · paused", table: .chat) }
        let every = SessionControlSnapshot.everyText(seconds: Double(heartbeat.intervalSeconds))
        return AppLocalization.string("Heartbeat · \(every)", table: .chat)
    }

    static func confirmTitle(_ action: SessionControlAction) -> String {
        switch action {
        case .goalClear: return AppLocalization.string("Clear this goal?", table: .chat)
        case .loopStop: return AppLocalization.string("Stop this loop?", table: .chat)
        case .heartbeatClear: return AppLocalization.string("Clear this heartbeat?", table: .chat)
        default: return AppLocalization.string("Remove every criterion?", table: .chat)
        }
    }

    static func confirmButton(_ action: SessionControlAction) -> String {
        switch action {
        case .goalClear: return AppLocalization.string("Clear Goal", table: .chat)
        case .loopStop: return AppLocalization.string("Stop Loop", table: .chat)
        case .heartbeatClear: return AppLocalization.string("Clear Heartbeat", table: .chat)
        default: return AppLocalization.string("Remove All", table: .chat)
        }
    }

    static func confirmMessage(_ action: SessionControlAction) -> String {
        switch action {
        case .goalClear: return AppLocalization.string("Hermes stops working toward it. Set a new one with /goal.", table: .chat)
        case .loopStop: return AppLocalization.string("Hermes stops running the prompt. Start another with /loop.", table: .chat)
        case .heartbeatClear: return AppLocalization.string("Hermes stops coming back to this chat when it's idle. Set another with /heartbeat.", table: .chat)
        default: return AppLocalization.string("The goal stays; only its extra criteria go.", table: .chat)
        }
    }
}
