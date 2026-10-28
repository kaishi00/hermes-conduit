//
//  RoomPosts.swift
//  Conduit
//
//  Posting in rooms other people host (designs/cross-owner-agents, C5a).
//  The room's composer in a copy posts to your own Hermes, which sends the
//  post to the room's home over your Link; the home posts it with each
//  line named for you ("Eric: …"), so the room's agents can tell it from
//  the host's own words, and says how it went (room_posts.py, notifier
//  0.115). The copy's events say whose each posted message is, and so do
//  the people of a room you host, so the room screen shows it as theirs.
//

import Foundation

/// A post as your Hermes keeps it.
struct RoomPost: Equatable {
    enum Status: Equatable {
        /// Sent to the home, which hasn't answered yet.
        case sending
        /// In the room, at the home's seq (your copy's too).
        case posted(seq: Int)
        /// Not posted, and why (`ended`, `not_in`, `too_long`, `too_many`,
        /// `unavailable`, `bad_post`, or one a newer plugin adds).
        case refused(String?)
    }

    let eventID: String
    let text: String
    let status: Status
}

/// Whose a message the home posted for someone is.
enum RoomPoster: Equatable {
    /// Yours, posted from a room someone else hosts.
    case you
    /// Another person's, by the name the home's Link gives them.
    case person(String)
}

/// Who the open room's people's messages are by: in a copy, as its events
/// say, with the name the home gives you (`GET /rooms/people`'s `you`); in
/// a room you host, by the people's `posts`.
struct RoomPostAttribution: Equatable {
    var isCopy: Bool
    var you: String?
    /// Event id to the person it was posted for (a room you host).
    var posts: [String: String]

    static let none = RoomPostAttribution(isCopy: false, you: nil, posts: [:])

    /// Nil for the user's own messages in a room they host, and for the
    /// host's in a copy.
    func poster(of event: GroupEvent) -> RoomPoster? {
        guard event.isUserMessage else { return nil }
        if isCopy {
            guard let post = event.post else { return nil }
            return post.by.map(RoomPoster.person) ?? .you
        }
        return posts[event.eventID].map(RoomPoster.person)
    }

    /// The message as its person wrote it: without the name the home put
    /// on each line.
    func text(of event: GroupEvent) -> String {
        let text = event.messageText ?? ""
        switch poster(of: event) {
        case .you: return RoomPostText.unnamed(text, name: you)
        case .person(let name): return RoomPostText.unnamed(text, name: name)
        case nil: return text
        }
    }

    /// Whether every user message among `events` is named already. In a
    /// room you host, one that isn't asks for the people again: it may be
    /// a post they don't list yet.
    func names(_ events: [GroupEvent]) -> Bool {
        isCopy || events.allSatisfy { !$0.isUserMessage || posts[$0.eventID] != nil }
    }
}

/// A refused post's text, handed back to the room's composer to edit.
struct RoomDraftHandBack: Equatable, Identifiable {
    let id = UUID()
    let text: String
}

/// What the room screen says about posts.
enum RoomPostText {
    /// `text` without `name` and its colon on every line, as the home
    /// named it; as it is when any line isn't named.
    static func unnamed(_ text: String, name: String?) -> String {
        guard let name, !name.isEmpty else { return text }
        let prefix = "\(name): "
        let lines = text.components(separatedBy: "\n")
        guard lines.allSatisfy({ $0.hasPrefix(prefix) }) else { return text }
        return lines.map { String($0.dropFirst(prefix.count)) }.joined(separator: "\n")
    }

    /// Why a post wasn't posted.
    static func refusal(_ error: String?) -> String {
        switch error {
        case "ended": return AppLocalization.string("Not posted: the room has ended.")
        case "not_in": return AppLocalization.string("Not posted: your agents aren't in this room.")
        case "too_long": return AppLocalization.string("Not posted: it's too long for this room.")
        case "too_many": return AppLocalization.string("Not posted: too many posts this hour. Try again later.")
        case "unavailable": return AppLocalization.string("Not posted: the host's Hermes couldn't take it. Try again.")
        case "bad_post": return AppLocalization.string("Not posted: the host's Hermes couldn't read it.")
        default: return AppLocalization.string("Not posted.")
        }
    }

    /// Whether posting it again could go differently.
    static func retries(_ error: String?) -> Bool {
        !["ended", "not_in", "too_long", "bad_post"].contains(error ?? "")
    }

    static func postFailure(_ error: Error) -> String {
        AppLocalization.string("Could not post in this room: \(RoomLinksClient.message(for: error))")
    }

    /// The pending row's state under its bubble.
    enum RowState: Equatable {
        case sending
        /// The request failed: it may not have reached your Hermes.
        case notDelivered
        case refused(String, retry: Bool)
        /// The room takes no more posts (it ended, or your agents left) and
        /// the post won't settle: why, with its text to copy before it's
        /// dismissed.
        case closed(String)
    }

    /// `takesPosts` false is a room that ended (`roomOver`) or one your
    /// agents left: a post still pending there can't go any further, unless
    /// it may still settle (`settling`: your Hermes is still asked about it).
    /// `waitedOut`: asked about long enough without settling, so it may
    /// still be posted. `canAsk` false: the plugin no longer posts, so
    /// nothing can be asked about it.
    static func rowState(post: RoomPost?, inFlight: Bool, takesPosts: Bool = true, roomOver: Bool = false,
                         settling: Bool = false, waitedOut: Bool = false, canAsk: Bool = true) -> RowState {
        if inFlight { return .sending }
        if waitedOut { return .closed(AppLocalization.string("Not confirmed yet: it may still be posted.")) }
        guard takesPosts else {
            guard canAsk else {
                return .closed(AppLocalization.string("Can't check this post: update the Conduit plugin on your Hermes."))
            }
            if settling { return .sending }
            if case .refused(let error)? = post?.status { return .closed(refusal(error)) }
            return .closed(refusal(roomOver ? "ended" : "not_in"))
        }
        guard let status = post?.status else { return .notDelivered }
        switch status {
        case .sending, .posted: return .sending
        case .refused(let error): return .refused(refusal(error), retry: retries(error))
        }
    }
}

/// The plugin's posts routes. Like the copies', they take no profile.
struct RoomPostsClient {
    static let capability = "room-posts"
    static let path = "/api/plugins/conduit_push/rooms/copies/messages"

    typealias Request = RoomLinksClient.Request

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    /// Posts `text` in the room under `eventID`, the retry key: the same id
    /// again is the same post. Answers how it stands.
    func post(roomID: String, eventID: String, text: String) async throws -> RoomPost {
        let body: [String: Any] = ["room_id": roomID, "event_id": eventID, "text": text]
        let response = try await request(Self.path, "POST", body, RoomLinksClient.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true, let object = response["message"] as? [String: Any],
              let post = Self.parsePost(object) else { throw HermesError.invalidResponse }
        return post
    }

    /// What you posted in the room, oldest first.
    func list(roomID: String) async throws -> [RoomPost] {
        guard let room = DashboardPath.encodedQueryComponent(roomID) else { throw HermesError.invalidResponse }
        let response = try await request("\(Self.path)?room_id=\(room)", "GET", nil, nil)
        guard response["ok"] as? Bool == true, let posts = response["messages"] as? [[String: Any]] else {
            throw HermesError.invalidResponse
        }
        return posts.compactMap(Self.parsePost)
    }

    /// A post without an event id, or with a status this app can't place,
    /// is left out.
    static func parsePost(_ object: [String: Any]) -> RoomPost? {
        guard let eventID = object["event_id"] as? String, !eventID.isEmpty,
              let status = object["status"] as? String else { return nil }
        let shown: RoomPost.Status
        switch status {
        case "sending": shown = .sending
        case "posted":
            guard let seq = object["seq"] as? Int else { return nil }
            shown = .posted(seq: seq)
        case "refused": shown = .refused(object["error"] as? String)
        default: return nil
        }
        return RoomPost(eventID: eventID, text: object["text"] as? String ?? "", status: shown)
    }
}

extension RoomPeople {
    /// On the home: each post the plugin made, by event id, to whom it's by.
    static func posts(_ response: [String: Any]) -> [String: String] {
        var posts: [String: String] = [:]
        for post in response["posts"] as? [[String: Any]] ?? [] {
            guard let eventID = post["event_id"] as? String, !eventID.isEmpty,
                  let by = post["by"] as? String, !by.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            posts[eventID] = by
        }
        return posts
    }

    /// On a member's Hermes: the name the home gives you, which your posts
    /// there carry.
    static func you(_ response: [String: Any]) -> String? {
        guard let you = response["you"] as? String, !you.isEmpty else { return nil }
        return you
    }
}

extension AppState {
    /// Whether the host's plugin posts in rooms other people host. Not in
    /// `usedCapabilities`, as with Links.
    var canPostInRoomCopies: Bool {
        canReadRoomCopies && notifierPlugin.reports(RoomPostsClient.capability)
    }

    /// Whether the open room is someone else's that takes your posts: still
    /// going, with an agent of yours in it.
    var activeRoomCopyTakesPosts: Bool {
        guard canPostInRoomCopies, let copy = activeRoomSurface?.copy else { return false }
        return copy.status == "started" && !copy.yours.isEmpty
    }

    /// Requests stay with the dashboard they were made for.
    var roomPostsClient: RoomPostsClient {
        let dashboard = activeDashboardID
        return RoomPostsClient(dashboardID: dashboard) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }
    }
}
