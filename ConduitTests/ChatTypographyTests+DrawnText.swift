import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// In a chat, text draws without a UITextView until a touch mounts one over
/// the drawing (SelectableTextCanvas), so the drawing must take the text
/// view's size and put every glyph where the text view does. An extension,
/// so the test plan gains no class.
extension ChatTypographyTests {
    @MainActor
    func testDrawnTextTakesTheTextViewsHeight() {
        var mismatches: [String] = []
        for (name, view) in drawnTextSamples() {
            let drawn = view.makeUIViewForTests(coordinator: view.makeCoordinator(), drawsUntilTouched: true)
            let plain = view.makeUIViewForTests(coordinator: view.makeCoordinator())
            XCTAssertNil(drawn.textView, "\(name): nothing mounted a text view yet")
            for width: CGFloat in [120, 241.5, 366] {
                let canvasHeight = drawn.canvas?.height(atWidth: width) ?? -1
                let textViewHeight = SelectableTextView.measuredWrappingHeight(of: plain.mountedTextView, at: width)
                if canvasHeight != textViewHeight {
                    mismatches.append("\(name)@\(width): drawn \(canvasHeight) vs text view \(textViewHeight)")
                }
            }
        }
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "; "))
    }

    @MainActor
    func testDrawnTextPutsGlyphsWhereTheTextViewDoes() throws {
        let text = MarkdownProseRun.attributedText(
            for: [
                .heading(level: 2, text: "Alpha heading"),
                .paragraph("Bravo paragraph has enough words in it to wrap onto a second line of the column, and then some."),
                .unorderedList(["Charlie item", "Delta item is long enough that it wraps onto another line as well"]),
                .orderedList(["Echo first"]),
                .paragraph("Foxtrot with a [link](https://example.com) and `code`.")
            ][...],
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )
        let view = SelectableTextView(
            attributedText: text,
            font: ChatTypography.font(for: .body, chatSize: .default),
            keepsParagraphStyles: true
        )
        let (window, drawn, plain) = drawnAndPlainHosts(of: view, width: 366)
        defer { window.isHidden = true }
        let canvas = try XCTUnwrap(drawn.canvas)
        // Asked the same way as the canvas: the text view's own firstRect
        // pads the line by a point.
        let textViewLayout = try XCTUnwrap(plain.mountedTextView.textLayoutManager, "the text view is on TextKit 2")
        textViewLayout.ensureLayout(for: textViewLayout.documentRange)
        var report: [String] = []
        for landmark in ["Alpha", "Bravo", "column", "Charlie", "Delta", "another", "Echo", "Foxtrot", "link", "code"] {
            let glyph = NSRange(location: (text.string as NSString).range(of: landmark).location, length: 1)
            guard let drawnRect = canvas.firstRectForTests(characterRange: glyph),
                  let viewRect = SelectableTextCanvas.firstRectForTests(characterRange: glyph, in: textViewLayout)
            else {
                report.append("\(landmark) missing")
                continue
            }
            if abs(drawnRect.minX - viewRect.minX) > 0.5 || abs(drawnRect.minY - viewRect.minY) > 0.5 {
                report.append(String(
                    format: "%@ drawn (%.1f, %.1f) vs text view (%.1f, %.1f)",
                    landmark, drawnRect.minX, drawnRect.minY, viewRect.minX, viewRect.minY
                ))
            }
        }
        XCTAssertTrue(report.isEmpty, report.joined(separator: "; "))
    }

    /// Mounting the text view over the drawing must not change a pixel, or
    /// every touch would flash.
    @MainActor
    func testDrawnTextLooksLikeTheTextView() throws {
        var report: [String] = []
        for (name, view) in drawnTextSamples() where name != "empty" {
            let (window, drawn, plain) = drawnAndPlainHosts(of: view, width: 300)
            defer { window.isHidden = true }
            if let difference = Self.inkDifference(Self.pixels(of: drawn), Self.pixels(of: plain)) {
                report.append("\(name): \(difference)")
            }
        }
        XCTAssertTrue(report.isEmpty, report.joined(separator: "; "))
    }

    @MainActor
    func testMountingTheTextViewKeepsTheTextAndHidesTheDrawing() throws {
        let view = SelectableTextView(text: "Mounted on touch, with a [link](https://example.com).", lineSpacing: 4)
        let (window, drawn, _) = drawnAndPlainHosts(of: view, width: 300)
        defer { window.isHidden = true }
        let sizeBefore = drawn.bounds.size
        let drawnPixels = Self.pixels(of: drawn)
        XCTAssertNil(drawn.hitTest(CGPoint(x: 10, y: 5), with: nil) as? UITextView, "only a touch mounts the text view")
        XCTAssertNil(drawn.textView)

        let textView = drawn.mountTextView()
        XCTAssertTrue(drawn.textView === textView)
        XCTAssertEqual(textView.attributedText.string, drawn.canvas?.text.string)
        XCTAssertEqual(textView.frame, drawn.bounds)
        XCTAssertTrue(drawn.canvas?.isHidden ?? false, "the text view draws in the commit that hides the drawing")
        drawn.canvas?.layoutIfNeeded()
        XCTAssertEqual(drawn.canvas?.subviews.count, 0, "a hidden drawing keeps no tiles")
        XCTAssertEqual(drawn.bounds.size, sizeBefore)
        XCTAssertEqual(drawn.displayedText, textView.text)
        // Drawn twice over, every glyph's edges would darken.
        XCTAssertNil(Self.inkDifference(Self.pixels(of: drawn), drawnPixels))
    }

    /// Measuring lays the text out at a new width before the canvas takes
    /// it; the resize still redraws every tile.
    @MainActor
    func testDrawnTextRedrawsAtANewWidth() throws {
        let view = SelectableTextView(
            text: String(repeating: "Lines wrap again when the column narrows. ", count: 6),
            lineSpacing: 4
        )
        let (window, drawn, _) = drawnAndPlainHosts(of: view, width: 300)
        defer { window.isHidden = true }
        let canvas = try XCTUnwrap(drawn.canvas)
        canvas.subviews.forEach { $0.layer.displayIfNeeded() }
        XCTAssertFalse(canvas.subviews.contains { $0.layer.needsDisplay() })

        drawn.frame.size = CGSize(width: 200, height: canvas.height(atWidth: 200))
        drawn.layoutIfNeeded()
        canvas.layoutIfNeeded()
        XCTAssertFalse(canvas.subviews.isEmpty)
        XCTAssertTrue(canvas.subviews.allSatisfy { $0.layer.needsDisplay() })
    }

    /// A sent bubble hugs a short message: asked for its ideal width, drawn
    /// text gives its unbroken width as the text view's intrinsic size did,
    /// instead of every bubble stretching to the widest it's offered.
    @MainActor
    func testDrawnTextFitsAShortSentBubble() throws {
        let view = SelectableTextView(text: "Goodbye.", font: ChatTypography.font(for: .body, chatSize: .default))
        let drawn = view.makeUIViewForTests(coordinator: view.makeCoordinator(), drawsUntilTouched: true)
        let plain = view.makeUIViewForTests(coordinator: view.makeCoordinator())
        let natural = try XCTUnwrap(drawn.canvas).naturalSize()
        let textViewWidth = ceil(plain.mountedTextView.sizeThatFits(
            CGSize(width: SelectableTextCanvas.unboundedWidth, height: CGFloat.greatestFiniteMagnitude)
        ).width)
        XCTAssertEqual(natural.width, textViewWidth, accuracy: 1)
        XCTAssertEqual(drawn.canvas?.height(atWidth: natural.width), natural.height, "fits on one line")

        let widths = try ["Goodbye.", String(repeating: "A sent message long enough to wrap. ", count: 4)].map { text in
            try sentBubbleTextWidth(UserBubble(
                message: ChatMessage(id: text, role: .user, content: text, timestamp: "1"),
                gatewayResolver: nil
            ))
        }
        XCTAssertEqual(widths[0], natural.width, accuracy: 2, "a short message's bubble fits its text")
        XCTAssertGreaterThan(widths[1], 2 * widths[0], "a long message still wraps at the column")
    }

    @MainActor
    private func sentBubbleTextWidth(_ bubble: UserBubble) throws -> CGFloat {
        let host = UIHostingController(rootView: bubble.environment(\.selectableTextDrawsUntilTouched, true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        func hosts(in view: UIView) -> [SelectableTextViewHostView] {
            ((view as? SelectableTextViewHostView).map { [$0] } ?? []) + view.subviews.flatMap(hosts)
        }
        let found = hosts(in: host.view)
        XCTAssertEqual(found.count, 1)
        let textHost = try XCTUnwrap(found.first)
        XCTAssertNotNil(textHost.canvas, "the text draws until touched")
        return textHost.bounds.width
    }

    /// A code block's line can run thousands of points, and tiles that wide
    /// are too big to back: text that doesn't wrap keeps its text view.
    @MainActor
    func testTextThatDoesntWrapIsNotDrawn() {
        var environment = EnvironmentValues()
        environment.selectableTextDrawsUntilTouched = true
        XCTAssertTrue(SelectableTextView(text: "Wraps").drawsUntilTouched(in: environment))
        let code = SelectableTextView(text: String(repeating: "x", count: 3_000), wrapsLines: false)
        XCTAssertFalse(code.drawsUntilTouched(in: environment))
    }

    /// A selection that becomes visible in one block mounts the message's
    /// other blocks, so it can be dragged across them, and so does a block
    /// that appears while it is live.
    @MainActor
    func testAVisibleSelectionMountsTheMessagesOtherBlocks() throws {
        SelectableTextViewPool.removeAll()
        defer { SelectableTextViewPool.removeAll() }
        let selection = MarkdownSelectionCoordinator()
        let segments = [
            MarkdownSelectionSegmentDescriptor(id: "block-0", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "block-1", order: 1, separatorBefore: "\n\n"),
            MarkdownSelectionSegmentDescriptor(id: "block-2", order: 2, separatorBefore: "\n\n")
        ]
        selection.replaceSegments(segments, revision: "drawn")
        let first = SelectableTextView(text: "First block", selectionCoordinator: selection, selectionSegment: segments[0])
        let second = SelectableTextView(text: "Second block", selectionCoordinator: selection, selectionSegment: segments[1])
        let firstHost = first.makeUIViewForTests(coordinator: first.makeCoordinator(), drawsUntilTouched: true)
        let secondHost = second.makeUIViewForTests(coordinator: second.makeCoordinator(), drawsUntilTouched: true)
        XCTAssertFalse(selection.isSegmentRegistered("block-0"))
        XCTAssertFalse(selection.isSegmentRegistered("block-1"))

        firstHost.mountTextView()
        XCTAssertTrue(selection.isSegmentRegistered("block-0"), "a mounted block registers its text view")
        XCTAssertNil(secondHost.textView, "a touch mounts only the block it lands on")

        selection.activateSelection(segmentID: "block-0", selectedRange: NSRange(location: 0, length: 5), windowPoint: .zero)
        XCTAssertNotNil(secondHost.textView)
        XCTAssertTrue(selection.isSegmentRegistered("block-1"))
        XCTAssertEqual(selection.activeSpans.map(\.segmentID), ["block-0"], "mounting kept the selection")

        let third = SelectableTextView(text: "Third block", selectionCoordinator: selection, selectionSegment: segments[2])
        let thirdHost = third.makeUIViewForTests(coordinator: third.makeCoordinator(), drawsUntilTouched: true)
        XCTAssertNotNil(thirdHost.textView, "a block that appears under a live selection mounts")
        XCTAssertTrue(selection.isSegmentRegistered("block-2"))
        selection.clearSelection()
        SelectableTextView.dismantleUIView(firstHost, coordinator: first.makeCoordinator())
        SelectableTextView.dismantleUIView(secondHost, coordinator: second.makeCoordinator())
        SelectableTextView.dismantleUIView(thirdHost, coordinator: third.makeCoordinator())
    }

    /// Voice Control and Full Keyboard Access can't be detected, and they
    /// target the links in text: assistive technology asking drawn text
    /// for its elements gets the text view.
    @MainActor
    func testAssistiveTechnologyGetsTheTextView() throws {
        let view = SelectableTextView(text: "Read by Voice Control with its links")
        let drawn = view.makeUIViewForTests(coordinator: view.makeCoordinator(), drawsUntilTouched: true)
        XCTAssertNil(drawn.textView)
        XCTAssertFalse(drawn.canvas?.isAccessibilityElement ?? true)

        let elements = try XCTUnwrap(drawn.accessibilityElements)
        let textView = try XCTUnwrap(drawn.textView)
        XCTAssertEqual(elements.count, 1)
        XCTAssertTrue(elements.first as? UITextView === textView)
        XCTAssertEqual(textView.text, "Read by Voice Control with its links")
    }

    // MARK: - Helpers

    @MainActor
    private func drawnTextSamples() -> [(String, SelectableTextView)] {
        let body = ChatTypography.font(for: .body, chatSize: .default)
        let run = MarkdownProseRun.attributedText(
            for: [
                .heading(level: 3, text: "Heading"),
                .paragraph("A paragraph under it that wraps at the narrow widths."),
                .unorderedList(["One", "Two wraps as well when the column is narrow"])
            ][...],
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )
        let linked = SelectableTextView.bridge(
            InlineMarkdownContent.attributed(source: "See **the docs** at [example](https://example.com) and `code`.", references: .empty),
            defaultFont: body,
            defaultColor: .label,
            linkColor: .link
        )
        return [
            ("paragraph", SelectableTextView(
                text: "The import step reads each source file, hashes it and compares the hash with the cache.",
                font: body,
                lineSpacing: 4
            )),
            ("prose run", SelectableTextView(attributedText: run, font: body, keepsParagraphStyles: true)),
            ("inline styles", SelectableTextView(attributedText: linked, font: body, lineSpacing: 4)),
            ("code", SelectableTextView(
                text: "func importAll(_ files: [URL]) async throws {\n    for file in files { try await parse(file) }\n}",
                font: .monospacedSystemFont(ofSize: 14, weight: .regular)
            )),
            ("emoji and CJK", SelectableTextView(text: "Done ✅ 完成了 — 日本語のテキストも折り返します 🎉", font: body)),
            ("trailing newline", SelectableTextView(text: "Ends with a newline\n", font: body)),
            ("two lines", SelectableTextView(
                text: "Capped at two lines, so the rest of this sentence is cut off with an ellipsis at the end.",
                font: body,
                maximumNumberOfLines: 2
            )),
            ("empty", SelectableTextView(text: "", font: body)),
        ]
    }

    /// The same text drawn and in a text view, side by side in a window at
    /// `width`, each sized by its own measurement.
    @MainActor
    private func drawnAndPlainHosts(
        of view: SelectableTextView,
        width: CGFloat
    ) -> (UIWindow, SelectableTextViewHostView, SelectableTextViewHostView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 2 * width + 20, height: 1200))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.backgroundColor = .white
        window.overrideUserInterfaceStyle = .light
        let drawn = view.makeUIViewForTests(coordinator: view.makeCoordinator(), drawsUntilTouched: true)
        let plain = view.makeUIViewForTests(coordinator: view.makeCoordinator())
        let drawnHeight = drawn.canvas?.height(atWidth: width) ?? 0
        let plainHeight = SelectableTextView.measuredWrappingHeight(of: plain.mountedTextView, at: width)
        drawn.frame = CGRect(x: 0, y: 0, width: width, height: drawnHeight)
        plain.frame = CGRect(x: width + 20, y: 0, width: width, height: plainHeight)
        window.rootViewController?.view.addSubview(drawn)
        window.rootViewController?.view.addSubview(plain)
        window.layoutIfNeeded()
        drawn.layoutIfNeeded()
        plain.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (window, drawn, plain)
    }

    /// Nil when two renderings (`pixels(of:)`) look alike: at most 2% of
    /// the inked pixels differ by more than antialiasing does.
    private static func inkDifference(_ drawnPixels: [UInt8], _ plainPixels: [UInt8]) -> String? {
        guard drawnPixels.count == plainPixels.count, !drawnPixels.isEmpty else {
            return "sizes differ: \(drawnPixels.count / 4) vs \(plainPixels.count / 4) pixels"
        }
        var differing = 0
        var inked = 0
        for index in stride(from: 0, to: drawnPixels.count, by: 4) {
            let delta = (0..<3).map { abs(Int(drawnPixels[index + $0]) - Int(plainPixels[index + $0])) }.max() ?? 0
            if delta > 48 { differing += 1 }
            if plainPixels[index] < 200 { inked += 1 }
        }
        guard inked == 0 || Double(differing) > Double(inked) * 0.02 else { return nil }
        return "\(differing) of \(inked) inked pixels differ"
    }

    @MainActor
    private static func pixels(of view: UIView) -> [UInt8] {
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1 else { return [] }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { return [] }
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
