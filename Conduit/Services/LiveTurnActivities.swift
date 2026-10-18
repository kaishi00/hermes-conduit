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
            if name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "clarify" {
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
            // Clamped as a Double: Int() traps on a huge value.
            next.context = Int(max(0, min(100, percent.rounded())))
        case .messageComplete:
            return finished(state, .done, now: now)
        case .messageError:
            return finished(state, .failed, now: now)
        case .messageInterrupted:
            return finished(state, .stopped, now: now)
        case .sessionBusy(_, let busy):
            // An approval or answer still pending outlasts an idle report.
            guard !busy, !state.turnPhase.waitsOnUser else { return nil }
            return finished(state, .done, now: now)
        case .sessionInfo(_, let snapshot):
            guard snapshot.running == false, !state.turnPhase.waitsOnUser else { return nil }
            return finished(state, .done, now: now)
        default:
            return nil
        }
        return next == state ? nil : next
    }

    /// The held events that belong to the new turn: those from its
    /// `messageStart` on. Without one, they're the tail of the turn before.
    static func newTurnEvents(_ events: [StreamEvent]) -> [StreamEvent] {
        guard let start = events.lastIndex(where: { event in
            if case .messageStart = event { return true }
            return false
        }) else { return [] }
        return Array(events[start...])
    }

    /// What one live-registry snapshot says about a running turn.
    enum RegistryVerdict: Equatable {
        /// One of the chat's ids is still working, waiting or starting.
        case running
        /// None of them is: the turn may be over.
        case absent
        /// The snapshot says nothing about it: another dashboard or
        /// profile, a turn already ended, or one too new to be in it.
        case unknown
    }

    /// What the gateway's live registry (`session.active_list`) says about
    /// a running turn: whether any of the chat's ids is among the sessions
    /// still working, waiting on the user or starting. Only the snapshot's
    /// own dashboard and profile count (an activity that names neither is
    /// from an older build, and goes by its chat ids), and an absence within
    /// `grace` of the turn's start counts for nothing: a snapshot read just
    /// before the prompt landed can miss it.
    static func registryVerdict(
        attributes: HermesTurnAttributes,
        state: HermesTurnAttributes.ContentState,
        liveSessionIDs: Set<String>,
        profile: String,
        dashboardID: String?,
        now: Date,
        grace: TimeInterval
    ) -> RegistryVerdict {
        guard !state.turnPhase.isFinished else { return .unknown }
        if let own = attributes.dashboardID, own != dashboardID { return .unknown }
        if case .session(_, let own?)? = ConduitAppLink(url: attributes.link), own != profile { return .unknown }
        guard Set(attributes.sessionIDs).isDisjoint(with: liveSessionIDs) else { return .running }
        return now.timeIntervalSince(attributes.startedAt) >= grace ? .absent : .unknown
    }

    /// Absences of running turns' chats from the live registry. One is not
    /// enough to end a turn: a gateway restarting or reloading can serve an
    /// empty or partial registry for a moment. A turn is over once its chat
    /// stays absent from one snapshot to another at least `span` later,
    /// with no snapshot in between that runs it (a burst of reads at the
    /// same moment counts once). An absence older than `staleSpans` spans
    /// (Conduit was away, or on another profile) starts over: the turn
    /// could have run unseen since.
    struct RegistryAbsences {
        /// When each activity's chat was first seen absent, by activity id.
        private var since: [String: Date] = [:]
        static let staleSpans: Double = 4

        /// Where a turn stands after one snapshot.
        enum Outcome: Equatable {
            /// Nothing to do.
            case none
            /// Its chat was just seen absent for the first time: a snapshot
            /// `span` from now settles it.
            case started
            /// Its chat has stayed absent: the turn is over.
            case over
        }

        /// Records `verdict` for activity `id`.
        mutating func record(_ verdict: RegistryVerdict, for id: String, at now: Date, span: TimeInterval) -> Outcome {
            switch verdict {
            case .unknown:
                return .none
            case .running:
                since[id] = nil
                return .none
            case .absent:
                guard let first = since[id], now.timeIntervalSince(first) <= span * Self.staleSpans else {
                    since[id] = now
                    return .started
                }
                return now.timeIntervalSince(first) >= span ? .over : .none
            }
        }

        /// The activity ended: its absence goes with it.
        mutating func forget(_ id: String) {
            since[id] = nil
        }
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
        /// The relay installation that took `pushToken`, through which the
        /// Conduit plugin can update and end the activity by push. It only
        /// counts while it is still this iPhone's installation: turning
        /// notifications off or moving relays drops it.
        var tokenInstallationID: String?
        var tokenTask: Task<Void, Never>?
        var stateTask: Task<Void, Never>?
        /// The last update handed to ActivityKit; each waits for the one
        /// before it, so a burst of events lands in order.
        var updateTask: Task<Void, Never>?
    }

    /// How long after a turn starts an idle `session.busy` / `session.info`
    /// is not taken as its end.
    static let idleSignalGrace: TimeInterval = 5
    /// How long after a turn starts the live registry's word that its chat
    /// isn't running is not taken as its end.
    nonisolated static let registryGrace: TimeInterval = 30
    /// How long a chat must stay out of the live registry before its turn
    /// is taken as over: two of the chat list's 4-second poll intervals, so
    /// the third absent snapshot in a row ends it.
    nonisolated static let registryAbsenceSpan: TimeInterval = 8

    private var running: [String: Running] = [:]
    private var registryAbsences = LiveTurnProgress.RegistryAbsences()
    private var adopted = false
    /// Stream events of chats whose prompt is still being submitted: the
    /// gateway can stream before prompt.submit answers, and those events
    /// belong to the activity that starts once it does.
    /// One entry per chat, so submissions to two chats don't clobber each
    /// other.
    private var early: [(sessionIDs: Set<String>, events: [StreamEvent])] = []
    /// Past this, the oldest held events go first.
    private static let earlyLimit = 64
    /// Chats whose submission was never accepted are dropped oldest first.
    private static let earlyChatLimit = 4

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// A prompt is about to be submitted: its chat's events are held until
    /// `turnStarted` (or dropped by the chat's next submission).
    func turnSubmitting(sessionIDs: Set<String>) {
        early.removeAll { !$0.sessionIDs.isDisjoint(with: sessionIDs) }
        guard Self.isEnabled, !sessionIDs.isEmpty else { return }
        if early.count >= Self.earlyChatLimit {
            early.removeFirst()
        }
        early.append((sessionIDs, []))
    }

    /// A prompt Conduit sent was accepted: the turn gets an activity, and an
    /// older one for the same chat ends.
    func turnStarted(sessionIDs: Set<String>, primaryID: String, title: String, profile: String?, profileName: String? = nil, glowHex: String? = nil, dashboardID: String? = nil) {
        adoptExisting()
        let held = early.first { !$0.sessionIDs.isDisjoint(with: sessionIDs) }
            .map { LiveTurnProgress.newTurnEvents($0.events) } ?? []
        early.removeAll { !$0.sessionIDs.isDisjoint(with: sessionIDs) }
        guard Self.isEnabled, !sessionIDs.isEmpty, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for id in matching(sessionIDs) {
            finish(id, phase: .stopped, dismissal: .immediate)
        }
        let attributes = HermesTurnAttributes(
            chatTitle: title,
            startedAt: Date(),
            language: AppLanguageStore.shared.selection.rawValue,
            link: ConduitAppLink.session(id: primaryID, profile: profile).url,
            sessionIDs: Array(sessionIDs).sorted(),
            profileName: profileName,
            glowHex: glowHex,
            dashboardID: dashboardID
        )
        let state = HermesTurnAttributes.ContentState(phase: .thinking)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)),
                pushType: .token
            )
            track(activity, state: state)
            // What streamed while the prompt was being submitted.
            let primary = sessionIDs.contains(primaryID) ? primaryID : sessionIDs.sorted()[0]
            for event in held {
                observe(event, sessionID: primary)
            }
        } catch {
            liveActivityLog.notice("Live Activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A stream event of the active chat.
    func observe(_ event: StreamEvent, sessionID: String) {
        guard !sessionID.isEmpty else { return }
        if let index = early.firstIndex(where: { $0.sessionIDs.contains(sessionID) }) {
            if early[index].events.count >= Self.earlyLimit {
                early[index].events.removeFirst()
            }
            early[index].events.append(event)
        }
        guard !running.isEmpty else { return }
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
                // Its stream is live: an absence from the registry (an id
                // that rotated mid-turn) is moot.
                registryAbsences.forget(id)
                let content = ActivityContent(state: next, staleDate: Date().addingTimeInterval(Self.staleAfter))
                let previous = entry.updateTask
                running[id]?.updateTask = Task {
                    await previous?.value
                    guard !Task.isCancelled else { return }
                    await entry.activity.update(content)
                }
            }
        }
    }

    /// A full `session.active_list` snapshot of `profile` on `dashboardID`:
    /// a turn whose chat is no longer running there ended without Conduit
    /// seeing it (it finished while Conduit was closed, or in a chat not on
    /// screen, with no relay to end it), so its activity ends as done
    /// instead of counting up for hours, once its chat has stayed out of
    /// the registry for `registryAbsenceSpan` (`RegistryAbsences`).
    /// `liveSessionIDs` are the ids of the rows still working, waiting or
    /// starting. True when a chat was just seen absent for the first time,
    /// so another snapshot `registryAbsenceSpan` from now is needed to
    /// settle it.
    @discardableResult
    func reconcile(liveSessionIDs: Set<String>, profile: String, dashboardID: String?, now: Date = Date()) -> Bool {
        guard !running.isEmpty else { return false }
        var over: [String] = []
        var confirmationNeeded = false
        for (id, entry) in running {
            let verdict = LiveTurnProgress.registryVerdict(
                attributes: entry.activity.attributes,
                state: entry.state,
                liveSessionIDs: liveSessionIDs,
                profile: profile,
                dashboardID: dashboardID,
                now: now,
                grace: Self.registryGrace
            )
            switch registryAbsences.record(verdict, for: id, at: now, span: Self.registryAbsenceSpan) {
            case .none: break
            case .started: confirmationNeeded = true
            case .over: over.append(id)
            }
        }
        // Ended only after the walk: finish removes from `running`.
        for id in over {
            // When it ended is unknown: no time shows rather than a wrong one.
            finish(id, phase: .done, dismissal: .after(now.addingTimeInterval(Self.dismissAfterEnd)), endKnown: false)
        }
        return confirmationNeeded
    }

    /// Conduit stops following `dashboardID`'s turns (its sign-in expired
    /// with no push route to end them, or the user disconnected or signed
    /// out): their activities go now rather than counting up on a turn
    /// nothing will end. `keepingThoseOnRelay` keeps the ones whose push
    /// token this iPhone's current relay installation took, which the
    /// Conduit plugin still ends by push (`endsTurn`).
    func endTurns(ofDashboard dashboardID: String?, keepingThoseOnRelay: Bool = false) {
        adoptExisting()
        let installationID = PushNotificationService.shared.installationID
        let ending = running.filter { _, entry in
            Self.endsTurn(
                activityDashboardID: entry.activity.attributes.dashboardID,
                tokenInstallationID: entry.tokenInstallationID,
                ofDashboard: dashboardID,
                keepingThoseOnRelay: keepingThoseOnRelay,
                currentInstallationID: installationID
            )
        }.map(\.key)
        for id in ending {
            finish(id, phase: .stopped, dismissal: .immediate)
        }
    }

    /// Whether `endTurns(ofDashboard:)` ends an activity. Another
    /// dashboard's activities stay, except one started by a build before
    /// `dashboardID`: naming no dashboard, it ends whichever dashboard this
    /// is. That only holds through the upgrade, until the system has ended
    /// those older activities. With `keepingThoseOnRelay`, one whose token
    /// the relay installation still in use took stays too.
    nonisolated static func endsTurn(
        activityDashboardID: String?,
        tokenInstallationID: String?,
        ofDashboard dashboardID: String?,
        keepingThoseOnRelay: Bool,
        currentInstallationID: String?
    ) -> Bool {
        if let own = activityDashboardID, own != dashboardID { return false }
        if keepingThoseOnRelay, let tokenInstallationID, tokenInstallationID == currentInstallationID { return false }
        return true
    }

    /// Lock Screen progress was turned off: every activity goes.
    func endAll() {
        adoptExisting()
        let tracked = Set(running.keys)
        for id in tracked {
            finish(id, phase: .stopped, dismissal: .immediate)
        }
        for activity in Activity<HermesTurnAttributes>.activities where !tracked.contains(activity.id) {
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
            // Left behind by a run that ended before the setting was
            // turned off: it goes instead of being kept up to date.
            guard Self.isEnabled else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            // Finished, but Conduit stopped before ending it.
            if activity.content.state.turnPhase.isFinished {
                let content = ActivityContent(state: activity.content.state, staleDate: nil)
                // Gone 5 minutes after the turn ended, like any other finish
                // (its start stands in for an unknown end).
                let ended = activity.content.state.endDate ?? activity.attributes.startedAt
                let dismissal = ActivityUIDismissalPolicy.after(ended.addingTimeInterval(Self.dismissAfterEnd))
                Task { await activity.end(content, dismissalPolicy: dismissal) }
                continue
            }
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
        // Ended or dismissed outside Conduit (swiped away, the system's
        // 8 hours, a push from the relay): stop tracking it and let the
        // relay forget its token.
        let stateTask = Task { [weak self] in
            for await activityState in activity.activityStateUpdates {
                if activityState == .ended || activityState == .dismissed {
                    await self?.forget(id)
                    return
                }
            }
        }
        running[id] = Running(activity: activity, sessionIDs: sessionIDs, state: state, tokenTask: tokenTask, stateTask: stateTask)
    }

    private func forget(_ id: String) async {
        registryAbsences.forget(id)
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.tokenTask?.cancel()
        entry.stateTask?.cancel()
        entry.updateTask?.cancel()
        if let token = entry.pushToken {
            await PushNotificationService.shared.unregisterLiveActivity(token: token)
        }
    }

    private func register(token: String, for id: String, sessionIDs: Set<String>) async {
        guard running[id] != nil else { return }
        let previous = running[id]?.pushToken
        running[id]?.pushToken = token
        if previous != token { running[id]?.tokenInstallationID = nil }
        if let previous, previous != token {
            await PushNotificationService.shared.unregisterLiveActivity(token: previous)
        }
        let installationID = await PushNotificationService.shared.registerLiveActivity(token: token, sessionIDs: Array(sessionIDs).sorted())
        // Unless a newer token replaced it meanwhile.
        if running[id]?.pushToken == token { running[id]?.tokenInstallationID = installationID }
    }

    private func finish(_ id: String, phase: HermesTurnPhase, dismissal: ActivityUIDismissalPolicy, endKnown: Bool = true) {
        registryAbsences.forget(id)
        guard let entry = running.removeValue(forKey: id) else { return }
        entry.tokenTask?.cancel()
        entry.stateTask?.cancel()
        var lastState = entry.state.turnPhase.isFinished
            ? entry.state
            : LiveTurnProgress.finished(entry.state, phase, now: Date())
        if !endKnown, !entry.state.turnPhase.isFinished { lastState.endedAt = nil }
        let pendingUpdate = entry.updateTask
        Task {
            await pendingUpdate?.value
            await entry.activity.end(ActivityContent(state: lastState, staleDate: nil), dismissalPolicy: dismissal)
            if let token = entry.pushToken {
                await PushNotificationService.shared.unregisterLiveActivity(token: token)
            }
        }
    }
}
