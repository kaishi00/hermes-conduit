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
        /// The tokens are found off the main thread (issue 2354): only
        /// setting their colors runs here, and an edit while they're found
        /// cancels them for the next pass. A small file opening is colored
        /// at once, so it never shows plain first.
        func highlight(_ textView: UITextView, now: Bool) {
            pending?.cancel()
            let language = parent.language
            let storage = textView.textStorage
            guard storage.length <= WorkspaceCodeEditor.highlightLimit,
                  WorkspaceCodeEditor.colorsCode(language) else {
                pending = nil
                WorkspaceCodeEditor.paint(storage, tokens: [])
                return
            }
            if now, storage.length <= WorkspaceCodeEditor.colorsAtOnceLimit {
                pending = nil
                WorkspaceCodeEditor.paint(storage, tokens: SyntaxHighlighter.coloredTokens(in: storage.string) ?? [])
                return
            }
            pending = Task { @MainActor [weak storage] in
                if !now { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled, let source = storage?.string else { return }
                let length = (source as NSString).length
                guard let tokens = await SyntaxHighlighter.coloredTokensDetached(in: source),
                      !Task.isCancelled, let storage, storage.length == length else { return }
                WorkspaceCodeEditor.paint(storage, tokens: tokens)
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

    /// A file up to this many UTF-16 units is colored as it opens, before
    /// it first draws; a bigger one draws plain until its colors are found.
    static let colorsAtOnceLimit = 16_000

    /// Only colors change: the selection, undo and the cursor stay as they are.
    @MainActor
    static func paint(_ storage: NSTextStorage, tokens: [(range: NSRange, kind: SyntaxHighlighter.TokenKind)]) {
        guard storage.length > 0 else { return }
        var colors: [SyntaxHighlighter.TokenKind: UIColor] = [:]
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: UIColor.label, range: NSRange(location: 0, length: storage.length))
        for token in tokens where NSMaxRange(token.range) <= storage.length {
            let color = colors[token.kind] ?? UIColor(token.kind.color)
            colors[token.kind] = color
            storage.addAttribute(.foregroundColor, value: color, range: token.range)
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
    /// Where each line starts, found again only after the text changes
    /// (issue 2354): the gutter reads it every scroll frame.
    let lines = WorkspaceLineIndex()

    init() {
        // TextKit 1, whose line fragments the gutter reads.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        storage.delegate = self
        gutter.textView = self
        gutter.lines = lines
        addSubview(gutter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = gutter.width(forLines: lines.count(in: textStorage.mutableString))
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

extension WorkspaceCodeTextView: NSTextStorageDelegate {
    // Colors change attributes only, so a pass of them keeps the index.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { lines.invalidate() }
    }
}

/// Where each line of a text starts (UTF-16 offsets), found in one pass
/// when first asked after a change, so a line's number is a binary search
/// rather than a count of the newlines above it.
final class WorkspaceLineIndex {
    private var starts: [Int]?

    func invalidate() { starts = nil }

    /// The number of lines, the empty one after a final newline included.
    func count(in source: NSString) -> Int { lineStarts(in: source).count }

    /// The 1-based number of the line holding `index`.
    func line(at index: Int, in source: NSString) -> Int {
        let starts = lineStarts(in: source)
        // The number of line starts at or before `index`.
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= index { low = middle + 1 } else { high = middle }
        }
        return max(1, low)
    }

    private func lineStarts(in source: NSString) -> [Int] {
        if let starts { return starts }
        var found = [0]
        var search = NSRange(location: 0, length: source.length)
        while true {
            let newline = source.range(of: "\n", options: .literal, range: search)
            guard newline.location != NSNotFound else { break }
            found.append(newline.location + 1)
            search = NSRange(location: newline.location + 1, length: source.length - newline.location - 1)
        }
        starts = found
        return found
    }
}

/// The numbers of the lines on screen, a wrapped line numbered once.
final class WorkspaceLineGutter: UIView {
    weak var textView: UITextView?
    weak var lines: WorkspaceLineIndex?

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

    /// The width measured for a count of digits at a text size: a layout
    /// pass runs every scroll frame.
    private var measuredWidth: (digits: Int, font: UIFont, width: CGFloat)?

    func width(forLines lines: Int) -> CGFloat {
        let digits = max(2, String(max(1, lines)).count)
        let font = numberFont
        if let measuredWidth, measuredWidth.digits == digits, measuredWidth.font == font { return measuredWidth.width }
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 12
        measuredWidth = (digits, font, width)
        return width
    }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layout = textView.layoutManager
        let source = textView.textStorage.mutableString
        let lines = self.lines ?? WorkspaceLineIndex()
        let visible = CGRect(origin: textView.contentOffset, size: textView.bounds.size)
            .offsetBy(dx: -textView.textContainerInset.left, dy: -textView.textContainerInset.top)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: textView.textContainer)
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: UIColor.tertiaryLabel]
        let firstCharacter = min(layout.characterIndexForGlyph(at: glyphs.location), source.length)
        var line = lines.line(at: firstCharacter, in: source)
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
            draw(lines.count(in: source), at: extra.minY, height: extra.height,
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
}
