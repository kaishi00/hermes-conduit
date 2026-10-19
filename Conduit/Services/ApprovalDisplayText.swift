import Foundation

/// Makes an approval's command and explanation, which the agent controls,
/// show everything they contain. An approval card is where the person
/// decides whether a command runs, so text that draws differently from what
/// it is must not reach it: a right-to-left override can make
/// `rm -rf ~ #…` read as something harmless, zero-width and tag characters
/// can carry text nobody sees, and a stack of combining marks can paint
/// over the line around it.
///
/// Nothing is dropped, since the command runs as it was sent: every scalar
/// in the control (Cc, other than a tab, a line feed and the carriage
/// return of a CRLF), format (Cf), private-use (Co), unassigned (Cn),
/// line-separator (Zl) or paragraph-separator (Zp) category is shown as
/// `<U+XXXX>` instead, and so is every combining mark past
/// `maxCombiningMarks` on one base. A zero-width joiner between two
/// pictographs is an emoji sequence and stays. Text without any of these
/// comes back unchanged.
enum ApprovalDisplayText {
    static let maxCombiningMarks = 3

    static func revealingHidden(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var shown = String.UnicodeScalarView()
        var marks = 0
        for (index, scalar) in scalars.enumerated() {
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            if isHidden(scalar, previous: index > 0 ? scalars[index - 1] : nil, next: next) {
                shown.append(contentsOf: escaped(scalar).unicodeScalars)
                marks = 0
                continue
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                marks += 1
                if marks > maxCombiningMarks {
                    shown.append(contentsOf: escaped(scalar).unicodeScalars)
                    continue
                }
            default:
                marks = 0
            }
            shown.append(scalar)
        }
        return String(shown)
    }

    private static func isHidden(
        _ scalar: Unicode.Scalar,
        previous: Unicode.Scalar?,
        next: Unicode.Scalar?
    ) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A:
            return false
        case 0x0D:
            return next?.value != 0x0A
        case 0x200D:
            guard let previous, let next else { return true }
            return !(isPictographLike(previous) && isPictographLike(next))
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    private static func escaped(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "<U+\(String(repeating: "0", count: max(0, 4 - hex.count)))\(hex)>"
    }

    private static func isPictographLike(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isEmojiPresentation
            || properties.isEmojiModifier
            || scalar.value == 0xFE0F
            || (properties.isEmoji && scalar.value > 0xFF)
    }
}
