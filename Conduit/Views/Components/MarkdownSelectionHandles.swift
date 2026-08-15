import SwiftUI
import UIKit

/// Cross-block selection chrome: draggable endpoint handles and a copy pill
/// positioned at the true selection endpoints anywhere in the message. The
/// system's native handles cannot leave the text view that owns them, so a
/// cross-segment selection takes over with coordinator-owned handles once
/// the gesture ends. Within-block selections never show this chrome and keep
/// the fully native handles and menu.
struct MarkdownSelectionHandleOverlay: UIViewRepresentable {
    @ObservedObject var coordinator: MarkdownSelectionCoordinator

    func makeUIView(context: Context) -> MarkdownSelectionHandleContainerView {
        let view = MarkdownSelectionHandleContainerView(frame: .zero)
        view.coordinator = coordinator
        return view
    }

    func updateUIView(_ uiView: MarkdownSelectionHandleContainerView, context: Context) {
        uiView.coordinator = coordinator
        uiView.setNeedsLayout()
    }

    /// Without this, SwiftUI sizes the overlay from the UIKit view's
    /// autolayout fitting size — a fraction of the content height — and
    /// handles laid out below that line render fine but can never be
    /// hit-tested. The overlay must match the content proposal exactly.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MarkdownSelectionHandleContainerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: proposal.height ?? uiView.bounds.height)
    }
}

final class MarkdownSelectionHandleContainerView: UIView, UIGestureRecognizerDelegate {
    weak var coordinator: MarkdownSelectionCoordinator? {
        didSet {
            if coordinator !== oldValue { installChromeIfNeeded() }
            setNeedsLayout()
        }
    }

    private(set) var anchorHandle: MarkdownSelectionHandleView?
    private(set) var focusHandle: MarkdownSelectionHandleView?
    private(set) var copyPill: UIButton?
    private(set) var copyPillBackdrop: UIVisualEffectView?
    private(set) var copyFeedbackLabel: UILabel?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The container itself is transparent to touches so the text beneath
    /// keeps working; only the handles and the pill accept hits.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        return view === self ? nil : view
    }

    private var repositioningDisplayLink: CADisplayLink?

    override func layoutSubviews() {
        super.layoutSubviews()

        guard
            let coordinator,
            let window,
            coordinator.hasCrossSegmentSelection,
            let anchor = coordinator.activeAnchorEndpoint,
            let focus = coordinator.activeFocusEndpoint
        else {
            subviews.forEach { $0.isHidden = true }
            stopRepositioningDisplayLink()
            return
        }

        let anchorCaret = coordinator.caretRect(for: anchor, in: window)
        let focusCaret = coordinator.caretRect(for: focus, in: window)
        guard let anchorCaret, let focusCaret else {
            subviews.forEach { $0.isHidden = true }
            stopRepositioningDisplayLink()
            return
        }

        anchorHandle?.isHidden = false
        focusHandle?.isHidden = false
        copyPill?.isHidden = false
        copyPillBackdrop?.isHidden = false
        startRepositioningDisplayLink()

        positionHandle(anchorHandle, atCaret: anchorCaret)
        positionHandle(focusHandle, atCaret: focusCaret)

        if let pill = copyPill {
            pill.invalidateIntrinsicContentSize()
            let fitted = pill.intrinsicContentSize
            let pillSize = CGSize(width: fitted.width, height: max(32, fitted.height))
            // Anchor to the focus end — the endpoint the finger last touched
            // — so the pill is always near the user's hand. For selections
            // taller than the screen this keeps it in view instead of pinned
            // to the distant start, and the clamp keeps it inside the
            // container where hit-testing can reach it.
            let focusLocal = convert(focusCaret, from: window)
            let pillX = min(max(8, focusLocal.midX - pillSize.width / 2), max(8, bounds.width - pillSize.width - 8))
            let pillY = min(max(4, focusLocal.minY - pillSize.height - 10), max(4, bounds.height - pillSize.height - 4))
            pill.frame = CGRect(origin: CGPoint(x: pillX, y: pillY), size: pillSize)
            copyPillBackdrop?.frame = pill.frame
            if let feedback = copyFeedbackLabel {
                feedback.sizeToFit()
                feedback.frame = CGRect(
                    x: pill.frame.minX + 10,
                    y: pill.frame.midY - feedback.frame.height / 2,
                    width: feedback.frame.width,
                    height: feedback.frame.height
                )
            }
        }
    }

    private func positionHandle(_ handle: MarkdownSelectionHandleView?, atCaret caret: CGRect) {
        guard let handle else { return }
        let local = convert(caret, from: window ?? self)
        // The knob (lower 12pt of the 20pt view) tucks just under the text
        // line; the stem rises through it.
        handle.center = CGPoint(
            x: local.midX,
            y: local.maxY - 2
        )
    }

    private func installChromeIfNeeded() {
        guard anchorHandle == nil, coordinator != nil else { return }

        let anchor = MarkdownSelectionHandleView(role: .anchor)
        anchor.accessibilityIdentifier = "selection.handle.anchor"
        let focus = MarkdownSelectionHandleView(role: .focus)
        focus.accessibilityIdentifier = "selection.handle.focus"

        let anchorPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        anchorPan.cancelsTouchesInView = false
        anchorPan.delegate = self
        anchor.addGestureRecognizer(anchorPan)
        let focusPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        focusPan.cancelsTouchesInView = false
        focusPan.delegate = self
        focus.addGestureRecognizer(focusPan)

        // Liquid Glass on iOS 26, adaptive thick material on older systems;
        // both read correctly in light and dark mode with label-colored
        // content, like the system edit menu.
        let pillEffect: UIVisualEffect
        if #available(iOS 26.0, *) {
            pillEffect = UIGlassEffect()
        } else {
            pillEffect = UIBlurEffect(style: .systemThickMaterial)
        }
        let pillBackdrop = UIVisualEffectView(effect: pillEffect)
        pillBackdrop.isUserInteractionEnabled = false
        pillBackdrop.layer.cornerRadius = 18
        pillBackdrop.layer.cornerCurve = .continuous
        pillBackdrop.clipsToBounds = true
        pillBackdrop.layer.shadowColor = UIColor.black.cgColor
        pillBackdrop.layer.shadowOpacity = 0.18
        pillBackdrop.layer.shadowRadius = 5
        pillBackdrop.layer.shadowOffset = CGSize(width: 0, height: 2)

        var pillConfiguration = UIButton.Configuration.plain()
        pillConfiguration.title = NSLocalizedString("Copy", comment: "Copy the cross-block selection")
        pillConfiguration.image = UIImage(systemName: "doc.on.doc")
        pillConfiguration.imagePlacement = .leading
        pillConfiguration.imagePadding = 6
        pillConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 16)
        pillConfiguration.baseForegroundColor = .label

        let pill = UIButton(configuration: pillConfiguration)
        pill.accessibilityIdentifier = "selection.copyPill"
        pill.addAction(UIAction { [weak self] _ in
            self?.copyActiveSelection()
        }, for: .touchUpInside)

        let feedback = UILabel()
        feedback.text = "Copied"
        feedback.textColor = .label
        feedback.font = .systemFont(ofSize: 12, weight: .semibold)
        feedback.isHidden = true

        [anchor, focus, pillBackdrop, pill, feedback].forEach {
            $0.isHidden = true
            $0.translatesAutoresizingMaskIntoConstraints = true
            addSubview($0)
        }

        anchorHandle = anchor
        focusHandle = focus
        copyPill = pill
        copyPillBackdrop = pillBackdrop
        copyFeedbackLabel = feedback
    }

    /// The container sits outside the transcript scroll view, so nothing
    /// naturally triggers a relayout while the transcript scrolls and the
    /// chrome would stay pinned at stale window coordinates. A display link
    /// (running only while the chrome is visible) repositions it every frame.
    private func startRepositioningDisplayLink() {
        guard repositioningDisplayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(repositionFromDisplayLink))
        link.add(to: .main, forMode: .common)
        repositioningDisplayLink = link
    }

    private func stopRepositioningDisplayLink() {
        repositioningDisplayLink?.invalidate()
        repositioningDisplayLink = nil
    }

    @objc private func repositionFromDisplayLink() {
        // Coordinator state gone — the next layout pass hides the chrome and
        // stops the link.
        guard let coordinator, coordinator.hasCrossSegmentSelection else {
            setNeedsLayout()
            return
        }
        setNeedsLayout()
    }

    deinit {
        repositioningDisplayLink?.invalidate()
    }

    /// Draggable chrome inside a scroll view: without this, the ancestor
    /// scroll pan claims any moving touch and the handles freeze.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UIPanGestureRecognizer
            && gestureRecognizer.view is MarkdownSelectionHandleView
            && otherGestureRecognizer is UIPanGestureRecognizer
            && !(otherGestureRecognizer.view is MarkdownSelectionHandleView)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let window else { return }
        let point = pan.location(in: window)

        switch pan.state {
        case .changed:
            if pan.view === anchorHandle {
                handleDragMoved(role: .anchor, windowPoint: point)
            } else {
                handleDragMoved(role: .focus, windowPoint: point)
            }
        case .ended, .cancelled:
            handleDragEnded()
        default:
            break
        }
    }

    func handleDragMoved(role: MarkdownSelectionHandleView.Role, windowPoint: CGPoint) {
        guard let coordinator else { return }
        if role == .anchor {
            coordinator.updateAnchorSelection(windowPoint: windowPoint)
        } else {
            coordinator.updateSelection(windowPoint: windowPoint)
        }
        setNeedsLayout()
    }

    func handleDragEnded() {
        coordinator?.endSelection()
        setNeedsLayout()
    }

    private func copyActiveSelection() {
        guard
            let coordinator,
            coordinator.hasActiveSelection
        else { return }
        let copied = coordinator.copiedAttributedTextForActiveSelection()
        guard copied.length > 0 else { return }

        // String-only, matching the copy paths proven to paste cross-app;
        // pairing the write with an RTF item made external paste targets
        // come up empty even though in-app reads showed the text.
        UIPasteboard.general.string = copied.string

        copyFeedbackLabel?.isHidden = false
        if let pill = copyPill {
            var copied = pill.configuration
            copied?.title = nil
            copied?.image = UIImage(systemName: "checkmark")
            copied?.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16)
            pill.configuration = copied
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyFeedbackLabel?.isHidden = true
            if let pill = self?.copyPill {
                var config = pill.configuration
                config?.title = NSLocalizedString("Copy", comment: "Copy the cross-block selection")
                config?.image = UIImage(systemName: "doc.on.doc")
                config?.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 16)
                pill.configuration = config
            }
        }
    }
}

/// Bridges the coordinator's static "visible selection owner" to SwiftUI so
/// the chrome root re-renders when ownership changes between messages.
@MainActor
final class MarkdownSelectionChromeLocator: ObservableObject {
    static let shared = MarkdownSelectionChromeLocator()
    private init() {}

    func selectionOwnerDidChange() {
        objectWillChange.send()
    }
}

/// Window-level host for the selection chrome. Mounted once at the chat
/// screen root (and the selection fixture), it gives the handles and copy
/// pill a full-screen frame — content-sized overlays proved unreliable
/// (SwiftUI sized one to 200pt of a 330pt message, leaving lower handles
/// rendered but untouchable). Positions come from window-coordinate
/// conversion, so placement is correct regardless of where this sits.
struct MarkdownSelectionChromeRoot: View {
    @ObservedObject private var locator = MarkdownSelectionChromeLocator.shared

    var body: some View {
        Group {
            if let coordinator = MarkdownSelectionCoordinator.activeCoordinator {
                MarkdownSelectionHandleOverlay(coordinator: coordinator)
            }
        }
    }
}

/// A single draggable selection endpoint: a small knob hanging just below
/// the caret line, mirroring the system handle silhouette.
final class MarkdownSelectionHandleView: UIView {
    enum Role {
        case anchor
        case focus
    }

    let role: Role

    init(role: Role) {
        self.role = role
        super.init(frame: CGRect(x: 0, y: 0, width: 14, height: 20))
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        // Without this the views are invisible to the accessibility tree —
        // both VoiceOver and the UI tests' identifier queries.
        isAccessibilityElement = true
        accessibilityLabel = role == .anchor ? "Selection start handle" : "Selection end handle"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Native-style hit slop: the 16x22 visual is far smaller than where a
    /// finger actually lands (a grab 14pt above the frame fell through in
    /// manual testing), so the touchable area extends well past the drawing.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -24, dy: -28).contains(point)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // System silhouette: a thin stem rising from a solid knob that sits
        // just below the text line — the knob occupies the lower 12pt and
        // the stem reaches up to the top of the frame.
        let knob = CGRect(x: 1, y: 8, width: 12, height: 12)
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth( 1.5)
        context.setLineCap(.round)

        context.move(to: CGPoint(x: knob.midX, y: 0))
        context.addLine(to: CGPoint(x: knob.midX, y: knob.minY + 1))
        context.strokePath()
        context.fillEllipse(in: knob)
    }
}
