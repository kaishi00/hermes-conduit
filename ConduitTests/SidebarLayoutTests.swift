//
//  SidebarLayoutTests.swift
//  Conduit
//
//  Coverage for the iPad persistent-sidebar layout policy and the drawer
//  dismissal helper shared by the sidebar's session-opening flows.
//

import XCTest
@testable import Conduit

final class SidebarLayoutTests: XCTestCase {
    private let phone = UIUserInterfaceIdiom.phone
    private let pad = UIUserInterfaceIdiom.pad

    private func resolve(
        _ idiom: UIUserInterfaceIdiom,
        prefersPersistentSidebar: Bool,
        availableWidth: CGFloat
    ) -> SidebarPresentation {
        SidebarLayoutPolicy.resolvePresentation(
            idiom: idiom,
            prefersPersistentSidebar: prefersPersistentSidebar,
            availableWidth: availableWidth
        )
    }

    // MARK: - Layout resolution

    func testPhoneUsesDrawerRegardlessOfPreferenceOrWidth() {
        for prefersPersistentSidebar in [false, true] {
            for width: CGFloat in [0, 320, 430, 768, 1024, 1366] {
                XCTAssertEqual(
                    resolve(phone, prefersPersistentSidebar: prefersPersistentSidebar, availableWidth: width),
                    .drawer,
                    "iPhone must keep the drawer (preference \(prefersPersistentSidebar), width \(width))."
                )
            }
        }
    }

    func testIPadWithPreferenceOffUsesDrawerAtAnyWidth() {
        for width: CGFloat in [0, 512, 683, 750, 768, 1024, 1366] {
            XCTAssertEqual(
                resolve(pad, prefersPersistentSidebar: false, availableWidth: width),
                .drawer,
                "Opt-out must keep the drawer at width \(width)."
            )
        }
    }

    func testIPadWithPreferenceOnAndWideWindowUsesPersistentSidebar() {
        // Full-screen landscape, full-screen portrait (768), and wide
        // Split View / Stage Manager tiles all clear the threshold.
        for width: CGFloat in [768, 834, 1024, 1194, 1366] {
            XCTAssertEqual(
                resolve(pad, prefersPersistentSidebar: true, availableWidth: width),
                .persistent,
                "Wide iPad window (\(width)) with the opt-in should host the persistent sidebar."
            )
        }
    }

    func testIPadWithPreferenceOnAndNarrowWindowFallsBackToDrawer() {
        // Split View halves, small Stage Manager tiles, and undetermined
        // pre-layout widths must keep the drawer.
        for width: CGFloat in [0, 320, 417, 512, 683, 749] {
            XCTAssertEqual(
                resolve(pad, prefersPersistentSidebar: true, availableWidth: width),
                .drawer,
                "Narrow iPad window (\(width)) must fall back to the drawer."
            )
        }
    }

    func testPersistentThresholdKeepsMinimumChatWidth() {
        XCTAssertEqual(
            SidebarLayoutMetrics.minimumPersistentLayoutWidth,
            SidebarLayoutMetrics.persistentSidebarWidth + SidebarLayoutMetrics.minimumChatWidth
        )

        let threshold = SidebarLayoutMetrics.minimumPersistentLayoutWidth
        XCTAssertEqual(
            resolve(pad, prefersPersistentSidebar: true, availableWidth: threshold),
            .persistent,
            "A window exactly at the threshold still leaves the minimum chat width."
        )
        XCTAssertEqual(
            resolve(pad, prefersPersistentSidebar: true, availableWidth: threshold - 1),
            .drawer,
            "One point below the threshold would squeeze the chat column."
        )
    }

    // MARK: - Return surface

    func testReturnSurfaceSkipsDrawerWhilePersistentSidebarIsActive() {
        XCTAssertFalse(
            SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
                persistentSidebarActive: true,
                drawerPresented: false
            ),
            "The persistent sidebar already shows Sessions; no drawer may open over it."
        )
        XCTAssertFalse(
            SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
                persistentSidebarActive: true,
                drawerPresented: true
            )
        )
    }

    func testReturnSurfacePreservesDrawerBehaviorWhenPersistentIsInactive() {
        XCTAssertTrue(
            SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
                persistentSidebarActive: false,
                drawerPresented: false
            ),
            "Drawer layouts keep opening the sessions drawer for return-surface requests."
        )
        XCTAssertFalse(
            SidebarLayoutPolicy.shouldPresentDrawerForReturnSurface(
                persistentSidebarActive: false,
                drawerPresented: true
            ),
            "An already-presented drawer is not re-presented."
        )
    }

    // MARK: - Drawer dismissal helper

    @MainActor
    func testDismissSidebarDrawerClosesOpenDrawer() {
        let state = makeAppState()
        state.showSidebar = true

        state.dismissSidebarDrawer()

        XCTAssertFalse(state.showSidebar)
    }

    @MainActor
    func testDismissSidebarDrawerIsNoOpWhenDrawerIsClosed() {
        let state = makeAppState()

        // Session-opening flows call this unconditionally; in the persistent
        // layout the drawer is never presented, so the helper must leave
        // showSidebar untouched rather than force a publication flush.
        state.dismissSidebarDrawer()

        XCTAssertFalse(state.showSidebar)
    }

    @MainActor
    private func makeAppState() -> AppState {
        let suite = "SidebarLayoutTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(
            defaults: defaults,
            loadSavedConnection: false,
            chatResumeLifecycleOperations: .live
        )
    }
}
