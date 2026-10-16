import SwiftUI

/// How one step of a turn looks in the chat (V2): an icon on a faint disc of
/// its color and plain words for what it does. Steps are described by the
/// same tool categories as the Live Activity (`HermesToolCategory`), never by
/// a tool's own name, which the opened step still shows.
struct ChatStepStyle: Equatable {
    let category: HermesToolCategory
    let symbol: String
    let tint: Color

    init(toolName: String) {
        let category = HermesToolCategory(toolName: toolName)
        self.category = category
        let picked = Self.phoneTools[toolName.lowercased()] ?? Self.look(category)
        symbol = picked.0
        tint = picked.1
    }

    /// The live line while this step runs ("Searching the web").
    var runningTitle: String {
        AppLocalization.string(String.LocalizationValue(HermesTurnCopy.toolKey(category)))
    }

    /// The row once the step finished ("Searched the web").
    var doneTitle: String {
        AppLocalization.string(Self.doneKey(category))
    }

    static let thinking = (symbol: "sparkle", tint: Color.conduitVoice)

    /// Where an opened row's text starts, under its title: the row's inset,
    /// the icon disc and the gap after it.
    static let contentInset: CGFloat = 14 + iconSize + 11

    static let iconSize: CGFloat = 26

    /// Conduit's own phone tools all read as "Using your iPhone"; their
    /// icons tell them apart.
    private static let phoneTools: [String: (String, Color)] = [
        "conduit_calendar": ("calendar", .red),
        "conduit_health": ("heart", .pink),
        "conduit_location": ("location", .conduitAura),
        "conduit_maps": ("map", .conduitSuccess),
        "conduit_contacts": ("person.crop.circle", .secondary),
        "conduit_phone": ("iphone", .secondary),
        "conduit_call_user": ("phone", .conduitSuccess),
        "conduit_call_watch": ("applewatch", .conduitSuccess),
        "conduit_present": ("checkmark.bubble", .conduitAccent),
        "conduit_settings": ("gearshape", .secondary),
    ]

    private static func look(_ category: HermesToolCategory) -> (String, Color) {
        switch category {
        case .tool: ("wrench.and.screwdriver", .secondary)
        case .terminal: ("terminal", .conduitSuccess)
        case .code: ("chevron.left.forwardslash.chevron.right", .conduitSuccess)
        case .files: ("doc.text", .secondary)
        case .web: ("globe", .conduitAura)
        case .browser: ("safari", .conduitAura)
        case .agents: ("person.2", .conduitAccent)
        case .memory: ("brain", .conduitScheduled)
        case .images: ("photo", .conduitVoice)
        case .audio: ("waveform", .conduitVoice)
        case .planning: ("checklist", .conduitAccent)
        case .schedule: ("clock", .conduitScheduled)
        case .messages: ("paperplane", .conduitAura)
        case .skills: ("book", .conduitScheduled)
        case .connector: ("puzzlepiece.extension", .secondary)
        case .phone: ("iphone", .secondary)
        case .home: ("house", .conduitSuccess)
        }
    }

    static func doneKey(_ category: HermesToolCategory) -> String.LocalizationValue {
        switch category {
        case .tool: "Used a tool"
        case .terminal: "Ran a command"
        case .code: "Ran code"
        case .files: "Worked with files"
        case .web: "Searched the web"
        case .browser: "Used the browser"
        case .agents: "Worked with subagents"
        case .memory: "Checked memory"
        case .images: "Worked with images"
        case .audio: "Made audio"
        case .planning: "Updated the plan"
        case .schedule: "Updated a schedule"
        case .messages: "Sent a message"
        case .skills: "Used a skill"
        case .connector: "Used a connector"
        case .phone: "Used your iPhone"
        case .home: "Used your smart home"
        }
    }
}

/// What a step was about, in one line: the search, command, page or file
/// from the tool's arguments ("dinner downtown Asheville"), or the input's
/// first line when it isn't a JSON object.
enum ChatStepSubject {
    private static let preferredKeys = [
        "query", "command", "url", "path", "file_path", "pattern", "goal",
        "prompt", "question", "title", "name", "text", "action",
    ]

    /// Past this, a JSON input isn't parsed: one line of it is shown as is.
    /// Tool output can run to megabytes, and rows render on the main thread.
    static let parseLimit = 4096

    static func line(from input: String?) -> String? {
        guard let input else { return nil }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.utf8.count <= parseLimit,
           trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let value = preferredKeys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
                ?? object.keys.sorted().lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
            return value.flatMap(oneLine)
        }
        return oneLine(trimmed)
    }

    private static func oneLine(_ text: String) -> String? {
        let line = String(text.prefix(400))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return String(line.prefix(200))
    }
}

/// A step's icon: its symbol in its color on a faint disc of it.
struct ChatStepIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: ChatStepStyle.iconSize, height: ChatStepStyle.iconSize)
            .background(tint.opacity(0.16), in: Circle())
            .conduitFixedGlyph()
            .accessibilityHidden(true)
    }
}

/// The quiet card behind the thinking and tool rows: a faint fill and a
/// hairline, like the "Started from this call" block.
extension View {
    func chatStepCard() -> some View {
        settingsCard(cornerRadius: 22)
    }
}

/// The running turn's line, in place of "Working…": the profile's picture
/// breathing in its glow and what Hermes is doing right now ("Home ·
/// Searching the web").
struct ChatWorkingLine: View {
    /// The tool running now, if any.
    let currentToolName: String?
    let isThinking: Bool
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    private var phrase: String {
        if let currentToolName {
            return ChatStepStyle(toolName: currentToolName).runningTitle
        }
        return isThinking ? AppLocalization.string("Thinking") : AppLocalization.string("Working…")
    }

    var body: some View {
        let name = appState.profileDisplayName(appState.activeProfile)
        HStack(spacing: 9) {
            ConduitAgentMark(
                isActive: true,
                avatarURL: appState.profileAvatarURL(for: appState.activeProfile),
                displayName: name,
                glow: appState.profileGlowTint(appState.activeProfile)
            )

            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            Text(phrase)
                .font(.subheadline)
                .foregroundStyle(Color.conduitAccent)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(ConduitMotion.settle, value: phrase)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.string("\(name) is working"))
        .accessibilityValue(phrase)
    }
}
