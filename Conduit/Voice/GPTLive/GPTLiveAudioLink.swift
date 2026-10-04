//
//  GPTLiveAudioLink.swift
//  Conduit
//
//  WebRTC runs in manual-audio mode for GPT-Live: Conduit owns the shared
//  audio session (a conversation lease from VoiceAudioSessionCoordinator)
//  and tells WebRTC when it may use it. That makes Conduit responsible for
//  what the system does to the session mid-call: an interruption (a phone
//  call, Siri, an alarm) deactivates it under WebRTC, and a route change
//  can reset it. The link pauses the call's audio on an interruption, or
//  on a route change whose policy can't be reapplied (another sound holds
//  the session), and resumes it when the interruption ends or the app
//  becomes active again. A pause never ends the call (#376).
//

import AVFAudio
import Foundation
import OSLog
import UIKit
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
    /// Lets WebRTC start its audio unit on the active session.
    func enableWebRTCAudio()
    /// Stops WebRTC's audio unit; the session is no longer usable.
    func disableWebRTCAudio()
}

@MainActor
final class GPTLiveAudioLink {
    /// The call's audio paused (`true`) or came back (`false`).
    var onPausedChanged: (@MainActor (Bool) -> Void)?
    /// Tries to resume after a failed one: the session can still be
    /// settling right after the other sound let go.
    static let resumeRetryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

    private let audio: GPTLiveAudioSessionControlling
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false
    private(set) var isInterrupted = false
    private var resumeTask: Task<Void, Never>?

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
            // Not every interruption gets an end (Apple doesn't promise
            // one): coming back to the app is another chance to resume.
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.appBecameActive() }
            },
        ]
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers = []
        resumeTask?.cancel()
        resumeTask = nil
        guard isRunning else { return }
        isRunning = false
        isInterrupted = false
        audio.disableWebRTCAudio()
        audio.release()
    }

    func interruptionBegan() {
        guard isRunning, !isInterrupted else { return }
        gptLiveAudioLogger.notice("GPT-Live audio interrupted")
        pause()
    }

    /// Resumes whether or not the system says it should: the call is still
    /// live, and a conversation that silently stays mute is worse than one
    /// that tries. A resume that fails is tried again shortly, and the call
    /// stays paused (never lost) until one works.
    func interruptionEnded() {
        guard isRunning, isInterrupted else { return }
        if !resume() { scheduleResume(after: Self.resumeRetryDelays) }
    }

    func appBecameActive() {
        guard isRunning, isInterrupted else { return }
        if !resume() { scheduleResume(after: Self.resumeRetryDelays) }
    }

    /// The system may have torn the session down with the old route (a
    /// Bluetooth headset dropping) even when its category looks unchanged,
    /// so every route change reasserts the lease, as the classic capture
    /// service does; the coordinator makes a redundant one cheap. A policy
    /// that can't be reapplied means another sound holds the session (an
    /// alarm's route change can arrive before its interruption): the call
    /// pauses instead of ending (#376).
    func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        // Our own policy changes post category changes: never loop on them.
        guard isRunning, !isInterrupted, reason != .categoryChange else { return }
        do {
            try audio.reassert()
        } catch {
            gptLiveAudioLogger.error("GPT-Live audio couldn't reapply after a route change: \(String(describing: error), privacy: .public)")
            pause()
            scheduleResume(after: Self.resumeRetryDelays)
        }
    }

    private func pause() {
        isInterrupted = true
        audio.disableWebRTCAudio()
        onPausedChanged?(true)
    }

    /// True once the audio is back (or there is nothing to resume).
    @discardableResult
    private func resume() -> Bool {
        guard isRunning, isInterrupted else { return true }
        do {
            try audio.reassert()
        } catch {
            gptLiveAudioLogger.notice("GPT-Live audio not back yet: \(String(describing: error), privacy: .public)")
            return false
        }
        resumeTask?.cancel()
        resumeTask = nil
        isInterrupted = false
        audio.enableWebRTCAudio()
        onPausedChanged?(false)
        return true
    }

    private func scheduleResume(after delays: [Duration]) {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.isRunning, self.isInterrupted else { return }
                if self.resume() { return }
            }
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
