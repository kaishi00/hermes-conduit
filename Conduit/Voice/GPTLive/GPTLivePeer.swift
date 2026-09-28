//
//  GPTLivePeer.swift
//  Conduit
//
//  The WebRTC side of a GPT-Live call: one peer connection carrying the
//  microphone out and the model's voice back as audio tracks, plus the
//  `oai-events` data channel for events. WebRTC's own audio unit plays the
//  model and does echo cancellation, so there is no separate playback
//  service; the shared audio session is still leased from
//  VoiceAudioSessionCoordinator like every other Conduit voice path.
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
    /// The data channel opened: events can be sent.
    var onChannelOpen: (@MainActor () -> Void)? { get set }
    /// The connection failed or closed underneath the session.
    var onDisconnected: (@MainActor () -> Void)? { get set }
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
    var onChannelOpen: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?

    /// How long ICE gathering may take before the offer goes out with the
    /// candidates it has (host candidates come almost at once).
    static let iceGatheringTimeout: Duration = .seconds(3)

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let audioSessions: VoiceAudioSessionCoordinator
    private var connection: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var microphone: RTCAudioTrack?
    private var lease: VoiceAudioLease?
    private var isClosed = false

    /// Optional rather than defaulted to `.shared`: default arguments are
    /// evaluated outside the main actor.
    init(audioSessions: VoiceAudioSessionCoordinator? = nil) {
        self.audioSessions = audioSessions ?? .shared
        super.init()
    }

    func makeOffer() async throws -> String {
        try startAudio()
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
        stopAudio()
    }

    // MARK: Audio session

    /// Conduit owns the audio session (a conversation lease); WebRTC is told
    /// when it may use it instead of configuring it on its own.
    private func startAudio() throws {
        let configuration = VoiceAudioSessionConfiguration.capture
        let webRTC = RTCAudioSessionConfiguration.webRTC()
        webRTC.category = configuration.category.rawValue
        webRTC.mode = configuration.mode.rawValue
        webRTC.categoryOptions = configuration.options
        RTCAudioSessionConfiguration.setWebRTC(webRTC)
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
        lease = try audioSessions.acquire(.conversationCapture)
        session.audioSessionDidActivate(AVAudioSession.sharedInstance())
        session.isAudioEnabled = true
    }

    private func stopAudio() {
        let session = RTCAudioSession.sharedInstance()
        session.isAudioEnabled = false
        guard let lease else { return }
        self.lease = nil
        session.audioSessionDidDeactivate(AVAudioSession.sharedInstance())
        audioSessions.release(lease)
    }

    fileprivate func connectionStateChanged(_ state: RTCPeerConnectionState) {
        guard !isClosed else { return }
        switch state {
        case .failed, .closed, .disconnected:
            gptLivePeerLogger.notice("GPT-Live peer connection ended: state=\(state.rawValue, privacy: .public)")
            onDisconnected?()
        default:
            break
        }
    }

    fileprivate func channelStateChanged(_ state: RTCDataChannelState) {
        guard !isClosed else { return }
        switch state {
        case .open: onChannelOpen?()
        case .closed: onDisconnected?()
        default: break
        }
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
