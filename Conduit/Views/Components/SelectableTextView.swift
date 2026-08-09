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
            attributedText: NSAttributedString(attributedText),
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

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        if !wrapsLines {
            let measured = uiView.attributedText.boundingRect(
                with: CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            return CGSize(
                width: max(1, ceil(measured.width)),
                height: max(uiView.font?.lineHeight ?? 1, ceil(measured.height))
            )
        }

        guard let width = proposal.width, width > 0 else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(measured.height))
    }

    private func configure(_ textView: UITextView) {
        textView.font = font
        textView.textColor = textColor
        textView.textContainer.widthTracksTextView = wrapsLines
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

        let styledText = NSMutableAttributedString(attributedString: attributedText)
        let range = NSRange(location: 0, length: styledText.length)
        if range.length > 0 {
            styledText.addAttribute(.font, value: font, range: range)
            styledText.addAttribute(.foregroundColor, value: textColor, range: range)
            styledText.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        }

        // Markdown's emphasis is represented by AttributedString runs. Keep
        // the UIKit surface visually close to the existing SwiftUI renderer
        // while still using a single selectable text layout.
        attributedText.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            if let runFont = value as? UIFont {
                styledText.addAttribute(.font, value: runFont, range: subrange)
            }
        }
        attributedText.enumerateAttribute(.foregroundColor, in: range, options: []) { value, subrange, _ in
            if let runColor = value as? UIColor {
                styledText.addAttribute(.foregroundColor, value: runColor, range: subrange)
            }
        }

        if !textView.attributedText.isEqual(to: styledText) {
            textView.attributedText = styledText
        }
        textView.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var linkColor: UIColor

        init(linkColor: UIColor) {
            self.linkColor = linkColor
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            UIApplication.shared.open(URL)
            return false
        }
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
