import SwiftUI

/// How one step of a turn looks in the chat (V2): an icon on a faint disc of
/// its color, from the same tool categories as the Live Activity
/// (`HermesToolCategory`). Its words are `ChatStepLabel`'s.
struct ChatStepStyle: Equatable {
    let category: HermesToolCategory
    let symbol: String
    let tint: Color

    init(toolName: String) {
        let category = HermesToolCategory(toolName: toolName)
        self.category = category
        let lowered = toolName.lowercased()
        // Connector tools aren't a Live Activity category (the plugin's
        // list is its twin); in the chat they look like the MCP tools.
        // A Tool Search wrapper still shown runs app or connector calls.
        let picked = Self.phoneTools[lowered] ?? Self.bridgeTools[lowered]
            ?? Self.look(lowered.hasPrefix("connectors__") || ToolSearchBridge.isWrapper(toolName) ? .connector : category)
        symbol = picked.0
        tint = picked.1
    }

    /// Thinking isn't an action: a quiet gray bubble, so the colored tool
    /// steps around it stand out.
    static let thinking = (symbol: "ellipsis.bubble", tint: Color.secondary)

    /// A step row's insets and the gap after its icon.
    static let rowHorizontalPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 10
    static let iconGap: CGFloat = 11

    /// Where an opened row's text starts, under its title: the row's inset,
    /// the icon disc and the gap after it.
    static let contentInset: CGFloat = rowHorizontalPadding + iconSize + iconGap

    static let iconSize: CGFloat = 26

    /// The transcript's gap between rows (ChatView's stack spacing). The
    /// rows of one run of steps close it to read as one card.
    static let transcriptRowSpacing: CGFloat = 18

    static let cardCornerRadius: CGFloat = 22

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
        "conduit_notify": ("bell", .conduitAccent),
        "conduit_present": ("checkmark.bubble", .conduitAccent),
        "conduit_settings": ("gearshape", .secondary),
    ]

    /// Tool Search's own steps: finding tools, then reading about them.
    private static let bridgeTools: [String: (String, Color)] = [
        "tool_search": ("magnifyingglass", .secondary),
        "tool_describe": ("book.closed", .secondary),
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

/// A step's words. Conduit's own phrase when it knows the kind of tool
/// ("Searched the web"); otherwise the name of what was used: the app of an
/// MCP or connector tool ("Used Notion"), the toolset Hermes' catalog puts
/// the tool in ("Used Spotify"), else the tool's own name made readable.
/// "Used a tool" is left for a call with no name at all.
struct ChatStepLabel: Equatable {
    enum Kind: Equatable {
        case category(HermesToolCategory)
        /// What was used, as Hermes or the tool names it (not translated).
        case named(String)
        /// Tool Search's own steps.
        case toolSearch
        case toolDescribe
    }

    let kind: Kind
    /// What an MCP or connector call did there ("create page").
    var action: String?
    /// The catalog's line about the toolset, for the opened row.
    var detail: String?

    init(toolName: String, input: String? = nil, catalog: ToolCatalog = ToolCatalog()) {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = name.lowercased()
        switch lowered {
        case "": kind = .category(.tool); return
        case "tool_search": kind = .toolSearch; return
        case "tool_describe": kind = .toolDescribe; return
        default: break
        }
        if ToolSearchBridge.isWrapper(name) {
            // A wrapper still shown is a batch or a connector call: name
            // what it ran.
            let labels = Self.calls(in: input).map { ChatStepLabel(toolName: $0, catalog: catalog) }
            var names: [String] = []
            for label in labels {
                guard let shown = label.shownName, !names.contains(shown) else { continue }
                names.append(shown)
            }
            // Every action it ran, as the subject line ("create page, list issues").
            var actions: [String] = []
            for label in labels {
                guard let done = label.action, !actions.contains(done) else { continue }
                actions.append(done)
            }
            let subject = actions.isEmpty ? nil : actions.prefix(3).joined(separator: ", ")
            if names.count == 1, var only = labels.first(where: { $0.shownName == names[0] }) {
                only.action = subject ?? only.action
                self = only
            } else if !names.isEmpty {
                kind = .named(Array(names.prefix(3)).formatted(.list(type: .and).locale(AppLocalization.formattingLocale)))
                action = subject
            } else if let first = labels.first {
                // Only kinds Conduit has words for: the first one's.
                self = first
            } else {
                kind = .category(.tool)
            }
            return
        }
        if let call = Self.appCall(name) {
            kind = .named(call.app)
            action = call.action.isEmpty ? nil : call.action
            return
        }
        let category = HermesToolCategory(toolName: name)
        if category != .tool && category != .connector {
            kind = .category(category)
        } else if let entry = catalog.entry(for: name) {
            kind = .named(entry.label)
            detail = entry.description
        } else if category == .connector {
            kind = .category(.connector)
        } else {
            let readable = Self.readableName(name)
            kind = readable.isEmpty ? .category(.tool) : .named(readable)
        }
    }

    /// The live line while this step runs ("Using Spotify").
    var runningTitle: String {
        switch kind {
        case .category(let category): AppLocalization.string(String.LocalizationValue(HermesTurnCopy.toolKey(category)))
        case .named(let name): AppLocalization.string("Using \(name)")
        case .toolSearch: AppLocalization.string("Looking for tools")
        case .toolDescribe: AppLocalization.string("Reading tool details")
        }
    }

    /// The row once the step finished ("Used Spotify").
    var doneTitle: String {
        switch kind {
        case .category(let category): AppLocalization.string(ChatStepStyle.doneKey(category))
        case .named(let name): AppLocalization.string("Used \(name)")
        case .toolSearch: AppLocalization.string("Looked for tools")
        case .toolDescribe: AppLocalization.string("Read tool details")
        }
    }

    private var shownName: String? {
        if case .named(let name) = kind { return name }
        return nil
    }

    /// An MCP tool (`mcp__notion__create_page`) or a connector tool
    /// (`connectors__github__list_issues`): its app and action, the way
    /// Hermes' own tool labels split them.
    static func appCall(_ name: String) -> (app: String, action: String)? {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, ["mcp", "connectors"].contains(parts[0].lowercased()),
              !parts[1].isEmpty else { return nil }
        let app = parts[1]
        var tool = parts[2...].joined(separator: "__")
        // Connector actions often repeat the app ("GITHUB_LIST_ISSUES").
        let prefix = app.replacingOccurrences(of: "-", with: "_").uppercased() + "_"
        if tool.uppercased().hasPrefix(prefix) { tool = String(tool.dropFirst(prefix.count)) }
        let action = tool.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").joined(separator: " ").lowercased()
        return (appTitle(app), action)
    }

    private static let appTitles = [
        "github": "GitHub", "gmail": "Gmail", "googlecalendar": "Google Calendar",
        "googledocs": "Google Docs", "googledrive": "Google Drive", "stripe_mcp": "Stripe",
    ]

    static func appTitle(_ slug: String) -> String {
        appTitles[slug.lowercased()] ?? readableName(slug, capitalizeEveryWord: true)
    }

    /// `crawl4ai_md` → "Crawl4ai md".
    static func readableName(_ name: String, capitalizeEveryWord: Bool = false) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        return words.enumerated().map { index, word in
            index == 0 || capitalizeEveryWord ? word.prefix(1).uppercased() + word.dropFirst() : word
        }.joined(separator: " ")
    }

    /// The tool names in a `tool_call` envelope (`{"calls": [{name}]}` or
    /// a legacy `{name}`); empty when it isn't readable.
    private static func calls(in input: String?) -> [String] {
        guard let input, input.utf8.count <= ChatStepSubject.parseLimit * 4,
              let data = input.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var entries: [Any] = []
        switch object["calls"] {
        case let list as [Any]: entries = list
        case let text as String:
            if let data = text.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                entries = list
            }
        case let one as [String: Any]: entries = [one]
        default: entries = [object]
        }
        return entries.compactMap { ($0 as? [String: Any])?["name"] as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// What a step was about, in one line: the search, command, page or file
/// from the tool's arguments ("dinner downtown Asheville"), or the input's
/// first line when it isn't a JSON object.
enum ChatStepSubject {
    private static let preferredKeys = [
        "query", "command", "url", "path", "file_path", "pattern", "goal",
        "prompt", "question", "title", "name", "text", "action", "message",
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
    var size: CGFloat = ChatStepStyle.iconSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
            .conduitFixedGlyph()
            .accessibilityHidden(true)
    }
}

/// The quiet card behind the thinking and tool rows: a faint fill and a
/// hairline, like the "Started from this call" block. Off for a row drawn
/// as part of a run's card.
extension View {
    @ViewBuilder
    func chatStepCard(_ isOn: Bool = true) -> some View {
        if isOn {
            settingsCard(cornerRadius: ChatStepStyle.cardCornerRadius)
        } else {
            self
        }
    }
}

/// The running turn's line, in place of "Working…": the agent's face (the
/// bot's picture or initial inside a Bot Chat, else the profile's) breathing
/// in its glow, what Hermes is doing right now ("Home · Searching the web")
/// and how long the turn has run.
struct ChatWorkingLine: View {
    /// The tool running now, if any.
    let currentToolName: String?
    /// Its input, so a Tool Search batch reads as what it runs.
    var currentToolInput: String? = nil
    /// Its own words for it ("Messaging Atlas…"), else the tool's kind.
    var currentToolTitle: String? = nil
    let isThinking: Bool
    /// When the turn began; nil hides the timer.
    var startedAt: Date?
    /// Another device is getting the reply (it took the chat's stream).
    var repliesElsewhere = false
    @Environment(\.chatRowState) private var rowState
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var phrase: String {
        if repliesElsewhere { return AppLocalization.string("Replying on another device") }
        if let currentToolTitle { return currentToolTitle }
        if let currentToolName {
            return ChatStepLabel(toolName: currentToolName, input: currentToolInput, catalog: rowState.toolCatalog).runningTitle
        }
        return isThinking ? AppLocalization.string("Thinking") : AppLocalization.string("Working…")
    }

    /// Counts on its own; this view doesn't re-render each second.
    @ViewBuilder
    private var timer: some View {
        if let startedAt {
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                .scaledFont(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    var body: some View {
        // The bot's identity inside a Bot Chat, else the workspace profile's.
        let identity = rowState.agentIdentity
        let largeText = dynamicTypeSize.isAccessibilitySize
        // Large text: the words wrap and stack instead of truncating.
        let lineLimit = largeText ? nil : 1 as Int?
        let line = HStack(spacing: 9) {
            ConduitAgentMark(
                isActive: true,
                identity: identity,
                glow: rowState.agentGlowTint
            )

            AdaptiveStack(spacing: 9) {
                Text(identity.name)
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(lineLimit)
                    .layoutPriority(1)

                Text(phrase)
                    .scaledFont(.subheadline)
                    .foregroundStyle(Color.conduitAccent)
                    .lineLimit(lineLimit)
                    .contentTransition(.opacity)
                    .animation(ConduitMotion.settle, value: phrase)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppLocalization.string("\(identity.name) is working"))
        .accessibilityValue(phrase)

        // The timer stays its own element, so VoiceOver reads it current.
        if largeText {
            // Under the words, not squeezed beside them.
            VStack(alignment: .leading, spacing: 6) {
                line
                timer
            }
        } else {
            HStack(spacing: 9) {
                line
                Spacer(minLength: 8)
                timer.fixedSize()
            }
        }
    }
}

// MARK: - Runs of steps

/// One thinking or tool step of a run, as the run's card needs it.
struct ChatStepGroupMember: Equatable {
    let messageID: String
    /// Nil for thinking.
    let toolName: String?
    /// The tool call's own id, the same live and in history.
    let toolID: String?
    /// The run's card changes with it (placement equality re-renders the
    /// rows when a step settles).
    let running: Bool
    let timestamp: String
    let duration: TimeInterval?

    init(_ message: ChatMessage) {
        messageID = message.id
        toolName = message.role == .tool ? message.tool?.name : nil
        toolID = message.role == .tool ? message.tool?.id : nil
        running = message.tool?.status == .running
        timestamp = message.timestamp
        duration = message.tool?.duration ?? message.stepDuration
    }

    var isThinking: Bool { toolName == nil }
}

/// A turn's consecutive thinking and tool rows. Two or more that show read
/// as one card: collapsed to a line of their icons ("4 steps · 12s") once
/// the turn is done, one row per step when opened.
struct ChatStepGroup: Equatable {
    let members: [ChatStepGroupMember]
    /// Nothing loaded follows the run. Only with a running turn does that
    /// mean the turn may still add to it; a history window can end on a
    /// finished run too.
    let isTrailing: Bool

    /// The run's first row; it keeps the run's open or closed choice.
    var id: String { members.first?.messageID ?? "" }

    /// Where the run's summary is kept (ChatStepSummaries).
    var summaryKey: String? { ChatStepSummaries.key(toolIDs: members.map(\.toolID)) }

    static func isStep(_ message: ChatMessage) -> Bool {
        switch message.role {
        case .reasoning:
            return !message.content.isEmpty
        case .tool:
            // A clarify reads as its own question card (#394), and cards
            // Hermes showed are part of the reply.
            guard let tool = message.tool else { return false }
            return tool.name.lowercased() != "clarify" && !RichCard.hasCards(message)
        default:
            return false
        }
    }

    /// The steps the display settings show.
    func visibleMembers(showReasoning: Bool, showTools: Bool) -> [ChatStepGroupMember] {
        members.filter { $0.isThinking ? showReasoning : showTools }
    }

    /// The steps a run's header counts: the ones Settings shows, thoughts
    /// shown on request aside (as a summary counts them), or the thoughts
    /// shown when Settings shows none of its steps.
    func countedMembers(showReasoning: Bool, thinkingShown: Bool, showTools: Bool) -> [ChatStepGroupMember] {
        let settingsVisible = visibleMembers(showReasoning: showReasoning, showTools: showTools)
        guard thinkingShown, settingsVisible.isEmpty else { return settingsVisible }
        return visibleMembers(showReasoning: true, showTools: showTools)
    }

    var hasThinking: Bool { members.contains(where: \.isThinking) }
}

struct ChatStepPlacement: Equatable {
    let group: ChatStepGroup
    let index: Int

    /// Whether this step's row draws anything (ChatStepRowBody): one hidden
    /// by the display settings, or inside a collapsed run (whose first row
    /// draws the run's line), draws nothing. The transcript leaves such rows
    /// out, because a LazyVStack spaces every row it is given, empty or not:
    /// a collapsed run of seven steps sat seven row spacings above the reply.
    @MainActor
    func drawsRow(
        messageID: String,
        preferences: ProfileDisplayPreferences,
        isBusy: Bool,
        disclosure: ChatRowDisclosure
    ) -> Bool {
        let showReasoning = preferences.showReasoning
            || (preferences.offersShowThinking && disclosure.showsThinking(in: group.id))
        let visible = group.visibleMembers(showReasoning: showReasoning, showTools: preferences.showToolProgress)
        guard let position = visible.firstIndex(where: { $0.messageID == messageID }) else { return false }
        guard visible.count >= 2, position > 0 else { return true }
        let live = group.isTrailing && isBusy
        return disclosure.isGroupExpanded(group.id, default: live || preferences.expandToolsByDefault)
    }
}

extension ChatMessageScrollTarget {
    /// A system row the transcript draws as a review card (MessageBubble):
    /// rows saved before reviews were tagged are told by their text.
    static func drawsReviewCard(_ message: ChatMessage) -> Bool {
        message.role == .system
            && (message.review != nil || MessageNormalizer.reviewActivity(fromText: message.content) != nil)
    }

    /// Whether the transcript draws this row: a self-improvement review
    /// while "Self-improvement updates" is off doesn't, nor one inside a
    /// closed run of reviews (ChatReviewPlacement.drawsRow), and a step follows
    /// ChatStepPlacement.drawsRow. The transcript leaves out a row that
    /// draws nothing, or the stack would space it.
    @MainActor
    func drawsRow(preferences: ProfileDisplayPreferences, isBusy: Bool, disclosure: ChatRowDisclosure) -> Bool {
        if !preferences.showReviews, isReview { return false }
        if let reviewRun, !reviewRun.drawsRow(disclosure: disclosure) { return false }
        return step?.drawsRow(messageID: id, preferences: preferences, isBusy: isBusy, disclosure: disclosure) ?? true
    }
}

// MARK: - Runs of reviews

/// Consecutive self-improvement reviews. Two or more read as one line
/// ("5 self-improvement reviews") with the last one's time, each card when
/// opened (#1518): a run of skill updates at the end of a chat filled the
/// screen. Closed by default, so a chat opens with them folded every time.
/// Reviews only report what Hermes saved; approvals, questions and errors
/// are rows of their own and end the run, so nothing that needs the reader
/// is ever folded into it.
struct ChatReviewRun: Equatable {
    let memberIDs: [String]
    let lastTimestamp: String

    /// The run's first row; it keeps the run's open or closed choice.
    var id: String { memberIDs.first ?? "" }
    var count: Int { memberIDs.count }
}

struct ChatReviewPlacement: Equatable {
    let run: ChatReviewRun
    let index: Int

    /// The run's first row draws its line, and its own card under the line
    /// while open; the others draw only while it is open.
    @MainActor
    func drawsRow(disclosure: ChatRowDisclosure) -> Bool {
        guard run.count >= 2, index > 0 else { return true }
        return disclosure.isGroupExpanded(run.id, default: false)
    }
}

/// How long steps took. Live steps are timed by Conduit (start stamped on
/// the row, end when it settles); history steps by Hermes' own duration
/// when it sends one, else its row times.
enum ChatStepTiming {
    static func elapsed(from start: String, to end: Date) -> TimeInterval? {
        guard let startDate = MessageTimestampFormatter.date(from: start) else { return nil }
        let value = end.timeIntervalSince(startDate)
        return value >= 0 ? value : nil
    }

    static func elapsed(from start: String, to end: String) -> TimeInterval? {
        guard let endDate = MessageTimestampFormatter.date(from: end) else { return nil }
        return elapsed(from: start, to: endDate)
    }

    /// From the first step's start to the last one's end; nil when the
    /// steps carry no usable times.
    static func span(of members: [ChatStepGroupMember]) -> TimeInterval? {
        var first: Date?
        var last: Date?
        for member in members {
            guard let start = MessageTimestampFormatter.date(from: member.timestamp) else { continue }
            let end = start.addingTimeInterval(member.duration ?? 0)
            first = min(first ?? start, start)
            last = max(last ?? end, end)
        }
        guard let first, let last else { return nil }
        return last.timeIntervalSince(first)
    }

    /// "12s", "1m 5s"; nil under a second, which reads as no time at all.
    static func text(_ seconds: TimeInterval?) -> String? {
        formatted(seconds, width: .narrow)
    }

    /// The same time in words, for VoiceOver ("12 seconds").
    static func spokenText(_ seconds: TimeInterval?) -> String? {
        formatted(seconds, width: .wide)
    }

    private static func formatted(_ seconds: TimeInterval?, width: Duration.UnitsFormatStyle.UnitWidth) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 1 else { return nil }
        return Duration.seconds(seconds.rounded())
            .formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: width)
                    .locale(AppLocalization.formattingLocale)
            )
    }
}

/// A thinking or tool row that belongs to a run of steps. Alone it is the
/// plain step card; with others it draws its slice of the run's card, or
/// nothing while the run is collapsed (the first row shows the summary,
/// which also tops the open card).
struct ChatStepRow: View {
    let message: ChatMessage
    let placement: ChatStepPlacement
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowDisclosure) private var disclosure
    @Environment(\.chatRowActions) private var actions

    var body: some View {
        let preferences = rowState.displayPreferences
        let key = placement.group.summaryKey
        if let disclosure {
            ChatStepRowBody(
                message: message,
                placement: placement,
                disclosure: disclosure,
                toggles: disclosure.groupToggles,
                profileShowsReasoning: preferences.showReasoning,
                offersShowThinking: preferences.offersShowThinking,
                showTools: preferences.showToolProgress,
                expandToolsByDefault: preferences.expandToolsByDefault,
                isBusy: rowState.isBusy,
                summary: key.flatMap { rowState.stepSummaries[$0] },
                lookingBack: key.map { rowState.stepSummariesAsked.contains($0) } ?? false,
                explain: rowState.canExplainStepRuns && key != nil ? { [actions] in
                    actions.required.explainStepRun(firstMessageID: placement.group.id)
                } : nil
            )
        } else {
            ChatStepRowBody.single(message)
        }
    }
}

private struct ChatStepRowBody: View {
    let message: ChatMessage
    let placement: ChatStepPlacement
    let disclosure: ChatRowDisclosure
    @ObservedObject var toggles: ChatStepGroupToggles
    /// Settings > Chat's Thinking is Show.
    let profileShowsReasoning: Bool
    /// It is On request: a run's menu can show its thinking anyway.
    let offersShowThinking: Bool
    let showTools: Bool
    let expandToolsByDefault: Bool
    let isBusy: Bool
    /// The run's summary, once Hermes wrote one.
    var summary: String?
    /// Hermes is writing it now.
    var lookingBack = false
    /// Asks Hermes to explain the run (its menu), when it can.
    var explain: (() -> Void)?

    @ViewBuilder
    static func single(_ message: ChatMessage, grouped: Bool = false, thinkingShown: Bool = false) -> some View {
        if message.role == .reasoning {
            ThinkingCard(message: message, grouped: grouped, shownAnyway: thinkingShown)
        } else {
            ToolCard(message: message, grouped: grouped)
        }
    }

    /// The reader asked to see this run's thinking (its menu or its reply's).
    private var thinkingShown: Bool {
        offersShowThinking && disclosure.showsThinking(in: placement.group.id)
    }

    /// Show thinking or Hide thinking, while Settings > Chat's Thinking is
    /// On request and the turn is done with the run.
    private var thinkingReveal: ChatThinkingReveal? {
        let group = placement.group
        guard offersShowThinking, group.hasThinking, !(group.isTrailing && isBusy) else { return nil }
        return ChatThinkingReveal(group: group, disclosure: disclosure)
    }

    var body: some View {
        let group = placement.group
        let thinkingShown = self.thinkingShown
        let visible = group.visibleMembers(showReasoning: profileShowsReasoning || thinkingShown, showTools: showTools)
        let counted = group.countedMembers(showReasoning: profileShowsReasoning, thinkingShown: thinkingShown, showTools: showTools)
        if let position = visible.firstIndex(where: { $0.messageID == message.id }) {
            if visible.count < 2 {
                // Whichever step is left showing carries the run's summary
                // and menu, a thought too when Settings > Chat hides the
                // tools (a run with no tool call has no Explain).
                if summary != nil || lookingBack || explain != nil || thinkingReveal != nil {
                    singleExplained(thinkingShown: thinkingShown)
                } else {
                    Self.single(message, thinkingShown: thinkingShown)
                }
            } else {
                // Open while the turn is still adding steps, so each one shows
                // as it happens; one line once it is done.
                let live = group.isTrailing && isBusy
                // Not over a step still marked running, hidden ones included.
                let offersExplain = !live && !group.members.contains(where: \.running)
                let expanded = disclosure.isGroupExpanded(group.id, default: live || expandToolsByDefault)
                let isFirst = position == 0
                let isLast = position == visible.count - 1
                if expanded {
                    VStack(alignment: .leading, spacing: 0) {
                        if isFirst {
                            ChatStepGroupHeader(
                                members: visible,
                                isLive: live,
                                expanded: true,
                                summary: summary,
                                lookingBack: lookingBack,
                                explain: offersExplain ? explain : nil,
                                thinking: thinkingReveal,
                                counted: counted,
                                toggle: { toggle(group, to: false) }
                            )
                        }
                        Self.single(message, grouped: true, thinkingShown: thinkingShown)
                    }
                    .background {
                        ChatStepSegmentShape(roundsTop: isFirst, roundsBottom: isLast)
                            .fill(Color.primary.opacity(0.05))
                        ChatStepSegmentBorder(roundsTop: isFirst, roundsBottom: isLast)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                    }
                    // Close the transcript's gap to the row above: one card.
                    .padding(.top, isFirst ? 0 : -ChatStepStyle.transcriptRowSpacing)
                } else if isFirst {
                    ChatStepGroupHeader(
                        members: visible,
                        isLive: live,
                        expanded: false,
                        summary: summary,
                        lookingBack: lookingBack,
                        explain: offersExplain ? explain : nil,
                        thinking: thinkingReveal,
                        counted: counted,
                        toggle: { toggle(group, to: true) }
                    )
                    .chatStepCard()
                }
            }
        }
    }

    /// A lone step: its card, then what Hermes said about its run, if it
    /// was asked (its menu).
    private func singleExplained(thinkingShown: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Self.single(message, thinkingShown: thinkingShown)
            if let summary {
                Text(summary)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ChatStepStyle.rowHorizontalPadding)
            }
            if lookingBack {
                ChatStepLookingBack()
                    .padding(.horizontal, ChatStepStyle.rowHorizontalPadding)
            }
        }
        .chatStepMenu(
            // Like the run's line: only once the turn is done with it.
            explain: (lookingBack || placement.group.members.contains(where: \.running) || (placement.group.isTrailing && isBusy)) ? nil : explain,
            title: summary == nil ? AppLocalization.string("Explain this step") : AppLocalization.string("Explain again"),
            thinking: thinkingReveal
        )
    }

    private func toggle(_ group: ChatStepGroup, to expanded: Bool) {
        withAnimation(ConduitMotion.response) {
            Haptics.light()
            disclosure.willToggleGroup(group.id, to: expanded)
        }
    }
}

/// The run's line: its steps' icons (collapsed), how many and how long,
/// and the chevron that opens or closes it.
private struct ChatStepGroupHeader: View {
    let members: [ChatStepGroupMember]
    let isLive: Bool
    let expanded: Bool
    /// What the run did, a few lines: under its icons folded, under the
    /// count at the top of the card open.
    var summary: String?
    var lookingBack = false
    /// Asks Hermes for the summary, or a new one (the run's menu).
    var explain: (() -> Void)?
    /// Shows or hides the run's thinking (the run's menu).
    var thinking: ChatThinkingReveal?
    /// The steps its count and time are of: `members` but for thoughts
    /// shown on request.
    var counted: [ChatStepGroupMember]?
    let toggle: () -> Void
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    private struct Look {
        let symbol: String
        let tint: Color
    }

    private static func look(_ member: ChatStepGroupMember) -> Look {
        guard let name = member.toolName else {
            return Look(symbol: ChatStepStyle.thinking.symbol, tint: ChatStepStyle.thinking.tint)
        }
        let style = ChatStepStyle(toolName: name)
        return Look(symbol: style.symbol, tint: style.tint)
    }

    /// The steps the discs draw: the ones counted, so the folded line
    /// shows the steps its count names.
    private var drawnMembers: [ChatStepGroupMember] { counted ?? members }

    /// One disc per kind of step, in order of first use.
    private var icons: [Look] {
        var seen = Set<String>()
        var result: [Look] = []
        for member in drawnMembers {
            let look = Self.look(member)
            if seen.insert(look.symbol).inserted { result.append(look) }
            if result.count == Self.maxIcons { break }
        }
        return result
    }

    private static let maxIcons = 5

    /// Over a summary: one disc per step, in order, as many as fit, then
    /// an ellipsis.
    private var stepIcons: some View {
        let members = drawnMembers
        let looks = members.prefix(Self.maxStepIcons).map(Self.look)
        // Each count tried in turn, the most first: all of them when the
        // run is short enough, else the cap with an ellipsis.
        let most = min(members.count, Self.maxStepIcons)
        let fits = Array(stride(from: most, through: 1, by: -1))
        return ViewThatFits(in: .horizontal) {
            ForEach(fits, id: \.self) { shown in
                HStack(spacing: 4) {
                    ForEach(Array(looks.prefix(shown).enumerated()), id: \.offset) { _, icon in
                        ChatStepIcon(symbol: icon.symbol, tint: icon.tint, size: 22)
                    }
                    if shown < members.count {
                        Text(verbatim: "…")
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private static let maxStepIcons = 16

    /// The run's count and, once it is done, its time (a running turn's
    /// time is on the working line): shown, then spoken.
    private var title: (shown: String, spoken: String) {
        let counted = self.counted ?? members
        let count = AppLocalization.string("\(counted.count) steps")
        let span = isLive ? nil : ChatStepTiming.span(of: counted)
        guard let time = ChatStepTiming.text(span),
              let spoken = ChatStepTiming.spokenText(span) else { return (count, count) }
        return ("\(count) · \(time)", "\(count), \(spoken)")
    }

    var body: some View {
        // Once: it parses every step's time.
        let title = self.title
        Button(action: toggle) {
            Group {
                if let summary, expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        countLayout(title)
                        summaryText(summary)
                        if lookingBack { lookingBackLine }
                    }
                    .accessibilityElement(children: .combine)
                } else if let summary {
                    summaryLayout(summary, title: title)
                } else if lookingBack {
                    VStack(alignment: .leading, spacing: 8) {
                        countLayout(title)
                        lookingBackLine
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    countLayout(title)
                }
            }
            .padding(.horizontal, ChatStepStyle.rowHorizontalPadding)
            .padding(.vertical, ChatStepStyle.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
        .chatStepMenu(
            // The caller leaves explain out over a step still marked running,
            // hidden ones included: Hermes isn't done with them.
            explain: lookingBack ? nil : explain,
            title: summary == nil ? AppLocalization.string("Explain these steps") : AppLocalization.string("Explain again"),
            thinking: thinking
        )
    }

    private var lookingBackLine: some View { ChatStepLookingBack() }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(.conduitTertiary)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            .accessibilityHidden(true)
    }

    /// Folded with a summary: every step's icon and the count on top, the
    /// summary under them at full width, never cut.
    private func summaryLayout(_ summary: String, title: (shown: String, spoken: String)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: ChatStepStyle.iconGap) {
                stepIcons
                Text(title.shown)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityLabel(title.spoken)
                Spacer(minLength: 8)
                chevron
            }
            summaryText(summary)
            if lookingBack { lookingBackLine }
        }
        // Read as one: the summary, then the count and time; the button's
        // own value says folded or open.
        .accessibilityElement(children: .combine)
    }

    /// The run's summary at full width, never cut: under the icons when
    /// folded, under the count at the top of the open card.
    private func summaryText(_ summary: String) -> some View {
        Text(summary)
            .scaledFont(.subheadline)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Folded without a summary, or open: the kinds of steps and the count.
    private func countLayout(_ title: (shown: String, spoken: String)) -> some View {
        HStack(spacing: ChatStepStyle.iconGap) {
            if !expanded {
                HStack(spacing: 4) {
                    ForEach(icons, id: \.symbol) { icon in
                        ChatStepIcon(symbol: icon.symbol, tint: icon.tint, size: 22)
                    }
                }
            }
            Text(title.shown)
                .scaledFont(expanded ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(title.spoken)
            Spacer(minLength: 8)
            chevron
        }
    }
}

/// While Hermes looks back on a run or step, under its count, its old
/// summary or the step's card.
struct ChatStepLookingBack: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text(AppLocalization.string("Hermes is looking back…"))
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Show thinking in a run's menu and its reply's ⋯ while Settings > Chat's
/// Thinking is On request: that run's thoughts, open, for as long as the
/// chat is on screen (Hide thinking puts the run back as it was). Nothing
/// is saved and nothing is asked of Hermes: the rows are already loaded.
struct ChatThinkingReveal {
    let shown: Bool
    let toggle: () -> Void

    @MainActor
    init(group: ChatStepGroup, disclosure: ChatRowDisclosure) {
        let shown = disclosure.showsThinking(in: group.id)
        self.shown = shown
        toggle = {
            withAnimation(ConduitMotion.response) {
                Haptics.light()
                disclosure.willShowThinking(in: group, !shown)
            }
        }
    }

    var title: String {
        shown ? AppLocalization.string("Hide thinking") : AppLocalization.string("Show thinking")
    }
}

extension View {
    /// A run's or a single step's menu (touch and hold), and the same
    /// actions for VoiceOver: asks Hermes to explain it, or shows its
    /// thinking.
    @ViewBuilder
    func chatStepMenu(explain: (() -> Void)?, title: String, thinking: ChatThinkingReveal? = nil) -> some View {
        if explain != nil || thinking != nil {
            contextMenu {
                if let explain {
                    Button(action: explain) {
                        Label(title, systemImage: "text.bubble")
                    }
                }
                if let thinking {
                    Button(action: thinking.toggle) {
                        Label(thinking.title, systemImage: ChatStepStyle.thinking.symbol)
                    }
                }
            }
            .accessibilityActions {
                if let explain {
                    Button(title, action: explain)
                }
                if let thinking {
                    Button(thinking.title, action: thinking.toggle)
                }
            }
        } else {
            self
        }
    }
}

/// One row's slice of a run's card: rounded only where the card begins
/// and ends.
struct ChatStepSegmentShape: Shape {
    let roundsTop: Bool
    let roundsBottom: Bool

    func path(in rect: CGRect) -> Path {
        let radius = ChatStepStyle.cardCornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: roundsTop ? radius : 0,
            bottomLeadingRadius: roundsBottom ? radius : 0,
            bottomTrailingRadius: roundsBottom ? radius : 0,
            topTrailingRadius: roundsTop ? radius : 0,
            // Circular, to match the hairline's arcs.
            style: .circular
        )
        .path(in: rect)
    }
}

/// The slice's hairline: its sides, plus the card's top or bottom edge
/// where it has one, so no line runs between the rows of one card.
struct ChatStepSegmentBorder: Shape {
    let roundsTop: Bool
    let roundsBottom: Bool

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: 0.25, dy: 0.25)
        guard rect.width > 0, rect.height > 0 else { return Path() }
        if roundsTop && roundsBottom {
            return ChatStepSegmentShape(roundsTop: true, roundsBottom: true).path(in: rect)
        }
        let radius = min(ChatStepStyle.cardCornerRadius, rect.height, rect.width / 2)
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        var path = Path()
        if roundsTop {
            // Down both sides from a rounded top edge.
            path.move(to: bottomLeft)
            path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: radius)
            path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: radius)
            path.addLine(to: bottomRight)
        } else if roundsBottom {
            // Down both sides into a rounded bottom edge.
            path.move(to: topLeft)
            path.addArc(tangent1End: bottomLeft, tangent2End: bottomRight, radius: radius)
            path.addArc(tangent1End: bottomRight, tangent2End: topRight, radius: radius)
            path.addLine(to: topRight)
        } else {
            path.move(to: topLeft)
            path.addLine(to: bottomLeft)
            path.move(to: topRight)
            path.addLine(to: bottomRight)
        }
        return path
    }
}
