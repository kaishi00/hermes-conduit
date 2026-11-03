//
//  V2NavigationHelpers.swift
//  ConduitUITests
//
//  Shared navigation for UI tests running against the V2 tab shell.
//

import XCTest

extension XCUIApplication {
    /// V2 opens on Bots; the profile strip lives on Sessions. If a
    /// conversation is showing, Back returns to the tabs, and if the
    /// element still isn't there, the Sessions tab shows it.
    func returnToV2Tabs(revealing element: XCUIElement) {
        if element.waitForExistence(timeout: 5) { return }
        let candidates = [
            navigationBars.buttons["Sessions"],
            navigationBars.buttons["Bots"],
            navigationBars.buttons["BackButton"],
            navigationBars.buttons["Back"]
        ]
        // Named Back only: a room's first bar button is Leave.
        candidates.first(where: { $0.exists })?.tap()
        if element.waitForExistence(timeout: 3) { return }
        let sessions = buttons["Sessions"].firstMatch
        if sessions.waitForExistence(timeout: 5) { sessions.tap() }
    }
}
