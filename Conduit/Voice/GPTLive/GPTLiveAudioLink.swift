//
//  GPTLiveAudioLink.swift
//  Conduit
//
//  WebRTC runs in manual-audio mode for GPT-Live: Conduit owns the shared
//  audio session (a conversation lease from VoiceAudioSessionCoordinator)
//  and tells WebRTC when it may use it. That makes Conduit responsible for
//  what the system does to the session mid-call: an interruption (a phone
//  call, Siri, an alarm) deactivates it under WebRTC, and a route change
//  can reset it. The link forwards both, the way the classic capture
//  service recovers: stop on interruption, reassert the lease and resume
//  when it ends, reassert after a route change that lost the policy.
//

import AVFAudio
import Foundation
import OSLog
import WebRTC

private let gptLiveAudioLogger = Logger(subsystem: "com.milim.relay", category: "GPTLive")

/// The audio operations the link drives. A seam so interruption handling is
/// testable without a real audio session or WebRTC.
@MainActor
protocol GPTLiveAudioSessionControlling: AnyObject {
    /// Takes the conversation lease (applies the capture policy).
    func acquire() throws
    /// Re-applies the leased policy after the system changed the session.
    func reassert() throws
    func release()
    /// Whether the system session still has the conversation policy.
    var hasConversationPolicy: Bool { get }
    /// Lets WebRTC start its audio unit on the active session.
    func enableWebRTCAudio()
    /// Stops WebRTC's audio unit; the session is no longer usable.
    func disableWebRTCAudio()
}

@MainActor
final class GPTLiveAudioLink {
    /// The audio couldn't be brought back after an interruption.
    var onAudioLost: (@MainActor (String) -> Void)?

    private let audio: GPTLiveAudioSessionControlling
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false
    private(set) var isInterrupted = false

    init(audio: GPTLiveAudioSessionControlling, center: NotificationCenter = .default) {
        self.audio = audio
        self.center = center
    }

    func start() throws {
        guard !isRunning else { return }
        try audio.acquire()
        isRunning = true
        isInterrupted = false
        audio.enableWebRTCAudio()
        // Session notifications can arrive on any thread.
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                Task { @MainActor [weak self] in
                    switch type {
                    case .began?: self?.interruptionBegan()
                    case .ended?: self?.interruptionEnded()
                    default: break
                    }
                }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                Task { @MainActor [weak self] in self?.routeChanged(reason) }
            },
        ]
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers = []
        guard isRunning else { return }
        isRunning = false
        isInterrupted = false
        audio.disableWebRTCAudio()
        audio.release()
    }

    func interruptionBegan() {
        guard isRunning, !isInterrupted else { return }
        gptLiveAudioLogger.notice("GPT-Live audio interrupted")
        isInterrupted = true
        audio.disableWebRTCAudio()
    }

    /// Resumes whether or not the system says it should: the call is still
    /// live, and a conversation that silently stays mute is worse than one
    /// that tries.
    func interruptionEnded() {
        guard isRunning, isInterrupted else { return }
        do {
            try audio.reassert()
        } catch {
            gptLiveAudioLogger.error("GPT-Live audio couldn't resume: \(String(describing: error), privacy: .public)")
            onAudioLost?(AppLocalization.string("GPT-Live's audio couldn't resume after the interruption."))
            return
        }
        isInterrupted = false
        audio.enableWebRTCAudio()
    }

    func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        // Our own policy changes post category changes: never loop on them.
        guard isRunning, !isInterrupted, reason != .categoryChange, !audio.hasConversationPolicy else { return }
        do {
            try audio.reassert()
        } catch {
            gptLiveAudioLogger.error("GPT-Live audio couldn't reapply after a route change: \(String(describing: error), privacy: .public)")
            audio.disableWebRTCAudio()
            onAudioLost?(AppLocalization.string("GPT-Live's audio couldn't resume after the interruption."))
        }
    }
}

/// The real session: the shared coordinator's lease plus RTCAudioSession.
@MainActor
final class SystemGPTLiveAudioSession: GPTLiveAudioSessionControlling {
    private let coordinator: VoiceAudioSessionCoordinator
    private var lease: VoiceAudioLease?

    init(coordinator: VoiceAudioSessionCoordinator? = nil) {
        self.coordinator = coordinator ?? .shared
    }

    func acquire() throws {
        let configuration = VoiceAudioSessionConfiguration.capture
        let webRTC = RTCAudioSessionConfiguration.webRTC()
        webRTC.category = configuration.category.rawValue
        webRTC.mode = configuration.mode.rawValue
        webRTC.categoryOptions = configuration.options
        RTCAudioSessionConfiguration.setWebRTC(webRTC)
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
        lease = try coordinator.acquire(.conversationCapture)
    }

    func reassert() throws {
        try coordinator.reassert()
    }

    func release() {
        guard let lease else { return }
        self.lease = nil
        coordinator.release(lease)
    }

    var hasConversationPolicy: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.category == VoiceAudioSessionConfiguration.capture.category
            && session.mode == VoiceAudioSessionConfiguration.capture.mode
    }

    func enableWebRTCAudio() {
        let session = RTCAudioSession.sharedInstance()
        // Activation and deactivation are counted by WebRTC: keep them paired.
        guard !session.isAudioEnabled else { return }
        session.audioSessionDidActivate(AVAudioSession.sharedInstance())
        session.isAudioEnabled = true
    }

    func disableWebRTCAudio() {
        let session = RTCAudioSession.sharedInstance()
        guard session.isAudioEnabled else { return }
        session.isAudioEnabled = false
        session.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
    }
}
