//
//  PreviewText.swift
//  Conduit
//
//  One-line previews (chat rows, the bot list) from text that is often
//  Markdown: "**Mon** Lemon chicken" reads "Mon Lemon chicken". Block marks
//  at line starts (headings, bullets, numbers, quotes) drop, lines join with
//  spaces, and inline marks (bold, italics, code, links) drop through the
//  system's Markdown parser.
//

import Foundation

enum PreviewText {
    /// Rows redraw often; the same preview parses once.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1000
        return cache
    }()

    static func plain(_ text: String) -> String {
        let key = text as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let result = strip(text)
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func strip(_ text: String) -> String {
        // A teammate's delivery previews as who said what ("Atlas: Found
        // three flights"), not its "Message from 🤖 Atlas (@atlas)" signature.
        var text = text
        if let inbound = BotTeammateMessages.inbound(text) {
            text = inbound.body.isEmpty ? inbound.sender : "\(inbound.sender): \(inbound.body)"
        }
        // A preview reads as its file, a Desktop card as what it is (#1522),
        // never as the directive.
        text = TranscriptDirectives.rewriting(
            text,
            preview: { TranscriptDirectives.fileName($0) },
            card: { _ in DesktopCardDirective.previewNote }
        )
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { dropBlockMark(from: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: " ")
        guard joined.contains(where: { "*_`[~\\".contains($0) }) else { return joined }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed = (try? AttributedString(markdown: joined, options: options)).map { String($0.characters) } ?? joined
        // A preview cut mid-span leaves its opening mark unmatched; a mark
        // touching a word goes, a spaced one ("5 ** 3") is the text's own.
        return parsed.replacingOccurrences(of: #"\*\*(?=\S)|(?<=\S)\*\*|`(?=\S)|(?<=\S)`"#,
                                           with: "", options: .regularExpression)
    }

    /// "## Camp" -> "Camp", "- Tent" -> "Tent", "2. Pack" -> "Pack",
    /// "> quote" -> "quote". A fence line ("```swift") drops whole.
    private static func dropBlockMark(from line: String) -> String {
        if line.hasPrefix("```") || line.hasPrefix("~~~") { return "" }
        var rest = Substring(line)
        if rest.hasPrefix("#") {
            let hashes = rest.prefix(while: { $0 == "#" })
            let after = rest.dropFirst(hashes.count)
            if hashes.count <= 6, after.first == " " { rest = after }
        } else if rest.hasPrefix(">") {
            // ">> quote" nests: drop every level.
            while let first = rest.first, first == ">" || first == " " { rest = rest.dropFirst() }
        } else if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            rest = rest.dropFirst(2)
        } else {
            let digits = rest.prefix(while: \.isNumber)
            let after = rest.dropFirst(digits.count)
            if !digits.isEmpty, digits.count <= 3, after.hasPrefix(". ") || after.hasPrefix(") ") {
                rest = after.dropFirst(2)
            }
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
