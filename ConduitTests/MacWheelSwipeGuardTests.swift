import UIKit
import XCTest
@testable import Conduit

/// Stands in for UIKit's private `_UISwipeActionPanGestureRecognizer`,
/// which the guard knows by name.
private final class FakeSwipeActionPanRecognizer: UIPanGestureRecognizer {}

/// The Mac wheel guard's walk (#1480).
@MainActor
final class MacWheelSwipeGuardTests: XCTestCase {
    func testWheelGuardStopsScrollEventsOnlyForRowSwipesOfListsAboveThePointer() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let list = UIScrollView(frame: window.bounds)
        let row = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 44))
        window.addSubview(list)
        list.addSubview(row)

        let swipe = FakeSwipeActionPanRecognizer(target: nil, action: nil)
        swipe.allowedScrollTypesMask = .all
        list.addGestureRecognizer(swipe)
        list.panGestureRecognizer.allowedScrollTypesMask = .continuous
        let otherPan = UIPanGestureRecognizer(target: nil, action: nil)
        otherPan.allowedScrollTypesMask = .all
        list.addGestureRecognizer(otherPan)

        let elsewhere = UIScrollView(frame: window.bounds)
        window.addSubview(elsewhere)
        let elsewhereSwipe = FakeSwipeActionPanRecognizer(target: nil, action: nil)
        elsewhereSwipe.allowedScrollTypesMask = .all
        elsewhere.addGestureRecognizer(elsewhereSwipe)

        MacWheelSwipeGuardRecognizer.stopWheelSwipes(under: row)

        XCTAssertEqual(swipe.allowedScrollTypesMask, [])
        XCTAssertEqual(otherPan.allowedScrollTypesMask, .all, "another pan on the list is left alone")
        XCTAssertEqual(elsewhereSwipe.allowedScrollTypesMask, .all, "only lists under the pointer change")
        XCTAssertEqual(list.panGestureRecognizer.allowedScrollTypesMask, .continuous, "the list's scrolling keeps its own")
    }

    func testWheelGuardKnowsRowSwipesByUIKitsClassName() {
        XCTAssertTrue(MacWheelSwipeGuardRecognizer.isSwipeActionPan(FakeSwipeActionPanRecognizer()))
        XCTAssertFalse(MacWheelSwipeGuardRecognizer.isSwipeActionPan(UIPanGestureRecognizer()))
        XCTAssertFalse(MacWheelSwipeGuardRecognizer.isSwipeActionPan(UIScrollView().panGestureRecognizer))
    }
}
