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
    /// What the Watch app should show from this phone, and what it was
    /// last sent.
    private var context: WatchPhoneContext?
    private var sharedContext: WatchPhoneContext?

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

    /// A Watch call answering a call from Hermes, whose start came through
    /// the relay (HermesNativeCalls): the Watch's link to this phone is
    /// down under its call screen. Served as if it had come over the link,
    /// so the same start arriving over it gets the same answer.
    func startAnsweredCall(_ start: WatchVoiceWire.Message, reply: @escaping ([String: Any]) -> Void) {
        direct.handle(start, reply: reply)
    }

    /// Which Watch voices can start, and whether calls from Hermes ring
    /// this phone (WatchCallVoices): the session's application context,
    /// which the Watch reads whenever it runs next. Sent once the session
    /// is up and the Watch app installed.
    func share(_ context: WatchPhoneContext) {
        self.context = context
        sendContext()
    }

    private func sendContext() {
        guard let context, context != sharedContext, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            try session.updateApplicationContext(context.encoded())
            sharedContext = context
        } catch {
            log.note("watchContextNotShared", ["error": error.localizedDescription])
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
        sendContext()
    }

    fileprivate func received(_ message: WatchVoiceWire.Message, reply: (([String: Any]) -> Void)?) {
        switch message {
        case .report(let line):
            log.watchReport(line)
            reply?([:])
        case .note(let line):
            log.watchNote(line)
            reply?([:])
        case .directStart, .bridgeStart, .grokStart, .directToken, .directTool, .directToolCancel, .directPoll, .directEnd, .directGrant:
            direct.handle(message, reply: reply)
        case .callsToken(let token, let key, let engine):
            // Calls from Hermes ring the Watch too (designs/hermes-calls-watch.md),
            // while its voice can start (WatchCallVoices). Its key opens an
            // answered call's start (HermesRingHandoff).
            let keySaved = key.flatMap(WatchToolSeal.data(base64URL:)).map(HermesRingHandoffKey.save)
            log.note("watchCallsToken", ["token": token != nil, "key": keySaved.map { $0 ? "saved" : "unsaved" } ?? "none", "engine": engine ?? "none"])
            PushNotificationService.shared.updateWatchVoIPToken(token, engine: engine)
            AppStateRuntimeRegistry.shared.appState.watchCallTokenChanged()
            reply?([:])
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
