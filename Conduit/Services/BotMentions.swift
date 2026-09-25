import Foundation

/// Bot @mentions, ported from upstream Desktop's composer middleware
/// (`apps/desktop/src/plugins/hermes-bots/plugin.tsx` `mention-middleware`
/// and `data.ts` `resolveRosterMentions` / `mentionNameForms` / `botHandle`,
/// pinned upstream SHA fdec926e).
///
/// The contract, in one place: the user's text is sent UNCHANGED except for a
/// trailing identification note that tells the ACTIVE bot exactly which
/// teammate each `@tag` refers to. Nothing is ever delivered client-side —
/// the agent composes and sends with its `message_agent` tool. An unknown
/// `@token`, an ambiguous handle, and an e-mail address all stay ordinary
/// text (fail closed, never guess).
enum BotMentions {
    /// Upper bound on the identification note so a pathological roster cannot
    /// balloon a submission. Upstream has no cap; its roster is bounded by the
    /// same gateway limit, so this only fires on adversarial data.
    static let maxAnnotatedBots = 16

    /// Tokens friendly names may never reduce to (reserved room handles and
    /// the primary identity). Mirrors upstream `mentionNameForms`'s drop list.
    static let reservedTokens: Set<String> = ["all", "everyone", "user", "default", "hermes"]

    /// The quick shape test upstream runs before touching the roster.
    static func textMightContainMention(_ text: String) -> Bool {
        guard let regex = mentionScanRegex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Resolve every `@tag` in `text` against the roster, in tag order.
    ///
    /// - Parameters:
    ///   - text: the composer text (code fences and inline code are stripped
    ///     before scanning, so a tag inside them is content).
    ///   - roster: the live bot roster.
    ///   - activeProfileName: the profile the focused conversation runs on
    ///     (the workspace profile for ordinary chats, the bot's own profile
    ///     inside its Bot Chat). That bot is the LISTENER — mentioning it is
    ///     not a handoff, so it is excluded exactly like upstream's
    ///     `isActiveRosterBot`.
    static func resolve(
        text: String,
        roster: [BotProfile],
        activeProfileName: String?
    ) -> [BotProfile] {
        guard let regex = mentionScanRegex else { return [] }
        let prose = proseStrippingCode(text)
        let fullRange = NSRange(prose.startIndex..., in: prose)

        var formOwners: [String: Owner] = [:]
        let active = activeProfileName?.trimmingCharacters(in: .whitespacesAndNewlines)

        for bot in roster where !isActiveRosterBot(bot, activeProfileName: active) {
            for form in resolvableForms(of: bot) {
                claim(form: form, for: bot, into: &formOwners)
            }
        }

        // Previous profile names fill gaps only: a bot renamed after the tag
        // was typed still resolves, but a live name outranks another bot's
        // rename history (upstream `previous_names`).
        for bot in roster where !isActiveRosterBot(bot, activeProfileName: active) {
            for previous in bot.previousNames {
                for form in mentionNameForms(previous) where formOwners[form] == nil {
                    formOwners[form] = .bot(bot)
                }
            }
        }

        var mentioned: [BotProfile] = []
        var seen = Set<String>()
        for match in regex.matches(in: prose, range: fullRange) {
            // Capture group 2 is the tag body. Group 3 (a `@connection`
            // qualifier) never resolves against Conduit's single-gateway
            // roster, so a qualified tag stays plain text — matching how
            // upstream pins qualified tags to a connection Conduit lacks.
            guard match.numberOfRanges > 2,
                  let tokenRange = Range(match.range(at: 2), in: prose) else { continue }
            let token = prose[tokenRange].lowercased()
            guard case .some(.bot(let bot)) = formOwners[token] else { continue }
            if seen.insert(bot.name).inserted {
                mentioned.append(bot)
                if mentioned.count >= maxAnnotatedBots { break }
            }
        }
        return mentioned
    }

    /// The resolvable handle for a bot: the profile name, except the primary
    /// profile (`default`), which answers to `@hermes`.
    static func handle(for bot: BotProfile) -> String {
        let name = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.lowercased() == "default" ? "hermes" : name
    }

    /// The tag the autocomplete inserts: the first friendly-name form when
    /// the bot has one, else the profile handle (upstream `botMentionTag`).
    static func mentionTag(for bot: BotProfile) -> String {
        for friendly in friendlyNames(of: bot) {
            if let first = mentionNameForms(friendly).first { return first }
        }
        return handle(for: bot)
    }

    /// Taggable forms of a friendly name: the slug ("Research Buddy" →
    /// "research-buddy"; runs of non-token characters collapse to one
    /// hyphen) and the collapsed form ("research-buddy" → "researchbuddy";
    /// hyphens and underscores survive). Reserved tokens and anything
    /// outside the mention charset are dropped.
    static func mentionNameForms(_ value: String?) -> [String] {
        let name = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return [] }

        var slugChars: [Character] = []
        for char in name {
            if isTokenCharacter(char) {
                slugChars.append(char)
            } else if slugChars.last != "-" {
                slugChars.append("-")
            }
        }
        var slug = String(slugChars)
        while slug.first == "-" { slug.removeFirst() }
        while slug.last == "-" { slug.removeLast() }
        let collapsed = String(name.filter(isTokenCharacter))

        var forms: [String] = []
        for form in [slug, collapsed]
        where isValidMentionToken(form) && !reservedTokens.contains(form) {
            if !forms.contains(form) { forms.append(form) }
        }
        return forms
    }

    /// `^[a-z0-9][a-z0-9_-]*$` — the upstream mention charset.
    static func isValidMentionToken(_ value: String) -> Bool {
        guard let first = value.first, isTokenCharacter(first) else { return false }
        return value.dropFirst().allSatisfy(isTokenCharacter)
    }

    /// Friendly names a roster row carries, in upstream precedence order:
    /// the Bot Mode title (ui_meta) then the profile display name.
    static func friendlyNames(of bot: BotProfile) -> [String?] {
        [bot.botTitle, bot.displayName]
    }

    /// Build the sent text: original + the upstream identification note, or
    /// the original unchanged when nothing resolved. The note format mirrors
    /// `plugin.tsx` `mention-middleware` exactly, so gateway-side behavior
    /// and agent expectations do not fork between clients.
    static func annotated(text: String, mentions: [BotProfile]) -> String {
        guard !mentions.isEmpty else { return text }
        let lines = mentions.map { bot -> String in
            let handle = handle(for: bot)
            let title = bot.botTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // message_agent resolves canonical identities (the profile name,
            // or `hermes` for the primary). Conduit has no source-qualified
            // aliases, so the handle always equals the message_agent target
            // and the "(message_agent target: …)" suffix never applies.
            return "@\(handle) = agent profile \"\(bot.name)\""
                + (title.isEmpty ? "" : " (\"\(title)\")")
        }
        let note =
            "\n\n[@mentions resolved from the Bot Mode roster — the user is referring to: "
            + lines.joined(separator: "; ")
            + ". If they want one of these agents contacted, compose your own message and send it with your message_agent tool (agents on other connected machines are reachable too — the Desktop relays it); never forward the user’s text verbatim. If this session has no message_agent tool, agent messaging is unavailable here — say so.]"
        return text + note
    }

    /// The composer middleware step: nil means "send the text untouched" —
    /// no roster, no plausible tag, or nothing resolved. Upstream leaves the
    /// draft alone in exactly those cases, which is also the graceful
    /// degradation for a gateway without Bot Mode (its roster is empty).
    static func middlewareAnnotation(
        text: String,
        roster: [BotProfile],
        activeProfileName: String?
    ) -> String? {
        guard !roster.isEmpty, textMightContainMention(text) else { return nil }
        let mentions = resolve(text: text, roster: roster, activeProfileName: activeProfileName)
        guard !mentions.isEmpty else { return nil }
        return annotated(text: text, mentions: mentions)
    }

    /// The forever-chat guard, as a pure decision: `/new` and `/reset` inside
    /// a bot's CANONICAL chat reroute to `/compact` (fresh working context,
    /// SAME conversation); every other session — and every other text —
    /// keeps full slash-command freedom. The caller supplies the canonical
    /// verdict from roster/registry evidence; this function never guesses.
    static func foreverChatRerouteText(for text: String, isCanonicalBotChat: Bool) -> String? {
        guard isCanonicalBotChat else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/new" || trimmed == "/reset" else { return nil }
        return "/compact"
    }

    // MARK: - Internals

    private enum Owner {
        case bot(BotProfile)
        case ambiguous
    }

    private static func resolvableForms(of bot: BotProfile) -> Set<String> {
        var forms = Set<String>()
        forms.insert(handle(for: bot).lowercased())
        forms.insert(bot.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        for friendly in friendlyNames(of: bot) {
            for form in mentionNameForms(friendly) {
                forms.insert(form)
            }
        }
        return forms
    }

    private static func claim(
        form: String,
        for bot: BotProfile,
        into owners: inout [String: Owner]
    ) {
        switch owners[form] {
        case .none:
            owners[form] = .bot(bot)
        case .some(.bot(let existing)) where existing != bot:
            owners[form] = .ambiguous
        default:
            break
        }
    }

    /// The focused conversation's own bot never appears in the annotation.
    private static func isActiveRosterBot(_ bot: BotProfile, activeProfileName: String?) -> Bool {
        guard let active = activeProfileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !active.isEmpty else { return false }
        return bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(active) == .orderedSame
    }

    private static func isTokenCharacter(_ char: Character) -> Bool {
        switch char {
        case "a"..."z", "0"..."9", "_", "-":
            return true
        default:
            return false
        }
    }

    /// Upstream strips fenced blocks and inline code before scanning so a
    /// `@tag` inside them is content, never a mention.
    static func proseStrippingCode(_ text: String) -> String {
        var result = text
        for regex in [fencedCodeRegex, inlineCodeRegex].compactMap({ $0 }) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }
        return result
    }

    /// `(^|\s)@token` — the leading boundary is the e-mail guard:
    /// `user@example.com` never matches because its `@` follows a letter.
    static let mentionScanRegex = try? NSRegularExpression(
        pattern: "(^|\\s)@([a-z0-9][a-z0-9_-]*)(?:@([a-z0-9][a-z0-9_-]*))?",
        options: [.caseInsensitive, .anchorsMatchLines]
    )
    private static let fencedCodeRegex = try? NSRegularExpression(
        pattern: "```[\\s\\S]*?```", options: [])
    private static let inlineCodeRegex = try? NSRegularExpression(
        pattern: "`[^`\\n]*`", options: [])
}
