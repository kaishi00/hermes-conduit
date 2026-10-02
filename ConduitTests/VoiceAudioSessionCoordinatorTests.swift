//
//  VoiceAudioSessionCoordinatorTests.swift
//  ConduitTests
//
//  Deterministic ownership semantics for the audio-session coordinator.
//  These run against a mocked session seam — never the process-global
//  AVAudioSession — so they assert exactly which policy won, how often the
//  session was (de)activated, and that cleanup is idempotent.
//

import AVFAudio
import XCTest
@testable import Conduit

@MainActor
final class VoiceAudioSessionCoordinatorTests: XCTestCase {
    private var session: MockVoiceAudioSession!
    private var coordinator: VoiceAudioSessionCoordinator!

    override func setUp() {
        super.setUp()
        session = MockVoiceAudioSession()
        coordinator = VoiceAudioSessionCoordinator(session: session)
    }

    func testConversationCaptureActivatesConversationPolicy() throws {
        let lease = try coordinator.acquire(.conversationCapture)

        XCTAssertEqual(session.categoryCalls.count, 1)
        XCTAssertEqual(session.categoryCalls.last?.category, .playAndRecord)
        XCTAssertEqual(session.categoryCalls.last?.mode, .voiceChat)
        XCTAssertTrue(session.categoryCalls.last?.options.contains(.allowBluetoothHFP) ?? false)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        XCTAssertEqual(session.activationCount, 1)
        _ = lease
    }

    func testConversationPlaybackJoinsCaptureWithoutReconfiguring() throws {
        _ = try coordinator.acquire(.conversationCapture)
        session.resetRecordings()

        _ = try coordinator.acquire(.conversationPlayback)

        XCTAssertEqual(session.categoryCalls.count, 0, "conversation playback must join the capture-owned session")
        XCTAssertEqual(session.activationCount, 0)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
    }

    func testPlaybackReleaseKeepsCaptureOwnedSessionActive() throws {
        let captureLease = try coordinator.acquire(.conversationCapture)
        let playbackLease = try coordinator.acquire(.conversationPlayback)

        coordinator.release(playbackLease)

        XCTAssertEqual(session.deactivationCount, 0, "playback release must not deactivate while capture owns the session")
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        _ = captureLease
    }

    func testLastConversationOwnerDeactivatesWithNotifyOthers() throws {
        let captureLease = try coordinator.acquire(.conversationCapture)
        let playbackLease = try coordinator.acquire(.conversationPlayback)

        coordinator.release(playbackLease)
        coordinator.release(captureLease)

        XCTAssertEqual(session.deactivationCount, 1, "the session deactivates exactly once when the last owner releases")
        XCTAssertEqual(session.lastDeactivationOptions, .notifyOthersOnDeactivation)
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testConversationPlaybackWithoutCaptureKeepsConversationPolicy() throws {
        // A voice conversation whose microphone is paused can still be
        // speaking: the route must not churn mid-playback, so conversation
        // playback alone keeps the conversation policy.
        _ = try coordinator.acquire(.conversationPlayback)

        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        XCTAssertEqual(session.categoryCalls.last?.category, .playAndRecord)
    }

    func testStandalonePlaybackUsesOutputOnlyPolicy() throws {
        _ = try coordinator.acquire(.standalonePlayback)

        XCTAssertEqual(session.categoryCalls.last?.category, .playback)
        XCTAssertTrue(session.categoryCalls.last?.options.contains(.mixWithOthers) ?? false)
        XCTAssertTrue(session.categoryCalls.last?.options.contains(.duckOthers) ?? false)
        XCTAssertEqual(session.categoryCalls.last?.mode, .default)
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)
        XCTAssertEqual(session.activationCount, 1)
    }

    func testStandalonePlaybackCannotDowngradeActiveConversation() throws {
        _ = try coordinator.acquire(.conversationCapture)
        session.resetRecordings()

        _ = try coordinator.acquire(.standalonePlayback)

        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
        XCTAssertEqual(session.categoryCalls.count, 0, "standalone playback must not reconfigure an active conversation session")
        XCTAssertEqual(session.deactivationCount, 0)
    }

    func testReleasingConversationOwnerHandsOffToStandaloneWithoutDeactivation() throws {
        // Read aloud cannot start mid-conversation today (AppState mutual
        // exclusion), but if a standalone lease ever overlaps a conversation
        // lease, the handoff must transition policies without an
        // intermediate deactivation.
        let captureLease = try coordinator.acquire(.conversationCapture)
        _ = try coordinator.acquire(.standalonePlayback)
        session.resetRecordings()

        coordinator.release(captureLease)

        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)
        XCTAssertEqual(session.deactivationCount, 0)
        XCTAssertEqual(session.categoryCalls.last?.category, .playback)
    }

    func testAcquiringConversationUnderStandaloneUpgradesWithoutDeactivation() throws {
        _ = try coordinator.acquire(.standalonePlayback)
        session.resetRecordings()

        _ = try coordinator.acquire(.conversationCapture)

        XCTAssertEqual(session.deactivationCount, 0)
        XCTAssertEqual(session.categoryCalls.last?.category, .playAndRecord)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
    }

    func testReassertFailureKeepsPolicySoLaterReleaseStillDeactivates() throws {
        let lease = try coordinator.acquire(.conversationCapture)
        session.categoryError = VoiceAudioSessionMockError.configurationFailed

        XCTAssertThrowsError(try coordinator.reassert())
        XCTAssertEqual(coordinator.appliedPolicy, .conversation, "a failed reassert keeps the last known-applied policy")
        session.resetRecordings()

        // With the last owner gone, the retained policy must still diff
        // against the inactive target so the final deactivation runs — the
        // exact sequence a failed route-change restart produces.
        coordinator.release(lease)

        XCTAssertEqual(session.deactivationCount, 1)
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testStandaloneReleaseDeactivatesImmediately() throws {
        let lease = try coordinator.acquire(.standalonePlayback)

        coordinator.release(lease)

        XCTAssertEqual(session.deactivationCount, 1)
        XCTAssertEqual(session.lastDeactivationOptions, .notifyOthersOnDeactivation)
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testSequentialPolicySwitchDeactivatesThenReactivatesStandalone() throws {
        let conversationLease = try coordinator.acquire(.conversationPlayback)
        coordinator.release(conversationLease)
        XCTAssertEqual(session.deactivationCount, 1, "the all-owners-gone transition deactivates before the next policy")
        session.resetRecordings()

        _ = try coordinator.acquire(.standalonePlayback)

        XCTAssertEqual(session.categoryCalls.last?.category, .playback)
        XCTAssertEqual(session.activationCount, 1)
    }

    func testReleaseIsIdempotentAndCannotUnderflow() throws {
        let lease = try coordinator.acquire(.standalonePlayback)
        coordinator.release(lease)
        session.resetRecordings()

        coordinator.release(lease)

        XCTAssertEqual(session.deactivationCount, 0, "releasing an already-released lease must be a no-op")
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testUnknownLeaseReleaseIsNoOp() {
        coordinator.release(VoiceAudioLease(id: UUID()))

        XCTAssertEqual(session.deactivationCount, 0)
    }

    func testAcquireFailureDoesNotLeakOwnership() throws {
        session.categoryError = VoiceAudioSessionMockError.configurationFailed

        XCTAssertThrowsError(try coordinator.acquire(.conversationCapture))
        XCTAssertNil(coordinator.appliedPolicy)

        session.categoryError = nil
        let lease = try coordinator.acquire(.conversationCapture)

        XCTAssertEqual(session.activationCount, 1)
        coordinator.release(lease)
        XCTAssertEqual(session.deactivationCount, 1)
    }

    func testReleaseAfterAcquireDeactivatesAndIsRepeatable() throws {
        let lease = try coordinator.acquire(.standalonePlayback)
        coordinator.release(lease)

        XCTAssertNil(coordinator.appliedPolicy)
        XCTAssertEqual(session.deactivationCount, 1)

        let second = try coordinator.acquire(.standalonePlayback)
        _ = second
        XCTAssertEqual(session.activationCount, 2)
    }

    func testActivationFailureAfterCategorySucceedsDoesNotLeakOwnership() throws {
        session.activateError = VoiceAudioSessionMockError.activationFailed

        XCTAssertThrowsError(try coordinator.acquire(.conversationCapture))
        XCTAssertNil(coordinator.appliedPolicy, "a failed activation must not mark the policy applied")

        session.activateError = nil
        let lease = try coordinator.acquire(.conversationCapture)

        XCTAssertEqual(session.categoryCalls.count, 2, "the retry must re-run configuration")
        XCTAssertEqual(session.activationCount, 1)
        coordinator.release(lease)
        XCTAssertEqual(session.deactivationCount, 1)
    }

    func testDeactivationFailureDoesNotCrashAndIsRetriedOnNextTransition() throws {
        let lease = try coordinator.acquire(.standalonePlayback)
        session.deactivateError = VoiceAudioSessionMockError.deactivationFailed

        coordinator.release(lease)

        // The failed deactivation must not crash or misreport the session as
        // inactive while the system session is actually still applied. The
        // mock records only successful calls, so zero recorded deactivations
        // plus a retained policy means the attempt threw and was swallowed.
        XCTAssertEqual(session.deactivationCount, 0)
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)

        // The next ownership transition retries the deactivation instead of
        // assuming the session went inactive.
        session.deactivateError = nil
        let retryLease = try coordinator.acquire(.standalonePlayback)
        coordinator.release(retryLease)

        XCTAssertEqual(session.deactivationCount, 1)
        XCTAssertEqual(session.lastDeactivationOptions, .notifyOthersOnDeactivation)
        XCTAssertNil(coordinator.appliedPolicy)
    }

    func testReassertReappliesPolicyForLiveOwners() throws {
        _ = try coordinator.acquire(.conversationCapture)
        session.resetRecordings()

        try coordinator.reassert()

        XCTAssertEqual(session.categoryCalls.count, 1, "reassert must reconfigure a live owner's session")
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
    }

    func testFailedStandaloneToConversationAcquisitionRollsBackAndRestoresPolicy() throws {
        _ = try coordinator.acquire(.standalonePlayback)
        session.resetRecordings()

        // One-shot activation failure: the transition switches the category
        // to conversation, then cannot activate.
        session.pendingActivationFailures = 1
        XCTAssertThrowsError(try coordinator.acquire(.conversationCapture))

        // The rolled-back acquisition must not leave the physical session
        // partially switched under the surviving standalone owner: the
        // compensating transition re-applied the standalone policy in full
        // (category restored, activation retried successfully).
        XCTAssertEqual(session.categoryCalls.map(\.category), [.playAndRecord, .playback])
        XCTAssertEqual(session.activationCount, 1, "the rollback re-activated the remaining policy")
        XCTAssertEqual(session.deactivationCount, 0)
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)

        // The failed lease was removed: an acquire matching the applied
        // policy is a plain ownership no-op with no reconfiguration.
        session.resetRecordings()
        _ = try coordinator.acquire(.standalonePlayback)
        XCTAssertEqual(session.categoryCalls.count, 0)
        XCTAssertEqual(session.activationCount, 0)
    }

    func testFailedAcquisitionWithStickyFailureStaysRecoverable() throws {
        _ = try coordinator.acquire(.standalonePlayback)
        session.resetRecordings()

        // Sticky failure: both the conversation transition and the rollback
        // fail. The coordinator must keep the bookkeeping consistent with
        // the surviving owner and keep demanding a full re-apply.
        session.activateError = VoiceAudioSessionMockError.activationFailed
        XCTAssertThrowsError(try coordinator.acquire(.conversationCapture))

        XCTAssertEqual(session.categoryCalls.count, 2, "the transition and the rollback each attempted the category")
        XCTAssertEqual(session.activationCount, 0, "neither the transition nor the rollback activated")
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)

        // Once activations succeed again, the very next ownership transition
        // — even one matching the applied policy — re-applies the full
        // configuration instead of trusting the stale bookkeeping.
        session.activateError = nil
        session.resetRecordings()
        _ = try coordinator.acquire(.standalonePlayback)
        XCTAssertEqual(session.categoryCalls.count, 1)
        XCTAssertEqual(session.activationCount, 1)
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)
    }

    func testFailedConversationToStandaloneHandoffWithExistingOwnersRecovers() throws {
        let captureLease = try coordinator.acquire(.conversationCapture)
        _ = try coordinator.acquire(.standalonePlayback)
        session.resetRecordings()

        // Releasing capture hands ownership to the surviving standalone
        // owner: the category switches to .playback, then a one-shot
        // activation failure hits.
        session.pendingActivationFailures = 1
        coordinator.release(captureLease)

        // The release path immediately re-applied the remaining standalone
        // policy in full, so bookkeeping and physical session agree again.
        XCTAssertEqual(session.categoryCalls.map(\.category), [.playback, .playback])
        XCTAssertEqual(session.activationCount, 1, "the release path restored the remaining standalone policy")
        XCTAssertEqual(session.deactivationCount, 0, "a failed handoff must not deactivate the session")
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)

        // Ownership is now cleanly standalone: acquiring conversation
        // capture performs a normal policy transition.
        session.resetRecordings()
        _ = try coordinator.acquire(.conversationCapture)
        XCTAssertEqual(session.categoryCalls.count, 1)
        XCTAssertEqual(session.categoryCalls.last?.category, .playAndRecord)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)
    }

    func testReassertWithoutOwnersDoesNothing() throws {
        try coordinator.reassert()

        XCTAssertEqual(session.categoryCalls.count, 0)
        XCTAssertEqual(session.activationCount, 0)
    }

    /// Service-level ownership check that needs no audio hardware: encoded
    /// playback acquires a lease before constructing the player, so a startup
    /// failure (here: invalid audio data) must roll the lease back through
    /// the coordinator — the same acquire/rollback contract the engine paths
    /// rely on. Engine-dependent paths (natural PCM completion, interruption,
    /// configuration change) remain manual/device verification.
    func testEncodedPlaybackStartupFailureReleasesAcquiredLease() throws {
        let service = AVSpeechPlaybackService(coordinator: coordinator)

        XCTAssertThrowsError(try service.playEncodedAudioData(Data()))

        XCTAssertEqual(session.categoryCalls.count, 1, "ownership was acquired before the player was built")
        XCTAssertEqual(session.categoryCalls.last?.category, .playback)
        XCTAssertEqual(session.deactivationCount, 1, "the failure must release the acquired lease")
        XCTAssertNil(coordinator.appliedPolicy)
    }
}

@MainActor
extension VoiceAudioSessionCoordinatorTests {
    func testWakeListeningMixesWithOtherAudio() throws {
        _ = try coordinator.acquire(.wakeListening)

        XCTAssertEqual(coordinator.appliedPolicy, .wakeListening)
        XCTAssertEqual(session.categoryCalls.last?.category, .playAndRecord)
        XCTAssertEqual(session.categoryCalls.last?.mode, .default)
        XCTAssertTrue(session.categoryCalls.last?.options.contains(.mixWithOthers) ?? false)
        XCTAssertFalse(coordinator.hasOwnersOtherThanWakeListening)
    }

    func testAnyOtherOwnerOutranksWakeListening() throws {
        _ = try coordinator.acquire(.wakeListening)
        let playback = try coordinator.acquire(.standalonePlayback)
        XCTAssertEqual(coordinator.appliedPolicy, .standalonePlayback)
        XCTAssertTrue(coordinator.hasOwnersOtherThanWakeListening)

        let capture = try coordinator.acquire(.conversationCapture)
        XCTAssertEqual(coordinator.appliedPolicy, .conversation)

        coordinator.release(capture)
        coordinator.release(playback)
        XCTAssertEqual(coordinator.appliedPolicy, .wakeListening)
        XCTAssertFalse(coordinator.hasOwnersOtherThanWakeListening)
    }

    func testOwnerChangesNotifyOnALaterTurn() async throws {
        var notifications = 0
        coordinator.onOwnersChanged = { notifications += 1 }

        let lease = try coordinator.acquire(.standalonePlayback)
        XCTAssertEqual(notifications, 0, "the callback must not re-enter the coordinator mid-transition")
        await Task.yield()
        await Task.yield()
        XCTAssertGreaterThanOrEqual(notifications, 1)

        coordinator.release(lease)
        await Task.yield()
        await Task.yield()
        XCTAssertGreaterThanOrEqual(notifications, 2)
    }
}

private final class MockVoiceAudioSession: VoiceAudioSessionControlling {
    struct CategoryCall: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private(set) var categoryCalls: [CategoryCall] = []
    private(set) var activationCalls: [(active: Bool, options: AVAudioSession.SetActiveOptions)] = []
    var categoryError: Error?
    var activateError: Error?
    var deactivateError: Error?
    /// Fails the next N activation attempts before recording them, modelling
    /// a one-shot activation failure (category succeeds, activation does
    /// not). Failed attempts are deliberately not recorded, so counts reflect
    /// successful system calls. Note: unlike the call recordings, the failure
    /// knobs are NOT cleared by `resetRecordings()` — clear them explicitly.
    var pendingActivationFailures = 0

    var activationCount: Int { activationCalls.filter(\.active).count }
    var deactivationCount: Int { activationCalls.filter { !$0.active }.count }
    var lastDeactivationOptions: AVAudioSession.SetActiveOptions? {
        activationCalls.last(where: { !$0.active })?.options
    }

    func resetRecordings() {
        categoryCalls.removeAll()
        activationCalls.removeAll()
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        if let categoryError { throw categoryError }
        categoryCalls.append(CategoryCall(category: category, mode: mode, options: options))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active {
            if pendingActivationFailures > 0 {
                pendingActivationFailures -= 1
                throw VoiceAudioSessionMockError.activationFailed
            }
            if let activateError { throw activateError }
        }
        if !active, let deactivateError { throw deactivateError }
        activationCalls.append((active, options))
    }
}

private enum VoiceAudioSessionMockError: Error {
    case configurationFailed
    case activationFailed
    case deactivationFailed
}
