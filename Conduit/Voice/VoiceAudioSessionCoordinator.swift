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
import os

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
    /// Whether the session plays out of the built-in loudspeaker right now.
    var isOutputOnBuiltInSpeaker: Bool { get }
    /// Whether the session plays out of the built-in earpiece right now
    /// (no headphones, Bluetooth, or car).
    var isOutputOnBuiltInReceiver: Bool { get }
    /// Whether the session already has this category, mode and options.
    func isConfigured(as configuration: VoiceAudioSessionConfiguration) -> Bool
    /// Sends output to the loudspeaker; the override is cleared by
    /// CallKit's Speaker button, or by the next category change.
    func overrideOutputToSpeaker() throws
}

/// Defaults for session seams that never route: test doubles that don't
/// care about output. A real session must implement every one, or in-call
/// speaker handling quietly turns off.
extension VoiceAudioSessionControlling {
    var isOutputOnBuiltInSpeaker: Bool { false }
    var isOutputOnBuiltInReceiver: Bool { false }
    func isConfigured(as configuration: VoiceAudioSessionConfiguration) -> Bool { false }
    func overrideOutputToSpeaker() throws {}
}

/// The blocking AVAudioSession calls. `SystemVoiceAudioSession` makes them
/// on its serial queue, never the main thread; tests substitute a fake.
protocol VoiceAudioSessionBackend: AnyObject, Sendable {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
    func overrideOutputToSpeaker() throws
}

final class SharedAVAudioSessionBackend: VoiceAudioSessionBackend {
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

    func overrideOutputToSpeaker() throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
    }
}

/// Every session change goes through one serial queue. Deactivation is
/// blocking IPC that waits for audio I/O to wind down, so it runs there
/// without the main thread waiting. Activation and category changes still
/// wait (callers need the error, and a live session before starting an
/// engine), and being on the same queue they run after any deactivation
/// queued before them. A deactivation still queued when a newer change
/// arrives is dropped: stop-then-listen-again doesn't flap the session or
/// resume other apps' audio for an instant.
@MainActor
final class SystemVoiceAudioSession: VoiceAudioSessionControlling {
    private let backend: VoiceAudioSessionBackend
    private let queue: DispatchQueue
    /// Bumped by every change other than deactivation; a queued
    /// deactivation runs only if nothing newer was asked for since.
    private let generation = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    init(backend: VoiceAudioSessionBackend? = nil, queue: DispatchQueue? = nil) {
        self.backend = backend ?? SharedAVAudioSessionBackend()
        self.queue = queue ?? DispatchQueue(label: "com.milim.relay.audio-session", qos: .userInitiated)
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        let backend = self.backend
        try onQueue { try backend.setCategory(category, mode: mode, options: options) }
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        let backend = self.backend
        if active {
            try onQueue { try backend.setActive(true, options: options) }
            return
        }
        let generation = self.generation
        let scheduled = generation.withLock { $0 }
        queue.async {
            guard generation.withLock({ $0 }) == scheduled else { return }
            do {
                try backend.setActive(false, options: options)
            } catch {
                audioSessionLogger.error("audio session deactivation failed: \(LogRedaction.describing(error), privacy: .public)")
            }
        }
    }

    /// Supersedes any queued deactivation, then waits for the change.
    private func onQueue(_ change: () throws -> Void) rethrows {
        generation.withLock { $0 &+= 1 }
        try queue.sync(execute: change)
    }

    var isOtherAudioPlaying: Bool {
        AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    var isOutputOnBuiltInSpeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    var isOutputOnBuiltInReceiver: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInReceiver }
    }

    func isConfigured(as configuration: VoiceAudioSessionConfiguration) -> Bool {
        let session = AVAudioSession.sharedInstance()
        // Options the system adds on its own (CallKit, the mode) don't
        // count; whether the speaker is the default does.
        return session.category == configuration.category
            && session.mode == configuration.mode
            && session.categoryOptions.isSuperset(of: configuration.options)
            && session.categoryOptions.contains(.defaultToSpeaker) == configuration.options.contains(.defaultToSpeaker)
    }

    func overrideOutputToSpeaker() throws {
        let backend = self.backend
        try onQueue { try backend.overrideOutputToSpeaker() }
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
    /// while no audio intent is active. Nil means Conduit holds nothing, not
    /// that the session is off: in a call from Hermes CallKit keeps it
    /// active, so code that reconfigures the session checks `isInNativeCall`
    /// too. Exposed read-only for diagnostics and deterministic ownership
    /// tests.
    private(set) var appliedPolicy: Policy?

    /// Raised when a policy transition failed partway — typically the
    /// category changed but activation did not. The physical session can no
    /// longer be trusted to match `appliedPolicy`, so the next transition
    /// must re-apply the full configuration even if the dominant policy is
    /// unchanged. Cleared whenever a transition completes successfully.
    private var needsReapply = false

    /// True from answering a call from Hermes in CallKit until the last
    /// call is gone: the conversation then uses the call's policy, whose
    /// speaker the call screen can turn off.
    private(set) var isInNativeCall = false
    /// The call's audio has had its one move to the loudspeaker.
    private var nativeCallSpeakerChosen = false
    /// CallKit activated the call's audio and hasn't taken it back. The
    /// session is then CallKit's to keep active: activating it again from
    /// here (every acquire and every route change's reassert did) flipped
    /// the call screen's Speaker button back off while the audio stayed on
    /// the loudspeaker.
    private var isNativeCallAudioActive = false

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
                "audio intent acquisition failed for \(Self.describe(intent), privacy: .public): \(LogRedaction.describing(error), privacy: .public)"
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
        // Here, before the player's engine starts: an override posts a
        // route change, and one landing on a running engine stops it and
        // drops the audio already scheduled (a one-chunk reply entirely).
        if intent == .conversationPlayback { ensureConversationSpeaker() }
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
                "audio session policy transition failed on release: \(LogRedaction.describing(error), privacy: .public)"
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
        // The microphone leaving a reply playing can leave it on the earpiece.
        if intent == .conversationCapture { ensureConversationSpeaker() }
    }

    /// A conversation's reply plays on the loudspeaker when nothing is
    /// connected. `.defaultToSpeaker` asks for that once, when the category
    /// is set; the output-only engine that plays the reply after the
    /// microphone stopped (barge-in off) could still land on the earpiece,
    /// and nothing put it back. Only from the earpiece, so headphones,
    /// Bluetooth and the car keep their route, and never in a call from
    /// Hermes, whose Speaker button owns the choice. Once on the speaker it
    /// does nothing: an override posts a route change of its own.
    func ensureConversationSpeaker() {
        guard appliedPolicy == .conversation, !isInNativeCall,
              leases.values.contains(.conversationPlayback),
              session.isOutputOnBuiltInReceiver else { return }
        do {
            try session.overrideOutputToSpeaker()
        } catch {
            audioSessionLogger.error("conversation speaker override failed: \(LogRedaction.describing(error), privacy: .public)")
        }
    }

    /// A call from Hermes answered in CallKit (#449): CallKit activates the
    /// session itself, so it only gets the call's category now. The voice
    /// conversation's acquire then applies it in full on the session
    /// CallKit activated.
    func configureForIncomingCall() {
        isInNativeCall = true
        nativeCallSpeakerChosen = false
        isNativeCallAudioActive = false
        // Raised first: a conversation already holding the session must
        // move onto the call's policy even if this category change fails.
        needsReapply = true
        let configuration = VoiceAudioSessionConfiguration.nativeCall
        do {
            try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
        } catch {
            audioSessionLogger.error("incoming call category failed: \(LogRedaction.describing(error), privacy: .public)")
        }
    }

    /// CallKit activated the call's audio: it starts on the loudspeaker as
    /// it always has, now as an override the Speaker button can clear.
    /// Only the first activation: CallKit activates again after an
    /// interruption, and that must not undo the earpiece the user chose.
    /// And only from the earpiece: like `.defaultToSpeaker`, a call
    /// answered on headphones, Bluetooth or in the car stays there (the
    /// override would take the loudspeaker and the phone's own microphone).
    func nativeCallAudioActivated() {
        guard isInNativeCall else { return }
        isNativeCallAudioActive = true
        guard !nativeCallSpeakerChosen else { return }
        guard session.isOutputOnBuiltInReceiver else {
            nativeCallSpeakerChosen = true
            return
        }
        do {
            try session.overrideOutputToSpeaker()
            // Only once it took: a failed move retries on the next
            // activation rather than leaving the call on the earpiece.
            nativeCallSpeakerChosen = true
        } catch {
            audioSessionLogger.error("call speaker override failed: \(LogRedaction.describing(error), privacy: .public)")
        }
    }

    /// CallKit took the call's audio back (an interruption, the call
    /// ending): the next acquire or reassert activates the session itself.
    func nativeCallAudioDeactivated() {
        isNativeCallAudioActive = false
    }

    /// The last call from Hermes is gone: a conversation still holding the
    /// session goes back to its own policy now, speaker by default.
    func nativeCallEnded() {
        guard isInNativeCall else { return }
        isInNativeCall = false
        isNativeCallAudioActive = false
        needsReapply = true
        guard !leases.isEmpty else { return }
        do {
            try applyDominantPolicy()
        } catch {
            // needsReapply stays raised: the next transition retries.
            audioSessionLogger.error("conversation policy after the call failed: \(LogRedaction.describing(error), privacy: .public)")
        }
    }

    /// A video or audio card plays outside any lease, only while nothing
    /// else holds the session (the card checks). Its changes still go
    /// through the session seam, so they supersede a deactivation queued
    /// when the last owner released, instead of having it land on the
    /// card's playback.
    func activateForCardPlayback() {
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true, options: [])
    }

    /// Hands the audio back to whatever the card's media paused.
    func deactivateAfterCardPlayback() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
                "audio session rollback to the remaining policy failed: \(LogRedaction.describing(error), privacy: .public)"
            )
        }
    }

    private func applyDominantPolicy() throws {
        let target = dominantPolicy
        guard target != appliedPolicy || needsReapply else { return }
        do {
            switch target {
            case .conversation:
                let configuration = isInNativeCall
                    ? VoiceAudioSessionConfiguration.nativeCall
                    : VoiceAudioSessionConfiguration.capture
                // In a call the speaker is an override a category change
                // clears. A reapply (a route change, the Speaker button
                // itself) leaves a session already on the call's category
                // alone, so the override's own route change can't loop
                // back here through a reassert; one that does change it
                // keeps whichever output the user is on.
                let changesCategory = !(isInNativeCall && session.isConfigured(as: configuration))
                let keepsSpeaker = isInNativeCall && session.isOutputOnBuiltInSpeaker
                if changesCategory {
                    try session.setCategory(configuration.category, mode: configuration.mode, options: configuration.options)
                }
                // CallKit keeps the call's audio active (see
                // isNativeCallAudioActive); before it has, or after it
                // took it back, the conversation activates it as usual.
                if !(isInNativeCall && isNativeCallAudioActive) {
                    try session.setActive(true, options: [])
                }
                // Best effort: losing the speaker must not fail capture. And
                // only if the change really took it: an override posts a
                // route change of its own.
                if changesCategory, keepsSpeaker, !session.isOutputOnBuiltInSpeaker {
                    try? session.overrideOutputToSpeaker()
                }
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
                // In a call from Hermes the session is CallKit's, which
                // deactivates it when the call ends. Classic voice holds
                // nothing while Hermes thinks or between listens; a
                // deactivation there dropped the Speaker button's override,
                // and the call came back on the earpiece every turn.
                if !isInNativeCall {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                }
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
