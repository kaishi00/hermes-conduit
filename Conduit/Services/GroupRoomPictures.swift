import Foundation
import ImageIO
import UIKit

/// Group chat pictures. Hermes' gateway-hosted rooms (`groups.*`) carry no
/// picture, so the host's notifier plugin keeps a room's custom one (plugin
/// 0.41+, capability `room-images`). Hermes Desktop's own group chats carry
/// theirs in the synced projection (`DesktopGroupChat.imageData`).
enum GroupRoomPictures {
    static let capability = "room-images"
    static let listPath = "/api/plugins/conduit_push/room-images"
    /// Pixels on a side of an uploaded picture: room pictures show at most
    /// 56 pt, so 256 px covers 3x with room to spare.
    static let uploadEdge: CGFloat = 256
    static let uploadTimeoutMilliseconds = 60_000
    /// The pictures the Bots list keeps with its rooms, by their bytes at
    /// most: a kept answer over 2 MB isn't kept at all.
    static let keptBytes = 1_000_000

    static func path(for roomID: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "._:-")
        guard !roomID.isEmpty, roomID.unicodeScalars.allSatisfy(allowed.contains),
              let encoded = roomID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return listPath + "/" + encoded
    }

    /// Each stored room's picture revision from `GET /room-images`.
    static func revisions(from response: [String: Any]) -> [String: String]? {
        guard response["ok"] as? Bool == true, let raw = response["revisions"] as? [String: Any] else { return nil }
        return raw.reduce(into: [String: String]()) { result, entry in
            if let revision = entry.value as? String, !revision.isEmpty { result[entry.key] = revision }
        }
    }

    /// The picture bytes and revision from `GET /room-images/<room id>`.
    static func picture(from response: [String: Any]) -> (data: Data, revision: String)? {
        guard response["ok"] as? Bool == true,
              let revision = response["rev"] as? String, !revision.isEmpty,
              let encoded = response["data_base64"] as? String,
              let data = Data(base64Encoded: encoded), !data.isEmpty else { return nil }
        return (data, revision)
    }

    /// The revision a `PUT` stored.
    static func storedRevision(from response: [String: Any]) -> String? {
        guard response["ok"] as? Bool == true, let revision = response["rev"] as? String, !revision.isEmpty else {
            return nil
        }
        return revision
    }

    /// The rooms a refresh must leave as they are: those set or removed
    /// here since it began (their generation moved on from `started`), and
    /// those whose change was still on its way when it began, whose answer
    /// may land before the refresh ends.
    static func changed(
        started: [String: Int],
        generations: [String: Int],
        changingAtStart: Set<String>
    ) -> Set<String> {
        Set(generations.keys.filter { generations[$0] != started[$0] }).union(changingAtStart)
    }

    /// A refresh's pictures merged into the ones on hand now. `listed` is
    /// the host's revisions, `fetched` what the refresh downloaded, and
    /// `changed` the rooms whose picture was set or removed here since the
    /// refresh began: those keep what they have, whatever the refresh saw.
    static func merged(
        data: [String: Data],
        revisions: [String: String],
        listed: [String: String],
        fetched: [String: (data: Data, revision: String)],
        changed: Set<String>
    ) -> (data: [String: Data], revisions: [String: String]) {
        var data = data.filter { listed[$0.key] != nil || changed.contains($0.key) }
        var revisions = revisions.filter { listed[$0.key] != nil || changed.contains($0.key) }
        for (roomID, picture) in fetched where !changed.contains(roomID) {
            data[roomID] = picture.data
            revisions[roomID] = picture.revision
        }
        return (data, revisions)
    }

    /// A square JPEG of `uploadEdge` px, center-cropped, as a `PUT` body.
    static func uploadBody(for image: UIImage) -> (body: Data, jpeg: Data)? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let edge = uploadEdge
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format)
        let side = min(image.size.width, image.size.height)
        let scale = edge / side
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (edge - drawSize.width) / 2, y: (edge - drawSize.height) / 2)
        let rendered = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.82),
              let body = try? JSONSerialization.data(withJSONObject: ["data_base64": jpeg.base64EncodedString()])
        else { return nil }
        return (body, jpeg)
    }

    /// The bytes of a `data:image/...;base64,` URL (Desktop's room picture).
    static func imageData(fromDataURL dataURL: String) -> Data? {
        guard dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].hasSuffix(";base64") else { return nil }
        let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]),
                        options: .ignoreUnknownCharacters)
        return data?.isEmpty == false ? data : nil
    }
}

/// Room pictures decoded once, at the largest size a room icon shows. Rows
/// redraw with the roster; decoding there each time would cost a full image
/// decode per row per redraw.
@MainActor
enum GroupRoomPictureImages {
    static let maxPixelSize: CGFloat = 192

    private static let images: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 48
        return cache
    }()

    static func image(from data: Data?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        let key = data as NSData
        if let cached = images.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: thumbnail)
        images.setObject(image, forKey: key)
        return image
    }
}

extension AppState {
    /// The room menu offers a picture only when the host can keep it.
    var canSetGroupRoomPictures: Bool {
        notifierPlugin.reports(GroupRoomPictures.capability)
    }

    /// A room's picture: the one set from Conduit (the kept one until the
    /// room list answers, #1533), else the one Hermes Desktop synced for the
    /// same room.
    func groupRoomPicture(roomID: String) -> UIImage? {
        if let data = groupRoomPictureData[roomID] { return GroupRoomPictureImages.image(from: data) }
        if !groupRoomsListed, let kept = keptGroupRooms()?.pictures.first(where: { $0.roomID == roomID }) {
            return GroupRoomPictureImages.image(from: kept.data)
        }
        guard !roomID.isEmpty,
              let desktop = shownDesktopGroupChats.first(where: { $0.roomID == roomID }) else { return nil }
        return GroupRoomPictureImages.image(from: desktop.imageData)
    }

    /// The rooms listed and their pictures, as the Bots list keeps them.
    func keptGroupRoomsNow() -> KeptGroupRooms {
        var bytes = 0
        let pictures = groupRooms.compactMap { room -> KeptGroupRooms.Picture? in
            guard let data = groupRoomPictureData[room.roomID],
                  let revision = groupRoomPictureRevisions[room.roomID],
                  bytes + data.count <= GroupRoomPictures.keptBytes else { return nil }
            bytes += data.count
            return KeptGroupRooms.Picture(roomID: room.roomID, revision: revision, data: data)
        }
        return KeptGroupRooms(rooms: groupRooms, pictures: pictures)
    }

    /// Takes the kept rooms' pictures as the ones on hand as the first list
    /// lands, so the rows keep them and the refresh fetches only the ones
    /// whose revision moved; never over one fetched or changed here. Taken
    /// before the plugin says it keeps pictures, too: its status can land
    /// after the list, which would otherwise keep the rooms without them.
    func adoptKeptGroupRoomPictures() {
        guard let kept = keptGroupRooms() else { return }
        var data = groupRoomPictureData
        var revisions = groupRoomPictureRevisions
        for picture in kept.pictures
        where data[picture.roomID] == nil && groupRoomPictureGenerations[picture.roomID] == nil {
            data[picture.roomID] = picture.data
            revisions[picture.roomID] = picture.revision
        }
        if data != groupRoomPictureData { groupRoomPictureData = data }
        groupRoomPictureRevisions = revisions
    }

    func hasCustomGroupRoomPicture(roomID: String) -> Bool {
        groupRoomPictureData[roomID] != nil
    }

    /// Fetches the pictures that changed since the last look. Runs with the
    /// room list, so it never polls on its own.
    func refreshGroupRoomPictures() async {
        guard canSetGroupRoomPictures, let bridge = dashboardTicketBridge else { return }
        let dashboard = activeDashboardID
        let epoch = groupRoomEpoch
        // A picture set or removed while this runs stays as the user left it.
        let started = groupRoomPictureGenerations
        let changingAtStart = Set(groupRoomPicturesChanging.keys)
        guard let listed = try? await bridge.requestJSON(path: GroupRoomPictures.listPath),
              let revisions = GroupRoomPictures.revisions(from: listed),
              activeDashboardID == dashboard, groupRoomEpoch == epoch else { return }
        let liveRooms = Set(groupRooms.map(\.roomID))
        var fetched: [String: (data: Data, revision: String)] = [:]
        for (roomID, revision) in revisions
        where groupRoomPictureRevisions[roomID] != revision && liveRooms.contains(roomID) {
            guard let path = GroupRoomPictures.path(for: roomID),
                  let answer = try? await bridge.requestJSON(path: path),
                  let picture = GroupRoomPictures.picture(from: answer) else { continue }
            guard activeDashboardID == dashboard, groupRoomEpoch == epoch else { return }
            fetched[roomID] = picture
        }
        let changed = GroupRoomPictures.changed(
            started: started,
            generations: groupRoomPictureGenerations,
            changingAtStart: changingAtStart
        )
        let merged = GroupRoomPictures.merged(
            data: groupRoomPictureData,
            revisions: groupRoomPictureRevisions,
            listed: revisions,
            fetched: fetched,
            changed: changed
        )
        if merged.data != groupRoomPictureData { groupRoomPictureData = merged.data }
        groupRoomPictureRevisions = merged.revisions
    }

    /// Sets the room's picture, or removes it with nil. Failures land in
    /// `errorMessage`.
    func setGroupRoomPicture(_ image: UIImage?, roomID: String) async {
        guard let bridge = dashboardTicketBridge, let path = GroupRoomPictures.path(for: roomID) else {
            errorMessage = AppLocalization.string("Connect to Hermes to change the group picture.")
            return
        }
        let dashboard = activeDashboardID
        let epoch = groupRoomEpoch
        // The latest change to the room wins, whichever answer comes last.
        let generation = (groupRoomPictureGenerations[roomID] ?? 0) + 1
        groupRoomPictureGenerations[roomID] = generation
        groupRoomPicturesChanging[roomID, default: 0] += 1
        defer {
            let left = (groupRoomPicturesChanging[roomID] ?? 1) - 1
            groupRoomPicturesChanging[roomID] = left > 0 ? left : nil
        }
        // A newer change to the room, another room or another dashboard has
        // taken over: this one fails quietly.
        var superseded: Bool {
            groupRoomPictureGenerations[roomID] != generation
                || activeDashboardID != dashboard || groupRoomEpoch != epoch
        }
        do {
            if let image {
                // Scaling and encoding a large photo stays off the main actor.
                let upload = await Task.detached(priority: .userInitiated) {
                    GroupRoomPictures.uploadBody(for: image)
                }.value
                guard let upload else {
                    if superseded { return }
                    errorMessage = AppLocalization.string("That picture could not be used.")
                    return
                }
                let answer = try await bridge.requestEncodedJSON(
                    path: path,
                    method: "PUT",
                    encodedBody: upload.body,
                    timeoutMilliseconds: GroupRoomPictures.uploadTimeoutMilliseconds
                )
                guard !superseded else { return }
                guard let revision = GroupRoomPictures.storedRevision(from: answer) else {
                    errorMessage = AppLocalization.string("The host's answer couldn't be read. Update the Conduit plugin and try again.")
                    return
                }
                groupRoomPictureData[roomID] = upload.jpeg
                groupRoomPictureRevisions[roomID] = revision
            } else {
                _ = try await bridge.requestJSON(path: path, method: "DELETE")
                guard !superseded else { return }
                groupRoomPictureData.removeValue(forKey: roomID)
                groupRoomPictureRevisions.removeValue(forKey: roomID)
            }
            // What the Bots list opens on next (#1533).
            keepGroupRoomPictures()
        } catch is CancellationError {
            return
        } catch {
            if superseded { return }
            errorMessage = AppLocalization.string("Could not change the group picture: \(UserFacingError.message(for: error))")
        }
    }
}
