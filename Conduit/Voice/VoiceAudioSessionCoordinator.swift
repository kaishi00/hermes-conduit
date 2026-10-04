//
//  VoiceAudioSessionCoordinator.swift
//  Conduit
//
//  Single authority for Conduit's ownership of the process-global
//  AVAudioSession. Services acquire an intent-scoped lease instead of
//  calling setCategory/setActive themselves, so playback-only flows
//  (Read Aloud, the TTS provider test) can no longer leave the session
//  active forever, and one component can never deactivate or reconfigure
//  the session while another still needs it (issue #140).
//

import AVFAudio
import Foundation
import OSLog

private let audioSessionLogger = Logger(subsystem: "com.milim.relay", category: "VoiceAudio")

/// An audio capability Conduit can hold against the shared session.
enum VoiceAudioIntent: Equatable {
    /// Microphone capture for an active Voice Conversation.
    case conversationCapture
    /// Assistant speech during an active Voice Conversation.
    case conversationPlayback
    /// Output-only speech outside a Voice Conversation (Read Aloud, TTS test).
    case standalonePlayback
    /// Foreground wake phrase listening (#174). The lowest-priority owner:
    /// any other intent takes the session over, and AppState disarms the
    /// wake listener as soon as another owner appears.
    case wakeListening
}

/// Seam over `AVAudioSession.sharedInstance()` so coordinator policy can be
/// asserted in unit tests without touching real system audio state.
@MainActor
protocol VoiceAudioSessionControlling: AnyObject {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
    /// Whether another app is playing audio right now (music, a podcast).
    var isOtherAudioPlaying: Bool { get }
}

@MainActor
final class SystemVoiceAudioSession: VoiceAudioSessionControlling {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        try AVAudioSession.sharedInstance().setCategory(category, mode: mode, options: options)
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try AVAudioSession.sharedInstance().setActive(active, options: options)
    }

    var isOtherAudioPlaying: Bool {
        AVAudioSession.sharedInstance().isOtherAudioPlaying
    }
}

/// Ownership token returned by `acquire`. Release is idempotent: releasing an
/// unknown or already-released lease is a no-op, so repeated cleanup paths
/// (stop, cancellation, backgrounding) can never underflow another owner.
struct VoiceAudioLease: Equatable {
    /// `fileprivate`, not `private`: the coordinator (same file, different
    /// type) keys its lease table on this id.
    fileprivate let id: UUID
    /// Internal so tests can synthesize unknown leases; production callers
    /// only ever receive leases from `acquire`.
    init(id: UUID = UUID()) { self.id = id }
}

@MainActor
final class VoiceAudioSessionCoordinator {
    /// Shared instance: the underlying `AVAudioSession` is itself a
    /// process-global singleton, so one coordinator mirrors reality. Tests
    /// construct isolated instances with a mocked session seam.
    /// Both audio services are app-lifetime objects owned by AppState and
    /// must release leases on every terminal path (stop, cancellation,
    /// failure) — a lease still held at service deinit would leave a
    /// permanent owner entry here.
    static let shared = VoiceAudioSessionCoordinator()

    /// The session policy currently applied to the system session, or nil
    /// while no audio intent is active. Exposed read-only for diagnostics
    /// and deterministic ownership tests.
    private(set) var appliedPolicy: Policy?

    /// Raised when a policy transition failed partway — typically the
    /// category changed but activation did not. The physical session can no
    /// longer be trusted to match `appliedPolicy`, so the next transition
    /// must re-apply the full configuration even if the dominant policy is
    /// unchanged. Cleared whenever a transition completes successfully.
    private var needsReapply = false

    enum Policy: Equatable {
        /// `.playAndRecord` + `.voiceChat`: Voice Conversation capture, and
        /// assistant speech that shares the capture-owned session.
        case conversation
        /// Output-only `.playback` with media coexistence: standalone speech.
        case standalonePlayback
        /// `.playAndRecord` + `.default`, mixing with other apps' audio:
        /// foreground wake phrase listening.
        case wakeListening
    }

    private let session: VoiceAudioSessionControlling
    private var leases: [UUID: VoiceAudioIntent] = [:]
    /// Owners that give way when another capture owner arrives (composer
    /// dictation), by lease.
    private var takeoverHandlers: [UUID: @MainActor () -> Void] = [:]

    /// Single consumer: AppState's wake lifecycle.
    /// Called on the next main-actor turn after the set of owners changed,
    /// so the wake listener can step aside for any other audio owner without
    /// re-entering the coordinator mid-transition.
    var onOwnersChanged: (@MainActor () -> Void)?

    /// Single consumer: AppState's wake lifecycle. Called synchronously,
    /// before anything changes, when another owner acquires while the wake
    /// listener holds the session, so the listener stops its microphone and
    /// releases first. Waiting for `onOwnersChanged` left both microphones
    /// running for a turn, and dictation started under wake listening never
    /// heard anything (#333).
    var onWakeListenerMustYield: (@MainActor () -> Void)?

    /// True while anything other than the wake listener holds the session.
    var hasOwnersOtherThanWakeListening: Bool {
        leases.values.contains { $0 != .wakeListening }
    }

    /// True while anything holds the microphone for a conversation.
    var hasCaptureOwner: Bool {
        leases.values.contains(.conversationCapture)
    }

    /// Optional injection instead of a default-constructed argument: default
    /// parameter values are evaluated in a nonisolated context, which cannot
    /// construct the MainActor-isolated `SystemVoiceAudioSession`.
    init(session: VoiceAudioSessionControlling? = nil) {
        self.session = session ?? SystemVoiceAudioSession()
    }

    /// `onTakenOver` makes the owner one that gives way: it is called, on a
    /// later main-actor turn, when another owner acquires capture. The owner
    /// still releases its own lease.
    func acquire(
        _ intent: VoiceAudioIntent,
        onTakenOver: (@MainActor () -> Void)? = nil
    ) throws -> VoiceAudioLease {
        // Before this acquisition touches any state, so the listener's own
        // release is an ordinary one.
        if intent != .wakeListening, leases.values.contains(.wakeListening) {
            onWakeListenerMustYield?()
        }
        let lease = VoiceAudioLease(id: UUID())
        let displaced = intent == .conversationCapture ? Array(takeoverHandlers.values) : []
        leases[lease.id] = intent
        do {
            try applyDominantPolicy()
        } catch {
            leases.removeValue(forKey: lease.id)
            audioSessionLogger.error(
                "audio intent acquisition failed for \(Self.describe(intent), privacy: .public): \(String(describing: error), privacy: .public)"
            )
            // The failed transition may have switched the category before
            // activation failed, leaving the physical session partially
            // switched under the remaining owners. needsReapply was raised by
            // the failed transition, so this compensating call re-applies
            // their dominant policy in full instead of trusting the
            // unchanged bookkeeping. If the restore also fails, the flag
            // stays raised and the next ownership transition retries.
            compensatingReapplyForRemainingOwners()
            throw error
        }
        audioSessionLogger.debug(
            "audio intent acquired: \(Self.describe(intent), privacy: .public) (owners: \(self.leases.count))"
        )
        if let onTakenOver { takeoverHandlers[lease.id] = onTakenOver }
        for handler in displaced {
            Task { @MainActor in handler() }
        }
        notifyOwnersChanged()
        return lease
    }

    func release(_ lease: VoiceAudioLease) {
        guard let intent = leases.removeValue(forKey: lease.id) else { return }
        takeoverHandlers.removeValue(forKey: lease.id)
        notifyOwnersChanged()
        do {
            try applyDominantPolicy()
        } catch {
            // Transition and deactivation failures must never crash the
            // caller.
            audioSessionLogger.error(
                "audio session policy transition failed on release: \(String(describing: error), privacy: .public)"
            )
            // A partial transition may have half-switched the physical
            // session under the remaining owners: restore their dominant
            // policy best-effort. A failed deactivation to nil has no
            // remaining owners and stays consistent under the retained
            // applied policy, so no rollback is attempted there.
            compensatingReapplyForRemainingOwners()
            return
        }
        audioSessionLogger.debug(
            "audio intent released: \(Self.describe(intent), privacy: .public) (owners: \(self.leases.count))"
        )
    }

    /// Reapplies the dominant policy after the system may have deactivated
    /// the session underneath a live lease (route change restarting capture).
    func reassert() throws {
        guard !leases.isEmpty else { return }
        needsReapply = true
        try applyDominantPolicy()
    }

    /// Any conversation intent keeps the conversation configuration:
    /// conversation playback joins the capture-owned session without
    /// reconfiguring it, and conversation playback that outlives its capture
    /// owner (paused microphone while the assistant is still speaking) must
    /// not churn the audio route mid-playback.
    /// Wake listening ranks below standalone playback: it is the only owner
    /// that steps aside on its own, so it never decides the policy while
    /// anything else holds the session.
    private var dominantPolicy: Policy? {
        if leases.values.contains(where: { $0 == .conversationCapture || $0 == .conversationPlayback }) {
            return .conversation
        }
        if leases.values.contains(.standalonePlayback) {
            return .standalonePlayback
        }
        if leases.values.contains(.wakeListening) {
            return .wakeListening
        }
        return nil
    }

    private func notifyOwnersChanged() {
        guard onOwnersChanged != nil else { return }
        Task { @MainActor [weak self] in self?.onOwnersChanged?() }
    }

    /// Best-effort restore of the surviving owners' policy after a partial
    /// transition failure. Never throws: a failed restore leaves needsReapply
    /// raised, so the next ownership transition retries the full
    /// configuration. The `appliedPolicy != nil` guard covers both callers —
    /// a failed acquire with no previously applied policy leaves the session
    /// inactive (the next acquire re-applies fully anyway), and a release to
    /// nil has no survivors.
    private func compensatingReapplyForRemainingOwners() {
        guard appliedPolicy != nil else { return }
        do {
            try applyDominantPolicy()
        } catch {
            audioSessionLogger.error(
                "audio session rollback to the remaining policy failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func applyDominantPolicy() throws {
        let target = dominantPolicy
        guard target != appliedPolicy || needsReapply else { return }
        do {
            switch target {
            case .conversation:
                let configuration = VoiceAudioSessionConfiguration.capture
                try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
                try session.setActive(true, options: [])
                appliedPolicy = .conversation
            case .standalonePlayback:
                // Chosen when standalone speech takes the session: alongside
                // other media it mixes and ducks as before; with nothing else
                // playing it owns the session, which is what makes Read Aloud
                // the Now Playing app (lock screen, Control Center, AirPods
                // play/pause, #373).
                let configuration = session.isOtherAudioPlaying
                    ? VoiceAudioSessionConfiguration.standalonePlayback
                    : VoiceAudioSessionConfiguration.standaloneNowPlaying
                try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
                try session.setActive(true, options: [])
                appliedPolicy = .standalonePlayback
            case .wakeListening:
                let configuration = VoiceAudioSessionConfiguration.wakeListening
                try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
                try session.setActive(true, options: [])
                appliedPolicy = .wakeListening
            case nil:
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                appliedPolicy = nil
            }
            needsReapply = false
        } catch {
            // An activation-path failure is partial: the category may have
            // changed even though activation did not, so the physical session
            // no longer matches appliedPolicy and the next transition must
            // re-apply the full configuration. A failed deactivation, by
            // contrast, leaves the session active under the applied policy —
            // still consistent — so the flag is not raised there.
            if target != nil { needsReapply = true }
            throw error
        }
        // "Applied" rather than "changed": a needsReapply transition can
        // legitimately re-apply the policy that bookkeeping already named.
        audioSessionLogger.info("audio policy applied: \(Self.describe(target), privacy: .public)")
    }

    private static func describe(_ intent: VoiceAudioIntent) -> String {
        switch intent {
        case .conversationCapture: return "conversationCapture"
        case .conversationPlayback: return "conversationPlayback"
        case .standalonePlayback: return "standalonePlayback"
        case .wakeListening: return "wakeListening"
        }
    }

    private static func describe(_ policy: Policy?) -> String {
        switch policy {
        case .conversation: return "conversation"
        case .standalonePlayback: return "standalone"
        case .wakeListening: return "wakeListening"
        case nil: return "inactive"
        }
    }
}
