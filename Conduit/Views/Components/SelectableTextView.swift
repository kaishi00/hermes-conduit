import SwiftUI
import UIKit

/// A non-editable UIKit text surface gives chat text true character-range
/// selection on the iOS versions Conduit supports. SwiftUI's native text
/// selection API is intentionally kept for controls outside this surface,
/// but it cannot select a range within a Text view on older OS releases.
struct SelectableTextView: UIViewRepresentable {
    typealias UIViewType = SelectableTextViewHostView

    let attributedText: NSAttributedString
    let font: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat
    let maximumNumberOfLines: Int
    let wrapsLines: Bool
    let linkColor: UIColor
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?

    init(
        attributedText: NSAttributedString,
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: UIColor = .link,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
    ) {
        self.attributedText = attributedText
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.wrapsLines = wrapsLines
        self.linkColor = linkColor
        self.selectionCoordinator = selectionCoordinator
        self.selectionSegment = selectionSegment
    }

    init(
        attributedText: AttributedString,
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: UIColor = .link,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
    ) {
        self.init(
            attributedText: Self.bridge(attributedText, defaultFont: font, defaultColor: textColor, linkColor: linkColor),
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            wrapsLines: wrapsLines,
            linkColor: linkColor,
            selectionCoordinator: selectionCoordinator,
            selectionSegment: selectionSegment
        )
    }

    init(
        text: String,
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: UIColor = .link,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil
    ) {
        self.init(
            attributedText: NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: textColor]
            ),
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            wrapsLines: wrapsLines,
            linkColor: linkColor,
            selectionCoordinator: selectionCoordinator,
            selectionSegment: selectionSegment
        )
    }

    /// Exposed for unit tests so the behavior that matters for the feature is
    /// tested directly instead of being inferred from a SwiftUI modifier.
    static func makeTextView() -> UITextView {
        let textView = UITextView(frame: .zero)
        configureBaseTextView(textView)
        return textView
    }

    private static func configureBaseTextView(_ textView: UITextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            linkColor: linkColor,
            selectionCoordinator: selectionCoordinator,
            selectionSegment: selectionSegment
        )
    }

    func makeUIView(context: Context) -> SelectableTextViewHostView {
        makeUIViewForTests(coordinator: context.coordinator)
    }

    func updateUIView(_ uiView: SelectableTextViewHostView, context: Context) {
        updateUIViewForTests(uiView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ uiView: SelectableTextViewHostView, coordinator: Coordinator) {
        tearDownMountedTextView(in: uiView)
    }

    @MainActor
    func makeUIViewForTests(coordinator: Coordinator) -> SelectableTextViewHostView {
        let hostView = SelectableTextViewHostView(frame: .zero)
        updateUIViewForTests(hostView, coordinator: coordinator)
        return hostView
    }

    @MainActor
    func updateUIViewForTests(_ uiView: SelectableTextViewHostView, coordinator: Coordinator) {
        coordinator.linkColor = linkColor
        coordinator.selectionCoordinator = selectionCoordinator
        coordinator.selectionSegment = selectionSegment

        unregisterMountedTextViewIfNeeded(in: uiView, coordinator: coordinator)

        let needsCoordinatedTextView = selectionCoordinator != nil && selectionSegment != nil
        if uiView.isUsingCoordinatedTextView != needsCoordinatedTextView {
            let replacementTextView = makeMountedTextView(needsCoordinatedTextView: needsCoordinatedTextView)
            replacementTextView.attributedText = uiView.mountedTextView.attributedText
            replacementTextView.selectedRange = uiView.mountedTextView.selectedRange
            uiView.setMountedTextView(replacementTextView)
        }

        let textView = uiView.mountedTextView
        textView.delegate = coordinator
        configureSelectionBridge(for: textView, coordinator: coordinator)
        configure(textView)
        registerSelectionIfNeeded(for: textView, coordinator: coordinator)
        uiView.mountedSelectionCoordinator = coordinator.selectionCoordinator
        uiView.mountedSelectionSegment = coordinator.selectionSegment
    }

    /// Extracted measurement logic so sizeThatFits and tests share one path.
    /// Applies the same default-font and paragraph-style fill that
    /// configure(_:) uses, so the measurement matches the rendered output.
    func measureNonWrapping() -> CGSize {
        let styledText = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: styledText.length)

        if fullRange.length > 0 {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            styledText.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

            styledText.enumerateAttribute(.font, in: fullRange, options: []) { value, subrange, _ in
                if value == nil {
                    styledText.addAttribute(.font, value: font, range: subrange)
                }
            }
        }

        let measured = styledText.boundingRect(
            with: CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(
            width: max(1, ceil(measured.width)),
            height: max(font.lineHeight, ceil(measured.height))
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextViewHostView, context: Context) -> CGSize? {
        if !wrapsLines {
            return measureNonWrapping()
        }

        let textView = uiView.mountedTextView

        // Inside a horizontal ScrollView the width proposal is nil; fall back
        // to the last laid-out width so SwiftUI measures at the real column
        // width instead of intrinsicContentSize (which uses a stale container).
        let width = proposal.width
            ?? (textView.bounds.width > 0 ? textView.bounds.width : nil)
        guard let width, width > 0, width.isFinite else { return nil }

        return CGSize(width: width, height: Self.measuredWrappingHeight(of: textView, at: width))
    }

    /// Shared measurement path for `sizeThatFits` and unit tests. Delegates
    /// to `UITextView.sizeThatFits` at the target width. On iOS 17+
    /// (TextKit 2) the proposed width drives wrapping independent of the
    /// text container's stored size, so no container mutation is needed.
    static func measuredWrappingHeight(of textView: UITextView, at width: CGFloat) -> CGFloat {
        let measured = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return ceil(measured.height)
    }

    private func configure(_ textView: UITextView) {
        textView.font = font
        textView.textColor = textColor
        textView.textContainer.widthTracksTextView = wrapsLines
        textView.textContainer.size = wrapsLines
            ? CGSize(width: max(textView.bounds.width, 1), height: CGFloat.greatestFiniteMagnitude)
            : CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer.maximumNumberOfLines = maximumNumberOfLines
        textView.textContainer.lineBreakMode = maximumNumberOfLines > 0
            ? .byTruncatingTail
            : (wrapsLines ? .byWordWrapping : .byClipping)
        textView.linkTextAttributes = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        // Single-pass styling: preserve per-run font and foregroundColor from
        // attributedText, fill only missing attributes with the configured
        // defaults, then apply paragraph style globally. This replaces the
        // previous double-pass that applied globals then overwrote with runs.
        let styledText = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: styledText.length)

        if fullRange.length > 0 {
            styledText.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

            styledText.enumerateAttribute(.font, in: fullRange, options: []) { value, subrange, _ in
                if value == nil {
                    styledText.addAttribute(.font, value: font, range: subrange)
                }
            }
            styledText.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, subrange, _ in
                if value == nil {
                    styledText.addAttribute(.foregroundColor, value: textColor, range: subrange)
                }
            }
        }

        let selectedRange = textView.selectedRange
        if !textView.attributedText.isEqual(to: styledText) {
            textView.attributedText = styledText
            let selectedLocation = min(selectedRange.location, styledText.length)
            let selectedEnd = min(NSMaxRange(selectedRange), styledText.length)
            textView.selectedRange = NSRange(
                location: selectedLocation,
                length: max(0, selectedEnd - selectedLocation)
            )
        }
        textView.invalidateIntrinsicContentSize()
    }

    private func registerSelectionIfNeeded(for textView: UITextView, coordinator: Coordinator) {
        guard
            let selectionCoordinator = coordinator.selectionCoordinator,
            let selectionSegment = coordinator.selectionSegment
        else { return }

        selectionCoordinator.register(descriptor: selectionSegment, textView: textView)
    }

    private func unregisterMountedTextViewIfNeeded(in hostView: SelectableTextViewHostView, coordinator: Coordinator) {
        guard
            let selectionCoordinator = hostView.mountedSelectionCoordinator,
            let selectionSegment = hostView.mountedSelectionSegment
        else { return }

        if selectionCoordinator !== coordinator.selectionCoordinator || selectionSegment != coordinator.selectionSegment {
            selectionCoordinator.unregister(segmentID: selectionSegment.id, textView: hostView.mountedTextView)
            hostView.mountedSelectionCoordinator = nil
            hostView.mountedSelectionSegment = nil
        }
    }

    private func configureSelectionBridge(for textView: UITextView, coordinator: Coordinator) {
        guard let coordinatedTextView = textView as? MarkdownSelectionTextView else { return }

        coordinatedTextView.selectionCoordinator = coordinator.selectionCoordinator
        coordinatedTextView.selectionSegment = coordinator.selectionSegment
        coordinatedTextView.onTouchBegan = makeTouchHandler(coordinator: coordinator)
    }

    private func makeTouchHandler(coordinator: Coordinator) -> ((MarkdownSelectionTextView, CGPoint) -> Void)? {
        guard coordinator.selectionCoordinator != nil, coordinator.selectionSegment != nil else {
            return nil
        }

        return { [weak selectionCoordinator = coordinator.selectionCoordinator, selectionSegment = coordinator.selectionSegment] coordinatedTextView, localPoint in
            guard
                let selectionCoordinator,
                let selectionSegment
            else { return }
            selectionCoordinator.beginPendingSelection(
                segmentID: selectionSegment.id,
                offset: coordinatedTextView.utf16Offset(for: localPoint),
                windowPoint: coordinatedTextView.windowPoint(forLocalPoint: localPoint) ?? .zero
            )
        }
    }

    private func makeMountedTextView(needsCoordinatedTextView: Bool) -> UITextView {
        if needsCoordinatedTextView {
            let textView = MarkdownSelectionTextView(frame: .zero)
            Self.configureBaseTextView(textView)
            return textView
        }
        return Self.makeTextView()
    }

    private static func tearDownMountedTextView(in hostView: SelectableTextViewHostView) {
        let textView = hostView.mountedTextView
        textView.delegate = nil
        if let coordinated = textView as? MarkdownSelectionTextView {
            coordinated.onTouchBegan = nil
            coordinated.selectionCoordinator = nil
            coordinated.selectionSegment = nil
        }
        textView.resignFirstResponder()
        if let selectionCoordinator = hostView.mountedSelectionCoordinator,
           let selectionSegment = hostView.mountedSelectionSegment {
            selectionCoordinator.unregister(segmentID: selectionSegment.id, textView: textView)
        }
        hostView.mountedSelectionCoordinator = nil
        hostView.mountedSelectionSegment = nil
    }

    /// Converts an AttributedString (from Markdown parsing) into an
    /// NSAttributedString with UIKit-compatible font traits. Exposed as
    /// internal so callers can convert without instantiating the full view.
    static func bridge(
        _ value: AttributedString,
        defaultFont: UIFont,
        defaultColor: UIColor,
        linkColor: UIColor
    ) -> NSAttributedString {
        let bridged = NSMutableAttributedString(
            string: String(value.characters),
            attributes: [
                .font: defaultFont,
                .foregroundColor: defaultColor
            ]
        )

        for run in value.runs {
            let range = NSRange(run.range, in: value)
            guard range.length > 0 else { continue }

            if let intent = run.inlinePresentationIntent {
                var runFont = defaultFont
                if intent.contains(.stronglyEmphasized) {
                    runFont = runFont.withTraits(.traitBold)
                }
                if intent.contains(.emphasized) {
                    runFont = runFont.withTraits(.traitItalic)
                }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: defaultFont.pointSize, weight: .regular)
                }
                bridged.addAttribute(.font, value: runFont, range: range)
                if intent.contains(.strikethrough) {
                    bridged.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range
                    )
                }
            }

            if let runColor = run.foregroundColor {
                bridged.addAttribute(.foregroundColor, value: UIColor(runColor), range: range)
            }
            if let link = run.link {
                bridged.addAttribute(.link, value: link, range: range)
                bridged.addAttribute(.foregroundColor, value: linkColor, range: range)
            }
        }
        return bridged
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var linkColor: UIColor
        weak var selectionCoordinator: MarkdownSelectionCoordinator?
        var selectionSegment: MarkdownSelectionSegmentDescriptor?

        init(
            linkColor: UIColor,
            selectionCoordinator: MarkdownSelectionCoordinator?,
            selectionSegment: MarkdownSelectionSegmentDescriptor?
        ) {
            self.linkColor = linkColor
            self.selectionCoordinator = selectionCoordinator
            self.selectionSegment = selectionSegment
        }

        // NOTE: there is deliberately no edit-menu interception here. The
        // only menuConfigurationFor delegate selector is for text items
        // (links/attachments), not the selection menu — an interception with
        // a near-miss selector compiles silently and never runs. And since
        // cross-block selections dismiss the owner's first responder (see
        // MarkdownSelectionCoordinator), they never present the system menu
        // at all: copying goes through the coordinator-owned pill, while
        // within-block selections keep the fully native menu.

        // shouldInteractWith is formally deprecated in iOS 17 in favor of
        // textView(_:primaryActionFor:defaultAction:) and
        // textView(_:menuConfigurationFor:defaultMenu:), but those are only
        // available on iOS 17+. We still support iOS 16, so we keep this
        // delegate method and gate behavior on the interaction type:
        //   .invokeDefaultAction → open the URL ourselves
        //   .preview / .presentActions → let UIKit show its context menu/preview
        @available(iOS, deprecated: 17.0)
        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            switch interaction {
            case .invokeDefaultAction:
                UIApplication.shared.open(url)
                return false
            case .preview, .presentActions:
                return true
            @unknown default:
                return true
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard
                let selectionCoordinator,
                let selectionSegment,
                !selectionCoordinator.isApplyingNativeSelectionRanges,
                let textRange = textView.selectedTextRange
            else { return }

            let startOffset = textView.offset(from: textView.beginningOfDocument, to: textRange.start)
            let endOffset = textView.offset(from: textView.beginningOfDocument, to: textRange.end)
            let startWindowPoint = windowPoint(for: textRange.start, in: textView)
            let endWindowPoint = windowPoint(for: textRange.end, in: textView)

            let selectedRange: NSRange
            let lowerWindowPoint: CGPoint
            let upperWindowPoint: CGPoint
            if startOffset <= endOffset {
                selectedRange = NSRange(location: startOffset, length: endOffset - startOffset)
                lowerWindowPoint = startWindowPoint
                upperWindowPoint = endWindowPoint
            } else {
                selectedRange = NSRange(location: endOffset, length: startOffset - endOffset)
                lowerWindowPoint = endWindowPoint
                upperWindowPoint = startWindowPoint
            }

            selectionCoordinator.updateNativeSelection(
                segmentID: selectionSegment.id,
                selectedRange: selectedRange,
                lowerWindowPoint: lowerWindowPoint,
                upperWindowPoint: upperWindowPoint
            )
        }

        private func windowPoint(for position: UITextPosition, in textView: UITextView) -> CGPoint {
            let caretRect = textView.caretRect(for: position)
            let caretPoint = CGPoint(x: caretRect.midX, y: caretRect.midY)
            return (textView as? MarkdownSelectionTextView)?.windowPoint(forLocalPoint: caretPoint)
                ?? textView.window.map { textView.convert(caretPoint, to: $0) }
                ?? .zero
        }
    }
}

private final class MarkdownSelectionTextView: UITextView {
    var onTouchBegan: ((MarkdownSelectionTextView, CGPoint) -> Void)?
    weak var selectionCoordinator: MarkdownSelectionCoordinator?
    var selectionSegment: MarkdownSelectionSegmentDescriptor?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addGestureRecognizer(MarkdownSelectionObserverGestureRecognizer(observedTextView: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first {
            onTouchBegan?(self, touch.location(in: self))
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        selectionCoordinator?.cancelPendingSelection()
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        selectionCoordinator?.cancelPendingSelection()
        super.touchesCancelled(touches, with: event)
    }

    override func copy(_ sender: Any?) {
        guard let copied = coordinatedCopiedAttributedText() else {
            super.copy(sender)
            return
        }

        // String-only, matching the copy paths proven to paste cross-app;
        // pairing the write with an RTF item made external paste targets
        // come up empty even though in-app reads showed the text.
        UIPasteboard.general.string = copied.string
    }

    func simulateTouchBeganForTesting(_ localPoint: CGPoint) {
        onTouchBegan?(self, localPoint)
    }

    func coordinatedCopiedAttributedText() -> NSAttributedString? {
        guard
            let selectionCoordinator,
            selectionCoordinator.hasCrossSegmentSelection
        else { return nil }

        let copied = selectionCoordinator.copiedAttributedTextForActiveSelection()
        return copied.length > 0 ? copied : nil
    }

    func utf16Offset(for localPoint: CGPoint) -> Int {
        guard let position = closestPosition(to: localPoint) else {
            return selectedRange.location
        }
        return offset(from: beginningOfDocument, to: position)
    }

    func windowPoint(forLocalPoint localPoint: CGPoint) -> CGPoint? {
        guard let window else { return nil }
        return convert(localPoint, to: window)
    }

    var selectionObserverForTesting: MarkdownSelectionObserverGestureRecognizer? {
        gestureRecognizers?.compactMap { $0 as? MarkdownSelectionObserverGestureRecognizer }.first
    }
}

/// Tracks the finger during a native text-selection drag without ever
/// recognizing, so UITextView's private selection gesture and the enclosing
/// scroll views keep their exact stock behavior. A recognizer that never
/// leaves `.possible`, always allows simultaneous recognition, and never
/// cancels touches can't be failed or excluded by those gestures — yet it
/// still receives the full touch stream, which is the piece every earlier
/// cross-block attempt was missing (SwiftUI gestures fought the ScrollView,
/// a coexisting pan was unpredictably failed by the private gesture, and
/// view-level touchesMoved was starved). While the coordinator reports an
/// active selection drag, each move is forwarded as a window point and the
/// coordinator resolves it against every registered block/cell text view,
/// extending the selection across them.
final class MarkdownSelectionObserverGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private weak var observedTextView: MarkdownSelectionTextView?
    /// Set when a touch begins on this text view's existing selection or its
    /// handles (e.g. dragging a native handle out of the block): the gesture
    /// flag is already false by then, so the touch itself arms the observer
    /// for the drag that follows.
    private var isDrivingSelectionTouch = false

    fileprivate init(observedTextView: MarkdownSelectionTextView) {
        self.observedTextView = observedTextView
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard
            let coordinator = observedTextView?.selectionCoordinator,
            let segment = observedTextView?.selectionSegment,
            coordinator.hasActiveSelection,
            coordinator.nativeSelectionOwnerSegmentID == segment.id
        else { return }
        isDrivingSelectionTouch = true
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, let window = observedTextView?.window else { return }
        handleMove(toWindowPoint: touch.location(in: window))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        handleTouchEnd()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        handleTouchEnd()
    }

    func handleMove(toWindowPoint windowPoint: CGPoint) {
        guard
            let coordinator = observedTextView?.selectionCoordinator,
            coordinator.hasActiveSelection,
            coordinator.isSelectionGestureActive || isDrivingSelectionTouch
        else { return }
        coordinator.updateSelection(windowPoint: windowPoint)
    }

    func handleTouchEnd() {
        let wasDriving = isDrivingSelectionTouch
        isDrivingSelectionTouch = false
        guard
            let coordinator = observedTextView?.selectionCoordinator,
            coordinator.isSelectionGestureActive || wasDriving
        else { return }
        coordinator.endSelection()
    }
}

final class SelectableTextViewHostView: UIView {
    private(set) var mountedTextView: UITextView
    weak var mountedSelectionCoordinator: MarkdownSelectionCoordinator?
    var mountedSelectionSegment: MarkdownSelectionSegmentDescriptor?

    override init(frame: CGRect) {
        self.mountedTextView = SelectableTextView.makeTextView()
        super.init(frame: frame)
        embedMountedTextView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isUsingCoordinatedTextView: Bool {
        mountedTextView is MarkdownSelectionTextView
    }

    func setMountedTextView(_ textView: UITextView) {
        guard mountedTextView !== textView else { return }
        mountedTextView.removeFromSuperview()
        mountedTextView = textView
        embedMountedTextView()
    }

    func simulateTouchBeganForTesting(at localPoint: CGPoint) {
        (mountedTextView as? MarkdownSelectionTextView)?.simulateTouchBeganForTesting(localPoint)
    }

    func coordinatedCopiedAttributedTextForTesting() -> NSAttributedString? {
        (mountedTextView as? MarkdownSelectionTextView)?.coordinatedCopiedAttributedText()
    }

    var selectionObserverForTesting: MarkdownSelectionObserverGestureRecognizer? {
        (mountedTextView as? MarkdownSelectionTextView)?.selectionObserverForTesting
    }

    private func embedMountedTextView() {
        addSubview(mountedTextView)
        mountedTextView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mountedTextView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mountedTextView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mountedTextView.topAnchor.constraint(equalTo: topAnchor),
            mountedTextView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

extension UIFont {
    /// Returns a font with the requested symbolic traits merged into the
    /// existing set, so chained calls (e.g. bold then italic) accumulate
    /// rather than replacing the entire trait collection.
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(traits)
        ) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
