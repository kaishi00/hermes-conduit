//
//  WatchLink.swift
//  Conduit Watch
//
//  The Watch end of WatchConnectivity: control messages and audio packets
//  to and from Conduit on the iPhone, with reachability tracked for the
//  test log. The session's delegate calls arrive on a background queue;
//  everything is handled on the main actor.
//

import Foundation
import WatchConnectivity

@MainActor
final class WatchLink: ObservableObject {
    static let shared = WatchLink()

    @Published private(set) var isReachable = false
    @Published private(set) var isActivated = false
    @Published private(set) var isCompanionInstalled = false
    /// Every reachable ↔ unreachable change since launch.
    private(set) var reachabilityChanges = 0

    /// The running call's and link test's handlers.
    var onMessage: ((WatchVoiceWire.Message) -> Void)?
    var onCallPacket: ((WatchVoicePacket) -> Void)?
    var onSoakPacket: ((WatchVoicePacket) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?
    var onSoakReachabilityChange: ((Bool) -> Void)?

    private let proxy = SessionDelegateProxy()

    private init() {}

    func activate() {
        guard WCSession.isSupported() else { return }
        proxy.link = self
        WCSession.default.delegate = proxy
        WCSession.default.activate()
    }

    /// Sends a control message. With `reply`, the iPhone answers with a
    /// message (nil if it couldn't be read); `failure` gets the send error.
    func send(
        _ message: WatchVoiceWire.Message,
        reply: ((WatchVoiceWire.Message?) -> Void)? = nil,
        failure: ((Error) -> Void)? = nil
    ) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            failure?(WatchLinkError.notActivated)
            return
        }
        let payload = WatchVoiceWire.encode(message)
        if let reply {
            session.sendMessage(payload, replyHandler: { answer in
                let decoded = WatchVoiceWire.decode(answer)
                WatchVoiceMain.async { reply(decoded) }
            }, errorHandler: { error in
                WatchVoiceMain.async { failure?(error) }
            })
        } else {
            session.sendMessage(payload, replyHandler: nil, errorHandler: { error in
                WatchVoiceMain.async { failure?(error) }
            })
        }
    }

    /// Queues a control message for whenever the iPhone app can take it,
    /// reachable or not. In order, after anything queued before it. False
    /// if the session isn't active, so nothing was queued.
    @discardableResult
    func queue(_ message: WatchVoiceWire.Message) -> Bool {
        let session = WCSession.default
        guard session.activationState == .activated else { return false }
        session.transferUserInfo(WatchVoiceWire.encode(message))
        return true
    }

    /// Sends a packet; `done` gets the round trip to the iPhone's
    /// acknowledgement, or the error.
    func send(_ packet: WatchVoicePacket, done: @escaping (Result<TimeInterval, Error>) -> Void) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            done(.failure(WatchLinkError.notActivated))
            return
        }
        let sentAt = Date()
        session.sendMessageData(packet.encoded(), replyHandler: { _ in
            let roundTrip = Date().timeIntervalSince(sentAt)
            WatchVoiceMain.async { done(.success(roundTrip)) }
        }, errorHandler: { error in
            WatchVoiceMain.async { done(.failure(error)) }
        })
    }

    fileprivate func activationCompleted(_ session: WCSession) {
        isActivated = session.activationState == .activated
        isCompanionInstalled = session.isCompanionAppInstalled
        isReachable = session.isReachable
        WatchProbeLog.shared.note("linkActivated", ["reachable": session.isReachable, "companionInstalled": session.isCompanionAppInstalled])
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        guard reachable != isReachable else { return }
        isReachable = reachable
        reachabilityChanges += 1
        WatchProbeLog.shared.note("reachability", ["reachable": reachable])
        onReachabilityChange?(reachable)
        onSoakReachabilityChange?(reachable)
    }

    /// A link test's results come back as replies, never on their own.
    fileprivate func received(_ message: WatchVoiceWire.Message) {
        onMessage?(message)
    }

    fileprivate func received(_ packet: WatchVoicePacket) {
        switch packet.kind {
        case .callAudio: onCallPacket?(packet)
        case .soak: onSoakPacket?(packet)
        }
    }
}

enum WatchLinkError: LocalizedError {
    case notActivated

    var errorDescription: String? {
        switch self {
        case .notActivated: return "The link to the iPhone isn't ready."
        }
    }
}

/// WCSession's delegate, off the main actor: answers what needs an answer
/// at once and hands the rest to the link.
private final class SessionDelegateProxy: NSObject, WCSessionDelegate {
    weak var link: WatchLink?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        WatchVoiceMain.async { [weak self] in self?.link?.activationCompleted(session) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        WatchVoiceMain.async { [weak self] in self?.link?.reachabilityChanged(reachable) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = WatchVoiceWire.decode(message) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(decoded) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
        guard let decoded = WatchVoiceWire.decode(message) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(decoded) }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let packet = WatchVoicePacket(data: messageData) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(packet) }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        // The acknowledgement is the sender's flow control: answer first.
        replyHandler(Data())
        guard let packet = WatchVoicePacket(data: messageData) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(packet) }
    }
}
