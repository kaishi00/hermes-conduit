import SwiftUI
import UIKit

/// On a Mac, keeps a mouse wheel over a list from crashing Conduit (issue
/// #1480). A list with swipe actions carries UIKit's row swipe recognizer,
/// which asks a scroll event for its raw, unaccelerated delta; a notched
/// mouse wheel's events (no trackpad phases) don't carry one, and macOS
/// newer than 26.6 asserts on it ("Missing expected nonaccelerated scroll
/// delta") while it gathers the recognizers under the pointer, before any
/// of Conduit's code runs. Before a wheel turns over a list the pointer has
/// hovered there, so each hover stops the swipe recognizers of the lists
/// under the pointer from taking scroll events. Rows still swipe with a
/// click and drag, and their context menus stay.
struct MacWheelSwipeGuardProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard ProcessInfo.processInfo.isiOSAppOnMac, let window,
                  !(window.gestureRecognizers ?? []).contains(where: { $0 is MacWheelSwipeGuardRecognizer })
            else { return }
            window.addGestureRecognizer(MacWheelSwipeGuardRecognizer())
        }
    }
}

/// Follows the pointer over the window without taking part in anything
/// else: it hovers alongside every recognizer and never touches a click.
final class MacWheelSwipeGuardRecognizer: UIHoverGestureRecognizer, UIGestureRecognizerDelegate {
    /// The view last hovered, so a pointer resting on one row doesn't walk
    /// its ancestors again on every move.
    private weak var lastHovered: UIView?

    init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(hovered))
        cancelsTouchesInView = false
        delegate = self
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc private func hovered() {
        guard state == .began || state == .changed, let window = view as? UIWindow else { return }
        let hovered = window.hitTest(location(in: window), with: nil)
        guard hovered !== lastHovered else { return }
        lastHovered = hovered
        Self.stopWheelSwipes(under: hovered)
    }

    /// Every list from `view` up to its window stops taking scroll events
    /// in its row swipe recognizers, the ones UIKit hit-tests for a wheel
    /// turned there.
    static func stopWheelSwipes(under view: UIView?) {
        var current = view
        while let candidate = current {
            if candidate is UIScrollView {
                for recognizer in candidate.gestureRecognizers ?? [] {
                    guard let pan = recognizer as? UIPanGestureRecognizer, isSwipeActionPan(pan),
                          pan.allowedScrollTypesMask != [] else { continue }
                    pan.allowedScrollTypesMask = []
                }
            }
            current = candidate.superview
        }
    }

    /// UIKit's row swipe recognizer (`_UISwipeActionPanGestureRecognizer`,
    /// made for UITableView and list collection views), known only by its
    /// private class's name. A UIScrollView's own pan is left alone.
    static func isSwipeActionPan(_ recognizer: UIPanGestureRecognizer) -> Bool {
        NSStringFromClass(type(of: recognizer)).contains("SwipeAction")
    }
}
