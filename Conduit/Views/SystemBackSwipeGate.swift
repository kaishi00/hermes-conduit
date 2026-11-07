//
//  SystemBackSwipeGate.swift
//  Conduit
//
//  Holds back UIKit's own ways off a pushed screen (the navigation stack's
//  edge and content swipes, and iOS 18's zoom dismissals: its leading-edge
//  pan, swipe down and pinch) while the screen goes back somewhere else
//  itself. A workstream's chat shows in its Bot Chat's pushed screen, often
//  grown out of its portrait on Bots Home: the zoom's swipes ignore a
//  hidden Back button, so a slow swipe popped the whole screen to Bots
//  Home while a quick flick went to the Bot Chat (Eric 2026-11-06).
//

import SwiftUI
import UIKit

/// Put behind a pushed screen's content. While `blocked`, the screen's
/// system back swipes are off; they come back as it clears or the screen
/// goes. SwiftUI has no switch for the zoom's (`.interactiveDismissDisabled`
/// doesn't reach it, FB22226720), so the gate finds them by the names UIKit
/// gives them; a release that renames them leaves its swipes on, as before.
struct SystemBackSwipeGate: UIViewRepresentable {
    let blocked: Bool

    func makeUIView(context: Context) -> GateView {
        GateView()
    }

    func updateUIView(_ view: GateView, context: Context) {
        view.blocked = blocked
    }

    static func dismantleUIView(_ view: GateView, coordinator: ()) {
        view.blocked = false
    }

    /// The prefix of the zoom transition's dismissal gestures' names
    /// (`com.apple.UIKit.ZoomInteractiveDismissLeadingEdgePan`, `…SwipeDown`,
    /// `…Pinch`, iOS 26.5 and 27.2).
    static let zoomDismissalPrefix = "com.apple.UIKit.ZoomInteractiveDismiss"

    static func isZoomDismissal(_ name: String?) -> Bool {
        name?.hasPrefix(zoomDismissalPrefix) ?? false
    }

    /// The controller a view's screen was pushed as: the one whose parent
    /// is the navigation stack.
    static func pushedPage(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let controller = next as? UIViewController, controller.parent is UINavigationController {
                return controller
            }
            responder = next
        }
        return nil
    }

    /// The page's system back swipes: the zoom's dismissals on its view and,
    /// while it's on top, the stack's edge and content swipes.
    static func systemBackSwipes(of page: UIViewController) -> [UIGestureRecognizer] {
        var found = (page.view.gestureRecognizers ?? []).filter { isZoomDismissal($0.name) }
        if let navigation = page.navigationController, navigation.topViewController === page {
            if let edge = navigation.interactivePopGestureRecognizer { found.append(edge) }
            if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer {
                found.append(content)
            }
        }
        return found
    }

    final class GateView: UIView {
        var blocked = false {
            didSet { if blocked != oldValue || blocked { apply() } }
        }
        /// What the gate turned off, and only that, so it never turns on a
        /// gesture UIKit itself had off.
        private let heldOff = NSHashTable<UIGestureRecognizer>.weakObjects()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { release() } else { apply() }
        }

        /// How many times, `retryDelay` apart, the gate looks again for a
        /// page the stack doesn't hold yet: about 2 s, past any push.
        static let retries = 40
        static let retryDelay: TimeInterval = 0.05

        private func apply(retriesLeft: Int = GateView.retries) {
            guard blocked else { return release() }
            guard window != nil else { return }
            guard let page = SystemBackSwipeGate.pushedPage(of: self) else {
                // Opened with its push (a workstream straight from the
                // bot's overview): the stack may not hold the page yet.
                if retriesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                        self?.apply(retriesLeft: retriesLeft - 1)
                    }
                }
                return
            }
            holdOff(SystemBackSwipeGate.systemBackSwipes(of: page))
            // The push may still be running, and the zoom's gestures and the
            // stack's top settle as it ends: look again then.
            page.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                self?.apply(retriesLeft: 0)
            }
        }

        private func holdOff(_ recognizers: [UIGestureRecognizer]) {
            for recognizer in recognizers where recognizer.isEnabled {
                recognizer.isEnabled = false
                heldOff.add(recognizer)
            }
        }

        private func release() {
            for recognizer in heldOff.allObjects { recognizer.isEnabled = true }
            heldOff.removeAllObjects()
        }
    }
}
