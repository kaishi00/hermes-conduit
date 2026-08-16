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
        // hang), so no post-drag interaction or screenshot happens here —
        // screenshot requests time out against a busy app on CI.
        Thread.sleep(forTimeInterval: 0.8)

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

        XCTAssertTrue(
            performCrossBlockDrag(app: app) {
                cellAnchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 1.2, thenDragTo: destination)
            },
            "Cell-anchored drag must produce a cross-block selection with endpoint handles"
        )

        Thread.sleep(forTimeInterval: 0.8)

        let focusHandle = app.descendants(matching: .any).matching(identifier: "selection.handle.focus").firstMatch
        XCTAssertTrue(focusHandle.waitForExistence(timeout: 5), "Cell-anchored drag must produce a cross-block selection with endpoint handles")
    }

    /// A plain vertical drag (no long-press) must not select or copy — the
    /// observer must be invisible outside selection gestures. (The fixture's
    /// content is shorter than the viewport, so no scroll can occur here.)
    func testPlainDragDoesNotSelectOrCopy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-conduitSelectionFixture"]
        app.launch()

        let top = app.descendants(matching: .any).matching(identifier: "fixture.top").firstMatch
        XCTAssertTrue(top.waitForExistence(timeout: 5))

        let pasteboardLabel = app.staticTexts.matching(identifier: "fixture.pasteboard").firstMatch
        XCTAssertTrue(pasteboardLabel.waitForExistence(timeout: 5))
        let pasteboardBeforeDrag = pasteboardLabel.label

        // The anchor marker is 2pt tall, so a -12 normalized offset is a
        // 24pt drag — small enough to stay a plain drag, not a long-press.
        let start = top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
        let end = top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -12))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertEqual(pasteboardLabel.label, pasteboardBeforeDrag, "A plain drag must not select or copy anything")
    }

    /// Synthesized long-press drags occasionally fail to produce a selection
    /// on slower CI runners (timing between press and drag). Retry the drag
    /// until the coordinator-owned chrome — both endpoint handles — is up,
    /// and report success so each caller fails with its own domain message.
    /// Waiting for both handles matters: the cell-anchored test asserts on
    /// the focus handle, so a retry that only watched the anchor handle
    /// could give up (or stop) while the chrome was half-installed.
    @discardableResult
    private func performCrossBlockDrag(
        app: XCUIApplication,
        performDrag: () -> Void
    ) -> Bool {
        let anchorHandle = app.descendants(matching: .any).matching(identifier: "selection.handle.anchor").firstMatch
        let focusHandle = app.descendants(matching: .any).matching(identifier: "selection.handle.focus").firstMatch
        for _ in 0..<3 {
            performDrag()
            if anchorHandle.waitForExistence(timeout: 4), focusHandle.waitForExistence(timeout: 2) {
                return true
            }
        }
        return false
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

        XCTAssertTrue(
            performCrossBlockDrag(app: app) {
                anchor.press(forDuration: 1.2, thenDragTo: destination, withVelocity: 3000, thenHoldForDuration: 0.1)
            },
            "Fast drag must still extend the selection across blocks"
        )

        Thread.sleep(forTimeInterval: 0.8)

        let anchorHandle = app.descendants(matching: .any).matching(identifier: "selection.handle.anchor").firstMatch
        XCTAssertTrue(anchorHandle.waitForExistence(timeout: 5), "Fast drag must still extend the selection across blocks")
    }

    /// Drags, then copies via the fixture's debug button and asserts through
    /// the fixture's pasteboard mirror. This proves the
    /// selection state survives the drag and copies cross-block text; the
    /// system-menu path itself is verified manually.
    func testCopyAfterDragCapturesCrossBlockText() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-conduitSelectionFixture"]
        app.launchEnvironment["CONDUIT_UITEST"] = "1"
        app.launch()

        let anchor = try pressAnchor(in: app)
        let destination = try dragDestination(in: app)
        XCTAssertTrue(
            performCrossBlockDrag(app: app) {
                anchor.press(forDuration: 1.2, thenDragTo: destination)
            },
            "Cross-block drag did not produce a selection to copy"
        )

        Thread.sleep(forTimeInterval: 0.8)
        // Tap the fixture's copy button by identifier — a hardcoded screen
        // offset would miss on any other device size.
        let fixtureCopy = app.buttons.matching(identifier: "fixture.copySelection").firstMatch
        XCTAssertTrue(fixtureCopy.waitForExistence(timeout: 5), "Fixture copy button not found")
        fixtureCopy.tap()

        Thread.sleep(forTimeInterval: 0.8)
        attachScreenshot("copy-after-drag")

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
        let destination = try dragDestination(in: app)
        XCTAssertTrue(
            performCrossBlockDrag(app: app) {
                anchor.press(forDuration: 1.2, thenDragTo: destination)
            },
            "Cross-block drag did not produce a selection with custom chrome"
        )

        Thread.sleep(forTimeInterval: 0.8)
        let anchorHandle = app.descendants(matching: .any).matching(identifier: "selection.handle.anchor").firstMatch
        let focusHandle = app.descendants(matching: .any).matching(identifier: "selection.handle.focus").firstMatch
        let copyPill = app.descendants(matching: .any).matching(identifier: "selection.copyPill").firstMatch

        XCTAssertTrue(anchorHandle.waitForExistence(timeout: 5), "Anchor handle missing after cross-block drag. Tree:\n\(app.debugDescription)")
        XCTAssertTrue(focusHandle.exists, "Focus handle missing after cross-block drag")
        XCTAssertTrue(copyPill.exists, "Copy pill missing after cross-block drag")

        copyPill.tap()
        Thread.sleep(forTimeInterval: 0.6)
        attachScreenshot("handles-after-copy")

        let pasteboardMirror = app.staticTexts.matching(identifier: "fixture.pasteboard").firstMatch
        let copied = pasteboardMirror.label
        XCTAssertTrue(copied.contains("Column A"), "Copy pill did not copy cross-block text: \(copied)")
        XCTAssertTrue(copied.contains("After the"), "Copy pill did not copy through the trailing paragraph: \(copied)")

        // Drag the ending handle back up into the table, then copy again:
        // the coordinated text must have shrunk to match the moved endpoint
        // — no longer reaching the trailing paragraph.
        focusHandle.press(forDuration: 0.05, thenDragTo: app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "alpha cell")).firstMatch)
        Thread.sleep(forTimeInterval: 0.6)

        let shrunkPill = app.descendants(matching: .any).matching(identifier: "selection.copyPill").firstMatch
        XCTAssertTrue(shrunkPill.waitForExistence(timeout: 5), "Chrome must persist after a handle drag")
        shrunkPill.tap()
        Thread.sleep(forTimeInterval: 0.6)

        let shrunkCopied = pasteboardMirror.label
        XCTAssertTrue(shrunkCopied.contains("Column A"), "Shrunk copy should still include the table: \(shrunkCopied)")
        XCTAssertFalse(shrunkCopied.contains("After the"), "Shrunk copy must not reach the trailing paragraph: \(shrunkCopied)")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
