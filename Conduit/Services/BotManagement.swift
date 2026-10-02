import Foundation
import UIKit

/// Bot management (create / edit / delete / avatars), mirroring Hermes
/// Desktop's Bot Mode editor. A bot is an ordinary Hermes profile, so every
/// write goes to the gateway that owns the profile and every Hermes client
/// sees the same result:
///
/// - identity: `profiles.create` (the profile id is a slug of the name);
/// - look: `ui_meta['hermes-bots']` in profile.yaml (`profiles.configure`);
/// - avatar image: the profile's asset store (`profiles.set_asset` /
///   `profiles.get_asset`), which is where Desktop already keeps its bot
///   pictures — data URLs never go into ui_meta (64KB cap, rides every
///   `profiles.list`);
/// - delete: the dashboard's `DELETE /api/profiles/{name}`.
///
/// Upstream: `apps/desktop/src/plugins/hermes-bots/{create-dialog,
/// edit-profile-dialog,profile-ops,data,labels,soul}.ts`.
enum BotManagement {
    /// The `ui_meta` namespace Desktop's bots plugin owns.
    static let uiMetaKey = "hermes-bots"
    /// The asset name `profiles.set_asset` accepts.
    static let avatarAsset = "avatar"
    /// Avatars are stored as a small square, like Desktop's uploads.
    static let avatarEdge: CGFloat = 256

    /// The profile Desktop and the gateway refuse to delete.
    static func isDefaultProfile(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default"
    }
}

// MARK: - Profile id

/// Upstream `slugifyProfileName` / `botProfileIdentity`: the profile id the
/// backend accepts (ASCII-only), derived from whatever the user typed as the
/// bot's name. Accented Latin folds to its base letters; every other letter
/// or digit becomes a deterministic `u<hex>` token so a CJK name never slugs
/// to "" and leaves Create disabled.
enum BotProfileSlug {
    static let maxLength = 64

    static func slug(from raw: String) -> String {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        var folded = ""
        for scalar in source.unicodeScalars {
            guard isLetterOrNumber(scalar) else {
                folded.unicodeScalars.append(scalar)
                continue
            }
            let base = String(scalar).decompositionWithoutMarks
            if !base.isEmpty, base.unicodeScalars.allSatisfy(isASCIIAlphanumeric) {
                folded += base
            } else {
                folded += "-u\(String(scalar.value, radix: 16))-"
            }
        }
        var slug = ""
        var pendingDash = false
        for scalar in folded.lowercased().unicodeScalars {
            if isSlugScalar(scalar) {
                if pendingDash, !slug.isEmpty { slug += "-" }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        slug = collapseDashes(slug).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard slug.count > maxLength else { return slug }
        // Cut at the last token boundary so no `u<hex>` token is split.
        let characters = Array(slug)
        let cut = String(characters.prefix(maxLength))
        if characters[maxLength] == "-" { return cut.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        if let boundary = cut.lastIndex(of: "-"), boundary > cut.startIndex {
            return String(cut[..<boundary]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return cut
    }

    /// `hermes_cli.profiles`' id rule: `^[a-z0-9][a-z0-9_-]{0,63}$`.
    static func isValid(_ slug: String) -> Bool {
        let scalars = Array(slug.unicodeScalars)
        guard let first = scalars.first, scalars.count <= maxLength,
              isLowercaseASCIILetterOrDigit(first) else { return false }
        return scalars.allSatisfy(isSlugScalar)
    }

    /// The display title a name implies: whatever the user typed, unless it
    /// already reads exactly like the profile id.
    static func title(forName raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == slug(from: name) ? "" : name
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isLowercaseASCIILetterOrDigit(scalar) || (65...90).contains(scalar.value)
    }

    /// `[a-z0-9]`.
    private static func isLowercaseASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
    }

    /// `[a-z0-9_-]`.
    private static func isSlugScalar(_ scalar: Unicode.Scalar) -> Bool {
        isLowercaseASCIILetterOrDigit(scalar) || scalar == "_" || scalar == "-"
    }

    private static func collapseDashes(_ value: String) -> String {
        var result = ""
        for character in value where !(character == "-" && result.last == "-") {
            result.append(character)
        }
        return result
    }
}

private extension String {
    /// NFKD with every combining mark removed: `é` → `e`.
    var decompositionWithoutMarks: String {
        var result = ""
        for scalar in decomposedStringWithCompatibilityMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                continue
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

// MARK: - Avatar color

/// `ui_meta['hermes-bots'].color` as Desktop writes it: a CSS color string,
/// in practice one of its `hsl(H 68% 58%)` swatches or a hex value. Conduit
/// reads the same strings and writes the same swatches so a color picked on
/// either client renders identically on the other.
enum BotAvatarColor {
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Desktop's `PROFILE_SWATCHES`: twelve evenly spaced hues at the
    /// profile palette's saturation/lightness.
    static let swatches: [String] = (0..<12).map { "hsl(\($0 * 30) 68% 58%)" }

    /// Desktop's fixed look for the primary (`default`) profile.
    static let primaryHex = "#8b5cf6"

    /// Parses `hsl(...)`/`hsla(...)` (space or comma separated) and
    /// `#rgb`/`#rrggbb`. Named colors are the view's concern.
    static func rgb(from css: String) -> RGB? {
        let value = css.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { return hexRGB(String(value.dropFirst())) }
        guard value.hasPrefix("hsl"), let open = value.firstIndex(of: "("),
              let close = value.lastIndex(of: ")"), open < close else { return nil }
        let parts = value[value.index(after: open)..<close]
            .split(whereSeparator: { $0 == " " || $0 == "," || $0 == "/" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "%deg")) }
            .filter { !$0.isEmpty }
        guard parts.count >= 3, let hue = Double(parts[0]), let saturation = Double(parts[1]),
              let lightness = Double(parts[2]) else { return nil }
        return hslToRGB(hue: hue, saturation: saturation / 100, lightness: lightness / 100)
    }

    /// Desktop's `profileColor(name)`: `hsl(hash % 360 68% 58%)`, where the
    /// hash is the JS `(h * 31 + charCode) >>> 0` loop over UTF-16 units.
    /// `default` has no name hue; Desktop paints it a fixed violet.
    static func fallbackRGB(for name: String) -> RGB {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty || key == "default" {
            return rgb(from: primaryHex) ?? RGB(red: 0.55, green: 0.36, blue: 0.96)
        }
        var hash: UInt32 = 0
        for unit in key.utf16 {
            hash = hash &* 31 &+ UInt32(unit)
        }
        return hslToRGB(hue: Double(hash % 360), saturation: 0.68, lightness: 0.58)
    }

    static func hslToRGB(hue: Double, saturation: Double, lightness: Double) -> RGB {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let s = min(max(saturation, 0), 1)
        let l = min(max(lightness, 0), 1)
        guard s > 0 else { return RGB(red: l, green: l, blue: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return RGB(red: channel(h + 1.0 / 3), green: channel(h), blue: channel(h - 1.0 / 3))
    }

    private static func hexRGB(_ hex: String) -> RGB? {
        let digits = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return RGB(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

// MARK: - ui_meta writes

enum BotMetaPatch {
    /// Keys that must never travel in ui_meta: data URLs go to the asset
    /// store (Desktop strips them the same way), and `chat` is a dead legacy
    /// pointer Desktop deletes on sight.
    static let strippedKeys: Set<String> = ["image", "pet", "chat"]

    /// The full `hermes-bots` value to write. The gateway replaces the key
    /// wholesale, so every field another client stored (sections, groups,
    /// shape, …) is carried over from the roster's copy and only the patched
    /// fields change. A nil patch value deletes that field.
    static func merged(
        existing: [String: AnyCodable],
        patch: [String: Any?]
    ) -> [String: Any] {
        var result = existing.mapValues(\.anyValue)
        for (key, value) in patch {
            if let value {
                result[key] = value
            } else {
                result.removeValue(forKey: key)
            }
        }
        for key in strippedKeys {
            result.removeValue(forKey: key)
        }
        return result
    }
}

/// How the ui_meta half of a `profiles.configure` landed.
enum BotMetaWriteOutcome: Equatable {
    /// `applied.ui_meta == true`.
    case persisted
    /// Another client wrote the key since our roster snapshot (CAS mismatch).
    case conflict
    /// The gateway speaks the contract and reported the write did not apply.
    case failed
    /// An older gateway with no `applied` contract.
    case unsupported

    init(configureResult result: AnyCodable) {
        guard let applied = result.objectValue?["applied"]?.objectValue else {
            self = .unsupported
            return
        }
        if applied["ui_meta"]?.boolValue == true {
            self = .persisted
        } else if applied["ui_meta_conflicts"]?.objectValue?.isEmpty == false {
            self = .conflict
        } else {
            self = .failed
        }
    }
}

/// The non-ui_meta sections of a `profiles.configure` answer that reported
/// failure (`applied.soul == false`, …).
enum BotConfigureSections {
    static func failed(in result: AnyCodable, among sections: [String]) -> [String] {
        let applied = result.objectValue?["applied"]?.objectValue ?? [:]
        return sections.filter { applied[$0]?.boolValue == false }
    }
}

// MARK: - SOUL

/// Upstream `composeSoul`: the SOUL a new bot is born with. Newer backends
/// inject the bot-to-bot messaging protocol into every session themselves
/// (`profiles.list` `bot_mode_protocol`), so the SOUL stays the bot's own
/// identity text; older ones need the protocol section appended.
enum BotSoul {
    static let protocolHeading = "## Messaging other agents"

    static func compose(
        name: String,
        title: String,
        description: String,
        customSoul: String,
        serverInjectsProtocol: Bool,
        roster: [BotProfile]
    ) -> String {
        let custom = customSoul.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty {
            if serverInjectsProtocol || custom.contains(protocolHeading) { return custom }
            return custom + "\n\n" + messagingProtocol(name: name, roster: roster)
        }
        let display = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? name : title
        let mission = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = ["# \(display)", ""]
        if !mission.isEmpty {
            lines += ["**Mission:** \(mission)", ""]
        }
        lines += [
            "You are \(display), a persistent named agent (profile `\(name)`) on this machine.",
            "You keep your own memory, skills, and conversation history across sessions."
        ]
        let identity = lines.joined(separator: "\n")
        return serverInjectsProtocol ? identity : identity + "\n\n" + messagingProtocol(name: name, roster: roster)
    }

    /// Upstream `messagingProtocolSection`, verbatim in substance.
    static func messagingProtocol(name: String, roster: [BotProfile]) -> String {
        let handle = name
        let teammates = roster.filter { $0.name != name }
        var lines = [
            protocolHeading,
            "",
            "You work alongside other named agents. Every agent (including you) has",
            "ONE canonical conversation titled \"Bot Chat\" — created with the agent,",
            "so it always exists. Agent-to-agent messages are delivered straight",
            "into it, like a DM. To message a teammate, run:",
            "",
            "```",
            "hermes -p <agent-name> chat --in ~ -c \"Bot Chat\" --create-if-missing -Q -q \"Message from 🤖 \(handle) (@\(handle)): your message\"",
            "",
            "Run the send with background=true and notify_on_complete=true on the",
            "terminal tool, then finish your turn — the reply arrives later as a",
            "background process notification. Never block waiting for it.",
            "```",
            "",
            "(`--in ~ -c \"Bot Chat\" --create-if-missing` resumes their canonical",
            "conversation in the home workspace, creating it if the target has no",
            "\"Bot Chat\" yet. `-Q` keeps output clean. Always open with the",
            "\"Message from 🤖 \(handle) (@\(handle)):\" prefix so they know",
            "who is talking (the @handle lets the app show your avatar to them).",
            "Their reply prints to stdout — relay the relevant part back to the",
            "user, and say which agent it came from.)",
            "",
            "If a message in YOUR chat starts with \"Message from 🤖 <name>\", it is",
            "a teammate messaging you, not the user. Answer it directly — your reply",
            "reaches them via their own delivery — and use the same command if you",
            "need to start a conversation yourself.",
            "",
            "When the user writes @<agent-name> or says \"ask <name> to ...\" /",
            "\"tell <name> ...\", that is a handoff: message that agent, wait for the",
            "reply, and report back.",
            "",
            "The roster grows over time — run `hermes profile list` for the LIVE",
            "teammate list before a handoff. Teammates when you were created:"
        ]
        if teammates.isEmpty {
            lines.append("- (none yet)")
        } else {
            lines += teammates.map { bot in
                let detail = bot.profileDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "- `\(bot.name)`" : "- `\(bot.name)` — \(detail)"
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Avatar images

enum BotAvatarImage {
    /// Center-crops to a square and downsizes to `edge` px PNG, the same
    /// normalization Desktop applies before `profiles.set_asset` (whose cap
    /// is 2MB).
    static func normalizedPNG(from image: UIImage, edge: CGFloat = BotManagement.avatarEdge) -> Data? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format)
        let side = min(image.size.width, image.size.height)
        let scale = edge / side
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (edge - drawSize.width) / 2, y: (edge - drawSize.height) / 2)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return rendered.pngData()
    }

    static func dataURL(png: Data) -> String {
        "data:image/png;base64," + png.base64EncodedString()
    }

    /// The image bytes of a `profiles.get_asset` answer: `found` plus a
    /// `data:image/...;base64,` URL. Nil for an absent or unreadable asset.
    static func imageData(fromGetAssetResult result: AnyCodable) -> Data? {
        guard let object = result.objectValue, object["found"]?.boolValue == true,
              let dataURL = object["data"]?.stringValue else { return nil }
        let payload: Substring
        if dataURL.hasPrefix("data:") {
            guard let comma = dataURL.firstIndex(of: ","),
                  dataURL[..<comma].hasSuffix(";base64") else { return nil }
            payload = dataURL[dataURL.index(after: comma)...]
        } else {
            payload = Substring(dataURL)
        }
        return Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters)
    }
}

// MARK: - Editor models

/// What `profiles.describe` returns that the bot editor needs.
struct BotProfileDetails: Equatable {
    var description: String
    var soul: String
}

/// The bot editor's form, shared by create and edit.
struct BotEditorDraft: Equatable {
    var name: String = ""
    var description: String = ""
    var soul: String = ""
    /// A CSS color string from `BotAvatarColor.swatches`, or nil for the
    /// name's own hue.
    var color: String?
    /// A freshly chosen picture (normalized PNG). Nil = unchanged.
    var newAvatarPNG: Data?
    /// The user removed the existing picture.
    var removesAvatar = false
}

/// What a create or edit came to. `saved` with a warning means the bot was
/// written but a best-effort part (look, picture, personality) was not.
enum BotSaveResult: Equatable {
    case saved(warning: String?)
    case failed(String)
}
