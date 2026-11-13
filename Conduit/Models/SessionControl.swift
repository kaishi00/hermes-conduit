//
//  SessionControl.swift
//  Conduit
//
//  A chat's standing goal, loop and heartbeat, as Hermes keeps them
//  (`session.control.read`, `session.control.update`, upstream
//  tui_gateway/methods_session_control.py), and the actions that change
//  them (`session.control`). Setting one stays a slash command (`/goal`,
//  `/loop`, `/heartbeat`, `/subgoal`), which Hermes runs as before.
//

import Combine
import Foundation

struct SessionControlSnapshot: Equatable {
    struct Goal: Equatable {
        var title: String
        /// active, paused or done.
        var status: String
        var turnsUsed: Int
        var maxTurns: Int
        var subgoals: [String]
        var pausedReason: String?
        var lastReason: String?

        var isPaused: Bool { status == "paused" }
        var isDone: Bool { status == "done" }
    }

    struct Loop: Equatable {
        var prompt: String
        /// active or paused; a finished loop isn't kept (`isShown`).
        var status: String
        var intervalSeconds: Double
        var ticksFired: Int
        var maxTicks: Int
        var until: String
        var nextDueAt: Double
        var pausedReason: String?
        var deferredByGoal: Bool

        var isPaused: Bool { status == "paused" }
    }

    struct Heartbeat: Equatable {
        var prompt: String
        /// active or paused.
        var status: String
        var intervalSeconds: Int
        var fireCount: Int

        var isPaused: Bool { status == "paused" }
    }

    var goal: Goal?
    var loop: Loop?
    var heartbeat: Heartbeat?
    /// Hermes' hash of what it shows; equal reads have equal revisions.
    var revision: String

    var isEmpty: Bool { goal == nil && loop == nil && heartbeat == nil }

    /// `{"control": {...}}` or the control object itself. Nil when it
    /// isn't one.
    init?(_ value: AnyCodable?) {
        guard let outer = value?.objectValue else { return nil }
        let control = outer["control"]?.objectValue ?? outer
        guard control.keys.contains("revision") || control.keys.contains("goal")
                || control.keys.contains("loop") || control.keys.contains("heartbeat") else { return nil }
        goal = control["goal"]?.objectValue.flatMap(Self.goal)
        loop = control["loop"]?.objectValue.flatMap(Self.loop)
        heartbeat = control["heartbeat"]?.objectValue.flatMap(Self.heartbeat)
        revision = control["revision"]?.stringValue ?? ""
    }

    init(goal: Goal? = nil, loop: Loop? = nil, heartbeat: Heartbeat? = nil, revision: String = "") {
        self.goal = goal
        self.loop = loop
        self.heartbeat = heartbeat
        self.revision = revision
    }

    private static func text(_ value: AnyCodable?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func goal(_ row: [String: AnyCodable]) -> Goal? {
        let status = row["status"]?.stringValue ?? "active"
        guard let title = text(row["title"]), status != "cleared" else { return nil }
        return Goal(
            title: title,
            status: status,
            turnsUsed: row["turns_used"]?.intValue ?? 0,
            maxTurns: row["max_turns"]?.intValue ?? 0,
            subgoals: (row["subgoals"]?.arrayValue ?? []).compactMap { text($0) },
            pausedReason: text(row["paused_reason"]),
            lastReason: text(row["last_reason"])
        )
    }

    private static func loop(_ row: [String: AnyCodable]) -> Loop? {
        let status = row["status"]?.stringValue ?? "active"
        // A loop that ran its course or was stopped has nothing left to
        // pause or stop.
        guard let prompt = text(row["prompt"]), status == "active" || status == "paused" else { return nil }
        return Loop(
            prompt: prompt,
            status: status,
            intervalSeconds: row["interval_seconds"]?.doubleValue ?? 0,
            ticksFired: row["ticks_fired"]?.intValue ?? 0,
            maxTicks: row["max_ticks"]?.intValue ?? 0,
            until: text(row["until"]) ?? "",
            nextDueAt: row["next_due_at"]?.doubleValue ?? 0,
            pausedReason: text(row["paused_reason"]),
            deferredByGoal: row["deferred_by_goal"]?.boolValue == true
        )
    }

    private static func heartbeat(_ row: [String: AnyCodable]) -> Heartbeat? {
        let status = row["status"]?.stringValue ?? "active"
        guard let prompt = text(row["prompt"]), status == "active" || status == "paused" else { return nil }
        return Heartbeat(
            prompt: prompt,
            status: status,
            intervalSeconds: row["interval_seconds"]?.intValue ?? 0,
            fireCount: row["fire_count"]?.intValue ?? 0
        )
    }

    /// "every 5 min", "every 2 h", "every 30 s": how often a loop or
    /// heartbeat runs.
    static func everyText(seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        // The pinned App Language, not the phone's.
        var calendar = Calendar.current
        calendar.locale = AppLocalization.formattingLocale
        formatter.calendar = calendar
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        let interval = formatter.string(from: max(seconds, 1)) ?? ""
        return AppLocalization.string("every \(interval)", table: .chat)
    }
}

/// `session.control`'s accepted actions (upstream `_ACTION_COMMAND_MAP` and
/// `_MANAGER_ACTIONS`). Gate actions stay Hermes' own.
enum SessionControlAction: Equatable {
    case goalPause, goalResume, goalClear
    case loopPause, loopResume, loopStop
    /// `criterion` is the text the dock showed at `index`: the action is
    /// refused when the list has changed under it.
    case subgoalRemove(index: Int, criterion: String? = nil)
    case subgoalClear
    case heartbeatPause, heartbeatResume, heartbeatClear

    var name: String {
        switch self {
        case .goalPause: return "goal.pause"
        case .goalResume: return "goal.resume"
        case .goalClear: return "goal.clear"
        case .loopPause: return "loop.pause"
        case .loopResume: return "loop.resume"
        case .loopStop: return "loop.stop"
        case .subgoalRemove: return "subgoal.remove"
        case .subgoalClear: return "subgoal.clear"
        case .heartbeatPause: return "heartbeat.pause"
        case .heartbeatResume: return "heartbeat.resume"
        case .heartbeatClear: return "heartbeat.clear"
        }
    }

    /// `args`, 1-based for a subgoal as Hermes counts them.
    var args: [String: Any]? {
        if case .subgoalRemove(let index, _) = self { return ["index": index] }
        return nil
    }

    /// Ending a goal, loop or heartbeat can't be taken back from here, so
    /// the dock asks first.
    var ends: Bool {
        switch self {
        case .goalClear, .loopStop, .heartbeatClear, .subgoalClear: return true
        default: return false
        }
    }
}

/// The open chat's controls, for the dock above the composer. Its own
/// object, so a control changing redraws the dock and not every view of
/// AppState.
final class SessionControlStore: ObservableObject {
    /// The chat they belong to (its runtime id).
    @Published private(set) var sessionID: String?
    @Published private(set) var snapshot = SessionControlSnapshot()
    /// The action on its way: the dock's buttons wait.
    @Published private(set) var working: String?
    /// Hermes' answer or why the last action didn't go, until the next
    /// action or another chat.
    @Published var notice: String?
    /// Counts each word applied or cleared: a read started before a newer
    /// one landed (an event, an action's answer) is dropped.
    private(set) var revision = 0
    /// The action on its way; a clear makes its answer stale.
    private var action = 0

    func apply(_ snapshot: SessionControlSnapshot, for sessionID: String) {
        revision += 1
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            working = nil
            notice = nil
        }
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }

    /// Starts an action; its token says whether its answer is still the
    /// dock's when it comes.
    func begin(_ action: SessionControlAction) -> Int {
        working = action.name
        notice = nil
        self.action += 1
        return self.action
    }

    func isCurrent(_ token: Int) -> Bool { token == action }

    func end(_ token: Int) {
        guard isCurrent(token) else { return }
        working = nil
    }

    /// Another chat opened, the same one opened again, or the connection
    /// changed.
    func clear() {
        action += 1
        revision += 1
        guard sessionID != nil || !snapshot.isEmpty || notice != nil || working != nil else { return }
        sessionID = nil
        snapshot = SessionControlSnapshot()
        working = nil
        notice = nil
    }
}
