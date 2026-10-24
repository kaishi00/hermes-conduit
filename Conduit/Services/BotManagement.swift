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
        // Meta-hidden bots stay out, as they do on the roster.
        let teammates = roster.filter { $0.name != name && !$0.isHiddenByMeta }
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
    /// The profile's own `model.provider` / `model.default`; empty when it
    /// has no pin of its own.
    var provider: String = ""
    var model: String = ""
    var capabilities = BotCapabilities()
}

/// One skill, toolset or MCP server a profile can turn on or off.
struct BotCapability: Equatable, Identifiable {
    var name: String
    var label: String?
    var description: String = ""
    var toolCount: Int?
    var enabled: Bool

    var id: String { name }
}

/// `profiles.describe`'s skills, toolsets and MCP servers (upstream
/// `profile-config.tsx` `AdvancedProfileConfig`).
struct BotCapabilities: Equatable {
    var skills: [BotCapability] = []
    var toolsets: [BotCapability] = []
    var mcpServers: [BotCapability] = []

    var isEmpty: Bool { skills.isEmpty && toolsets.isEmpty && mcpServers.isEmpty }

    init(skills: [BotCapability] = [], toolsets: [BotCapability] = [], mcpServers: [BotCapability] = []) {
        self.skills = skills
        self.toolsets = toolsets
        self.mcpServers = mcpServers
    }

    init(describe object: [String: AnyCodable]) {
        func rows(_ key: String) -> [BotCapability] {
            (object[key]?.arrayValue ?? []).compactMap { row in
                guard let item = row.objectValue,
                      let name = item["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { return nil }
                let label = item["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                return BotCapability(
                    name: name,
                    label: label?.isEmpty == false ? label : nil,
                    description: item["description"]?.stringValue ?? "",
                    toolCount: item["tool_count"]?.intValue,
                    // An MCP entry without the flag is on, as the runtime reads it.
                    enabled: item["enabled"]?.boolValue ?? (key == "mcp_servers")
                )
            }
        }
        skills = rows("skills").sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        toolsets = rows("toolsets")
        mcpServers = rows("mcp_servers")
    }

    /// The `profiles.configure` sections for what `edited` changed from
    /// `original`; an untouched section is never written. Toolsets all on
    /// clear the pin so the platform default applies, as Desktop does.
    /// Hermes reads an empty list the same way, so all off can't be said:
    /// the editor keeps the last tool on (`canTurnOffToolset`). MCP is a
    /// plain on/off per server, so an empty list does mean none.
    static func configureParams(original: BotCapabilities, edited: BotCapabilities) -> [String: Any] {
        func enabledNames(_ rows: [BotCapability]) -> Set<String> { Set(rows.filter(\.enabled).map(\.name)) }
        var params: [String: Any] = [:]
        if enabledNames(edited.skills) != enabledNames(original.skills) {
            params["disabled_skills"] = edited.skills.filter { !$0.enabled }.map(\.name)
        }
        if enabledNames(edited.toolsets) != enabledNames(original.toolsets) {
            let enabled = edited.toolsets.filter(\.enabled).map(\.name)
            params["enabled_toolsets"] = enabled.count == edited.toolsets.count ? [String]() : enabled
        }
        if enabledNames(edited.mcpServers) != enabledNames(original.mcpServers) {
            params["enabled_mcp_servers"] = edited.mcpServers.filter(\.enabled).map(\.name)
        }
        return params
    }

    /// Whether the toolset at `index` may be turned off: never the last one
    /// on, since no tools on would save as Hermes' default tools.
    func canTurnOffToolset(at index: Int) -> Bool {
        guard toolsets.indices.contains(index), toolsets[index].enabled else { return true }
        return toolsets.filter(\.enabled).count > 1
    }

    /// The `applied` keys `configureParams` sections report under (the
    /// gateway's `_configure_cfg_sections` names them so, not by field).
    static func appliedSections(for params: [String: Any]) -> [String] {
        var sections: [String] = []
        if params["disabled_skills"] != nil { sections.append("skills") }
        if params["enabled_toolsets"] != nil { sections.append("toolsets") }
        if params["enabled_mcp_servers"] != nil { sections.append("mcp_servers") }
        return sections
    }
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

    // Advanced (Desktop's New Bot "Advanced" section).
    /// The profile a new bot copies its settings from: the main profile
    /// (Desktop's default), another bot, or "" for a fresh profile with the
    /// bundled skills.
    var cloneFrom: String = BotCreateRequest.mainProfile
    /// A provider and model pin. Both empty: a new bot inherits the main
    /// profile's model, an edited bot keeps its own.
    var provider: String = ""
    var model: String = ""
    /// Share (not copy) the main profile's keys and accounts, so a token
    /// refresh in one never signs the other out.
    var shareAuth = true
    /// Skip the bundled skills.
    var noSkills = false
    /// Skills, toolsets and MCP servers as the user left them, and as they
    /// were loaded (for a new bot: its Start From profile's). Nil until
    /// loaded; only changed sections are written.
    var capabilities: BotCapabilities?
    var capabilitiesBaseline: BotCapabilities?
}

/// Upstream `create-dialog.tsx` `ensureAgentCreated`: the `profiles.create`
/// parameters for a new bot.
enum BotCreateRequest {
    /// The profile Desktop clones by default.
    static let mainProfile = "default"

    static func params(slug: String, description: String, soul: String, draft: BotEditorDraft) -> [String: Any] {
        var params: [String: Any] = [
            "name": slug,
            "description": description,
            "soul": soul,
            "no_skills": draft.noSkills,
            "share_auth": draft.shareAuth
        ]
        let cloneFrom = draft.cloneFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        // Omitted = a fresh profile with the bundled skills.
        if !cloneFrom.isEmpty { params["clone_from"] = cloneFrom }
        let provider = draft.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        // The gateway pins a model only with both; one alone inherits.
        if !provider.isEmpty, !model.isEmpty {
            params["provider"] = provider
            params["model"] = model
        }
        return params
    }

    /// Whether a model the create asked for was pinned. `profiles.create`
    /// reports a failed pin only as `model_set: false`; an older gateway
    /// that omits the key counts as pinned.
    static func modelPinned(_ params: [String: Any], result: AnyCodable) -> Bool {
        guard params["model"] != nil else { return true }
        return result.objectValue?["model_set"]?.boolValue != false
    }
}

/// `setup.runtime_check` for a new bot: can its profile reach a model?
/// Only an explicit `ok: false` counts, so an older gateway goes ahead as
/// before (upstream `create-dialog.tsx` `submit`).
enum BotRuntimeCheck {
    static func needsModel(_ result: AnyCodable?) -> Bool {
        result?.objectValue?["ok"]?.boolValue == false
    }
}

/// A `profiles.configure` model pin the gateway would not write unasked
/// (an expensive or data-training model): its `confirm_message`.
enum BotModelConfirmation {
    static func message(in result: AnyCodable) -> String? {
        let object = result.objectValue ?? [:]
        guard object["confirm_required"]?.boolValue == true else { return nil }
        // `warning` is the older gateways' name for the same text.
        let message = [object["confirm_message"], object["warning"]]
            .lazy
            .compactMap { $0?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return message.isEmpty ? AppLocalization.string("Hermes requires confirmation before using this model.") : message
    }
}

/// What a create or edit came to. `saved` with a warning means the bot was
/// written but a best-effort part (look, picture, personality) was not.
enum BotSaveResult: Equatable {
    /// `needsModel`: a new bot that cannot reach a model yet, so it skips
    /// its introduction.
    case saved(warning: String?, needsModel: Bool = false)
    /// Everything else saved; the model pin waits for the user to confirm
    /// the gateway's message.
    case confirmModel(String)
    case failed(String)
}
