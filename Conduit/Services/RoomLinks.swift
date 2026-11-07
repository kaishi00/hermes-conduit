//
//  RoomLinks.swift
//  Conduit
//
//  Settings > People (designs/cross-owner-agents, C2): the Links between
//  this Hermes and other people's, which let two people bring their agents
//  into rooms together, and the invites that make them. The host's notifier
//  plugin keeps them for the whole installation (room_links.py) and talks to
//  the other side through the rooms mailbox. A Link grants nothing by
//  itself: what an agent may do is chosen for each room.
//
//  An invite is a `conduit://link/` link, also its QR code's payload. Only
//  the plugin reads what's in it. It carries the token that links whoever
//  holds it with the inviter, so it's never logged, and RoomLinkURL's
//  descriptions leave it out. Opened from another app, tapped in a chat,
//  scanned or pasted, it opens RoomLinkOpenedSheet, which asks before linking.
//

import Foundation

/// A Link invite: `conduit://link/` and a payload only the plugin reads.
struct RoomLinkURL: Identifiable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id = UUID()
    /// `conduit://link/` and the payload, the spelling the plugin reads.
    let text: String

    static let host = "link"
    static let prefix = "conduit://link/"
    /// The longest invite the plugin takes.
    static let maxLength = 2_048

    /// The whole text, trimmed, as an invite. The scheme and host may come
    /// in any case; the payload is base64url, as the plugin writes it.
    init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.prefix(Self.prefix.count).lowercased() == Self.prefix else { return nil }
        let payload = trimmed.dropFirst(Self.prefix.count)
        let text = Self.prefix + payload
        guard Self.isPayload(payload), text.utf8.count <= Self.maxLength else { return nil }
        self.text = text
    }

    init?(url: URL) {
        self.init(url.absoluteString)
    }

    /// The first invite in pasted text, which may hold more than the link.
    static func find(in text: String) -> RoomLinkURL? {
        guard let start = text.range(of: prefix, options: .caseInsensitive) else { return nil }
        let payload = text.unicodeScalars[start.upperBound...].prefix { payloadScalars.contains($0) }
        return RoomLinkURL(prefix + String(String.UnicodeScalarView(payload)))
    }

    /// As the plugin's base64url reader takes it: no padding, and never one
    /// character left over.
    private static func isPayload(_ payload: Substring) -> Bool {
        !payload.isEmpty && payload.unicodeScalars.count % 4 != 1 && payload.unicodeScalars.allSatisfy(payloadScalars.contains)
    }

    private static let payloadScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func == (lhs: RoomLinkURL, rhs: RoomLinkURL) -> Bool {
        lhs.text == rhs.text
    }

    var description: String { "RoomLinkURL(\(text.count) characters)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["length": text.count]) }
}

/// A Link as the plugin shows it: who's on the other side, whether their
/// Hermes has confirmed it, and their four fingerprint words.
struct RoomLink: Identifiable, Equatable {
    let id: String
    let name: String
    /// `waiting` (for the other side's Hermes to confirm it), `linked`, or
    /// `unanswered` (no confirmation came in time: link again). A status a
    /// newer plugin adds is kept as it is and shown with none.
    let status: String
    let words: [String]
    let createdAt: Date?
}

/// An invite this Hermes made that hasn't been used or run out.
struct RoomLinkInvite: Identifiable, Equatable {
    let id: String
    /// Who the invite says it's from, as the person opening it sees.
    let name: String
    let expiresAt: Date
}

struct RoomLinksList: Equatable {
    var links: [RoomLink]
    var invites: [RoomLinkInvite]
    /// False while nothing on the host reads the rooms mailbox. It reads
    /// only while there's an invite or a Link.
    var mailboxReading: Bool
}

/// This installation's four fingerprint words, which the other person's
/// Conduit shows when they open one of its invites.
struct RoomIdentity: Equatable {
    /// Nil before the host's first invite or accept made its keys.
    let words: [String]?
    /// False on a Hermes without Python's cryptography package, which
    /// can't make the keys a Link needs.
    let crypto: Bool
}

/// An invite this Hermes just made: its link, also its QR code's payload,
/// and this Hermes' four words, for the other person to compare.
struct RoomLinkInviteMade: Equatable {
    let url: RoomLinkURL
    let invite: RoomLinkInvite
    let words: [String]
}

/// What an invite says, as the plugin reads it, before it's accepted.
struct RoomLinkPreview: Equatable {
    /// Why it offers no Link.
    enum Stop: Equatable {
        /// It's this Hermes' own.
        case own
        case expired
        /// This Hermes already has a Link with them, by its id.
        case linked(String)
    }

    /// Who it's from, as the inviter wrote it.
    let name: String
    /// Their Hermes' four words.
    let words: [String]
    /// The host of the rooms mailbox it names.
    let mailbox: String
    let expiresAt: Date
    let expired: Bool
    let own: Bool
    /// This Hermes' Link with them already, waiting or linked.
    let linkedAs: String?

    var stop: Stop? {
        if own { return .own }
        if expired { return .expired }
        return linkedAs.map(Stop.linked)
    }
}

/// The name someone goes by in the invites they make and accept, kept on
/// this device for the next one.
enum RoomLinkName {
    static let storageKey = "conduit.roomLinks.name"
    /// The plugin takes 1 to 64 characters.
    static let maxLength = 64
}

/// The plugin's links routes. They take no profile: Links are the
/// installation's. Inviting, accepting, unlinking and cancelling wait on the
/// rooms mailbox, which the plugin gives up to 50 seconds.
struct RoomLinksClient {
    static let capability = "room-links"
    static let path = "/api/plugins/conduit_push/rooms"
    /// Past the plugin's own 50 s for a call that waits on the mailbox.
    static let mailboxTimeoutMilliseconds = 55_000

    /// `timeoutMilliseconds` nil keeps the dashboard request's own.
    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?, _ timeoutMilliseconds: Int?) async throws -> [String: Any]

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    func identity() async throws -> RoomIdentity {
        try Self.parseIdentity(try await request("\(Self.path)/identity", "GET", nil, nil))
    }

    func list() async throws -> RoomLinksList {
        try Self.parseList(try await request("\(Self.path)/links", "GET", nil, nil))
    }

    /// False when the plugin had no such Link (already gone).
    func unlink(_ linkID: String) async throws -> Bool {
        guard let link = DashboardPath.encodedQueryComponent(linkID) else { throw HermesError.invalidResponse }
        let response = try await request("\(Self.path)/links?link_id=\(link)", "DELETE", nil, Self.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true, let removed = response["removed"] as? Bool else {
            throw HermesError.invalidResponse
        }
        return removed
    }

    /// False when the invite was already used, cancelled or run out.
    func cancel(inviteID: String) async throws -> Bool {
        guard let invite = DashboardPath.encodedQueryComponent(inviteID) else { throw HermesError.invalidResponse }
        let response = try await request("\(Self.path)/links/invites?invite_id=\(invite)", "DELETE", nil, Self.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true, let cancelled = response["cancelled"] as? Bool else {
            throw HermesError.invalidResponse
        }
        return cancelled
    }

    /// A new invite, from `name`: who the other person sees it's from. Good
    /// for one accept within 24 hours.
    func invite(name: String) async throws -> RoomLinkInviteMade {
        try Self.parseInvite(try await request("\(Self.path)/links/invites", "POST", ["name": name], Self.mailboxTimeoutMilliseconds))
    }

    /// Who an invite is from, before it's accepted.
    func preview(_ invite: RoomLinkURL) async throws -> RoomLinkPreview {
        try Self.parsePreview(try await request("\(Self.path)/links/preview", "POST", ["url": invite.text], nil))
    }

    /// Accepts an invite as `name`, the name the inviter sees: the Link,
    /// waiting until their Hermes confirms it.
    func accept(_ invite: RoomLinkURL, name: String) async throws -> RoomLink {
        let response = try await request("\(Self.path)/links", "POST", ["url": invite.text, "name": name], Self.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true, let object = response["link"] as? [String: Any],
              let link = Self.link(object) else { throw HermesError.invalidResponse }
        return link
    }

    static func parseInvite(_ response: [String: Any]) throws -> RoomLinkInviteMade {
        guard response["ok"] as? Bool == true,
              let text = response["url"] as? String, let url = RoomLinkURL(text),
              let object = response["invite"] as? [String: Any], let invite = Self.invite(object),
              let words = Self.words(response["words"]) else { throw HermesError.invalidResponse }
        return RoomLinkInviteMade(url: url, invite: invite, words: words)
    }

    static func parsePreview(_ response: [String: Any]) throws -> RoomLinkPreview {
        guard response["ok"] as? Bool == true,
              let name = response["name"] as? String,
              let words = Self.words(response["words"]),
              let mailbox = response["mailbox"] as? String,
              let expiresAt = date(response["expires_at"]),
              let expired = response["expired"] as? Bool,
              let own = response["own"] as? Bool else { throw HermesError.invalidResponse }
        let linkedAs = (response["linked_as"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return RoomLinkPreview(
            name: name, words: words, mailbox: mailbox, expiresAt: expiresAt, expired: expired, own: own, linkedAs: linkedAs
        )
    }

    static func parseIdentity(_ response: [String: Any]) throws -> RoomIdentity {
        guard response["ok"] as? Bool == true, let crypto = response["crypto"] as? Bool else {
            throw HermesError.invalidResponse
        }
        return RoomIdentity(words: words(response["words"]), crypto: crypto)
    }

    /// A Link or an invite the page can't show (no id, name or words) is
    /// left out rather than refusing the whole list.
    static func parseList(_ response: [String: Any]) throws -> RoomLinksList {
        guard response["ok"] as? Bool == true,
              let links = response["links"] as? [[String: Any]],
              let invites = response["invites"] as? [[String: Any]] else { throw HermesError.invalidResponse }
        let mailbox = response["mailbox"] as? [String: Any]
        return RoomLinksList(
            links: links.compactMap(link),
            invites: invites.compactMap(invite),
            mailboxReading: mailbox?["reading"] as? Bool ?? false
        )
    }

    static func link(_ object: [String: Any]) -> RoomLink? {
        guard let id = object["id"] as? String, !id.isEmpty,
              let name = object["name"] as? String,
              let status = object["status"] as? String,
              let words = Self.words(object["words"]) else { return nil }
        return RoomLink(id: id, name: name, status: status, words: words, createdAt: date(object["created_at"]))
    }

    static func invite(_ object: [String: Any]) -> RoomLinkInvite? {
        guard let id = object["id"] as? String, !id.isEmpty,
              let name = object["name"] as? String,
              let expiresAt = date(object["expires_at"]) else { return nil }
        return RoomLinkInvite(id: id, name: name, expiresAt: expiresAt)
    }

    /// Four words, or nil.
    static func words(_ value: Any?) -> [String]? {
        guard let words = value as? [String], words.count == 4 else { return nil }
        return words
    }

    /// Unix seconds, as the plugin writes times.
    static func date(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// What a failed links or setup request says: the plugin's own words,
    /// as the bridge keeps them for a 400 or a 409. A 502, 503 or 504 the
    /// plugin answered (in JSON, with words of its own) is the rooms
    /// mailbox's answer or a call it gave up on, not a dashboard that
    /// couldn't reach Hermes, so its words are kept too.
    static func message(for error: Error) -> String {
        if case DashboardTicketBridgeError.http(let status, let detail) = error, (502...504).contains(status),
           let words = DashboardTicketBridgeError.meaningfulDetail(detail, status: status) {
            return words
        }
        return UserFacingError.message(for: error)
    }
}

extension AppState {
    /// Whether the host's plugin keeps Links. Not in `usedCapabilities`: an
    /// older plugin just doesn't offer Settings > People, with no update
    /// notice.
    var canLinkRooms: Bool {
        notifierPlugin.reports(RoomLinksClient.capability)
    }

    /// A `conduit://link/` invite opened Conduit or was tapped in a chat:
    /// RootView shows who it's from. Returns false for other links. An
    /// invite Conduit can't read is still one: it opens nothing else.
    func routeRoomLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ConduitAppLink.scheme,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?.lowercased() == RoomLinkURL.host else {
            return false
        }
        if let invite = RoomLinkURL(url: url) {
            pendingRoomLink = invite
        }
        return true
    }

    /// Requests stay with the dashboard they were made for.
    var roomLinksClient: RoomLinksClient {
        let dashboard = activeDashboardID
        return RoomLinksClient(dashboardID: dashboard) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard else { throw DashboardTicketBridgeError.notReady }
            return try await self.roomRouteJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
        }
    }
}
