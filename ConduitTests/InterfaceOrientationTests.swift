import Foundation
import XCTest

final class InterfaceOrientationTests: XCTestCase {
    private let appBundleIdentifier = "com.milim.relay"

    private func appInfoDictionary() throws -> [String: Any] {
        let bundle = try XCTUnwrap(Bundle(identifier: appBundleIdentifier))
        let infoData = try Data(contentsOf: bundle.bundleURL.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
    }

    /// The iPhone lists landscape so a bot's screen in full screen can turn
    /// sideways; `InterfaceOrientationGate` keeps every other screen in
    /// portrait (#2172), and HermesClientTests checks the gate.
    func testIPhoneOrientationsListLandscapeForTheGate() throws {
        let info = try appInfoDictionary()
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations"] as? [String],
            [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ]
        )
    }

    func testIPadOrientationsIncludeBothLandscapeDirections() throws {
        let info = try appInfoDictionary()
        XCTAssertEqual(
            info["UISupportedInterfaceOrientations~ipad"] as? [String],
            [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationPortraitUpsideDown",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ]
        )
        XCTAssertNil(info["UIRequiresFullScreen"])
    }
}
