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
    /// Paragraph-style alignment applied to laid-out text, so it governs
    /// every wrapped line (Markdown table `:---:`/`---:` cells). `.natural`
    /// preserves the default for all other callers.
    let textAlignment: NSTextAlignment
    /// When set, the view self-sizes at a deterministic width derived from
    /// its content and this range (used by Markdown table cells), ignoring
    /// layout proposals. See `measuredSize(proposalWidth:textView:)`.
    let selfSizingWidthRange: ClosedRange<CGFloat>?
    let selectionCoordinator: MarkdownSelectionCoordinator?
    let selectionSegment: MarkdownSelectionSegmentDescriptor?
    /// Keeps the paragraph styles the text carries (a chat answer's run of
    /// prose blocks, each paragraph spaced and indented as its own block
    /// view would be); `lineSpacing` and `textAlignment` fill the rest.
    /// Off, they replace every paragraph's style.
    let keepsParagraphStyles: Bool

    init(
        attributedText: NSAttributedString,
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: UIColor = .link,
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
        selectionCoordinator: MarkdownSelectionCoordinator? = nil,
        selectionSegment: MarkdownSelectionSegmentDescriptor? = nil,
        keepsParagraphStyles: Bool = false
    ) {
        self.attributedText = attributedText
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.wrapsLines = wrapsLines
        self.linkColor = linkColor
        self.textAlignment = textAlignment
        self.selfSizingWidthRange = selfSizingWidthRange
        self.selectionCoordinator = selectionCoordinator
        self.selectionSegment = selectionSegment
        self.keepsParagraphStyles = keepsParagraphStyles
    }

    init(
        attributedText: AttributedString,
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: UIColor = .link,
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
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
            textAlignment: textAlignment,
            selfSizingWidthRange: selfSizingWidthRange,
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
        textAlignment: NSTextAlignment = .natural,
        selfSizingWidthRange: ClosedRange<CGFloat>? = nil,
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
            textAlignment: textAlignment,
            selfSizingWidthRange: selfSizingWidthRange,
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

    @MainActor
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
        context.coordinator.openURL = context.environment.openURL
        context.coordinator.quoteAction = context.environment.chatQuoteAction
        let hostView = makeUIViewForTests(
            coordinator: context.coordinator,
            drawsUntilTouched: drawsUntilTouched(in: context.environment)
        )
        hostView.selectionTint = context.environment.textSelectionTint
        return hostView
    }

    func updateUIView(_ uiView: SelectableTextViewHostView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        context.coordinator.quoteAction = context.environment.chatQuoteAction
        // VoiceOver or Switch Control came on: they read the text view.
        if uiView.canvas != nil, !drawsUntilTouched(in: context.environment) {
            uiView.needsTextView = true
        }
        updateUIViewForTests(uiView, coordinator: context.coordinator)
        uiView.selectionTint = context.environment.textSelectionTint
    }

    /// Whether this text is drawn until something needs its text view: on
    /// in a chat, except for VoiceOver and Switch Control, which read the
    /// text view, and for text that doesn't wrap: a code block's tiles
    /// would be as wide as its longest line. A touch mounts it
    /// (SelectableTextViewHostView), and so does a selection made elsewhere
    /// in the same message.
    func drawsUntilTouched(in environment: EnvironmentValues) -> Bool {
        wrapsLines
            && environment.selectableTextDrawsUntilTouched
            && !environment.accessibilityVoiceOverEnabled
            && !environment.accessibilitySwitchControlEnabled
    }

    @MainActor
    static func dismantleUIView(_ uiView: SelectableTextViewHostView, coordinator: Coordinator) {
        uiView.cancelDeferredSelectionRegistration()
        guard let textView = uiView.textView else { return }
        tearDownMountedTextView(in: uiView)
        SelectableTextViewPool.recycle(textView)
    }

    @MainActor
    func makeUIViewForTests(coordinator: Coordinator, drawsUntilTouched: Bool = false) -> SelectableTextViewHostView {
        let hostView: SelectableTextViewHostView
        if drawsUntilTouched {
            hostView = SelectableTextViewHostView(canvas: SelectableTextCanvas())
        } else {
            // The kind of text view this mount needs, made once: a plain one
            // swapped straight for a coordinated one cost two UITextViews per
            // block each time a row scrolled into view.
            let needsCoordinatedTextView = selectionCoordinator != nil && selectionSegment != nil
            hostView = SelectableTextViewHostView(
                textView: makeMountedTextView(needsCoordinatedTextView: needsCoordinatedTextView)
            )
        }
        updateUIViewForTests(hostView, coordinator: coordinator)
        return hostView
    }

    @MainActor
    func updateUIViewForTests(_ uiView: SelectableTextViewHostView, coordinator: Coordinator) {
        TranscriptPerf.note(.selectableTextViewUpdate)
        coordinator.linkColor = linkColor
        coordinator.selectionCoordinator = selectionCoordinator
        coordinator.selectionSegment = selectionSegment

        if let canvas = uiView.canvas {
            // A touch can mount the text view between updates, configured
            // from this view's inputs.
            coordinator.latestView = self
            uiView.coordinator = coordinator
            let presentation = Coordinator.Presentation(view: self)
            if coordinator.canvasPresentation != presentation {
                TranscriptPerf.note(.selectableTextViewTextRebuild)
                canvas.configure(
                    text: styledText(),
                    font: font,
                    linkColor: linkColor,
                    maximumNumberOfLines: maximumNumberOfLines,
                    wrapsLines: wrapsLines
                )
                coordinator.canvasPresentation = presentation
                coordinator.presentationGeneration &+= 1
            }
            // A block that appears while a selection is live mounts at once,
            // so the selection can reach it.
            guard uiView.textView != nil || uiView.needsTextView
                || selectionCoordinator?.hasActiveSelection == true else {
                deferSelectionRegistration(in: uiView, coordinator: coordinator)
                return
            }
        }
        syncMountedTextView(in: uiView, coordinator: coordinator)
    }

    /// Mounts the host's text view if it has none yet, and brings it up to
    /// date with this view's inputs.
    @MainActor
    func syncMountedTextView(in uiView: SelectableTextViewHostView, coordinator: Coordinator) {
        if uiView.textView == nil {
            uiView.cancelDeferredSelectionRegistration()
            let needsCoordinatedTextView = selectionCoordinator != nil && selectionSegment != nil
            uiView.embedTextView(makeMountedTextView(needsCoordinatedTextView: needsCoordinatedTextView))
            coordinator.appliedPresentation = nil
        }

        unregisterMountedTextViewIfNeeded(in: uiView, coordinator: coordinator)

        let needsCoordinatedTextView = selectionCoordinator != nil && selectionSegment != nil
        // Not recycled: the kind only changes when a block gains or loses
        // its selection coordinator, never as rows scroll.
        if uiView.isUsingCoordinatedTextView != needsCoordinatedTextView {
            let replacementTextView = makeMountedTextView(needsCoordinatedTextView: needsCoordinatedTextView)
            replacementTextView.attributedText = uiView.mountedTextView.attributedText
            replacementTextView.selectedRange = uiView.mountedTextView.selectedRange
            uiView.setMountedTextView(replacementTextView)
            // The mounted text view instance changed. The replacement only
            // inherits attributedText/selection — font, colors, line limits,
            // wrapping, container sizing, and link attributes are applied by
            // `configure` alone, so the presentation gate must not skip it:
            // clear the applied presentation (and cached metrics derived
            // from the previous instance) so the gate below configures this
            // fresh view exactly once. Attributed content is still preserved:
            // configure's isEqual guard skips replacement when the copied
            // text already matches, so a selection-only swap does not
            // regenerate content.
            coordinator.appliedPresentation = nil
            coordinator.cachedMeasurement = nil
            coordinator.presentationGeneration &+= 1
        }

        let textView = uiView.mountedTextView
        textView.delegate = coordinator
        configureSelectionBridge(for: textView, coordinator: coordinator)

        // Presentation identity: when every input that materially affects
        // text styling/layout is unchanged, `configure` is a no-op-by-rebuild
        // (styled copy, attribute enumeration, container mutation, intrinsic
        // invalidation) — skip it entirely. Selection registration below is
        // deliberately NOT part of the gate: coordinator/segment changes must
        // keep flowing without forcing text restyling.
        let presentation = Coordinator.Presentation(view: self)
        let presentationIsUnchanged = coordinator.appliedPresentation == presentation
        if !presentationIsUnchanged {
            configure(textView, styledText: uiView.canvas?.text)
            coordinator.appliedPresentation = presentation
            coordinator.presentationGeneration &+= 1
        }

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
            applyParagraphStyle(paragraphStyle, to: styledText, in: fullRange)

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
        // A drawn host measures with its canvas even once its text view is
        // mounted, so mounting never changes its size.
        if let canvas = uiView.canvas {
            return measuredSizeCached(proposalWidth: proposal.width, coordinator: context.coordinator) { width in
                canvas.height(atWidth: width)
            }
        }
        return measuredSizeCached(
            proposalWidth: proposal.width,
            textView: uiView.mountedTextView,
            coordinator: context.coordinator
        )
    }

    /// Cached measurement entry for the SwiftUI sizing hook: an unchanged
    /// presentation measured at the same effective width returns the cached
    /// CGSize without asking TextKit to lay the text out again. Any change
    /// that can alter geometry bumps `presentationGeneration` in
    /// `updateUIViewForTests`, invalidating the entry; the cache lives on
    /// the coordinator and dies with the mounted view.
    @MainActor
    func measuredSizeCached(
        proposalWidth: CGFloat?,
        textView: UITextView,
        coordinator: Coordinator
    ) -> CGSize? {
        measuredSizeCached(proposalWidth: proposalWidth, coordinator: coordinator) { width in
            Self.measuredWrappingHeight(of: textView, at: width)
        }
    }

    @MainActor
    private func measuredSizeCached(
        proposalWidth: CGFloat?,
        coordinator: Coordinator,
        wrappingHeight: (CGFloat) -> CGFloat
    ) -> CGSize? {
        let key: Coordinator.MeasurementKey
        switch effectiveMeasurementMode(proposalWidth: proposalWidth) {
        case .none:
            return nil
        case .nonWrapping:
            key = .nonWrapping
        case .selfSizing:
            key = .selfSizing
        case .wrapping(let width):
            key = .wrapping(width: width)
        }

        if let cached = coordinator.cachedMeasurement,
           cached.generation == coordinator.presentationGeneration,
           cached.key == key {
            return cached.size
        }
        guard let size = measuredSize(proposalWidth: proposalWidth, wrappingHeight: wrappingHeight) else {
            return nil
        }
        coordinator.cachedMeasurement = Coordinator.CachedMeasurement(
            generation: coordinator.presentationGeneration,
            key: key,
            size: size
        )
        return size
    }

    /// The measurement mode derived from the view's configuration and the
    /// proposal — mirrors the branching in `measuredSize(proposalWidth:textView:)`.
    private enum MeasurementMode {
        case none
        case nonWrapping
        case selfSizing
        case wrapping(width: CGFloat)
    }

    private func effectiveMeasurementMode(proposalWidth: CGFloat?) -> MeasurementMode {
        if !wrapsLines {
            return .nonWrapping
        }
        if selfSizingWidthRange != nil {
            return .selfSizing
        }
        guard let width = proposalWidth, width > 0, width.isFinite else {
            return .none
        }
        return .wrapping(width: width)
    }

    /// Extracted sizing logic so `sizeThatFits` and unit tests share one
    /// path (`UIViewRepresentableContext` cannot be constructed outside
    /// SwiftUI).
    ///
    /// Self-sizing range (table cells): Markdown tables lay out inside a
    /// horizontal ScrollView, where width proposals are nil or transient and
    /// first-pass UIKit bounds are zero — a proposal- or bounds-derived width
    /// produces a different wrapped height on the first pass than in steady
    /// state, which is the intermittent half-line/1–2-line clipping. Instead,
    /// the measurement width is derived deterministically from the content's
    /// ideal width clamped to the table's column policy, so the first pass
    /// and every later pass report the same correct height.
    func measuredSize(proposalWidth: CGFloat?, textView: UITextView) -> CGSize? {
        measuredSize(proposalWidth: proposalWidth) { width in
            Self.measuredWrappingHeight(of: textView, at: width)
        }
    }

    private func measuredSize(proposalWidth: CGFloat?, wrappingHeight: (CGFloat) -> CGFloat) -> CGSize? {
        if !wrapsLines {
            return measureNonWrapping()
        }

        if let range = selfSizingWidthRange {
            let idealWidth = max(1, measureNonWrapping().width)
            let width = min(max(idealWidth, range.lowerBound), range.upperBound)
            return CGSize(width: width, height: wrappingHeight(width))
        }

        guard let width = proposalWidth, width > 0, width.isFinite else { return nil }
        return CGSize(width: width, height: wrappingHeight(width))
    }

    /// Shared measurement path for `sizeThatFits` and unit tests. Delegates
    /// to `UITextView.sizeThatFits` at the target width. On iOS 17+
    /// (TextKit 2) the proposed width drives wrapping independent of the
    /// text container's stored size, so no container mutation is needed.
    static func measuredWrappingHeight(of textView: UITextView, at width: CGFloat) -> CGFloat {
        TranscriptPerf.note(.textKitMeasurement)
        let measured = textView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return ceil(measured.height)
    }

    private func applyParagraphStyle(
        _ paragraphStyle: NSParagraphStyle,
        to styledText: NSMutableAttributedString,
        in fullRange: NSRange
    ) {
        guard keepsParagraphStyles else {
            styledText.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
            return
        }
        styledText.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, subrange, _ in
            if value == nil {
                styledText.addAttribute(.paragraphStyle, value: paragraphStyle, range: subrange)
            }
        }
    }

    private func configure(_ textView: UITextView, styledText precomputed: NSAttributedString? = nil) {
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

        let styledText = precomputed ?? self.styledText()

        let selectedRange = textView.selectedRange
        if !textView.attributedText.isEqual(to: styledText) {
            TranscriptPerf.note(.selectableTextViewTextRebuild)
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

    /// The text as laid out: per-run fonts and colours kept from
    /// `attributedText`, missing ones filled with the defaults, and the
    /// paragraph style applied (see `keepsParagraphStyles`).
    private func styledText() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.alignment = textAlignment

        // Single-pass styling: preserve per-run font and foregroundColor from
        // attributedText, fill only missing attributes with the configured
        // defaults, then apply paragraph style globally. This replaces the
        // previous double-pass that applied globals then overwrote with runs.
        let styledText = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: styledText.length)

        if fullRange.length > 0 {
            applyParagraphStyle(paragraphStyle, to: styledText, in: fullRange)

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
        return styledText
    }

    /// Until a drawn host mounts its text view, its selection segment waits
    /// in the coordinator, which mounts it as soon as a selection in the
    /// same message becomes visible, so the selection can reach it.
    @MainActor
    private func deferSelectionRegistration(in uiView: SelectableTextViewHostView, coordinator: Coordinator) {
        let segmentID = coordinator.selectionSegment?.id
        if let deferredCoordinator = uiView.deferredSelectionCoordinator,
           deferredCoordinator === coordinator.selectionCoordinator,
           let segmentID, uiView.deferredSelectionSegmentID == segmentID,
           deferredCoordinator.hasDeferredRegistration(segmentID, owner: uiView) {
            return
        }
        uiView.cancelDeferredSelectionRegistration()
        guard let selectionCoordinator = coordinator.selectionCoordinator, let segmentID else { return }
        selectionCoordinator.deferRegistration(segmentID: segmentID, owner: uiView) { [weak uiView] in
            uiView?.mountTextView()
        }
        uiView.deferredSelectionCoordinator = selectionCoordinator
        uiView.deferredSelectionSegmentID = segmentID
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
            let selectionSegment = hostView.mountedSelectionSegment,
            let textView = hostView.textView
        else { return }

        if selectionCoordinator !== coordinator.selectionCoordinator || selectionSegment != coordinator.selectionSegment {
            selectionCoordinator.unregister(segmentID: selectionSegment.id, textView: textView)
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

    @MainActor
    private func makeMountedTextView(needsCoordinatedTextView: Bool) -> UITextView {
        if let reused = SelectableTextViewPool.take(coordinated: needsCoordinatedTextView) {
            return reused
        }
        if needsCoordinatedTextView {
            let textView = MarkdownSelectionTextView(frame: .zero)
            Self.configureBaseTextView(textView)
            return textView
        }
        return Self.makeTextView()
    }

    @MainActor
    private static func tearDownMountedTextView(in hostView: SelectableTextViewHostView) {
        guard let textView = hostView.textView else { return }
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
        /// Every input that materially affects text presentation. When an
        /// incoming update's presentation equals the applied one, text
        /// configuration is skipped. `NSAttributedString` equality is
        /// content equality, so a stable object from the Markdown render
        /// cache compares equal cheaply while a genuinely changed value
        /// correctly invalidates.
        struct Presentation: Equatable {
            let attributedText: NSAttributedString
            let font: UIFont
            let textColor: UIColor
            let lineSpacing: CGFloat
            let maximumNumberOfLines: Int
            let wrapsLines: Bool
            let linkColor: UIColor
            let textAlignment: NSTextAlignment
            let selfSizingWidthRange: ClosedRange<CGFloat>?
            let keepsParagraphStyles: Bool

            init(view: SelectableTextView) {
                self.attributedText = view.attributedText
                self.font = view.font
                self.textColor = view.textColor
                self.lineSpacing = view.lineSpacing
                self.maximumNumberOfLines = view.maximumNumberOfLines
                self.wrapsLines = view.wrapsLines
                self.linkColor = view.linkColor
                self.textAlignment = view.textAlignment
                self.selfSizingWidthRange = view.selfSizingWidthRange
                self.keepsParagraphStyles = view.keepsParagraphStyles
            }
        }

        /// Identifies the effective measurement inputs for the sizing cache.
        /// The presentation generation (bumped whenever styling is applied or
        /// the mounted text view is swapped) covers content/font/spacing/
        /// alignment/limits; the key covers the width regime.
        enum MeasurementKey: Equatable {
            case nonWrapping
            case selfSizing
            case wrapping(width: CGFloat)
        }

        struct CachedMeasurement {
            let generation: UInt64
            let key: MeasurementKey
            let size: CGSize
        }

        var linkColor: UIColor
        weak var selectionCoordinator: MarkdownSelectionCoordinator?
        var selectionSegment: MarkdownSelectionSegmentDescriptor?

        var appliedPresentation: Presentation?
        /// What a drawn host's canvas shows, which runs ahead of
        /// `appliedPresentation` (the mounted text view's) until a touch
        /// mounts the text view.
        var canvasPresentation: Presentation?
        /// The latest inputs, for a text view mounted between updates.
        var latestView: SelectableTextView?
        var presentationGeneration: UInt64 = 0
        /// One-entry measurement cache scoped to the current presentation
        /// generation. Invalidated by any generation bump; lives and dies
        /// with the coordinator (i.e. the mounted view).
        var cachedMeasurement: CachedMeasurement?
        /// The environment's link opener, so in-app links (a voice call's
        /// job link) open inside Conduit; others fall through to the system.
        var openURL: OpenURLAction?
        /// Set inside a chat: the selection menu then offers Quote (#385).
        var quoteAction: ChatQuoteAction?

        init(
            linkColor: UIColor,
            selectionCoordinator: MarkdownSelectionCoordinator?,
            selectionSegment: MarkdownSelectionSegmentDescriptor?
        ) {
            self.linkColor = linkColor
            self.selectionCoordinator = selectionCoordinator
            self.selectionSegment = selectionSegment
        }

        @MainActor
        func mountTextView(in hostView: SelectableTextViewHostView) {
            latestView?.syncMountedTextView(in: hostView, coordinator: self)
        }

        // NOTE: the selection menu is only extended, never replaced, and only
        // inside a chat. `menuConfigurationFor` is for text items (links,
        // attachments), not the selection menu; `editMenuForTextIn` below is
        // the selection one. Cross-block selections dismiss the owner's first
        // responder (see MarkdownSelectionCoordinator), so they never present
        // the system menu at all: Copy and Quote go through the
        // coordinator-owned pill, while within-block selections keep the
        // native menu.

        /// Inside a chat, the native selection menu gains Quote right after
        /// the standard edit group (Copy), which puts the selection in the
        /// composer as a `>` quote (#385). Elsewhere the default menu shows.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let quoteAction, quoteAction.isAvailable, range.length > 0 else { return nil }
            let quote = UIAction(
                title: AppLocalization.string("Quote"),
                image: UIImage(systemName: "text.quote")
            ) { [weak textView] _ in
                guard let textView else { return }
                // The selection as it is now, should the text have changed
                // under the open menu.
                let current = textView.selectedRange
                Self.quoteSelection(in: textView, range: current.length > 0 ? current : range, with: quoteAction)
            }
            return UIMenu(children: Self.editMenuElements(suggestedActions, adding: quote))
        }

        static func editMenuElements(_ suggestedActions: [UIMenuElement], adding quote: UIMenuElement) -> [UIMenuElement] {
            var elements = suggestedActions
            let standardEdit = elements.firstIndex { ($0 as? UIMenu)?.identifier == .standardEdit }
            elements.insert(quote, at: standardEdit.map { $0 + 1 } ?? 0)
            return elements
        }

        /// Hands the selected text to the composer and clears the selection,
        /// which dismisses the menu. A selection spanning blocks quotes all
        /// of it, matching what Copy would take. Whitespace alone has nothing
        /// to quote, so the selection then stays as it was, as on the pill.
        @MainActor
        static func quoteSelection(in textView: UITextView, range: NSRange, with quoteAction: ChatQuoteAction) {
            let fullText = textView.attributedText ?? NSAttributedString()
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: fullText.length))
            let selected = (textView as? MarkdownSelectionTextView)?.coordinatedCopiedAttributedText()?.string
                ?? MarkdownProseRun.copyableText(fullText.attributedSubstring(from: clamped)).string
            guard selected.contains(where: { !$0.isWhitespace }) else { return }
            (textView as? MarkdownSelectionTextView)?.selectionCoordinator?.clearSelection()
            textView.selectedRange = NSRange(location: clamped.location, length: 0)
            textView.resignFirstResponder()
            quoteAction(selected)
        }

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
                if let openURL {
                    openURL(url)
                } else {
                    UIApplication.shared.open(url)
                }
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
        guard let copied = coordinatedCopiedAttributedText() ?? MarkdownProseRun.copiedSelection(in: self) else {
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

    /// Clears what a touch in progress left behind, before the pool hands
    /// this view to another block.
    func prepareForReuse() {
        gestureRecognizers?
            .compactMap { $0 as? MarkdownSelectionObserverGestureRecognizer }
            .forEach { $0.prepareForReuse() }
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

    fileprivate func prepareForReuse() {
        isDrivingSelectionTouch = false
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

/// Text views whose rows scrolled out of view, kept for the rows that
/// scroll in next. Making a UITextView is the larger part of what a Markdown
/// block costs to mount, and a chat takes rows down and builds them again
/// all the time it scrolls. Only the empty view is kept: teardown clears its
/// delegate and coordinator, and recycling drops its text and selection,
/// so a reused view starts out like a new one.
@MainActor
enum SelectableTextViewPool {
    /// Rows leave at one end as they enter at the other, so the pool only
    /// has to cover a burst, such as a jump to the latest message.
    static let capacity = 32
    private static var plain: [UITextView] = []
    private static var coordinated: [UITextView] = []
    /// Emptied on a memory warning, and in the background, where no chat
    /// scrolls.
    private static let drainObservers = [
        UIApplication.didReceiveMemoryWarningNotification,
        UIApplication.didEnterBackgroundNotification,
    ].map { name in
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            // Delivered on the main queue.
            MainActor.assumeIsolated { SelectableTextViewPool.removeAll() }
        }
    }

    static func take(coordinated wantsCoordinated: Bool) -> UITextView? {
        _ = drainObservers
        return wantsCoordinated ? coordinated.popLast() : plain.popLast()
    }

    /// Call after `tearDownMountedTextView`, which clears the delegate,
    /// the coordinator and the selection registration.
    static func recycle(_ textView: UITextView) {
        assert(
            textView.delegate == nil && (textView as? MarkdownSelectionTextView)?.onTouchBegan == nil,
            "recycle after tearDownMountedTextView"
        )
        _ = drainObservers
        // Pooled twice, one view would be handed to two blocks.
        guard !plain.contains(where: { $0 === textView }),
              !coordinated.contains(where: { $0 === textView })
        else { return }
        textView.removeFromSuperview()
        // The selection overlay's layoutManager calls move a text view to
        // TextKit 1, which lays text out a little differently from the
        // drawing a chat mounts text views over (SelectableTextCanvas).
        guard textView.textLayoutManager != nil else { return }
        textView.attributedText = NSAttributedString()
        textView.selectedRange = NSRange(location: 0, length: 0)
        if let coordinatedTextView = textView as? MarkdownSelectionTextView {
            coordinatedTextView.prepareForReuse()
            if coordinated.count < capacity { coordinated.append(textView) }
        } else if plain.count < capacity {
            plain.append(textView)
        }
    }

    static func removeAll() {
        plain.removeAll()
        coordinated.removeAll()
    }
}

final class SelectableTextViewHostView: UIView {
    /// Draws the text while the host has no text view: only hosts made to
    /// draw until touched have one (`SelectableTextView.drawsUntilTouched`).
    let canvas: SelectableTextCanvas?
    private(set) var textView: UITextView?
    /// Set on a drawn host, which mounts its text view through it. Held
    /// strongly: nothing it holds leads back here.
    var coordinator: SelectableTextView.Coordinator?
    /// Mount the text view at the next update, whatever touches it.
    var needsTextView = false
    weak var mountedSelectionCoordinator: MarkdownSelectionCoordinator?
    var mountedSelectionSegment: MarkdownSelectionSegmentDescriptor?
    /// Where a drawn host's segment waits for its text view.
    weak var deferredSelectionCoordinator: MarkdownSelectionCoordinator?
    var deferredSelectionSegmentID: String?

    /// The tint the text view draws its selection in; nil inherits the
    /// accent. A pooled text view may arrive tinted by its last mount, so
    /// every mounted view gets this value.
    var selectionTint: UIColor? {
        didSet {
            // The tint is a shared static colour, so equality is identity.
            guard selectionTint != oldValue else { return }
            // A drawn host's text view takes it when it mounts.
            textView?.tintColor = selectionTint
        }
    }

    init(textView: UITextView) {
        self.canvas = nil
        self.textView = textView
        super.init(frame: .zero)
        textView.tintColor = nil
        embedMountedTextView()
    }

    init(canvas: SelectableTextCanvas) {
        self.canvas = canvas
        self.textView = nil
        super.init(frame: .zero)
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The text view, mounted first if the host only drew its text so far.
    var mountedTextView: UITextView {
        textView ?? mountTextView()
    }

    var isUsingCoordinatedTextView: Bool {
        textView is MarkdownSelectionTextView
    }

    /// The text shown, without mounting a text view to read it.
    var displayedText: String {
        textView?.text ?? canvas?.text.string ?? ""
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas?.frame = bounds
    }

    /// Assistive technology gets the text view, whose links are targets:
    /// Voice Control and Full Keyboard Access can't be detected, so a drawn
    /// host mounts its text view when one asks for its elements.
    override var accessibilityElements: [Any]? {
        get {
            guard canvas != nil else { return super.accessibilityElements }
            return [mountedTextView]
        }
        set { super.accessibilityElements = newValue }
    }

    /// A touch gets the real text view, mounted in place of the drawing as
    /// the touch begins: links, selection, menus and drags then behave
    /// exactly as they always have. Scrolling stays cheap, as the finger is
    /// still.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if textView == nil, canvas != nil, event?.type == .touches,
           isUserInteractionEnabled, !isHidden, alpha > 0.01,
           self.point(inside: point, with: event) {
            mountTextView()
        }
        return super.hitTest(point, with: event)
    }

    @discardableResult
    func mountTextView() -> UITextView {
        if let textView { return textView }
        coordinator?.mountTextView(in: self)
        if let textView { return textView }
        // Made outside SwiftUI, with no inputs to configure from.
        let fallback = SelectableTextView.makeTextView()
        fallback.attributedText = canvas?.text ?? NSAttributedString()
        embedTextView(fallback)
        return fallback
    }

    /// Mounts a drawn host's text view in place of its canvas. The text
    /// view lays out and draws in the commit that hides the canvas, and
    /// the two draw the same glyphs in the same places, so nothing on
    /// screen changes; left showing, the canvas would draw every glyph
    /// twice and thicken the text.
    func embedTextView(_ textView: UITextView) {
        guard self.textView == nil else { return }
        self.textView = textView
        textView.tintColor = selectionTint
        embedMountedTextView()
        textView.frame = bounds
        canvas?.isHidden = true
    }

    func cancelDeferredSelectionRegistration() {
        if let coordinator = deferredSelectionCoordinator, let segmentID = deferredSelectionSegmentID {
            coordinator.cancelDeferredRegistration(segmentID: segmentID, owner: self)
        }
        deferredSelectionCoordinator = nil
        deferredSelectionSegmentID = nil
    }

    func setMountedTextView(_ textView: UITextView) {
        guard self.textView !== textView else { return }
        self.textView?.removeFromSuperview()
        self.textView = textView
        textView.tintColor = selectionTint
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
        guard let textView else { return }
        addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

private struct SelectableTextDrawsUntilTouchedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// On in a chat, where text draws without a UITextView until something
    /// needs one (`SelectableTextView.drawsUntilTouched`).
    var selectableTextDrawsUntilTouched: Bool {
        get { self[SelectableTextDrawsUntilTouchedKey.self] }
        set { self[SelectableTextDrawsUntilTouchedKey.self] = newValue }
    }
}

private struct TextSelectionTintKey: EnvironmentKey {
    static let defaultValue: UIColor? = nil
}

extension EnvironmentValues {
    /// The selection tint for chat text drawn on a coloured surface (#697):
    /// a sent bubble is the accent, the colour selections take by default.
    var textSelectionTint: UIColor? {
        get { self[TextSelectionTintKey.self] }
        set { self[TextSelectionTintKey.self] = newValue }
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
