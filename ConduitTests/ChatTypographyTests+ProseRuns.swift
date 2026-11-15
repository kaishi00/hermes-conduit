import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// A chat answer's runs of headings, paragraphs and lists draw in one text
/// view each (MarkdownProseRun), laid out where their block views were.
/// An extension, so the test plan gains no class.
extension ChatTypographyTests {
    func testRunsJoinProseBlocksThatWouldMountSeveralViews() {
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Plan"),
            .paragraph("Alpha"),
            .code(language: "swift", source: "let x = 1"),
            .paragraph("Bravo"),
            .unorderedList(["One", "Two"]),
            .quote([MarkdownQuoteLine(depth: 1, text: "Quoted")]),
            .paragraph("Alone"),
            .divider,
            .orderedList(["Three", "Four"]),
            .unorderedList(["[ ] Task", "[x] Done"])
        ]

        XCTAssertEqual(MarkdownProseRun.ranges(in: blocks), [0..<2, 3..<5, 8..<9])
        XCTAssertEqual(
            MarkdownProseRun.pieces(blockCount: blocks.count, runs: MarkdownProseRun.ranges(in: blocks)).map(\.blocks),
            [0..<2, 2..<3, 3..<5, 5..<6, 6..<7, 7..<8, 8..<9, 9..<10]
        )
    }

    func testRunIsOneSelectionSegmentNamedForItsFirstBlock() {
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Plan"),
            .unorderedList(["One", "Two"]),
            .code(language: "swift", source: "let x = 1"),
            .paragraph("After")
        ]
        let descriptors = MarkdownSelectionSegmentPlan.descriptors(
            for: blocks,
            joiningRuns: MarkdownProseRun.ranges(in: blocks)
        )

        XCTAssertEqual(descriptors.map(\.id), ["block-0", "block-2-code", "block-3"])
        XCTAssertEqual(descriptors.map(\.order), [0, 1, 2])
        XCTAssertEqual(descriptors.map(\.separatorBefore), ["", "\n\n", "\n\n"])
    }

    /// Copying a run gives what copying its blocks did: blocks a blank line
    /// apart, list items a line apart, each with its marker and a space.
    @MainActor
    func testRunTextCopiesLikeItsBlocks() {
        let blocks: [MarkdownBlock] = [
            .heading(level: 2, text: "Plan"),
            .paragraph("Alpha **bold**"),
            .unorderedList(["One", "Two"]),
            .orderedList(["Three"])
        ]
        let text = MarkdownProseRun.attributedText(
            for: blocks[...],
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )

        XCTAssertEqual(text.string, "Plan\nAlpha bold\n•\tOne\n•\tTwo\n1.\tThree", "one line break between blocks, spaced by the paragraph style")
        XCTAssertEqual(MarkdownProseRun.copyableText(text).string, "Plan\n\nAlpha bold\n\n• One\n• Two\n\n1. Three")

        let textView = UITextView()
        textView.attributedText = text
        textView.selectedRange = (text.string as NSString).range(of: "bold\n•\tOne")
        XCTAssertEqual(MarkdownProseRun.copiedSelection(in: textView)?.string, "bold\n\n• One", "a selection inside the run copies the same way")
        textView.selectedRange = (text.string as NSString).range(of: "Alpha")
        XCTAssertNil(MarkdownProseRun.copiedSelection(in: textView), "plain text copies as the text view would")
        textView.selectedRange = (text.string as NSString).range(of: "\nAlpha bold\n")
        XCTAssertEqual(MarkdownProseRun.copiedSelection(in: textView)?.string, "Alpha bold", "breaks at the selection's ends copy as nothing, as a block's own view ended there")

        let boldFont = text.attribute(.font, at: (text.string as NSString).range(of: "bold").location, effectiveRange: nil) as? UIFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) == true, "inline styles carry over")
    }

    /// Every block's text starts where its own view put it, so joining
    /// changes nothing on screen.
    @MainActor
    func testJoinedRunKeepsEachBlockWhereItsOwnViewPutIt() throws {
        let source = """
        ## Alpha heading

        Bravo paragraph has enough words in it to wrap onto a second line of the chat column at this width, and then some more.

        - Charlie item
        - Delta item is long enough that it wraps onto another line in the chat column at this width as well

        1. Echo first
        2. Foxtrot second

        ### Golf heading

        Hotel closing paragraph.

        ---

        Zulu after the divider.
        """
        let landmarks = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "Zulu"]

        let separateWindow = proseRunWindow(source, joinsProseRuns: false)
        let separate = landmarkOrigins(landmarks, in: separateWindow)
        separateWindow.isHidden = true
        let joinedWindow = proseRunWindow(source, joinsProseRuns: true)
        defer { joinedWindow.isHidden = true }
        XCTAssertEqual(proseTextViews(in: joinedWindow).count, 2, "the run and the paragraph after the divider")
        let joined = landmarkOrigins(landmarks, in: joinedWindow)

        let report = landmarks.map { landmark in
            "\(landmark) \(describeLandmark(separate[landmark])) -> \(describeLandmark(joined[landmark]))"
        }.joined(separator: "; ")
        for landmark in landmarks {
            let before = try XCTUnwrap(separate[landmark], "\(landmark) missing from block views: \(report)")
            let after = try XCTUnwrap(joined[landmark], "\(landmark) missing from the run: \(report)")
            XCTAssertEqual(after.x, before.x, accuracy: 1, "\(landmark) moved sideways: \(report)")
            XCTAssertEqual(after.y, before.y, accuracy: 1, "\(landmark) moved down or up: \(report)")
        }
    }

    /// A reply of only prose draws as one text view (the flow text, not a
    /// run): its list items and quote lines hang their marker in a gutter,
    /// and every wrapped line starts under the text, not at the left edge
    /// under the marker.
    @MainActor
    func testFlowReplyHangsListAndQuoteMarkers() throws {
        let source = """
        Alpha paragraph.

        - Bravo item is long enough that it wraps onto another line in the chat column at this width, and onto a third line as well if it can
        - Charlie item

        3. Delta item is long enough that it wraps onto another line in the chat column at this width as well, then some more words
        4. Echo item

        > Foxtrot quote is long enough that it wraps onto another line in the chat column at this width as well, and then a few words more
        """
        let window = proseRunWindow(source, joinsProseRuns: false)
        defer { window.isHidden = true }
        let textViews = proseTextViews(in: window)
        XCTAssertEqual(textViews.count, 1, "a prose-only reply is one text view")
        let textView = try XCTUnwrap(textViews.first)
        let origins = landmarkOrigins(["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot"], in: window)
        let alpha = try XCTUnwrap(origins["Alpha"])
        let bravo = try XCTUnwrap(origins["Bravo"])
        let delta = try XCTUnwrap(origins["Delta"])
        let foxtrot = try XCTUnwrap(origins["Foxtrot"])
        XCTAssertGreaterThan(bravo.x, alpha.x + 10, "a bullet's text starts past its gutter")
        XCTAssertEqual(try XCTUnwrap(origins["Charlie"]).x, bravo.x, accuracy: 1)
        XCTAssertGreaterThan(delta.x, bravo.x, "a number's gutter is wider than a bullet's")
        XCTAssertEqual(try XCTUnwrap(origins["Echo"]).x, delta.x, accuracy: 1)

        // Each wrapped line starts where its item's text does.
        for (landmark, origin) in [("Bravo", bravo), ("Delta", delta), ("Foxtrot", foxtrot)] {
            let wrapped = try XCTUnwrap(
                firstWrappedLineOrigin(after: landmark, in: textView),
                "\(landmark) never wrapped at this width"
            )
            XCTAssertEqual(wrapped.x, origin.x, accuracy: 1, "\(landmark)'s wrapped line went back to the edge")
        }

        // Copy keeps the markers' spaces.
        let copied = MarkdownProseRun.copyableText(try XCTUnwrap(textView.attributedText)).string
        XCTAssertTrue(copied.contains("• Bravo item"), copied)
        XCTAssertTrue(copied.contains("\n• Charlie item\n\n3. Delta"), copied)
    }

    /// Drawn as block views (a rich answer under VoiceOver, or with prose
    /// runs off), a nested list moves in a level, sits a list item's gap
    /// under its parent list and copies on the next line.
    @MainActor
    func testBlockViewsNestAnOutline() throws {
        let source = """
        - Alpha item
          - Bravo sub-item
          - Charlie sub-item

        ```
        code keeps these block views
        ```
        """
        let blocks = MarkdownParser.parse(source)
        let descriptors = MarkdownSelectionSegmentPlan.descriptors(for: blocks, joiningRuns: [])
        XCTAssertEqual(descriptors.map(\.separatorBefore).prefix(3), ["", "\n", "\n"], "the sub-list copies a line under its parent")

        let window = proseRunWindow(source, joinsProseRuns: false)
        defer { window.isHidden = true }
        let origins = landmarkOrigins(["Alpha", "Bravo", "Charlie"], in: window)
        let alpha = try XCTUnwrap(origins["Alpha"])
        let bravo = try XCTUnwrap(origins["Bravo"])
        let charlie = try XCTUnwrap(origins["Charlie"])
        XCTAssertEqual(bravo.x - alpha.x, MarkdownProseRun.nestedListIndent(chatTextSize: .default), accuracy: 1, "a level in")
        XCTAssertEqual(bravo.y - alpha.y, charlie.y - bravo.y, accuracy: 1, "an item's gap, not a block's")
    }

    /// A long reply's flow chunk keeps its lists' hanging indents and
    /// nesting (it draws its text with keepsParagraphStyles).
    @MainActor
    func testLargeFlowChunkKeepsListIndents() throws {
        let blocks = MarkdownParser.parse("- Alpha item\n  - Bravo sub-item")
        let host = UIHostingController(rootView: VStack(spacing: 0) {
            LargeFlowChunkView(
                blocks: blocks,
                references: .empty,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                selectionCoordinator: nil,
                selectionSegment: nil
            )
            Spacer(minLength: 0)
        }
        .frame(width: 390))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.view.layoutIfNeeded()

        let origins = landmarkOrigins(["Alpha", "Bravo"], in: window)
        let alpha = try XCTUnwrap(origins["Alpha"])
        let bravo = try XCTUnwrap(origins["Bravo"])
        let step = MarkdownProseRun.nestedListIndent(chatTextSize: .default)
        XCTAssertGreaterThan(alpha.x, 10, "the bullet hangs in a gutter")
        XCTAssertEqual(bravo.x - alpha.x, step, accuracy: 1, "the sub-list a level in")
    }

    /// A task list keeps its own view; its sub-list joins a prose run and
    /// still sits an item's gap under it, as the rest of the outline does.
    @MainActor
    func testProseRunUnderATaskListSitsAnItemsGapBelow() throws {
        // The divider keeps the reply off the flow path, which would draw
        // it all as one text.
        let source = "- [ ] Alpha task\n  - Bravo sub-item\n  - Charlie sub-item\n\n---\n\nZulu after the divider."
        let window = proseRunWindow(source, joinsProseRuns: true)
        defer { window.isHidden = true }
        XCTAssertEqual(proseTextViews(in: window).count, 3, "the task's own view, the sub-list's run and the paragraph after the divider")
        let origins = landmarkOrigins(["Alpha", "Bravo", "Charlie"], in: window)
        let alpha = try XCTUnwrap(origins["Alpha"])
        let bravo = try XCTUnwrap(origins["Bravo"])
        let charlie = try XCTUnwrap(origins["Charlie"])
        XCTAssertEqual(bravo.y - alpha.y, charlie.y - bravo.y, accuracy: 1.5, "an item's gap, not a block's")
    }

    // MARK: - Helpers

    /// Where the first line after the one `landmark` starts on begins, in
    /// window points, within the same paragraph.
    @MainActor
    private func firstWrappedLineOrigin(after landmark: String, in textView: UITextView) -> CGPoint? {
        textView.layoutIfNeeded()
        let text = (textView.text ?? "") as NSString
        let location = text.range(of: landmark).location
        guard location != NSNotFound,
              let start = textView.position(from: textView.beginningOfDocument, offset: location)
        else { return nil }
        let firstLine = textView.caretRect(for: start).minY
        let paragraphEnd = NSMaxRange(text.paragraphRange(for: NSRange(location: location, length: 0)))
        for offset in (location + 1)..<paragraphEnd {
            guard let position = textView.position(from: textView.beginningOfDocument, offset: offset),
                  let end = textView.position(from: position, offset: 1),
                  let glyph = textView.textRange(from: position, to: end),
                  text.character(at: offset) != 0x20
            else { continue }
            let rect = textView.firstRect(for: glyph)
            if rect.minY > firstLine + 4 {
                return textView.convert(CGPoint(x: rect.minX, y: rect.minY), to: nil)
            }
        }
        return nil
    }

    @MainActor
    private func proseRunWindow(_ source: String, joinsProseRuns: Bool) -> UIWindow {
        // Pinned to the top: a hosting controller centres smaller content,
        // which would move every landmark by half a height difference.
        let host = UIHostingController(rootView: VStack(spacing: 0) {
            MarkdownText(source: source)
                .environment(\.markdownJoinsProseRuns, joinsProseRuns)
            Spacer(minLength: 0)
        }
        .frame(width: 390))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 1400))
        window.rootViewController = host
        window.isHidden = false
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.view.layoutIfNeeded()
        return window
    }

    /// Where each landmark's first character is drawn, in window points:
    /// the glyph's leading edge, and the top of the caret in front of it.
    /// (A caret sits a point before a glyph inside a line, but at a text
    /// view's leading edge it can't, so its x would differ by a point.)
    @MainActor
    private func landmarkOrigins(_ landmarks: [String], in root: UIView) -> [String: CGPoint] {
        var origins: [String: CGPoint] = [:]
        for textView in proseTextViews(in: root) {
            textView.layoutIfNeeded()
            let text = (textView.text ?? "") as NSString
            for landmark in landmarks where origins[landmark] == nil {
                let location = text.range(of: landmark).location
                guard location != NSNotFound,
                      let start = textView.position(from: textView.beginningOfDocument, offset: location),
                      let end = textView.position(from: start, offset: 1),
                      let glyph = textView.textRange(from: start, to: end)
                else { continue }
                let caret = textView.caretRect(for: start)
                let x = textView.firstRect(for: glyph).minX
                origins[landmark] = textView.convert(CGPoint(x: x, y: caret.minY), to: nil)
            }
        }
        return origins
    }

    private func describeLandmark(_ point: CGPoint?) -> String {
        guard let point else { return "none" }
        return String(format: "(%.1f, %.1f)", point.x, point.y)
    }

    private func proseTextViews(in view: UIView) -> [UITextView] {
        view.subviews.flatMap { subview -> [UITextView] in
            (subview as? UITextView).map { [$0] } ?? proseTextViews(in: subview)
        }
    }
}
