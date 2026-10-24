import ActivityKit
import Foundation

/// A running Hermes turn on the Lock Screen and in the Dynamic Island
/// (#605). Conduit starts one when it sends a turn and updates it from the
/// chat's stream while it runs; once Conduit is in the background the
/// notifier plugin keeps it current through the relay
/// (hermes-conduit-notifier `live_activity.py`, relay `live-activities.mjs`).
///
/// The attributes stay on the phone (the chat's title never reaches the
/// relay). `ContentState` is what pushes carry: its JSON keys are the
/// relay's `content-state` keys, so keep them in step.
struct HermesTurnAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// A `HermesTurnPhase` raw value; unknown values read as thinking.
        var phase: String
        /// A `HermesToolCategory` raw value while a tool runs.
        var tool: String?
        /// Tools started this turn.
        var tools: Int
        /// How full the context is, in percent.
        var context: Int?
        /// When the turn ended, in seconds since 1970 (pushes can't carry a
        /// `Date` in a form ActivityKit's decoder reads).
        var endedAt: Double?

        init(phase: HermesTurnPhase, tool: HermesToolCategory? = nil, tools: Int = 0, context: Int? = nil, endedAt: Date? = nil) {
            self.phase = phase.rawValue
            self.tool = tool?.rawValue
            self.tools = tools
            self.context = context
            self.endedAt = endedAt?.timeIntervalSince1970
        }

        var turnPhase: HermesTurnPhase { HermesTurnPhase(rawValue: phase) ?? .thinking }
        var toolCategory: HermesToolCategory? { tool.flatMap(HermesToolCategory.init(rawValue:)) }
        var endDate: Date? { endedAt.map(Date.init(timeIntervalSince1970:)) }
    }

    /// The chat's title when the turn started.
    var chatTitle: String
    var startedAt: Date
    /// Conduit's UI language (`AppLanguageStore`), so the activity speaks
    /// the same language as the app.
    var language: String
    /// Opens the chat (`conduit://session/<id>?profile=<name>&dashboard=<uuid>`).
    var link: URL
    /// Every id the chat is known under (runtime, stored, lineage), so the
    /// app can tell which chat's events update it after a relaunch.
    var sessionIDs: [String]
    /// The profile's name and its backdrop glow color (`#rrggbb`), so the
    /// card is lit like the app. Optional: activities started by an older
    /// build decode without them.
    var profileName: String? = nil
    var glowHex: String? = nil
    /// The saved dashboard the turn ran on (`SavedDashboard.id`), so a
    /// relaunched Conduit settles it only against that dashboard's live
    /// sessions. Optional: activities started by an older build have none.
    var dashboardID: String? = nil

    /// The glow color (`#rrggbb` only, as `ProfileGlowRGB.hex` writes it),
    /// nil when there is none or it doesn't parse.
    var glowColor: (red: Double, green: Double, blue: Double)? {
        guard var hex = glowHex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }
}

enum HermesTurnPhase: String, Codable, CaseIterable {
    case thinking
    case writing
    case tool
    case approval
    case input
    case done
    case failed
    case stopped

    var isFinished: Bool { self == .done || self == .failed || self == .stopped }
    var waitsOnUser: Bool { self == .approval || self == .input }
}

/// What kind of tool is running. Same list as the plugin's
/// `live_activity.tool_category`: never a tool's own name.
enum HermesToolCategory: String, Codable, CaseIterable {
    case tool, terminal, code, files, web, browser, agents, memory, images, audio
    case planning, schedule, messages, skills, connector, phone, home

    private static let exact: [String: HermesToolCategory] = [
        "terminal": .terminal, "process": .terminal, "execute_code": .code,
        "read_file": .files, "write_file": .files, "patch": .files, "search_files": .files,
        "web_search": .web, "web_extract": .web, "web_crawl": .web,
        "delegate_task": .agents, "memory": .memory, "session_search": .memory,
        "vision_analyze": .images, "image_generate": .images, "text_to_speech": .audio,
        "todo": .planning, "cronjob": .schedule, "send_message": .messages, "message_agent": .messages,
        "skill_view": .skills, "skills_list": .skills, "skill_manage": .skills,
    ]
    private static let prefixes: [(String, HermesToolCategory)] = [
        ("browser_", .browser), ("mcp_", .connector), ("conduit_", .phone),
        ("ha_", .home), ("web_", .web), ("skill", .skills),
    ]

    init(toolName: String) {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let category = Self.exact[name] {
            self = category
        } else if let match = Self.prefixes.first(where: { name.hasPrefix($0.0) }) {
            self = match.1
        } else {
            self = .tool
        }
    }
}

/// The words the activity shows, in the app's language. Every key here is
/// in Conduit/Localizable.xcstrings (the widget extension bundles it).
enum HermesTurnCopy {
    static func status(_ state: HermesTurnAttributes.ContentState, language: String) -> String {
        WidgetLocalization.string(statusKey(state), language: language)
    }

    static func statusKey(_ state: HermesTurnAttributes.ContentState) -> String {
        switch state.turnPhase {
        case .thinking: "Thinking"
        case .writing: "Writing"
        case .approval: "Waiting for your approval"
        case .input: "Waiting for your answer"
        case .done: "Finished"
        case .failed: "Turn failed"
        case .stopped: "Stopped"
        case .tool: toolKey(state.toolCategory ?? .tool)
        }
    }

    static func toolKey(_ category: HermesToolCategory) -> String {
        switch category {
        case .tool: "Using a tool"
        case .terminal: "Running a command"
        case .code: "Running code"
        case .files: "Working with files"
        case .web: "Searching the web"
        case .browser: "Using the browser"
        case .agents: "Working with subagents"
        case .memory: "Checking memory"
        case .images: "Working with images"
        case .audio: "Making audio"
        case .planning: "Planning"
        case .schedule: "Scheduling"
        case .messages: "Sending a message"
        case .skills: "Using a skill"
        case .connector: "Using a connector"
        case .phone: "Using your iPhone"
        case .home: "Using your smart home"
        }
    }

    /// Interpolated like AppLocalization, so the catalog's plural
    /// variants ("1 tool", Russian one/few/many) are picked.
    static func tools(_ count: Int, language: String) -> String {
        String(localized: "\(count) tools", bundle: WidgetLocalization.bundle(language: language), locale: locale(language))
    }

    static func context(_ percent: Int, language: String) -> String {
        // Pushed states skip the app's own clamp.
        let clamped = max(0, min(100, percent))
        let value = (Double(clamped) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale(language)))
        return String(localized: "Context \(value)", bundle: WidgetLocalization.bundle(language: language), locale: locale(language))
    }

    static func locale(_ language: String) -> Locale {
        language == "system" || language.isEmpty ? .current : Locale(identifier: language)
    }
}
