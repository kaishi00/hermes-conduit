import XCTest
@testable import Conduit

/// #195: inline chat media opens full screen for save/share. These cover the
/// pure pieces — which `MEDIA:` lines render as media, and the file names a
/// preview is staged and shared under.
///
/// An extension rather than its own class: the CI planner caps sequential
/// batches per lane, and one more class tips a lane over that cap. Hosting
/// these on a smoke-suite class also gets them onto the hosted runner.
extension MarkdownLargeDocumentTests {

    // MARK: - MEDIA: recognition

    func testMediaPreview_GatewayMediaPathStillRecognizesImages() {
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/out/result.png"), "/tmp/out/result.png")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:/tmp/a.JPEG?v=2"), "/tmp/a.JPEG?v=2")
    }

    func testMediaPreview_GatewayMediaPathRecognizesVideoAudioAndDocuments() {
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/clip.mp4"), "/tmp/clip.mp4")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/voice.ogg"), "/tmp/voice.ogg")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/report.pdf"), "/tmp/report.pdf")
    }

    func testMediaPreview_GatewayMediaPathRejectsUnknownExtensionsAndProse() {
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/archive.tar.gz"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/no-extension"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: see /tmp/clip.mp4 later"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("/tmp/clip.mp4"))
    }

    func testMediaPreview_ParsedVideoLineBecomesMediaBlockOnlyWhenGatewayMediaIsRecognized() {
        let source = "Here it is:\n\nMEDIA: /home/me/render.mov"
        let withGateway = MarkdownParser.parse(source, recognizesGatewayMedia: true)
        XCTAssertTrue(withGateway.contains { block in
            if case .image(let url, let alt) = block { return url == "MEDIA: /home/me/render.mov" && alt == "render.mov" }
            return false
        })
        let withoutGateway = MarkdownParser.parse(source, recognizesGatewayMedia: false)
        XCTAssertFalse(withoutGateway.contains { block in
            if case .image = block { return true }
            return false
        })
    }

    func testMediaPreview_GatewayMediaKindClassifiesByExtension() {
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.HEIC"), .image)
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.mov"), .video)
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.m4a?x=1"), .audio)
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.docx"), .document)
        XCTAssertNil(GatewayMediaKind(path: "/a/b.exe"))
    }

    // MARK: - File naming

    func testMediaPreview_SanitizedFilenameKeepsLastComponentWithoutQuery() {
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("/tmp/out/result.png?v=3"), "result.png")
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("C:\\renders\\clip.mp4"), "clip.mp4")
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("/tmp/.."), "media")
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename(""), "media")
    }

    func testMediaPreview_SanitizedFilenameTruncatesLongStemKeepingExtension() {
        let long = String(repeating: "é", count: 300) + ".mp4"
        let name = MediaPreviewPresenter.sanitizedFilename("/tmp/" + long)
        XCTAssertLessThanOrEqual(name.utf8.count, 200)
        XCTAssertTrue(name.hasSuffix(".mp4"))
        XCTAssertEqual(MediaPreviewPresenter.sanitizedFilename("/tmp/short.png"), "short.png")
    }

    func testMediaPreview_AttachmentPreviewFilenameBorrowsExtensionFromStoredPath() {
        XCTAssertEqual(AttachmentPreviewFilename.make(name: "Screenshot", uri: "/uploads/abc.png"), "Screenshot.png")
        XCTAssertEqual(AttachmentPreviewFilename.make(name: "photo.PNG", uri: "/uploads/abc.png"), "photo.PNG")
        // The stored path describes the bytes; a disagreeing name extension
        // would send Quick Look to the wrong renderer.
        XCTAssertEqual(AttachmentPreviewFilename.make(name: "photo.txt", uri: "/uploads/abc.png"), "photo.png")
        XCTAssertEqual(AttachmentPreviewFilename.make(name: "  ", uri: "/uploads/abc.png"), "abc.png")
    }

    // MARK: - Content policy

    func testMediaPreview_RefusesActiveWebContentByExtensionOrMIME() {
        XCTAssertFalse(MediaPreviewPresenter.isPreviewable(filename: "/tmp/page.html", mimeType: nil))
        XCTAssertFalse(MediaPreviewPresenter.isPreviewable(filename: "logo.SVG", mimeType: nil))
        XCTAssertFalse(MediaPreviewPresenter.isPreviewable(filename: "report.pdf", mimeType: "text/html; charset=utf-8"))
        XCTAssertTrue(MediaPreviewPresenter.isPreviewable(filename: "report.pdf", mimeType: "application/pdf"))
        XCTAssertTrue(MediaPreviewPresenter.isPreviewable(filename: "clip.mp4", mimeType: nil))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/page.html"))
    }

    func testMediaPreview_ReadsMIMETypeFromDataURLHeader() {
        XCTAssertEqual(MediaPreviewPresenter.mimeType(ofDataURL: "data:Text/HTML;base64,PGI+"), "text/html")
        XCTAssertEqual(MediaPreviewPresenter.mimeType(ofDataURL: "data:video/mp4;base64,AAAA"), "video/mp4")
        XCTAssertNil(MediaPreviewPresenter.mimeType(ofDataURL: "data:;base64,AAAA"))
        XCTAssertNil(MediaPreviewPresenter.mimeType(ofDataURL: "https://example.com/a.png"))
    }

    func testMediaPreview_StageWritesBytesUnderOriginalNameInOwnDirectory() throws {
        let data = Data("hello".utf8)
        let staged = try XCTUnwrap(MediaPreviewPresenter.stage(data: data, filename: "/remote/dir/note.txt"))
        defer { MediaPreviewPresenter.removeDirectory(staged.directory) }
        XCTAssertEqual(staged.file.lastPathComponent, "note.txt")
        XCTAssertEqual(staged.file.deletingLastPathComponent().standardizedFileURL, staged.directory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: staged.file), data)

        MediaPreviewPresenter.removeDirectory(staged.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
    }
}
