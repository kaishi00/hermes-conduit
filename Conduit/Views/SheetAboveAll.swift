//
//  SheetAboveAll.swift
//  Conduit
//
//  A root sheet that also shows while another sheet is up.
//

import SwiftUI
import UIKit

extension View {
    /// A sheet the app opens from outside (a Link invite, a room invite or
    /// approval whose notification was tapped, a sign-in code link), shown
    /// even while another sheet is already up. A root view's own `.sheet`
    /// can't present then, so the item would wait unseen until that sheet
    /// closed. With nothing else up it's SwiftUI's own sheet; with a sheet up
    /// it goes over the topmost one, which stays underneath.
    func sheetAboveAll<Item: Identifiable, Sheet: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Sheet
    ) -> some View {
        modifier(SheetAboveAll(item: item, sheet: content))
    }
}

private struct SheetAboveAll<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let sheet: (Item) -> Sheet
    @State private var host = SheetAboveAllHost()

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: {
                    guard let item else { return nil }
                    return host.route(for: AnyHashable(item.id)) == .root ? item : nil
                },
                set: { item = $0 }
            )) { shown in
                sheet(shown)
            }
            .onChange(of: item.map { AnyHashable($0.id) }, initial: true) { _, id in
                follow(id)
            }
    }

    private func follow(_ id: AnyHashable?) {
        guard let id, let item else {
            host.close()
            return
        }
        guard host.route(for: id) == .overTop, host.shownID != id else { return }
        let binding = $item
        host.show(id: id, kind: String(describing: Item.self), view: sheet(item)) {
            // Closed over there (swiped down, or the sheet dismissed itself):
            // the item is done with, unless a newer one took its place.
            if binding.wrappedValue.map({ AnyHashable($0.id) }) == id {
                binding.wrappedValue = nil
            }
        }
    }
}

/// Where each item shows, decided once when it arrives, and the controller
/// that holds one shown over another sheet. Not observed: the route is read
/// while the view renders, and deciding it there publishes nothing.
@MainActor
final class SheetAboveAllHost {
    enum Route { case root, overTop }

    private var decided: (id: AnyHashable, route: Route)?
    private weak var controller: UIViewController?
    private(set) var shownID: AnyHashable?

    /// The route for `id`: over the top when another sheet was up as it
    /// arrived. Kept while it shows, so the root sheet it becomes doesn't
    /// count as another sheet up.
    func route(for id: AnyHashable) -> Route {
        if let decided, decided.id == id { return decided.route }
        // The root sheet still showing the last item takes this one in its
        // place (SwiftUI swaps them): presented over it, the new one would
        // go down with it as the binding stops returning the old item.
        let route: Route = decided?.route == .root
            ? .root
            : (Self.topPresenter()?.presentingViewController != nil ? .overTop : .root)
        if shownID != nil, shownID != id { close() }
        decided = (id, route)
        return route
    }

    func show<Sheet: View>(id: AnyHashable, kind: String, view: Sheet, closed: @escaping @MainActor () -> Void) {
        // Each window's root has this modifier: the first to show an item
        // shows it, once.
        let key = "\(kind)|\(id)"
        guard !Self.showing.contains(key), let presenter = Self.topPresenter() else { return }
        let hosting = UIHostingController(rootView: view.onDisappear {
            // Runs however it closed: by a swipe, its own dismiss, or close().
            Task { @MainActor in
                Self.showing.remove(key)
                closed()
            }
        })
        Self.showing.insert(key)
        controller = hosting
        shownID = id
        func present(retrying: Bool) {
            // The top again: what was going may have gone, or another sheet come.
            guard self.controller === hosting, let top = Self.topPresenter() else {
                Self.showing.remove(key)
                return
            }
            top.present(hosting, animated: true)
            // UIKit refuses a presentation it can't make now (no callback,
            // no onDisappear): try once more from the top, then forget it.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard hosting.presentingViewController == nil, !hosting.isBeingPresented else { return }
                guard let self, self.controller === hosting else {
                    Self.showing.remove(key)
                    return
                }
                if retrying { return present(retrying: false) }
                Self.showing.remove(key)
                self.controller = nil
                self.shownID = nil
                closed()
            }
        }
        // One this replaced is still animating away (close()): present once it's gone.
        if let going = presenter.presentedViewController, going.isBeingDismissed,
           let coordinator = going.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in Task { @MainActor in present(retrying: true) } }
        } else {
            present(retrying: true)
        }
    }

    private static var showing: Set<String> = []

    /// Takes down the one shown over the top, if any, and forgets the route.
    func close() {
        decided = nil
        shownID = nil
        // Dismissing it would take down whatever came up over it too (a room
        // approval over an invite), so with something above it stays: the
        // person closes it themselves, and its item is no longer the binding's.
        if let controller, controller.presentingViewController != nil, !controller.isBeingDismissed,
           controller.presentedViewController == nil {
            controller.dismiss(animated: true)
        }
        controller = nil
    }

    /// The topmost presented controller of the active window, or its root
    /// when nothing is presented.
    static func topPresenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
