import XCTest
import UIKit
@testable import Conduit

/// The contrast contract behind the accent picker (#697): every preset stays
/// readable wherever Conduit draws it, in light and dark, by WCAG AA. Values
/// come from the same presets and dynamic colours the UI draws with.
///
/// - Sent bubbles carry white text, so both stops of their fill need 4.5:1
///   against white.
/// - The accent is text and tint on the backdrop and on plain light
///   surfaces, so it needs 4.5:1 there.
///
/// One shade can't do both in dark mode: an accent light enough to read on
/// the near-black backdrop is too light for white text. So a sent bubble has
/// its own fill.
final class AccentContrastTests: XCTestCase {
    /// `ConduitBackdrop.base`, dark and light.
    private static let darkBackdrop = UIColor(red: 0.045, green: 0.052, blue: 0.072, alpha: 1)
    private static let lightBackdrop = UIColor(red: 0.94, green: 0.95, blue: 0.98, alpha: 1)

    func testSentBubbleTextIsReadableOnEveryPreset() {
        for choice in ConduitAccentChoice.allCases {
            for dark in [false, true] {
                let traits = Self.traits(choice, dark: dark)
                let top = UIColor.conduitUserBubble.resolvedColor(with: traits)
                let bottom = UIColor.conduitUserBubbleShade.resolvedColor(with: traits)
                XCTAssertGreaterThanOrEqual(Self.contrast(.white, top), 4.5, "\(choice) dark=\(dark): bubble top stop")
                XCTAssertGreaterThanOrEqual(Self.contrast(.white, bottom), 4.5, "\(choice) dark=\(dark): bubble bottom stop")
            }
        }
    }

    func testAccentReadsAsTextOnTheBackdrop() {
        for choice in ConduitAccentChoice.allCases {
            XCTAssertGreaterThanOrEqual(
                Self.contrast(choice.color(dark: true), Self.darkBackdrop), 4.5,
                "\(choice): dark accent on the dark backdrop"
            )
            XCTAssertGreaterThanOrEqual(
                Self.contrast(choice.color(dark: false), Self.lightBackdrop), 4.5,
                "\(choice): light accent on the light backdrop"
            )
            XCTAssertGreaterThanOrEqual(
                Self.contrast(choice.color(dark: false), .white), 4.5,
                "\(choice): light accent on a white surface"
            )
        }
    }

    func testSelectionOnASentBubbleStandsOutFromIt() {
        for choice in ConduitAccentChoice.allCases {
            for dark in [false, true] {
                let traits = Self.traits(choice, dark: dark)
                let bubble = UIColor.conduitUserBubble.resolvedColor(with: traits)
                let selection = UIColor.conduitSelectionOnAccent.resolvedColor(with: traits)
                XCTAssertGreaterThan(Self.contrast(bubble, selection), 3.0, "\(choice) dark=\(dark)")
            }
        }
    }

    func testTheBubbleFollowsThePick() {
        for choice in ConduitAccentChoice.allCases {
            for dark in [false, true] {
                let resolved = UIColor.conduitUserBubble.resolvedColor(with: Self.traits(choice, dark: dark))
                XCTAssertEqual(Self.contrast(resolved, choice.bubbleColor), 1, accuracy: 0.01, "\(choice) dark=\(dark)")
            }
        }
    }

    // MARK: Helpers

    private static func traits(_ choice: ConduitAccentChoice, dark: Bool) -> UITraitCollection {
        UITraitCollection(mutations: { traits in
            traits.conduitAccent = choice
            traits.userInterfaceStyle = dark ? .dark : .light
        })
    }

    /// WCAG 2.1 contrast ratio.
    private static func contrast(_ lhs: UIColor, _ rhs: UIColor) -> CGFloat {
        let first = lhs.conduitRelativeLuminance
        let second = rhs.conduitRelativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
