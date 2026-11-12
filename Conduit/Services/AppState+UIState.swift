//
//  AppState+UIState.swift
//  Conduit
//
//  UI state that isn't a chat's: pausing live publishes, the sidebar,
//  a Bot Chat opening, Settings dismissal and room handoffs. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Runtime

    /// A card with an event this recent may belong to an agent the gateway
    /// roster hasn't registered yet, so the roster check leaves it alone.
    static let delegateAgentRosterGrace: TimeInterval = 30

    // MARK: - UI state

    /// The open chat's live rows can't be seen: the sessions drawer covers
    /// them, or Conduit is in the background or inactive (sceneHidesLiveRows). Their text and reasoning
    /// publishes (to `liveTurn`, which only those rows observe) pause then.
    /// In the background a reply streaming in otherwise kept the main
    /// thread drawing it, the whole growing reply on each publish, so iOS's
    /// watchdog killed Conduit when it couldn't finish going to the
    /// background or quitting (8BADF00D). The live buffers stay
    /// authoritative and are republished once the rows show again.
    var liveRowsHidden: Bool { showSidebar || sceneHidesLiveRows }

    /// Conduit's screens are in view: the scene is active, or on a Mac its
    /// window shows behind another app's. The Chats list's live reads keep
    /// going there, so its Running and Approve keep up with the chats
    /// beside the app in front (issue 1615).
    var sceneIsInView: Bool {
        isSceneActive || (inactiveSceneStaysInView && sceneHasBeenActive && !sceneHidesLiveRows)
    }

    func pauseLivePublishes() {
        streamingPublishTask?.cancel()
        streamingPublishTask = nil
        hasScheduledStreamingPublish = false
        reasoningPublishTask?.cancel()
        reasoningPublishTask = nil
        hasScheduledReasoningPublish = false
    }

    /// What streamed while the live rows were hidden, in one publish.
    func resumeLivePublishesIfShown() {
        guard !liveRowsHidden else { return }
        if !streamingBuffer.isEmpty, streamingBuffer != streamingText {
            lastStreamingPublishBurst = max(
                streamingBuffer.count - streamingText.count,
                0
            )
            lastStreamingPublishDate = Date()
            streamingText = streamingBuffer
        }
        flushReasoningPublish()
    }

    /// Closes the modal sessions drawer if it is open. Session-opening flows
    /// inside the sidebar call this unconditionally: in drawer mode it
    /// dismisses the sheet, while in the iPad persistent-sidebar layout the
    /// drawer is never presented (`showSidebar` stays false), so this is a
    /// no-op and the persistent column remains visible.
    func dismissSidebarDrawer() {
        guard showSidebar else { return }
        showSidebar = false
    }

    /// Closes the list for `name`'s Bot Chat; `endOpeningBotChat` once the
    /// open has finished, opened or not.
    func beginOpeningBotChat(_ name: String) {
        botChatOpening = name
        let pushed = showSidebar || botChatMarks.values.contains { $0.pushed }
        let mark = botChatMarks[name]
        botChatMarks[name] = ((mark?.taps ?? 0) + 1, (mark?.pushed ?? false) || pushed)
        botChatLatestMark = name
        dismissSidebarDrawer()
    }

    func endOpeningBotChat(_ name: String) {
        if botChatOpening == name { botChatOpening = nil }
        guard let mark = botChatMarks[name] else { return }
        if mark.taps > 1 {
            botChatMarks[name] = (mark.taps - 1, mark.pushed)
            return
        }
        botChatMarks[name] = nil
        // What the chat shows from now on is seen, once nothing covers it.
        noteActiveChatSeen(respectingMarks: true)
        updateChatOnScreen()
    }

    /// The open chat (or room) is hidden behind a bot a list of bots is
    /// opening: its cover shows, or the latest mark, for another bot or a
    /// room, is still out, from the moment the list closes. What arrives
    /// meanwhile isn't seen, so it's not marked read and its notifications
    /// stay. An earlier tap still out covers nothing: a newer one took over.
    var botChatCoversOpenChat: Bool {
        if botChatComingOverAnother != nil { return true }
        guard let name = botChatLatestMark, botChatMarks[name] != nil else { return false }
        guard activeRoomSurface == nil, let open = activeBotChatProfile else { return true }
        return !profilesMatch(open, name)
    }

    /// The shell placed the conversation for the marked Bot Chat: the mark
    /// is spent, so a plain session a notification opens before the Bot
    /// Chat lands still goes to Sessions.
    func botChatOpeningPlaced() {
        botChatOpening = nil
    }

    /// Whether the shell keeps the conversation it's placing in Bots: a
    /// Bot Chat or a workstream's chat is open, or a list of bots marked
    /// one as coming.
    var placesConversationAsBotChat: Bool {
        activeBotChatProfile != nil || activeWorkstream != nil || botChatOpening != nil
    }

    /// Also asked while Settings is only queued behind a closing drawer.
    func requestSettingsDismissal() {
        settingsDismissRequest &+= 1
    }

    enum RoomHandoff: Equatable {
        /// Back, a disband, a server change: the room's screen goes.
        case none
        /// A session open, whose id is already the active one: it places itself.
        case openedChat
        /// A new chat, which has no id until Hermes answers: always an
        /// ordinary chat, in Sessions, whatever Bot Chat was open before.
        case newChat
    }

    /// Where a chat sync puts its error: `errorMessage`, or
    /// `chatErrorBehindRoom` while a room is on screen.
    var chatSyncErrorMessage: String? {
        get { activeRoomSurface == nil ? errorMessage : chatErrorBehindRoom }
        set {
            if activeRoomSurface == nil {
                errorMessage = newValue
            } else {
                chatErrorBehindRoom = newValue
            }
        }
    }

    static let pulseHomesKey = "conduit.pulse.homeChats"

    static let pulseProfilesKey = "conduit.pulse.homeProfiles"

    static let pulseDoItBotsKey = "conduit.pulse.doItBots"

    struct RoomDraftAppend: Equatable {
        let id = UUID()
        let dashboardID: UUID
        let roomID: String
        let words: String
    }
}
