//
//  PowerPolicy.swift
//  Conduit
//
//  How often Conduit asks Hermes for things while nobody waits on the
//  answer. Every timed read in the app (the Chats list, the open chat's
//  registry check, Tasks, the socket keepalive) takes its interval from
//  here, so a phone left on the list all day, or an iPad all night, wakes
//  the radio only as often as something is likely to have changed.
//
//  Low Power Mode stretches the polls three times, Low Data Mode or a
//  metered path (cellular, a hotspot) twice. Nothing here shows in the UI.
//

import Foundation
import Network

/// What the device asks of Conduit's background reads right now.
struct DeviceConditions: Equatable, Sendable {
    /// Settings > Battery > Low Power Mode.
    var lowPowerMode = false
    /// Low Data Mode on the current path (`NWPath.isConstrained`).
    var lowDataMode = false
    /// The current path is metered: cellular or a personal hotspot
    /// (`NWPath.isExpensive`).
    var expensivePath = false
    /// The device has a network path a connection can use or bring up
    /// (`NWPath.status` other than `.unsatisfied`: `.requiresConnection`, as
    /// with VPN On Demand, comes up when a connection tries).
    var pathSatisfied = true
    /// Bumped by every path change after the first report (Wi-Fi to
    /// cellular, a VPN coming back): an open socket may have died with the
    /// old path.
    var pathGeneration = 0

    /// How many times longer a poll waits. Low Power Mode wins over Low
    /// Data: the stretches don't multiply, so a poll never waits more than
    /// three times its normal interval.
    var pollStretch: Double {
        if lowPowerMode { return 3 }
        if lowDataMode || expensivePath { return 2 }
        return 1
    }
}

/// Every timed read's interval, in one place.
enum PollCadence {
    /// The Chats list's registry poll: 4 s while something on the list
    /// changes or a turn runs, then longer each time nothing moved.
    static let chatListSteps: [TimeInterval] = [4, 8, 15, 30, 60]
    /// An idle open chat's registry check (another device's turn): 15 s,
    /// then longer while the chat stays the same.
    static let openChatIdleSteps: [TimeInterval] = [15, 30, 60]
    /// Tasks board and task detail while the live event stream is down.
    static let kanbanBoard: TimeInterval = 8
    static let kanbanTaskDetail: TimeInterval = 4
    /// Tasks board and task detail while the live event stream is
    /// connected: the stream says when to read, so the poll is a backstop.
    static let kanbanWhileStreaming: TimeInterval = 60
    /// Quiet time before the chat socket's keepalive ping. Hermes'
    /// dashboard pings the socket itself every 20 s on a non-loopback bind
    /// (uvicorn's ws_ping_interval), and the shortest idle limit between the
    /// two is a proxy's 60 s (nginx's proxy_read_timeout, a load balancer's
    /// default); Cloudflare's is 100 s. One ping every 30 s finds a dead path
    /// while nobody waits on it and keeps a path Hermes doesn't ping (a
    /// loopback bind behind a local proxy) under 60 s.
    static let keepaliveForeground: TimeInterval = 30
    /// Off screen, while audio keeps Conduit running (Read Aloud, a locked
    /// listen, a call, CarPlay): nothing on screen waits on the socket, and
    /// 45 s still stays under a 60 s proxy limit.
    static let keepaliveBackground: TimeInterval = 45
    /// No stretched poll waits longer than this.
    static let longestPoll: TimeInterval = 180
    /// A dropped chat socket's reconnect: exponential from 1 s, capped at
    /// 60 s with full jitter off screen (background audio, a locked
    /// listen)...
    static let reconnectBase: TimeInterval = 1
    static let reconnectCap: TimeInterval = 60
    /// ...and at 8 s while someone looks at Conduit, with the jitter in the
    /// upper half: a gateway restarting while the app is open is noticed
    /// within 8 s, and each step there is a cheap readiness probe first
    /// (GatewayReadinessProbe), not a full reconnect.
    static let reconnectCapOnScreen: TimeInterval = 8
    /// Even the luckiest jitter waits this long, so a gateway that refuses
    /// at once isn't asked in a tight loop.
    static let reconnectFloor: TimeInterval = 0.5

    /// The wait before reconnect attempt `attempt` (0 for the first):
    /// anywhere up to `min(60, 2^attempt)` seconds, so devices that lost the
    /// same gateway spread out instead of returning on one beat. `random` is
    /// in 0..<1.
    static func reconnectDelay(attempt: Int, random: Double, onScreen: Bool = false) -> TimeInterval {
        let cap = onScreen ? reconnectCapOnScreen : reconnectCap
        let ceiling = min(cap, reconnectBase * pow(2, Double(min(max(attempt, 0), 16))))
        let jitter = min(max(random, 0), 1)
        // On screen the wait stays in the step's upper half, so a gateway
        // that is down is probed about every 6 s rather than 4.
        let share = onScreen ? 0.5 + 0.5 * jitter : jitter
        return max(reconnectFloor, ceiling * share)
    }

    /// `interval` under these conditions.
    static func stretched(_ interval: TimeInterval, by conditions: DeviceConditions) -> TimeInterval {
        let stretched = interval * conditions.pollStretch
        return min(stretched, max(interval, longestPoll))
    }

    /// The wait after a failed read: the interval plus up to half of it
    /// again, at random, so devices that lost the same gateway don't all
    /// come back on the same beat. `random` is in 0..<1.
    static func afterFailure(_ interval: TimeInterval, random: Double) -> TimeInterval {
        min(interval * (1 + 0.5 * min(max(random, 0), 1)), max(interval, longestPoll))
    }
}

/// A poll that waits longer each time nothing changed, and goes back to its
/// shortest interval when something does.
struct PollBackoff: Equatable {
    let steps: [TimeInterval]
    private(set) var step = 0

    init(steps: [TimeInterval]) {
        precondition(!steps.isEmpty)
        self.steps = steps
    }

    var interval: TimeInterval { steps[step] }
    var isAtShortest: Bool { step == 0 }

    mutating func reset() { step = 0 }

    mutating func lengthen() {
        step = min(step + 1, steps.count - 1)
    }
}

/// The Chats list's poll: what one tick saw decides the next wait.
struct ChatListPollPacer {
    /// What the registry and the list looked like at one tick.
    struct Observation: Equatable {
        /// Each live row's id, status and message count, or nil when the
        /// registry couldn't be read.
        var registry: Set<String>?
        /// A turn runs on a listed chat, here or elsewhere.
        var turnRunning: Bool
        /// Bumped by every catalog read that changed the list.
        var catalogGeneration: Int
    }

    private(set) var backoff = PollBackoff(steps: PollCadence.chatListSteps)
    private var last: Observation?

    /// Something the user did, a return to the app or a send: back to the
    /// shortest interval, and the next tick compares afresh.
    mutating func reset() {
        backoff.reset()
        last = nil
    }

    /// Records one tick and returns the wait before the next.
    mutating func next(
        after observation: Observation,
        conditions: DeviceConditions,
        random: Double
    ) -> TimeInterval {
        guard let registry = observation.registry else {
            // The last answer stays the one to compare with, so a gateway
            // failing every other read doesn't keep the list quick.
            // A failed read moves nothing: it backs off like a quiet one,
            // with jitter.
            backoff.lengthen()
            return PollCadence.afterFailure(
                PollCadence.stretched(backoff.interval, by: conditions),
                random: random
            )
        }
        let changed = last.map {
            $0.registry != registry || $0.catalogGeneration != observation.catalogGeneration
        } ?? true
        last = observation
        if observation.turnRunning || changed {
            backoff.reset()
        } else {
            backoff.lengthen()
        }
        return PollCadence.stretched(backoff.interval, by: conditions)
    }

    /// The registry rows' part of an observation.
    static func registryKeys(_ rows: [LiveSessionStatus]) -> Set<String> {
        Set(rows.map { "\($0.storedSessionId)|\($0.runtimeSessionId)|\($0.status)|\($0.messageCount ?? -1)" })
    }

    /// Whether a row is a turn in progress. "waiting" (an approval or a
    /// question for the user) can sit for hours, so it backs off like an
    /// idle row; answering it changes the row, which brings the poll back.
    static func isTurnRunning(_ row: LiveSessionStatus) -> Bool {
        row.status == "working" || row.status == "starting"
    }
}

/// A sleep that something can cut short: the Chats list's poll waits up to
/// a minute, and a return to the app or a tap shouldn't wait it out.
@MainActor
final class WakeableSleep {
    private var current: Task<Void, Never>?
    /// A wake that came while nothing slept: the next sleep returns at once.
    private var wokenEarly = false

    /// Whether a sleep is under way (tests wait for it).
    var isSleeping: Bool { current != nil }

    /// Sleeps for `seconds`, or until `wake()` or cancellation.
    func sleep(seconds: TimeInterval) async {
        if wokenEarly {
            wokenEarly = false
            return
        }
        let task = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(seconds)) }
        current = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if current == task { current = nil }
    }

    /// Forgets a wake no sleep took (a new loop starts with its own tick).
    func clearPendingWake() {
        wokenEarly = false
    }

    func wake() {
        guard let current else {
            wokenEarly = true
            return
        }
        current.cancel()
        self.current = nil
    }
}

/// Low Power Mode and the network path (usable, Low Data, metered, changed),
/// for the whole app. One `NWPathMonitor` and one power-state observer,
/// started at launch; readers take `current` when they schedule their next
/// read, and AppState follows path changes to reconnect and to check the
/// chat socket.
@MainActor
final class DeviceConditionsMonitor: ObservableObject {
    static let shared = DeviceConditionsMonitor()

    @Published private(set) var current: DeviceConditions

    private let processInfo: ProcessInfo
    private let notificationCenter: NotificationCenter
    private var powerObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?

    init(processInfo: ProcessInfo = .processInfo, notificationCenter: NotificationCenter = .default) {
        self.processInfo = processInfo
        self.notificationCenter = notificationCenter
        current = DeviceConditions(lowPowerMode: processInfo.isLowPowerModeEnabled)
    }

    deinit {
        if let powerObserver { notificationCenter.removeObserver(powerObserver) }
        pathMonitor?.cancel()
    }

    /// Starts watching; repeated calls do nothing. Tests leave the path
    /// out and set it with `update`.
    func start(watchingPath: Bool = true) {
        guard powerObserver == nil else { return }
        // Any sender: the notice may not come from this ProcessInfo object.
        powerObserver = notificationCenter.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update { $0.lowPowerMode = self.processInfo.isLowPowerModeEnabled }
            }
        }
        update { $0.lowPowerMode = processInfo.isLowPowerModeEnabled }
        guard watchingPath else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            let satisfied = path.status != .unsatisfied
            // Delivered on the main queue, so reports apply in the order the
            // monitor sent them: an older unsatisfied report can't land after
            // a newer satisfied one.
            MainActor.assumeIsolated {
                self?.notePath(constrained: constrained, expensive: expensive, satisfied: satisfied)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// One path report. The monitor reports the current path first; only
    /// the reports after it count as changes.
    func notePath(constrained: Bool, expensive: Bool, satisfied: Bool) {
        let isChange = sawFirstPath
        sawFirstPath = true
        update {
            $0.lowDataMode = constrained
            $0.expensivePath = expensive
            $0.pathSatisfied = satisfied
            if isChange { $0.pathGeneration &+= 1 }
        }
    }

    private var sawFirstPath = false

    /// Publishes only a real change: every publish reaches every reader.
    func update(_ change: (inout DeviceConditions) -> Void) {
        var next = current
        change(&next)
        if next != current { current = next }
    }
}
