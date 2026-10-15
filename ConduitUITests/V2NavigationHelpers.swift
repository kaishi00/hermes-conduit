//
//  V2NavigationHelpers.swift
//  ConduitUITests
//
//  Shared navigation for UI tests running against the V2 tab shell.
//

import XCTest

extension XCUIApplication {
    /// V2 opens the last conversation at launch with the tab bar hidden; Back
    /// returns to Chats, where the tab bar and the profile strip live.
    func returnToV2Tabs(revealing element: XCUIElement) {
        if element.waitForExistence(timeout: 5) { return }
        let candidates = [
            navigationBars.buttons["Chats"],
            navigationBars.buttons["BackButton"],
            navigationBars.buttons["Back"]
        ]
        // Named Back only: a room's first bar button is Leave.
        candidates.first(where: { $0.exists })?.tap()
    }
}
