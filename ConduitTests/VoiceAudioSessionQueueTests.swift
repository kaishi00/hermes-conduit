//
//  VoiceAudioSessionQueueTests.swift
//  ConduitTests
//
//  The system session seam makes its blocking AVAudioSession calls on one
//  serial queue: deactivation leaves the main thread, and a deactivation
//  queued before a newer activation (stop, then listen again) is dropped
//  instead of landing after it and silencing the new session. These run
//  against a fake backend, never the process-global AVAudioSession.
//

import AVFAudio
import XCTest
@testable import Conduit

@MainActor
final class VoiceAudioSessionQueueTests: XCTestCase {
    private var backend: FakeAudioSessionBackend!
    private var queue: DispatchQueue!
    private var session: SystemVoiceAudioSession!

    override func setUp() {
        super.setUp()
        backend = FakeAudioSessionBackend()
        queue = DispatchQueue(label: "VoiceAudioSessionQueueTests")
        queue.setSpecific(key: testQueueKey, value: ())
        session = SystemVoiceAudioSession(backend: backend, queue: queue)
    }

    func testDeactivationLeavesTheMainThread() throws {
        let gate = holdQueue()

        try session.setActive(false, options: .notifyOthersOnDeactivation)

        XCTAssertEqual(backend.ops, [], "the caller must not wait for the deactivation")
        gate.signal()
        drainQueue()
        XCTAssertEqual(backend.ops, [.deactivate(.notifyOthersOnDeactivation)])
        XCTAssertEqual(backend.ranOnMainThread, [false])
    }

    func testStaleDeactivationAfterNewerActivationIsIgnored() throws {
        let gate = holdQueue()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        releaseLater(gate)

        try session.setActive(true, options: [])
        drainQueue()

        XCTAssertEqual(backend.ops, [.activate], "a stop queued before a newer start must not run after it")
    }

    func testStaleDeactivationAfterNewerCategoryChangeIsIgnored() throws {
        // An answered call sets the category, then CallKit activates the
        // session itself: a queued deactivation must not land in between.
        let gate = holdQueue()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        releaseLater(gate)

        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        drainQueue()

        XCTAssertEqual(backend.ops, [.category(.playAndRecord)])
    }

    func testDeactivationNeverLandsAfterANewerActivation() throws {
        // Unforced timing: whichever way the queue runs, the session ends
        // active.
        for _ in 0..<50 {
            try session.setActive(true, options: [])
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setActive(true, options: [])
        }
        drainQueue()

        XCTAssertEqual(backend.ops.last, .activate)
    }

    func testActivationRunsOnTheQueueAndStillThrowsToTheCaller() {
        backend.activateError = NSError(domain: "test", code: 1)

        XCTAssertThrowsError(try session.setActive(true, options: []))
        // A `queue.sync` from the main thread runs its block on the calling
        // thread (a GCD optimization), so this checks the call was made
        // inside the serial queue, which is what orders it after a queued
        // deactivation, not which thread ran it.
        XCTAssertEqual(backend.ranOnTestQueue, [true])
    }

    func testStopThenListenAgainLeavesTheSessionActive() throws {
        // The coordinator path: the last owner releases (deactivation
        // queued), and a new conversation acquires right away.
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let first = try coordinator.acquire(.conversationCapture)
        drainQueue()
        backend.resetOps()
        let gate = holdQueue()

        coordinator.release(first)
        releaseLater(gate)
        let second = try coordinator.acquire(.conversationCapture)
        drainQueue()

        XCTAssertFalse(backend.ops.contains(.deactivate(.notifyOthersOnDeactivation)))
        XCTAssertEqual(backend.ops.last, .activate)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        coordinator.release(second)
        drainQueue()
        XCTAssertEqual(backend.ops.last, .deactivate(.notifyOthersOnDeactivation))
    }

    func testCardPlaybackRightAfterReadAloudEndsKeepsTheSessionActive() throws {
        // Read Aloud stopping queues the deactivation and leaves the
        // `.playback` category, so the card doesn't see the session as owned
        // elsewhere and activates it: the queued deactivation must not land
        // on the card's playback.
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        let lease = try coordinator.acquire(.standalonePlayback)
        drainQueue()
        backend.resetOps()
        let gate = holdQueue()

        coordinator.release(lease)
        releaseLater(gate)
        coordinator.activateForCardPlayback()
        drainQueue()

        XCTAssertEqual(backend.ops, [.category(.playback), .activate])
    }

    func testCardPlaybackEndDeactivatesOffTheMainThread() {
        let coordinator = VoiceAudioSessionCoordinator(session: session)
        coordinator.activateForCardPlayback()
        drainQueue()
        backend.resetOps()

        coordinator.deactivateAfterCardPlayback()
        drainQueue()

        XCTAssertEqual(backend.ops, [.deactivate(.notifyOthersOnDeactivation)])
        XCTAssertEqual(backend.ranOnMainThread, [false])
    }

    // MARK: Helpers

    /// Blocks the session queue until the returned gate is signalled.
    private func holdQueue() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        return gate
    }

    /// Opens the gate from another thread while the main thread is waiting
    /// on the queue for a newer call.
    private func releaseLater(_ gate: DispatchSemaphore) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gate.signal() }
    }

    private func drainQueue() {
        queue.sync {}
    }
}

/// Marks the test's serial queue, to tell a block running inside it.
private let testQueueKey = DispatchSpecificKey<Void>()

private final class FakeAudioSessionBackend: VoiceAudioSessionBackend, @unchecked Sendable {
    enum Op: Equatable {
        case category(AVAudioSession.Category)
        case activate
        case deactivate(AVAudioSession.SetActiveOptions)
        case speaker
    }

    private let lock = NSLock()
    private var recordedOnQueue: [Bool] = []
    var ranOnTestQueue: [Bool] { lock.withLock { recordedOnQueue } }
    private var recordedOps: [Op] = []
    private var recordedThreads: [Bool] = []
    var activateError: Error?

    var ops: [Op] { lock.withLock { recordedOps } }
    var ranOnMainThread: [Bool] { lock.withLock { recordedThreads } }

    func resetOps() {
        lock.withLock {
            recordedOps = []
            recordedThreads = []
            recordedOnQueue = []
        }
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        record(.category(category))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active {
            lock.withLock {
                recordedThreads.append(Thread.isMainThread)
                recordedOnQueue.append(DispatchQueue.getSpecific(key: testQueueKey) != nil)
            }
            if let activateError { throw activateError }
            lock.withLock { recordedOps.append(.activate) }
        } else {
            record(.deactivate(options))
        }
    }

    func overrideOutputToSpeaker() throws {
        record(.speaker)
    }

    private func record(_ op: Op) {
        lock.withLock {
            recordedOps.append(op)
            recordedThreads.append(Thread.isMainThread)
        }
    }
}
