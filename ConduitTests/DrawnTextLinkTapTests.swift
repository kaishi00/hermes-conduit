import UIKit
import XCTest
@testable import Conduit

/// A link in a chat answer opens on the tap that mounts its text view. The
/// chat draws answers until a touch mounts the text view (hitTest); a text
/// view mounted but not yet laid out had no text layout under the finger,
/// so that first tap found no link and links opened only on a second tap.
final class DrawnTextLinkTapTests: XCTestCase {
    @MainActor
    func testTheTouchThatMountsTheTextViewFindsTheLink() throws {
        let text = NSMutableAttributedString(string: "Sources: quebec.ca — Fever in children")
        text.addAttribute(.link, value: try XCTUnwrap(URL(string: "https://www.quebec.ca/en/health/fever")),
                          range: (text.string as NSString).range(of: "quebec.ca — Fever in children"))
        let view = SelectableTextView(
            attributedText: text,
            font: ChatTypography.font(for: .body, chatSize: .default)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let host = view.makeUIViewForTests(coordinator: view.makeCoordinator(), drawsUntilTouched: true)
        host.frame = CGRect(x: 16, y: 100, width: 358, height: 80)
        root.view.addSubview(host)
        root.view.layoutIfNeeded()
        XCTAssertNil(host.textView, "drawn until touched")

        let textView = host.mountTextViewForTouch()

        XCTAssertFalse(textView.layer.needsLayout(), "the touch is routed to a laid-out text view")
        XCTAssertEqual(textView.frame, host.bounds)
        let linkRange = (textView.text as NSString).range(of: "quebec.ca")
        XCTAssertNotEqual(linkRange.location, NSNotFound)
        let linkStart = linkRange.location
        let start = try XCTUnwrap(textView.position(from: textView.beginningOfDocument, offset: linkStart + 2))
        let caret = textView.caretRect(for: start)
        let tapped = try XCTUnwrap(textView.closestPosition(to: CGPoint(x: caret.midX, y: caret.midY)))
        let offset = textView.offset(from: textView.beginningOfDocument, to: tapped)
        XCTAssertNotNil(textView.attributedText.attribute(.link, at: offset, effectiveRange: nil),
                        "the point under the finger is the link")
    }
}
