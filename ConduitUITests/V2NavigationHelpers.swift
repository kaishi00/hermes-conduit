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
