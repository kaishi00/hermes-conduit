//
//  V2ListNavigationBar.swift
//  Conduit
//
//  The Sessions list draws its own top bar (V2TopBar) and used to hide the
//  navigation bar. A chat pushed from it then brought the bar in with its
//  page, and UIKit keeps a bar that travels attached to the page from the
//  main thread: each time the main thread was busy during the slide (the
//  chat's resume landing, 100 ms and more), the chat's Back, title and ⋯
//  stopped short of their place and jumped there afterwards (an iPhone 16
//  Pro Max, iOS 27.3, 2026-11-15: 5 to 13 pt short for 100 to 135 ms on a
//  regular session, up to 87 pt behind the page in a probe). From a project
//  page, whose bar is already on screen, the bar never moves.
//
//  So the list keeps the bar on screen too: empty, clear, taking no room
//  and no touches.
//

import SwiftUI
import UIKit

extension View {
    /// The list's navigation bar: shown, with nothing in it and nothing
    /// behind it, so a chat pushed over the list finds the bar in place.
    /// Hidden as before on a Mac (`V2ListNavigationBarPolicy`).
    @ViewBuilder
    func v2ListNavigationBar() -> some View {
        if V2ListNavigationBarPolicy.keepsBarShown() {
            shownEmptyListNavigationBar()
        } else {
            toolbar(.hidden, for: .navigationBar)
        }
    }

    private func shownEmptyListNavigationBar() -> some View {
        toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            // The title stays for the pushed screen's Back; this keeps it
            // from being drawn in the bar.
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .background { V2ListNavigationBar() }
    }
}

/// Whether the Sessions list keeps its navigation bar shown. Not when the
/// iPad app runs on a Mac (`isiOSAppOnMac`): there, from the build that
/// first showed it, the profile strip at the top of the sidebar went blank
/// with its row kept, the filter row under it still drawn (issue 2671). The
/// header jump the shown bar fixes was measured on an iPhone, mid-push; a
/// Mac opens chats beside the list and pushes one only in a narrow window,
/// so it keeps the hidden bar it had before #2580.
enum V2ListNavigationBarPolicy {
    static func keepsBarShown(onMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac) -> Bool {
        !onMac
    }
}

/// Behind the list: takes the shown bar's height back out of the list's
/// safe area, so the list lies where it did under a hidden bar, and lets
/// touches through the bar to the list's own top bar while the list is the
/// top of its stack.
struct V2ListNavigationBar: UIViewRepresentable {
    func makeUIView(context: Context) -> KeeperView {
        KeeperView()
    }

    func updateUIView(_ view: KeeperView, context: Context) {
        view.sync()
    }

    static func dismantleUIView(_ view: KeeperView, coordinator: ()) {
        view.release()
    }

    final class KeeperView: UIView {
        private weak var page: UIViewController?
        private weak var navigation: UINavigationController?
        private var barObservation: NSKeyValueObservation?
        /// A lookup is waiting to try again.
        private var retryPending = false
        /// The give-up trace went out for this stay; a later attach that
        /// finds the stack clears it.
        private var reportedNoStack = false
        /// How many times a lookup tries again, and how it finds the page:
        /// tests change them.
        var retries = SystemBackSwipeGate.GateView.retries
        var findPage: (UIView) -> UIViewController? = { SystemBackSwipeGate.pushedPage(of: $0) }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                // Covered by a pushed page, or gone: the bar is that
                // page's again.
                handBack()
            } else {
                attach(retriesLeft: retries)
            }
        }

        private func attach(retriesLeft: Int) {
            guard window != nil else { return }
            guard let page = findPage(self), let navigation = page.navigationController else {
                // Shown with its stack: the stack may not hold the page yet.
                if retriesLeft > 0 {
                    retryPending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + SystemBackSwipeGate.GateView.retryDelay) { [weak self] in
                        self?.retryPending = false
                        self?.attach(retriesLeft: retriesLeft - 1)
                    }
                } else if !reportedNoStack {
                    // Not for good: each later update of the list looks
                    // again (sync), so a stack wired after the retries ran
                    // out still gets the bar managed (issue 2592).
                    reportedNoStack = true
                    ChatViewportTrace.shared.log("list bar keeper found no page in a stack after \(retries) retries: its bar stays shown over the list until a later update finds it")
                }
                return
            }
            if reportedNoStack {
                reportedNoStack = false
                ChatViewportTrace.shared.log("list bar keeper found its stack on a later update")
            }
            if self.page !== page {
                self.page = page
                self.navigation = navigation
                // The bar's height changes with the window (a turned
                // phone, a resized iPad window).
                barObservation = navigation.navigationBar.observe(\.bounds) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.sync() }
                }
            }
            sync()
            // Back in view under a pop: the list is on top only once the
            // pop has finished, and not at all if the swipe is let go.
            navigation.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                self?.sync()
            }
        }

        /// The list's safe area without the bar, and the bar's touches.
        func sync() {
            guard window != nil else { return }
            guard let page, let navigation else {
                // The lookup ran out before the stack held the page: look
                // once more on this update, with no retries of its own.
                if !retryPending { attach(retriesLeft: 0) }
                return
            }
            let bar = navigation.navigationBar
            let height = navigation.isNavigationBarHidden ? 0 : bar.bounds.height
            if page.additionalSafeAreaInsets.top != -height {
                page.additionalSafeAreaInsets.top = -height
            }
            let onTop = navigation.topViewController === page
            if bar.isUserInteractionEnabled == onTop {
                bar.isUserInteractionEnabled = !onTop
            }
            // Empty as it is, the bar still carries the title for the
            // pushed screen's Back: VoiceOver doesn't stop on it here.
            if bar.accessibilityElementsHidden != onTop {
                bar.accessibilityElementsHidden = onTop
            }
        }

        /// The bar as any other screen has it.
        private func handBack() {
            // The next stay traces its own give-up (#2628's review).
            reportedNoStack = false
            guard let bar = navigation?.navigationBar else { return }
            bar.isUserInteractionEnabled = true
            bar.accessibilityElementsHidden = false
        }

        func release() {
            barObservation = nil
            page?.additionalSafeAreaInsets.top = 0
            handBack()
        }
    }
}
