import Foundation

/// Files sent into a group chat room. A room is not a session, so Hermes'
/// attach RPCs (which stage into a session's workspace) can't take them: the
/// host's notifier plugin stores each upload (plugin 0.38+, capability
/// `room-files`) and hands back the `@file:` reference that goes on its own
/// line above the message, as a chat's staged files do.
final class GroupRoomFilesClient {
    static let capability = "room-files"
    static let path = "/api/plugins/conduit_push/room-files"
    /// Base64 of a file near the host's 50 MB cap takes a while to send.
    static let minimumTimeoutMilliseconds = 180_000

    /// The largest file /room-files takes (plugin_api ROOM_FILE_MAX_BYTES).
    static let maximumMegabytes = 50

    /// The room composer's staging limit: the user's attachment limit, but
    /// never more than the room route takes.
    static func stagingLimit(preference: Int) -> Int {
        min(preference, maximumMegabytes)
    }

    /// What the room composer says about files over its limit. When the
    /// room route's cap is the one that binds (a Settings limit at or above
    /// it), raising the Settings limit can't help, so the message names the
    /// room's cap and offers no setting.
    static func tooLargeMessage(names: [String], preference: Int) -> String {
        guard AttachmentSizeLimit.clampedMegabytes(preference) >= maximumMegabytes else {
            return AttachmentSizeLimit.tooLargeMessage(names: names, megabytes: preference)
        }
        let limit = String(maximumMegabytes)
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

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return AppLocalization.string("Could not prepare \(name) for upload.")
            case .malformed:
                return AppLocalization.string("The host's answer couldn't be read. Update the Conduit plugin and try again.")
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
        notifierPlugin.reports(GroupRoomFilesClient.capability) && activeRoomSurface?.copy == nil
    }

    /// Uploads a room message's files and returns the text the room gets:
    /// their references, a blank line, then what was typed.
    func roomMessageText(_ text: String, attachments: [Attachment]) async throws -> String {
        guard !attachments.isEmpty else { return text }
        let client = GroupRoomFilesClient(request: { [weak self] path, body in
            guard let bridge = self?.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestEncodedJSON(
                path: path,
                encodedBody: body,
                timeoutMilliseconds: GroupRoomFilesClient.timeoutMilliseconds(forBodyBytes: body.count)
            )
        })
        let references = try await client.upload(attachments)
        return Self.promptText(text.trimmingCharacters(in: .whitespacesAndNewlines), fileReferences: references)
    }
}
