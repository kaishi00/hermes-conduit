//
//  GPTLivePeer.swift
//  Conduit
//
//  The WebRTC side of a GPT-Live call: one peer connection carrying the
//  microphone out and the model's voice back as audio tracks, plus the
//  `oai-events` data channel for events. WebRTC's own audio unit plays the
//  model and does echo cancellation, so there is no separate playback
//  service; the shared audio session is still leased from
//  VoiceAudioSessionCoordinator like every other Conduit voice path, with
//  GPTLiveAudioLink carrying interruptions and route changes to WebRTC.
//

import AVFAudio
import Foundation
import OSLog
import WebRTC

private let gptLivePeerLogger = Logger(subsystem: "com.milim.relay", category: "GPTLive")

/// The transport a GPT-Live session drives. A seam so the session and its
/// controller are testable without WebRTC or audio hardware.
@MainActor
protocol GPTLivePeer: AnyObject {
    /// A message from the data channel.
    var onMessage: (@MainActor (String) -> Void)? { get set }
    /// The connection failed or closed underneath the session.
    var onDisconnected: (@MainActor () -> Void)? { get set }
    /// ICE lost the path for now (a network handoff, a packet-loss blip):
    /// `true` when it drops, `false` once it is connected again. It often
    /// recovers on its own; the session decides how long to wait.
    var onConnectionInterrupted: (@MainActor (Bool) -> Void)? { get set }
    /// The call's audio couldn't be brought back (after an interruption).
    var onAudioLost: (@MainActor (String) -> Void)? { get set }
    /// Opens the microphone and the data channel and returns the local SDP
    /// offer, with its ICE candidates gathered.
    func makeOffer() async throws -> String
    func acceptAnswer(_ sdp: String) async throws
    /// False when the channel isn't open or refused the message.
    @discardableResult
    func send(_ text: String) -> Bool
    /// Mute is the local track disabled: the subscription protocol has no
    /// mute event.
    func setMicrophoneEnabled(_ enabled: Bool)
    func close()
}

enum GPTLivePeerError: LocalizedError {
    case offerFailed
    case answerRejected

    var errorDescription: String? {
        switch self {
        case .offerFailed: return AppLocalization.string("Couldn't prepare the GPT-Live call.")
        case .answerRejected: return AppLocalization.string("GPT-Live's call answer couldn't be used.")
        }
    }
}

@MainActor
final class WebRTCGPTLivePeer: NSObject, GPTLivePeer {
    var onMessage: (@MainActor (String) -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onConnectionInterrupted: (@MainActor (Bool) -> Void)?
    var onAudioLost: (@MainActor (String) -> Void)?
    private var isInterrupted = false

    /// How long ICE gathering may take before the offer goes out with the
    /// candidates it has (host candidates come almost at once).
    static let iceGatheringTimeout: Duration = .seconds(3)

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let audio: GPTLiveAudioLink
    private var connection: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private var isClosed = false

    /// Optional rather than defaulted: default arguments are evaluated
    /// outside the main actor.
    init(audio: GPTLiveAudioLink? = nil) {
        self.audio = audio ?? GPTLiveAudioLink(audio: SystemGPTLiveAudioSession())
        super.init()
        self.audio.onAudioLost = { [weak self] message in
            guard let self, !self.isClosed else { return }
            self.onAudioLost?(message)
        }
    }

    func makeOffer() async throws -> String {
        try audio.start()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw GPTLivePeerError.offerFailed
        }
        self.connection = connection

        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: [
            "googEchoCancellation": "true",
            "googAutoGainControl": "true",
            "googNoiseSuppression": "true",
        ])
        let source = Self.factory.audioSource(with: audioConstraints)
        let track = Self.factory.audioTrack(with: source, trackId: "conduit-microphone")
        connection.add(track, streamIds: ["conduit"])
        microphone = track

        // Created before the offer so its m-line is negotiated.
        let channelConfiguration = RTCDataChannelConfiguration()
        guard let channel = connection.dataChannel(forLabel: GPTLiveProtocol.dataChannelLabel, configuration: channelConfiguration) else {
            throw GPTLivePeerError.offerFailed
        }
        channel.delegate = self
        self.channel = channel

        let offerConstraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: offerConstraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? GPTLivePeerError.offerFailed) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let deadline = ContinuousClock.now.advanced(by: Self.iceGatheringTimeout)
        while connection.iceGatheringState != .complete, ContinuousClock.now < deadline, !isClosed {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !isClosed, let sdp = connection.localDescription?.sdp, !sdp.isEmpty else {
            throw GPTLivePeerError.offerFailed
        }
        return sdp
    }

    func acceptAnswer(_ sdp: String) async throws {
        guard let connection, !isClosed else { throw GPTLivePeerError.answerRejected }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.setRemoteDescription(answer) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            gptLivePeerLogger.error("GPT-Live answer rejected: \(String(describing: error), privacy: .public)")
            throw GPTLivePeerError.answerRejected
        }
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphone?.isEnabled = enabled
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        channel?.delegate = nil
        channel?.close()
        channel = nil
        microphone?.isEnabled = false
        microphone = nil
        connection?.delegate = nil
        connection?.close()
        connection = nil
        audio.stop()
    }

    fileprivate func connectionStateChanged(_ state: RTCPeerConnectionState) {
        guard !isClosed else { return }
        switch state {
        case .failed, .closed:
            gptLivePeerLogger.notice("GPT-Live peer connection ended: state=\(state.rawValue, privacy: .public)")
            onDisconnected?()
        case .disconnected:
            // WebRTC's temporary state: it usually returns to connected.
            guard !isInterrupted else { return }
            gptLivePeerLogger.notice("GPT-Live peer connection interrupted")
            isInterrupted = true
            onConnectionInterrupted?(true)
        case .connected:
            guard isInterrupted else { return }
            gptLivePeerLogger.notice("GPT-Live peer connection restored")
            isInterrupted = false
            onConnectionInterrupted?(false)
        default:
            break
        }
    }

    fileprivate func channelStateChanged(_ state: RTCDataChannelState) {
        guard !isClosed else { return }
        if state == .closed { onDisconnected?() }
    }

    fileprivate func received(_ text: String) {
        guard !isClosed else { return }
        onMessage?(text)
    }
}

// WebRTC calls its delegates on its own threads; everything hops to the main actor.
extension WebRTCGPTLivePeer: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in self?.connectionStateChanged(newState) }
    }
}

extension WebRTCGPTLivePeer: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        Task { @MainActor [weak self] in self?.channelStateChanged(state) }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, let text = String(data: buffer.data, encoding: .utf8) else { return }
        Task { @MainActor [weak self] in self?.received(text) }
    }
}
