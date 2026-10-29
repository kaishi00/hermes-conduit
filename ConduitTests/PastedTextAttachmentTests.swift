//
//  PastedTextAttachmentTests.swift
//  ConduitTests
//
//  A long paste becomes a text attachment (PastedText): Hermes Desktop's
//  threshold and file name, so both apps read it as pasted content, and
//  its text survives an edit and going back into the message.
//

import XCTest
@testable import Conduit

extension ComposerAttachmentPolicyTests {
    func testOnlyPastesPastDesktopsThresholdBecomeAttachments() {
        XCTAssertFalse(PastedText.becomesAttachment(String(repeating: "a", count: 3_000)))
        XCTAssertTrue(PastedText.becomesAttachment(String(repeating: "a", count: 3_001)))
        XCTAssertFalse(PastedText.becomesAttachment(""))
    }

    func testAPasteIsNamedAsDesktopNamesIt() {
        let date = Date(timeIntervalSince1970: 1_793_300_000.25)
        let name = PastedText.filename(now: date)
        XCTAssertTrue(name.hasPrefix("pasted_content_"), name)
        XCTAssertTrue(name.hasSuffix(".txt"), name)
        XCTAssertNotNil(name.wholeMatch(of: #/pasted_content_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}_[0-9a-f]{6}\.txt/#), name)
        XCTAssertTrue(PastedText.isPastedText(name))
    }

    func testPastesAreKnownByNameWhereverHermesStoredThem() {
        XCTAssertTrue(PastedText.isPastedText("pasted_content_2026-10-29_20-50-06-123_a1b2c3.txt"))
        XCTAssertTrue(PastedText.isPastedText("attachments/pasted_content_2026-10-29_20-50-06-123_a1b2c3-2.txt"))
        XCTAssertFalse(PastedText.isPastedText("notes.txt"))
        XCTAssertFalse(PastedText.isPastedText("pasted_content_2026.pdf"))

        let file = Attachment(id: "a", name: "pasted_content_x.txt", uri: "/tmp/x", mimeType: "text/plain", kind: .document)
        XCTAssertEqual(AttachmentTypePolicy.displayName(for: file), PastedText.displayName)
        XCTAssertEqual(AttachmentTypePolicy.symbolName(for: file), "doc.plaintext")
        let other = Attachment(id: "b", name: "report.pdf", uri: "/tmp/r", mimeType: "application/pdf", kind: .document)
        XCTAssertEqual(AttachmentTypePolicy.displayName(for: other), "report.pdf")
    }

    func testAPasteIsStagedAsTextAndKeepsItsIdWhenEdited() throws {
        let pasted = String(repeating: "line of a log\n", count: 400)
        guard case .staged(let attachment) = PastedText.stage(pasted, limitMegabytes: 16) else {
            return XCTFail("the paste wasn't staged")
        }
        defer { ComposerBar.discardStagedFile(attachment) }
        XCTAssertEqual(attachment.kind, .document)
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertTrue(PastedText.isPastedText(attachment))
        XCTAssertEqual(PastedText.text(of: attachment), pasted)

        guard case .staged(let edited) = PastedText.restage(attachment, with: "shorter", limitMegabytes: 16) else {
            return XCTFail("the edit wasn't staged")
        }
        defer { ComposerBar.discardStagedFile(edited) }
        XCTAssertEqual(edited.id, attachment.id)
        XCTAssertEqual(edited.name, attachment.name)
        XCTAssertNotEqual(edited.uri, attachment.uri)
        XCTAssertEqual(PastedText.text(of: edited), "shorter")
    }

    func testAPasteOverTheLimitIsNamedAsPastedText() {
        let pasted = String(repeating: "x", count: 1024 * 1024 + 1)
        guard case .tooLarge(let name) = PastedText.stage(pasted, limitMegabytes: 1) else {
            return XCTFail("a paste over the limit was staged")
        }
        XCTAssertEqual(name, PastedText.displayName)
    }

    func testAPastePutBackGoesAfterWhatWasTyped() {
        XCTAssertEqual(PastedText.joined("", with: "log"), "log")
        XCTAssertEqual(PastedText.joined("  \n", with: "log"), "log")
        XCTAssertEqual(PastedText.joined("Why does this fail?", with: "log"), "Why does this fail?\n\nlog")
        XCTAssertEqual(PastedText.joined("Why?\n", with: "log"), "Why?\n\nlog")
    }

    func testTheChipPreviewsThePastesFirstWords() {
        XCTAssertEqual(PastedText.preview(of: "\n\n   First line  \nsecond"), "First line")
        let long = String(repeating: "w", count: 100)
        XCTAssertEqual(PastedText.preview(of: long, limit: 10), "wwwwwwwwww…")
    }
}

extension ComposerAttachmentPolicyTests {
    func testHermesTitlesAPasteFromItsFirstThousandCharacters() {
        let pasted = String(repeating: "é", count: 5_000)
        guard case .staged(let attachment) = PastedText.stage(pasted, limitMegabytes: 16) else {
            return XCTFail("the paste wasn't staged")
        }
        defer { ComposerBar.discardStagedFile(attachment) }
        let picture = Attachment(id: "p", name: "photo.jpg", uri: "file:///nowhere.jpg", mimeType: "image/jpeg", kind: .image)
        XCTAssertEqual(PastedText.titlePreview(in: [picture, attachment]), String(repeating: "é", count: 1_000))
        XCTAssertNil(PastedText.titlePreview(in: [picture]))
    }
}
