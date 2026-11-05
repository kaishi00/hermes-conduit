import CoreImage
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Conduit

/// The shared-draft envelope, its inbox and the share sheet's collector
/// (#812): what the extension writes and the app trusts.
final class ShareDraftTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareDraftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let workspace = WidgetWorkspaceID(dashboardID: UUID(uuidString: "00000000-0000-0000-0000-00000000d812")!, profile: "work")

    private func reference(scope: String = "work", session: String = "chat-1") -> WidgetConversationReference {
        WidgetConversationReference(kind: .dashboard, scopeProfile: scope, botName: nil, botLabel: nil, sessionID: session, isUnverified: false)
    }

    private func envelope(
        createdAt: Date = Date(),
        workspace: WidgetWorkspaceID?? = nil,
        target: ShareDraftTarget = .newChat,
        text: String = "Look at this",
        attachments: [ShareDraftAttachment] = []
    ) -> ShareDraftEnvelope {
        ShareDraftEnvelope(
            createdAt: createdAt,
            workspace: workspace ?? self.workspace,
            target: target,
            text: text,
            attachments: attachments
        )
    }

    // MARK: Envelope

    func testEnvelopeRoundTripsEveryTarget() throws {
        let file = ShareDraftAttachment(storedName: "1.pdf", displayName: "Report.pdf", typeIdentifier: "com.adobe.pdf", byteCount: 2048)
        for target in [ShareDraftTarget.newChat, .conversation(reference())] {
            let original = envelope(createdAt: Date(timeIntervalSince1970: 1_792_000_000), target: target, attachments: [file])
            let decoded = try ShareDraftEnvelope.decoded(from: ShareDraftEnvelope.encoded(original))
            XCTAssertEqual(decoded, original)
        }
        let noWorkspace = envelope(createdAt: Date(timeIntervalSince1970: 1_792_000_000.5), workspace: .some(nil))
        XCTAssertEqual(try ShareDraftEnvelope.decoded(from: ShareDraftEnvelope.encoded(noWorkspace)), noWorkspace)
    }

    func testEnvelopeOfAnotherSchemaIsRefused() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ShareDraftEnvelope.encoded(envelope())) as? [String: Any])
        object["schemaVersion"] = 2
        XCTAssertThrowsError(try ShareDraftEnvelope.decoded(from: JSONSerialization.data(withJSONObject: object)))
    }

    func testEnvelopeRulesHoldOnDecode() throws {
        // A chat target needs a workspace, and a dashboard chat its profile.
        XCTAssertFalse(envelope(workspace: .some(nil), target: .conversation(reference())).isValid)
        XCTAssertFalse(envelope(target: .conversation(reference(scope: "other"))).isValid)
        XCTAssertTrue(envelope(target: .conversation(reference())).isValid)
        // Nothing shared is no draft.
        XCTAssertFalse(envelope(text: "").isValid)
        // Over the caps.
        XCTAssertFalse(envelope(text: String(repeating: "a", count: ShareDraftLimits.maximumTextCharacters + 1)).isValid)
        let big = (1...3).map { ShareDraftAttachment(storedName: "\($0).bin", displayName: "f\($0)", typeIdentifier: nil, byteCount: 40 * 1024 * 1024) }
        XCTAssertFalse(envelope(attachments: big).isValid, "the total cap")
        let many = (1...(ShareDraftLimits.maximumAttachments + 1)).map {
            ShareDraftAttachment(storedName: "\($0).txt", displayName: "f\($0).txt", typeIdentifier: nil, byteCount: 1)
        }
        XCTAssertFalse(envelope(attachments: many).isValid, "the count cap")
        let twice = [ShareDraftAttachment(storedName: "1.txt", displayName: "a.txt", typeIdentifier: nil, byteCount: 1),
                     ShareDraftAttachment(storedName: "1.txt", displayName: "b.txt", typeIdentifier: nil, byteCount: 1)]
        XCTAssertFalse(envelope(attachments: twice).isValid, "one file per stored name")

        let invalid = envelope(workspace: .some(nil), target: .conversation(reference()))
        XCTAssertThrowsError(try ShareDraftEnvelope.decoded(from: ShareDraftEnvelope.encoded(invalid)))
    }

    func testStoredNamesCannotLeaveTheDraftFolder() throws {
        for unsafe in ["../envelope.json", "..", ".hidden", "a/b", "/etc/passwd", "", "a\u{0}b", "é.txt", String(repeating: "a", count: 65)] {
            XCTAssertFalse(ShareDraftNames.isSafeStoredName(unsafe), unsafe)
        }
        for safe in ["1", "1.jpg", "10.pdf", "2_a-b.txt"] {
            XCTAssertTrue(ShareDraftNames.isSafeStoredName(safe), safe)
        }
        XCTAssertEqual(ShareDraftNames.storedName(ordinal: 3, pathExtension: "PDF"), "3.pdf")
        XCTAssertEqual(ShareDraftNames.storedName(ordinal: 3, pathExtension: "../x"), "3")
        XCTAssertEqual(ShareDraftNames.storedName(ordinal: 3, pathExtension: nil), "3")

        // An envelope naming a path outside its folder doesn't decode.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ShareDraftEnvelope.encoded(envelope(
            attachments: [ShareDraftAttachment(storedName: "1.txt", displayName: "a.txt", typeIdentifier: nil, byteCount: 1)]
        ))) as? [String: Any])
        var files = try XCTUnwrap(object["attachments"] as? [[String: Any]])
        files[0]["storedName"] = "../../Library/Preferences/x.plist"
        object["attachments"] = files
        XCTAssertThrowsError(try ShareDraftEnvelope.decoded(from: JSONSerialization.data(withJSONObject: object)))
    }

    func testDisplayNamesAreLabelsOnly() {
        XCTAssertEqual(ShareDraftNames.sanitizedDisplayName("../../secret.txt"), "_.._secret.txt")
        XCTAssertEqual(ShareDraftNames.sanitizedDisplayName("  .hidden.pdf "), "hidden.pdf")
        XCTAssertEqual(ShareDraftNames.sanitizedDisplayName("a\nb\u{7}c:d\\e"), "a_b_c_d_e")
        XCTAssertEqual(ShareDraftNames.sanitizedDisplayName(". ."), "")
        let long = ShareDraftNames.sanitizedDisplayName(String(repeating: "x", count: 300) + ".pdf")
        XCTAssertEqual(long.count, ShareDraftNames.maximumDisplayNameLength)
        XCTAssertTrue(long.hasSuffix(".pdf"))
        for name in ["../../secret.txt", ". .x", " . a ", String(repeating: "y ", count: 200), "photo.HEIC"] {
            let once = ShareDraftNames.sanitizedDisplayName(name)
            XCTAssertEqual(ShareDraftNames.sanitizedDisplayName(once), once, "sanitizing is stable: \(name)")
        }
    }

    // MARK: Limits and expiry

    func testFileCapFollowsTheComposerLimitUpToTheShareMaximum() {
        let megabyte: Int64 = 1024 * 1024
        XCTAssertEqual(ShareDraftLimits.fileByteLimit(composerMegabytes: nil), 16 * megabyte)
        XCTAssertEqual(ShareDraftLimits.fileByteLimit(composerMegabytes: 32), 32 * megabyte)
        XCTAssertEqual(ShareDraftLimits.fileByteLimit(composerMegabytes: 256), 64 * megabyte)
        XCTAssertEqual(ShareDraftLimits.fileByteLimit(composerMegabytes: 0), 1 * megabyte)
    }

    func testDraftsExpireAfterADayAndFutureDatesAreRefused() {
        let now = Date()
        XCTAssertFalse(ShareDraftLimits.isExpired(createdAt: now.addingTimeInterval(-60 * 60), now: now))
        XCTAssertTrue(ShareDraftLimits.isExpired(createdAt: now.addingTimeInterval(-25 * 60 * 60), now: now))
        XCTAssertFalse(ShareDraftLimits.isExpired(createdAt: now.addingTimeInterval(60), now: now), "a small clock skew is fine")
        XCTAssertTrue(ShareDraftLimits.isExpired(createdAt: now.addingTimeInterval(60 * 60), now: now))
    }

    // MARK: Inbox

    private func stage(_ inbox: ShareDraftInbox, _ envelope: ShareDraftEnvelope, files: [String: Data] = [:]) throws {
        let staging = try inbox.beginStaging()
        for (name, data) in files { try data.write(to: staging.url.appendingPathComponent(name)) }
        try inbox.commit(envelope, from: staging)
    }

    func testCommittedDraftIsPendingOldestFirstWithItsFiles() throws {
        let inbox = ShareDraftInbox(directory: root)
        let now = Date()
        let file = ShareDraftAttachment(storedName: "1.txt", displayName: "notes.txt", typeIdentifier: "public.plain-text", byteCount: 5)
        let newer = envelope(createdAt: now, attachments: [file])
        let older = envelope(createdAt: now.addingTimeInterval(-60), text: "first")
        try stage(inbox, newer, files: ["1.txt": Data("hello".utf8)])
        try stage(inbox, older)

        let pending = inbox.pending(now: now)
        XCTAssertEqual(pending.map(\.envelope.id), [older.id, newer.id])
        let draft = try XCTUnwrap(inbox.pending(id: newer.id, now: now))
        let url = try XCTUnwrap(inbox.file(for: file, in: draft))
        XCTAssertEqual(try Data(contentsOf: url), Data("hello".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(ShareDraftInbox.stagingPrefix) })

        inbox.remove(id: newer.id)
        XCTAssertEqual(inbox.pending(now: now).map(\.envelope.id), [older.id])
    }

    func testCommitRefusesAnEnvelopeWhoseFileIsMissing() throws {
        let inbox = ShareDraftInbox(directory: root)
        let staging = try inbox.beginStaging()
        let file = ShareDraftAttachment(storedName: "1.txt", displayName: "notes.txt", typeIdentifier: nil, byteCount: 5)
        XCTAssertThrowsError(try inbox.commit(envelope(attachments: [file]), from: staging))
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testExpiredUnreadableAndAbandonedDraftsAreDeleted() throws {
        let inbox = ShareDraftInbox(directory: root)
        let now = Date()
        let stale = envelope(createdAt: now.addingTimeInterval(-ShareDraftLimits.lifetime - 60))
        try stage(inbox, stale)
        // Not a draft folder, and a folder with a broken envelope.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("junk"), withIntermediateDirectories: true)
        let broken = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: broken.appendingPathComponent(ShareDraftInbox.envelopeFilename))
        // A share that started an hour and a bit ago and never finished, and
        // one still being written.
        let abandoned = try inbox.beginStaging()
        let current = try inbox.beginStaging()

        XCTAssertTrue(inbox.pending(now: now).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.url.path), "a share still being written stays")
        XCTAssertTrue(inbox.pending(now: now.addingTimeInterval(ShareDraftInbox.abandonedStagingAge + 60)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testOnlyTheNewestDraftsAreKept() throws {
        let inbox = ShareDraftInbox(directory: root)
        let now = Date()
        var ids: [UUID] = []
        for index in 0..<(ShareDraftLimits.maximumPendingDrafts + 2) {
            let draft = envelope(createdAt: now.addingTimeInterval(Double(index)))
            ids.append(draft.id)
            try stage(inbox, draft)
        }
        XCTAssertEqual(inbox.pending(now: now).map(\.envelope.id), Array(ids.suffix(ShareDraftLimits.maximumPendingDrafts)))
    }

    func testALinkPlantedInADraftIsNotFollowed() throws {
        let inbox = ShareDraftInbox(directory: root)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let file = ShareDraftAttachment(storedName: "1.txt", displayName: "notes.txt", typeIdentifier: nil, byteCount: 6)
        let draft = envelope(attachments: [file])
        try stage(inbox, draft, files: ["1.txt": Data("inside".utf8)])
        let pending = try XCTUnwrap(inbox.pending(id: draft.id))
        let planted = pending.folder.appendingPathComponent("1.txt")
        try FileManager.default.removeItem(at: planted)
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)

        XCTAssertNil(inbox.file(for: file, in: pending))
    }

    func testRemoveAllTakesOnlyTheDraftsAsked() throws {
        let inbox = ShareDraftInbox(directory: root)
        let other = WidgetWorkspaceID(dashboardID: UUID(), profile: "default")
        let mine = envelope()
        let theirs = envelope(workspace: .some(other))
        try stage(inbox, mine)
        try stage(inbox, theirs)
        _ = try inbox.beginStaging()

        inbox.removeAll { $0.workspace?.dashboardID == self.workspace.dashboardID }

        XCTAssertEqual(inbox.pending().map(\.envelope.id), [theirs.id])
        let staged = { try FileManager.default.contentsOfDirectory(atPath: self.root.path).contains { $0.hasPrefix(ShareDraftInbox.stagingPrefix) } }
        XCTAssertTrue(try staged(), "a share still being written stays")
        inbox.removeAll(now: Date().addingTimeInterval(ShareDraftInbox.abandonedStagingAge + 60)) { _ in false }
        XCTAssertFalse(try staged())
    }

    func testAnEnvelopeTooBigToReadIsNotWritten() throws {
        let inbox = ShareDraftInbox(directory: root)
        let staging = try inbox.beginStaging()
        // Control characters escape to six bytes each in JSON.
        let text = String(repeating: "\u{1}", count: ShareDraftLimits.maximumTextBytes)
        XCTAssertThrowsError(try inbox.commit(envelope(text: text), from: staging))
        XCTAssertTrue(inbox.pending().isEmpty)
    }

    func testTextIsCappedInBytesToo() {
        let emoji = String(repeating: "👩‍👩‍👧‍👦", count: 50_000)
        let cut = ShareDraftLimits.truncated(emoji, characters: ShareDraftLimits.maximumTextCharacters)
        XCTAssertLessThanOrEqual(cut.utf8.count, ShareDraftLimits.maximumTextBytes)
        XCTAssertGreaterThan(cut.utf8.count, ShareDraftLimits.maximumTextBytes - 200)
        XCTAssertTrue(emoji.hasPrefix(cut))
    }

    func testAFileSharedByItsURLAlone() async throws {
        let (collector, staging) = try collector()
        let source = root.appendingPathComponent("src-\(UUID().uuidString).pdf")
        try Data(repeating: 1, count: 64).write(to: source)
        let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        provider.suggestedName = "Statement.pdf"

        let result = await collector.collect(providers: [provider])

        XCTAssertEqual(result.attachments.map(\.displayName), ["Statement.pdf"])
        XCTAssertEqual(result.attachments.first?.byteCount, 64)
        XCTAssertTrue(result.problems.isEmpty, "\(result.problems)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.url.appendingPathComponent("1.pdf").path))
    }

    func testComposerLimitIsPublishedForTheShareSheet() throws {
        let suite = "ShareDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(ShareDraftSettings.composerLimit(from: defaults))
        ShareDraftSettings.publishComposerLimit(megabytes: 32, to: defaults)
        XCTAssertEqual(ShareDraftSettings.composerLimit(from: defaults), 32)
    }

    // MARK: Collector

    private func collector(fileLimit: Int64 = 1024, total: Int64 = 4096, maxFiles: Int = 3, maxText: Int = 1000) throws -> (ShareDraftCollector, ShareDraftStagingFolder) {
        let staging = try ShareDraftInbox(directory: root).beginStaging()
        return (ShareDraftCollector(staging: staging, fileByteLimit: fileLimit, totalByteLimit: total, maximumAttachments: maxFiles, maximumTextCharacters: maxText), staging)
    }

    private func fileProvider(named name: String, bytes: Int, type: UTType) throws -> NSItemProvider {
        let source = root.appendingPathComponent("src-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "bin")")
        try Data(repeating: 7, count: bytes).write(to: source)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        provider.suggestedName = name
        return provider
    }

    func testTextAndALinkBecomeTheDraftText() async throws {
        let (collector, _) = try collector()
        let text = NSItemProvider(object: "Worth a read" as NSString)
        let link = NSItemProvider(object: URL(string: "https://example.com/a")! as NSURL)

        let result = await collector.collect(providers: [text, link])

        XCTAssertEqual(result.text, "Worth a read\n\nhttps://example.com/a")
        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertTrue(result.problems.isEmpty)
    }

    func testALinkAlreadyInTheTextIsNotRepeated() async throws {
        let (collector, _) = try collector()
        let text = NSItemProvider(object: "See https://example.com/a" as NSString)
        let link = NSItemProvider(object: URL(string: "https://example.com/a")! as NSURL)
        let result = await collector.collect(providers: [text, link])
        XCTAssertEqual(result.text, "See https://example.com/a")
    }

    func testThePageTitleIsUsedOnlyWithoutSharedText() async throws {
        let (collector, _) = try collector()
        let link = NSItemProvider(object: URL(string: "https://example.com/a")! as NSURL)
        let titled = await collector.collect(providers: [link], itemText: ["An article"])
        XCTAssertEqual(titled.text, "An article\n\nhttps://example.com/a")
        let text = NSItemProvider(object: "My note" as NSString)
        let both = await collector.collect(providers: [text], itemText: ["An article"])
        XCTAssertEqual(both.text, "My note")
    }

    func testFilesAreCopiedUnderTheirOwnNamesAndLabelledSafely() async throws {
        let (collector, staging) = try collector()
        let pdf = try fileProvider(named: "../../Report.pdf", bytes: 100, type: .pdf)
        let picture = try fileProvider(named: "", bytes: 50, type: .png)

        let result = await collector.collect(providers: [pdf, picture])

        XCTAssertEqual(result.attachments.map(\.storedName), ["1.pdf", "2.png"])
        XCTAssertEqual(result.attachments.map(\.displayName), ["_.._Report.pdf", "photo-2.png"])
        XCTAssertEqual(result.attachments.map(\.byteCount), [100, 50])
        XCTAssertEqual(result.attachments.first?.typeIdentifier, UTType.pdf.identifier)
        for attachment in result.attachments {
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.url.appendingPathComponent(attachment.storedName).path))
        }
        XCTAssertTrue(result.problems.isEmpty)
    }

    /// The screenshot editor's Share offers the picture only as an image
    /// object, under UIKit's own type (#1747): it's attached as a PNG.
    func testAPictureOfferedOnlyAsAnImageObjectIsAttachedAsPNG() async throws {
        let (collector, staging) = try collector()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let archived = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: ShareDraftCollector.imageObjectType, visibility: .all) { completion in
            completion(archived, nil)
            return nil
        }
        XCTAssertTrue(provider.canLoadObject(ofClass: UIImage.self), "UIKit reads its own image type")
        XCTAssertNil(ShareDraftCollector.fileType(of: provider), "an archived image object is not a picture file")
        XCTAssertEqual(ShareDraftCollector.kind(of: provider), .file)

        let result = await collector.collect(providers: [provider])

        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.attachments.map(\.storedName), ["1.png"])
        XCTAssertEqual(result.attachments.map(\.displayName), ["photo.png"])
        XCTAssertEqual(result.attachments.first?.typeIdentifier, UTType.png.identifier)
        let stored = try Data(contentsOf: staging.url.appendingPathComponent("1.png"))
        XCTAssertEqual(Array(stored.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "written as PNG")

        // A suggested name keeps its stem and takes .png, multi-dot names too.
        for (suggested, expected) in [("shot.jpg", "shot.png"), ("photo.edited.heic", "photo.edited.png")] {
            let (named, _) = try self.collector()
            provider.suggestedName = suggested
            let renamed = await named.collect(providers: [provider])
            XCTAssertEqual(renamed.attachments.map(\.displayName), [expected])
            XCTAssertEqual(renamed.attachments.map(\.storedName), ["1.png"])
        }
    }

    /// A provider that also offers the picture as a file is read as that
    /// file, never as UIKit's archived object.
    func testAPictureFileWinsOverItsImageObject() async throws {
        let (collector, _) = try collector()
        let provider = try fileProvider(named: "shot.png", bytes: 10, type: .png)
        provider.registerDataRepresentation(forTypeIdentifier: ShareDraftCollector.imageObjectType, visibility: .all) { completion in
            completion(Data([1]), nil)
            return nil
        }
        XCTAssertEqual(ShareDraftCollector.fileType(of: provider), .png)

        let result = await collector.collect(providers: [provider])

        XCTAssertEqual(result.attachments.map(\.displayName), ["shot.png"])
        XCTAssertEqual(result.attachments.map(\.byteCount), [10], "the PNG file, not the image object")
    }

    private func redSquare() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private struct ProviderFailure: LocalizedError {
        var errorDescription: String? { "The picture went away." }
    }

    /// A provider that lists a picture file it can't hand over.
    private func brokenPictureProvider(named name: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(nil, false, ProviderFailure())
            return nil
        }
        provider.suggestedName = name
        return provider
    }

    /// The screenshot editor on build 251 (issue 1747): the provider lists
    /// a PNG but can't hand its file over. The picture is still read, as
    /// the image object it also offers.
    func testAPictureWhoseFileCantBeReadIsTakenAsItsImageObject() async throws {
        let (collector, staging) = try collector()
        let provider = brokenPictureProvider(named: "Screenshot 2026-11-05 at 13.19.47.png")
        let archived = try NSKeyedArchiver.archivedData(withRootObject: redSquare(), requiringSecureCoding: true)
        provider.registerDataRepresentation(forTypeIdentifier: ShareDraftCollector.imageObjectType, visibility: .all) { completion in
            completion(archived, nil)
            return nil
        }
        XCTAssertEqual(ShareDraftCollector.fileType(of: provider), .png)

        let result = await collector.collect(providers: [provider])

        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.attachments.map(\.storedName), ["1.png"])
        XCTAssertEqual(result.attachments.map(\.displayName), ["Screenshot 2026-11-05 at 13.19.47.png"])
        let stored = try Data(contentsOf: staging.url.appendingPathComponent("1.png"))
        XCTAssertEqual(Array(stored.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "written as PNG")
    }

    /// A document whose file fails is never replaced by a picture of it.
    func testADocumentWhoseFileFailsIsNotTakenAsItsPreview() async throws {
        let (collector, _) = try collector()
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(nil, false, ProviderFailure())
            return nil
        }
        let archived = try NSKeyedArchiver.archivedData(withRootObject: redSquare(), requiringSecureCoding: true)
        provider.registerDataRepresentation(forTypeIdentifier: ShareDraftCollector.imageObjectType, visibility: .all) { completion in
            completion(archived, nil)
            return nil
        }
        provider.suggestedName = "Report.pdf"

        let result = await collector.collect(providers: [provider])

        XCTAssertTrue(result.attachments.isEmpty, "\(result.attachments)")
        XCTAssertEqual(result.problems.count, 1)
    }

    /// When every way fails, the sheet says so with the system's reason.
    func testAPictureNoWayReadsIsLeftOutWithTheReason() async throws {
        let (collector, staging) = try collector()

        let result = await collector.collect(providers: [brokenPictureProvider(named: "shot.png")])

        XCTAssertTrue(result.attachments.isEmpty)
        guard case .unreadable(let name, let reason)? = result.problems.first, result.problems.count == 1 else {
            return XCTFail("\(result.problems)")
        }
        XCTAssertEqual(name, "shot.png")
        XCTAssertFalse(reason?.isEmpty ?? true, "the system's reason is kept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.url.path), [], "nothing left on disk")
    }

    /// A picture with no bitmap of its own (drawn from a CIImage) has no
    /// pngData(); it is drawn once and that is written.
    func testAPictureWithoutABitmapIsDrawnBeforeItIsWritten() throws {
        let ciImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = try XCTUnwrap(ProviderPicture.pngData(UIImage(ciImage: ciImage)))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(decoded.width, 4 * Int(UIImage(ciImage: ciImage).scale), "the whole picture is drawn")
        // Its pixel is the red that was drawn, not a blank redraw.
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(drawn)
        XCTAssertGreaterThan(pixel[0], 200, "red")
        XCTAssertLessThan(pixel[1], 60, "not green")
        XCTAssertEqual(pixel[3], 255, "opaque")
        XCTAssertNotNil(ProviderPicture.pngData(redSquare()))
    }

    /// A provider whose file can't be handed over whatever it registers,
    /// as the screenshot editor's was on build 251.
    private final class FileFailingProvider: NSItemProvider {
        override func loadFileRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress {
            completionHandler(nil, ProviderFailure())
            return Progress(totalUnitCount: 0)
        }
    }

    private func picturePNG() throws -> Data {
        try XCTUnwrap(redSquare().pngData())
    }

    /// When the file fails, the picture's own bytes are taken next, as
    /// they are: a PNG stays the PNG it was.
    func testAPictureWhoseFileFailsIsTakenAsItsBytes() async throws {
        let (collector, staging) = try collector()
        let png = try picturePNG()
        let provider = FileFailingProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        provider.suggestedName = "shot.png"

        let result = await collector.collect(providers: [provider])

        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.attachments.map(\.displayName), ["shot.png"])
        XCTAssertEqual(result.attachments.map(\.byteCount), [Int64(png.count)])
        XCTAssertEqual(try Data(contentsOf: staging.url.appendingPathComponent("1.png")), png, "the bytes as handed over")
    }

    /// Bytes over the limit are refused as too large, not decoded, and
    /// nothing else is tried: the same picture is no smaller another way.
    func testAPictureWhoseBytesAreOverTheLimitIsTooLarge() async throws {
        let png = try picturePNG()
        let (collector, staging) = try collector(fileLimit: Int64(png.count) - 1)
        let provider = FileFailingProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(png, nil)
            return nil
        }
        provider.suggestedName = "shot.png"

        let result = await collector.collect(providers: [provider])

        XCTAssertTrue(result.attachments.isEmpty)
        XCTAssertEqual(result.problems, [.fileTooLarge(name: "shot.png", limitBytes: Int64(png.count) - 1)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.url.path), [], "nothing left on disk")
    }

    /// Bytes that aren't a picture, or whose header claims more pixels
    /// than a redraw may take, are not taken as one.
    func testPictureBytesMustDecodeWithinTheBound() throws {
        XCTAssertTrue(ProviderPicture.decodes(try picturePNG()))
        XCTAssertFalse(ProviderPicture.decodes(Data(repeating: 7, count: 64)))
        XCTAssertFalse(ProviderPicture.decodes(Self.pngHeader(width: 20_000, height: 20_000)), "400 megapixels is never decoded")
    }

    /// A PNG signature and header chunk alone: enough for ImageIO to read
    /// the size it claims.
    private static func pngHeader(width: UInt32, height: UInt32) -> Data {
        func bigEndian(_ value: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) } }
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
            }
            return ~crc
        }
        let chunk: [UInt8] = Array("IHDR".utf8) + bigEndian(width) + bigEndian(height) + [8, 6, 0, 0, 0]
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += bigEndian(13) + chunk + bigEndian(crc32(chunk))
        return Data(bytes)
    }

    func testCapsLeaveFilesOutAndSayWhy() async throws {
        let (collector, staging) = try collector(fileLimit: 1000, total: 1500, maxFiles: 2)
        let huge = try fileProvider(named: "huge.pdf", bytes: 1001, type: .pdf)
        let first = try fileProvider(named: "a.pdf", bytes: 1000, type: .pdf)
        let pastTotal = try fileProvider(named: "b.pdf", bytes: 600, type: .pdf)
        let fits = try fileProvider(named: "c.pdf", bytes: 400, type: .pdf)
        let pastCount = try fileProvider(named: "d.pdf", bytes: 10, type: .pdf)

        let result = await collector.collect(providers: [huge, first, pastTotal, fits, pastCount])

        XCTAssertEqual(result.attachments.map(\.displayName), ["a.pdf", "c.pdf"])
        XCTAssertEqual(result.problems, [
            .fileTooLarge(name: "huge.pdf", limitBytes: 1000),
            .totalTooLarge(name: "b.pdf", limitBytes: 1500),
            .tooManyFiles(dropped: 1, limit: 2),
        ])
        let left = try FileManager.default.contentsOfDirectory(atPath: staging.url.path).sorted()
        XCTAssertEqual(left, result.attachments.map(\.storedName).sorted(), "nothing left out stays on disk")
    }

    func testLongTextIsCut() async throws {
        let (collector, _) = try collector(maxText: 10)
        let result = await collector.collect(providers: [NSItemProvider(object: "0123456789abc" as NSString)])
        XCTAssertEqual(result.text, "0123456789")
        XCTAssertEqual(result.problems, [.textTruncated(limit: 10)])
    }

    /// Text another app hands over as bytes: UTF-8, or UTF-16 marked by its
    /// byte order mark, never unreadable bytes guessed into text.
    func testSharedTextBytesReadAsUTF8OrMarkedUTF16() throws {
        XCTAssertEqual(ShareDraftCollector.text(from: Data("Café notes".utf8)), "Café notes")
        let littleEndianBytes = try XCTUnwrap("Café notes".data(using: .utf16LittleEndian))
        let littleEndian = Data([0xFF, 0xFE]) + littleEndianBytes
        XCTAssertEqual(ShareDraftCollector.text(from: littleEndian), "Café notes")
        let bigEndianBytes = try XCTUnwrap("Café notes".data(using: .utf16BigEndian))
        let bigEndian = Data([0xFE, 0xFF]) + bigEndianBytes
        XCTAssertEqual(ShareDraftCollector.text(from: bigEndian), "Café notes")
        XCTAssertNil(ShareDraftCollector.text(from: Data([0xC3, 0x28, 0xA0, 0xA1])), "Not text in either")
    }

    func testProviderKinds() throws {
        XCTAssertEqual(ShareDraftCollector.kind(of: NSItemProvider(object: "x" as NSString)), .text)
        XCTAssertEqual(ShareDraftCollector.kind(of: NSItemProvider(object: URL(string: "https://example.com")! as NSURL)), .link)
        XCTAssertEqual(ShareDraftCollector.kind(of: try fileProvider(named: "a.jpg", bytes: 1, type: .jpeg)), .file)
        XCTAssertEqual(ShareDraftCollector.kind(of: try fileProvider(named: "notes.txt", bytes: 1, type: .plainText)), .file, "a named text file stays a file")
        XCTAssertEqual(ShareDraftCollector.kind(of: NSItemProvider()), .unsupported)
    }
}
