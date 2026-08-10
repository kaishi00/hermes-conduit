import SwiftUI
import UIKit

/// A non-editable UIKit text surface gives chat text true character-range
/// selection on the iOS versions Conduit supports. SwiftUI's native text
/// selection API is intentionally kept for controls outside this surface,
/// but it cannot select a range within a Text view on older OS releases.
struct SelectableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let font: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat
    let maximumNumberOfLines: Int
    let wrapsLines: Bool
    let linkColor: UIColor

    init(
        attributedText: NSAttributedString,
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: UIColor = .link
    ) {
        self.attributedText = attributedText
        self.font = font
        self.textColor = textColor
        self.lineSpacing = lineSpacing
        self.maximumNumberOfLines = maximumNumberOfLines
        self.wrapsLines = wrapsLines
        self.linkColor = linkColor
    }

    init(
        attributedText: AttributedString,
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: UIColor = .link
    ) {
        self.init(
            attributedText: Self.bridge(attributedText, defaultFont: font, defaultColor: textColor, linkColor: linkColor),
            font: font,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maximumNumberOfLines: maximumNumberOfLines,
            wrapsLines: wrapsLines,
            linkColor: linkColor
        )
    }

    init(
        text: String,
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        lineSpacing: CGFloat = 0,
        maximumNumberOfLines: Int = 0,
        wrapsLines: Bool = true,
        linkColor: UIColor = .link
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
            linkColor: linkColor
        )
    }

    /// Exposed for unit tests so the behavior that matters for the feature is
    /// tested directly instead of being inferred from a SwiftUI modifier.
    static func makeTextView() -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(linkColor: linkColor)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
        configure(textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.linkColor = linkColor
        configure(textView)
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if !wrapsLines {
            return measureNonWrapping()
        }

        guard let width = proposal.width, width > 0 else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(measured.height))
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

        init(linkColor: UIColor) {
            self.linkColor = linkColor
        }

        // shouldInteractWith is formally deprecated in iOS 17, but it remains
        // the only UITextViewDelegate API for intercepting URL taps. The
        // replacement (UITextInteraction edit-menu API) does not provide a
        // link-activation callback. This annotation silences the deprecation
        // warning while keeping the working behavior.
        @available(iOS, deprecated: 17.0)
        func textView(
            _ textView: UITextView,
            shouldInteractWith url: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            UIApplication.shared.open(url)
            return false
        }
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
