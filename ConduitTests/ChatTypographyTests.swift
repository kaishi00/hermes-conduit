//
//  ChatTypographyTests.swift
//  ConduitTests
//
//  Regression coverage for the chat-only text-size preference (issue #85):
//  preference persistence, centralized typography resolution, typography-
//  sensitive cache identities (render cache, table measurement, flow-chunk
//  memos, code-slice identity), and the settled-row Equatable gates.
//
//  Scope note: interface chrome (timestamps, buttons, navigation, Settings,
//  composer, selection handles) intentionally does NOT resolve through
//  ChatTypography — that exclusion is a code-review invariant, not something
//  the unit harness can observe; the font-level tests here pin the content
//  side so any accidental app-wide scaling surfaces as a failure.
//

import SwiftUI
import UIKit
import XCTest
@testable import Conduit

final class ChatTypographyTests: XCTestCase {

    // MARK: - Preference model

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: ChatTypography.preferenceKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: ChatTypography.preferenceKey)
        super.tearDown()
    }

    func testPreferenceDefaultsToDefaultWithNoStoredValue() {
        // A missing key must resolve to the default position so existing
        // users keep today's transcript appearance after updating.
        XCTAssertNil(UserDefaults.standard.object(forKey: ChatTypography.preferenceKey))
        XCTAssertEqual(ChatTypography.stored(), .default)
        XCTAssertEqual(ChatTypography.resolve(rawValue: nil), .default)
    }

    func testAllFivePersistedValuesRoundTrip() {
        for size in ChatTextSize.allCases {
            UserDefaults.standard.set(size.rawValue, forKey: ChatTypography.preferenceKey)
            XCTAssertEqual(ChatTypography.stored(), size, "rawValue `\(size.rawValue)` must round-trip")
        }
    }

    func testInvalidPersistedValuesFallBackSafely() {
        for invalid in [-1, 5, 99, Int.min, Int.max] {
            UserDefaults.standard.set(invalid, forKey: ChatTypography.preferenceKey)
            XCTAssertEqual(
                ChatTypography.stored(),
                .default,
                "out-of-range rawValue \(invalid) must fall back to .default"
            )
        }
        // Non-integer storage reads as "no valid Int" too.
        UserDefaults.standard.set("nonsense", forKey: ChatTypography.preferenceKey)
        XCTAssertEqual(ChatTypography.stored(), .default)
    }

    func testCacheIdentitiesAreDistinctPerPosition() {
        let identities = Set(ChatTextSize.allCases.map(\.cacheIdentity))
        XCTAssertEqual(identities.count, ChatTextSize.allCases.count,
                       "each position needs its own cache identity so no cache can cross sizes")
    }

    // MARK: - Typography resolution

    func testScaleFactorsMatchSpecification() {
        let expected: [ChatTextSize: CGFloat] = [
            .smallest: 0.85,
            .smaller: 0.925,
            .default: 1.00,
            .larger: 1.125,
            .largest: 1.25
        ]
        for (size, factor) in expected {
            XCTAssertEqual(ChatTypography.scale(for: size), factor, accuracy: 0.0001,
                           "\(size) scale must match the documented factor")
        }
    }

    func testDefaultResolvesExactlyTodayTypography() {
        let roles: [ChatTypography.Role] = [
            .body, .heading(level: 1), .heading(level: 3), .quote,
            .tableHeader, .tableBody, .thinking, .blockCode, .sourceCode
        ]
        for role in roles {
            let resolved = ChatTypography.font(for: role, chatSize: .default)
            let base = ChatTypography.baseFont(for: role)
            XCTAssertEqual(resolved.pointSize, base.pointSize, accuracy: 0.001,
                           "\(role) at .default must be the historical font")
            XCTAssertEqual(resolved.fontDescriptor, base.fontDescriptor,
                           "\(role) at .default must preserve the historical descriptor")
        }
    }

    func testSizesAreMonotonicAcrossAllRoles() {
        let ordered = ChatTextSize.allCases.sorted { $0.rawValue < $1.rawValue }
        let roles: [ChatTypography.Role] = [
            .body, .heading(level: 1), .heading(level: 4), .quote,
            .tableHeader, .tableBody, .thinking, .blockCode, .sourceCode
        ]
        for role in roles {
            var previous: CGFloat = -1
            for size in ordered {
                let pointSize = ChatTypography.font(for: role, chatSize: size).pointSize
                XCTAssertGreaterThan(pointSize, previous,
                                     "\(role) must strictly grow across positions at \(size)")
                previous = pointSize
            }
        }
    }

    func testSystemDynamicTypeStillAffectsResolvedFonts() {
        // The chat scale must AUGMENT Dynamic Type, never replace it: at a
        // fixed chat size, a larger system category still yields larger fonts.
        let small = UITraitCollection(preferredContentSizeCategory: .small)
        let huge = UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
        for size in ChatTextSize.allCases {
            for role in [ChatTypography.Role.body, .heading(level: 2), .tableBody] {
                let atSmall = ChatTypography.font(for: role, chatSize: size, compatibleWith: small)
                let atHuge = ChatTypography.font(for: role, chatSize: size, compatibleWith: huge)
                XCTAssertGreaterThan(
                    atHuge.pointSize, atSmall.pointSize,
                    "\(role) at chat size \(size) must still respond to Dynamic Type"
                )
            }
        }
        // And the augmentation composes: largest system + largest chat is
        // exactly 1.25x the largest system font.
        let base = ChatTypography.font(for: .body, chatSize: .default, compatibleWith: huge)
        let scaled = ChatTypography.font(for: .body, chatSize: .largest, compatibleWith: huge)
        XCTAssertEqual(scaled.pointSize, base.pointSize * 1.25, accuracy: 0.001)
    }

    func testSemanticHierarchyRemainsIntactAtEverySize() {
        for size in ChatTextSize.allCases {
            func font(_ role: ChatTypography.Role) -> UIFont {
                ChatTypography.font(for: role, chatSize: size)
            }
            let h1 = font(.heading(level: 1))
            let h2 = font(.heading(level: 2))
            let h3 = font(.heading(level: 3))
            let h4 = font(.heading(level: 4))
            let body = font(.body)
            let tableBody = font(.tableBody)

            XCTAssertGreaterThan(h1.pointSize, h2.pointSize)
            XCTAssertGreaterThan(h2.pointSize, h3.pointSize)
            XCTAssertGreaterThan(h3.pointSize, h4.pointSize)
            // h3 keeps today's relationship to body: same size, heavier trait.
            XCTAssertEqual(h3.pointSize, body.pointSize, accuracy: 0.001)
            XCTAssertTrue(h3.fontDescriptor.symbolicTraits.contains(.traitBold),
                          "a heading must still look like a heading (bold) at \(size)")
            XCTAssertGreaterThan(body.pointSize, tableBody.pointSize)

            // Code stays monospaced at every size.
            for codeRole in [ChatTypography.Role.blockCode, .sourceCode] {
                let codeFont = font(codeRole)
                XCTAssertEqual(
                    codeFont.fontName,
                    UIFont.monospacedSystemFont(ofSize: 10, weight: .regular).fontName,
                    "\(codeRole) must stay monospaced at \(size)"
                )
            }
            XCTAssertTrue(font(.tableHeader).fontDescriptor.symbolicTraits.contains(.traitBold),
                          "table header must stay bold at \(size)")
            XCTAssertTrue(font(.quote).fontDescriptor.symbolicTraits.contains(.traitItalic),
                          "quote must stay italic at \(size)")
        }
    }

    // MARK: - Markdown render cache

    private let cacheFixtureSource = """
    ## Cached typography probe

    A paragraph with **bold**, *italic*, `code`, and a [link](https://example.com).
    """

    @MainActor
    func testRenderCacheSeparatesChatSizes() throws {
        func firstFontSize(_ rendering: MarkdownRendering) throws -> CGFloat {
            let attributed = try XCTUnwrap(rendering.selectableText)
            let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            return font.pointSize
        }

        let atDefault = MarkdownRenderCache.rendering(
            source: cacheFixtureSource,
            recognizesGatewayMedia: false,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            isStreaming: false,
            chatTextSize: .default
        )
        let atLargest = MarkdownRenderCache.rendering(
            source: cacheFixtureSource,
            recognizesGatewayMedia: false,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            isStreaming: false,
            chatTextSize: .largest
        )
        XCTAssertFalse(atDefault === atLargest,
                       "a chat-size change must never reuse the other size's rendering")
        XCTAssertGreaterThan(try firstFontSize(atLargest), try firstFontSize(atDefault),
                             "the rebuilt rendering must carry the larger fonts")

        // Returning to the earlier size must hit the original cached entry
        // again — both directions stay cached, nothing stale is served.
        let backToDefault = MarkdownRenderCache.rendering(
            source: cacheFixtureSource,
            recognizesGatewayMedia: false,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            isStreaming: false,
            chatTextSize: .default
        )
        XCTAssertTrue(backToDefault === atDefault,
                      "returning to a previously rendered size must reuse that size's cache entry")
    }

    @MainActor
    func testStreamingAndSettledConvergeOnOneTypography() throws {
        // Stable chunks (isStreaming: false) and the live tail
        // (isStreaming: true) resolve through the same ChatTypography value,
        // so a mid-stream preference change moves BOTH pieces together.
        func firstFontSize(isStreaming: Bool, chatTextSize: ChatTextSize) throws -> CGFloat {
            let rendering = MarkdownRenderCache.rendering(
                source: cacheFixtureSource,
                recognizesGatewayMedia: false,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                isStreaming: isStreaming,
                chatTextSize: chatTextSize
            )
            let attributed = try XCTUnwrap(rendering.selectableText)
            let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
            return font.pointSize
        }

        let settled = try firstFontSize(isStreaming: false, chatTextSize: .larger)
        let streaming = try firstFontSize(isStreaming: true, chatTextSize: .larger)
        XCTAssertEqual(streaming, settled, accuracy: 0.001,
                       "streaming and settled content must resolve identical fonts")

        let settledDefault = try firstFontSize(isStreaming: false, chatTextSize: .default)
        XCTAssertGreaterThan(settled, settledDefault)
    }

    // MARK: - Selection formatter fonts

    func testFormatterScalesAllInlineRuns() throws {
        let blocks = MarkdownParser.parse("A **bold** run, *italic*, `code`, and plain.")
        func fontSizes(at size: ChatTextSize) throws -> [CGFloat] {
            let attributed = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
                for: blocks,
                foregroundStyle: .primary,
                usesAccentSurface: false,
                newestCharacterOpacities: [],
                chatTextSize: size
            ))
            var sizes: [CGFloat] = []
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
                if let font = value as? UIFont { sizes.append(font.pointSize) }
            }
            return sizes
        }

        let baseline = try fontSizes(at: .default)
        let scaled = try fontSizes(at: .larger)
        XCTAssertEqual(baseline.count, scaled.count)
        for (index, baseSize) in baseline.enumerated() {
            XCTAssertEqual(scaled[index], baseSize * 1.125, accuracy: 0.01,
                           "every run (bold, italic, code, plain) must scale proportionally")
        }
    }

    func testFormatterDefaultMatchesUnscaledPreferredFont() throws {
        let blocks = MarkdownParser.parse("Plain paragraph for the baseline probe.")
        let attributed = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
            for: blocks,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            newestCharacterOpacities: [],
            chatTextSize: .default
        ))
        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, UIFont.preferredFont(forTextStyle: .body).pointSize, accuracy: 0.001)
    }

    func testSelectionContentIsSizeInvariant() throws {
        // Selection works on character ranges; the typography change must
        // not alter the string the ranges point into.
        let blocks = MarkdownParser.parse("## Head\n\nOne **two** three.")
        let small = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
            for: blocks, foregroundStyle: .primary, usesAccentSurface: false,
            newestCharacterOpacities: [], chatTextSize: .smallest
        ))
        let large = try XCTUnwrap(MarkdownSelectionFormatter.attributedText(
            for: blocks, foregroundStyle: .primary, usesAccentSurface: false,
            newestCharacterOpacities: [], chatTextSize: .largest
        ))
        XCTAssertEqual(small.string, large.string)
        XCTAssertEqual(small.length, large.length)
    }

    // MARK: - Large-document flow chunk memo

    @MainActor
    func testFlowChunkBoxInvalidatesOnChatTextSizeChange() {
        let box = LargeFlowChunkBox()
        let blocks: [MarkdownBlock] = [.paragraph("Large-document chunk typography probe.")]

        let atDefault = box.attributedText(
            blocks: blocks, references: .empty,
            foregroundStyle: .primary, usesAccentSurface: false,
            contentCategory: .large, chatTextSize: .default
        )
        let cachedDefault = box.attributedText(
            blocks: blocks, references: .empty,
            foregroundStyle: .primary, usesAccentSurface: false,
            contentCategory: .large, chatTextSize: .default
        )
        XCTAssertTrue(atDefault === cachedDefault, "same chat size must reuse the memoized string")

        let atLargest = box.attributedText(
            blocks: blocks, references: .empty,
            foregroundStyle: .primary, usesAccentSurface: false,
            contentCategory: .large, chatTextSize: .largest
        )
        XCTAssertFalse(atDefault === atLargest,
                       "a chat-size change must rebuild the memoized chunk")
        if let oldFont = atDefault?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont,
           let newFont = atLargest?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
            XCTAssertGreaterThan(newFont.pointSize, oldFont.pointSize)
        } else {
            XCTFail("flow chunk strings must carry fonts")
        }

        let backToDefault = box.attributedText(
            blocks: blocks, references: .empty,
            foregroundStyle: .primary, usesAccentSurface: false,
            contentCategory: .large, chatTextSize: .default
        )
        // The box is a single-slot memo: returning to the earlier size
        // legitimately REBUILDS (the .largest entry replaced it) — the
        // contract is that it rebuilds to the original size's metrics and
        // never serves the other size's string.
        XCTAssertFalse(backToDefault === atLargest,
                       "the previous size's string must not be served at the original size")
        if let originalFont = atDefault?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont,
           let rebuiltFont = backToDefault?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
            XCTAssertEqual(rebuiltFont.pointSize, originalFont.pointSize, accuracy: 0.001,
                           "the rebuilt memo must carry the original size's typography")
        } else {
            XCTFail("flow chunk strings must carry fonts")
        }
    }

    // MARK: - Table measurement identity

    @MainActor
    func testTableMeasurementChangesWithChatSize() {
        // Wide cells exercise the measurement (not the fixed caps): the
        // fonts grow, so the ideal cell widths grow too.
        let headers = ["Column One", "Column Two"]
        let rows = [["measured content driver", "second driver value"]]

        let atDefault = MarkdownTableLayout.columnWidths(
            headers: headers, rows: rows,
            availableWidth: 390, chatTextSize: .default
        )
        let atLargest = MarkdownTableLayout.columnWidths(
            headers: headers, rows: rows,
            availableWidth: 390, chatTextSize: .largest
        )
        XCTAssertEqual(atDefault.count, atLargest.count)
        for (old, new) in zip(atDefault, atLargest) {
            XCTAssertGreaterThan(new, old,
                                 "larger chat text must measure wider cells — no stale widths")
        }

        // Back to the first size: the original measurements again (exact
        // equality proves the cache served the right identity).
        let backToDefault = MarkdownTableLayout.columnWidths(
            headers: headers, rows: rows,
            availableWidth: 390, chatTextSize: .default
        )
        XCTAssertEqual(backToDefault, atDefault)

        // Narrow table: tiny content stays a valid two-column layout.
        let tiny = MarkdownTableLayout.columnWidths(
            headers: ["A", "B"], rows: [["1", "2"]],
            availableWidth: 390, chatTextSize: .default
        )
        let tinyLarge = MarkdownTableLayout.columnWidths(
            headers: ["A", "B"], rows: [["1", "2"]],
            availableWidth: 390, chatTextSize: .largest
        )
        XCTAssertEqual(tiny.count, 2)
        XCTAssertEqual(tinyLarge.count, 2)
    }

    // MARK: - Large/sliced code identity

    func testLargeCodeSliceIdentityIncludesChatSize() {
        let category = ContentSizeCategory.large
        let base = LargeCodeSliceIdentity.identity(source: "let x = 1", sizeCategory: category, chatTextSize: .default)

        XCTAssertEqual(base, LargeCodeSliceIdentity.identity(source: "let x = 1", sizeCategory: category, chatTextSize: .default),
                       "identical inputs must keep one identity")
        for size in ChatTextSize.allCases where size != .default {
            XCTAssertNotEqual(
                base,
                LargeCodeSliceIdentity.identity(source: "let x = 1", sizeCategory: category, chatTextSize: size),
                "a chat-size change must invalidate the slice's highlight pass"
            )
        }
        XCTAssertNotEqual(
            base,
            LargeCodeSliceIdentity.identity(source: "let y = 2", sizeCategory: category, chatTextSize: .default)
        )
        XCTAssertNotEqual(
            base,
            LargeCodeSliceIdentity.identity(source: "let x = 1", sizeCategory: .extraExtraLarge, chatTextSize: .default)
        )
    }

    // MARK: - Settled-row Equatable gates

    private func assistantMessage() -> ChatMessage {
        ChatMessage(
            id: "m1",
            role: .assistant,
            content: "Settled **assistant** body for the gate probe.",
            timestamp: "2026-01-01T00:00:00Z"
        )
    }

    private func userMessage() -> ChatMessage {
        ChatMessage(
            id: "m2",
            role: .user,
            content: "Settled user body for the gate probe.",
            timestamp: "2026-01-01T00:00:01Z"
        )
    }

    func testSettledAssistantGateReOpensOnChatSizeChange() {
        let message = assistantMessage()
        let baseline = SettledAssistantMessageContent(
            message: message, displayName: "Hermes", avatarURL: nil,
            gatewayResolver: nil, sizeCategory: .large, chatTextSize: .default
        )
        let sameInputs = SettledAssistantMessageContent(
            message: message, displayName: "Hermes", avatarURL: nil,
            gatewayResolver: nil, sizeCategory: .large, chatTextSize: .default
        )
        XCTAssertEqual(baseline, sameInputs,
                       "identical inputs (the ordinary streaming publish) must stay gated")

        let resized = SettledAssistantMessageContent(
            message: message, displayName: "Hermes", avatarURL: nil,
            gatewayResolver: nil, sizeCategory: .large, chatTextSize: .larger
        )
        XCTAssertNotEqual(baseline, resized,
                          "a chat text-size change must re-open the settled gate")
    }

    func testSettledUserGateReOpensOnChatSizeChange() {
        let message = userMessage()
        let baseline = UserMessageContent(
            message: message, gatewayResolver: nil,
            sizeCategory: .large, chatTextSize: .default
        )
        XCTAssertEqual(baseline, UserMessageContent(
            message: message, gatewayResolver: nil,
            sizeCategory: .large, chatTextSize: .default
        ))

        XCTAssertNotEqual(baseline, UserMessageContent(
            message: message, gatewayResolver: nil,
            sizeCategory: .large, chatTextSize: .smallest
        ))
    }

    func testSettledThinkingGateReOpensOnChatSizeChange() {
        let message = assistantMessage()
        let baseline = SettledThinkingCardContent(
            message: message, displayName: "Hermes", avatarURL: nil,
            sizeCategory: .large, chatTextSize: .default
        )
        XCTAssertEqual(baseline, SettledThinkingCardContent(
            message: message, displayName: "Hermes", avatarURL: nil,
            sizeCategory: .large, chatTextSize: .default
        ))
        XCTAssertNotEqual(baseline, SettledThinkingCardContent(
            message: message, displayName: "Hermes", avatarURL: nil,
            sizeCategory: .large, chatTextSize: .largest
        ))
    }

    // MARK: - Ordinary table view wiring (review-gate integration)

    /// Regression for the review-gate BLOCKER: the ordinary MarkdownTable
    /// must pass the selected chat size into MarkdownTableLayout, so columns
    /// are measured at the same size the cells render at. Mounting the view
    /// is the only way to observe that wiring — a direct columnWidths call
    /// with an explicit argument cannot catch a missed argument at the call
    /// site inside the view.
    @MainActor
    func testOrdinaryTableViewWiresChatSizeIntoColumnWidths() throws {
        func mountedTextViewWidths(chatTextSize: ChatTextSize) throws -> [CGFloat] {
            let table = MarkdownTable(
                headers: ["Column One", "Column Two"],
                alignments: [.leading, .leading],
                rows: [["measured content driver", "second driver value"]],
                foregroundStyle: .primary,
                usesAccentSurface: false,
                selectionCoordinator: nil,
                blockIndex: 0,
                selectionSegments: []
            )
            .environment(\.markdownReferences, .empty)
            .environment(\.chatTextSize, chatTextSize)

            let host = UIHostingController(rootView: table)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.isHidden = false
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            // The width probe settles a frame after the first layout pass.
            let settled = XCTestExpectation(description: "width probe settles")
            DispatchQueue.main.async { settled.fulfill() }
            wait(for: [settled], timeout: 2)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()

            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            let textViews = allTextViewsDeep(in: host.view).compactMap { $0 as? UITextView }
            XCTAssertFalse(textViews.isEmpty, "mounted table must contain text views")
            return textViews.map { $0.frame.width }.sorted()
        }

        let atDefault = try mountedTextViewWidths(chatTextSize: .default)
        let atLargest = try mountedTextViewWidths(chatTextSize: .largest)
        XCTAssertEqual(atDefault.count, atLargest.count)
        XCTAssertGreaterThan(
            atLargest.max() ?? 0, atDefault.max() ?? 0,
            "the ordinary table's mounted columns must grow with the chat size"
        )
    }

    private func allTextViewsDeep(in view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + allTextViewsDeep(in: $0) }
    }
}
