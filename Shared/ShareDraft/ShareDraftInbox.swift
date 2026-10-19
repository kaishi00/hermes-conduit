//
//  ShareDraftInbox.swift
//  Conduit
//
//  The folder shared drafts wait in (#812): `ShareInbox/` inside the
//  launcher App Group, next to the widgets' chat index, which the share
//  sheet reads for its recent chats. Nothing else in the group is touched.
//
//      ShareInbox/<draft id>/envelope.json
//      ShareInbox/<draft id>/1.jpg, 2.pdf ...
//      ShareInbox/.staging-<uuid>/        a share still being written
//
//  The extension builds a draft in a staging folder and renames it into
//  place once its envelope is written, so the app never reads half a draft.
//

import Foundation

/// One draft found in the inbox, with the folder its files are in.
struct ShareDraftPending: Equatable {
    let envelope: ShareDraftEnvelope
    let folder: URL
}

/// A share being written by the extension.
struct ShareDraftStagingFolder: Equatable {
    let url: URL
}

struct ShareDraftInbox {
    static let appGroup = WidgetSnapshotStore.appGroup
    static let folderName = "ShareInbox"
    static let envelopeFilename = "envelope.json"
    static let stagingPrefix = ".staging-"
    /// A staging folder this old belongs to a share that never finished.
    static let abandonedStagingAge: TimeInterval = 60 * 60
    /// The Darwin notification the extension posts once a draft is in
    /// place, so a Conduit already on screen (iPad, side by side) picks it
    /// up without leaving the foreground. It carries nothing.
    static let stagedNotificationName = "com.milim.relay.share-draft-staged"
    /// The local notification the extension posts, when Conduit may notify,
    /// so the user can tap straight back into Conduit.
    static let notificationIdentifierPrefix = "conduit.share-draft."

    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static var production: ShareDraftInbox? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        return ShareDraftInbox(directory: container.appendingPathComponent(folderName, isDirectory: true))
    }

    // MARK: Writing (the share extension)

    func beginStaging() throws -> ShareDraftStagingFolder {
        let url = directory.appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: Self.protection)
        return ShareDraftStagingFolder(url: url)
    }

    /// Writes the envelope and moves the staged files into place under the
    /// draft's id. Drafts past the cap go, oldest first.
    func commit(_ envelope: ShareDraftEnvelope, from staging: ShareDraftStagingFolder, now: Date = Date()) throws {
        guard envelope.isValid else { throw CocoaError(.fileWriteInvalidFileName) }
        for attachment in envelope.attachments {
            guard let url = Self.file(named: attachment.storedName, in: staging.url),
                  Self.isRegularFile(url) else { throw CocoaError(.fileNoSuchFile) }
        }
        let data = try ShareDraftEnvelope.encoded(envelope)
        // The app refuses bigger envelopes unread; refuse to write one.
        guard data.count <= Self.maximumEnvelopeBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: staging.url.appendingPathComponent(Self.envelopeFilename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let destination = directory.appendingPathComponent(envelope.id.uuidString, isDirectory: true)
        try fileManager.moveItem(at: staging.url, to: destination)
        trim(keeping: ShareDraftLimits.maximumPendingDrafts, now: now)
    }

    func discard(_ staging: ShareDraftStagingFolder) {
        try? fileManager.removeItem(at: staging.url)
    }

    // MARK: Reading (the app)

    /// Every draft still good, oldest first. Expired, unreadable and
    /// abandoned drafts are deleted on the way.
    func pending(now: Date = Date()) -> [ShareDraftPending] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey],
            options: []
        ) else { return [] }
        var found: [ShareDraftPending] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(Self.stagingPrefix) {
                let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if created.map({ now.timeIntervalSince($0) > Self.abandonedStagingAge }) ?? true {
                    try? fileManager.removeItem(at: entry)
                }
                continue
            }
            guard let draft = read(entry), !ShareDraftLimits.isExpired(createdAt: draft.envelope.createdAt, now: now) else {
                // Not a draft folder, unreadable, or too old: it goes.
                try? fileManager.removeItem(at: entry)
                continue
            }
            found.append(draft)
        }
        return found.sorted {
            if $0.envelope.createdAt != $1.envelope.createdAt { return $0.envelope.createdAt < $1.envelope.createdAt }
            return $0.envelope.id.uuidString < $1.envelope.id.uuidString
        }
    }

    /// The draft with this id, if it is still waiting and good.
    func pending(id: UUID, now: Date = Date()) -> ShareDraftPending? {
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard let draft = read(folder), draft.envelope.id == id,
              !ShareDraftLimits.isExpired(createdAt: draft.envelope.createdAt, now: now) else { return nil }
        return draft
    }

    /// The file one of the draft's attachments is in: inside the draft's
    /// folder, a plain file and not a link. Nil otherwise.
    func file(for attachment: ShareDraftAttachment, in draft: ShareDraftPending) -> URL? {
        guard let url = Self.file(named: attachment.storedName, in: draft.folder), Self.isRegularFile(url) else { return nil }
        return url
    }

    func remove(id: UUID) {
        try? fileManager.removeItem(at: directory.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// Deletes the drafts `shouldRemove` picks, and abandoned staging
    /// folders (a share still being written stays).
    func removeAll(now: Date = Date(), where shouldRemove: (ShareDraftEnvelope) -> Bool = { _ in true }) {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for entry in entries {
            if entry.lastPathComponent.hasPrefix(Self.stagingPrefix) {
                let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if created.map({ now.timeIntervalSince($0) > Self.abandonedStagingAge }) ?? true {
                    try? fileManager.removeItem(at: entry)
                }
            } else if let draft = read(entry) {
                if shouldRemove(draft.envelope) { try? fileManager.removeItem(at: entry) }
            } else {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    // MARK: -

    private func read(_ folder: URL) -> ShareDraftPending? {
        guard let id = UUID(uuidString: folder.lastPathComponent),
              id.uuidString == folder.lastPathComponent,
              let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let envelopeURL = folder.appendingPathComponent(Self.envelopeFilename)
        guard Self.isRegularFile(envelopeURL),
              let size = (try? envelopeURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= Self.maximumEnvelopeBytes,
              let data = try? Data(contentsOf: envelopeURL),
              let envelope = try? ShareDraftEnvelope.decoded(from: data),
              envelope.id == id else { return nil }
        return ShareDraftPending(envelope: envelope, folder: folder)
    }

    /// An envelope holds text (at most 400,000 bytes of UTF-8, which JSON
    /// can escape to a few times that) and a short file list; anything
    /// bigger isn't one.
    static let maximumEnvelopeBytes = 4 * 1024 * 1024

    private func trim(keeping limit: Int, now: Date) {
        let drafts = pending(now: now)
        guard drafts.count > limit else { return }
        for draft in drafts.prefix(drafts.count - limit) {
            remove(id: draft.envelope.id)
        }
    }

    /// `name` inside `folder`, refusing anything that would resolve outside
    /// it. Stored names are already checked; this holds even if they weren't.
    static func file(named name: String, in folder: URL) -> URL? {
        guard ShareDraftNames.isSafeStoredName(name) else { return nil }
        let url = folder.appendingPathComponent(name, isDirectory: false)
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        return url
    }

    static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static let protection: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
    ]
}

/// What the app tells the share sheet, through the App Group's defaults:
/// only the composer's attachment limit, so a share is capped the way the
/// composer would cap the same file.
enum ShareDraftSettings {
    static let composerLimitKey = "share.composerAttachmentLimitMB"

    static var groupDefaults: UserDefaults? { UserDefaults(suiteName: ShareDraftInbox.appGroup) }

    static func publishComposerLimit(megabytes: Int, to defaults: UserDefaults? = groupDefaults) {
        guard let defaults, defaults.integer(forKey: composerLimitKey) != megabytes else { return }
        defaults.set(megabytes, forKey: composerLimitKey)
    }

    static func composerLimit(from defaults: UserDefaults? = groupDefaults) -> Int? {
        guard let value = defaults?.integer(forKey: composerLimitKey), value > 0 else { return nil }
        return value
    }
}
