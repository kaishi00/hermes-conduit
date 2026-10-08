//
//  WatchVoiceLink.swift
//  Conduit
//
//  The iPhone end of Apple Watch voice (designs/apple-watch-voice-direct.md
//  and apple-watch-gpt-live.md). The Watch runs its call itself; this side
//  answers its WatchConnectivity messages: the call's setup, single-use
//  tokens, tool calls, job polls and grant renewals go to the broker
//  (WatchDirectBroker), and the Watch's log lines to the call log.
//

import Combine
import Foundation
import UIKit
import WatchConnectivity

@MainActor
final class WatchVoiceLink: ObservableObject {
    static let shared = WatchVoiceLink()

    @Published private(set) var isActivated = false
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false

    let log = WatchPhoneCallLog.shared
    /// Sets up and serves the Watch's calls.
    private(set) lazy var direct = WatchDirectBroker(link: self)
    private let proxy = PhoneWatchSessionProxy()

    private init() {}

    func activate() {
        guard WCSession.isSupported() else { return }
        proxy.link = self
        WCSession.default.delegate = proxy
        WCSession.default.activate()
    }

    /// The app's state, for the call log.
    static var appStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    // MARK: Receiving

    fileprivate func sessionChanged(_ session: WCSession, activation: Bool = false) {
        isActivated = session.activationState == .activated
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
        if activation {
            log.note("linkActivated", ["paired": session.isPaired, "watchAppInstalled": session.isWatchAppInstalled])
        }
    }

    fileprivate func received(_ message: WatchVoiceWire.Message, reply: (([String: Any]) -> Void)?) {
        switch message {
        case .report(let line):
            log.watchReport(line)
            reply?([:])
        case .note(let line):
            log.watchNote(line)
            reply?([:])
        case .directStart, .bridgeStart, .directToken, .directTool, .directToolCancel, .directPoll, .directEnd, .directGrant:
            direct.handle(message, reply: reply)
        default:
            reply?([:])
        }
    }
}

// MARK: - WCSession delegate

/// WCSession's delegate, off the main actor: hands everything to the link
/// in order.
private final class PhoneWatchSessionProxy: NSObject, WCSessionDelegate {
    weak var link: WatchVoiceLink?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        WatchVoiceMain.async { [weak self] in self?.link?.sessionChanged(session, activation: true) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Another Watch was chosen: start talking to it.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        WatchVoiceMain.async { [weak self] in self?.link?.sessionChanged(session) }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        WatchVoiceMain.async { [weak self] in self?.link?.sessionChanged(session) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let decoded = WatchVoiceWire.decode(message) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(decoded, reply: nil) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let decoded = WatchVoiceWire.decode(message) else {
            replyHandler([:])
            return
        }
        WatchVoiceMain.async { [weak self] in
            guard let link = self?.link else {
                replyHandler([:])
                return
            }
            link.received(decoded, reply: replyHandler)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let decoded = WatchVoiceWire.decode(userInfo) else { return }
        WatchVoiceMain.async { [weak self] in self?.link?.received(decoded, reply: nil) }
    }
}
