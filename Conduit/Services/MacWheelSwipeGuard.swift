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
/// under the pointer from taking scroll events; while the pointer rests in
/// the window, a check every quarter second catches a list that
/// opened under it (a click that pushes a page with a list). A trackpad no longer
/// swipes a row on a Mac, so every row's swipe actions are on its
/// right-click menu too (`macSwipeActionsMenu` where only a swipe had them).
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
    /// Where the pointer rests, looked at again while it doesn't move.
    private var lastLocation: CGPoint?
    private var restingCheck: Timer?
    static let restingCheckInterval: TimeInterval = 0.25

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
        guard state == .began || state == .changed, let window = view as? UIWindow else {
            // The pointer left the window: nothing to look at until it's back.
            restingCheck?.invalidate()
            restingCheck = nil
            lastLocation = nil
            return
        }
        lastLocation = location(in: window)
        checkUnderPointer()
        guard restingCheck == nil else { return }
        let timer = Timer(timeInterval: Self.restingCheckInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                self.checkUnderPointer()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        restingCheck = timer
    }

    /// Guards the lists under the pointer. Walked every time, not only when
    /// the view there changes: a list can gain its swipe recognizer under
    /// the same view as its rows load, and the walk is a short superview
    /// chain.
    private func checkUnderPointer() {
        guard let window = view as? UIWindow, let lastLocation else { return }
        Self.stopWheelSwipes(under: window.hitTest(lastLocation, with: nil))
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
    /// private class's name. Matched on "SwipeAction" rather than the whole
    /// name, so a renamed or subclassed one is still caught; any pan named
    /// so is a row swipe, which a wheel never needs. A UIScrollView's own
    /// pan is left alone.
    static func isSwipeActionPan(_ recognizer: UIPanGestureRecognizer) -> Bool {
        NSStringFromClass(type(of: recognizer)).contains("SwipeAction")
    }
}

extension View {
    /// A row whose actions are only in its swipe gets them on a right click
    /// on a Mac, where the wheel guard keeps a trackpad from swiping it.
    @ViewBuilder
    func macSwipeActionsMenu<Menu: View>(@ViewBuilder _ menu: () -> Menu) -> some View {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            contextMenu { menu() }
        } else {
            self
        }
    }
}
