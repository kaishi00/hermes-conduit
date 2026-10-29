//
//  RoomChats.swift
//  Conduit
//
//  A room's private chat with one of your agents (designs/cross-owner-agents,
//  C5b). Group Info's "Ask … about this room" opens a chat with that agent,
//  in its own profile, and tells your Hermes which room it's about
//  (`PUT /rooms/chats`, notifier 0.117): each turn there is told the room,
//  and the agent reads it with its room tool. Nothing written there goes to
//  the room. Wrap Up opens the same chat and asks for notes; an agent that
//  only listens in a room leaves its notes there on its own once the room
//  goes quiet (room_chats.py). One chat per room and profile, the latest
//  kept.
//

import Foundation

/// A room's chat, as your Hermes keeps it for one profile.
struct RoomChat: Equatable {
    let roomID: String
    let chatID: String
    /// The last seq of the room its notes cover.
    let notesSeq: Int
}

/// The plugin's room chats routes, per profile.
struct RoomChatsClient {
    static let capability = "room-chats"
    static let path = "/api/plugins/conduit_push/rooms/chats"

    typealias Request = RoomLinksClient.Request

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    /// `profile`'s room chats.
    func chats(profile: String) async throws -> [RoomChat] {
        let response = try await request(DashboardPath.withProfile(Self.path, profile: profile), "GET", nil, nil)
        guard response["ok"] as? Bool == true, let chats = response["chats"] as? [[String: Any]] else {
            throw HermesError.invalidResponse
        }
        return chats.compactMap(Self.chat)
    }

    /// `chatID` is `profile`'s chat about the room from now on.
    func open(roomID: String, chatID: String, profile: String) async throws -> RoomChat {
        let response = try await request(DashboardPath.withProfile(Self.path, profile: profile), "PUT",
                                         ["room_id": roomID, "chat_id": chatID], nil)
        guard response["ok"] as? Bool == true, let object = response["chat"] as? [String: Any],
              let chat = Self.chat(object) else { throw HermesError.invalidResponse }
        return chat
    }

    static func chat(_ object: [String: Any]) -> RoomChat? {
        guard let roomID = object["room_id"] as? String, !roomID.isEmpty,
              let chatID = object["chat_id"] as? String, !chatID.isEmpty else { return nil }
        return RoomChat(roomID: roomID, chatID: chatID, notesSeq: object["notes_seq"] as? Int ?? 0)
    }
}

/// One of your agents in the open room, which Group Info offers a chat with.
struct RoomChatAgent: Equatable {
    let profile: String
    let name: String

    /// Your agents still in a room with other people's agents; none in a
    /// room of your own agents only, which has nothing of other people's to
    /// ask about.
    static func agents(in members: [GroupMember]) -> [RoomChatAgent] {
        guard members.contains(where: \.isPeer) else { return [] }
        var agents: [RoomChatAgent] = []
        for member in members where !member.isPeer && member.out == nil {
            guard let profile = member.profile, !profile.isEmpty,
                  !agents.contains(where: { AppState.profilesMatch($0.profile, profile) }) else { continue }
            agents.append(RoomChatAgent(profile: profile, name: GroupRoomTurns.displayName(of: member)))
        }
        return agents
    }
}

/// How opening a room's chat went.
enum RoomChatOpenOutcome: Equatable {
    case opened
    /// Another navigation took the screen meanwhile.
    case superseded
    /// Hermes doesn't have the chat (deleted there, or never written to
    /// and pruned).
    case gone
    /// It may open on another try (a dropped connection, a timeout).
    case failed
}

/// Opens a room's chat: the one your Hermes keeps for the room and profile,
/// else a new one it's told about first, so the chat's first turn already
/// knows its room. Its steps are the app's, passed in.
struct RoomChatOpener {
    /// The profile's room chats.
    var chats: (_ profile: String) async throws -> [RoomChat]
    /// A new chat in the profile: the id it runs under, and the id Hermes
    /// keeps it by (none from a Hermes that didn't say). Until it's titled
    /// or written to it's Hermes' lazy row, which Hermes prunes.
    var create: (_ profile: String) async throws -> (runtimeID: String, storedID: String?)
    /// The chat, by the id Hermes keeps it by, is the room's.
    var register: (_ roomID: String, _ chatID: String, _ profile: String) async throws -> RoomChat
    /// Titles the chat by the id it runs under, which writes its row.
    var title: (_ runtimeID: String, _ profile: String, _ title: String) async -> Void
    /// Opens the chat on screen.
    var open: (_ chatID: String, _ profile: String, _ title: String) async -> RoomChatOpenOutcome
    /// Sends a message in the chat on screen.
    var send: (_ text: String) async -> Bool

    /// A chat the plugin keeps that Hermes no longer has is replaced by a
    /// new one; one that didn't open for another reason stays the room's.
    /// Throws when the chats can't be read or the new one can't be made or
    /// registered: a chat is never made while the room's own may still be
    /// there. A new chat Hermes gave no stored id for is never registered
    /// or opened: its runtime id names nothing once the chat closes.
    @MainActor
    func run(roomID: String, roomName: String, profile: String, wrapUp: Bool) async throws -> RoomChatOpenOutcome {
        let title = RoomChatText.chatTitle(roomName)
        let kept = try await chats(profile).first { $0.roomID == roomID }
        var outcome = RoomChatOpenOutcome.gone
        if let kept {
            outcome = await open(kept.chatID, profile, title)
        }
        if outcome == .gone {
            // Titled only once registered: one your Hermes refused stays a lazy row Hermes prunes, never a
            // stray chat that doesn't know its room.
            let created = try await create(profile)
            guard let chatID = created.storedID, !chatID.isEmpty else { throw HermesError.invalidResponse }
            _ = try await register(roomID, chatID, profile)
            await self.title(created.runtimeID, profile, title)
            outcome = await open(chatID, profile, title)
        }
        if outcome == .opened, wrapUp {
            _ = await send(RoomChatText.wrapUpPrompt)
        }
        return outcome
    }
}

/// What Group Info says about a room's chats.
enum RoomChatText {
    static var sectionTitle: String { AppLocalization.string("Ask Your Agent") }

    static func ask(_ name: String) -> String {
        AppLocalization.string("Ask \(name) about this room")
    }

    static func wrapUp(_ name: String) -> String {
        AppLocalization.string("Wrap Up with \(name)")
    }

    static var footer: String {
        AppLocalization.string("Opens a private chat with your agent about this room. Nothing you write there goes to the room. An agent that only listens leaves you notes there when the room goes quiet.")
    }

    /// The message Wrap Up sends in the room's chat.
    static var wrapUpPrompt: String {
        AppLocalization.string("Wrap up this room for me: what was decided, what I said I'd do, what I might have missed, and anything waiting on my answer.")
    }

    static func chatTitle(_ roomName: String) -> String {
        let name = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppLocalization.string("About \(name.isEmpty ? AppLocalization.string("a room") : name)")
    }

    static var failureTitle: String { AppLocalization.string("Could not open the room's chat") }

    /// The banner's words, once Group Info has closed.
    static func failure(_ reason: String) -> String {
        AppLocalization.string("Could not open the room's chat: \(reason)")
    }

    static var openFailure: String { AppLocalization.string("The chat didn't open. Try again.") }
}

extension AppState {
    /// Whether the host's plugin keeps rooms' chats. Not in
    /// `usedCapabilities`, as with Links.
    var canOpenRoomChats: Bool {
        notifierPlugin.reports(RoomChatsClient.capability)
    }

    /// Your agents in the open room Group Info offers a chat with.
    var activeRoomChatAgents: [RoomChatAgent] {
        guard canOpenRoomChats, activeRoomSurface != nil else { return [] }
        return RoomChatAgent.agents(in: GroupRoomTurns.members(activeRoomMembers, namedBy: botRoster))
    }

    /// Requests stay with the dashboard they were made for.
    var roomChatsClient: RoomChatsClient {
        let dashboard = activeDashboardID
        return RoomChatsClient(dashboardID: dashboard) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }
    }

    /// Opens the open room's chat with `agent`, and with `wrapUp` asks it for
    /// notes there. Nil when it opened (or another navigation took over),
    /// else why not, for Group Info to say while it's still `shown` on its
    /// room; once it has closed, or its room has (for the chat, or for
    /// another room), the app's banner says it instead.
    func openRoomChat(with agent: RoomChatAgent, wrapUp: Bool, shown: () -> Bool = { true }) async -> String? {
        let room = activeRoomSurface.map { $0.copy?.id ?? $0.room.roomID }
        guard let failure = await openRoomChatFailure(with: agent, wrapUp: wrapUp) else { return nil }
        if shown(), activeRoomSurface.map({ $0.copy?.id ?? $0.room.roomID }) == room { return failure }
        errorMessage = RoomChatText.failure(failure)
        return nil
    }

    private func openRoomChatFailure(with agent: RoomChatAgent, wrapUp: Bool) async -> String? {
        guard canOpenRoomChats, isConnected, let client, let surface = activeRoomSurface else {
            return RoomLinksClient.message(for: HermesError.notConnected)
        }
        let roomID = surface.room.roomID
        let routes = roomChatsClient
        let opener = RoomChatOpener(
            chats: { profile in try await routes.chats(profile: profile) },
            create: { [weak self] profile in
                guard let self else { throw HermesError.notConnected }
                let scoped = self.profilesMatch(profile, self.activeProfile) ? nil : profile
                let created = try await client.createSession(inProfile: scoped)
                if let returned = created.profile, !self.profilesMatch(returned, profile) {
                    throw HermesError.invalidResponse
                }
                return (created.sessionId, created.storedSessionId)
            },
            register: { roomID, chatID, profile in
                try await routes.open(roomID: roomID, chatID: chatID, profile: profile)
            },
            title: { [weak self] runtimeID, profile, title in
                guard let self else { return }
                // To the id it runs under, as a Bot Chat's title goes. A title that didn't land leaves the
                // chat as Hermes names it: it still knows its room.
                try? await client.setSessionTitle(runtimeID, title: title,
                                                  profile: self.profilesMatch(profile, self.activeProfile) ? nil : profile)
            },
            open: { [weak self] chatID, profile, title in
                guard let self else { return .failed }
                return await self.openRoomChatSession(chatID, profile: profile, agentName: agent.name, title: title)
            },
            send: { [weak self] text in
                guard let self else { return false }
                // A chat still settling on screen takes it into its composer, to send.
                if await self.submitComposer(text: text) { return true }
                // Never over a draft the chat already has.
                if !self.composerDraftStore.hasDraft(for: self.composerDraftKeyOnScreen) {
                    self.prefillComposer(text)
                }
                return false
            }
        )
        do {
            let outcome = try await opener.run(roomID: roomID, roomName: surface.room.name, profile: agent.profile,
                                               wrapUp: wrapUp)
            return outcome == .opened || outcome == .superseded ? nil : RoomChatText.openFailure
        } catch {
            return RoomLinksClient.message(for: error)
        }
    }
}
