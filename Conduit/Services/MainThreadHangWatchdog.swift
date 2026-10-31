import Foundation
import os
import UIKit

/// Notices when the main thread stops coming back to its run loop for 2 s
/// and saves the chat recorder's lines from just before as a stall trace
/// (ChatTraceStore), in every build: only the moments before a freeze say
/// what set it off, as in the Mac transcript freeze, where SwiftUI's lazy
/// stack loops with no app code in the stack (#1539). MetricKit's report of
/// the same freeze, offered on the next launch, carries that trace, and
/// when the main thread comes back the trace says how long it was away.
///
/// A timer on the main run loop beats every half second; a timer on a queue
/// of its own checks the beat (StallClock). Both stop while the app is in
/// the background, and a check that finds its own last check late (the app
/// was suspended) starts over rather than call that a stall. A stall saves a
/// trace at most once a minute, as the transcript's watchers do. Off in unit
/// tests, which hold the main thread on purpose.
final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

    private let lock = NSLock()
    private var clock = StallClock()
    /// The reported stall's saved trace.
    private var stallTrace: String?
    // Started and stopped on the main thread.
    private var beatTimer: Timer?
    private var checkTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "com.milim.relay.hang-watchdog", qos: .utility)
    private let logger = Logger(subsystem: "com.milim.relay", category: "hang")

    @MainActor
    func start() {
        guard observers.isEmpty,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.stopTimers()
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.startTimers()
            },
        ]
        startTimers()
        logger.notice("Hang watchdog running (threshold \(StallClock.threshold, privacy: .public) s)")
    }

    /// On the main thread.
    private func startTimers() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        clock.start(at: now)
        lock.unlock()
        guard beatTimer == nil else { return }
        let beat = Timer(timeInterval: StallClock.interval, repeats: true) { [weak self] _ in self?.beat() }
        RunLoop.main.add(beat, forMode: .common)
        beatTimer = beat
        let check = DispatchSource.makeTimerSource(queue: queue)
        check.schedule(deadline: .now() + StallClock.interval, repeating: StallClock.interval)
        check.setEventHandler { [weak self] in self?.check() }
        check.resume()
        checkTimer = check
    }

    /// On the main thread.
    private func stopTimers() {
        beatTimer?.invalidate()
        beatTimer = nil
        checkTimer?.cancel()
        checkTimer = nil
    }

    private func beat() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let lasted = clock.beat(at: now)
        lock.unlock()
        guard let lasted else { return }
        let line = String(format: "stall ended: main thread back after %.1f s", lasted)
        ChatViewportTrace.shared.log(line)
        logger.fault("\(line, privacy: .public)")
        // On the check's queue, after the trace it saved.
        queue.async { [self] in
            lock.lock()
            let trace = stallTrace
            stallTrace = nil
            lock.unlock()
            if let trace { ChatTraceStore().append(line, to: trace) }
        }
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        // A stall before any chat was drawn has nothing to say about one.
        let recorded = !ChatViewportTrace.shared.isEmpty
        lock.lock()
        guard let away = clock.check(at: now) else {
            lock.unlock()
            return
        }
        // One within a minute of the last saved stays in the recorder, for
        // the next trace.
        let saves = recorded && clock.savesTrace(at: now)
        lock.unlock()

        let line = String(format: "stall: main thread away %.1f s", away)
        ChatViewportTrace.shared.log(line)
        logger.fault("\(line, privacy: .public)")
        guard saves else { return }
        let lines = ChatViewportTrace.shared.lines(last: ChatTraceStore.maxRingLines)
        let trace = ChatTraceStore().save(.stall, lines: lines)
        lock.lock()
        stallTrace = trace
        lock.unlock()
        #if DEBUG
        for line in lines.suffix(80) {
            logger.fault("trace: \(line, privacy: .public)")
        }
        #endif
    }
}

/// The watchdog's clock, apart from its timers and threads so a test can
/// drive it: when the main thread counts as away, when a suspension starts
/// it over, and when a stall may save a trace.
struct StallClock {
    /// How long the main thread can be away before it counts as a stall.
    static let threshold: TimeInterval = 2
    static let interval: TimeInterval = 0.5
    /// As the transcript's watchers (ChatViewportWatch.saveInterval).
    static let saveInterval: TimeInterval = 60

    private var lastBeat: TimeInterval = 0
    private var lastCheck: TimeInterval = 0
    /// The last beat before the stall being reported.
    private var stallStart: TimeInterval?
    private var lastSave: TimeInterval?

    mutating func start(at now: TimeInterval) {
        lastBeat = now
        lastCheck = now
    }

    /// The main thread's beat. How long the stall it ends lasted, when one
    /// was reported.
    mutating func beat(at now: TimeInterval) -> TimeInterval? {
        defer {
            lastBeat = now
            stallStart = nil
        }
        return stallStart.map { now - $0 }
    }

    /// A check on the watchdog's queue: how long the main thread has been
    /// away, once per stall, or nil.
    mutating func check(at now: TimeInterval) -> TimeInterval? {
        guard now - lastCheck <= Self.interval * 3 else {
            // This queue didn't run either: the app was suspended.
            start(at: now)
            return nil
        }
        lastCheck = now
        let away = now - lastBeat
        guard away >= Self.threshold, stallStart == nil else { return nil }
        stallStart = lastBeat
        return away
    }

    /// Whether a stall at `now` saves a trace: at most once a minute.
    mutating func savesTrace(at now: TimeInterval) -> Bool {
        if let lastSave, now - lastSave < Self.saveInterval { return false }
        lastSave = now
        return true
    }
}
