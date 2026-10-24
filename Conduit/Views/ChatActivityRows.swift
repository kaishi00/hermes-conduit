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
            return ChatStepStyle(toolName: currentToolName).runningTitle
        }
        return isThinking ? AppLocalization.string("Thinking") : AppLocalization.string("Working…")
    }

    /// Counts on its own; this view doesn't re-render each second.
    @ViewBuilder
    private var timer: some View {
        if let startedAt {
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                .font(.caption.weight(.medium))
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(lineLimit)
                    .layoutPriority(1)

                Text(phrase)
                    .font(.subheadline)
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
    /// The run's card changes with it (placement equality re-renders the
    /// rows when a step settles).
    let running: Bool
    let timestamp: String
    let duration: TimeInterval?

    init(_ message: ChatMessage) {
        messageID = message.id
        toolName = message.role == .tool ? message.tool?.name : nil
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
        let visible = group.visibleMembers(showReasoning: preferences.showReasoning, showTools: preferences.showToolProgress)
        guard let position = visible.firstIndex(where: { $0.messageID == messageID }) else { return false }
        guard visible.count >= 2, position > 0 else { return true }
        let live = group.isTrailing && isBusy
        return disclosure.isGroupExpanded(group.id, default: live || preferences.expandToolsByDefault)
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
/// nothing while the run is collapsed (the first row shows the summary).
struct ChatStepRow: View {
    let message: ChatMessage
    let placement: ChatStepPlacement
    @Environment(\.chatRowState) private var rowState
    @Environment(\.chatRowDisclosure) private var disclosure

    var body: some View {
        let preferences = rowState.displayPreferences
        if let disclosure {
            ChatStepRowBody(
                message: message,
                placement: placement,
                disclosure: disclosure,
                toggles: disclosure.groupToggles,
                showReasoning: preferences.showReasoning,
                showTools: preferences.showToolProgress,
                expandToolsByDefault: preferences.expandToolsByDefault,
                isBusy: rowState.isBusy
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
    let showReasoning: Bool
    let showTools: Bool
    let expandToolsByDefault: Bool
    let isBusy: Bool

    @ViewBuilder
    static func single(_ message: ChatMessage, grouped: Bool = false) -> some View {
        if message.role == .reasoning {
            ThinkingCard(message: message, grouped: grouped)
        } else {
            ToolCard(message: message, grouped: grouped)
        }
    }

    var body: some View {
        let group = placement.group
        let visible = group.visibleMembers(showReasoning: showReasoning, showTools: showTools)
        if let position = visible.firstIndex(where: { $0.messageID == message.id }) {
            if visible.count < 2 {
                Self.single(message)
            } else {
                // Open while the turn is still adding steps, so each one shows
                // as it happens; one line once it is done.
                let live = group.isTrailing && isBusy
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
                                toggle: { toggle(group, to: false) }
                            )
                        }
                        Self.single(message, grouped: true)
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
                        toggle: { toggle(group, to: true) }
                    )
                    .chatStepCard()
                }
            }
        }
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
    let toggle: () -> Void
    @ObservedObject private var appLanguage = AppLanguageStore.shared

    private struct Look {
        let symbol: String
        let tint: Color
    }

    /// One disc per kind of step, in order of first use.
    private var icons: [Look] {
        var seen = Set<String>()
        var result: [Look] = []
        for member in members {
            let look: Look
            if let name = member.toolName {
                let style = ChatStepStyle(toolName: name)
                look = Look(symbol: style.symbol, tint: style.tint)
            } else {
                look = Look(symbol: ChatStepStyle.thinking.symbol, tint: ChatStepStyle.thinking.tint)
            }
            if seen.insert(look.symbol).inserted { result.append(look) }
            if result.count == Self.maxIcons { break }
        }
        return result
    }

    private static let maxIcons = 5

    /// The run's count and, once it is done, its time (a running turn's
    /// time is on the working line): shown, then spoken.
    private var title: (shown: String, spoken: String) {
        let count = AppLocalization.string("\(members.count) steps")
        let span = isLive ? nil : ChatStepTiming.span(of: members)
        guard let time = ChatStepTiming.text(span),
              let spoken = ChatStepTiming.spokenText(span) else { return (count, count) }
        return ("\(count) · \(time)", "\(count), \(spoken)")
    }

    var body: some View {
        // Once: it parses every step's time.
        let title = self.title
        Button(action: toggle) {
            HStack(spacing: ChatStepStyle.iconGap) {
                if !expanded {
                    HStack(spacing: 4) {
                        ForEach(icons, id: \.symbol) { icon in
                            ChatStepIcon(symbol: icon.symbol, tint: icon.tint, size: 22)
                        }
                    }
                }
                Text(title.shown)
                    .font(expanded ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(title.spoken)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.conduitTertiary)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, ChatStepStyle.rowHorizontalPadding)
            .padding(.vertical, ChatStepStyle.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
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
