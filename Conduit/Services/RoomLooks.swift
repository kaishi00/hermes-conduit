//
//  RoomLooks.swift
//  Conduit
//
//  How everyone in a room over Links looks (designs/cross-owner-agents,
//  N8; room_looks.py, notifier 0.139). No other Hermes can read your bots'
//  pictures or the glow color Bots Home gives them, so Conduit gives its
//  own Hermes a small picture and the color it draws for each bot, and the
//  picture you chose for rooms (`PUT /rooms/looks`). Each Hermes sends the
//  others in a room how its own look, and the room's home passes on
//  everyone else's, so the room screen draws other people's agents, and
//  the people, as their owner's Conduit does (`GET /rooms/looks`).
//

import SwiftUI
import UIKit

/// A picture and a color, either of which may be missing.
struct RoomLook: Equatable, Sendable {
    /// A small JPEG or PNG.
    var picture: Data?
    /// `#RRGGBB`.
    var color: String?

    init(picture: Data?, color: String?) {
        self.picture = picture
        self.color = color
    }

    /// One as the plugin answers it: nil for one with neither.
    init?(_ value: Any?) {
        guard let value = value as? [String: Any] else { return nil }
        let picture = (value["picture"] as? String).flatMap { Data(base64Encoded: $0) }
        let color = (value["color"] as? String).flatMap { CustomAccentColor(hex: $0) != nil ? $0 : nil }
        guard picture != nil || color != nil else { return nil }
        self.init(picture: picture, color: color)
    }

    var image: UIImage? { picture.flatMap(RoomLookImages.image(for:)) }

    var tint: CustomAccentColor? { color.flatMap { CustomAccentColor(hex: $0) } }

    var body: [String: Any] {
        ["picture": picture.map { $0.base64EncodedString() } ?? NSNull(), "color": color ?? NSNull()]
    }
}

/// How the open room's other people and their agents look, as their own
/// Conduits gave it (`GET /rooms/looks`).
struct RoomLooks: Equatable, Sendable {
    /// Other people's agents, by member id.
    var members: [String: RoomLook] = [:]
    /// The other people but the host, by their Link's name and by the name
    /// their posts carry.
    var people: [String: RoomLook] = [:]
    /// The host's, in a room someone else hosts.
    var home: RoomLook?
    /// The host's name as your Link gives it, in a room someone else hosts
    /// (`GET /rooms/people`'s `home`), which finds `home` by name.
    var hostName: String?
    /// Every Hermes in the open room is yours (`GET /rooms/people`'s
    /// `own_hermes`): its bots are drawn as yours, with no owner chip.
    var ownHermes = false

    static let empty = RoomLooks()

    init() {}

    init(_ response: [String: Any]) {
        for (memberID, value) in response["members"] as? [String: Any] ?? [:] {
            if let look = RoomLook(value) { members[memberID] = look }
        }
        for person in response["people"] as? [[String: Any]] ?? [] {
            guard let look = RoomLook(person["look"]) else { continue }
            for key in ["name", "poster"] {
                if let name = (person[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    people[name] = look
                }
            }
        }
        home = RoomLook(response["home"])
    }

    /// A member's, when it's another person's agent.
    func member(_ member: GroupMember?) -> RoomLook? {
        guard let member, member.isPeer, !member.isYours else { return nil }
        return members[member.identityKey]
    }

    /// A person's by the name your Link or their posts give them, the
    /// host's when it's the host's name (`home`).
    func person(named name: String?) -> RoomLook? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if let look = people[name] { return look }
        if let hostName, name == hostName.trimmingCharacters(in: .whitespacesAndNewlines) { return home }
        return nil
    }
}

/// Room looks' pictures decoded once.
enum RoomLookImages {
    private static let cache: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let image = cache.object(forKey: key) { return image }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// What Conduit gives its Hermes (`PUT /rooms/looks`).
enum RoomLooksUpload {
    static let capability = "room-looks"
    /// Your picture kept on Hermes for all your devices (`GET /rooms/looks`
    /// without a room; a `PUT` keeps what it leaves out), plugin 0.164.7+.
    static let youCapability = "room-looks-you"
    static let path = "/api/plugins/conduit_push/rooms/looks"
    /// room_looks.MAX_PICTURE_BYTES.
    static let maxPictureBytes = 8 * 1024
    /// A picture's edge, in pixels: a room draws one at 24 pt.
    static let edges: [CGFloat] = [96, 72, 56]
    static let qualities: [CGFloat] = [0.72, 0.55, 0.4, 0.28]
    /// Where your picture for rooms is kept, on this phone.
    static let personPictureKey = "conduit.roomPersonPicture.v1"

    /// A square JPEG, center-cropped, small enough to send; nil for an
    /// image that can't be drawn.
    static func picture(_ image: UIImage) -> Data? {
        let width = image.size.width, height = image.size.height
        guard width > 0, height > 0 else { return nil }
        for edge in edges {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format)
            let scale = edge / min(width, height)
            let size = CGSize(width: width * scale, height: height * scale)
            let rendered = renderer.image { context in
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
                image.draw(in: CGRect(origin: CGPoint(x: (edge - size.width) / 2, y: (edge - size.height) / 2), size: size))
            }
            for quality in qualities {
                if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= maxPictureBytes {
                    return jpeg
                }
            }
        }
        return nil
    }

    /// The body: each bot's look by profile, and yours.
    static func body(agents: [String: RoomLook], person: RoomLook?) -> [String: Any] {
        ["agents": agents.mapValues(\.body), "person": person?.body ?? NSNull()]
    }

    /// The same body always gives the same digest, whatever order the
    /// dictionary keeps.
    static func digest(agents: [String: RoomLook], person: RoomLook?) -> String {
        var parts = agents.keys.sorted().map { profile -> String in
            let look = agents[profile]!
            return "\(profile)|\(look.color ?? "")|\(look.picture?.hashValue ?? 0)|\(look.picture?.count ?? 0)"
        }
        parts.append("person|\(person?.picture?.hashValue ?? 0)|\(person?.picture?.count ?? 0)")
        return parts.joined(separator: "\n")
    }

    static func storedPersonPicture(_ defaults: UserDefaults = .standard) -> Data? {
        guard let data = defaults.data(forKey: personPictureKey), data.count <= maxPictureBytes else { return nil }
        return data
    }
}

extension AppState {
    /// Whether the host's plugin carries looks between rooms' Hermes.
    var canShareRoomLooks: Bool {
        notifierPlugin.reports(RoomLooksUpload.capability)
    }

    /// How a room member is drawn: its own bot's, else, for another
    /// person's agent, the look its owner's Conduit gave.
    func roomLook(for member: GroupMember?) -> RoomLook? {
        activeRoomLooks.member(member)
    }

    /// The open room's looks with its host's name, for the room screen's
    /// environment (`groupRoomLooks`).
    var activeRoomLooksShown: RoomLooks {
        var looks = activeRoomLooks
        looks.hostName = activeRoomHomeName
        looks.ownHermes = activeRoomOwnHermes == true
        return looks
    }

    /// Whether your Hermes keeps your picture for all your devices: each
    /// device then gives it only when you choose or remove it, so one
    /// without it set never takes it away from the people in your rooms.
    var roomLooksKeepYou: Bool {
        notifierPlugin.reports(RoomLooksUpload.youCapability)
    }

    enum RoomPersonPictureChange: Equatable {
        case saved
        /// It couldn't be made small enough to send.
        case unusable
        /// Your Hermes didn't take it.
        case notSaved
    }

    /// Sets the picture you show in rooms over Links (nil takes it away),
    /// kept on this phone and given to your Hermes, which keeps it for all
    /// your devices where it can (`roomLooksKeepYou`).
    @discardableResult
    func setRoomPersonPicture(_ image: UIImage?) async -> RoomPersonPictureChange {
        let data = image.flatMap(RoomLooksUpload.picture)
        if image != nil, data == nil { return .unusable }
        guard !roomPersonPictureSaving else { return .notSaved }
        roomPersonPictureSaving = true
        roomPersonPictureChanges &+= 1
        // Again as it ends: a read that started while it was out may hold
        // the picture from before it.
        defer {
            roomPersonPictureChanges &+= 1
            roomPersonPictureSaving = false
        }
        if roomLooksKeepYou {
            let dashboard = activeDashboardID
            let person: Any = data.map { RoomLook(picture: $0, color: nil).body } ?? NSNull()
            guard isConnected,
                  let response = try? await roomRouteJSON(path: RoomLooksUpload.path, method: "PUT",
                                                          body: ["person": person], timeoutMilliseconds: nil),
                  response["ok"] as? Bool == true else { return .notSaved }
            // Kept on the dashboard it was saved to; another one shown now
            // keeps showing its own, which its read brings back.
            guard activeDashboardID == dashboard else { return .saved }
            keepRoomPersonPicture(data)
            return .saved
        }
        keepRoomPersonPicture(data)
        await shareRoomLooksIfNeeded()
        return .saved
    }

    /// Shows the picture your Hermes keeps for you, as another of your
    /// devices last gave it (`GET /rooms/looks` without a room). One that
    /// fails, or that a change here overtook, keeps what's shown.
    func readRoomPersonPicture() async {
        guard roomLooksKeepYou, isConnected, let dashboard = activeDashboardID else { return }
        let changes = roomPersonPictureChanges
        guard let response = try? await roomRouteJSON(path: RoomLooksUpload.path, method: "GET", body: nil,
                                                      timeoutMilliseconds: nil),
              response["ok"] as? Bool == true, activeDashboardID == dashboard,
              roomPersonPictureChanges == changes, !roomPersonPictureSaving else { return }
        keepRoomPersonPicture(RoomLook(response["person"])?.picture)
    }

    private func keepRoomPersonPicture(_ data: Data?) {
        if roomPersonPicture != data { roomPersonPicture = data }
        if let data {
            appDefaults.set(data, forKey: RoomLooksUpload.personPictureKey)
        } else {
            appDefaults.removeObject(forKey: RoomLooksUpload.personPictureKey)
        }
    }

    /// Gives your Hermes how your bots and you look, when that changed
    /// since it was last given on this dashboard: each bot's picture and
    /// the color it's drawn in (`botColor`, the glow first), and yours.
    func shareRoomLooksIfNeeded() async {
        // One at a time: a change made while a share is on its way is
        // shared after it, so the last one given is what's shown here.
        if roomLooksSharing {
            roomLooksShareAgain = true
            return
        }
        roomLooksSharing = true
        defer { roomLooksSharing = false }
        repeat {
            roomLooksShareAgain = false
            await shareRoomLooksOnce()
        } while roomLooksShareAgain
    }

    private func shareRoomLooksOnce() async {
        guard canShareRoomLooks, canInviteLinkedPeople, isConnected, let dashboard = activeDashboardID else { return }
        let bots = shownBotRoster
        guard !bots.isEmpty else { return }
        let glows = profileGlowColors()
        var agents: [String: RoomLook] = [:]
        for bot in bots.prefix(32) {
            let picture = botAvatarImage(for: bot).flatMap { roomLookPicture(for: bot.name, image: $0) }
            let color = ProfileGlowRGB(UIColor(Self.botColor(bot, glow: glows[bot.name])))?.hex.uppercased()
            agents[bot.name] = RoomLook(picture: picture, color: color)
        }
        // A Hermes that keeps your picture is given it only when you choose
        // or remove it (setRoomPersonPicture): this device may not have it.
        let keepsYou = roomLooksKeepYou
        let person = keepsYou ? nil : roomPersonPicture.map { RoomLook(picture: $0, color: nil) }
        let digest = RoomLooksUpload.digest(agents: agents, person: person) + (keepsYou ? "\nkeeps-you" : "")
        guard sharedRoomLooks[dashboard] != digest else { return }
        var body = RoomLooksUpload.body(agents: agents, person: person)
        if keepsYou { body["person"] = nil }
        guard let response = try? await roomRouteJSON(path: RoomLooksUpload.path, method: "PUT", body: body,
                                                      timeoutMilliseconds: nil),
              response["ok"] as? Bool == true, activeDashboardID == dashboard else { return }
        sharedRoomLooks[dashboard] = digest
    }

    /// A bot's picture as sent, made once for each picture it has.
    private func roomLookPicture(for profile: String, image: UIImage) -> Data? {
        // The image itself is kept, so its identity can't be another's.
        if let kept = roomLookPictures[profile], kept.image === image { return kept.data }
        let data = RoomLooksUpload.picture(image)
        roomLookPictures[profile] = (image, data)
        return data
    }

    /// Reads how the open room's other people and their agents look. One
    /// that fails keeps what was read; one another room overtook is dropped.
    func readActiveRoomLooks(epoch: Int) async {
        guard canShareRoomLooks, let surface = activeRoomSurface,
              let room = DashboardPath.encodedQueryComponent(surface.room.roomID) else { return }
        // One read at a time for a room: the people read and the poll both
        // start one, and a slow one can outlast the 30 s between polls.
        let reading = "\(epoch)|\(surface.room.roomID)"
        guard activeRoomLooksReading != reading else { return }
        activeRoomLooksReading = reading
        defer { if activeRoomLooksReading == reading { activeRoomLooksReading = nil } }
        let dashboard = activeDashboardID
        activeRoomLooksReadAt = Date()
        let response = try? await roomRouteJSON(
            path: "\(RoomLooksUpload.path)?room_id=\(room)", method: "GET", body: nil, timeoutMilliseconds: nil)
        guard groupRoomEpoch == epoch, activeDashboardID == dashboard,
              activeRoomSurface?.room.roomID == surface.room.roomID else { return }
        guard let response, response["ok"] as? Bool == true else {
            // The next poll tries again, not 30 s on.
            activeRoomLooksReadAt = nil
            return
        }
        let looks = RoomLooks(response)
        if looks != activeRoomLooks { activeRoomLooks = looks }
        if let dashboard { keepHomeRoomLooks(looks, roomID: surface.room.roomID, dashboard: dashboard) }
    }

    /// The rooms over Links on Bots Home: your rooms with another person's
    /// agents in them, and the rooms others host yours in.
    var homeLinkedRoomIDs: [String] {
        shownGroupRooms.filter(\.isLinked).map(\.roomID) + linkedRoomCopyRows.map(\.roomID)
    }

    /// How a room over Links looks on Bots Home, as its tile draws it.
    func homeRoomLooks(roomID: String) -> RoomLooks {
        guard let dashboard = activeDashboardID else { return .empty }
        return homeRoomLooksByKey[Self.homeRoomLooksKey(dashboard, roomID)] ?? .empty
    }

    /// Reads how Bots Home's rooms over Links look, each at most every
    /// 30 s, one after another. One that fails keeps what was read.
    func readHomeRoomLooks() async {
        guard canShareRoomLooks, isConnected, let dashboard = activeDashboardID else { return }
        let roomIDs = homeLinkedRoomIDs
        // A room that no longer shows keeps no faces.
        let shown = Set(roomIDs.map { Self.homeRoomLooksKey(dashboard, $0) })
        let prefix = "\(dashboard.uuidString)|"
        for key in homeRoomLooksByKey.keys where key.hasPrefix(prefix) && !shown.contains(key) {
            homeRoomLooksByKey[key] = nil
            homeRoomLooksReadAt[key] = nil
        }
        // A room someone else hosts that's over can't change: read once.
        let over = Set(linkedRoomCopyRows.filter(\.isOver).map(\.roomID))
        for roomID in roomIDs {
            let key = Self.homeRoomLooksKey(dashboard, roomID)
            if over.contains(roomID), homeRoomLooksByKey[key] != nil { continue }
            if let at = homeRoomLooksReadAt[key], Date().timeIntervalSince(at) < Self.roomLooksReadInterval { continue }
            guard !Task.isCancelled else { return }
            guard let room = DashboardPath.encodedQueryComponent(roomID) else { continue }
            homeRoomLooksReadAt[key] = Date()
            let response = try? await roomRouteJSON(
                path: "\(RoomLooksUpload.path)?room_id=\(room)", method: "GET", body: nil, timeoutMilliseconds: nil)
            // Signed out meanwhile: what it said is the outgoing session's.
            guard activeDashboardID == dashboard, isConnected else { return }
            guard let response, response["ok"] as? Bool == true else {
                homeRoomLooksReadAt[key] = nil
                continue
            }
            keepHomeRoomLooks(RoomLooks(response), roomID: roomID, dashboard: dashboard)
        }
    }

    private func keepHomeRoomLooks(_ looks: RoomLooks, roomID: String, dashboard: UUID) {
        let key = Self.homeRoomLooksKey(dashboard, roomID)
        homeRoomLooksReadAt[key] = Date()
        if homeRoomLooksByKey[key] != looks { homeRoomLooksByKey[key] = looks }
    }

    nonisolated static func homeRoomLooksKey(_ dashboard: UUID, _ roomID: String) -> String {
        "\(dashboard.uuidString)|\(roomID)"
    }

    /// The poll reads them again now and then, so looks that came after
    /// the room opened (a person who joined later) show.
    func readActiveRoomLooksIfDue() {
        guard canShareRoomLooks, let surface = activeRoomSurface,
              surface.copy != nil || surface.room.members.contains(where: \.isPeer) else { return }
        if let at = activeRoomLooksReadAt, Date().timeIntervalSince(at) < Self.roomLooksReadInterval { return }
        let epoch = groupRoomEpoch
        Task { await self.readActiveRoomLooks(epoch: epoch) }
    }

    nonisolated static let roomLooksReadInterval: TimeInterval = 30
}

private struct GroupRoomLooksKey: EnvironmentKey {
    static let defaultValue = RoomLooks.empty
}

extension EnvironmentValues {
    /// How the open room's other people and their agents look (RoomLooks).
    var groupRoomLooks: RoomLooks {
        get { self[GroupRoomLooksKey.self] }
        set { self[GroupRoomLooksKey.self] = newValue }
    }
}
