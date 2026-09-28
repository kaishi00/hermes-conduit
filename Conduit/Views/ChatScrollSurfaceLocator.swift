import SwiftUI
import UIKit

/// Placed behind the transcript stack inside the chat ScrollView. Finds the
/// UIScrollView SwiftUI renders that ScrollView with and connects it to
/// ChatScrollEngine: content size, viewport size and offset changes arrive
/// through KVO, and drags through the scroll view's own pan gesture.
///
/// iOS 17 has no SwiftUI API for reading scroll geometry (that arrived with
/// onScrollGeometryChange in iOS 18), and measuring it with GeometryReader
/// preferences is what made every scroll tick re-evaluate the chat. If the
/// scroll view cannot be found, the engine stays detached and the view falls
/// back to ScrollViewProxy for explicit commands.
struct ChatScrollSurfaceLocator: UIViewRepresentable {
    let engine: ChatScrollEngine

    func makeUIView(context: Context) -> ChatScrollSurfaceLocatorView {
        ChatScrollSurfaceLocatorView(engine: engine)
    }

    func updateUIView(_ view: ChatScrollSurfaceLocatorView, context: Context) {
        view.engine = engine
    }

    static func dismantleUIView(_ view: ChatScrollSurfaceLocatorView, coordinator: ()) {
        view.disconnect()
    }
}

final class ChatScrollSurfaceLocatorView: UIView {
    weak var engine: ChatScrollEngine? {
        didSet {
            guard engine !== oldValue else { return }
            disconnect()
            connectIfNeeded()
        }
    }

    private(set) var surface: UIScrollViewChatSurface?

    init(engine: ChatScrollEngine) {
        self.engine = engine
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            disconnect()
        } else {
            connectIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The superview chain can be completed after the move to a window.
        connectIfNeeded()
        // adjustedContentInset (safe area) is not KVO-observable; a change
        // to it re-lays out the content, which lands here.
        surface?.checkAdjustedInsets()
    }

    func disconnect() {
        guard let surface else { return }
        self.surface = nil
        surface.invalidate()
    }

    private func connectIfNeeded() {
        guard window != nil, let engine else { return }
        var candidate = superview
        while let view = candidate, !(view is UIScrollView) {
            candidate = view.superview
        }
        guard let scrollView = candidate as? UIScrollView else { return }
        if let surface, surface.scrollView === scrollView { return }
        disconnect()
        let surface = UIScrollViewChatSurface(scrollView: scrollView, locator: self, engine: engine)
        self.surface = surface
        engine.attach(surface)
    }
}

/// ChatScrollSurface backed by the transcript's UIScrollView.
final class UIScrollViewChatSurface: NSObject, ChatScrollSurface {
    private(set) weak var scrollView: UIScrollView?
    private weak var locator: UIView?
    private weak var engine: ChatScrollEngine?
    private var observations: [NSKeyValueObservation] = []
    private var lastAdjustedInsets: UIEdgeInsets

    init(scrollView: UIScrollView, locator: UIView, engine: ChatScrollEngine) {
        self.scrollView = scrollView
        self.locator = locator
        self.engine = engine
        lastAdjustedInsets = scrollView.adjustedContentInset
        super.init()
        observations = [
            scrollView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.engine?.surfaceLayoutChanged() }
            },
            scrollView.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                // Bounds origin is the content offset; only a size change is
                // a layout change (keyboard, rotation, split view).
                guard change.oldValue?.size != change.newValue?.size else { return }
                Self.onMain { self?.engine?.surfaceLayoutChanged() }
            },
            scrollView.observe(\.contentInset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.engine?.surfaceLayoutChanged() }
            },
            scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
                guard change.oldValue != change.newValue else { return }
                Self.onMain { self?.engine?.surfaceScrolled() }
            },
        ]
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
    }

    /// UIKit changes these on the main thread; should one ever arrive
    /// elsewhere, hop instead of trapping.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { body() }
        }
    }

    func checkAdjustedInsets() {
        guard let scrollView, scrollView.adjustedContentInset != lastAdjustedInsets else { return }
        lastAdjustedInsets = scrollView.adjustedContentInset
        engine?.surfaceLayoutChanged()
    }

    func invalidate() {
        observations.forEach { $0.invalidate() }
        observations = []
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
        engine?.detach(self)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            engine?.userDragBegan()
        case .ended, .cancelled, .failed:
            engine?.userDragEnded()
        default:
            break
        }
    }

    // MARK: - ChatScrollSurface

    var contentOffsetY: CGFloat { scrollView?.contentOffset.y ?? 0 }
    var contentHeight: CGFloat { scrollView?.contentSize.height ?? 0 }
    var viewportHeight: CGFloat { scrollView?.bounds.height ?? 0 }
    var insetTop: CGFloat { scrollView?.adjustedContentInset.top ?? 0 }
    var insetBottom: CGFloat { scrollView?.adjustedContentInset.bottom ?? 0 }
    var isTracking: Bool { scrollView?.isTracking ?? false }
    var isDecelerating: Bool { scrollView?.isDecelerating ?? false }

    var transcriptOriginY: CGFloat {
        guard let scrollView, let locator else { return 0 }
        return locator.convert(CGPoint.zero, to: scrollView).y
    }

    func setContentOffsetY(_ y: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        var offset = scrollView.contentOffset
        offset.y = y
        scrollView.setContentOffset(offset, animated: animated)
    }
}
