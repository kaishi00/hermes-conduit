//
//  ChatCardsModel.swift
//  Conduit
//
//  The open chat's plan, docked above the composer (docs/PLAN_CARD.md): a
//  slim line that opens upward into the whole card. Its own observable, so
//  the plan changing redraws the dock and nothing else in the chat.
//

import Combine
import Foundation

/// The chat the cards are for: a profile and every id it is known by, so a
/// runtime id rotating under it isn't another chat.
struct ChatCardsChat: Equatable {
    let profile: String
    let ids: Set<String>

    init?(profile: String, ids: [String?]) {
        let ids = Set(ids.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return nil }
        self.profile = profile
        self.ids = ids
    }

    func isSameChat(as other: ChatCardsChat) -> Bool {
        profile == other.profile && !ids.isDisjoint(with: other.ids)
    }
}

@MainActor
final class ChatCardsModel: ObservableObject {
    static let pinsPlanKey = "chatCards.pinsPlan"
    /// A finished plan stays this long, then goes: its line and, unless the
    /// user is reading it, its card.
    static let finishedPlanDelay: Duration = .seconds(60)
    /// A row stamped this long before the chat opened is still live news
    /// (the host's clock and the phone's needn't agree to the second).
    static let clockSlack: TimeInterval = 5

    @Published private(set) var plan: AgentPlan?
    @Published private(set) var planExpanded = false
    /// A finished plan whose time is up: nothing shows, though `plan` is
    /// kept, so more work on it brings it back.
    @Published private(set) var planRetired = false
    /// Goes up when a new plan arrives while the chat is open, so the line
    /// can announce it (a pop and a pulse) without opening over the chat.
    @Published private(set) var announcement = 0
    @Published private(set) var pinsPlan: Bool

    private let defaults: UserDefaults
    private let finishedPlanDelay: Duration
    private let now: () -> Date

    private var chat: ChatCardsChat?
    private var openedAt = Date.distantPast
    /// `todo_state` from the chat's resume, by chat.
    private var serverPlan: AgentPlan?
    /// The newest plan the transcript has shown (an empty one included);
    /// it outranks the resume snapshot once the transcript has had one.
    private var transcriptPlan: AgentPlan?
    /// The transcript row the shown plan ends at; nil for the server's.
    private var planRowID: String?
    private var planTimer: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        finishedPlanDelay: Duration = ChatCardsModel.finishedPlanDelay,
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.finishedPlanDelay = finishedPlanDelay
        self.now = now
        pinsPlan = defaults.bool(forKey: Self.pinsPlanKey)
    }

    // MARK: - Inputs

    /// The open chat changed, or a reconnect learned another id for it.
    func show(_ chat: ChatCardsChat?) {
        if let chat, let current = self.chat, chat.isSameChat(as: current) {
            self.chat = ChatCardsChat(profile: chat.profile, ids: Array(chat.ids.union(current.ids)))
            return
        }
        self.chat = chat
        openedAt = now()
        serverPlan = nil
        transcriptPlan = nil
        planRowID = nil
        planTimer?.cancel()
        plan = nil
        planExpanded = false
        planRetired = false
    }

    /// `todo_state` from `session.resume`. A plan the loaded transcript
    /// shows is the newest one (the page is the history's tail), so this
    /// only stands when it shows none.
    func applyServerPlan(_ snapshot: AgentPlan?, for chat: ChatCardsChat?) {
        // The resume can land before the chat screen has said which chat
        // is open; it is always the open chat's.
        show(chat)
        guard self.chat != nil else { return }
        serverPlan = snapshot?.isEmpty == false ? snapshot : nil
        // The plan the transcript showed outranks the snapshot, even once its
        // rows have left the loaded page: a resume may carry no `todo_state`
        // (before Hermes 0.21) or an older one.
        guard planRowID == nil else { return }
        present(transcriptPlan ?? serverPlan, rowTimestamp: nil)
    }

    /// The transcript on screen changed.
    func transcriptChanged(_ messages: [ChatMessage], for chat: ChatCardsChat?) {
        show(chat)
        guard self.chat != nil else { return }
        updatePlan(from: messages)
    }

    // MARK: - User actions

    func setPlanExpanded(_ expanded: Bool) {
        guard plan != nil else { return }
        if !expanded, pinsPlan { setPinsPlan(false) }
        planTimer?.cancel()
        planExpanded = expanded
        // Opening or folding a finished plan starts its time again.
        if plan?.isFinished == true { scheduleFinishedPlanRetire() }
    }

    /// Whether the dock shows the plan at all.
    var showsPlan: Bool { plan != nil && !planRetired }

    func setPinsPlan(_ pinned: Bool) {
        pinsPlan = pinned
        defaults.set(pinned, forKey: Self.pinsPlanKey)
        if pinned {
            planTimer?.cancel()
            planRetired = false
            if plan != nil { planExpanded = true }
        } else if let plan, plan.isFinished {
            scheduleFinishedPlanRetire()
        }
    }

    // MARK: - Plan

    private func updatePlan(from messages: [ChatMessage]) {
        guard let latest = AgentPlanTranscript.latest(in: messages) else {
            // The rows that held it went (a backfill reset, a reload): the
            // last plan they showed stands, else the resume snapshot.
            if planRowID != nil {
                planRowID = nil
                present(transcriptPlan ?? serverPlan, rowTimestamp: nil)
            }
            return
        }
        transcriptPlan = latest.plan
        guard latest.messageID != planRowID || latest.plan != plan else { return }
        planRowID = latest.messageID
        present(latest.plan, rowTimestamp: latest.timestamp)
    }

    /// `rowTimestamp` nil: read when the chat opened, not news.
    private func present(_ next: AgentPlan?, rowTimestamp: String?) {
        let previous = plan
        guard next != previous else { return }
        guard let next, !next.isEmpty else {
            planTimer?.cancel()
            plan = nil
            planExpanded = false
            planRetired = false
            return
        }
        let live = rowTimestamp.map(isLive) ?? false
        plan = next
        if !next.isFinished { planRetired = false }
        if pinsPlan {
            planRetired = false
            planExpanded = true
            return
        }
        let isNew = previous == nil || next.isNewPlan(comparedTo: previous)
        guard live else {
            // Opening the chat: the line, folded; nothing announces. A plan
            // that finished before the chat opened has had its time.
            if isNew { planTimer?.cancel(); planExpanded = false }
            if next.isFinished { planTimer?.cancel(); planExpanded = false; planRetired = true }
            return
        }
        let reopened = previous?.isFinished == true && !next.isFinished
        if isNew || reopened { announcement &+= 1 }
        if next.isFinished {
            if previous?.isFinished != true { scheduleFinishedPlanRetire() }
        } else {
            planTimer?.cancel()
        }
    }

    /// A finished plan goes after a while: the line and its card.
    private func scheduleFinishedPlanRetire() {
        planTimer?.cancel()
        guard !pinsPlan else { return }
        let delay = finishedPlanDelay
        planTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.pinsPlan, self.plan?.isFinished == true else { return }
            self.planExpanded = false
            self.planRetired = true
        }
    }

    /// Whether a row came in while the chat was open, rather than with it.
    private func isLive(_ timestamp: String) -> Bool {
        guard let date = MessageTimestampFormatter.date(from: timestamp) else { return false }
        return date.timeIntervalSince(openedAt) >= -Self.clockSlack
    }
}
