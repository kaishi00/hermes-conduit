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
/// A colour of the user's own is held to the same contract: its shades are
/// worked out from the pick, so the extremes are checked too.
///
/// One shade can't do both in dark mode: an accent light enough to read on
/// the near-black backdrop is too light for white text. So a sent bubble has
/// its own fill.
final class AccentContrastTests: XCTestCase {
    /// `ConduitBackdrop.base`, dark and light.
    private static let darkBackdrop = UIColor(red: 0.045, green: 0.052, blue: 0.072, alpha: 1)
    private static let lightBackdrop = UIColor(red: 0.94, green: 0.95, blue: 0.98, alpha: 1)

    func testSentBubbleTextIsReadableOnEveryPreset() {
        for choice in Self.everyAccent {
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
        for choice in Self.everyAccent {
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
        for choice in Self.everyAccent {
            for dark in [false, true] {
                let traits = Self.traits(choice, dark: dark)
                let bubble = UIColor.conduitUserBubble.resolvedColor(with: traits)
                let selection = UIColor.conduitSelectionOnAccent.resolvedColor(with: traits)
                XCTAssertGreaterThan(Self.contrast(bubble, selection), 3.0, "\(choice) dark=\(dark)")
            }
        }
    }

    func testTheMarkOnAFillIsWhicheverOfBlackAndWhiteStandsOutMore() {
        // A grid of fills, mid greys included, where a cutoff off the
        // black/white crossover (luminance ~0.179) picks the weaker one.
        let steps: [CGFloat] = [0, 0.2, 0.4, 0.45, 0.5, 0.55, 0.6, 0.8, 1]
        var fills = steps.flatMap { red in steps.flatMap { green in steps.map { blue in
            UIColor(red: red, green: green, blue: blue, alpha: 1)
        } } }
        fills += ConduitAccentChoice.allCases.flatMap { [$0.color(dark: true), $0.color(dark: false), $0.softColor(dark: true)] }
        for fill in fills {
            let mark = ConduitAccentChoice.markColor(on: fill)
            let other: UIColor = Self.contrast(mark, .black) < 1.01 ? .white : .black
            XCTAssertGreaterThanOrEqual(Self.contrast(mark, fill), Self.contrast(other, fill), "fill \(fill)")
        }
    }

    func testTheBubbleFollowsThePick() {
        for choice in Self.everyAccent {
            for dark in [false, true] {
                let resolved = UIColor.conduitUserBubble.resolvedColor(with: Self.traits(choice, dark: dark))
                XCTAssertEqual(Self.contrast(resolved, choice.bubbleColor), 1, accuracy: 0.01, "\(choice) dark=\(dark)")
            }
        }
    }

    func testACustomColorRoundTripsThroughItsStoredValue() {
        let pick = CustomAccentColor(red: 0.2, green: 0.6, blue: 0.4)
        XCTAssertEqual(ConduitAccent(rawValue: pick.hex), .custom(pick))
        XCTAssertEqual(ConduitAccent(rawValue: "teal"), .preset(.teal))
        XCTAssertNil(ConduitAccent(rawValue: "#12345"))
        XCTAssertNil(ConduitAccent(rawValue: "violet"))
    }

    func testACustomColorThatAlreadyReadsIsDrawnAsPicked() {
        // A mid blue reads on the dark backdrop as it is.
        let pick = CustomAccentColor(red: 0.33, green: 0.58, blue: 0.98)
        XCTAssertEqual(pick.darkShade, pick.picked)
        XCTAssertNotEqual(pick.lightShade, pick.picked, "too light for white text, so darkened")
    }

    // MARK: Helpers

    /// Every preset, and custom picks from white to black: the palest and
    /// darkest, pure primaries, a grey, and a spread of hues.
    private static let customPicks: [(red: Double, green: Double, blue: Double)] = [
        (1, 1, 1), (0, 0, 0), (0.5, 0.5, 0.5), (1, 1, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1),
        (0, 1, 1), (1, 0, 1), (1, 0.95, 0.85), (0.05, 0.08, 0.2), (0.89, 0.38, 0.25),
    ]
    private static let everyAccent: [ConduitAccent] = ConduitAccentChoice.allCases.map { ConduitAccent.preset($0) }
        + customPicks.map { ConduitAccent.custom(CustomAccentColor(red: $0.red, green: $0.green, blue: $0.blue)) }

    private static func traits(_ choice: ConduitAccent, dark: Bool) -> UITraitCollection {
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
