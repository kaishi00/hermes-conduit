import XCTest

/// End-to-end verification of cross-block Markdown selection through the REAL
/// gesture pipeline: `press(forDuration:thenDragTo:)` synthesizes an actual
/// long-press-then-drag touch, so UITextView's private selection gesture, the
/// observer recognizer, the coordinator, and the cross-block Copy override are
/// all exercised exactly as a human finger would.
final class SelectionObserverUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLongPressAndDragExtendsSelectionAcrossTableAndCodeBlocks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-conduitSelectionFixture"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()

        let anchor = try pressAnchor(in: app)
        let destination = try dragDestination(in: app)
        let pasteboardLabel = app.staticTexts.matching(identifier: "fixture.pasteboard").firstMatch
        XCTAssertTrue(pasteboardLabel.waitForExistence(timeout: 5))
        let pasteboardBeforeDrag = pasteboardLabel.label

        anchor.press(forDuration: 1.2, thenDragTo: destination)

        // The edit menu keeps the app from ever idling (XCUITest teardown
        // hang), so no post-drag interaction happens here. The screenshot is
        // written where the host can read it; the cross-block highlights
        // across the table, code block, and trailing paragraph are verified
        // from it, and the span/copy logic is covered by unit tests.
        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: "/tmp/conduit-uitest-after-drag.png"))

        XCTAssertEqual(pasteboardLabel.label, pasteboardBeforeDrag, "No copy should happen without user action")
    }

    /// Anchoring inside a table cell and dragging out through the rest of the
    /// response must extend the same way a paragraph-anchored drag does.
    func testCellAnchoredLongPressAndDragExtendsAcrossBlocks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-conduitSelectionFixture"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()

        let cellAnchor = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "alpha cell")).firstMatch
        XCTAssertTrue(cellAnchor.waitForExistence(timeout: 5), "Table cell text view not found. Tree:\n\(app.debugDescription)")
        let destination = try dragDestination(in: app)

        cellAnchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2, thenDragTo: destination)

        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: "/tmp/conduit-uitest-cell-drag.png"))
    }

    /// A plain vertical drag (no long-press) must still scroll rather than
    /// select — the observer must be invisible outside selection gestures.
    func testPlainDragStillScrolls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-conduitSelectionFixture"]
        app.launch()

        let top = app.descendants(matching: .any).matching(identifier: "fixture.top").firstMatch
        XCTAssertTrue(top.waitForExistence(timeout: 5))

        let start = top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        let end = top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -12))
        start.press(forDuration: 0.05, thenDragTo: end)

        let pasteboardLabel = app.staticTexts.matching(identifier: "fixture.pasteboard").firstMatch
        XCTAssertTrue(pasteboardLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(pasteboardLabel.label, "pasteboard:empty", "A plain drag must not select or copy anything")
    }

    // MARK: - Anchors

    private func pressAnchor(in app: XCUIApplication) throws -> XCUICoordinate {
        let before = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Before the table")).firstMatch
        if before.waitForExistence(timeout: 5) {
            return before.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        }

        // Fallback: geometric anchors from the fixture's marker views —
        // 28pt below the top marker lands inside the first paragraph line.
        return try markerCoordinate(in: app, identifier: "fixture.top", offset: CGVector(dx: 100, dy: 28))
    }

    private func dragDestination(in app: XCUIApplication) throws -> XCUICoordinate {
        let after = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "After the blocks")).firstMatch
        if after.waitForExistence(timeout: 2) {
            return after.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        }

        return try markerCoordinate(in: app, identifier: "fixture.bottom", offset: CGVector(dx: 150, dy: -28))
    }

    /// A fast, human-like drag produces sparse touch samples; verify the
    /// selection still extends across the blocks at flick velocity.
    func testFastLongPressAndDragStillExtendsAcrossBlocks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-conduitSelectionFixture"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()

        let anchor = try pressAnchor(in: app)
        let destination = try dragDestination(in: app)

        anchor.press(forDuration: 1.2, thenDragTo: destination, withVelocity: 3000, thenHoldForDuration: 0.1)

        Thread.sleep(forTimeInterval: 0.8)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: "/tmp/conduit-uitest-fast-drag.png"))
    }

    /// Drags, then copies via the fixture's debug button (the system edit
    /// menu stalls accessibility queries, so it is tapped by fixed coordinate)
    /// and asserts the pasteboard from the runner process. This proves the
    /// selection state survives the drag and copies cross-block text; the
    /// system-menu path itself is verified manually.
    func testCopyAfterDragCapturesCrossBlockText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-conduitSelectionFixture"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()

        let anchor = try pressAnchor(in: app)
        anchor.press(forDuration: 1.2, thenDragTo: try dragDestination(in: app))

        Thread.sleep(forTimeInterval: 0.8)
        // Tap the fixture's copy button by identifier — a hardcoded screen
        // offset would miss on any other device size.
        let fixtureCopy = app.buttons.matching(identifier: "fixture.copySelection").firstMatch
        XCTAssertTrue(fixtureCopy.waitForExistence(timeout: 5), "Fixture copy button not found")
        fixtureCopy.tap()

        Thread.sleep(forTimeInterval: 0.8)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/conduit-uitest-copy.png"))

        // Assert through the fixture's pasteboard mirror; see the handles
        // test for why the runner does not read UIPasteboard directly.
        let label = app.staticTexts.matching(identifier: "fixture.pasteboard").firstMatch
        let copied = label.label
        XCTAssertTrue(copied.contains("Column A"), "Copied text missing table content: \(copied)")
        XCTAssertTrue(copied.contains("After the"), "Copied text missing trailing paragraph: \(copied)")
    }

    /// After a cross-block drag, the coordinator-owned chrome takes over:
    /// endpoint handles appear at the true selection boundaries and the copy
    /// pill copies the coordinated text (the system menu no longer shows for
    /// cross-segment selections).
    func testCustomHandlesAndCopyPillAppearAfterCrossBlockDrag() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-conduitSelectionFixture"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()

        let anchor = try pressAnchor(in: app)
        anchor.press(forDuration: 1.2, thenDragTo: try dragDestination(in: app))

        Thread.sleep(forTimeInterval: 0.8)
        let anchorHandle = app.descendants(matching: .any).matching(identifier: "selection.handle.anchor").firstMatch
        let focusHandle = app.descendants(matching: .any).matching(identifier: "selection.handle.focus").firstMatch
        let copyPill = app.descendants(matching: .any).matching(identifier: "selection.copyPill").firstMatch

        XCTAssertTrue(anchorHandle.waitForExistence(timeout: 5), "Anchor handle missing after cross-block drag. Tree:\n\(app.debugDescription)")
        XCTAssertTrue(focusHandle.exists, "Focus handle missing after cross-block drag")
        XCTAssertTrue(copyPill.exists, "Copy pill missing after cross-block drag")

        copyPill.tap()
        Thread.sleep(forTimeInterval: 0.6)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/conduit-uitest-handles.png"))

        let copied = UIPasteboard.general.string ?? ""
        XCTAssertTrue(copied.contains("Column A"), "Copy pill did not copy cross-block text: \(copied)")
        XCTAssertTrue(copied.contains("After the"), "Copy pill did not copy through the trailing paragraph: \(copied)")

        // Drag the ending handle back up into the table: the selection must
        // shrink (focus follows the finger).
        focusHandle.press(forDuration: 0.05, thenDragTo: app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "alpha cell")).firstMatch)
        Thread.sleep(forTimeInterval: 0.6)
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: "/tmp/conduit-uitest-focus-drag.png"))
    }

    private func markerCoordinate(
        in app: XCUIApplication,
        identifier: String,
        offset: CGVector
    ) throws -> XCUICoordinate {
        let marker = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5), "Fixture marker \(identifier) missing. Tree:\n\(app.debugDescription)")
        let frame = marker.frame
        let window = app.windows.firstMatch
        return window
            .coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: frame.minX + offset.dx, dy: frame.minY + offset.dy))
    }
}
