//
//  AppState+ChatOnScreen.swift
//  Conduit
//
//  Holds the open chat as on screen on the host while its reply runs, so
//  that reply sends no push (ChatOnScreen.swift), and clears the chat's
//  notifications from this device once it's on screen (#1579).
//

import Foundation
import UserNotifications

@MainActor
extension AppState {
    /// The chat on screen now: the open, live one, with Conduit active and
    /// neither the list nor a group room covering it. Nil when the plugin
    /// doesn't take reports.
    var chatOnScreenClaim: ChatOnScreen.Claim? {
        guard chatOnScreenSender != nil || ChatOnScreen.isTaken(by: notifierPlugin),
              let sessionID = chatShownOnScreen else { return nil }
        return ChatOnScreen.Claim(profile: activeProfile, sessionIDs: chatOwnSessionIDs(for: sessionID))
    }

    /// The open chat's id while it's on screen: Conduit active, the chat
    /// live, and neither the list nor a group room covering it.
    var chatShownOnScreen: String? {
        guard isSceneActive, !showSidebar, activeRoomSurface == nil,
              let sessionID = activeSessionId, !sessionID.isEmpty,
              composerChatOnScreen == .live(sessionID) else { return nil }
        return sessionID
    }

    /// A chat on screen has been read: its notifications leave this
    /// device's Notification Center, and the Watch's with the iPhone's
    /// (#1579). Other devices keep theirs.
    func clearShownChatNotifications() {
        guard let sessionID = chatShownOnScreen else { return }
        let sessionIDs = chatOwnSessionIDs(for: sessionID)
        let dashboardID = activeDashboardID
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let delivered = await center.deliveredNotifications()
            guard !delivered.isEmpty else { return }
            let read = ReadChatNotifications.identifiers(
                of: delivered.map { (identifier: $0.request.identifier, target: PushNotificationService.readChatTarget(from: $0.request.content.userInfo)) },
                sessionIDs: sessionIDs,
                dashboardID: dashboardID
            )
            if !read.isEmpty { center.removeDeliveredNotifications(withIdentifiers: read) }
        }
    }

    /// Brings the host's hold in line with what is on screen. Called on each
    /// change of the open chat, the list, a group room, the scene, the
    /// profile and the turn.
    func updateChatOnScreen() {
        // The suggestion row follows the same edges (AppState+Predictive.swift).
        updatePredictiveScreen()
        // So does clearing what the chat on screen already shows.
        clearShownChatNotifications()
        for action in chatOnScreenTracker.update(wanted: chatOnScreenClaim, turnRunning: turnState.isRunning) {
            switch action {
            case .startRenewing(let claim):
                chatOnScreenRenewal?.cancel()
                chatOnScreenRenewal = Task { @MainActor [weak self] in
                    var holding = false
                    while !Task.isCancelled {
                        guard let interval = self?.renewChatOnScreen(claim, holding: &holding) else { return }
                        do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                    }
                }
            case .stopRenewing:
                chatOnScreenRenewal?.cancel()
                chatOnScreenRenewal = nil
            case .release(let claim):
                // A hold that already ran out (or was let go) needs nothing.
                guard let ends = chatOnScreenHoldEnds, ends > Date() else { continue }
                // Leaving for the background: the release still gets out.
                let end: (() -> Void)? = isSceneActive ? nil
                    : beginVoiceTranscriptBackgroundTask(named: "conduit.chatOnScreen.release")
                sendChatOnScreen(claim, holdSeconds: 0, then: end)
            }
        }
    }

    /// One renewal tick: holds the chat while someone used Conduit lately,
    /// lets it go once nobody has. Returns the wait before the next tick.
    private func renewChatOnScreen(_ claim: ChatOnScreen.Claim, holding: inout Bool) -> TimeInterval {
        // Low Power and Low Data Mode stretch the renewal like every other
        // timed read; the hold stretches with it.
        let interval = ChatOnScreen.renewalInterval(under: deviceConditions())
        // The chat's ids as they stand now: a stored id learned mid-turn
        // rides the next renewal. Nothing on screen holds nothing.
        // A turn Hermes took on its own (Predictive follow-ups) is watched
        // by someone sitting still: it holds too.
        if let current = chatOnScreenClaim,
           InteractionIdleState.shared.usedWithin(ChatOnScreen.engagedWindow)
            || (predictiveFollowUpTurn != nil && predictiveFollowUpTurn?.sessionID == activeSessionId) {
            sendChatOnScreen(current, holdSeconds: ChatOnScreen.holdSeconds(renewingEvery: interval))
            holding = true
        } else if holding {
            // A long turn left running unattended, or the chat no longer on
            // screen: its reply pushes.
            sendChatOnScreen(claim, holdSeconds: 0)
            holding = false
        }
        return interval
    }

    /// Sends after any report still on its way, so the last one sent is
    /// the one the host keeps. A report that fails is dropped: the reply
    /// then pushes, as before.
    private func sendChatOnScreen(_ claim: ChatOnScreen.Claim, holdSeconds: Int, then done: (() -> Void)? = nil) {
        let body = ChatOnScreen.body(device: ChatOnScreen.device, claim: claim, holdSeconds: holdSeconds)
        let path = DashboardPath.withProfile(ChatOnScreen.path, profile: claim.profile)
        let send: (String, [String: Any]) async throws -> Void
        if let chatOnScreenSender {
            send = chatOnScreenSender
        } else if let bridge = dashboardTicketBridge {
            send = { path, body in
                _ = try await bridge.requestJSON(path: path, method: "PUT", body: body,
                                                 timeoutMilliseconds: ChatOnScreen.timeoutMilliseconds)
            }
        } else {
            chatOnScreenHoldEnds = nil
            done?()
            return
        }
        // Counted from now. Kept when the report fails: an earlier hold may
        // still be running on the host, and a release it didn't need costs
        // nothing.
        chatOnScreenHoldEnds = holdSeconds > 0 ? Date().addingTimeInterval(TimeInterval(holdSeconds)) : nil
        let previous = chatOnScreenLastSend
        chatOnScreenLastSend = Task { @MainActor in
            await previous?.value
            try? await send(path, body)
            done?()
        }
    }
}
