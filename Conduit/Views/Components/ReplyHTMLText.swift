//
//  ReplyHTMLText.swift
//  Conduit
//
//  The text tags a reply writes, drawn (ReplyHTML): each paired tag becomes
//  a mark in the text Foundation parses, then the style it names.
//

import Foundation
import SwiftUI

extension ReplyHTML {
    // MARK: Text tags

    enum TextTag: Equatable {
        case bold, italic, underline, strikethrough, highlight, key, lowered, raised
        case colored(foreground: String?, background: String?)
    }

    private static let textTagNames: [String: TextTag] = [
        "b": .bold, "strong": .bold, "i": .italic, "em": .italic, "u": .underline, "ins": .underline,
        "s": .strikethrough, "del": .strikethrough, "strike": .strikethrough, "mark": .highlight, "kbd": .key,
        "sub": .lowered, "sup": .raised
    ]

    private static let inlineTag = compiled(
        #"<(/?)([a-zA-Z][a-zA-Z0-9]*)((?:\s+[^\s"'>/=]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)\s*(/?)>"#)
    private static let attribute = compiled(#"([^\s"'>/=]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)

    /// Each drawn tag is a mark in the text Foundation parses: a
    /// private-use character naming the style it opens or closes, taken out
    /// again once the text is parsed (`applying`). `<br>` is its own mark.
    private static let openBase: UInt32 = 0xE000
    private static let closeBase: UInt32 = 0xE800
    private static let lineBreakMark: Character = "\u{F8FF}"
    private static let maximumStyles = 0x800

    /// `source` with its drawn tags as marks, and the style each opens; nil
    /// when it has none.
    static func marking(_ source: String) -> (text: String, styles: [TextTag])? {
        guard source.contains("<") else { return nil }
        // Text already holding a mark's character would be read as one: drawn as written instead.
        guard !source.unicodeScalars.contains(where: { (openBase..<(closeBase + UInt32(maximumStyles))).contains($0.value) || $0 == lineBreakMark.unicodeScalars.first! }) else { return nil }
        let ns = source as NSString
        let code = codeSpans(in: source)
        struct Found { let range: NSRange; let name: String; let closing: Bool; let tag: TextTag? }
        var tags: [Found] = []
        for match in inlineTag.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            if code.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            let name = ns.substring(with: match.range(at: 2)).lowercased()
            let closing = match.range(at: 1).length > 0
            if name == "br", !closing {
                tags.append(Found(range: match.range, name: name, closing: false, tag: nil))
                continue
            }
            let attributes = match.range(at: 3).length > 0 ? Self.attributes(ns.substring(with: match.range(at: 3))) : [:]
            let tag: TextTag?
            if let known = textTagNames[name] { tag = known }
            else if name == "span" || name == "font" { tag = colors(tag: name, attributes) }
            else { tag = nil }
            // A span with no color still pairs with its closing tag, so that one can't close an outer colored span.
            let pairs = textTagNames[name] != nil || name == "span" || name == "font"
            if pairs, match.range(at: 4).length == 0 {
                tags.append(Found(range: match.range, name: name, closing: closing, tag: tag))
            }
        }
        // Pair each opening with its closing tag; one without stays text.
        var replacements: [(range: NSRange, mark: String)] = []
        var styles: [TextTag] = []
        var stack: [(index: Int, name: String)] = []
        for (index, found) in tags.enumerated() {
            if found.name == "br" { replacements.append((found.range, String(lineBreakMark))); continue }
            if !found.closing { stack.append((index, found.name)); continue }
            guard let at = stack.lastIndex(where: { $0.name == found.name }) else { continue }
            let opening = stack[at].index
            stack.removeSubrange(at...)
            guard styles.count < maximumStyles, let style = tags[opening].tag else { continue }
            replacements.append((tags[opening].range, mark(openBase, styles.count)))
            replacements.append((found.range, mark(closeBase, styles.count)))
            styles.append(style)
        }
        guard !replacements.isEmpty else { return nil }
        let result = NSMutableString(string: source)
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: replacement.range, with: replacement.mark)
        }
        return (result as String, styles)
    }

    private static func mark(_ base: UInt32, _ index: Int) -> String {
        String(Character(Unicode.Scalar(base + UInt32(index))!))
    }

    /// `attributed` without its marks, each run between an opening and its
    /// closing mark styled as the tag says; a line-break mark a newline.
    static func applying(_ styles: [TextTag], to attributed: AttributedString) -> AttributedString {
        let characters = attributed.characters
        var result = AttributedString()
        var active: [Int] = []
        var segmentStart = characters.startIndex
        var index = characters.startIndex
        func flush(upTo end: AttributedString.Index) {
            guard segmentStart < end else { return }
            var piece = AttributedString(attributed[segmentStart..<end])
            for style in active { apply(styles[style], to: &piece) }
            result.append(piece)
        }
        while index < characters.endIndex {
            let next = characters.index(after: index)
            let character = characters[index]
            if character == lineBreakMark {
                flush(upTo: index)
                var newline = AttributedString(attributed[index..<next])
                newline.characters.replaceSubrange(newline.startIndex..<newline.endIndex, with: "\n")
                result.append(newline)
                segmentStart = next
            } else if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                      scalar.value >= openBase, scalar.value < closeBase + UInt32(maximumStyles) {
                flush(upTo: index)
                let opens = scalar.value < closeBase
                let style = Int(scalar.value - (opens ? openBase : closeBase))
                if style < styles.count {
                    if opens { active.append(style) } else { active.removeAll { $0 == style } }
                }
                segmentStart = next
            }
            index = next
        }
        flush(upTo: characters.endIndex)
        return result
    }

    private static func apply(_ tag: TextTag, to piece: inout AttributedString) {
        func intent(_ added: InlinePresentationIntent) {
            // Rebuilt run by run, so no index is used after a change.
            var rebuilt = AttributedString()
            for run in piece.runs {
                var part = AttributedString(piece[run.range])
                part.inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(added)
                rebuilt.append(part)
            }
            piece = rebuilt
        }
        switch tag {
        case .bold: intent(.stronglyEmphasized)
        case .italic: intent(.emphasized)
        case .strikethrough: intent(.strikethrough)
        case .key: intent(.code)
        case .underline:
            piece[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
        case .highlight:
            piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.conduitAccent.opacity(0.3)
        case .lowered:
            piece[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] = -3
        case .raised:
            piece[AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute.self] = 6
        case .colored(let foreground, let background):
            if let foreground, let color = color(foreground) {
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = color
            }
            if let background, let color = color(background) {
                piece[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = color
            }
        }
    }

    private static func attributes(_ text: String) -> [String: String] {
        let ns = text as NSString
        var found: [String: String] = [:]
        for match in attribute.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let value = (2...4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }.map { ns.substring(with: $0) } ?? ""
            found[name] = value
        }
        return found
    }

    /// A span's or font's colors, or nil when it gives none a reply may use.
    private static func colors(tag: String, _ attributes: [String: String]) -> TextTag? {
        var foreground: String?
        var background: String?
        if tag == "font" { foreground = safeColor(attributes["color"]) }
        for rule in (attributes["style"] ?? "").split(separator: ";") {
            let parts = rule.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard parts.count == 2, let value = safeColor(parts[1]) else { continue }
            if parts[0] == "color" { foreground = value }
            if parts[0] == "background-color" || parts[0] == "background" { background = value }
        }
        return foreground == nil && background == nil ? nil : .colored(foreground: foreground, background: background)
    }

    private static let namedColors: [String: Color] = [
        "red": .red, "green": .green, "blue": .blue, "orange": .orange, "yellow": .yellow, "purple": .purple,
        "pink": .pink, "gray": .gray, "grey": .gray, "black": .black, "white": .white, "teal": .teal,
        "brown": .brown, "cyan": .cyan, "magenta": Color(red: 1, green: 0, blue: 1), "indigo": .indigo
    ]
    private static let hexColor = compiled(#"^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$"#)
    private static let rgbColor = compiled(#"^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$"#)

    /// A CSS color a reply may use, lowercased, or nil: a name, a hex color,
    /// or rgb()/rgba() with plain numbers.
    static func safeColor(_ value: String?) -> String? {
        guard let color = value?.trimmingCharacters(in: .whitespaces).lowercased(), !color.isEmpty else { return nil }
        if namedColors[color] != nil || matches(hexColor, color) || matches(rgbColor, color) { return color }
        return nil
    }

    /// The color `safeColor` took.
    static func color(_ value: String) -> Color? {
        if let named = namedColors[value] { return named }
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count <= 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard let number = UInt64(digits, radix: 16) else { return nil }
            let hasAlpha = digits.count == 8
            let rgb = hasAlpha ? number >> 8 : number
            return Color(
                red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255,
                opacity: hasAlpha ? Double(number & 0xFF) / 255 : 1
            )
        }
        let ns = value as NSString
        guard let match = rgbColor.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let parts = (1...4).map { match.range(at: $0) }.map { $0.location == NSNotFound ? nil : Double(ns.substring(with: $0)) }
        guard let red = parts[0], let green = parts[1], let blue = parts[2] else { return nil }
        return Color(red: min(red, 255) / 255, green: min(green, 255) / 255, blue: min(blue, 255) / 255, opacity: min(parts[3] ?? 1, 1))
    }

    // MARK: Words

    /// Said where a page is when a reply is read aloud.
    static var spokenNote: String { AppLocalization.string("(There's a page here.)", table: .chat) }
    /// Shown where a page is in a preview line.
    static var previewNote: String { "🗂 " + AppLocalization.string("Page", table: .chat) }
}
