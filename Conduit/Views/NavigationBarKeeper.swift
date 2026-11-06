//
//  NavigationBarKeeper.swift
//  Conduit
//
//  Brings a chat's navigation bar back when a swipe back that was let go
//  (the stack's edge swipe, or iOS 18's zoom dismissals: its leading-edge
//  pan, swipe down and pinch) left it hidden. Bots Home and the Sessions
//  list hide their bar; a Bot Chat or a room grown out of its portrait
//  that started to shrink home and was let go stayed with the list's
//  hidden bar, so its title, Back and ⋯ were gone until it was reopened
//  (Eric 2026-11-06: a group chat lost its top menus after some scrolling).
//

import SwiftUI
import UIKit

/// Put behind a pushed screen that always shows its navigation bar. Each
/// time one of its system back swipes ends, once its transition has
/// settled, a screen still on top of its stack with its bar hidden gets the
/// bar back. It never hides a bar, and leaves one a finished pop took away.
struct NavigationBarKeeper: UIViewRepresentable {
    func makeUIView(context: Context) -> KeeperView {
        KeeperView()
    }

    func updateUIView(_ view: KeeperView, context: Context) {}

    static func dismantleUIView(_ view: KeeperView, coordinator: ()) {
        view.stopWatching()
    }

    final class KeeperView: UIView {
        /// The swipes this view listens to, weakly: the zoom's go with the
        /// page, the stack's outlive it.
        private let watched = NSHashTable<UIGestureRecognizer>.weakObjects()
        private(set) weak var page: UIViewController?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stopWatching() } else { watch() }
        }

        private func watch(retriesLeft: Int = SystemBackSwipeGate.GateView.retries) {
            guard window != nil else { return }
            guard let page = SystemBackSwipeGate.pushedPage(of: self) else {
                // Shown with its push: the stack may not hold the page yet.
                if retriesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + SystemBackSwipeGate.GateView.retryDelay) { [weak self] in
                        self?.watch(retriesLeft: retriesLeft - 1)
                    }
                }
                return
            }
            self.page = page
            for recognizer in SystemBackSwipeGate.systemBackSwipes(of: page) where !watched.contains(recognizer) {
                watched.add(recognizer)
                recognizer.addTarget(self, action: #selector(swipeChanged(_:)))
            }
            // The zoom adds its dismissals as the push ends, and the page is
            // on top of the stack only then: look again.
            page.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                self?.watch(retriesLeft: 0)
            }
        }

        func stopWatching() {
            for recognizer in watched.allObjects {
                recognizer.removeTarget(self, action: #selector(swipeChanged(_:)))
            }
            watched.removeAllObjects()
        }

        @objc private func swipeChanged(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .ended, .cancelled, .failed:
                // The transition a swipe drives finishes or cancels after
                // the finger lifts: look once it has.
                DispatchQueue.main.async { [weak self] in self?.afterSwipe() }
            default:
                break
            }
        }

        private func afterSwipe() {
            guard let navigation = page?.navigationController else { return }
            if let coordinator = navigation.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    // SwiftUI sets the bar as the transition ends too.
                    DispatchQueue.main.async { self?.restoreBar() }
                }
            } else {
                restoreBar()
            }
        }

        /// The page still on top of its stack with its bar hidden: the bar
        /// comes back.
        func restoreBar() {
            guard let page, let navigation = page.navigationController,
                  navigation.topViewController === page, navigation.isNavigationBarHidden else { return }
            ChatViewportTrace.shared.log("navigation bar hidden after a back swipe, shown again")
            navigation.setNavigationBarHidden(false, animated: false)
        }
    }
}
