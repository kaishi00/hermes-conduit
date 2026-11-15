//
//  SidewaysScrollTouch.swift
//  Conduit
//
//  Whether the finger now on the screen landed on something that scrolls
//  sideways and can still scroll back: a card carousel, a wide table or
//  code block, a row of chips. A Bot Chat's swipe home from anywhere (and
//  a workstream's to its Bot Chat) is the app's own drag over the whole
//  chat, so it fired as such a scroller was dragged back toward its start
//  and the chat closed under the finger (Eric 2026-11-15). iOS's own swipe
//  from anywhere lets the scroller have it; this lets the app's do the same.
//

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

@MainActor
enum SidewaysScrollTouch {
    /// A swipe that starts this close to the screen's leading edge is the
    /// edge swipe back, over a scroller or not, as iOS's own is.
    static let edgeWidth: CGFloat = 24

    /// Whether the touch that began last landed on a scroller that could
    /// scroll back, away from the leading edge. Set as each first finger
    /// lands, so it holds for that touch until the next one.
    private(set) static var lastTouchCouldScrollBack = false

    /// A first finger landing at `point` in `window`.
    static func touchBegan(at point: CGPoint, in window: UIWindow) {
        lastTouchCouldScrollBack = holdsBackSwipe(
            under: window.hitTest(point, with: nil),
            at: point,
            in: window
        )
    }

    /// Whether a swipe back starting on `hit`, at `point` in `window`,
    /// belongs to a scroller under it instead.
    static func holdsBackSwipe(under hit: UIView?, at point: CGPoint, in window: UIWindow) -> Bool {
        let rightToLeft = window.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let fromLeadingEdge = rightToLeft ? window.bounds.maxX - point.x : point.x - window.bounds.minX
        guard fromLeadingEdge > edgeWidth else { return false }
        var view = hit
        while let current = view {
            // Each scroller by its own direction: a left-to-right code
            // block in a right-to-left chat starts at its left end.
            if let scrollView = current as? UIScrollView,
               canScrollBack(scrollView, rightToLeft: scrollView.effectiveUserInterfaceLayoutDirection == .rightToLeft) {
                return true
            }
            // Only scrollers on the pushed page itself: a pager the stack
            // sits in isn't the touch's to scroll.
            if let controller = current.next as? UIViewController, controller.parent is UINavigationController {
                return false
            }
            view = current.superview
        }
        return false
    }

    /// Whether a sideways scroller has scrolled away from its leading end,
    /// so a swipe toward the trailing edge would scroll it back.
    static func canScrollBack(_ scrollView: UIScrollView, rightToLeft: Bool = false) -> Bool {
        guard scrollView.isScrollEnabled, scrollView.panGestureRecognizer.isEnabled else { return false }
        let inset = scrollView.adjustedContentInset
        let scrollable = scrollView.contentSize.width + inset.left + inset.right - scrollView.bounds.width
        guard scrollable > 0.5 else { return false }
        let minX = -inset.left
        let maxX = minX + scrollable
        // SwiftUI flips a right-to-left scroller by a transform, so its
        // offset still runs from the left: there its leading end is the
        // right one.
        let flipped = rightToLeft && scrollView.transform.a >= 0
        return flipped ? scrollView.contentOffset.x < maxX - 0.5 : scrollView.contentOffset.x > minX + 0.5
    }
}

/// Puts `SidewaysScrollTouchRecognizer` on the window it lands in. Draws
/// nothing and takes no touches.
struct SidewaysScrollTouchProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window,
                  !(window.gestureRecognizers ?? []).contains(where: { $0 is SidewaysScrollTouchRecognizer })
            else { return }
            window.addGestureRecognizer(SidewaysScrollTouchRecognizer())
        }
    }
}

/// Notes where each first finger lands, the way
/// `InteractionIdleTouchRecognizer` watches touches: it never recognizes,
/// delays or cancels a touch, never makes another gesture wait, and fails
/// once the last finger lifts (issue 1687).
final class SidewaysScrollTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // Only the first finger: a second one landing mid-swipe doesn't
        // change what the swipe started on.
        guard let window = view as? UIWindow ?? view?.window,
              let touch = touches.first,
              Self.isFirstFinger(touches, among: event.touches(for: self) ?? [])
        else { return }
        SidewaysScrollTouch.touchBegan(at: touch.location(in: window), in: window)
    }

    /// Whether `began` are the only fingers down: none of the watcher's
    /// other touches is still on the screen.
    static func isFirstFinger(_ began: Set<UITouch>, among touches: Set<UITouch>) -> Bool {
        !fingerStillDown(besides: [], among: touches.subtracting(began))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        failIfLastTouch(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        failIfLastTouch(touches, event: event)
    }

    private func failIfLastTouch(_ touches: Set<UITouch>, event: UIEvent) {
        guard !Self.fingerStillDown(besides: touches, among: event.touches(for: self) ?? []) else { return }
        state = .failed
    }
}
