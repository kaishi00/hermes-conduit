//
//  V2NavigationHelpers.swift
//  ConduitUITests
//
//  Shared navigation for UI tests running against the V2 tab shell.
//

import XCTest

extension XCUIApplication {
    /// V2 opens on Chats, where the tab bar and the profile strip live; if a
    /// conversation is showing instead, Back returns there.
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
