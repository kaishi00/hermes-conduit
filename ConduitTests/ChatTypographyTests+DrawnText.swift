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
            let drawnPixels = Self.pixels(of: drawn)
            let plainPixels = Self.pixels(of: plain)
            guard drawnPixels.count == plainPixels.count, !drawnPixels.isEmpty else {
                report.append("\(name): sizes differ \(drawn.bounds.size) vs \(plain.bounds.size)")
                continue
            }
            var differing = 0
            var inked = 0
            for index in stride(from: 0, to: drawnPixels.count, by: 4) {
                let delta = (0..<3).map { abs(Int(drawnPixels[index + $0]) - Int(plainPixels[index + $0])) }.max() ?? 0
                if delta > 48 { differing += 1 }
                if plainPixels[index] < 200 { inked += 1 }
            }
            if inked == 0 || Double(differing) > Double(inked) * 0.02 {
                report.append("\(name): \(differing) of \(inked) inked pixels differ")
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
        XCTAssertNil(drawn.hitTest(CGPoint(x: 10, y: 5), with: nil) as? UITextView, "only a touch mounts the text view")
        XCTAssertNil(drawn.textView)

        let textView = drawn.mountTextView()
        XCTAssertTrue(drawn.textView === textView)
        XCTAssertEqual(textView.attributedText.string, drawn.canvas?.text.string)
        XCTAssertEqual(textView.frame, drawn.bounds)
        XCTAssertFalse(drawn.canvas?.isHidden ?? true, "the drawing stays until the text view has drawn")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(drawn.canvas?.isHidden ?? false)
        XCTAssertEqual(drawn.bounds.size, sizeBefore)
        XCTAssertEqual(drawn.displayedText, textView.text)
    }

    /// A selection that becomes visible in one block mounts the message's
    /// other blocks, so it can be dragged across them.
    @MainActor
    func testAVisibleSelectionMountsTheMessagesOtherBlocks() throws {
        let selection = MarkdownSelectionCoordinator()
        let segments = [
            MarkdownSelectionSegmentDescriptor(id: "block-0", order: 0, separatorBefore: ""),
            MarkdownSelectionSegmentDescriptor(id: "block-1", order: 1, separatorBefore: "\n\n")
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
        selection.clearSelection()
        SelectableTextView.dismantleUIView(firstHost, coordinator: first.makeCoordinator())
        SelectableTextView.dismantleUIView(secondHost, coordinator: second.makeCoordinator())
    }

    @MainActor
    func testDrawnTextReadsAsItsText() {
        let view = SelectableTextView(text: "Read by Voice Control as text")
        let drawn = view.makeUIViewForTests(coordinator: view.makeCoordinator(), drawsUntilTouched: true)
        XCTAssertEqual(drawn.canvas?.accessibilityLabel, "Read by Voice Control as text")
        XCTAssertTrue(drawn.canvas?.isAccessibilityElement ?? false)
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
