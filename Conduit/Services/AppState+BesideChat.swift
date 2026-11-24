//
//  AppState+BesideChat.swift
//  Conduit
//
//  A chat kept beside the one on screen in a wide window (all-live stage 2,
//  slice 3). Open Beside on a chat's row opens that chat and keeps the one
//  that was on screen in a pane beside it: a followed chat
//  (AppState+BackgroundChats.swift) that stays followed with no reply
//  running, so the pane shows its rows and any reply as it streams. The
//  pane only shows: Swap opens its chat in the chat's own column, where it
//  can be written to, and keeps the other beside in its place.
//

import Combine
import Foundation

/// Tells the pane beside the chat that its chat's rows or reply moved. Its
/// own object, as the reply on screen has (`LiveTurnProjection`): a reply
/// streaming in the pane redraws the pane, never every view of AppState.
/// Each kept chat (the pane's and every chat window's) has a notice of its
/// own, so a reply streaming in one redraws that one only (issue 2625).
@MainActor
final class BesideChatLive {
    /// One kept chat's notice.
    final class Chat: ObservableObject {
        @Published private(set) var revision: UInt64 = 0
        func moved() { revision &+= 1 }
    }

    private var chats: [ObjectIdentifier: Chat] = [:]

    /// The notice the views of `chat` follow.
    func notice(for chat: BackgroundChat) -> Chat {
        let key = ObjectIdentifier(chat.state)
        if let notice = chats[key] { return notice }
        let notice = Chat()
        chats[key] = notice
        return notice
    }

    /// `chat`'s rows or reply moved.
    func moved(_ chat: BackgroundChat) { chats[ObjectIdentifier(chat.state)]?.moved() }

    /// Every kept chat may have moved (the socket closed, a pane opened).
    /// Notices of chats no longer followed go.
    func moved(keeping chats: [BackgroundChat]) {
        forget(keeping: chats)
        self.chats.values.forEach { $0.moved() }
    }

    /// Notices of chats no longer followed go, the rest untouched: called
    /// whenever the followed chats change (issue 2655).
    func forget(keeping chats: [BackgroundChat]) {
        guard !self.chats.isEmpty else { return }
        let kept = Set(chats.map { ObjectIdentifier($0.state) })
        if self.chats.keys.contains(where: { !kept.contains($0) }) {
            self.chats = self.chats.filter { kept.contains($0.key) }
        }
    }

    /// How many kept chats have a notice, for tests.
    var noticeCount: Int { chats.count }
}

extension AppState {
    /// The followed chat the pane draws: the one kept beside, on its own
    /// dashboard and profile (the screen's, or another combined dashboard's
    /// opened in place). Nil with no pane.
    var besideChat: BackgroundChat? {
        guard let ids = besideChatIDs else { return nil }
        let ownerDashboard = besideChatOwner?.dashboardID ?? dashboardIDOnScreen
        let ownerProfile = besideChatOwner?.profile ?? runtimeOnScreen.activeProfile
        return backgroundChats.first {
            $0.dashboardID == ownerDashboard && $0.profile == ownerProfile
                && !$0.sessionIDs.isDisjoint(with: ids)
        }
    }

    /// Whether the chat acted on (`act(on:)`) is the one kept beside or in a window.
    var actingOnBesideChat: Bool {
        guard let scope = liveChatScope else { return false }
        return isKeptChat(dashboardID: activeDashboardID, profile: scope.profile, answering: scope.sessionIDs)
    }

    /// A message another device or process sent to the pane's chat, or a
    /// chat window's, shows there as it's sent, ahead of its reply: once,
    /// by Hermes' row id. Hermes also announces the message this device
    /// sent just before the chat was left, whose row is here already
    /// without Hermes' id: the same words with no reply after them yet are
    /// that row. The same words again after a reply are a new message.
    func noteUserMessageInBesideChat(sessionId: String, rowId: Int?, text: String) {
        guard let chat = keptChat(answering: sessionId), !eventBelongsToActiveSession(sessionId),
              text.contains(where: { !$0.isWhitespace }) else { return }
        // Its next message from the box goes where this one came.
        noteKeptChatEvent(chat, sessionID: sessionId)
        let rows = chat.state.messages
        if let rowId, rows.contains(where: { $0.rowId == rowId }) { return }
        if let latest = rows.lastIndex(where: { $0.role == .user }),
           rowId == nil || rows[latest].rowId == nil,
           !rows[(latest + 1)...].contains(where: { $0.role == .assistant }),
           Self.wordsOnly(rows[latest].content) == Self.wordsOnly(text) {
            if rows[latest].rowId == nil, let rowId { chat.state.messages[latest].rowId = rowId }
            return
        }
        var row = ChatMessage(
            id: rowId.map { "user-row-\($0)" } ?? "user-\(UUID().uuidString)",
            role: .user,
            content: text,
            timestamp: Self.localTimestamp(),
            author: nil
        )
        row.rowId = rowId
        chat.state.messages.append(row)
        besideChatLive.moved(chat)
    }

    /// A message's whole words, spacing aside: two messages that only start
    /// alike aren't the same one.
    private static func wordsOnly(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether the chat on screen can stay beside another: an ordinary
    /// chat, live from Hermes, with rows to show (on screen or on its
    /// kept combined runtime). A Bot Chat, a group room and a saved copy
    /// still opening can't.
    var canKeepChatOnScreenBeside: Bool {
        onChatRuntimeValue(unreachable: false) {
            guard isConnected, activeRoomSurface == nil, offlineChatPresentation == nil,
                  activeBotChatProfile == nil, !messages.isEmpty,
                  let id = activeSessionId, !id.isEmpty else { return false }
            if let farOwner = farChat, farBotChatProfile(in: farOwner.dashboardID) != nil {
                return false
            }
            return botStoreProfile(forSessionIDs: Array(knownSessionIDs(for: id).union([id]))) == nil
        }
    }

    /// Whether a chat's row offers Open Beside: another chat of this
    /// profile or another kept combined dashboard's openable chat, while
    /// the chat on screen can stay beside it.
    func canOpenBeside(_ session: SessionSummary) -> Bool {
        guard canKeepChatOnScreenBeside, !isShowingSavedChatList,
              !isSavedChatRow(session), let active = activeSessionId else { return false }
        if let farDashboard = session.combinedDashboardID, farDashboard != dashboardIDOnScreen {
            guard isInCombinedGroup(farDashboard),
                  let kept = keptDashboardRuntimes[farDashboard], kept.client.isConnected,
                  !isFarBotChat(session, in: farDashboard) else { return false }
            let targetProfile = session.profile ?? "default"
            guard profilesMatch(kept.client.profile ?? "default", targetProfile) || kept.client.canHandOffSocket else {
                return false
            }
            if farChat?.dashboardID == farDashboard,
               profilesMatch(farChat?.profile ?? "default", targetProfile) {
                let open = onChatRuntimeValue(unreachable: Set<String>()) {
                    knownSessionIDs(for: active).union([active])
                }
                return open.isDisjoint(with: session.nestingIDs) && !open.contains(session.id)
            }
            return true
        }
        guard !isOtherProfileRow(session) else { return false }
        if farChat == nil {
            let open = knownSessionIDs(for: active).union([active])
            return open.isDisjoint(with: session.nestingIDs) && !open.contains(session.id)
        }
        return true
    }

    /// Opens `session` and keeps the chat on screen beside it. Where that
    /// chat can't stay beside, the row opens as a tap opens it.
    func openBeside(_ session: SessionSummary) {
        let previous = besideChatIDs
        let previousOwner = besideChatOwner
        guard canOpenBeside(session), keepChatOnScreenBeside() else {
            openListedSession(session)
            return
        }
        let kept = besideChatIDs
        let keptOwner = besideChatOwner
        // The chat that was beside until now gives up its place, unless
        // it's the exact chat opening on that dashboard.
        let previousDashboard = previousOwner?.dashboardID ?? dashboardIDOnScreen
        let openingDashboard = session.combinedDashboardID ?? dashboardIDOnScreen
        if let previous,
           previousDashboard != openingDashboard
            || (previous.isDisjoint(with: session.nestingIDs) && !previous.contains(session.id)) {
            letGoOfIdleFollowedChat(answering: previous, dashboardID: previousDashboard)
        }
        if let farDashboard = session.combinedDashboardID, farDashboard != dashboardIDOnScreen {
            guard startFarChatOpen(session, in: farDashboard, onFailure: { [weak self] _ in
                self?.besideChatOpenFailed(kept: kept, owner: keptOwner)
            }) != nil else {
                besideChatOpenFailed(kept: kept, owner: keptOwner)
                openListedSession(session)
                return
            }
            ensureKeptPluginReport(for: farDashboard)
            return
        }
        requestOpenSession(session.id) { [weak self] _ in
            self?.besideChatOpenFailed(kept: kept, owner: keptOwner)
        }
    }

    /// Opens the pane's chat in the chat's own column, and keeps the chat
    /// that was there beside it. A chat that can't stay beside (a Bot
    /// Chat, a group room) gives way: the pane's chat opens and the pane
    /// closes.
    func swapBesideChat() {
        guard let beside = besideChat,
              let target = beside.durableSessionID ?? beside.sessionIDs.sorted().first else { return }
        let targetOwner = besideChatOwner
        if let targetOwner, keptDashboardRuntimes[targetOwner.dashboardID]?.client.isConnected != true { return }
        guard keepChatOnScreenBeside() else {
            // Landing on it lets go of the followed copy, and the pane.
            _ = openKeptChatInMainColumn(target: target, owner: targetOwner, onFailure: nil)
            return
        }
        let kept = besideChatIDs
        let keptOwner = besideChatOwner
        if !openKeptChatInMainColumn(target: target, owner: targetOwner, onFailure: { [weak self] _ in
            self?.besideChatOpenFailed(kept: kept, owner: keptOwner)
        }) {
            besideChatOpenFailed(kept: kept, owner: keptOwner)
        }
    }

    /// Opens a kept chat (beside pane or chat window) in the main column on
    /// its own dashboard runtime. Returns `false` when a far dashboard's
    /// kept runtime cannot open it.
    func openKeptChatInMainColumn(
        target: String,
        owner: FarChatOwner?,
        onFailure: (@MainActor (_ sessionWasNotFound: Bool) -> Void)?
    ) -> Bool {
        if let owner {
            guard let runtime = keptRuntime(owner.dashboardID, on: owner.profile) else { return false }
            ensureKeptPluginReport(for: owner.dashboardID)
            widgetLaunchCoordinator.supersede()
            act(onRuntime: runtime) {
                requestOpenSession(target, onFailure: onFailure)
            }
            return true
        }
        requestOpenSession(target, onFailure: onFailure)
        return true
    }

    /// Closes the pane. Its chat goes on being followed only while a reply
    /// still runs in it, as any chat left mid-reply.
    func closeBesideChat() {
        guard let ids = besideChatIDs else { return }
        let owner = besideChatOwner
        besideChatIDs = nil
        besideChatOwner = nil
        letGoOfIdleFollowedChat(answering: ids, dashboardID: owner?.dashboardID ?? dashboardIDOnScreen)
    }

    /// The pane closes once its chat is followed no longer: opened in the
    /// chat's own column, deleted, or on a dashboard or profile left.
    func closeBesideChatWithoutItsChat() {
        if besideChatIDs != nil, besideChat == nil {
            besideChatIDs = nil
            besideChatOwner = nil
        }
        closeChatWindowsWithoutTheirChats()
    }

    /// Follows the chat on screen as the one kept beside, from now: what
    /// comes for it reaches the copy too, and leaving it takes a fresh one.
    /// False when it can't be followed, with the pane as it was.
    func keepChatOnScreenBeside() -> Bool {
        guard canKeepChatOnScreenBeside, let id = activeSessionId,
              let targetRuntime = farChat != nil ? chatOnScreenRuntime : runtimeOnScreen else { return false }
        let ids = act(onRuntime: targetRuntime) { followedSessionIDs(forChatOpenAs: id) }
        let previous = besideChatIDs
        let previousOwner = besideChatOwner
        let owner = farChat
        besideChatIDs = ids
        besideChatOwner = owner
        act(onRuntime: targetRuntime) {
            followChatOnScreen(answering: ids, openAs: id, turnRunning: turnState == .running, staysBeside: true)
        }
        guard besideChat != nil else {
            besideChatIDs = previous
            besideChatOwner = previousOwner
            return false
        }
        return true
    }

    /// The open beside a kept chat failed and left that chat on screen:
    /// it isn't also beside itself.
    private func besideChatOpenFailed(kept: Set<String>?, owner: FarChatOwner?) {
        guard let kept, besideChatIDs == kept, besideChatOwner == owner,
              let active = activeSessionId, farChat == owner else { return }
        let matchesKept = onChatRuntimeValue(unreachable: false) {
            kept.contains(active) || followedSessionIDs(forChatOpenAs: active) == kept
        }
        guard matchesKept else { return }
        let ownerDashboard = owner?.dashboardID ?? dashboardIDOnScreen
        besideChatIDs = nil
        besideChatOwner = nil
        backgroundChats.removeAll { $0.dashboardID == ownerDashboard && !$0.sessionIDs.isDisjoint(with: kept) }
    }

    func letGoOfIdleFollowedChat(answering ids: Set<String>, dashboardID: UUID? = nil) {
        let targetDashboard = dashboardID ?? activeDashboardID
        backgroundChats.removeAll { $0.dashboardID == targetDashboard && !$0.sessionIDs.isDisjoint(with: ids) && !$0.isRunning }
    }
}
