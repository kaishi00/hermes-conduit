import Compression
import UIKit
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

    // MARK: - Web pictures load within bounds

    private func remoteTestPNG(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// A real, all-black 1-bit PNG: about 10 KB for 9,000 × 9,000, which
    /// decodes to 81 megapixels.
    private func remoteTestPNGBomb(side: UInt32) -> Data {
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0) }
            }
            return ~crc
        }
        func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
        }
        let raw = [UInt8](repeating: 0, count: (Int(side + 7) / 8 + 1) * Int(side))
        var deflated = [UInt8](repeating: 0, count: raw.count / 100 + 4096)
        let deflatedCount = compression_encode_buffer(&deflated, deflated.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        // zlib header, raw deflate, Adler-32 (all zeros: a = 1, b = length).
        let idat = [0x78, 0x9C] + deflated[0..<deflatedCount] + bigEndian(UInt32(raw.count % 65521) << 16 | 1)
        let header = bigEndian(side) + bigEndian(side) + [1, 0, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            + chunk("IHDR", header) + chunk("IDAT", idat) + chunk("IEND", []))
    }

    func testRemoteImage_ALargePictureIsDownsampledToTheSizeShown() {
        guard case .image(let image) = BoundedRemoteImage.decode(remoteTestPNG(width: 3000, height: 1200), maxPixelSize: 600) else {
            return XCTFail("A picture within bounds loads")
        }
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height) * image.scale, 600)
    }

    func testRemoteImage_ASmallFileOfHugeDimensionsIsRefusedUndecoded() {
        let bomb = remoteTestPNGBomb(side: 9_000)
        XCTAssertLessThan(bomb.count, 64 * 1024)
        guard case .tooLarge = BoundedRemoteImage.decode(bomb, maxPixelSize: 600) else {
            return XCTFail("81 megapixels is never decoded")
        }
    }

    func testRemoteImage_APastedLinkOfHugeDimensionsIsNotAttached() {
        // The composer uploads a pasted picture link to the gateway: one
        // whose header claims 81 megapixels is refused as a markdown image is.
        XCTAssertNil(PastedRemoteImage.image(from: remoteTestPNGBomb(side: 9_000)))
        XCTAssertNotNil(PastedRemoteImage.image(from: remoteTestPNG(width: 300, height: 200)))
    }

    func testRemoteImage_APageThatIsNotAPictureIsUnavailable() {
        guard case .unavailable = BoundedRemoteImage.decode(Data("<html><body>Not found</body></html>".utf8), maxPixelSize: 600) else {
            return XCTFail("Not a picture")
        }
    }

    func testRemoteImage_ADownloadOverTheCeilingIsNotHandedToTheWebView() async {
        let outcome = await BoundedRemoteImage.load(URL(string: "https://example.test/huge.png")!, maxPixelSize: 600) { _ in .tooLarge }
        guard case .tooLarge = outcome else { return XCTFail("Offered as a link instead") }
    }

    func testRemoteImage_AFailedFetchStillTriesTheWebView() async {
        let outcome = await BoundedRemoteImage.load(URL(string: "https://example.test/a.png")!, maxPixelSize: 600) { _ in .failed }
        guard case .unavailable = outcome else { return XCTFail("The web view gets its chance") }
    }

    func testRemoteImage_APictureShownAgainIsNotDownloadedAgain() async {
        let url = URL(string: "https://example.test/\(UUID().uuidString).png")!
        let png = remoteTestPNG(width: 40, height: 20)
        var downloads = 0
        let download: (URL) async -> BoundedDownloadResult = { _ in
            downloads += 1
            return .downloaded(png, URLResponse())
        }

        guard case .image = await BoundedRemoteImage.load(url, maxPixelSize: 600, download: download),
              case .image = await BoundedRemoteImage.load(url, maxPixelSize: 600, download: download) else {
            return XCTFail("A picture within bounds loads")
        }

        XCTAssertEqual(downloads, 1)
        XCTAssertNotNil(BoundedRemoteImage.cachedImage(url, maxPixelSize: 600))
        // Another size is its own picture.
        XCTAssertNil(BoundedRemoteImage.cachedImage(url, maxPixelSize: 360))
    }

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

    func testMediaPreview_GatewayMediaPathRejectsProseAndBarePaths() {
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: see /tmp/clip.mp4 later"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("/tmp/clip.mp4"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: /"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("`MEDIA:/tmp/example.png`"))
        XCTAssertNil(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/out is where results go"))
    }

    // MARK: - #439: any MEDIA: path Hermes would deliver

    func testMediaPreview_GatewayMediaPathAcceptsPathsWithSpaces() {
        let spaced = "/Users/nealbailey/Neal Master/Private/Mimeeq Sale/PandaDoc/Mimeeq_Overview_for_PandaDoc_2026-10.pdf"
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:\(spaced)"), spaced)
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: \(spaced)  "), spaced)
    }

    func testMediaPreview_GatewayMediaPathAcceptsAnyFileAloneOnItsLine() {
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/archive.tar.gz"), "/tmp/archive.tar.gz")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/no-extension"), "/tmp/no-extension")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:/srv/data/map data.weird"), "/srv/data/map data.weird")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:~/Downloads/notes.log"), "~/Downloads/notes.log")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:C:\\Users\\Me\\My Docs\\a.pdf"), "C:\\Users\\Me\\My Docs\\a.pdf")
    }

    func testMediaPreview_GatewayMediaPathStripsQuotesEmphasisAndTrailingPunctuation() {
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("**MEDIA:/tmp/report.pdf**"), "/tmp/report.pdf")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:\"/tmp/My Report.pdf\""), "/tmp/My Report.pdf")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:`/tmp/My Report.pdf`"), "/tmp/My Report.pdf")
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA:/tmp/data.csv."), "/tmp/data.csv")
    }

    func testMediaPreview_SegmentsSplitSeveralTagsAndSurroundingText() {
        XCTAssertEqual(
            GatewayMediaTags.segments(in: "Here you go: MEDIA:/tmp/a b.png and MEDIA:/tmp/c.mp3 done"),
            [.text("Here you go:"), .media("/tmp/a b.png"), .text("and"), .media("/tmp/c.mp3"), .text("done")]
        )
        XCTAssertEqual(GatewayMediaTags.segments(in: "MEDIA:/a.pngMEDIA:/b.png"), [.media("/a.png"), .media("/b.png")])
        // A list marker or emphasis left behind is not text.
        XCTAssertEqual(GatewayMediaTags.segments(in: "- MEDIA:/tmp/x.pdf"), [.media("/tmp/x.pdf")])
        XCTAssertEqual(GatewayMediaTags.segments(in: "MEDIA:/tmp/a.png 🎉"), [.media("/tmp/a.png"), .text("🎉")])
        XCTAssertEqual(GatewayMediaTags.segments(in: "![Screenshot](MEDIA:/tmp/My Shot.png)"), [.media("/tmp/My Shot.png", alt: "Screenshot")])
        XCTAssertEqual(GatewayMediaTags.segments(in: "![Shot](MEDIA:/tmp/a.png \"Title\")"), [.media("/tmp/a.png", alt: "Shot")])
        XCTAssertEqual(GatewayMediaTags.segments(in: "[Download](MEDIA:/tmp/report.pdf)"), [.media("/tmp/report.pdf", alt: "Download")])
        XCTAssertEqual(GatewayMediaTags.segments(in: "> [[audio_as_voice]]"), [])
        XCTAssertEqual(
            GatewayMediaTags.segments(in: "Here: [the report](MEDIA:/tmp/r.pdf \"Q3\") for you"),
            [.text("Here:"), .media("/tmp/r.pdf", alt: "the report"), .text("for you")]
        )
        // A tag inside a consumed link title must not rewind the cursor.
        XCTAssertEqual(
            GatewayMediaTags.segments(in: "[a](MEDIA:/r.pdf \"see MEDIA:/x.png\") done"),
            [.media("/r.pdf", alt: "a"), .text("done")]
        )
        XCTAssertEqual(GatewayMediaTags.removingTags(from: "Here: [the report](MEDIA:/r.pdf) for you"), "Here: the report for you")
        XCTAssertNil(GatewayMediaTags.segments(in: "No tags here"))
        XCTAssertNil(GatewayMediaTags.segments(in: "> MEDIA:/tmp/quoted.png"))
        XCTAssertNil(GatewayMediaTags.segments(in: "Write `MEDIA:/path/file.png` to send a file"))
    }

    func testMediaPreview_HermesDirectivesAreHidden() {
        XCTAssertEqual(GatewayMediaTags.segments(in: "[[audio_as_voice]]"), [])
        XCTAssertEqual(GatewayMediaTags.segments(in: "[[as_document]] Here it is"), [.text("Here it is")])
        let blocks = MarkdownParser.parse("[[audio_as_voice]]\nMEDIA:/Users/me/.hermes/audio_cache/tts_1.mp3", recognizesGatewayMedia: true)
        XCTAssertEqual(blocks.count, 1)
        if case .image(let url, let alt) = blocks.first {
            XCTAssertEqual(url, "MEDIA: /Users/me/.hermes/audio_cache/tts_1.mp3")
            XCTAssertEqual(alt, "tts_1.mp3")
        } else {
            XCTFail("expected a media block, got \(blocks)")
        }
    }

    func testMediaPreview_IssueReplyRendersTwoCardsAndNoRawTag() {
        let source = """
        MEDIA:/Users/nealbailey/Neal Master/Private/Mimeeq Sale/PandaDoc/Mimeeq_Overview_for_PandaDoc_2026-10.pdf
        MEDIA:/Users/nealbailey/Downloads/Mimeeq_Overview_for_PandaDoc_2026-10.pdf
        """
        let blocks = MarkdownParser.parse(source, recognizesGatewayMedia: true)
        let urls = blocks.compactMap { block -> String? in
            if case .image(let url, _) = block { return url }
            return nil
        }
        XCTAssertEqual(urls, [
            "MEDIA: /Users/nealbailey/Neal Master/Private/Mimeeq Sale/PandaDoc/Mimeeq_Overview_for_PandaDoc_2026-10.pdf",
            "MEDIA: /Users/nealbailey/Downloads/Mimeeq_Overview_for_PandaDoc_2026-10.pdf"
        ])
        XCTAssertEqual(blocks.count, 2)
    }

    func testMediaPreview_TagMidParagraphBreaksOutOfTheParagraph() {
        let blocks = MarkdownParser.parse("The report is ready.\nMEDIA:/tmp/r.pdf\nAnything else?", recognizesGatewayMedia: true)
        XCTAssertEqual(blocks.count, 3)
        if case .image(let url, _) = blocks[1] { XCTAssertEqual(url, "MEDIA: /tmp/r.pdf") } else { XCTFail("\(blocks)") }
    }

    func testMediaPreview_RemovingTagsLeavesOnlyReadableText() {
        XCTAssertEqual(
            GatewayMediaTags.removingTags(from: "Here it is:\n[[audio_as_voice]]\nMEDIA:/tmp/My Clip.mp3\nEnjoy"),
            "Here it is:\nEnjoy"
        )
        XCTAssertEqual(GatewayMediaTags.removingTags(from: "Plain text"), "Plain text")
    }

    func testMediaPreview_AudioPlayerHelpers() {
        XCTAssertEqual(ChatAudioClipPlayer.timeLabel(65), "1:05")
        XCTAssertEqual(ChatAudioClipPlayer.timeLabel(3725), "1:02:05")
        XCTAssertEqual(ChatAudioClipPlayer.timeLabel(-3), "0:00")
        XCTAssertEqual(ChatAudioClipPlayer.fileTypeHint(for: "/tmp/My Clip.mp3"), "public.mp3")
        XCTAssertNil(ChatAudioClipPlayer.fileTypeHint(for: "/tmp/clip"))
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
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.TIFF"), .image)
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.opus"), .audio)
        // Anything else is still a file card (#439); SVG is never rendered.
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.exe"), .document)
        XCTAssertEqual(GatewayMediaKind(path: "/a/b.svg"), .document)
        XCTAssertEqual(GatewayMediaKind(path: "/a/Makefile"), .document)
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
        // Still a card, so it can be shared, but never previewed.
        XCTAssertEqual(MarkdownParser.gatewayMediaPath("MEDIA: /tmp/page.html"), "/tmp/page.html")
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
