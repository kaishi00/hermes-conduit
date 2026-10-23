import XCTest
import UIKit
@testable import Conduit

/// The chat text style (typeface) beside the size: prose takes the picked
/// system design at the same size, code stays monospaced, and caches key on
/// the style without changing default-style keys.
extension ChatTypographyTests {
    func testEveryStyleKeepsTheSizeAndOnlyTheDefaultKeepsTheFont() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let base = ChatTypography.font(for: .body, appearance: .larger, compatibleWith: traits)
        for style in ChatFontStyle.allCases {
            let font = ChatTypography.font(
                for: .body,
                appearance: ChatTextAppearance(size: .larger, style: style),
                compatibleWith: traits
            )
            XCTAssertEqual(font.pointSize, base.pointSize, accuracy: 0.001, "\(style) keeps the size")
            if style == .standard {
                XCTAssertEqual(font.fontName, base.fontName)
            } else {
                XCTAssertNotEqual(font.fontName, base.fontName, "\(style) sets prose in its own design")
            }
        }
    }

    func testHeadingsKeepTheirWeightInAStyle() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let heading = ChatTypography.font(
            for: .heading(level: 1),
            appearance: ChatTextAppearance(size: .default, style: .serif),
            compatibleWith: traits
        )
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testCodeStaysMonospacedInEveryStyle() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        for role in [ChatTypography.Role.blockCode, .sourceCode] {
            let base = ChatTypography.font(for: role, appearance: .default, compatibleWith: traits)
            for style in ChatFontStyle.allCases {
                let font = ChatTypography.font(
                    for: role,
                    appearance: ChatTextAppearance(size: .default, style: style),
                    compatibleWith: traits
                )
                XCTAssertEqual(font, base, "\(role) in \(style)")
            }
        }
    }

    func testTheStyleKeysCachesAndTheDefaultKeepsItsKey() {
        XCTAssertEqual(ChatTextAppearance.default.cacheIdentity, ChatTextSize.default.cacheIdentity)
        let identities = Set(ChatFontStyle.allCases.map {
            ChatTextAppearance(size: .default, style: $0).cacheIdentity
        })
        XCTAssertEqual(identities.count, ChatFontStyle.allCases.count)
        XCTAssertNotEqual(
            ChatTextAppearance(size: .default, style: .serif),
            ChatTextAppearance.default,
            "a style change compares unequal and re-opens settled gates"
        )
    }

    func testAnUnknownStoredStyleReadsAsTheDefault() {
        XCTAssertEqual(ChatTypography.resolveStyle(rawValue: nil), .standard)
        XCTAssertEqual(ChatTypography.resolveStyle(rawValue: "comic"), .standard)
        XCTAssertEqual(ChatTypography.resolveStyle(rawValue: "serif"), .serif)
    }
}
