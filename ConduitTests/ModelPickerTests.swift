import XCTest
@testable import Conduit

final class ModelPickerTests: XCTestCase {
    func testModelPickerYoloDraftStartsFromCurrentRuntimeValue() {
        let draft = ModelPickerYoloDraft(runtimeYolo: true)

        XCTAssertTrue(draft.initial)
        XCTAssertTrue(draft.selected)
    }

    func testModelPickerYoloDraftSeedsWhenInitialBaselineIsMissing() {
        let draft = ModelPickerYoloDraft.seededIfNeeded(initial: nil, runtimeYolo: true)

        XCTAssertEqual(draft, ModelPickerYoloDraft(runtimeYolo: true))
    }

    func testModelPickerYoloDraftDoesNotReseedAnExistingBaseline() {
        let draft = ModelPickerYoloDraft.seededIfNeeded(initial: false, runtimeYolo: true)

        XCTAssertNil(draft)
    }

    func testUnchangedYoloSelectionDoesNotPersistASessionOverride() {
        XCTAssertFalse(sessionYoloSelectionChanged(from: true, to: true))
    }

    func testChangedYoloSelectionPersistsTheNewSessionOverride() {
        XCTAssertTrue(sessionYoloSelectionChanged(from: false, to: true))
        XCTAssertTrue(sessionYoloSelectionChanged(from: true, to: false))
    }

    func testSelectionBeforeInitialLoadDoesNotPersistAnOverride() {
        XCTAssertFalse(sessionYoloSelectionChanged(from: nil, to: true))
    }

    func testFloorBoundaryOnlyCrossesBetweenOffAndNonOff() {
        // Boundary crossings re-seed the toggle.
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: nil, to: "off"))
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: "manual", to: "off"))
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: "off", to: "manual"))
        XCTAssertTrue(yoloFloorBoundaryCrossed(from: "off", to: nil))
        // Same-side transitions must not discard an in-progress draft.
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: nil, to: "manual"))
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: "manual", to: "smart"))
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: "smart", to: "manual"))
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: "off", to: "off"))
        XCTAssertFalse(yoloFloorBoundaryCrossed(from: nil, to: nil))
    }
}
