import XCTest

final class AgentAvatarPickerUITests: XCTestCase {
    func testSaveCancelRelaunchAndReset() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-uitest.example",
                               "-CONDUIT_UI_TEST_INBOX_FIXTURE", "multi-profile"]
        app.launch()
        openPicker(app)
        app.segmentedControls["avatar.style"].buttons["Character"].tap()
        app.buttons["avatar.shape.petal"].tap()
        app.buttons["avatar.color.blue"].tap()
        app.buttons["avatar.save"].tap()
        XCTAssertTrue(app.buttons["avatar.edit.default"].waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        openPicker(app)
        XCTAssertTrue(app.buttons["avatar.shape.petal"].isSelected)
        XCTAssertTrue(app.buttons["avatar.color.blue"].isSelected)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Production avatar picker"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["avatar.color.rose"].tap()
        app.buttons["avatar.cancel"].tap()
        app.buttons["avatar.edit.default"].tap()
        XCTAssertTrue(app.buttons["avatar.color.blue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["avatar.color.blue"].isSelected)

        app.swipeUp()
        app.buttons["avatar.reset"].tap()
        app.buttons["avatar.save"].tap()
        app.buttons["avatar.edit.default"].tap()
        XCTAssertTrue(app.buttons["avatar.shape.softSquare"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["avatar.shape.softSquare"].isSelected)
        XCTAssertTrue(app.buttons["avatar.color.orange"].isSelected)
        app.buttons["avatar.cancel"].tap()
    }

    private func openPicker(_ app: XCUIApplication) {
        let profiles = app.buttons["Profile management"]
        XCTAssertTrue(profiles.waitForExistence(timeout: 10), app.debugDescription)
        profiles.tap()
        let edit = app.buttons["avatar.edit.default"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription)
        edit.tap()
        XCTAssertTrue(app.buttons["avatar.save"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
