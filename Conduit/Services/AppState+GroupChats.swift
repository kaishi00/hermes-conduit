//
//  AppState+GroupChats.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Group Chats (hosted rooms).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Group Chats (hosted rooms)

    /// The profile the FOCUSED conversation runs on: the bot's own profile
    /// inside a Bot Chat, else the workspace profile. The mention middleware
    /// excludes that bot — it is the listener, never a mention target
    /// (upstream `focusedMentionProfile`).
    private var activeConversationProfileScope: String {
        if let sessionId = activeSessionId,
           let botProfile = botChatSessionProfiles[sessionId]?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !botProfile.isEmpty {
            return botProfile
        }
        return activeProfile
    }

    /// Upstream's canonical-forever-chat guard: `/new`, `/reset` or
    /// `/clear` inside a bot's canonical chat would fork the relationship
    /// into a scratch session — the one thing Bot Mode promises never
    /// happens. True ONLY
    /// when the active session is positively a bot's canonical chat (see
    /// `activeChatIsCanonicalBotChat`), whatever follows the command (`/new
    /// A title` is still a reset). No evidence, no reroute: ordinary
    /// sessions keep full `/new` freedom.
    func isCanonicalForeverChatReset(_ text: String) -> Bool {
        guard let command = Self.parseSlashCommand(text),
              ["new", "reset", "clear"].contains(command.name) else { return false }
        return activeChatIsCanonicalBotChat
    }

    /// Whether the open chat is a bot's canonical chat, by positive
    /// evidence: this process registered one of its ids when it opened the
    /// Bot Chat (the registry only ever holds canonical chats and the
    /// runtimes resuming them), or the roster's canonical id is one of the
    /// chat's own ids. A resume runs a Bot Chat under a fresh runtime id the
    /// roster never names, so the roster alone missed every reopened Bot
    /// Chat and `/new` forked it into a workspace chat (#1307).
    private var activeChatIsCanonicalBotChat: Bool {
        guard let sessionId = activeSessionId else { return false }
        let ids = chatOwnSessionIDs(for: sessionId).union([sessionId])
        return botOwnership.botProfileName(owningAny: ids) != nil
    }

    /// The composer's @mention middleware, shared by every routing path (a
    /// new turn, a busy steer, a redirect) so a mention typed while the bot
    /// is streaming is identified exactly like one sent at idle.
    func mentionAnnotatedOutboundText(_ text: String) -> String {
        // Quoted lines (#385) are not scanned for mentions; see
        // `middlewareAnnotation`. The whole text is sent.
        BotMentions.middlewareAnnotation(
            text: text,
            roster: shownBotRoster,
            activeProfileName: activeConversationProfileScope
        ) ?? text
    }

    /// What the composer's @ picker offers: the Bot Mode roster (the kept
    /// one until Hermes answers) minus the bot this conversation already
    /// talks to, tagged exactly as the middleware above resolves them.
    /// Empty without Bot Mode.
    var composerMentionCandidates: [MentionAutocomplete.Candidate] {
        MentionAutocomplete.botCandidates(shownBotRoster, activeProfileName: activeConversationProfileScope)
    }

    /// Presentation state for one open hosted room. A room is NOT a session:
    /// it never touches `activeSessionId`, the transcript cache, or the saved
    /// `SessionReference`, and it is deliberately NOT persisted — cold launch
    /// restores the remembered session, never a room. Session isolation is
    /// structural, not behavioral.
    struct GroupRoomSurface: Equatable {
        /// The dashboard this room belongs to; a stale dashboard's surface is
        /// fenced out at the server boundary.
        let dashboardID: UUID
        let room: GroupRoom
        /// Set for a room someone else hosts: the room screen reads your
        /// Hermes' copy of it (RoomCopies.swift), and nothing is sent to it.
        var copy: RoomCopy? = nil

        /// The thread a composer message starts: its own, named by its
        /// client event id, as Hermes Desktop sends one. The host routes and
        /// caps each thread as its own discussion, and routes (lead or
        /// automatic) only a message that opens a new thread, so a single
        /// shared thread would make every message after the first a reply
        /// that no routing ever sees. A retry keeps its event id, so it
        /// keeps its thread.
        static func threadID(forEventID eventID: String) -> String { eventID }
    }

    /// Lifecycle of the Group Chat capability probe.
    enum GroupChatPhase: Equatable {
        case idle
        case loading
        case available
        case gatewayUnsupported
        case failed(message: String)
    }

    static let roomCopyNameReadLimit = 5

    static let roomCopyPostWaitLimit = 20

    /// Between an ended copy's people reads for your name.
    static let roomPeopleRetryDelay: Duration = .seconds(2)

    /// The open room's members, with their owners and who's out. In a copy,
    /// your agents that are out are yours from its invite until the people
    /// read says so.
    var activeRoomMembers: [GroupMember] {
        var members = activeRoomSurface?.room.members ?? []
        if let copy = activeRoomSurface?.copy, let invite = linkedRoomInvite(copy.id), !invite.gone.isEmpty {
            members = GroupRoomTurns.members(members, gone: invite.gone)
        }
        return GroupRoomTurns.members(members, people: activeRoomPeople)
    }

    /// Where the user's answer to each of the open room's pending approvals
    /// stands, keyed by `GroupPendingApproval.id`. A sent answer stays for
    /// as long as the room is open, so a poll that started before it and
    /// lands later still listing the approval can't bring its card back.
    /// Ids are request-unique, so this grows by one per answer at most.
    enum RoomApprovalAnswer: Equatable {
        case submitting
        case sent
        case failed(String)
    }

    /// The open room's approvals still waiting on the user.
    var activeRoomPendingApprovals: [GroupPendingApproval] {
        guard groupCapabilities?.supports("groups.approve") == true else { return [] }
        return (activeRoomDriverStatus?.pendingApprovals ?? []).filter {
            roomApprovalAnswers[$0.id] != .sent
        }
    }

    /// The member whose turn the open room is running. A driver that reports
    /// idle or blocked names nobody. A host that lists its live turns
    /// (`member_activity`) says who outright; otherwise, and with no driver
    /// status yet (first load, or a gateway without one), the log decides.
    var activeRoomResponder: GroupMember? {
        if let driver = activeRoomDriverStatus, !driver.working || driver.blocked { return nil }
        let room = activeRoomSurface?.room
        if let activity = activeRoomDriverStatus?.memberActivity {
            return GroupRoomTurns.activeResponder(activity: activity, members: room?.members ?? [])
        }
        let key = "\(roomReplayKey)|\(room?.revision ?? -1)"
            + "|\(activeRoomDriverStatus?.maxRounds ?? 0)"
        let context = activeRoomContext
        if let cached = roomResponderCache, cached.key == key, cached.context == context { return cached.member }
        let member = GroupRoomTurns.pendingResponder(
            events: activeRoomReplay.events, members: room?.members ?? [], context: context,
            roundLimit: activeRoomDriverStatus?.maxRounds
        )
        roomResponderCache = (key, context, member)
        return member
    }

    /// Whether the open room's live member can answer: a member on another
    /// Hermes reads as cut off or unreachable while its route says so.
    var activeRoomResponderState: GroupResponderState {
        guard let member = activeRoomResponder, let driver = activeRoomDriverStatus else { return .responding }
        return driver.responderState(for: member, in: activeRoomSurface?.room.members ?? [])
    }

    /// Each member's pill under the open room's title, by `identityKey`
    /// (GroupRoomTurns.memberStatuses). A driver that reports idle has no
    /// live turns, so only outcomes and approvals show.
    ///
    /// Kept for its inputs, like `activeRoomResponder`: the room's header
    /// asks on every render, and every publish elsewhere renders it, while
    /// the walk goes through the whole log with mention matching and
    /// hashing (issue 1968).
    var activeRoomMemberStatuses: [String: GroupMemberStatus] {
        let inputs = RoomMemberStatusInputs(
            replay: roomReplayKey,
            activity: activeRoomDriverStatus?.memberActivity,
            working: activeRoomDriverStatus?.working,
            responder: activeRoomResponder,
            approvals: activeRoomPendingApprovals,
            members: activeRoomSurface?.room.members ?? [],
            context: activeRoomContext
        )
        if let cached = roomMemberStatusCache, cached.inputs == inputs { return cached.statuses }
        let statuses = GroupRoomTurns.memberStatuses(
            events: activeRoomReplay.events,
            activity: inputs.activity,
            working: inputs.working,
            responder: inputs.responder,
            approvals: inputs.approvals,
            members: inputs.members,
            context: inputs.context
        )
        roomMemberStatusCache = (inputs, statuses)
        return statuses
    }

    /// Whether the open room's newest message settled, for its title. Not
    /// while one is on its way. Kept for the log it read (issue 1968).
    var activeRoomSettled: Bool {
        let key = "\(roomReplayKey)|\(pendingRoomMessage != nil)"
        if let cached = roomSettledCache, cached.key == key { return cached.settled }
        let settled = GroupRoomTurns.latestDiscussionSettled(activeRoomReplay.events, sending: pendingRoomMessage != nil)
        roomSettledCache = (key, settled)
        return settled
    }

    /// Which log the open room's replay holds: its room and how many times
    /// it has changed, so any append, trim or replacement reads it again.
    private var roomReplayKey: String {
        "\(activeRoomReplay.roomID)|\(roomReplayRevision)"
    }

    struct RoomMemberStatusInputs: Equatable {
        let replay: String
        let activity: [GroupMemberActivity]?
        let working: Bool?
        let responder: GroupMember?
        let approvals: [GroupPendingApproval]
        let members: [GroupMember]
        let context: GroupRoomContext?
    }

    /// The open room's settings, as `groups.state` last gave them (or a
    /// save here). Nil until the host answers, or on a host without them.
    var activeRoomContext: GroupRoomContext? { activeRoomDriverStatus?.roomContext }

    /// Whether the open room's settings can be changed here.
    var canEditActiveRoomSettings: Bool {
        groupCapabilities?.supports("groups.context") == true && activeRoomContext != nil
            && activeRoomSurface.map { !$0.room.isDisbanded } == true
    }

    /// The who-answers modes the host offers; empty on a host that routes
    /// every message to everyone, whose rooms keep only purpose and notes.
    var activeRoomRoutingModes: [GroupRouting] {
        (activeRoomDriverStatus?.routingModes ?? []).compactMap(GroupRouting.init(rawValue:))
    }

    /// The pending discussion's routing while it is still being picked:
    /// a lead's routing turn or the router's call (the room's subtitle).
    /// The router's call runs before any turn, so the driver can read idle
    /// meanwhile: the log alone says it's choosing.
    var activeRoomPendingRoute: GroupRoomTurns.DiscussionRoute? {
        guard let route = GroupRoomTurns.pendingRoute(
            events: activeRoomReplay.events, members: activeRoomSurface?.room.members ?? [], context: activeRoomContext
        ) else { return nil }
        switch route {
        case .leadChoosing, .routerChoosing: return route
        case .unrouted, .routed: return nil
        }
    }

    /// The open room's discussions paused at their cap that Continue can
    /// reopen, by the cap's event id (its caption carries the button).
    var activeRoomContinuablePauses: [String: (discussionEventID: String, grant: Int)] {
        guard groupCapabilities?.supports("groups.continue") == true,
              let maxContinues = activeRoomDriverStatus?.maxContinues, maxContinues > 0 else { return [:] }
        return GroupRoomTurns.continuablePauses(events: activeRoomReplay.events).filter { $0.value.grant <= maxContinues }
    }

    /// Tests stand in for the plugin's rooms routes.
    var roomRouteIsStubbed: Bool { groupChatOperations.roomRoute != nil }

    /// A rooms route of the plugin (the drafts, the Links): the injectable
    /// seam first (tests), then the dashboard bridge.
    func roomRouteJSON(path: String, method: String, body: [String: Any]?, timeoutMilliseconds: Int?)
        async throws -> [String: Any] {
        if let route = groupChatOperations.roomRoute { return try await route(path, method, body, timeoutMilliseconds) }
        guard let bridge = dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
        if let timeoutMilliseconds {
            return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeoutMilliseconds)
        }
        return try await bridge.requestJSON(path: path, method: method, body: body)
    }

    // Group Chat RPC routing: the injectable seam first (tests), then the
    // production client call.
    private func groupsCapabilities(_ client: HermesClient) async throws -> GroupCapabilities {
        if let operation = groupChatOperations.capabilities { return try await operation(client) }
        return try await client.groupsCapabilities()
    }

    private func groupsList(_ client: HermesClient) async throws -> ([GroupRoom], Int?) {
        if let operation = groupChatOperations.list { return try await operation(client) }
        return try await client.groupsList()
    }

    private func groupsState(_ client: HermesClient, roomID: String)
        async throws -> (GroupRoom, GroupDriverStatus?) {
        if let operation = groupChatOperations.state { return try await operation(client, roomID) }
        return try await client.groupsState(roomID: roomID)
    }

    private func groupsLog(_ client: HermesClient, roomID: String, sinceSeq: Int, limit: Int? = nil)
        async throws -> GroupLogPage {
        if let operation = groupChatOperations.log { return try await operation(client, roomID, sinceSeq, limit) }
        return try await client.groupsLog(roomID: roomID, sinceSeq: sinceSeq, limit: limit, includeDisbanded: true)
    }

    private func groupsSend(
        _ client: HermesClient,
        roomID: String,
        eventID: String,
        text: String,
        threadID: String,
        attachments: [GroupRoomAttachment] = []
    ) async throws -> GroupSendResult {
        if let operation = groupChatOperations.send {
            groupChatOperations.sendAttachments?(attachments)
            return try await operation(client, roomID, eventID, text, threadID)
        }
        return try await client.groupsSend(
            roomID: roomID, eventID: eventID, text: text, threadID: threadID, attachments: attachments
        )
    }

    func groupsAttachmentUpload(
        _ client: HermesClient, roomID: String, uploadID: String, kind: String, name: String, mime: String, dataBase64: String
    ) async throws -> GroupRoomAttachment {
        if let operation = groupChatOperations.uploadAttachment {
            return try await operation(client, roomID, uploadID, kind, name, mime, dataBase64)
        }
        return try await client.groupsAttachmentUpload(
            roomID: roomID, uploadID: uploadID, kind: kind, name: name, mime: mime, dataBase64: dataBase64
        )
    }

    func groupsAttachmentDownload(
        _ client: HermesClient, roomID: String, eventID: String, attachmentID: String, size: Int = 0
    ) async throws -> String {
        if let operation = groupChatOperations.downloadAttachment {
            return try await operation(client, roomID, eventID, attachmentID, size)
        }
        return try await client.groupsAttachmentDownload(
            roomID: roomID, eventID: eventID, attachmentID: attachmentID, size: size
        )
    }

    private func groupsCreate(_ client: HermesClient, roomID: String, name: String, members: [[String: Any]])
        async throws -> GroupRoom {
        if let operation = groupChatOperations.create { return try await operation(client, roomID, name, members) }
        return try await client.groupsCreate(roomID: roomID, name: name, members: members)
    }

    private func groupsStop(_ client: HermesClient, roomID: String) async throws -> Int {
        if let operation = groupChatOperations.stop { return try await operation(client, roomID) }
        return try await client.groupsStop(roomID: roomID)
    }

    private func groupsApprove(
        _ client: HermesClient, roomID: String, approval: GroupPendingApproval, choice: String
    ) async throws -> Bool {
        if let operation = groupChatOperations.approve {
            return try await operation(client, roomID, approval, choice)
        }
        return try await client.groupsApprove(roomID: roomID, approval: approval, choice: choice)
    }

    private func groupsDisband(_ client: HermesClient, roomID: String) async throws {
        if let operation = groupChatOperations.disband { return try await operation(client, roomID) }
        return try await client.groupsDisband(roomID: roomID)
    }

    func invalidateGroupChatState() {
        groupChatPhase = .idle
        groupChatProbeRetry.succeeded()
        groupCapabilities = nil
        // Group Settings asked for on the outgoing server isn't for this one.
        groupSettingsOnOpen = nil
        // Whether the gateway can make pictures is the outgoing one's answer.
        canGeneratePictures = false
        groupRoomsListed = false
        groupRoomsComplete = false
        groupRooms = []
        // Faces read from the outgoing server aren't this one's.
        homeRoomLooksByKey = [:]
        homeRoomLooksReadAt = [:]
        linkedRoomDrafts = nil
        linkedRoomInvites = nil
        linkedRoomInviteFollow?.cancel()
        linkedRoomInviteFollow = nil
        presentedRoomInvite = nil
        linkedRoomApprovals = nil
        answeredLinkedRoomApprovalIDs = []
        presentedRoomApproval = nil
        linkedRoomCopies = nil
        // Shared again after a sign-in: that Hermes may have lost them.
        sharedRoomLooks = [:]
        roomLookPictures = [:]
        talkingRoomIDs = []
        desktopGroupChats = []
        groupRoomPictureData = [:]
        groupRoomPictureRevisions = [:]
        // Identity/sign-out teardown: the caller owns `errorMessage` (it may
        // have just set a connection error), so the room must not wipe it.
        // Parked sends and drafts belong to the outgoing identity.
        closeRoomSurface(clearingRoomError: false, parkingPendingSend: false)
        parkedRoomOutboxes.removeAll()
        groupRoomDrafts.removeAll()
        keptRoomReplays.removeAll()
        dropRoomAttachments { _ in true }
        // A send still awaiting its reply belongs to the outgoing identity;
        // its defer's removal is a no-op once the key is gone.
        inFlightRoomSendTokens.removeAll()
    }

    private static func roomKey(dashboardID: UUID, roomID: String) -> String {
        "\(dashboardID.uuidString)|\(roomID)"
    }

    /// A room's key, by its Link too for a copy: room ids are only unique
    /// per host.
    private static func roomKey(for surface: GroupRoomSurface) -> String {
        roomKey(dashboardID: surface.dashboardID, roomID: surface.copy?.id ?? surface.room.roomID)
    }

    /// Move the open room's pending send (if any) into the parked store, and
    /// keep its events to show when it opens again.
    private func parkActiveRoomSend() {
        guard let surface = activeRoomSurface else { return }
        let key = Self.roomKey(for: surface)
        if activeRoomReplay.roomID == surface.room.roomID, !activeRoomReplay.events.isEmpty {
            keptRoomReplays[key] = activeRoomReplay
        }
        if groupRoomOutbox.pending != nil {
            parkedRoomOutboxes[key] = groupRoomOutbox
        } else {
            parkedRoomOutboxes.removeValue(forKey: key)
        }
        if activeRoomReplay.roomID == surface.room.roomID, !activeRoomReplay.events.isEmpty {
            keptRoomReplays[key] = activeRoomReplay
            keptRoomReplayOrder.removeAll { $0 == key }
            keptRoomReplayOrder.append(key)
            // Up to 400 events each: the rooms left longest ago go past
            // `maxKeptRoomReplays`, never one with a send still parked
            // (issue 1969).
            for dropped in Self.keptRoomReplaysToDrop(
                order: keptRoomReplayOrder.filter { keptRoomReplays[$0] != nil },
                pinned: Set(parkedRoomOutboxes.keys)
            ) {
                keptRoomReplays.removeValue(forKey: dropped)
            }
            keptRoomReplayOrder.removeAll { keptRoomReplays[$0] == nil }
        }
    }

    /// Rooms whose events stay in memory after they're left, to show at
    /// once when they open again; as many as Bot Chats' kept copies.
    static let maxKeptRoomReplays = 8

    /// The kept room replays to drop: the least recently left first, past
    /// `limit`, skipping any room `pinned` names (a parked send settles
    /// against its events).
    static func keptRoomReplaysToDrop(order: [String], pinned: Set<String>, limit: Int = maxKeptRoomReplays) -> [String] {
        var excess = order.count - limit
        guard excess > 0 else { return [] }
        var dropped: [String] = []
        for key in order where excess > 0 && !pinned.contains(key) {
            dropped.append(key)
            excess -= 1
        }
        return dropped
    }

    /// Drop parked sends and drafts of this dashboard's rooms that left the
    /// room list (disbanded elsewhere): they can never be reopened.
    private func pruneRoomStores(liveRoomIDs: Set<String>) {
        guard let dashboardID = activeDashboardID else { return }
        let prefix = "\(dashboardID.uuidString)|"
        // Rooms other people host (keyed by Link and room, with a slash)
        // are kept by their copies, not this list, and until those are read.
        let copies = readLinkedRoomCopyIDs
        func isGone(_ key: String) -> Bool {
            guard key.hasPrefix(prefix) else { return false }
            let id = String(key.dropFirst(prefix.count))
            if id.contains("/") { return copies.map { !$0.contains(id) } ?? false }
            return !liveRoomIDs.contains(id)
        }
        parkedRoomOutboxes = parkedRoomOutboxes.filter { !isGone($0.key) }
        groupRoomDrafts = groupRoomDrafts.filter { !isGone($0.key) }
        keptRoomReplays = keptRoomReplays.filter { !isGone($0.key) }
        dropRoomAttachments(where: isGone)
    }

    /// Drops the staged files of the rooms `isDropped` names, and their
    /// local copies.
    private func dropRoomAttachments(where isDropped: (String) -> Bool) {
        for (key, files) in groupRoomAttachments where isDropped(key) {
            files.forEach(ComposerBar.discardStagedFile)
            groupRoomAttachments.removeValue(forKey: key)
        }
    }

    /// Close a room that no longer exists (disbanded or not found): nothing
    /// is parked for it, and its draft goes too — it can never be reopened.
    private func closeGoneRoomSurface() {
        if let surface = activeRoomSurface {
            let key = Self.roomKey(for: surface)
            parkedRoomOutboxes.removeValue(forKey: key)
            groupRoomDrafts.removeValue(forKey: key)
            keptRoomReplays.removeValue(forKey: key)
            dropRoomAttachments { $0 == key }
        }
        closeRoomSurfaceBackToChat(parkingPendingSend: false)
    }

    /// Close the room onto the chat under it, which shows what its sync said
    /// while the room covered it (`chatErrorBehindRoom`). Opening another
    /// chat or a new one closes the room with `closeRoomSurface` instead,
    /// which drops that error.
    private func closeRoomSurfaceBackToChat(parkingPendingSend: Bool = true) {
        let chatError = chatErrorBehindRoom
        closeRoomSurface(parkingPendingSend: parkingPendingSend)
        if let chatError {
            errorMessage = chatError
        }
    }

    /// Settle the open room's pending send when `events` carry its
    /// server-side twin: an ambiguous send that landed, seen by a poll, a
    /// resync, or a reopen's tail.
    private func settlePendingRoomSend(from events: [GroupEvent]) {
        guard groupRoomOutbox.settle(from: events) else { return }
        pendingRoomMessage = groupRoomOutbox.pending
        clearRoomSendError()
    }

    /// Retire the send-failure banner, and only that banner: an unrelated
    /// room error (a failed stop or disband) stays up.
    private func clearRoomSendError() {
        if let sendError = roomSendErrorMessage, errorMessage == sendError {
            errorMessage = nil
        }
        roomSendErrorMessage = nil
    }

    private func showRoomSendError(_ message: String) {
        errorMessage = message
        roomSendErrorMessage = message
    }

    /// Whether the open room takes a quote: one that is still running.
    func canQuoteIntoRoom() -> Bool {
        // A room someone else hosts has a composer while it takes your posts.
        if activeRoomSurface?.copy != nil { return activeRoomCopyTakesPosts }
        return activeRoomSurface?.room.isDisbanded == false
    }

    /// Selected room text goes into the room's draft as a `>` quote, with
    /// its tags defanged so quoting doesn't address anyone.
    func quoteIntoRoomComposer(_ selectedText: String) {
        guard canQuoteIntoRoom() else { return }
        let quote = ChatQuote.blockquote(GroupRoomMentions.defanged(selectedText))
        guard !quote.isEmpty else { return }
        roomQuoteRequest = ComposerQuoteRequest(content: .text(quote))
    }

    /// A room message's Reply button: the whole message rides along with
    /// the next one, shown in the room composer as a "Replying to…" chip,
    /// and the bot that wrote it is picked in the "To" row.
    func replyInRoomComposer(text: String, authorName: String, authorHandle: String? = nil, threadID: String? = nil) {
        guard canQuoteIntoRoom(), text.contains(where: { !$0.isWhitespace }) else { return }
        let thread = threadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        roomQuoteRequest = ComposerQuoteRequest(
            content: .reply(ComposerReplyReference(
                authorName: authorName, text: text, threadID: thread?.isEmpty == false ? thread : nil
            ))
        )
        if let authorHandle { mentionInRoomComposer(handle: authorHandle) }
    }

    /// Picks a bot in the room composer's "To" row.
    func mentionInRoomComposer(handle: String) {
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canQuoteIntoRoom(), !handle.isEmpty else { return }
        roomRecipientRequest = RoomRecipientRequest(handle: handle)
    }

    func consumeRoomRecipientRequest(_ id: UUID) {
        guard roomRecipientRequest?.id == id else { return }
        roomRecipientRequest = nil
    }

    /// The roster bot a room member is (GroupRoomTurns.rosterBot).
    func groupMemberBot(_ member: GroupMember?, name: String) -> BotProfile? {
        GroupRoomTurns.rosterBot(for: member, name: name, in: shownBotRoster)
    }

    /// Each member's color by `identityKey`: its bot's glow on Bots Home
    /// (`botColor`: the color picked for it or drawn from its photo, else
    /// its color in Hermes), another person's agent's as their Conduit
    /// draws it (RoomLooks), else the hue its picture falls back to, so a
    /// bot looks the same on its tile, in its name, its bubble and the tags
    /// that name it.
    func groupMemberTints(_ members: [GroupMember]) -> [String: CustomAccentColor] {
        var tints: [String: CustomAccentColor] = [:]
        let glows = profileGlowColors()
        for member in members {
            let key = member.identityKey
            guard !key.isEmpty, tints[key] == nil else { continue }
            let name = GroupRoomTurns.displayName(of: member)
            let bot = groupMemberBot(member, name: name)
            // Another person's agent: the color its owner's Conduit draws it in.
            if bot == nil, let tint = activeRoomLooks.member(member)?.tint {
                tints[key] = tint
                continue
            }
            let color = UIColor(Self.groupMemberColor(bot: bot, name: name, glows: glows))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { continue }
            tints[key] = CustomAccentColor(red: Double(red), green: Double(green), blue: Double(blue))
        }
        return tints
    }

    /// A room member's color: its bot's (`botColor`, the glow first), else
    /// its name's hue.
    static func groupMemberColor(bot: BotProfile?, name: String, glows: [String: ProfileGlowRGB]) -> Color {
        guard let bot else { return BotAvatarView.color(for: nil, name: name) }
        return botColor(bot, glow: glows[bot.name])
    }

    /// The room composer took the quote.
    func consumeRoomQuoteRequest(_ id: UUID) {
        guard roomQuoteRequest?.id == id else { return }
        roomQuoteRequest = nil
    }

    /// The open room's unsent composer text.
    func activeRoomDraft() -> String {
        guard let surface = activeRoomSurface else { return "" }
        return groupRoomDrafts[Self.roomKey(for: surface)] ?? ""
    }

    /// Keep the open room's composer text so leaving and reopening the room
    /// restores it. Empty text drops the entry.
    func saveActiveRoomDraft(_ text: String) {
        guard let surface = activeRoomSurface else { return }
        let key = Self.roomKey(for: surface)
        if text.isEmpty {
            groupRoomDrafts.removeValue(forKey: key)
        } else {
            groupRoomDrafts[key] = text
        }
    }

    /// A dictation Retry's words for a room's draft, after what it holds.
    /// The open composer keeps its draft here as it changes, so the words
    /// reach whichever composer shows the room now, or wait for reopen.
    /// False when the room can't be confirmed (disbanded, off the room
    /// list, or on a dashboard no longer active): the caller keeps the
    /// recording, offered again for a Retry.
    @discardableResult
    func appendToRoomDraft(_ words: String, dashboardID: UUID, roomID: String) -> Bool {
        // The open room counts even when the list missed it (a new room
        // whose list refresh failed).
        let isOpen = activeRoomSurface.map {
            $0.dashboardID == dashboardID && $0.room.roomID == roomID && !$0.room.isDisbanded
        } ?? false
        guard dashboardID == activeDashboardID,
              isOpen || groupRooms.contains(where: { $0.roomID == roomID && !$0.isDisbanded }) else {
            return false
        }
        // The open room's own key: a room hosted elsewhere keeps its draft
        // by its Link too, as its composer reads it.
        let openKey = isOpen ? activeRoomSurface.map(Self.roomKey(for:)) : nil
        let key = openKey ?? Self.roomKey(dashboardID: dashboardID, roomID: roomID)
        let text = ComposerDictation.draft(before: groupRoomDrafts[key] ?? "", dictated: words)
        guard !text.isEmpty else { return true }
        groupRoomDrafts[key] = text
        roomDraftAppend = RoomDraftAppend(dashboardID: dashboardID, roomID: roomID, words: words)
        return true
    }

    /// The files staged in the open room's composer.
    func activeRoomAttachments() -> [Attachment] {
        guard let surface = activeRoomSurface else { return [] }
        return groupRoomAttachments[Self.roomKey(for: surface)] ?? []
    }

    /// Keep the open room's staged files with its text, so leaving and
    /// reopening the room brings them back. The composer deletes the local
    /// copy of a file it removes or sends.
    func saveActiveRoomAttachments(_ attachments: [Attachment]) {
        guard let surface = activeRoomSurface else { return }
        let key = Self.roomKey(for: surface)
        if attachments.isEmpty {
            groupRoomAttachments.removeValue(forKey: key)
        } else {
            groupRoomAttachments[key] = attachments
        }
    }

    /// Drop the room surface AND stop its poller. The complete teardown —
    /// every path that closes a room (navigation, disband, poll-detected
    /// disband, server-identity invalidation) funnels here, so a closed room
    /// can never leave a polling task spinning behind it.
    ///
    /// Clears `errorMessage` by default: a room's error must not outlive the
    /// room and surface over the session composer.
    ///
    /// Parks the room's pending send by default (see `parkedRoomOutboxes`).
    ///
    /// `handingTo`: what is opening in the room's place (`roomHandedTo`).
    func closeRoomSurface(clearingRoomError: Bool = true, parkingPendingSend: Bool = true,
                                  handingTo: RoomHandoff = .none) {
        roomHandedTo = handingTo
        if clearingRoomError, activeRoomSurface != nil {
            errorMessage = nil
        }
        if parkingPendingSend {
            parkActiveRoomSend()
        }
        groupRoomEpoch &+= 1
        groupRoomPollTask?.cancel()
        groupRoomPollTask = nil
        activeRoomLogRead = nil
        activeRoomSurface = nil
        chatErrorBehindRoom = nil
        activeRoomReplay = GroupRoomReplay(roomID: "")
        activeRoomDriverStatus = nil
        activeRoomPeople = [:]
        activeRoomLooks = .empty
        activeRoomHomeName = nil
        activeRoomLooksReadAt = nil
        activeRoomPeopleRetries = 0
        activeRoomPeopleReadFailed = false
        activeRoomPostAttribution = .none
        activeRoomCopyPost = nil
        roomApprovalAnswers = [:]
        activeRoomSendInFlight = false
        groupRoomOutbox.discard()
        pendingRoomMessage = nil
        roomSendErrorMessage = nil
        // A quote or drop the closed room's composer never took must not
        // land in the next room opened.
        roomQuoteRequest = nil
        roomDraftHandBack = nil
        roomDropRequest = nil
    }

    /// Probe `groups.capabilities` and, when the foundation methods are
    /// advertised, refresh the room list, then the drafts of rooms with
    /// people you've linked (not with each room list read, which a room's
    /// send and poll make). Called alongside the bot roster refresh; a
    /// gateway that lacks the method is a supported outcome, not an error.
    /// The response is epoch- AND dashboard-fenced: an in-flight probe must
    /// never resurrect the outgoing server's phase on the new dashboard's
    /// surface.
    func refreshGroupChatSupport() async {
        guard let client, isConnected else {
            groupChatPhase = .idle
            return
        }
        let epoch = groupRoomEpoch
        let dashboard = activeDashboardID
        do {
            let capabilities = try await groupsCapabilities(client)
            guard groupRoomEpoch == epoch, activeDashboardID == dashboard else { return }
            groupCapabilities = capabilities
            groupChatProbeRetry.succeeded()
            guard capabilities.foundationSupported else {
                groupChatPhase = .gatewayUnsupported
                groupRooms = []
                return
            }
            groupChatPhase = .available
            // Only the capabilities gate the rest, which are reads of their
            // own, each fenced by its own epoch and dashboard: they go
            // together, so a cold open waits for the slowest, not the sum
            // (issue 2153). The copies go before the invites, which read
            // them again for a started invite with no copy yet.
            async let rooms: Void = refreshGroupRooms()
            async let drafts: Void = refreshLinkedRoomDrafts()
            async let approvals = refreshLinkedRoomApprovals()
            async let joined: Void = refreshLinkedRoomCopiesThenInvites()
            _ = await (rooms, drafts, approvals, joined)
            // A room on its way when Conduit connects (a launch, a reconnect,
            // a foreground read that ran before the connection) is followed
            // from here, or it would show only on the next reload.
            guard groupRoomEpoch == epoch, activeDashboardID == dashboard else { return }
            followLinkedRoomsOnTheirWay()
        } catch is CancellationError {
            return
        } catch {
            guard groupRoomEpoch == epoch, activeDashboardID == dashboard, !Task.isCancelled else { return }
            if HermesClient.isMissingRPCMethod(error) {
                groupCapabilities = nil
                groupChatPhase = .gatewayUnsupported
                groupRooms = []
            } else if groupChatPhase != .available {
                groupChatPhase = .failed(message: UserFacingError.message(for: error))
                groupChatProbeRetry.schedule { [weak self] in
                    guard let self, self.isConnected, self.groupRoomEpoch == epoch,
                          self.activeDashboardID == dashboard,
                          case .failed = self.groupChatPhase else { return }
                    await self.refreshGroupChatSupport()
                }
            }
            // A transient failure while already .available keeps the last
            // known rooms and phase — same contract as the roster notice.
        }
    }

    /// The rooms you joined, then the invites, which read the copies again
    /// only for a started invite whose copy isn't there yet.
    private func refreshLinkedRoomCopiesThenInvites() async {
        await refreshLinkedRoomCopies()
        await refreshLinkedRoomInvites()
    }

    func refreshGroupRooms() async {
        guard groupChatPhase == .available, let client, isConnected else { return }
        let epoch = groupRoomEpoch
        var stayed: KeptGroupRooms?
        do {
            // Kept for the Bots list to open on, with the pictures (#1533),
            // when they changed: a room's send reads the list again, and
            // keeping it encodes up to a megabyte of pictures on the main
            // actor, which an unchanged list needn't pay (issue 2152).
            _ = try await keepingRead(as: KeptRoute.groupRooms, profile: KeptRoute.everyProfile,
                                      owner: currentDashboardRuntimeOwner(),
                                      unchanged: { [weak self] rooms in
                                          guard let self, self.keptGroupRooms() == rooms else { return false }
                                          stayed = rooms
                                          return true
                                      }) {
                let (rooms, nextOffset) = try await self.groupsList(client)
                guard self.groupRoomEpoch == epoch else { throw CancellationError() }
                if !self.groupRoomsListed {
                    self.adoptKeptGroupRoomPictures()
                    self.groupRoomsListed = true
                }
                self.groupRooms = rooms.filter { !$0.isDisbanded }
                self.groupRoomsComplete = nextOffset == nil
                // Only a complete list proves a room is gone: a partial page
                // (next_offset set) must not drop another room's retry key.
                if nextOffset == nil {
                    self.pruneRoomStores(liveRoomIDs: Set(self.groupRooms.map(\.roomID)))
                }
                await self.refreshGroupRoomPictures()
                guard self.groupRoomEpoch == epoch else { throw CancellationError() }
                return self.keptGroupRoomsNow()
            }
            // Its turn moved on with nothing written: the decoded copy
            // still stands, so the next send's compare decodes nothing.
            if let stayed { keptGroupRoomsStayed(stayed) }
        } catch is CancellationError {
            return
        } catch {
            // Keep the last known room list; the roster surfaces the probe
            // failure path, and a stale room row is safer than an empty one.
        }
        // How your bots and you look in rooms over Links, when that changed.
        await shareRoomLooksIfNeeded()
    }

    /// The most rooms Bots Home asks after at once: the ones talked in
    /// last (`updatedAt`), so a host with many rooms isn't asked about each.
    static let talkingRoomsRead = 8

    /// A talking room that doesn't answer stays talking for this many reads.
    static let talkingRoomMissesKept = 3

    /// `refreshTalkingRooms`, unless one began within `every` (less a
    /// second's slack): Bots Home and a bot's overview both ask on their
    /// own clocks, and the rooms are read once each round, not by each.
    func refreshTalkingRoomsIfDue(every: Duration) async {
        // Offline nothing is read, and the first ask back reads at once.
        guard isConnected else {
            talkingRoomsReadAt = nil
            await refreshTalkingRooms()
            return
        }
        let interval = Double(every.components.seconds) - 1
        if let at = talkingRoomsReadAt, Date().timeIntervalSince(at) < interval { return }
        talkingRoomsReadAt = Date()
        await refreshTalkingRooms()
        // Rooms someone else hosts say they're working in their copies,
        // read on the same tick so their rings come and go with these.
        if !linkedRoomCopyRows.isEmpty { await refreshLinkedRoomCopies() }
    }

    /// Which hosted rooms are talking now: one `groups.state` per room
    /// (its driver's `working`), the rooms updated last first. Bots Home
    /// reads it while it shows. An unanswered room keeps what it was.
    func refreshTalkingRooms() async {
        // Bots Home and a bot's overview both ask; one read at a time.
        guard !talkingRoomsReading else { return }
        talkingRoomsReading = true
        defer { talkingRoomsReading = false }
        guard groupChatPhase == .available, groupRoomsListed, let client, isConnected else {
            if !talkingRoomIDs.isEmpty { talkingRoomIDs = [] }
            talkingRoomMisses = [:]
            // Asked again as soon as it can answer.
            talkingRoomsReadAt = nil
            return
        }
        let epoch = groupRoomEpoch
        let rooms = groupRooms.filter { !$0.isDisbanded }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.talkingRoomsRead)
        var talking = Set<String>()
        // Only the rooms read this pass keep a count, so one that left
        // the read rooms starts over when it comes back.
        var misses: [String: Int] = [:]
        for room in rooms {
            do {
                let (_, driver) = try await groupsState(client, roomID: room.roomID)
                if driver?.working == true { talking.insert(room.roomID) }
            } catch is CancellationError {
                // Cut short: the next ask reads again at once.
                talkingRoomsReadAt = nil
                return
            } catch {
                // Kept through a couple of misses, not for good.
                let missed = (talkingRoomMisses[room.roomID] ?? 0) + 1
                misses[room.roomID] = missed
                if talkingRoomIDs.contains(room.roomID), missed < Self.talkingRoomMissesKept {
                    talking.insert(room.roomID)
                }
            }
            guard groupRoomEpoch == epoch, self.client === client else { return }
        }
        talkingRoomMisses = misses
        if talking != talkingRoomIDs { talkingRoomIDs = talking }
    }

    /// The talking rooms `profile` is a member of, talked in last first.
    func talkingRooms(of profile: String) -> [GroupRoom] {
        guard !talkingRoomIDs.isEmpty else { return [] }
        return talkingRooms.filter { room in
            room.members.contains { $0.profile?.caseInsensitiveCompare(profile) == .orderedSame }
        }
    }

    /// The talking rooms, talked in last first.
    var talkingRooms: [GroupRoom] {
        guard !talkingRoomIDs.isEmpty else { return [] }
        return groupRooms.filter { talkingRoomIDs.contains($0.roomID) && !$0.isDisbanded }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Keeps the listed rooms and their pictures as they are now, as a
    /// write: a picture set or removed here is what the Bots list opens on
    /// next.
    func keepGroupRoomPictures() {
        guard groupRoomsListed, let owner = currentDashboardRuntimeOwner(),
              let data = try? JSONEncoder().encode(keptGroupRoomsNow()),
              let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        keepWrittenAnswer(answer, for: KeptRoute.groupRooms, profile: KeptRoute.everyProfile, owner: owner, removals: offlineChatCache.removals)
    }

    /// The Bots list's hosted rooms: `groups.list`'s, else the kept ones
    /// until it answers, none once Hermes says it has no hosted rooms; in
    /// the person's order (`groupRoomOrder`), the rooms it doesn't name yet
    /// first, as Hermes lists them, so a room just made lands at the top
    /// where Hermes puts it.
    var shownGroupRooms: [GroupRoom] {
        let rooms = groupRoomsListed || groupChatPhase == .gatewayUnsupported
            ? groupRooms
            : keptGroupRooms()?.rooms ?? []
        return groupRoomOrder.arrange(rooms, name: \.roomID)
    }

    /// The rooms kept on this dashboard, decoded once per answer kept.
    func keptGroupRooms() -> KeptGroupRooms? {
        let key = keptGroupRoomsMemoKey
        if let memo = keptGroupRoomsMemo, memo.key == key { return memo.rooms }
        let rooms = keptRead(KeptGroupRooms.self, KeptRoute.groupRooms, profile: KeptRoute.everyProfile)
        keptGroupRoomsMemo = (key, rooms)
        return rooms
    }

    private var keptGroupRoomsMemoKey: String {
        let turn = keptAnswerTurn(KeptRoute.groupRooms, profile: KeptRoute.everyProfile)
        return "\(activeDashboardID?.uuidString ?? "-")|\(offlineChatCache.removals)|\(turn)"
    }

    /// A read the same as the kept rooms moved their turn on without
    /// writing them (keepingRead's `unchanged`): what's kept is still
    /// `rooms`, under the new turn.
    private func keptGroupRoomsStayed(_ rooms: KeptGroupRooms) {
        keptGroupRoomsMemo = (key: keptGroupRoomsMemoKey, rooms: rooms)
    }

    /// Opens the room a notification names (issue 2064), as Hermes lists
    /// it: the list on hand when it has the room, else read again first.
    /// A room the list still lacks is asked about itself, since a list kept
    /// from before a read that failed, or the first page of a long one,
    /// doesn't prove it gone. Only Hermes saying so (or hosting no rooms)
    /// drops the tap; a list or room that can't be read yet is tried again.
    func openNotificationRoom(_ roomID: String) async -> NotificationOpenOutcome {
        guard let client, isConnected else { return .retry }
        let dashboardID = activeDashboardID
        // A chat or room opened while Hermes is asked owns the screen: the
        // tap is dropped, not opened over it.
        let viewport = chatViewportTransitionGeneration
        let roomEpoch = groupRoomEpoch
        var superseded: Bool { chatViewportTransitionGeneration != viewport || groupRoomEpoch != roomEpoch }
        if !groupRoomsListed || !groupRooms.contains(where: { $0.roomID == roomID }) {
            if groupCapabilities == nil {
                await refreshGroupChatSupport()
            } else {
                await refreshGroupRooms()
            }
            guard !Task.isCancelled, activeDashboardID == dashboardID else { return .retry }
            if superseded { return .failed }
        }
        var listed = groupRooms.first(where: { $0.roomID == roomID })
        if listed == nil {
            if groupChatPhase == .gatewayUnsupported {
                errorMessage = AppLocalization.string("That chat is no longer available.")
                return .failed
            }
            // No list read yet: the room opens from it once one is.
            guard groupRoomsListed, self.client === client, isConnected else { return .retry }
            do {
                let (state, _) = try await groupsState(client, roomID: roomID)
                guard !Task.isCancelled, activeDashboardID == dashboardID else { return .retry }
                if superseded { return .failed }
                listed = state
            } catch {
                guard !Task.isCancelled, activeDashboardID == dashboardID else { return .retry }
                // Not the old tap's error over what opened since.
                if superseded { return .failed }
                guard HermesClient.isRoomNotFoundError(error) else { return .retry }
            }
        }
        guard let room = listed, !room.isDisbanded else {
            errorMessage = AppLocalization.string("That chat is no longer available.")
            return .failed
        }
        showSidebar = false
        roomFoundGoneOnOpen = nil
        await openGroupRoom(room)
        guard !Task.isCancelled else { return .retry }
        if activeRoomSurface?.room.roomID == roomID { return .opened }
        // Gone between the lookup and the open's own read, which closes with
        // nothing said; unless a room, chat or dashboard opened since.
        if let gone = roomFoundGoneOnOpen, gone.roomID == roomID, gone.epoch == groupRoomEpoch,
           chatViewportTransitionGeneration == viewport, activeDashboardID == dashboardID,
           activeRoomSurface == nil, errorMessage == nil {
            errorMessage = AppLocalization.string("That chat is no longer available.")
        }
        return .failed
    }

    /// Open a hosted room. Loads the room's authoritative state, replays a
    /// bounded tail of the log, and starts incremental polling. The CURRENT
    /// session selection is left untouched: opening a room takes the
    /// viewport, and the next session open takes it back.
    func openGroupRoom(_ room: GroupRoom) async {
        guard let client, isConnected else {
            errorMessage = AppLocalization.string("Connect to Hermes to open group chats.")
            return
        }
        guard let dashboardID = activeDashboardID else { return }
        // A kept room asks Hermes first, and opens as Hermes lists it.
        var room = room
        if !groupRoomsListed {
            if groupCapabilities == nil {
                await refreshGroupChatSupport()
            } else {
                await refreshGroupRooms()
            }
            guard self.client === client, isConnected, activeDashboardID == dashboardID else { return }
            let roomID = room.roomID
            guard groupRoomsListed else {
                // A Hermes that hosts no rooms any more won't open it on a retry.
                errorMessage = groupChatPhase == .gatewayUnsupported
                    ? AppLocalization.string("That chat is no longer available.")
                    : AppLocalization.string("Couldn't open that chat. Try again.")
                return
            }
            guard let listed = groupRooms.first(where: { $0.roomID == roomID }) else {
                errorMessage = AppLocalization.string("That chat is no longer available.")
                return
            }
            room = listed
        }
        guard groupCapabilities?.foundationSupported == true else { return }
        guard room.isDisbanded == false else { return }
        // Group Settings asked for another room waits for that room.
        if groupSettingsOnOpen?.roomID != room.roomID { groupSettingsOnOpen = nil }
        // A newer destination than a New Chat or widget action on its way.
        widgetLaunchCoordinator.supersede()

        groupRoomEpoch &+= 1
        let epoch = groupRoomEpoch
        roomFoundGoneOnOpen = nil
        groupRoomPollTask?.cancel()
        // The room banner renders the shared errorMessage: a stale session
        // error must not greet the user inside the room.
        errorMessage = nil
        roomSendErrorMessage = nil
        // Switching straight from another room parks that room's send; the
        // in-flight flag follows the room being opened.
        parkActiveRoomSend()
        activeRoomSendInFlight = inFlightRoomSendTokens[
            Self.roomKey(dashboardID: dashboardID, roomID: room.roomID)
        ] != nil
        // A quote or drop the room being left never took stays with it.
        if activeRoomSurface?.room.roomID != room.roomID {
            roomQuoteRequest = nil
            roomDropRequest = nil
        }
        activeRoomLogRead = nil
        activeRoomSurface = GroupRoomSurface(dashboardID: dashboardID, room: room)
        activeRoomReplay = keptRoomReplays[Self.roomKey(dashboardID: dashboardID, roomID: room.roomID)]
            ?? GroupRoomReplay(roomID: room.roomID)
        activeRoomDriverStatus = nil
        activeRoomPeople = [:]
        activeRoomLooks = .empty
        activeRoomHomeName = nil
        activeRoomLooksReadAt = nil
        activeRoomPeopleRetries = 0
        activeRoomPeopleReadFailed = false
        activeRoomPostAttribution = .none
        activeRoomCopyPost = nil
        roomDraftHandBack = nil
        roomApprovalAnswers = [:]
        // A send parked when this room was left comes back with its retry
        // key; the tail below settles it if it landed meanwhile.
        groupRoomOutbox = parkedRoomOutboxes.removeValue(
            forKey: Self.roomKey(dashboardID: dashboardID, roomID: room.roomID)
        ) ?? GroupRoomOutbox()
        pendingRoomMessage = groupRoomOutbox.pending

        do {
            // Bounded tail: the room's replay cursor tells us where the log
            // ends; fetch only the last WINDOW events instead of the whole
            // history (upstream keeps 200 — GROUP_CHAT_HISTORY_LIMIT). The
            // window never exceeds the gateway's advertised page limit, so
            // the since_seq and the page limit always agree.
            let window = min(GroupRoomReplay.tailWindow, groupCapabilities?.maxLogLimit ?? 500)
            let (state, driver) = try await groupsState(client, roomID: room.roomID)
            guard groupRoomEpoch == epoch else { return }
            if state.isDisbanded {
                closeGoneRoomSurface()
                roomFoundGoneOnOpen = (room.roomID, groupRoomEpoch)
                await refreshGroupRooms()
                return
            }
            activeRoomSurface = GroupRoomSurface(dashboardID: dashboardID, room: state)
            activeRoomDriverStatus = driver
            if state.members.contains(where: \.isPeer) {
                Task { await self.readActiveRoomPeople(epoch: epoch) }
            }
            let latest = state.latestSeq ?? 0
            let start = max(0, latest - window)
            let page = try await groupsLog(
                client,
                roomID: room.roomID,
                sinceSeq: start,
                limit: window
            )
            guard groupRoomEpoch == epoch else { return }
            var replay = GroupRoomReplay(roomID: room.roomID)
            replay.adoptInitialTail(page: page)
            activeRoomReplay = replay
            activeRoomLogRead = room.roomID
            settlePendingRoomSend(from: replay.events)
            startRoomPolling()
        } catch is CancellationError {
            return
        } catch {
            guard groupRoomEpoch == epoch else { return }
            if HermesClient.isRoomNotFoundError(error) {
                // The room vanished between the roster and the open: no
                // poller, no haunted surface — back to the roster.
                closeGoneRoomSurface()
                roomFoundGoneOnOpen = (room.roomID, groupRoomEpoch)
                await refreshGroupRooms()
                return
            }
            // Leave the room open with whatever loaded (possibly nothing) and
            // surface the failure; the poller starts anyway so a transient
            // blip self-heals on the next tick.
            errorMessage = AppLocalization.string("Could not load this group chat: \(UserFacingError.message(for: error))")
            startRoomPolling()
        }
    }

    /// Incremental room updates: bounded `groups.log` deltas by `since_seq`
    /// (the least-wasteful upstream-supported mechanism — there is no client
    /// stream for room logs), plus a driver-status refresh each tick.
    private func startRoomPolling() {
        groupRoomPollTask?.cancel()
        let epoch = groupRoomEpoch
        groupRoomPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, self.groupRoomEpoch == epoch else { return }
                await self.pollActiveRoomOnce(epoch: epoch)
            }
        }
    }

    /// Whether a room screen shows. None mounted yet (the room just opened)
    /// counts as showing; none left after one went away doesn't.
    var roomSurfaceShows: Bool {
        roomViewsShowing.values.contains(true) || (roomViewsShowing.isEmpty && !roomScreenLeft)
    }

    /// A room screen showing, hidden (`shows` false), or gone (nil). Shown
    /// again after the polls stopped, the room catches up at once.
    func noteRoomView(_ id: UUID, shows: Bool?) {
        let before = roomSurfaceShows
        roomViewsShowing[id] = shows
        if shows != nil { roomScreenLeft = false } else if roomViewsShowing.isEmpty { roomScreenLeft = true }
        // Whether its notifications are read goes with it (issue 2064).
        if before != roomSurfaceShows { updateChatOnScreen() }
        guard !before, roomSurfaceShows, activeRoomSurface != nil else { return }
        let epoch = groupRoomEpoch
        Task { @MainActor [weak self] in await self?.pollActiveRoomOnce(epoch: epoch) }
    }

    private func pollActiveRoomOnce(epoch: Int) async {
        // Backgrounded, or the room's tab hidden: skip the tick (no RPCs
        // while nobody sees the room); the loop resumes polling on the
        // first tick after it shows again.
        guard isSceneActive, roomSurfaceShows else { return }
        guard let client, isConnected,
              let surface = activeRoomSurface,
              groupRoomEpoch == epoch,
              surface.dashboardID == activeDashboardID else { return }
        if surface.copy != nil {
            await pollActiveRoomCopyOnce(epoch: epoch)
            return
        }
        do {
            let page = try await groupsLog(
                client,
                roomID: surface.room.roomID,
                sinceSeq: activeRoomReplay.sinceSeq
            )
            guard groupRoomEpoch == epoch, let surface = activeRoomSurface else { return }
            let pageIsThisRoom = page.events.first.map { $0.roomID == surface.room.roomID } ?? true
            guard pageIsThisRoom else { return }
            let fresh = page.events.filter { $0.roomID == surface.room.roomID && $0.seq > activeRoomReplay.cursor }
            if activeRoomReplay.hasGap || activeRoomReplay.pageSkipsAhead(page) {
                // Gap detected (the replay's own flag, or a poll event that
                // jumped past unseen events): resync from the room's
                // authoritative cursor instead of rendering a hole. The
                // resync refreshes driver status itself.
                await resyncActiveRoom(epoch: epoch)
                return
            }
            if !fresh.isEmpty {
                activeRoomReplay.adopt(page: page)
                settlePendingRoomSend(from: fresh)
            }
            // A room whose open read failed is read once a poll catches it up.
            activeRoomLogRead = surface.room.roomID
            rereadActiveRoomPeopleForPosts(fresh)
            readActiveRoomLooksIfDue()
            // Driver status tracks the DRIVER, not the log: refresh even on
            // an eventless tick, or a settled room keeps offering Stop and
            // showing "working…" until the next unrelated event.
            if activeRoomReplay.cursor >= page.latestSeq || fresh.isEmpty {
                let (room, driver) = try await groupsState(client, roomID: surface.room.roomID)
                guard groupRoomEpoch == epoch else { return }
                if room.isDisbanded {
                    // A room tombstoned without new log events must still
                    // close the surface — otherwise the poller spins and
                    // sends fail against the tombstone forever.
                    closeGoneRoomSurface()
                    await refreshGroupRooms()
                    return
                }
                // Most ticks bring the same status: publishing it anyway
                // redrew everything watching AppState every 3 s (#1827).
                if activeRoomDriverStatus != driver { activeRoomDriverStatus = driver }
                sweepRoomApprovalAnswers()
            }
        } catch is CancellationError {
            return
        } catch {
            guard groupRoomEpoch == epoch else { return }
            if HermesClient.isRoomNotFoundError(error) {
                // The room was tombstoned while we polled (a not-found
                // answer when the tombstone was not opted into): no further
                // events will ever arrive, so keep spinning would be a lie.
                closeGoneRoomSurface()
                await refreshGroupRooms()
                return
            }
            // Transient poll failure: keep the surface and retry next tick.
        }
    }

    /// Send one user message to the open room via `groups.send`. The event
    /// id is minted once per logical message and REUSED on retry, so an
    /// ambiguous failure can never double-send (the gateway deduplicates on
    /// the mapped server-side id). The optimistic row comes from
    /// `pendingRoomMessage`; the accepted event reconciles it.
    ///
    /// Returns whether the send was REGISTERED — the pending row (and its
    /// retry key) now owns the text. `false` means the guards declined it
    /// and nothing holds the text, so the composer must keep its draft.
    /// `threadID` is a reply's: the message goes in the thread it answers.
    /// Otherwise it opens a thread of its own, so the host can route it.
    @discardableResult
    func sendGroupRoomMessage(
        _ rawText: String,
        threadID: String? = nil,
        attachments: [GroupRoomAttachment] = []
    ) async -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Files alone are a message too; a retry brings the pending ones.
        guard !text.isEmpty || !attachments.isEmpty || groupRoomOutbox.pending?.text == text else { return false }
        if activeRoomSurface?.copy != nil { return await postInActiveRoomCopy(text) }
        guard let surface = activeRoomSurface, surface.copy == nil, let client, isConnected,
              groupCapabilities?.supports("groups.send") == true,
              !activeRoomSendInFlight else { return false }
        guard surface.room.isDisbanded == false else { return false }
        // A pending (ambiguous-outcome) message owns the composer: the SAME
        // text retries with the same event id; DIFFERENT text is refused so
        // no message is ever silently swallowed or silently replaced.
        guard groupRoomOutbox.accepts(text: text) else {
            showRoomSendError(AppLocalization.string(
                "Your previous message is still pending. Retry it from the room, or wait for it to deliver."
            ))
            return false
        }
        let epoch = groupRoomEpoch
        let logical = groupRoomOutbox.beginSend(text: text, threadID: threadID, attachments: attachments) {
            "conduit-\(UUID().uuidString.lowercased())"
        }
        pendingRoomMessage = groupRoomOutbox.pending
        let sendKey = Self.roomKey(for: surface)
        activeRoomSendInFlight = true
        let sendToken = UUID()
        inFlightRoomSendTokens[sendKey] = sendToken
        // Per room: this send's end unlocks only its own room's composer,
        // whether that room is still open, reopened, or not open at all.
        defer {
            // Only while the entry is still this send's: after a teardown a
            // newer send to the same room owns the entry and the composer.
            if inFlightRoomSendTokens[sendKey] == sendToken {
                inFlightRoomSendTokens.removeValue(forKey: sendKey)
                if let open = activeRoomSurface,
                   Self.roomKey(for: open) == sendKey {
                    activeRoomSendInFlight = false
                }
            }
        }
        do {
            let result = try await groupsSend(
                client,
                roomID: surface.room.roomID,
                eventID: logical.eventID,
                text: logical.text,
                threadID: logical.threadID ?? GroupRoomSurface.threadID(forEventID: logical.eventID),
                attachments: logical.attachments
            )
            // A non-throwing groups.send is a delivered event: upstream
            // `methods_groups.py` answers `accepted: true` for a fresh or an
            // idempotently replayed append, and a refusal is an RPC error.
            guard groupRoomEpoch == epoch, activeRoomSurface?.room.roomID == surface.room.roomID else {
                // The room was left (or replaced) mid-send. The gateway
                // accepted it, so settle whichever copy holds the retry key:
                // the active outbox when the SAME room was already reopened,
                // else the parked one — a delivered send never offers retry.
                if result.event.roomID == surface.room.roomID {
                    if activeRoomSurface?.room.roomID == surface.room.roomID,
                       activeRoomSurface?.dashboardID == surface.dashboardID {
                        groupRoomOutbox.accept(eventID: logical.eventID)
                        pendingRoomMessage = groupRoomOutbox.pending
                    } else {
                        let key = Self.roomKey(for: surface)
                        parkedRoomOutboxes[key]?.accept(eventID: logical.eventID)
                        if parkedRoomOutboxes[key]?.pending == nil {
                            parkedRoomOutboxes.removeValue(forKey: key)
                        }
                    }
                }
                return true
            }
            guard result.event.roomID == surface.room.roomID else {
                // An answer naming another room settles nothing: keep the
                // pending row (same event id) for an explicit retry.
                showRoomSendError(AppLocalization.string("Could not send to this group chat: \(HermesError.invalidResponse.localizedDescription)"))
                return true
            }
            let cursorBefore = activeRoomReplay.cursor
            activeRoomReplay.adopt(page: GroupLogPage(
                events: [result.event],
                cursor: result.event.seq,
                latestSeq: max(result.event.seq, activeRoomReplay.cursor),
                hasMore: false,
                authorityGatewayID: activeRoomReplay.authorityGatewayID,
                authorityEpoch: activeRoomReplay.authorityEpoch
            ))
            groupRoomOutbox.accept(eventID: logical.eventID)
            pendingRoomMessage = groupRoomOutbox.pending
            if result.driverStarted {
                // The driver took the message on: show it working now rather
                // than waiting for the next poll's status, which corrects it.
                // Its routes hold until then; who answers first is the
                // log's to say, since the live turns predate the message.
                activeRoomDriverStatus = activeRoomDriverStatus?.with(running: true, working: true)
                    ?? GroupDriverStatus(running: true, working: true, blocked: false, counts: [:], pendingActions: [])
            }
            // A delivered message retires the failure banner of its earlier
            // ambiguous attempt.
            clearRoomSendError()
            if result.event.seq > cursorBefore + 1 {
                // The accepted event jumped past events this client has not
                // seen (a busy room between polls): resync from the room's
                // authoritative cursor instead of rendering a hole.
                await resyncActiveRoom(epoch: epoch)
            }
            await refreshGroupRooms()
            return true
        } catch is CancellationError {
            return true
        } catch {
            guard groupRoomEpoch == epoch else { return true }
            // A poll already proved this send delivered while it was in
            // flight: the failure is only the response's, nothing to report.
            guard groupRoomOutbox.pending?.eventID == logical.eventID else { return true }
            // Ambiguous outcome: KEEP pendingRoomMessage (same event id) so
            // the user's retry deduplicates server-side.
            showRoomSendError(AppLocalization.string("Could not send to this group chat: \(UserFacingError.message(for: error))"))
            return true
        }
    }

    /// Rebuild the open room's transcript from the room's authoritative
    /// cursor (groups.state + a bounded fresh tail). Used after a detected
    /// gap, and after a send whose accepted event skipped unseen events.
    private func resyncActiveRoom(epoch: Int) async {
        guard let client, let surface = activeRoomSurface, groupRoomEpoch == epoch else { return }
        do {
            let (state, driver) = try await groupsState(client, roomID: surface.room.roomID)
            guard groupRoomEpoch == epoch, let surface = activeRoomSurface,
                  surface.room.roomID == state.roomID else { return }
            if state.isDisbanded {
                closeGoneRoomSurface()
                await refreshGroupRooms()
                return
            }
            activeRoomSurface = GroupRoomSurface(dashboardID: surface.dashboardID, room: state)
            activeRoomDriverStatus = driver
            var fresh = GroupRoomReplay(roomID: state.roomID)
            let window = min(GroupRoomReplay.tailWindow, groupCapabilities?.maxLogLimit ?? 500)
            let start = max(0, (state.latestSeq ?? 0) - window)
            let tail = try await groupsLog(
                client, roomID: state.roomID, sinceSeq: start, limit: window)
            guard groupRoomEpoch == epoch else { return }
            fresh.adoptInitialTail(page: tail)
            activeRoomReplay = fresh
            activeRoomLogRead = state.roomID
            settlePendingRoomSend(from: fresh.events)
        } catch {
            // A failed resync keeps the current transcript; the next poll's
            // gap flag retries.
        }
    }

    /// Stop the open room's queued or running work (`groups.stop`).
    func stopActiveRoomWork() async {
        guard let surface = activeRoomSurface, surface.copy == nil, let client, isConnected,
              groupCapabilities?.supports("groups.stop") == true else { return }
        let epoch = groupRoomEpoch
        do {
            _ = try await groupsStop(client, roomID: surface.room.roomID)
            guard groupRoomEpoch == epoch else { return }
            await pollActiveRoomOnce(epoch: epoch)
        } catch {
            guard groupRoomEpoch == epoch else { return }
            // Surface without closing: stop is advisory to the driver.
            errorMessage = AppLocalization.string("Could not stop this group chat's work: \(UserFacingError.message(for: error))")
        }
    }

    /// Continue a discussion paused at its cap (`groups.continue`): the
    /// room's members get another budget of rounds and messages for it.
    func continueActiveRoomDiscussion(_ discussionEventID: String) async {
        guard let surface = activeRoomSurface, let client, isConnected,
              groupCapabilities?.supports("groups.continue") == true,
              !continuingRoomDiscussions.contains(discussionEventID),
              // A Stop or a newer message since the tap ended the pause.
              activeRoomContinuablePauses.values.contains(where: { $0.discussionEventID == discussionEventID })
        else { return }
        let epoch = groupRoomEpoch
        continuingRoomDiscussions.insert(discussionEventID)
        defer { continuingRoomDiscussions.remove(discussionEventID) }
        do {
            if let operation = groupChatOperations.continueDiscussion {
                try await operation(client, surface.room.roomID, discussionEventID)
            } else {
                try await client.groupsContinue(roomID: surface.room.roomID, discussionEventID: discussionEventID)
            }
            guard groupRoomEpoch == epoch else { return }
            await pollActiveRoomOnce(epoch: epoch)
        } catch {
            guard groupRoomEpoch == epoch else { return }
            errorMessage = AppLocalization.string("Could not continue this conversation: \(UserFacingError.message(for: error))")
        }
    }

    /// Save the open room's settings (`groups.context`). `eventID` is the
    /// save's retry key: the same settings sent again keep it, so the host
    /// returns the first save instead of writing a second. Routing goes
    /// along only where the host routes and the save changes it, so a mode
    /// this client predates (read as Everyone) survives a purpose or notes
    /// edit. `original` is the settings the draft started from (the room's
    /// current ones when nil): another client's routing change while the
    /// sheet was open survives a save that left Who answers alone. Returns
    /// the error to show, or nil once the host took it.
    func saveActiveRoomSettings(
        _ context: GroupRoomContext, eventID: String, roomID: String, original: GroupRoomContext? = nil
    ) async -> String? {
        guard let surface = activeRoomSurface, let client, isConnected,
              groupCapabilities?.supports("groups.context") == true else {
            return AppLocalization.string("Connect to Hermes to change this group chat's settings.")
        }
        // Settings drafted for one room never land in another opened since.
        guard surface.room.roomID == roomID else { return AppLocalization.string("That chat is no longer available.") }
        let epoch = groupRoomEpoch
        // Who answers showed where the host lists a mode this app knows, or
        // where the room runs on one newer than it (then with Everyone).
        let opened = original ?? activeRoomContext
        let offersRouting = !activeRoomRoutingModes.isEmpty || opened?.newerRouting.isEmpty == false
        let includesRouting = offersRouting && opened.map {
            $0.routing != context.routing || $0.leadMemberID != context.leadMemberID
                || $0.newerRouting != context.newerRouting
        } ?? true
        do {
            let saved: GroupRoomContext
            if let operation = groupChatOperations.context {
                saved = try await operation(client, surface.room.roomID, eventID, context, includesRouting)
            } else {
                saved = try await client.groupsContext(
                    roomID: surface.room.roomID, eventID: eventID, context: context, includesRouting: includesRouting
                )
            }
            guard groupRoomEpoch == epoch else { return nil }
            activeRoomDriverStatus?.roomContext = saved
            await pollActiveRoomOnce(epoch: epoch)
            return nil
        } catch {
            return UserFacingError.message(for: error)
        }
    }

    /// Answer one member's pending approval in the open room
    /// (`groups.approve`). The room's driver resumes the member's turn on
    /// its own; the poll that follows picks up the new status.
    func respondToRoomApproval(_ approval: GroupPendingApproval, choice: String) async {
        guard let surface = activeRoomSurface, surface.copy == nil, let client, isConnected,
              groupCapabilities?.supports("groups.approve") == true,
              approval.allows(choice),
              roomApprovalAnswers[approval.id] != .submitting,
              roomApprovalAnswers[approval.id] != .sent else { return }
        let epoch = groupRoomEpoch
        roomApprovalAnswers[approval.id] = .submitting
        do {
            let resolved = try await groupsApprove(
                client, roomID: surface.room.roomID, approval: approval, choice: choice)
            guard groupRoomEpoch == epoch else { return }
            roomApprovalAnswers[approval.id] = resolved
                ? .sent
                : .failed(AppLocalization.string("This approval is no longer active."))
        } catch is CancellationError {
            guard groupRoomEpoch == epoch else { return }
            roomApprovalAnswers.removeValue(forKey: approval.id)
            return
        } catch {
            guard groupRoomEpoch == epoch else { return }
            // A request the gateway no longer holds (answered elsewhere,
            // timed out, the turn stopped) drops off with the next status.
            roomApprovalAnswers[approval.id] = .failed(UserFacingError.message(for: error))
        }
        await pollActiveRoomOnce(epoch: epoch)
    }

    /// Forget failures whose approval the gateway no longer lists. Sent
    /// answers stay (see `roomApprovalAnswers`), and so does an answer
    /// still in flight.
    private func sweepRoomApprovalAnswers() {
        let listed = Set((activeRoomDriverStatus?.pendingApprovals ?? []).map(\.id))
        let kept = roomApprovalAnswers.filter { entry in
            if case .failed = entry.value { return listed.contains(entry.key) }
            return true
        }
        if kept != roomApprovalAnswers { roomApprovalAnswers = kept }
    }

    /// Permanently disband the open room (destructive; the view confirms).
    func disbandActiveRoom() async {
        // A room someone else hosts is theirs to disband.
        guard let surface = activeRoomSurface, surface.copy == nil else { return }
        await disbandGroupRoom(surface.room.roomID, opened: true)
    }

    /// Permanently disband a room, open or not: from its own menu, or its
    /// tile's on Bots Home (destructive; the view confirms). `opened`: asked
    /// from the open room, whose failure says nothing once another opens.
    /// Returns what went wrong, also set as `errorMessage`, else nil.
    @discardableResult
    func disbandGroupRoom(_ roomID: String, opened: Bool = false) async -> String? {
        guard groupCapabilities?.supports("groups.disband") == true else { return nil }
        guard let client, isConnected else {
            // Asked for and confirmed: say why nothing happened.
            let message = AppLocalization.string("Connect to Hermes to open group chats.")
            errorMessage = message
            return message
        }
        let epoch = groupRoomEpoch
        do {
            try await groupsDisband(client, roomID: roomID)
        } catch {
            guard self.client === client, !opened || groupRoomEpoch == epoch else { return nil }
            let message = AppLocalization.string("Could not disband this group chat: \(UserFacingError.message(for: error))")
            errorMessage = message
            return message
        }
        guard self.client === client else { return nil }
        if activeRoomSurface?.copy == nil, activeRoomSurface?.room.roomID == roomID { closeGoneRoomSurface() }
        await refreshGroupRooms()
        return nil
    }

    /// Leave the room view WITHOUT touching session state — the next session
    /// open, or this call's inverse, owns the viewport transition.
    func closeGroupRoom() {
        closeRoomSurfaceBackToChat()
        Task {
            await self.refreshGroupRooms()
            await self.refreshLinkedRoomCopies()
        }
    }

    /// Who's who in the open room over Links: the other people's agents'
    /// owners, and who left or was taken out. A read that fails keeps the
    /// last (unnamed at first: "On another Hermes"); one another room
    /// overtook is dropped.
    private func readActiveRoomPeople(epoch: Int) async {
        guard canInviteLinkedPeople, let surface = activeRoomSurface,
              let room = DashboardPath.encodedQueryComponent(surface.room.roomID) else { return }
        let dashboard = activeDashboardID
        // One for a room already left mustn't drop the open room's read.
        guard groupRoomEpoch == epoch else { return }
        activeRoomPeopleRead &+= 1
        let read = activeRoomPeopleRead
        let response = try? await roomRouteJSON(
            path: "\(RoomPeople.path)?room_id=\(room)", method: "GET", body: nil, timeoutMilliseconds: nil)
        guard read == activeRoomPeopleRead, groupRoomEpoch == epoch, activeDashboardID == dashboard,
              activeRoomSurface?.room.roomID == surface.room.roomID else { return }
        guard let response, response["ok"] as? Bool == true else {
            activeRoomPeopleReadFailed = true
            return
        }
        activeRoomPeopleReadFailed = false
        let people = RoomPeople.people(response)
        if people != activeRoomPeople { activeRoomPeople = people }
        let home = (response["home"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if home != activeRoomHomeName { activeRoomHomeName = home }
        // How they look comes with who they are (RoomLooks.swift).
        Task { await self.readActiveRoomLooks(epoch: epoch) }
        let attribution = RoomPostAttribution(
            isCopy: surface.copy != nil, you: RoomPeople.you(response), posts: RoomPeople.posts(response))
        if attribution != activeRoomPostAttribution { activeRoomPostAttribution = attribution }
    }

    /// A poll's events ask for the people again: in a room you host with
    /// linked people, a user message they don't name, which may be one of
    /// their posts, or any tick after a read failed while one isn't named
    /// (your own messages count, as the people never name them; a few
    /// times a visit);
    /// in a copy, your posts while the name the home gives you isn't known
    /// yet (the opening read failed). One read at a time, and one asked for
    /// meanwhile runs after it.
    private func rereadActiveRoomPeopleForPosts(_ events: [GroupEvent]) {
        guard let surface = activeRoomSurface else { return }
        let attribution = activeRoomPostAttribution
        if surface.copy != nil {
            // Each tick until it's known, a few times a visit.
            guard attribution.you == nil, activeRoomPeopleReadFailed, activeRoomPeopleRetries < Self.roomCopyNameReadLimit,
                  activeRoomReplay.events.contains(where: { attribution.poster(of: $0) == .you }) else { return }
            activeRoomPeopleRetries += 1
        } else {
            guard surface.room.members.contains(where: \.isPeer) else { return }
            if attribution.names(events) {
                guard activeRoomPeopleReadFailed, activeRoomPeopleRetries < Self.roomCopyNameReadLimit,
                      !attribution.names(activeRoomReplay.events) else { return }
                activeRoomPeopleRetries += 1
            }
        }
        guard !activeRoomPeopleRereading else {
            activeRoomPeopleRereadWanted = true
            return
        }
        activeRoomPeopleRereading = true
        Task {
            repeat {
                self.activeRoomPeopleRereadWanted = false
                await self.readActiveRoomPeople(epoch: self.groupRoomEpoch)
            } while self.activeRoomPeopleRereadWanted
            self.activeRoomPeopleRereading = false
        }
    }

    /// Who's who in the open room, read now (Group Info, and after taking
    /// one out).
    func refreshActiveRoomPeople() async {
        guard let surface = activeRoomSurface, surface.copy != nil || surface.room.members.contains(where: \.isPeer)
        else { return }
        await readActiveRoomPeople(epoch: groupRoomEpoch)
    }

    /// Posts `text` in the open room someone else hosts, through your
    /// Hermes (RoomPosts.swift). The room's outbox holds it as in your own
    /// rooms: one at a time, its event id kept for a retry, which your
    /// Hermes keeps as the same post. False when nothing took the text.
    private func postInActiveRoomCopy(_ text: String) async -> Bool {
        guard let surface = activeRoomSurface, let copy = surface.copy, isConnected, activeRoomCopyTakesPosts,
              !activeRoomSendInFlight else { return false }
        guard groupRoomOutbox.accepts(text: text) else {
            showRoomSendError(AppLocalization.string(
                "Your previous message is still pending. Retry it from the room, or wait for it to deliver."
            ))
            return false
        }
        let epoch = groupRoomEpoch
        let logical = groupRoomOutbox.beginSend(text: text) {
            "conduit-\(UUID().uuidString.lowercased())"
        }
        pendingRoomMessage = groupRoomOutbox.pending
        // Sent again, it's sending until your Hermes answers.
        activeRoomCopyPost = nil
        activeRoomSendInFlight = true
        let client = roomPostsClient
        defer {
            if groupRoomEpoch == epoch { activeRoomSendInFlight = false }
        }
        do {
            let post = try await client.post(roomID: copy.roomID, eventID: logical.eventID, text: logical.text)
            guard groupRoomEpoch == epoch, activeRoomSurface?.copy?.id == copy.id else { return true }
            clearRoomSendError()
            adoptActiveRoomCopyPost(post)
        } catch is CancellationError {
            return true
        } catch {
            guard groupRoomEpoch == epoch, groupRoomOutbox.pending?.eventID == logical.eventID else { return true }
            // It may not have reached your Hermes: kept, with its id, to retry.
            showRoomSendError(RoomPostText.postFailure(error))
        }
        return true
    }

    /// How the pending post stands, as your Hermes says. Posted, it's the
    /// room's message once the copy's log has it; until then it shows as
    /// sending. In a copy that takes no more posts, once its log has all
    /// it will (or it was waited on long enough), posted is settled as it
    /// is.
    private func adoptActiveRoomCopyPost(_ post: RoomPost) {
        guard groupRoomOutbox.pending?.eventID == post.eventID else { return }
        if case .posted(let seq) = post.status, activeRoomReplay.cursor >= seq || activeRoomCopyLogIsComplete {
            groupRoomOutbox.accept(eventID: post.eventID)
            pendingRoomMessage = groupRoomOutbox.pending
            activeRoomCopyPost = nil
            return
        }
        if post != activeRoomCopyPost { activeRoomCopyPost = post }
    }

    /// Asks your Hermes how the open copy's pending post stands (each tick
    /// while one is pending, and when the room opens).
    private func refreshActiveRoomCopyPost(epoch: Int) async {
        guard let copy = activeRoomSurface?.copy, let pending = groupRoomOutbox.pending, canPostInRoomCopies,
              !activeRoomSendInFlight, groupRoomEpoch == epoch else { return }
        if !activeRoomCopyTakesPosts || activeRoomCopyPostIsUnanswered { activeRoomCopyPostWaits += 1 }
        guard let posts = try? await roomPostsClient.list(roomID: copy.roomID), groupRoomEpoch == epoch,
              activeRoomSurface?.copy?.id == copy.id, !activeRoomSendInFlight,
              groupRoomOutbox.pending?.eventID == pending.eventID else { return }
        guard let post = posts.first(where: { $0.eventID == pending.eventID }) else {
            activeRoomCopyPostAbsent = true
            return
        }
        adoptActiveRoomCopyPost(post)
    }

    /// Your Hermes last said the pending post is sending, or posted at a seq
    /// the copy's log hasn't reached.
    private var activeRoomCopyPostIsUnanswered: Bool {
        switch activeRoomCopyPost?.status {
        case .sending?, .posted?: return true
        case .refused?, nil: return false
        }
    }

    /// The pending post was asked about `roomCopyPostWaitLimit` ticks
    /// without settling: Copy and Dismiss, saying it may still be posted.
    var activeRoomCopyPostWaitedOut: Bool {
        guard groupRoomOutbox.pending != nil, canPostInRoomCopies,
              activeRoomCopyPostWaits >= Self.roomCopyPostWaitLimit else { return false }
        if case .refused? = activeRoomCopyPost?.status { return false }
        return activeRoomCopyPost != nil || !activeRoomCopyPostAbsent
    }

    /// The open copy takes no more posts and its log has all it will: the
    /// room ended (its last event is in), or the pending post was waited on
    /// long enough.
    private var activeRoomCopyLogIsComplete: Bool {
        guard let copy = activeRoomSurface?.copy, !activeRoomCopyTakesPosts else { return false }
        return activeRoomCopyPostWaits >= Self.roomCopyPostWaitLimit
            || (copy.isOver && activeRoomReplay.cursor >= copy.lastSeq)
    }

    /// A refused post's Edit: it leaves the room screen, and its text goes
    /// back into the composer. Only while there is one: in a room that
    /// takes no more posts the row offers Copy and Dismiss instead.
    func editActiveRoomCopyPost() {
        guard activeRoomCopyTakesPosts, let pending = groupRoomOutbox.pending,
              case .refused(_)? = activeRoomCopyPost?.status else { return }
        groupRoomOutbox.discard()
        pendingRoomMessage = nil
        activeRoomCopyPost = nil
        clearRoomSendError()
        roomDraftHandBack = RoomDraftHandBack(text: pending.text)
    }

    /// Dismiss: a pending post in a copy that takes no more posts, or one
    /// waited on long enough, leaves the room screen, and isn't kept for
    /// when it opens again.
    func dismissActiveRoomCopyPost() {
        guard activeRoomSurface?.copy != nil, !activeRoomSendInFlight, groupRoomOutbox.pending != nil,
              activeRoomCopyPostWaitedOut || (!activeRoomCopyTakesPosts && !activeRoomCopyPostUnsettled) else { return }
        groupRoomOutbox.discard()
        pendingRoomMessage = nil
        activeRoomCopyPost = nil
        clearRoomSendError()
    }

    /// The room composer took the text back.
    func consumeRoomDraftHandBack(_ id: UUID) {
        if roomDraftHandBack?.id == id { roomDraftHandBack = nil }
    }

    /// Open a room someone else hosts, from your Hermes' copy of it: the
    /// room built from the copy, a bounded tail of its log, and what it's
    /// doing from its state. Polled as a room is, until it's over.
    func openRoomCopy(_ copy: RoomCopy) async {
        guard isConnected, canReadRoomCopies, let dashboardID = activeDashboardID else {
            errorMessage = AppLocalization.string("Connect to Hermes to open group chats.")
            return
        }
        widgetLaunchCoordinator.supersede()
        groupRoomEpoch &+= 1
        let epoch = groupRoomEpoch
        groupRoomPollTask?.cancel()
        groupRoomPollTask = nil
        errorMessage = nil
        roomSendErrorMessage = nil
        parkActiveRoomSend()
        activeRoomSendInFlight = false
        roomQuoteRequest = nil
        // Someone else hosts it: no notification of yours names it.
        activeRoomLogRead = nil
        activeRoomSurface = GroupRoomSurface(dashboardID: dashboardID, room: copy.room, copy: copy)
        activeRoomReplay = GroupRoomReplay(roomID: copy.roomID)
        activeRoomDriverStatus = copy.state
        activeRoomPeople = [:]
        activeRoomLooks = .empty
        activeRoomHomeName = nil
        activeRoomLooksReadAt = nil
        activeRoomCopyApprovalsReadAt = nil
        activeRoomPeopleRetries = 0
        activeRoomPeopleReadFailed = false
        // Its events say whose each post is; the people read names yours.
        activeRoomPostAttribution = RoomPostAttribution(isCopy: true, you: nil, posts: [:])
        activeRoomCopyPost = nil
        roomDraftHandBack = nil
        activeRoomCopyNeedsTail = false
        activeRoomCopyTailRead = false
        roomApprovalAnswers = [:]
        // A post parked when this room was left comes back with its retry
        // key; your Hermes says below how it stands now.
        groupRoomOutbox = parkedRoomOutboxes.removeValue(
            forKey: Self.roomKey(dashboardID: dashboardID, roomID: copy.id)
        ) ?? GroupRoomOutbox()
        pendingRoomMessage = groupRoomOutbox.pending
        let client = roomCopiesClient
        do {
            let window = GroupRoomReplay.tailWindow
            let page = try await client.log(roomID: copy.roomID, sinceSeq: max(0, copy.lastSeq - window), limit: window)
            guard groupRoomEpoch == epoch else { return }
            var replay = GroupRoomReplay(roomID: copy.roomID)
            replay.adoptInitialTail(page: page)
            activeRoomReplay = replay
            activeRoomCopyTailRead = true
        } catch is CancellationError {
            return
        } catch {
            guard groupRoomEpoch == epoch else { return }
            if RoomCopiesClient.isNoCopy(error) {
                closeGoneRoomSurface()
                await refreshLinkedRoomCopies()
                return
            }
            errorMessage = AppLocalization.string("Could not load this group chat: \(UserFacingError.message(for: error))")
            activeRoomCopyNeedsTail = true
        }
        Task {
            await self.readActiveRoomPeople(epoch: epoch)
            // One that's over isn't polled: your name is asked again here.
            guard copy.isOver else { return }
            while self.activeRoomPeopleRetries < Self.roomCopyNameReadLimit, self.groupRoomEpoch == epoch,
                  self.activeRoomPostAttribution.you == nil, self.activeRoomPeopleReadFailed,
                  self.activeRoomReplay.events.contains(where: { self.activeRoomPostAttribution.poster(of: $0) == .you }) {
                self.activeRoomPeopleRetries += 1
                try? await Task.sleep(for: Self.roomPeopleRetryDelay)
                await self.readActiveRoomPeople(epoch: epoch)
            }
        }
        await refreshActiveRoomCopyPost(epoch: epoch)
        // One whose opening read failed is polled until its tail comes.
        if !copy.isOver || activeRoomCopyNeedsTail || activeRoomCopyPostUnsettled { startRoomPolling() }
    }

    /// One tick of a copy's room screen: the log after the cursor, then,
    /// when it brought nothing new, the copy again for what the room is
    /// doing, and your agents' approvals in it (`roomCopyReadsApprovals`).
    /// A copy that's over stops the polling; one that's gone closes the room.
    private func pollActiveRoomCopyOnce(epoch: Int) async {
        guard let surface = activeRoomSurface, let copy = surface.copy, groupRoomEpoch == epoch else { return }
        let client = roomCopiesClient
        do {
            // The opening tail read failed: read the tail again, not the
            // room from its first event.
            if activeRoomCopyNeedsTail {
                let window = GroupRoomReplay.tailWindow
                let tail = try await client.log(
                    roomID: copy.roomID, sinceSeq: max(0, copy.lastSeq - window), limit: window)
                guard groupRoomEpoch == epoch, activeRoomSurface?.copy?.id == copy.id else { return }
                var replay = GroupRoomReplay(roomID: copy.roomID)
                replay.adoptInitialTail(page: tail)
                activeRoomReplay = replay
                activeRoomCopyNeedsTail = false
                activeRoomCopyTailRead = true
                errorMessage = nil
                // As it stands now: it may have ended, or been left, since;
                // a post that may still settle keeps it polled.
                if activeRoomSurface?.copy?.isOver == true, !activeRoomCopyPostUnsettled { stopRoomCopyPolling() }
                return
            }
            let page = try await client.log(
                roomID: copy.roomID, sinceSeq: activeRoomReplay.sinceSeq, limit: RoomCopiesClient.maxLogLimit)
            guard groupRoomEpoch == epoch, activeRoomSurface?.copy?.id == copy.id else { return }
            let fresh = page.events.filter { $0.roomID == copy.roomID && $0.seq > activeRoomReplay.cursor }
            if activeRoomReplay.hasGap || activeRoomReplay.pageSkipsAhead(page) {
                let window = GroupRoomReplay.tailWindow
                let tail = try await client.log(
                    roomID: copy.roomID, sinceSeq: max(0, page.latestSeq - window), limit: window)
                guard groupRoomEpoch == epoch else { return }
                var replay = GroupRoomReplay(roomID: copy.roomID)
                replay.adoptInitialTail(page: tail)
                activeRoomReplay = replay
            } else if !fresh.isEmpty {
                activeRoomReplay.adopt(page: page)
            }
            rereadActiveRoomPeopleForPosts(fresh)
            readActiveRoomLooksIfDue()
            await refreshActiveRoomCopyPost(epoch: epoch)
            if fresh.isEmpty || activeRoomReplay.cursor >= page.latestSeq {
                guard await refreshActiveRoomCopy(epoch: epoch) else { return }
            }
            await readRoomCopyApprovalsIfDue(roomMoved: !fresh.isEmpty)
        } catch is CancellationError {
            return
        } catch {
            guard groupRoomEpoch == epoch else { return }
            if RoomCopiesClient.isNoCopy(error) {
                closeGoneRoomSurface()
                await refreshLinkedRoomCopies()
            }
            // Otherwise a transient failure: the next tick tries again.
        }
    }

    /// A copy tick's approvals read, when `roomCopyReadsApprovals` says
    /// it's due. Only a read that answered waits out the quiet interval; a
    /// failed one is tried again next tick (issue 2151).
    func readRoomCopyApprovalsIfDue(roomMoved: Bool, now: Date = Date()) async {
        guard Self.roomCopyReadsApprovals(roomMoved: roomMoved, working: activeRoomDriverStatus?.working == true,
                                          listed: !activeRoomCopyApprovals.isEmpty,
                                          lastRead: activeRoomCopyApprovalsReadAt, now: now),
              await refreshLinkedRoomApprovals() else { return }
        activeRoomCopyApprovalsReadAt = now
    }

    /// Whether a copy's room tick reads your agents' approvals: each tick
    /// while the room moves, the room says it's working or one of them is
    /// listed (answered elsewhere, its card goes); a quiet room's on the
    /// first tick and then every `roomCopyQuietApprovalsInterval`, so one
    /// asked while nothing else shows is there within that (issue 2151).
    nonisolated static func roomCopyReadsApprovals(roomMoved: Bool, working: Bool, listed: Bool,
                                                   lastRead: Date?, now: Date) -> Bool {
        if roomMoved || working || listed { return true }
        guard let lastRead else { return true }
        return now.timeIntervalSince(lastRead) >= roomCopyQuietApprovalsInterval
    }

    nonisolated static let roomCopyQuietApprovalsInterval: TimeInterval = 15

    /// The open copy read again: what the room is doing and how it stands.
    /// One deleted elsewhere closes the room, and one that's over stops the
    /// polling. False when the room closed or another took its place.
    @discardableResult
    func refreshActiveRoomCopy(epoch: Int? = nil) async -> Bool {
        let epoch = epoch ?? groupRoomEpoch
        guard let copy = activeRoomSurface?.copy, groupRoomEpoch == epoch else { return false }
        guard let copies = await readLinkedRoomCopies() else { return true }
        guard groupRoomEpoch == epoch, let open = activeRoomSurface, open.copy?.id == copy.id else { return false }
        guard let latest = copies.first(where: { $0.id == copy.id }) else {
            // Deleted elsewhere: it can't be read any more.
            closeGoneRoomSurface()
            return false
        }
        // A quiet tick leaves the room screen as it is.
        if latest != open.copy {
            activeRoomSurface = GroupRoomSurface(dashboardID: open.dashboardID, room: latest.room, copy: latest)
        }
        if latest.state != activeRoomDriverStatus { activeRoomDriverStatus = latest.state }
        // A post pending as it ended is asked about once more: posted, it
        // settles, as the polling stops here.
        if latest.isOver, open.copy?.isOver != true, groupRoomOutbox.pending != nil {
            await refreshActiveRoomCopyPost(epoch: epoch)
            guard groupRoomEpoch == epoch, activeRoomSurface?.copy?.id == copy.id else { return false }
        }
        // One whose opening read failed is polled until its tail comes, and
        // one with a post your Hermes hasn't settled until it does.
        // Its last messages may have come after this tick's log read: read
        // once more as it ends, and leave a gap to the next tick.
        if latest.isOver, open.copy?.isOver != true, !activeRoomCopyNeedsTail,
           latest.lastSeq > activeRoomReplay.cursor,
           let page = try? await roomCopiesClient.log(
               roomID: copy.roomID, sinceSeq: activeRoomReplay.sinceSeq, limit: RoomCopiesClient.maxLogLimit) {
            guard groupRoomEpoch == epoch, activeRoomSurface?.copy?.id == copy.id else { return false }
            if activeRoomReplay.hasGap || activeRoomReplay.pageSkipsAhead(page) { return true }
            if page.events.contains(where: { $0.roomID == copy.roomID && $0.seq > activeRoomReplay.cursor }) {
                activeRoomReplay.adopt(page: page)
            }
        }
        if latest.isOver, !activeRoomCopyNeedsTail, !activeRoomCopyPostUnsettled { stopRoomCopyPolling() }
        return true
    }

    /// The open copy's pending post may still settle: your Hermes last said
    /// it's sending or posted, or hasn't been asked yet. Not once it was
    /// waited on long enough in a copy that takes no more posts.
    var activeRoomCopyPostUnsettled: Bool {
        // Without the posts routes nothing can be asked: it's as it is.
        guard groupRoomOutbox.pending != nil, canPostInRoomCopies,
              activeRoomCopyPostWaits < Self.roomCopyPostWaitLimit else { return false }
        switch activeRoomCopyPost?.status {
        case .sending?, .posted?: return true
        case .refused?: return false
        case nil: return !activeRoomCopyPostAbsent
        }
    }

    private func stopRoomCopyPolling() {
        groupRoomPollTask?.cancel()
        groupRoomPollTask = nil
    }

    /// One poll of the open room now, as the poller's tick runs it (tests,
    /// and a pull to refresh).
    func pollActiveRoom() async {
        await pollActiveRoomOnce(epoch: groupRoomEpoch)
    }

    /// Whether the open room is polled.
    var isPollingActiveRoom: Bool { groupRoomPollTask != nil }

    /// Create a hosted room from bots on the CURRENT gateway. Member rows
    /// carry `{member_id, profile, handle, display_name}`: identity is the
    /// profile name, the handle is the resolvable room tag (the mention tag,
    /// falling back to the profile handle) — the gateway re-validates the
    /// frozen 2–6 roster and refuses duplicated or reserved handles, and the
    /// client refuses first when two picks would claim one tag.
    /// `roomID` is the CLIENT-minted identity and create idempotency key:
    /// the CALLER owns its lifetime (the create sheet holds one per logical
    /// room) so a retry of an ambiguous create reuses the SAME id and the
    /// gateway deduplicates instead of forking a twin room.
    func createGroupRoom(name: String, bots: [BotProfile], roomID: String) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Each refusal explains itself: the sheet's own gate cannot see a
        // dropped connection or a roster that changed under the selection.
        guard let client, isConnected,
              groupCapabilities?.foundationSupported == true else {
            errorMessage = AppLocalization.string("Connect to Hermes to create a group chat.")
            return false
        }
        guard bots.count >= 2, bots.count <= GroupRoomLimits.maxMembers else {
            errorMessage = AppLocalization.string("Pick 2 to 6 bots for a group chat.")
            return false
        }
        guard !trimmedName.isEmpty else { return false }
        // The create sheet renders the shared errorMessage: clear the last
        // attempt's (or an unrelated surface's) failure before this one.
        errorMessage = nil
        guard let handles = BotMentions.roomHandles(for: bots) else {
            errorMessage = AppLocalization.string(
                "Two of these bots would claim the same @handle. Rename one bot's title, then try again."
            )
            return false
        }
        let members: [[String: Any]] = zip(bots, handles).map { bot, handle in
            [
                "member_id": bot.name,
                "profile": bot.name,
                "handle": handle,
                "display_name": bot.displayLabel,
            ]
        }
        do {
            let room = try await groupsCreate(client, roomID: roomID, name: trimmedName, members: members)
            await refreshGroupRooms()
            await openGroupRoom(room)
            return true
        } catch {
            errorMessage = AppLocalization.string("Could not create the group chat: \(UserFacingError.message(for: error))")
            return false
        }
    }
}
