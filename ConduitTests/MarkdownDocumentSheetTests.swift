//
//  MarkdownDocumentSheetTests.swift
//  ConduitTests
//
//  The decisions a Markdown artifact makes before its sheet is drawn: which
//  names are Markdown, how the host's text is decoded, and the file name the
//  Open/Share handoff uses on a Windows or a Mac host.
//

import XCTest
@testable import Conduit

/// Counts the host reads a load makes.
private actor MarkdownLoadProbe {
    private(set) var calls = 0
    let response: String?

    init(response: String?) { self.response = response }

    func fetch() -> String? {
        calls += 1
        return response
    }
}

final class MarkdownDocumentSheetTests: XCTestCase {
    func testMarkdownNamesFromWindowsAndMacPaths() {
        XCTAssertTrue(MarkdownArtifact.isMarkdown("C:\\Hermes\\work\\PLAN.md"))
        XCTAssertTrue(MarkdownArtifact.isMarkdown("G:\\Hermes\\documents\\card.markdown"))
        XCTAssertTrue(MarkdownArtifact.isMarkdown("/Users/chencha/Hermes/notes.mdown"))
        XCTAssertTrue(MarkdownArtifact.isMarkdown("REPORT.MD"))
        XCTAssertTrue(MarkdownArtifact.isMarkdown("PLAN.md?download=1"))
        XCTAssertFalse(MarkdownArtifact.isMarkdown("C:\\Hermes\\work\\PLAN.txt"))
        XCTAssertFalse(MarkdownArtifact.isMarkdown("README"))
    }

    func testDecodedTextIsTheFileAndBinaryIsRefused() {
        let source = "# Plan\n\n| host | state |\n|---|---|\n| Mac | ready |\n"
        let dataURL = "data:text/markdown;base64," + Data(source.utf8).base64EncodedString()
        XCTAssertEqual(MarkdownArtifact.text(from: dataURL), source)

        let binary = Data([0xFF, 0xFE, 0xFD]).base64EncodedString()
        XCTAssertNil(MarkdownArtifact.text(from: "data:application/octet-stream;base64,\(binary)"))
        XCTAssertNil(MarkdownArtifact.text(from: "data:text/markdown;base64,"))
        XCTAssertNil(MarkdownArtifact.text(from: dataURL, maxBytes: 4))
    }

    func testHandoffNameKeepsTheLastComponentOnBothHosts() {
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("C:\\Hermes\\work\\PLAN.md"), "PLAN.md")
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("/Users/chencha/Hermes/PLAN.md"), "PLAN.md")
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("PLAN.md?download=1"), "PLAN.md")
    }

    func testHandoffKeepsAMarkdownNameWhenTheCardsLabelHasNone() {
        XCTAssertEqual(MarkdownArtifact.handoffName(title: "Report", path: "/tmp/out/PLAN.md"), "PLAN.md")
        XCTAssertEqual(MarkdownArtifact.handoffName(title: "Report", path: "C:\\Hermes\\PLAN.md"), "PLAN.md")
        XCTAssertEqual(MarkdownArtifact.handoffName(title: "notes.md", path: "/tmp/x/other.md"), "notes.md")
    }

    func testLoadSkipsAFileKnownToBeOverTheCeiling() async {
        // The host would answer, so a nil says the reader never asked: the
        // fallback downloads the file once instead.
        let dataURL = "data:text/markdown;base64," + Data("# Big".utf8).base64EncodedString()
        let probe = MarkdownLoadProbe(response: dataURL)
        let text = await MarkdownArtifact.load(
            path: "/tmp/BIG.md", knownSize: Int64(DataURLLimits.maxDecodedBytes) + 1,
            dataURL: { _ in await probe.fetch() }
        )
        XCTAssertNil(text)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    func testLoadReadsTheTextAndFallsBackWhenTheHostHasNone() async {
        let source = "# Notes\n\n- [x] done\n"
        let dataURL = "data:text/markdown;base64," + Data(source.utf8).base64EncodedString()
        let loaded = await MarkdownArtifact.load(path: "C:\\Hermes\\notes.md", dataURL: { _ in dataURL })
        XCTAssertEqual(loaded, source)
        let missing = await MarkdownArtifact.load(path: "/Users/x/gone.md", dataURL: { _ in nil })
        XCTAssertNil(missing)
    }
}
