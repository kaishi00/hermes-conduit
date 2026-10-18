import UIKit

/// Draws a SelectableTextView's text until the UITextView itself is needed.
/// Making, laying out and drawing a UITextView costs many times what its
/// text costs to draw, and a chat mounts text afresh as rows scroll in,
/// though most of it is only ever read. TextKit 2 lays the text out here as
/// it does inside the text view, so sizes, line breaks and glyphs land where
/// the text view puts them once a touch mounts it in place of this drawing
/// (SelectableTextViewHostView).
final class SelectableTextCanvas: UIView {
    /// Each tile is its own backing store, kept well under the largest a
    /// layer can hold: a long answer can be thousands of points tall.
    static let tileHeight: CGFloat = 1024
    /// Wide enough that no line breaks: text that doesn't wrap, and the
    /// text's natural size, are laid out at it.
    static let unboundedWidth: CGFloat = 100_000

    private let contentStorage = NSTextContentStorage()
    private let textLayoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(
        size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
    )
    private let linkStyle = SelectableTextCanvasLinkStyle()
    private(set) var text = NSAttributedString()
    private var font = UIFont.preferredFont(forTextStyle: .body)
    private var wrapsLines = true
    /// The width the text is laid out at; nil after the text changes.
    private var layoutWidth: CGFloat?
    /// The text's size on unbroken lines; nil after the text changes.
    private var cachedNaturalSize: CGSize?
    private var tiles: [SelectableTextCanvasTile] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        textContainer.lineFragmentPadding = 0
        textLayoutManager.textContainer = textContainer
        textLayoutManager.delegate = linkStyle
        contentStorage.addTextLayoutManager(textLayoutManager)
        contentStorage.primaryTextLayoutManager = textLayoutManager
        // Assistive technology reads the text view instead, whose links
        // stay targets (SelectableTextViewHostView.accessibilityElements).
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitAccessibilityContrast.self,
            UITraitDisplayScale.self,
        ]) { (canvas: SelectableTextCanvas, _: UITraitCollection) in
            canvas.redrawTiles()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// What the text view would show: `text` already carries every font,
    /// colour and paragraph style; the rest mirrors the text view's
    /// container and link attributes.
    func configure(
        text: NSAttributedString,
        font: UIFont,
        linkColor: UIColor,
        maximumNumberOfLines: Int,
        wrapsLines: Bool
    ) {
        if !self.text.isEqual(to: text) {
            self.text = text
            contentStorage.attributedString = text
            layoutWidth = nil
            cachedNaturalSize = nil
        }
        if self.font != font {
            self.font = font
            cachedNaturalSize = nil
        }
        linkStyle.attributes = [
            .foregroundColor: linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let lineBreakMode: NSLineBreakMode = maximumNumberOfLines > 0
            ? .byTruncatingTail
            : (wrapsLines ? .byWordWrapping : .byClipping)
        if textContainer.maximumNumberOfLines != maximumNumberOfLines
            || textContainer.lineBreakMode != lineBreakMode
            || self.wrapsLines != wrapsLines {
            textContainer.maximumNumberOfLines = maximumNumberOfLines
            textContainer.lineBreakMode = lineBreakMode
            self.wrapsLines = wrapsLines
            layoutWidth = nil
            cachedNaturalSize = nil
        }
        setNeedsLayout()
        redrawTiles()
    }

    /// The height the text view would take at `width`.
    func height(atWidth width: CGFloat) -> CGFloat {
        TranscriptPerf.note(.textKitMeasurement)
        guard text.length > 0 else { return Self.emptyHeight(for: font) }
        layOut(atWidth: width)
        return ceil(textLayoutManager.usageBoundsForTextContainer.height)
    }

    /// The size the text takes when no width bounds it, which a text view
    /// pinned in its host gave as its intrinsic size: a short sent message's
    /// bubble fits its text instead of the widest width it's offered.
    func naturalSize() -> CGSize {
        if let cachedNaturalSize { return cachedNaturalSize }
        TranscriptPerf.note(.textKitMeasurement)
        let size: CGSize
        if text.length == 0 {
            size = CGSize(width: 1, height: Self.emptyHeight(for: font))
        } else {
            layOut(atWidth: Self.unboundedWidth)
            let bounds = textLayoutManager.usageBoundsForTextContainer
            size = CGSize(width: max(1, ceil(bounds.width)), height: ceil(bounds.height))
        }
        cachedNaturalSize = size
        return size
    }

    /// An empty text view still takes a line's height, where TextKit 2
    /// gives an empty document none; measured once per font.
    private static var emptyHeights: [UIFont: CGFloat] = [:]

    private static func emptyHeight(for font: UIFont) -> CGFloat {
        if let height = emptyHeights[font] { return height }
        let textView = SelectableTextView.makeTextView()
        textView.font = font
        let height = ceil(textView.sizeThatFits(
            CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        ).height)
        emptyHeights[font] = height
        return height
    }

    /// Hidden once the text view mounts, the canvas only measures: its
    /// tiles and their backing stores go.
    override var isHidden: Bool {
        didSet {
            if isHidden != oldValue { setNeedsLayout() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = wrapsLines ? bounds.width : Self.unboundedWidth
        if !isHidden, layoutWidth != width {
            layOut(atWidth: width)
            redrawTiles()
        }
        let count = !isHidden && bounds.height > 0 ? Int(ceil(bounds.height / Self.tileHeight)) : 0
        while tiles.count < count {
            let tile = SelectableTextCanvasTile(canvas: self)
            tiles.append(tile)
            addSubview(tile)
        }
        while tiles.count > count {
            tiles.removeLast().removeFromSuperview()
        }
        for (index, tile) in tiles.enumerated() {
            let top = CGFloat(index) * Self.tileHeight
            let frame = CGRect(x: 0, y: top, width: bounds.width, height: min(Self.tileHeight, bounds.height - top))
            if tile.frame != frame {
                tile.frame = frame
                tile.setNeedsDisplay()
            }
        }
    }

    private func layOut(atWidth width: CGFloat) {
        guard layoutWidth != width else { return }
        layoutWidth = width
        textContainer.size = CGSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
    }

    private func redrawTiles() {
        tiles.forEach { $0.setNeedsDisplay() }
    }

    /// Draws the fragments that reach into `rect`, in this view's points;
    /// the context is the tile's, whose origin sits at `tileOrigin`.
    fileprivate func drawText(in rect: CGRect, tileOrigin: CGPoint, context: CGContext) {
        guard text.length > 0 else { return }
        layOut(atWidth: wrapsLines ? bounds.width : Self.unboundedWidth)
        context.saveGState()
        context.translateBy(x: -tileOrigin.x, y: -tileOrigin.y)
        textLayoutManager.enumerateTextLayoutFragments(
            from: textLayoutManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            let drawn = fragment.renderingSurfaceBounds.offsetBy(dx: frame.minX, dy: frame.minY).union(frame)
            if drawn.minY > rect.maxY { return false }
            if drawn.maxY >= rect.minY {
                fragment.draw(at: frame.origin, in: context)
            }
            return true
        }
        context.restoreGState()
    }

    /// Where the first character of `range` is drawn, in this view's
    /// points: for tests that hold the drawing against the text view's.
    func firstRectForTests(characterRange range: NSRange) -> CGRect? {
        layOut(atWidth: wrapsLines ? bounds.width : Self.unboundedWidth)
        return Self.firstRectForTests(characterRange: range, in: textLayoutManager)
    }

    /// The same for any TextKit 2 layout, such as a text view's.
    static func firstRectForTests(characterRange range: NSRange, in textLayoutManager: NSTextLayoutManager) -> CGRect? {
        guard let start = textLayoutManager.location(textLayoutManager.documentRange.location, offsetBy: range.location),
              let end = textLayoutManager.location(start, offsetBy: max(range.length, 1)),
              let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        var first: CGRect?
        textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            first = frame
            return false
        }
        return first
    }
}

/// UITextView draws links with its `linkTextAttributes`; the canvas draws
/// them the same way.
private final class SelectableTextCanvasLinkStyle: NSObject, NSTextLayoutManagerDelegate {
    var attributes: [NSAttributedString.Key: Any] = [:]

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        renderingAttributesForLink link: Any,
        at location: any NSTextLocation,
        defaultAttributes renderingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any]? {
        attributes
    }
}

private final class SelectableTextCanvasTile: UIView {
    private weak var canvas: SelectableTextCanvas?

    init(canvas: SelectableTextCanvas) {
        self.canvas = canvas
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let canvas, let context = UIGraphicsGetCurrentContext() else { return }
        canvas.drawText(
            in: rect.offsetBy(dx: frame.minX, dy: frame.minY),
            tileOrigin: frame.origin,
            context: context
        )
    }
}
