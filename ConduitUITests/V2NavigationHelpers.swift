//
//  V2NavigationHelpers.swift
//  ConduitUITests
//
//  Shared navigation for UI tests running against the V2 tab shell.
//

import XCTest

extension XCUIApplication {
    /// Conduit as every UI test launches it: the backdrop holds still
    /// (`ConduitBackdropMotionPolicy.isHeldStillForUITests`), since XCUITest
    /// waits for the app to settle before each step and a drifting backdrop
    /// never settles.
    static func conduit() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CONDUIT_STILL_BACKDROP"] = "1"
        return app
    }

    /// V2 opens on Bots; the profile strip lives on Sessions. If a
    /// conversation is showing, Back returns to the tabs, and if the
    /// element still can't be tapped, the Sessions tab shows it. The shell
    /// keeps a visited tab mounted under the selected one, so the element
    /// can exist there without being hittable.
    func returnToV2Tabs(revealing element: XCUIElement) {
        if element.waitForExistence(timeout: 5), element.isHittable { return }
        let candidates = [
            navigationBars.buttons["Sessions"],
            navigationBars.buttons["Bots"],
            navigationBars.buttons["BackButton"],
            navigationBars.buttons["Back"]
        ]
        // Named Back only: a room's first bar button is Leave.
        if let back = candidates.first(where: { $0.exists }) {
            back.tap()
            if element.waitForExistence(timeout: 3), element.isHittable { return }
        }
        let sessions = buttons["Sessions"].firstMatch
        if sessions.waitForExistence(timeout: 5) { sessions.tap() }
        _ = element.waitForExistence(timeout: 5)
    }
}

extension XCUIElement {
    /// Waits until this field has the keyboard, for a test about to type in
    /// it. A simulator's first keyboard after a fresh install can take
    /// several seconds to come up: typing straight after the tap then failed
    /// with "Neither element nor any descendant has keyboard focus" on the
    /// first run of a Nightly shard (2026-11-14). Taps again once, halfway
    /// through, if the first tap was lost; `tappingAgain: false` is for a
    /// field that got its focus some other way (Return from the field above).
    func waitForKeyboardFocus(
        timeout: TimeInterval = 40,
        tappingAgain: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let retapAt = Date().addingTimeInterval(timeout / 2)
        var tappedAgain = !tappingAgain
        while Date() < deadline {
            if (value(forKey: "hasKeyboardFocus") as? Bool) == true { return }
            if !tappedAgain, Date() >= retapAt {
                tappedAgain = true
                if isHittable { tap() }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let name = identifier.isEmpty ? label : identifier
        XCTFail("\(name.isEmpty ? "The field" : name) never got keyboard focus", file: file, line: line)
    }
}
