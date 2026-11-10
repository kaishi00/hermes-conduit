import CryptoKit
import Foundation

/// Files sent into a group chat room. A room is not a session, so Hermes'
/// attach RPCs (which stage into a session's workspace) can't take them: the
/// host's notifier plugin stores each upload (plugin 0.38+, capability
/// `room-files`) and hands back the `@file:` reference that goes on its own
/// line above the message, as a chat's staged files do.
final class GroupRoomFilesClient {
    static let capability = "room-files"
    static let path = "/api/plugins/conduit_push/room-files"
    /// Reads a stored picture back as a data URL (plugin 0.142+), so a room
    /// draws it instead of its name.
    static let pictureCapability = "room-file-pictures"
    /// The same route reads any file sent into a room (plugin 0.143+), so
    /// a room opens and plays them as a chat does.
    static let readCapability = "room-file-reads"
    /// Linked Rooms carry each file sent into a room to its guests' hosts,
    /// and the same route reads the home's path from your own host's copy
    /// (plugin 0.149+), so a room someone else hosts draws them too.
    static let linkedCapability = "room-files-linked"
    static let readPath = "/api/plugins/conduit_push/room-files/data-url"

    /// A picture `/room-files` stored (`<hermes home>/conduit/room-files/
    /// <upload>/<name>`): only these are read back. Any other `@file:`
    /// picture keeps its name, since the route would refuse it.
    static func isStoredPicture(_ file: Attachment) -> Bool {
        file.kind == .image && isStoredFile(file)
    }

    /// A file Hermes keeps as the message's own attachment.
    static func isHermesAttachment(_ file: Attachment) -> Bool {
        GroupRoomAttachment.parse(path: file.uri) != nil
    }

    /// Any file `/room-files` stored: only these are read back. The route
    /// reads only `room-files/<upload>/<name>`, so nothing else qualifies.
    static func isStoredFile(_ file: Attachment) -> Bool {
        if isHermesAttachment(file) { return true }
        guard file.uri.hasPrefix("/"),
              let marker = file.uri.range(of: "/conduit/room-files/", options: .backwards) else { return false }
        let parts = file.uri[marker.upperBound...].split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }
    /// Base64 of a file near the host's 50 MB cap takes a while to send.
    static let minimumTimeoutMilliseconds = 180_000

    /// The largest file /room-files takes (dashboard/api/rooms.py ROOM_FILE_MAX_BYTES).
    static let maximumMegabytes = 50

    /// The largest file Hermes keeps as a room message's attachment
    /// (15,000,000 bytes), for a host whose plugin can't store room files.
    static let hermesMaximumMegabytes = 14

    /// The room composer's staging limit: the user's attachment limit, but
    /// never more than the room takes.
    static func stagingLimit(preference: Int, roomCap: Int = maximumMegabytes) -> Int {
        min(preference, roomCap)
    }

    /// What the room composer says about files over its limit. When the
    /// room route's cap is the one that binds (a Settings limit at or above
    /// it), raising the Settings limit can't help, so the message names the
    /// room's cap and offers no setting.
    static func tooLargeMessage(names: [String], preference: Int, roomCap: Int = maximumMegabytes) -> String {
        guard AttachmentSizeLimit.clampedMegabytes(preference) >= roomCap else {
            return AttachmentSizeLimit.tooLargeMessage(names: names, megabytes: preference)
        }
        let limit = String(roomCap)
        if names.count == 1, let name = names.first {
            return AppLocalization.string("\(name) is larger than the \(limit) MB a group room takes.")
        }
        let list = names.joined(separator: ", ")
        return AppLocalization.string("These files are larger than the \(limit) MB a group room takes: \(list).")
    }

    /// At least the minimum, plus about 1 s for every 64 KB of body (about
    /// 0.5 Mbit/s), so a slow link can still finish a large upload.
    static func timeoutMilliseconds(forBodyBytes count: Int) -> Int {
        max(minimumTimeoutMilliseconds, count / 64)
    }

    /// Sends one upload's JSON body, already encoded.
    typealias Request = @MainActor (_ path: String, _ body: Data) async throws -> [String: Any]

    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case malformed
        /// Together past what Hermes takes in one message (25 MB), with no
        /// plugin to take the rest.
        case overMessageLimit
        /// More files than Hermes takes in one message (8), with no plugin
        /// to take the rest.
        case tooManyFiles
        /// Files for Hermes with no connection to send them on, and no
        /// plugin to take them.
        case notConnected

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return AppLocalization.string("Could not prepare \(name) for upload.")
            case .malformed:
                return PluginUpdateAsk.text(AppLocalization.string("The host's answer couldn't be read. Update the Conduit plugin and try again."),
                                    instead: AppLocalization.string("The host's answer couldn't be read. Try again in a moment."))
            case .overMessageLimit:
                let limit = String(GroupRoomAttachment.maxMessageBytes / 1_000_000)
                return AppLocalization.string("Together these files are over the \(limit) MB a group room message takes. Send some in another message.")
            case .tooManyFiles:
                let limit = String(GroupRoomAttachment.maxPerMessage)
                return AppLocalization.string("A group room message takes up to \(limit) files. Send the rest in another message.")
            case .notConnected:
                return AppLocalization.string("Connect to Hermes to send files to this room.")
            }
        }
    }

    private let request: Request

    init(request: @escaping Request) {
        self.request = request
    }

    /// Uploads each attachment in order; returns their `@file:` references.
    @MainActor
    func upload(_ attachments: [Attachment]) async throws -> [String] {
        var references: [String] = []
        for attachment in attachments {
            // A composer that went away stops before the next file.
            try Task.checkCancellation()
            // Reading and encoding a large file stays off the main actor.
            let body = await Task.detached(priority: .userInitiated) { () -> Data? in
                let base64 = await AttachmentHelper.toBase64(attachment)
                guard !base64.isEmpty else { return nil }
                return try? JSONSerialization.data(withJSONObject: ["name": attachment.name, "data_base64": base64])
            }.value
            guard let body else { throw Failure.unreadable(attachment.name) }
            let response = try await request(Self.path, body)
            references.append(try Self.reference(from: response))
        }
        return references
    }

    /// The host's `ref_text`, else one built from the stored path.
    static func reference(from response: [String: Any]) throws -> String {
        guard response["ok"] as? Bool == true else { throw Failure.malformed }
        if let text = (response["ref_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("@file:"), text.count > "@file:".count {
            return text
        }
        guard let path = (response["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { throw Failure.malformed }
        return "@file:\(HermesClient.formatReferenceValue(path))"
    }
}

extension AppState {
    /// The room composer offers files only when the host can store them,
    /// and not in a room someone else hosts, whose home can't open them.
    var canAttachRoomFiles: Bool {
        (notifierPlugin.reports(GroupRoomFilesClient.capability) || roomTakesHermesAttachments)
            && activeRoomSurface?.copy == nil
    }

    /// The open room's Hermes keeps files as its messages' own attachments
    /// (`groups.attachment.upload`, Hermes 0.22.6+), which it hands to each
    /// bot as a chat's: pictures to a model without vision through the
    /// auxiliary vision model. Not in a copy, and not in a linked room:
    /// Hermes' peer route carries no files, and its driver fails a guest
    /// agent's whole turn on a message that has them
    /// (`attachments_unsupported_on_route`), so a linked room's files go
    /// through the plugin as `@file:` lines, which notifier #629 carries.
    var roomTakesHermesAttachments: Bool {
        groupCapabilities?.supports("groups.attachment.upload") == true
            && activeRoomSurface?.copy == nil
            && activeRoomSurface?.room.isLinked != true
    }

    /// The largest file the room composer stages, in MB.
    var roomFileCapMegabytes: Int {
        notifierPlugin.reports(GroupRoomFilesClient.capability)
            ? GroupRoomFilesClient.maximumMegabytes
            : GroupRoomFilesClient.hermesMaximumMegabytes
    }

    /// A room message ready for `groups.send`: its text (with the `@file:`
    /// lines of files the plugin stored) and its Hermes attachments.
    struct RoomMessage: Equatable {
        let text: String
        var attachments: [GroupRoomAttachment] = []
    }

    /// Uploads a room message's files. Each goes to Hermes as the message's
    /// own attachment where it can (a picture Hermes recognizes, a PDF or
    /// another file, within its 8 files, 15 MB each, 25 MB a message);
    /// the rest go to the plugin's room files as `@file:` lines above what
    /// was typed.
    func roomMessage(
        _ text: String, attachments: [Attachment], pictureCache: URL = TranscriptImageCache.defaultDirectory
    ) async throws -> RoomMessage {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return RoomMessage(text: text) }
        var sent: [(Attachment, GroupRoomAttachment)] = []
        var forPlugin: [Attachment] = []
        let pluginStores = notifierPlugin.reports(GroupRoomFilesClient.capability)
        // Both legs of one send go to the dashboard it started on.
        let pluginBridge = dashboardTicketBridge
        if roomTakesHermesAttachments, !isConnected || client == nil, !pluginStores {
            throw GroupRoomFilesClient.Failure.notConnected
        }
        if roomTakesHermesAttachments, let client, let roomID = activeRoomSurface?.room.roomID {
            // With nowhere for the rest, say what stops the message before
            // anything goes up, so no upload is left stored on the host for
            // a message that never sends. A file Hermes never takes comes
            // first: no split of the message would send it.
            if !pluginStores {
                let refused = await Task.detached(priority: .userInitiated) {
                    attachments.first { !GroupRoomHermesUpload.takes($0) }
                }.value
                if let refused { throw GroupRoomFilesClient.Failure.unreadable(refused.name) }
                if attachments.count > GroupRoomAttachment.maxPerMessage {
                    throw GroupRoomFilesClient.Failure.tooManyFiles
                }
                if Self.roomFilesBytes(attachments) > GroupRoomAttachment.maxMessageBytes {
                    throw GroupRoomFilesClient.Failure.overMessageLimit
                }
            }
            var total = 0
            for attachment in attachments {
                try Task.checkCancellation()
                var upload: GroupRoomHermesUpload?
                if sent.count < GroupRoomAttachment.maxPerMessage {
                    // Reading and encoding stays off the main actor.
                    upload = await Task.detached(priority: .userInitiated) { GroupRoomHermesUpload(attachment) }.value
                }
                guard let upload, total + upload.size <= GroupRoomAttachment.maxMessageBytes else {
                    if upload != nil, !pluginStores {
                        // Each fits, together they don't: say so, not that a
                        // file couldn't be prepared.
                        throw GroupRoomFilesClient.Failure.overMessageLimit
                    }
                    forPlugin.append(attachment)
                    continue
                }
                do {
                    let saved = try await groupsAttachmentUpload(
                        client, roomID: roomID, uploadID: upload.uploadID(stagedID: attachment.id), kind: upload.kind,
                        name: upload.name, mime: upload.mime, dataBase64: upload.base64
                    )
                    sent.append((attachment, saved))
                    total += upload.size
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Hermes turned this one down: the plugin takes it where it can.
                    guard pluginStores else { throw error }
                    forPlugin.append(attachment)
                }
            }
            if let resolver = roomFilePicturesResolver {
                await keepSentRoomPictures(
                    sent.filter { $0.1.kind == "image" }.map { ($0.0, $0.1.path(roomID: roomID)) },
                    resolver: resolver, in: pictureCache
                )
            }
        } else {
            forPlugin = attachments
        }
        guard !forPlugin.isEmpty else {
            return RoomMessage(text: typed, attachments: sent.map(\.1))
        }
        guard pluginStores else { throw GroupRoomFilesClient.Failure.unreadable(forPlugin[0].name) }
        let pluginText = try await roomMessageText(typed, attachments: forPlugin, bridge: pluginBridge)
        return RoomMessage(text: pluginText, attachments: sent.map(\.1))
    }

    /// The staged files' sizes added up, read from the files without
    /// loading them. A file that can't be read counts as nothing here and
    /// fails when it's prepared.
    nonisolated static func roomFilesBytes(_ attachments: [Attachment]) -> Int {
        attachments.reduce(0) { total, attachment in
            guard let url = URL(string: attachment.uri), url.isFileURL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return total }
            return total + size
        }
    }

    /// Uploads a room message's files to the plugin and returns the text
    /// the room gets: their references, a blank line, then what was typed.
    func roomMessageText(
        _ text: String, attachments: [Attachment], bridge: DashboardTicketBridge? = nil
    ) async throws -> String {
        guard !attachments.isEmpty else { return text }
        // The dashboard the send started on, not whichever is current when
        // a file goes up.
        let startedOn = bridge ?? dashboardTicketBridge
        let client = GroupRoomFilesClient(request: { [weak self] path, body in
            let timeout = GroupRoomFilesClient.timeoutMilliseconds(forBodyBytes: body.count)
            if let self, self.roomRouteIsStubbed {
                let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                return try await self.roomRouteJSON(path: path, method: "POST", body: fields, timeoutMilliseconds: timeout)
            }
            guard let bridge = startedOn, self?.dashboardTicketBridge === bridge else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestEncodedJSON(
                path: path,
                encodedBody: body,
                timeoutMilliseconds: timeout
            )
        })
        let references = try await client.upload(attachments)
        if let pictures = roomFilePicturesResolver {
            // Before the send: the composer clears its staged files after.
            await keepSentRoomPictures(attachments, references: references, resolver: pictures)
        }
        return Self.promptText(text.trimmingCharacters(in: .whitespacesAndNewlines), fileReferences: references)
    }

    /// Where a room's pictures are read, or nil where they can't be: a
    /// plugin before 0.142, or a room someone else hosts while your plugin
    /// doesn't keep its files (before 0.149, `room-files-linked`). One
    /// instance per dashboard, so the rows reading it compare equal.
    var roomFilePicturesResolver: GatewayMediaDataURLResolver? {
        roomFilesResolver(reporting: GroupRoomFilesClient.pictureCapability)
    }

    /// Where a room's other files are read (plugin 0.143+), as pictures are.
    var roomFileReadsResolver: GatewayMediaDataURLResolver? {
        roomFilesResolver(reporting: GroupRoomFilesClient.readCapability)
    }

    private func roomFilesResolver(reporting capability: String) -> GatewayMediaDataURLResolver? {
        let reads = GatewayMediaDataURLResolver.RoomFileReads(
            hermesAttachments: groupCapabilities?.supports("groups.attachment.download") == true,
            pluginPictures: notifierPlugin.reports(GroupRoomFilesClient.pictureCapability),
            pluginFiles: notifierPlugin.reports(GroupRoomFilesClient.readCapability)
        )
        let hermesReads = reads.hermesAttachments
        // A room someone else hosts names its home's paths; your own
        // host reads them from the copy Linked Rooms keep there.
        guard notifierPlugin.reports(capability) || hermesReads,
              activeRoomSurface?.copy == nil || notifierPlugin.reports(GroupRoomFilesClient.linkedCapability)
        else { return nil }
        // A new resolver when what it reads changes, so the rows draw again.
        if let cached = cachedRoomFilesResolver, cached.dashboardID == activeDashboardID, cached.roomFileReads == reads {
            return cached
        }
        // Its own profile name keeps its pictures apart from a chat's on
        // the phone; room files aren't a profile's.
        let resolver = GatewayMediaDataURLResolver(appState: self, profile: "room-files", source: .roomFiles, roomFileReads: reads)
        cachedRoomFilesResolver = resolver
        return resolver
    }

    /// A room message's file read back as a data URL: a Hermes attachment
    /// through `groups.attachment.download`, else one `/room-files` stored
    /// (pictures since plugin 0.142, any type since 0.143).
    func roomFileRead(for path: String) async -> GatewayMediaRead {
        if let attachment = GroupRoomAttachment.parse(path: path) {
            return await roomAttachmentRead(roomID: attachment.roomID, attachmentID: attachment.attachmentID)
        }
        // The resolver can be Hermes' alone: a plugin file needs the plugin.
        guard notifierPlugin.reports(GroupRoomFilesClient.pictureCapability)
                || notifierPlugin.reports(GroupRoomFilesClient.readCapability),
              let encodedPath = DashboardPath.encodedQueryComponent(path) else { return .gone }
        return await dataURLRead(endpoint: "\(GroupRoomFilesClient.readPath)?path=\(encodedPath)")
    }

    /// Keeps the pictures the user just sent on the phone under their room
    /// file, so their message shows them without reading them back.
    func keepSentRoomPictures(
        _ attachments: [Attachment],
        references: [String],
        resolver: GatewayMediaDataURLResolver,
        in directory: URL = TranscriptImageCache.defaultDirectory
    ) async {
        let stored: [(Attachment, String)] = zip(attachments, references).compactMap { attachment, reference in
            guard let file = MessageNormalizer.splitLeadingFileReferences(reference, messageId: "room").attachments.first,
                  GroupRoomFilesClient.isStoredFile(file) else { return nil }
            return (attachment, file.uri)
        }
        await keepSentRoomPictures(stored, resolver: resolver, in: directory)
    }

    /// Keeps each picture on the phone under the room path it was stored at.
    func keepSentRoomPictures(
        _ stored: [(Attachment, String)],
        resolver: GatewayMediaDataURLResolver,
        in directory: URL = TranscriptImageCache.defaultDirectory
    ) async {
        let generation = TranscriptImageCache.generation
        let kept: [(Attachment, String)] = stored.compactMap { attachment, path in
            guard attachment.kind == .image, let key = resolver.imageCacheKey(forMediaPath: path) else { return nil }
            return (attachment, key)
        }
        guard !kept.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for (attachment, key) in kept {
                guard let data = AttachmentHelper.data(for: attachment) else { continue }
                let type = TranscriptImageCache.fileExtension(forDataURL: "data:\(attachment.mimeType ?? "");")
                TranscriptImageCache.store(data, fileExtension: type, for: key, in: directory, generation: generation)
            }
        }.value
    }
}

extension AppState {
    /// A room message's Hermes attachment, read back as a data URL. Hermes
    /// reads it by the message that carries it, found in the open room.
    func roomAttachmentRead(roomID: String, attachmentID: String) async -> GatewayMediaRead {
        guard let client, activeRoomSurface?.room.roomID == roomID else { return .failed }
        let carrying: (eventID: String, attachments: [GroupRoomAttachment], pending: Bool)
        if let event = activeRoomReplay.events.last(where: { event in
            event.attachments.contains { $0.attachmentID == attachmentID }
        }) {
            carrying = (event.eventID, event.attachments, false)
        } else if let pending = pendingRoomMessage,
                  pending.attachments.contains(where: { $0.attachmentID == attachmentID }) {
            // Still sending: the id Hermes files its message under once the
            // send lands (`user:` + the client id's digest), as its row's.
            carrying = (GroupRoomOutbox.serverEventID(forClientEventID: pending.eventID), pending.attachments, true)
        } else {
            return .failed
        }
        let size = carrying.attachments.first { $0.attachmentID == attachmentID }?.size ?? 0
        do {
            let dataURL = try await groupsAttachmentDownload(
                client, roomID: roomID, eventID: carrying.eventID, attachmentID: attachmentID, size: size
            )
            // Bounded as the plugin's room-file read: an answer over 16 MB,
            // or one that isn't base64 media, is one Hermes won't give.
            return DataURLLimits.isBoundedBase64DataURL(dataURL) ? .dataURL(dataURL) : .gone
        } catch is CancellationError {
            return .failed
        } catch {
            // Hermes answered and won't give it (expired, or not this
            // viewer's); anything else may read on a later ask. A message
            // still sending may not have landed yet, so that's a later ask.
            return error is RpcError && !carrying.pending ? .gone : .failed
        }
    }
}

/// One staged file as Hermes takes it: a picture only when its bytes are
/// one Hermes recognizes (PNG, JPEG, GIF, WebP), a PDF only when they are
/// one, anything else a file; nil when it can't go (unreadable, or over
/// 15 MB), so the plugin takes it.
struct GroupRoomHermesUpload {
    let name: String
    let kind: String
    let mime: String
    let size: Int
    let base64: String
    let digest: String

    init?(_ attachment: Attachment) {
        guard let data = AttachmentHelper.data(for: attachment),
              let accepted = Self.accepted(data, declared: attachment.mimeType) else { return nil }
        (kind, mime) = accepted
        name = attachment.name
        size = data.count
        base64 = data.base64EncodedString()
        digest = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether Hermes takes this file at all, read without encoding it.
    static func takes(_ attachment: Attachment) -> Bool {
        guard let data = AttachmentHelper.data(for: attachment) else { return false }
        return accepted(data, declared: attachment.mimeType) != nil
    }

    /// The kind and type Hermes takes these bytes as, or nil where it
    /// takes them as nothing.
    private static func accepted(_ data: Data, declared mimeType: String?) -> (kind: String, mime: String)? {
        guard !data.isEmpty, data.count <= GroupRoomAttachment.maxBytes else { return nil }
        let declared = (mimeType ?? "").lowercased()
        if let picture = pictureType(data) { return ("image", picture) }
        if data.starts(with: Array("%PDF-".utf8)) { return ("pdf", "application/pdf") }
        // A picture or PDF Hermes doesn't recognize (HEIC, a damaged
        // file): Hermes takes neither as a plain file.
        if declared.hasPrefix("image/") || declared == "application/pdf" { return nil }
        if declared.hasPrefix("text/") || declared.isEmpty {
            // Hermes takes text only as plain text.
            guard String(data: data, encoding: .utf8) != nil, !data.contains(0) else { return nil }
            return ("file", "text/plain")
        }
        return ("file", declared)
    }

    /// The staged file and its bytes: a retry of the same file reuses the
    /// upload Hermes kept; the same picture staged again is a new one.
    func uploadID(stagedID: String) -> String {
        let staged = String(stagedID.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
        return "conduit-\(staged)-\(digest)"
    }

    static func pictureType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        if data.count >= 12, data.starts(with: Array("RIFF".utf8)),
           data[data.index(data.startIndex, offsetBy: 8)..<data.index(data.startIndex, offsetBy: 12)].elementsEqual(Array("WEBP".utf8)) {
            return "image/webp"
        }
        return nil
    }
}
