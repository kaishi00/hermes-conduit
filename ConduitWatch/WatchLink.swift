//
//  WatchLink.swift
//  Conduit Watch
//
//  The Watch end of WatchConnectivity: a call's control messages to and
//  from Conduit on the iPhone, with reachability tracked for the call log.
//  The session's delegate calls arrive on a background queue; everything
//  is handled on the main actor.
//

import Foundation
import WatchConnectivity

@MainActor
final class WatchLink: ObservableObject {
    static let shared = WatchLink()

    @Published private(set) var isReachable = false
    @Published private(set) var isActivated = false
    @Published private(set) var isCompanionInstalled = false
    /// What Conduit on the iPhone last shared: which voices can start, and
    /// whether calls from Hermes ring it. Nil from an older iPhone app.
    @Published private(set) var phoneContext: WatchPhoneContext?
    /// Every reachable ↔ unreachable change since launch.
    private(set) var reachabilityChanges = 0

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

    fileprivate func activationCompleted(_ session: WCSession) {
        isActivated = session.activationState == .activated
        isCompanionInstalled = session.isCompanionAppInstalled
        isReachable = session.isReachable
        // The last one shared before this launch.
        phoneContext = WatchPhoneContext.decode(session.receivedApplicationContext) ?? phoneContext
        WatchCallLog.shared.note("linkActivated", ["reachable": session.isReachable, "companionInstalled": session.isCompanionAppInstalled])
    }

    fileprivate func phoneContextChanged(_ context: WatchPhoneContext?) {
        guard let context, context != phoneContext else { return }
        phoneContext = context
    }

    fileprivate func reachabilityChanged(_ reachable: Bool) {
        guard reachable != isReachable else { return }
        isReachable = reachable
        reachabilityChanges += 1
        WatchCallLog.shared.note("reachability", ["reachable": reachable])
    }
}

enum WatchLinkError: LocalizedError {
    case notActivated

    var errorDescription: String? {
        switch self {
        case .notActivated: return String(localized: "The link to your iPhone isn't ready.")
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

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = WatchPhoneContext.decode(applicationContext)
        WatchVoiceMain.async { [weak self] in self?.link?.phoneContextChanged(context) }
    }

    // Besides its application context, the iPhone only ever answers the
    // Watch's messages: any message it sends on its own is acknowledged
    // and dropped.
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
    }
}
