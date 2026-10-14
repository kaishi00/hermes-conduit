import ActivityKit
import Foundation
import os

private let liveActivityLog = Logger(subsystem: "com.milim.relay", category: "LiveActivity")

/// How a chat's stream events move a running turn's Lock Screen state
/// (#605). Pure, so the mapping is tested without ActivityKit.
enum LiveTurnProgress {
    /// The next state after `event`, or nil when the event changes nothing
    /// the activity shows.
    static func applying(
        _ event: StreamEvent,
        to state: HermesTurnAttributes.ContentState,
        now: Date = Date()
    ) -> HermesTurnAttributes.ContentState? {
        var next = state
        switch event {
        case .messageStart, .reasoningDelta:
            next.phase = HermesTurnPhase.thinking.rawValue
            next.tool = nil
        case .messageDelta:
            next.phase = HermesTurnPhase.writing.rawValue
            next.tool = nil
        case .toolStart(_, let name, _, _):
            if name.lowercased() == "clarify" {
                next.phase = HermesTurnPhase.input.rawValue
                next.tool = nil
            } else {
                next.phase = HermesTurnPhase.tool.rawValue
                next.tool = HermesToolCategory(toolName: name).rawValue
                next.tools += 1
            }
        case .toolComplete:
            next.phase = HermesTurnPhase.thinking.rawValue
            next.tool = nil
        case .approval:
            next.phase = HermesTurnPhase.approval.rawValue
            next.tool = nil
        case .clarify, .inputPrompt:
            next.phase = HermesTurnPhase.input.rawValue
            next.tool = nil
        case .approvalWithdrawn, .clarifyExpire, .inputPromptExpire:
            guard state.turnPhase.waitsOnUser else { return nil }
            next.phase = HermesTurnPhase.thinking.rawValue
        case .contextUpdate(_, let percent, _, _):
            guard percent.isFinite else { return nil }
            next.context = max(0, min(100, Int(percent.rounded())))
        case .messageComplete:
            return finished(state, .done, now: now)
        case .messageError:
            return finished(state, .failed, now: now)
        case .messageInterrupted:
            return finished(state, .stopped, now: now)
        case .sessionBusy(_, let busy):
            guard !busy else { return nil }
            return finished(state, .done, now: now)
        case .sessionInfo(_, let snapshot):
            guard snapshot.running == false else { return nil }
            return finished(state, .done, now: now)
        default:
            return nil
        }
        return next == state ? nil : next
    }

    static func finished(
        _ state: HermesTurnAttributes.ContentState,
        _ phase: HermesTurnPhase,
        now: Date
    ) -> HermesTurnAttributes.ContentState {
        var next = state
        next.phase = phase.rawValue
        next.tool = nil
        next.endedAt = now.timeIntervalSince1970
        return next
    }
}

/// The Live Activities of turns Conduit sent (#605): started when a prompt
/// is accepted, updated from the chat's stream while Conduit runs, and kept
/// current by the notifier plugin through the relay once Conduit is in the
/// background (the activity's push token is registered there under the
/// chat's ids).
@MainActor
final class LiveTurnActivities {
    static let shared = LiveTurnActivities()
    /// Settings > Notifications "Progress on the Lock Screen"; on unless
    /// turned off.
    nonisolated static let enabledDefaultsKey = "conduit.liveActivities.enabled"
    /// An activity nobody updated for this long reads as out of date.
    static let staleAfter: TimeInterval = 15 * 60
    /// A finished turn stays on the Lock Screen this long.
    static let dismissAfterEnd: TimeInterval = 5 * 60

    private struct Running {
        let activity: Activity<HermesTurnAttributes>
        let sessionIDs: Set<String>
        var state: HermesTurnAttributes.ContentState
        var pushToken: String?
        var tokenTask: Task<Void, Never>?
    }

    /// How long after a turn starts an idle `session.busy` / `session.info`
    /// is not taken as its end.
    static let idleSignalGrace: TimeInterval = 5

    private var running: [String: Running] = [:]
    private var adopted = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// A prompt Conduit sent was accepted: the turn gets an activity, and an
    /// older one for the same chat ends.
    func turnStarted(sessionIDs: Set<String>, primaryID: String, title: String, profile: String?) {
        adoptExisting()
        guard Self.isEnabled, !sessionIDs.isEmpty, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for id in matching(sessionIDs) {
            finish(id, phase: .stopped, dismissal: .immediate)
        }
        let attributes = HermesTurnAttributes(
            chatTitle: title,
            startedAt: Date(),
            language: AppLanguageStore.shared.selection.rawValue,
            link: ConduitAppLink.session(id: primaryID, profile: profile).url,
            sessionIDs: Array(sessionIDs).sorted()
        )
        let state = HermesTurnAttributes.ContentState(phase: .thinking)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)),
                pushType: .token
            )
            track(activity, state: state)
        } catch {
            liveActivityLog.notice("Live Activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A stream event of the active chat.
    func observe(_ event: StreamEvent, sessionID: String) {
        guard !running.isEmpty, !sessionID.isEmpty else { return }
        for id in matching([sessionID]) {
            guard let entry = running[id] else { continue }
            // An idle snapshot read just as the prompt went out can predate
            // the turn it carries.
            if Self.isIdleSignal(event),
               Date().timeIntervalSince(entry.activity.attributes.startedAt) < Self.idleSignalGrace {
                continue
            }
            guard let next = LiveTurnProgress.applying(event, to: entry.state) else { continue }
            if next.turnPhase.isFinished {
                running[id]?.state = next
                finish(id, phase: next.turnPhase, dismissal: .after(Date().addingTimeInterval(Self.dismissAfterEnd)))
            } else {
                running[id]?.state = next
                let content = ActivityContent(state: next, staleDate: Date().addingTimeInterval(Self.staleAfter))
                Task { await entry.activity.update(content) }
            }
        }
    }

    /// Lock Screen progress was turned off: every activity goes.
    func endAll() {
        adoptExisting()
        for id in Array(running.keys) {
            finish(id, phase: .stopped, dismissal: .immediate)
        }
        for activity in Activity<HermesTurnAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Activities a previous run of Conduit started are taken over, so the
    /// stream can still update and end them.
    func adoptExisting() {
        guard !adopted else { return }
        adopted = true
        for activity in Activity<HermesTurnAttributes>.activities where running[activity.id] == nil {
            guard activity.activityState == .active || activity.activityState == .stale else { continue }
            track(activity, state: activity.content.state)
        }
    }

    // MARK: - Internals

    private static func isIdleSignal(_ event: StreamEvent) -> Bool {
        switch event {
        case .sessionBusy, .sessionInfo: true
        default: false
        }
    }

    private func matching(_ sessionIDs: Set<String>) -> [String] {
        running.filter { !$0.value.sessionIDs.isDisjoint(with: sessionIDs) }.map { $0.key }
    }

    private func track(_ activity: Activity<HermesTurnAttributes>, state: HermesTurnAttributes.ContentState) {
        let id = activity.id
        let sessionIDs = Set(activity.attributes.sessionIDs)
        let tokenTask = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await self?.register(token: token, for: id, sessionIDs: sessionIDs)
            }
        }
        running[id] = Running(activity: activity, sessionIDs: sessionIDs, state: state, tokenTask: tokenTask)
    }

    private func register(token: String, for id: String, sessionIDs: Set<String>) async {
        guard running[id] != nil else { return }
        let previous = running[id]?.pushToken
        running[id]?.pushToken = token
        if let previous, previous != token {
            await PushNotificationService.shared.unregisterLiveActivity(token: previous)
        }
        await PushNotificationService.shared.registerLiveActivity(token: token, sessionIDs: Array(sessionIDs).sorted())
    }

    private func finish(_ id: String, phase: HermesTurnPhase, dismissal: ActivityUIDismissalPolicy) {
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.tokenTask?.cancel()
        let lastState = entry.state.turnPhase.isFinished
            ? entry.state
            : LiveTurnProgress.finished(entry.state, phase, now: Date())
        Task {
            await entry.activity.end(ActivityContent(state: lastState, staleDate: nil), dismissalPolicy: dismissal)
            if let token = entry.pushToken {
                await PushNotificationService.shared.unregisterLiveActivity(token: token)
            }
        }
    }
}
