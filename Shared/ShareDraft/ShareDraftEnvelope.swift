//
//  ShareDraftEnvelope.swift
//  Conduit
//
//  A draft shared into Conduit from another app (#812). The share extension
//  writes one envelope per share into the App Group's ShareInbox folder; the
//  app picks it up when it comes to the front and puts it in the composer of
//  the chat it was meant for, where nothing is sent until the user sends it.
//  Compiled into the app and the share extension.
//

import Foundation

/// How much one share can carry. The extension enforces these before it
/// writes anything and says why something was left out; the app checks the
/// envelope again when it picks it up.
enum ShareDraftLimits {
    /// Files and pictures in one share.
    static let maximumAttachments = 10
    /// Shared text past this is cut (a whole web page pasted as text).
    static let maximumTextCharacters = 100_000
    /// And past this many bytes of UTF-8, for text heavy in emoji or
    /// scripts that take several bytes a character.
    static let maximumTextBytes = 400_000
    /// The per-file cap when the app hasn't said what its composer accepts:
    /// the composer's own default (AttachmentSizeLimit.defaultMegabytes).
    static let defaultFileMegabytes = 16
    /// A share never carries a bigger file, whatever the composer's limit:
    /// every upload is held in memory and base64-encoded before it is sent.
    static let maximumFileMegabytes = 64
    /// Everything in one share together.
    static let totalBytes: Int64 = 100 * 1024 * 1024
    /// A draft not picked up by then is deleted unread.
    static let lifetime: TimeInterval = 24 * 60 * 60
    /// Drafts waiting at once; the oldest goes when a share would pass it.
    static let maximumPendingDrafts = 10
    /// A draft dated this far in the future came from a wrong clock; it is
    /// treated as unreadable rather than kept forever.
    static let clockSkewAllowance: TimeInterval = 5 * 60

    /// `text` cut to at most `characters` characters and `maximumTextBytes`
    /// bytes of UTF-8, on a character boundary.
    static func truncated(_ text: String, characters: Int) -> String {
        var cut = Substring(text.prefix(characters))
        while cut.utf8.count > maximumTextBytes {
            // The excess in characters of the text's own average size: a
            // few rounds at most, and never far below the cap.
            let excess = cut.utf8.count - maximumTextBytes
            let average = max(1, cut.utf8.count / max(1, cut.count))
            cut = cut.dropLast(max(1, excess / average))
        }
        return String(cut)
    }

    /// The per-file cap for the composer limit the app published (in MB).
    static func fileByteLimit(composerMegabytes: Int?) -> Int64 {
        let megabytes = min(max(composerMegabytes ?? defaultFileMegabytes, 1), maximumFileMegabytes)
        return Int64(megabytes) * 1024 * 1024
    }

    /// Whether a draft made at `createdAt` is past its lifetime, or dated
    /// impossibly far ahead, at `now`.
    static func isExpired(createdAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age > lifetime || age < -clockSkewAllowance
    }
}

/// Where the shared draft goes: a new chat, or one of the recent chats the
/// app listed for the share sheet.
enum ShareDraftTarget: Equatable {
    case newChat
    case conversation(WidgetConversationReference)
}

extension ShareDraftTarget: Codable {
    private enum CodingKeys: String, CodingKey { case kind, conversation }
    private enum Kind: String, Codable { case newChat, conversation }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .newChat:
            self = .newChat
        case .conversation:
            self = .conversation(try values.decode(WidgetConversationReference.self, forKey: .conversation))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newChat:
            try values.encode(Kind.newChat, forKey: .kind)
        case .conversation(let reference):
            try values.encode(Kind.conversation, forKey: .kind)
            try values.encode(reference, forKey: .conversation)
        }
    }
}

/// One file in a shared draft. The file sits in the envelope's folder under
/// `storedName`, a name the extension makes up itself ("2.pdf"); the name the
/// sending app gave it is only ever a label (`displayName`), never a path.
struct ShareDraftAttachment: Codable, Equatable {
    let storedName: String
    let displayName: String
    /// The uniform type the sending app declared, if any.
    let typeIdentifier: String?
    let byteCount: Int64

    init(storedName: String, displayName: String, typeIdentifier: String?, byteCount: Int64) {
        self.storedName = storedName
        self.displayName = displayName
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey { case storedName, displayName, typeIdentifier, byteCount }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try values.decode(String.self, forKey: .storedName)
        let display = try values.decode(String.self, forKey: .displayName)
        let type = try values.decodeIfPresent(String.self, forKey: .typeIdentifier)
        let size = try values.decode(Int64.self, forKey: .byteCount)
        guard ShareDraftNames.isSafeStoredName(stored),
              !display.isEmpty, ShareDraftNames.sanitizedDisplayName(display) == display,
              type.map({ !$0.isEmpty && $0.count <= 256 }) ?? true,
              size >= 0, size <= Int64(ShareDraftLimits.maximumFileMegabytes) * 1024 * 1024 else {
            throw DecodingError.dataCorruptedError(forKey: .storedName, in: values, debugDescription: "Invalid shared file")
        }
        self.init(storedName: stored, displayName: display, typeIdentifier: type, byteCount: size)
    }
}

struct ShareDraftEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    /// The dashboard and profile the draft is for. Nil when the share sheet
    /// had no chat list from the app yet: the app then asks, if it has more
    /// than one dashboard.
    let workspace: WidgetWorkspaceID?
    let target: ShareDraftTarget
    let text: String
    let attachments: [ShareDraftAttachment]

    init(
        id: UUID = UUID(),
        createdAt: Date,
        workspace: WidgetWorkspaceID?,
        target: ShareDraftTarget,
        text: String,
        attachments: [ShareDraftAttachment]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.workspace = workspace
        self.target = target
        self.text = text
        self.attachments = attachments
    }

    /// The rules a draft must keep to be picked up at all.
    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              workspace.map(\.isValid) ?? true,
              text.count <= ShareDraftLimits.maximumTextCharacters,
              text.utf8.count <= ShareDraftLimits.maximumTextBytes,
              attachments.count <= ShareDraftLimits.maximumAttachments,
              !(text.isEmpty && attachments.isEmpty),
              attachments.reduce(Int64(0), { $0 + $1.byteCount }) <= ShareDraftLimits.totalBytes,
              Set(attachments.map(\.storedName)).count == attachments.count else { return false }
        if case .conversation(let reference) = target {
            // A chat is always named within a workspace, and a dashboard
            // chat within that workspace's profile.
            guard let workspace else { return false }
            switch reference.kind {
            case .dashboard:
                guard reference.botName == nil, reference.scopeProfile == workspace.profile else { return false }
            case .bot:
                guard reference.botName == reference.scopeProfile else { return false }
            }
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, workspace, target, text, attachments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values, debugDescription: "Unsupported shared draft schema")
        }
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            createdAt: try values.decode(Date.self, forKey: .createdAt),
            workspace: try values.decodeIfPresent(WidgetWorkspaceID.self, forKey: .workspace),
            target: try values.decode(ShareDraftTarget.self, forKey: .target),
            text: try values.decode(String.self, forKey: .text),
            attachments: try values.decode([ShareDraftAttachment].self, forKey: .attachments)
        )
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .attachments, in: values, debugDescription: "Invalid shared draft")
        }
    }

    static func encoded(_ envelope: ShareDraftEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(envelope)
    }

    static func decoded(from data: Data) throws -> ShareDraftEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ShareDraftEnvelope.self, from: data)
    }
}

/// File names in a shared draft.
enum ShareDraftNames {
    static let maximumDisplayNameLength = 120

    /// A name the extension made up for a file in the envelope's folder: a
    /// short run of letters, digits, dots, dashes and underscores that can't
    /// leave the folder or hide (no leading dot, no "..").
    static func isSafeStoredName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), !name.hasPrefix("."), !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }

    /// The stored name for the `ordinal`-th file (from 1), keeping a short,
    /// plain extension when the file has one.
    static func storedName(ordinal: Int, pathExtension: String?) -> String {
        let ext = (pathExtension ?? "").lowercased()
        let plain = ext.count <= 10 && !ext.isEmpty && ext.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }
        return plain ? "\(ordinal).\(ext)" : "\(ordinal)"
    }

    /// A file name another app suggested, made safe to show and to send as
    /// a label: no folders, no control characters, no leading dots, and not
    /// too long (the extension is kept). Empty when nothing is left.
    static func sanitizedDisplayName(_ suggested: String) -> String {
        var name = String(suggested.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                || scalar == "/" || scalar == "\\" || scalar == ":" {
                return "_"
            }
            return Character(scalar)
        })
        name = trimmed(name)
        guard name.count > maximumDisplayNameLength else { return name }
        let ext = (name as NSString).pathExtension
        let keepsExtension = !ext.isEmpty && ext.count <= 10
        let stemLimit = maximumDisplayNameLength - (keepsExtension ? ext.count + 1 : 0)
        let stem = trimmed(String((keepsExtension ? (name as NSString).deletingPathExtension : name).prefix(stemLimit)))
        guard !stem.isEmpty else { return "" }
        return keepsExtension ? "\(stem).\(ext)" : stem
    }

    /// No leading dots or spaces, no trailing spaces: what's left is the
    /// same however many times it is trimmed.
    private static func trimmed(_ value: String) -> String {
        var name = Substring(value)
        while let first = name.first, first == "." || first.isWhitespace { name.removeFirst() }
        while let last = name.last, last.isWhitespace { name.removeLast() }
        return String(name)
    }
}
