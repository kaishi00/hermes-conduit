//
//  TranscriptTouchTrace.swift
//  Conduit
//
//  The recorder's lines for fingers on a chat's transcript (issue 1687: a
//  swipe at the screen's left edge left the whole chat unable to scroll
//  until it was reopened, with nothing in the trace to say why).
//

import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Where each finger on a transcript landed and which gestures took it,
/// and the system's swipe back on the transcript's navigation stack, in the
/// chat recorder (ChatViewportTrace). A line names a place on the screen,
/// UIKit class names and gesture states, never what's drawn there.
///
/// The probe on the window watches touches the way
/// InteractionIdleTouchRecognizer does: it never recognizes, delays or
/// cancels a touch, and never makes another gesture wait.
@MainActor
enum TranscriptTouchTrace {
    private static let surfaces = NSHashTable<UICollectionView>.weakObjects()
    /// Touches whose start was logged: their end is too.
    private static var logged: Set<ObjectIdentifier> = []
    /// Weak, so a later stack's recognizer at a recycled address is still watched.
    private static let watchedBackSwipes = NSHashTable<UIGestureRecognizer>.weakObjects()
    private static let backSwipeTarget = BackSwipeTarget()

    /// A transcript on screen: touches on it are logged.
    static func watch(_ collectionView: UICollectionView, navigationController: UINavigationController?) {
        surfaces.add(collectionView)
        if let window = collectionView.window,
           !(window.gestureRecognizers ?? []).contains(where: { $0 is TranscriptTouchProbe }) {
            window.addGestureRecognizer(TranscriptTouchProbe())
        }
        guard let navigationController else { return }
        watchBackSwipe(navigationController.interactivePopGestureRecognizer, kind: .edge)
        if #available(iOS 26.0, *) {
            watchBackSwipe(navigationController.interactiveContentPopGestureRecognizer, kind: .content)
        }
    }

    static func unwatch(_ collectionView: UICollectionView) {
        surfaces.remove(collectionView)
    }

    private static func watchBackSwipe(_ recognizer: UIGestureRecognizer?, kind: BackSwipeTarget.Kind) {
        guard let recognizer, !watchedBackSwipes.contains(recognizer) else { return }
        watchedBackSwipes.add(recognizer)
        recognizer.addTarget(backSwipeTarget, action: kind == .edge ? #selector(BackSwipeTarget.edge(_:)) : #selector(BackSwipeTarget.content(_:)))
    }

    fileprivate static func touchBegan(_ touch: UITouch, in window: UIWindow) {
        guard let surface = surfaces.allObjects.first(where: {
            $0.window === window && $0.bounds.contains(touch.location(in: $0))
        }) else { return }
        logged.insert(ObjectIdentifier(touch))
        let point = touch.location(in: window)
        let hit = window.hitTest(point, with: nil)
        ChatViewportTrace.shared.log(beganLine(
            x: point.x,
            y: point.y,
            hit: hit.map(name) ?? "nothing",
            inTranscript: hit?.isDescendant(of: surface) ?? false,
            scrolls: surface.isScrollEnabled && surface.panGestureRecognizer.isEnabled,
            blockedBy: blocker(of: surface).map(name),
            active: activeRecognizers(touch)
        ))
    }

    fileprivate static func touchFinished(_ touch: UITouch, cancelled: Bool) {
        guard logged.remove(ObjectIdentifier(touch)) != nil else { return }
        ChatViewportTrace.shared.log(endedLine(cancelled: cancelled, took: activeRecognizers(touch)))
    }

    /// The gestures that took the touch, or have it now.
    private static func activeRecognizers(_ touch: UITouch) -> [(String, UIGestureRecognizer.State)] {
        (touch.gestureRecognizers ?? []).compactMap { recognizer in
            guard !(recognizer is TranscriptTouchProbe), !(recognizer is InteractionIdleTouchRecognizer),
                  recognizer.state != .possible, recognizer.state != .failed else { return nil }
            return (name(recognizer), recognizer.state)
        }
    }

    /// The transcript itself, or a view it's in, that takes no touches.
    private static func blocker(of surface: UIView) -> UIView? {
        var view: UIView? = surface
        while let current = view {
            if !current.isUserInteractionEnabled || current.isHidden || current.alpha < 0.01 { return current }
            view = current.superview
        }
        return nil
    }

    /// A class's name up to its generic arguments, which can run long.
    static func name(_ object: AnyObject) -> String {
        String(String(describing: type(of: object)).prefix { $0 != "<" }.prefix(48))
    }

    static func stateName(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: "possible"
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        @unknown default: "state\(state.rawValue)"
        }
    }

    static func beganLine(
        x: CGFloat,
        y: CGFloat,
        hit: String,
        inTranscript: Bool,
        scrolls: Bool,
        blockedBy: String?,
        active: [(String, UIGestureRecognizer.State)]
    ) -> String {
        var line = String(format: "touch at %.0f,%.0f hit %@%@", x, y, hit, inTranscript ? "" : " over transcript")
        if !scrolls { line += " scroll off" }
        if let blockedBy { line += " blocked by \(blockedBy)" }
        if !active.isEmpty { line += " busy " + recognizers(active) }
        return line
    }

    static func endedLine(cancelled: Bool, took: [(String, UIGestureRecognizer.State)]) -> String {
        let end = cancelled ? "touch cancelled" : "touch ended"
        return took.isEmpty ? "\(end), nothing took it" : "\(end), took " + recognizers(took)
    }

    /// The transcript's own drag, as it starts and as it ends.
    static func dragLine(_ state: UIGestureRecognizer.State, offset: CGFloat) -> String {
        String(format: "drag %@ offset %.1f", stateName(state), offset)
    }

    static func backSwipeLine(content: Bool, state: UIGestureRecognizer.State, x: CGFloat) -> String {
        String(format: "back swipe %@ %@ at x %.0f", content ? "content" : "edge", stateName(state), x)
    }

    private static func recognizers(_ list: [(String, UIGestureRecognizer.State)]) -> String {
        list.map { "\($0.0):\(stateName($0.1))" }.joined(separator: ",")
    }
}

/// The system's swipe back on the transcript's navigation stack: logged as
/// it starts and ends, not each move.
@MainActor
private final class BackSwipeTarget: NSObject {
    enum Kind { case edge, content }

    @objc func edge(_ recognizer: UIGestureRecognizer) { log(recognizer, content: false) }
    @objc func content(_ recognizer: UIGestureRecognizer) { log(recognizer, content: true) }

    private func log(_ recognizer: UIGestureRecognizer, content: Bool) {
        guard recognizer.state != .changed else { return }
        let x = recognizer.location(in: recognizer.view).x
        ChatViewportTrace.shared.log(TranscriptTouchTrace.backSwipeLine(content: content, state: recognizer.state, x: x))
    }
}

/// Watches touches without taking part in them (InteractionIdleTouchRecognizer).
final class TranscriptTouchProbe: UIGestureRecognizer, UIGestureRecognizerDelegate {
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
        guard let window = view as? UIWindow else { return }
        for touch in touches { TranscriptTouchTrace.touchBegan(touch, in: window) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        for touch in touches { TranscriptTouchTrace.touchFinished(touch, cancelled: false) }
        failIfLastTouch(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        for touch in touches { TranscriptTouchTrace.touchFinished(touch, cancelled: true) }
        failIfLastTouch(touches, event: event)
    }

    /// Fails once every finger has lifted, which resets it for the next touch.
    private func failIfLastTouch(_ touches: Set<UITouch>, event: UIEvent) {
        if !Self.fingerStillDown(besides: touches, among: event.touches(for: self) ?? []) { state = .failed }
    }
}
