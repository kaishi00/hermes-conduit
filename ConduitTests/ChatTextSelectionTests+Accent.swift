import XCTest
import UIKit
import SwiftUI
@testable import Conduit

/// Issue #697: a readable selection on sent bubbles, their copy button, and
/// the accent colour choice.
extension ChatTextSelectionTests {
    func testAccentResolvesTheChosenPreset() {
        for choice in ConduitAccentChoice.allCases {
            for dark in [false, true] {
                let traits = UITraitCollection(mutations: { traits in
                    traits.conduitAccent = choice
                    traits.userInterfaceStyle = dark ? .dark : .light
                })
                XCTAssertTrue(
                    Self.isClose(UIColor.conduitAccent.resolvedColor(with: traits), choice.color(dark: dark)),
                    "\(choice) dark=\(dark)"
                )
            }
        }
        // No choice made: the original amber.
        let unset = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertTrue(Self.isClose(
            UIColor.conduitAccent.resolvedColor(with: unset),
            UIColor(red: 0.88, green: 0.67, blue: 0.28, alpha: 1)
        ))
    }

    func testSelectionOnASentBubbleStandsOutFromIt() {
        for choice in ConduitAccentChoice.allCases {
            for dark in [false, true] {
                let bubble = choice.color(dark: dark).conduitRelativeLuminance
                let selection = choice.selectionColorOnBubble(dark: dark).conduitRelativeLuminance
                XCTAssertGreaterThan(
                    (max(bubble, selection) + 0.05) / (min(bubble, selection) + 0.05),
                    3.0,
                    "\(choice) dark=\(dark)"
                )
            }
        }
    }

    @MainActor
    func testSentBubbleTextSelectsInTheContrastingTint() throws {
        let host = UIHostingController(rootView:
            MarkdownText(source: "Something I wrote", foregroundStyle: .white, usesAccentSurface: true)
                .environment(\.conduitAccent, .amber)
                .preferredColorScheme(.dark)
        )
        let window = Self.window(hosting: host)
        defer { Self.close(window) }

        let textView = try XCTUnwrap(Self.subviews(of: UITextView.self, in: host.view).first)
        let tint = textView.tintColor.resolvedColor(with: textView.traitCollection)
        XCTAssertTrue(Self.isClose(tint, .black), "dark-mode amber bubble selects in black, got \(tint)")
    }

    @MainActor
    func testReplyTextKeepsTheInheritedSelectionTint() throws {
        let host = UIHostingController(rootView:
            MarkdownText(source: "Something Hermes wrote")
                .tint(Color(uiColor: .systemRed))
        )
        let window = Self.window(hosting: host)
        defer { Self.close(window) }

        let textView = try XCTUnwrap(Self.subviews(of: UITextView.self, in: host.view).first)
        XCTAssertFalse(Self.isClose(textView.tintColor.resolvedColor(with: textView.traitCollection), .black))
        XCTAssertFalse(Self.isClose(textView.tintColor.resolvedColor(with: textView.traitCollection), .white))
    }

    @MainActor
    func testAPickRedrawsTheAccentInPlace() throws {
        let model = AccentProbeModel()
        let host = UIHostingController(rootView: AccentProbeView(model: model))
        let window = Self.window(hosting: host)
        defer { Self.close(window) }

        XCTAssertTrue(Self.isClose(try Self.centerColor(of: host.view), ConduitAccentChoice.amber.color(dark: true), tolerance: 0.05))
        let swatch = try XCTUnwrap(Self.subviews(of: AccentProbeUIView.self, in: host.view).first)
        XCTAssertEqual(swatch.traitCollection.conduitAccent, .amber)

        model.choice = .blue
        Self.settle(host)

        XCTAssertTrue(
            Self.isClose(try Self.centerColor(of: host.view), ConduitAccentChoice.blue.color(dark: true), tolerance: 0.05),
            "SwiftUI fills redraw in the new accent"
        )
        XCTAssertEqual(swatch.traitCollection.conduitAccent, .blue, "UIKit views see the new accent too")
    }

    @MainActor
    func testAPickRetintsAMountedSentBubbleSelection() throws {
        let model = AccentProbeModel()
        model.choice = .pink
        let host = UIHostingController(rootView: SentBubbleProbeView(model: model))
        let window = Self.window(hosting: host)
        defer { Self.close(window) }

        let textView = try XCTUnwrap(Self.subviews(of: UITextView.self, in: host.view).first)
        XCTAssertTrue(Self.isClose(textView.tintColor.resolvedColor(with: textView.traitCollection), .black))

        // Dark-mode purple is a dark bubble: the selection turns white.
        model.choice = .purple
        Self.settle(host)
        XCTAssertEqual(textView.traitCollection.conduitAccent, .purple)
        XCTAssertTrue(Self.isClose(textView.tintColor.resolvedColor(with: textView.traitCollection), .white))
    }

    func testCopyingASentMessageLeavesOutTheQuotedReply() {
        let plain = ChatMessage(id: "u1", role: .user, content: "Just me", timestamp: "1")
        XCTAssertEqual(UserMessageCopyButton.copyText(for: plain), "Just me")

        let quoted = ChatMessage(
            id: "u2",
            role: .user,
            content: ReplyQuoteEnvelope.outboundText(quoting: "Hermes said this", message: "And I said this"),
            timestamp: "1"
        )
        XCTAssertEqual(UserMessageCopyButton.copyText(for: quoted), "And I said this")
    }

    // MARK: Helpers

    private static func isClose(_ lhs: UIColor, _ rhs: UIColor, tolerance: CGFloat = 0.03) -> Bool {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard lhs.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              rhs.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        else { return false }
        return abs(r1 - r2) <= tolerance && abs(g1 - g2) <= tolerance && abs(b1 - b2) <= tolerance
    }

    @MainActor
    private static func window(hosting host: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 300))
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.isHidden = false
        settle(host)
        return window
    }

    @MainActor
    private static func settle(_ host: UIViewController) {
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    private static func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }

    @MainActor
    private static func subviews<Match: UIView>(of type: Match.Type, in view: UIView) -> [Match] {
        if let match = view as? Match { return [match] }
        return view.subviews.flatMap { subviews(of: type, in: $0) }
    }

    /// The colour drawn at the middle of the left half (the SwiftUI fill).
    @MainActor
    private static func centerColor(of view: UIView) throws -> UIColor {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        // The context owns its one-pixel buffer.
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let point = CGPoint(x: view.bounds.width / 4, y: view.bounds.height / 2)
        context.draw(cgImage, in: CGRect(
            x: -point.x,
            y: -(CGFloat(cgImage.height) - point.y),
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        ))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }
}

@MainActor
private final class AccentProbeModel: ObservableObject {
    @Published var choice = ConduitAccentChoice.amber
}

/// A SwiftUI fill on the left, a UIKit view on the right, both in the
/// accent, under the environment value the app root sets.
private struct AccentProbeView: View {
    @ObservedObject var model: AccentProbeModel

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.conduitAccent)
            AccentProbeRepresentable()
        }
        .environment(\.conduitAccent, model.choice)
    }
}

private struct SentBubbleProbeView: View {
    @ObservedObject var model: AccentProbeModel

    var body: some View {
        MarkdownText(source: "Something I wrote", foregroundStyle: .white, usesAccentSurface: true)
            .environment(\.conduitAccent, model.choice)
    }
}

private struct AccentProbeRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AccentProbeUIView {
        let view = AccentProbeUIView()
        view.backgroundColor = .conduitAccent
        return view
    }

    func updateUIView(_ uiView: AccentProbeUIView, context: Context) {}
}

private final class AccentProbeUIView: UIView {}
