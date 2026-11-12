import SwiftUI
import UIKit

/// The Folder's text editor (issue 1438): monospaced, numbered lines,
/// colored as the chat colors code, the indent carried to a new line, and
/// Find (Cmd-F on a keyboard, or the toolbar's search button). No
/// autocorrect, smart quotes or capitals, which break code.
struct WorkspaceCodeEditor: UIViewRepresentable {
    @Binding var text: String
    let language: String
    /// Bumped to show the find bar.
    var findRequest = 0

    /// Past this many UTF-16 units the editor stops coloring, so typing in a
    /// large file stays quick.
    static let highlightLimit = 200_000

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WorkspaceCodeTextView {
        let view = WorkspaceCodeTextView()
        view.delegate = context.coordinator
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.isFindInteractionEnabled = true
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.font = WorkspaceCodeTextView.codeFont
        view.textColor = .label
        view.text = text
        context.coordinator.highlight(view, now: true)
        return view
    }

    func updateUIView(_ view: WorkspaceCodeTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            context.coordinator.language = language
            context.coordinator.highlight(view, now: true)
        } else if context.coordinator.language != language {
            // The file's language can arrive after its draft (a tab
            // reopened while the file loads again).
            context.coordinator.language = language
            context.coordinator.highlight(view, now: true)
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: WorkspaceCodeEditor
        var findRequest: Int
        /// The language the text was last colored as.
        var language: String
        private var pending: Task<Void, Never>?

        init(_ parent: WorkspaceCodeEditor) {
            self.parent = parent
            self.findRequest = parent.findRequest
            self.language = parent.language
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            highlight(textView, now: false)
            (textView as? WorkspaceCodeTextView)?.gutter.setNeedsDisplay()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? WorkspaceCodeTextView)?.gutter.setNeedsDisplay()
        }

        /// A new line starts at the indent of the one before it.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            guard replacement == "\n" else { return true }
            let source = textView.text as NSString
            let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
            let indent = WorkspaceCodeEditor.indent(of: source.substring(with: NSRange(location: lineStart, length: range.location - lineStart)))
            guard !indent.isEmpty else { return true }
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let replaced = textView.textRange(from: start, to: end) else { return true }
            // As typed, so undo takes it back in one step.
            textView.replace(replaced, withText: "\n" + indent)
            return false
        }

        /// Colors the text as the chat colors code, after typing settles.
        func highlight(_ textView: UITextView, now: Bool) {
            pending?.cancel()
            let language = parent.language
            pending = Task { @MainActor [weak textView] in
                if !now { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled, let textView else { return }
                WorkspaceCodeEditor.color(textView.textStorage, language: language)
            }
        }
    }

    /// Whether `language` (Hermes' name for it) is code to color; plain
    /// text and Markdown stay plain.
    static func colorsCode(_ language: String) -> Bool {
        !["", "text", "plaintext", "plain", "markdown", "md"].contains(language.lowercased())
    }

    static func indent(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    /// Only colors change: the selection, undo and the cursor stay as they are.
    @MainActor
    static func color(_ storage: NSTextStorage, language: String) {
        let whole = NSRange(location: 0, length: storage.length)
        guard storage.length > 0 else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: UIColor.label, range: whole)
        if storage.length <= highlightLimit, colorsCode(language) {
            let bridged = SelectableTextView.bridge(
                SyntaxHighlighter.highlight(storage.string, language: language),
                defaultFont: WorkspaceCodeTextView.codeFont,
                defaultColor: .label,
                linkColor: .label
            )
            if bridged.length == storage.length {
                bridged.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                    if let value { storage.addAttribute(.foregroundColor, value: value, range: range) }
                }
            }
        }
        storage.endEditing()
    }
}

/// A text view with its line numbers in a gutter on the left.
final class WorkspaceCodeTextView: UITextView {
    static var codeFont: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    let gutter = WorkspaceLineGutter()

    init() {
        // TextKit 1, whose line fragments the gutter reads.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        gutter.textView = self
        addSubview(gutter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = gutter.width(for: text)
        if textContainerInset.left != width + 6 {
            textContainerInset = UIEdgeInsets(top: 8, left: width + 6, bottom: 8, right: 8)
        }
        // Pinned to the left edge while the text scrolls under it.
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: width, height: bounds.height)
        bringSubviewToFront(gutter)
        gutter.setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            font = Self.codeFont
            setNeedsLayout()
        }
    }
}

/// The numbers of the lines on screen, a wrapped line numbered once.
final class WorkspaceLineGutter: UIView {
    weak var textView: UITextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var numberFont: UIFont {
        UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
    }

    func width(for text: String) -> CGFloat {
        let lines = max(1, text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
        let sample = String(repeating: "8", count: max(2, String(lines).count)) as NSString
        return ceil(sample.size(withAttributes: [.font: numberFont]).width) + 12
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layout = textView.layoutManager
        let source = textView.text as NSString
        let visible = CGRect(origin: textView.contentOffset, size: textView.bounds.size)
            .offsetBy(dx: -textView.textContainerInset.left, dy: -textView.textContainerInset.top)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: textView.textContainer)
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: UIColor.tertiaryLabel]
        let firstCharacter = min(layout.characterIndexForGlyph(at: glyphs.location), source.length)
        var line = 1 + Self.newlines(in: source, before: firstCharacter)
        var lastLineStart = -1
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, glyphRange, _ in
            let character = layout.characterIndexForGlyph(at: glyphRange.location)
            let lineStart = source.length == 0 ? 0
                : source.lineRange(for: NSRange(location: min(character, source.length - 1), length: 0)).location
            if lastLineStart >= 0, lineStart != lastLineStart { line += 1 }
            lastLineStart = lineStart
            // A wrapped line's later fragments have no number of their own.
            guard character == lineStart else { return }
            self.draw(line, at: used.minY, height: used.height, attributes: attributes, in: textView)
        }
        // The empty line after a final newline.
        let extra = layout.extraLineFragmentUsedRect
        if !extra.isEmpty, source.length == 0 || source.hasSuffix("\n") {
            draw(1 + Self.newlines(in: source, before: source.length), at: extra.minY, height: extra.height,
                 attributes: attributes, in: textView)
        }
    }

    private func draw(_ line: Int, at top: CGFloat, height: CGFloat,
                      attributes: [NSAttributedString.Key: Any], in textView: UITextView) {
        let number = "\(line)" as NSString
        let size = number.size(withAttributes: attributes)
        let y = top + textView.textContainerInset.top - textView.contentOffset.y
        number.draw(at: CGPoint(x: bounds.width - size.width - 6, y: y + max(0, height - size.height) / 2),
                    withAttributes: attributes)
    }

    static func newlines(in source: NSString, before end: Int) -> Int {
        var count = 0
        var search = NSRange(location: 0, length: min(end, source.length))
        while true {
            let found = source.range(of: "\n", options: .literal, range: search)
            guard found.location != NSNotFound else { return count }
            count += 1
            search = NSRange(location: found.location + 1, length: search.upperBound - found.location - 1)
        }
    }
}
