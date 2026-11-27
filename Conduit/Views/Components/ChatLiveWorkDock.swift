//
//  ChatLiveWorkDock.swift
//  Conduit
//
//  The open chat's turn running in the gateway, on `hermes dashboard`
//  (Eric, 2026-11-27): an API chat's turn, another app's, one this phone's
//  message waits behind. Above the composer: the bot's mark, what the turn
//  does now ("Working with subagents") and each of its delegate agents
//  with its goal, its own step and how long it has run, so a chat waiting
//  on a subagent doesn't look finished. Read as the chat opens and as its
//  own turn ends, then every 5 s while a turn runs there or a message of
//  the chat waits in the gateway's queue; the same reads fill the queue
//  dock below it. A turn this phone runs itself shows its own progress, so
//  the line hides then.
//

import SwiftUI

struct ChatLiveWorkDock: View {
    let appState: AppState
    /// The queue dock's rows: a message forwarded behind a turn starts the reads.
    @ObservedObject var queue: AuthorityQueueStore
    /// The open chat: another starts with nothing.
    let openChatID: String?
    /// This phone runs the chat's turn and draws it itself.
    let isBusy: Bool
    /// The chat shows (the app is active, the tab and the chat on screen).
    let isShowing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var work: ChatLiveWork?

    private var shows: Bool { work?.running == true && !isBusy && isShowing }
    /// A message of the chat waits in the gateway's queue.
    private var waits: Bool { queue.readOnly && !queue.isEmpty }

    var body: some View {
        Group {
            if shows, let work {
                card(work).transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 12)
        .padding(.bottom, shows ? 6 : 0)
        .animation(ConduitMotion.ease(reduceMotion: reduceMotion), value: work)
        .onChange(of: openChatID) { work = nil }
        .task(id: "\(openChatID ?? "")|\(isBusy)|\(isShowing)|\(waits)") {
            guard let chatID = openChatID, isShowing else { return }
            repeat {
                let previous = work
                let answer = await appState.loadOpenChatLiveWork()
                guard !Task.isCancelled, openChatID == chatID else { return }
                if let answer {
                    work = answer
                    appState.applyChatLiveWork(answer, previous: previous, for: chatID)
                }
                // A failed read (a blip, the plugin restarting) tries again while
                // the last one still had something to follow, as the Kanban dock does.
                guard work?.isActive == true || waits else { return }
                try? await Task.sleep(for: ChatLiveWork.refreshInterval)
            } while !Task.isCancelled
        }
    }

    private func card(_ work: ChatLiveWork) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(verbatim: work.step?.title ?? AppLocalization.string("Working"))
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !work.agents.isEmpty {
                    Text(AppLocalization.string("\(work.agents.count) subagents working", table: .chat))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // One clock for every row's run time, counting up each second.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(work.agents.prefix(3)) { agent in
                        agentRow(agent, at: context.date)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .conduitGlassControl(cornerRadius: 20, interactive: false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func agentRow(_ agent: ChatLiveWork.Agent, at now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.2")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: agent.goal.isEmpty ? AppLocalization.string("Delegate agent", table: .chat) : agent.goal)
                    .scaledFont(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                // Its step, and how long it has run.
                Text(verbatim: subtitle(agent, at: now))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func subtitle(_ agent: ChatLiveWork.Agent, at now: Date) -> String {
        guard let started = agent.started else { return agent.step.title }
        let seconds = max(0, now.timeIntervalSince1970 - started)
        return [agent.step.title, ChatStepTiming.text(seconds)].compactMap { $0 }.joined(separator: " · ")
    }
}
