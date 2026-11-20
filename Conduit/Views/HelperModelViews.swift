//
//  HelperModelViews.swift
//  Conduit
//
//  Settings > Models & providers > Helper models: the smaller jobs Hermes
//  runs beside a profile's chats (titles, compaction, image reading and the
//  rest of `/api/model/auxiliary`), each on the chat model unless it has a
//  model of its own. A helper's page is Voice replies' section, for that
//  slot; Voice settings shows the same `voice_chat` slot.
//

import SwiftUI

/// One of Hermes' helper model slots, named for Models & providers.
struct HelperModelSlot: Identifiable, Equatable {
    var id: String { setting.task }
    let setting: VoiceReplyModelSetting
    let title: String
    /// What the slot does, under its pickers.
    let caption: String
    let symbol: String
    /// A plugin slot that follows another slot while unpinned: that slot's
    /// title.
    let followsTitle: String?

    /// Slots set elsewhere in Conduit: Pulse's memory runs on the main
    /// profile only, and Settings > Pulse sets it there.
    static let setElsewhere: Set<String> = ["pulse_memory"]

    /// Conduit's predictions, a slot the Conduit plugin adds (0.124.0).
    static let predictions = "conduit_predict"

    /// The Conduit plugin's work watch (0.155.0): reads a bot's workstreams
    /// as they work; Edit Bot > Work sets it too.
    static let workWatch = "conduit_work_watch"

    /// Hermes' background review (what goes into memory, which skills to
    /// patch): `enabled` in its block turns the automatic one off, and two
    /// counters decide when it runs while on.
    static let backgroundReview = "background_review"

    /// Hermes' group router: who answers in a group chat set to pick
    /// automatically. Hermes reads it from the install's default profile for
    /// every room, so only that profile lists it (issue 2909).
    static let groupRouter = "group_router"

    /// Slots Hermes reads only from the default profile: another profile's
    /// would change nothing, so its list leaves them out.
    static let defaultProfileOnly: Set<String> = [groupRouter]

    /// A helper's own on/off switch, in its `auxiliary.<task>` block, and
    /// the intervals that decide when it runs while it's on.
    struct OnOff {
        let key: String
        let defaultValue: Bool
        let title: () -> String
        let label: () -> String
        let caption: () -> String
        var intervals: [Interval] = []

        /// Every config key the section reads: the switch's, then each
        /// interval's.
        var keys: [String] { [key] + intervals.map(\.key) }

        /// The switch as config holds it; unset, Hermes' default.
        func isOn(in values: [String: ProfileSettingValue]) -> Bool {
            values[key]?.boolValue ?? defaultValue
        }
    }

    /// A counter in the profile's config: the helper runs each time it
    /// reaches this many, and 0 turns that kind of run off.
    struct Interval: Identifiable {
        var id: String { key }
        let key: String
        let defaultValue: Int
        let label: () -> String
        let caption: () -> String

        /// As Hermes reads it (`int()` of the value); unset or unreadable,
        /// Hermes' default.
        func value(in values: [String: ProfileSettingValue]) -> Int {
            switch values[key] {
            case .number(let number) where number.isFinite && abs(number) < 1e9: return Int(number)
            case .text(let text): return Int(text.trimmingCharacters(in: .whitespaces)) ?? defaultValue
            default: return defaultValue
            }
        }

        /// What someone typed: a whole number, 0 or more, digits only (a
        /// pasted "1,000" is refused rather than read as 1); nil otherwise.
        static func parse(_ raw: String) -> Int? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...9).contains(trimmed.count), trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(trimmed)
        }
    }

    /// The helpers with an on/off switch of their own: Background review's,
    /// its biggest cost lever (issue 2871). Hermes checks two counters after
    /// each turn and reviews only when one reaches its interval
    /// (`memory.nudge_interval`, user turns, for memory;
    /// `skills.creation_nudge_interval`, tool-calling steps, for skills;
    /// both 10 by default, 0 off), so they show under it (issue 2905).
    static func onOff(task: String) -> OnOff? {
        guard task == backgroundReview else { return nil }
        return OnOff(
            key: "auxiliary.background_review.enabled",
            defaultValue: true,
            title: { AppLocalization.string("Automatic review", table: .bots) },
            label: { AppLocalization.string("On") },
            caption: { AppLocalization.string("Runs when the memory or skill interval below is reached. Off, Hermes reviews a chat only when you ask with /refine.", table: .bots) },
            intervals: [
                Interval(
                    key: "memory.nudge_interval",
                    defaultValue: 10,
                    label: { AppLocalization.string("Messages between memory reviews", table: .bots) },
                    caption: { AppLocalization.string("How many of your messages before Hermes looks for what to remember about you. 0 turns memory review off.", table: .bots) }
                ),
                Interval(
                    key: "skills.creation_nudge_interval",
                    defaultValue: 10,
                    label: { AppLocalization.string("Tool steps between skill reviews", table: .bots) },
                    caption: { AppLocalization.string("How many tool-using steps before Hermes looks for a skill to create or improve. 0 turns skill review off.", table: .bots) }
                ),
            ]
        )
    }

    /// `/api/model/auxiliary`'s answer as the phone keeps it: each slot's
    /// endpoint as its scheme, host and port only, since a path can carry a
    /// token and the page shows only the host.
    static func keptAnswer(_ answer: [String: Any]) -> [String: Any] {
        guard let tasks = answer["tasks"] as? [[String: Any]] else { return answer }
        var kept = answer
        // An inheriting plugin slot's `effective` route carries one too.
        func keptEndpoint(_ fields: [String: Any]) -> [String: Any] {
            guard let url = fields["base_url"] as? String, !url.isEmpty else { return fields }
            var fields = fields
            fields["base_url"] = ProviderCatalog.keptAddress(url)
            return fields
        }
        kept["tasks"] = tasks.map { row -> [String: Any] in
            var row = keptEndpoint(row)
            if let effective = row["effective"] as? [String: Any] { row["effective"] = keptEndpoint(effective) }
            return row
        }
        return kept
    }

    /// Posted once Hermes took a slot's new model: a list read asked before
    /// it may answer with the old one, so the lists read again.
    static let saved = Notification.Name("conduit.helperModels.saved")

    /// The slots of a `/api/model/auxiliary` answer, in Hermes' order:
    /// built-ins, then the plugins'.
    /// `includingSetElsewhere` keeps Pulse's too, for the checks that ask
    /// what runs on a provider; `inDefaultProfile` false leaves out the
    /// slots only the default profile's config sets.
    static func slots(in response: [String: Any], includingSetElsewhere: Bool = false, inDefaultProfile: Bool = true) -> [HelperModelSlot] {
        let rows = response["tasks"] as? [[String: Any]] ?? []
        let titles = Dictionary(
            rows.compactMap { row -> (String, String)? in
                guard let task = row["task"] as? String else { return nil }
                return (task, title(task: task, label: row["label"] as? String))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return rows.compactMap { row in
            guard let setting = VoiceReplyModelSetting(row: row),
                  includingSetElsewhere || !setElsewhere.contains(setting.task),
                  includingSetElsewhere || inDefaultProfile || !defaultProfileOnly.contains(setting.task) else { return nil }
            let task = setting.task
            let inherits = (row["inherit_from"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return HelperModelSlot(
                setting: setting,
                title: titles[task] ?? task,
                caption: caption(task: task, hint: row["hint"] as? String),
                symbol: builtIn[task]?.symbol ?? (row["plugin"] as? String == nil ? "cpu" : "puzzlepiece.extension"),
                followsTitle: inherits.map { titles[$0] ?? $0 }
            )
        }
    }

    /// Runs on the chat model or the slot it follows.
    var followsChats: Bool { setting.followsChats }

    /// The model it runs on, or what it follows; a slot on an endpoint of
    /// its own names its host.
    var value: String {
        if setting.followsChats {
            return followsTitle.map { AppLocalization.string("Same as \($0)", table: .bots) } ?? AppLocalization.string("Same as chats")
        }
        let model = setting.providerOnly
            ? VoiceJobModelSettingsSection.providerDefaultTitle(setting.provider)
            : setting.model
        return setting.endpointHost.map { model + " · " + $0 } ?? model
    }

    /// "Same as chats" in the model picker, or the slot it follows.
    var followTitle: String {
        followsTitle.map { AppLocalization.string("Same as \($0)", table: .bots) } ?? AppLocalization.string("Same as chats")
    }

    // MARK: Names

    private struct Words {
        let title: () -> String
        let caption: () -> String
        let symbol: String
    }

    /// Hermes labels its own slots in its web page, not in the answer, so
    /// Conduit names them; Conduit's plugin slot too, in the app's language.
    private static let builtIn: [String: Words] = [
        "vision": Words(title: { AppLocalization.string("Image reading", table: .bots) },
                        caption: { AppLocalization.string("Reads pictures and screenshots for a chat model that can't see them.", table: .bots) },
                        symbol: "eye"),
        "compression": Words(title: { AppLocalization.string("Compaction", table: .bots) },
                             caption: { AppLocalization.string("Summarizes a long chat so it still fits the model's context.", table: .bots) },
                             symbol: "arrow.down.right.and.arrow.up.left"),
        "skills_hub": Words(title: { AppLocalization.string("Skill search", table: .bots) },
                            caption: { AppLocalization.string("Finds skills in the Skills Hub.", table: .bots) },
                            symbol: "magnifyingglass"),
        "approval": Words(title: { AppLocalization.string("Smart approvals", table: .bots) },
                          caption: { AppLocalization.string("Decides which commands are safe to run without asking you, when smart approvals are on.", table: .bots) },
                          symbol: "checkmark.shield"),
        // Hermes runs it only when an MCP server asks for a completion
        // (sampling/createMessage); the chat model picks tools (issue 2877).
        "mcp": Words(title: { AppLocalization.string("MCP sampling", table: .bots) },
                     caption: { AppLocalization.string("Answers when an MCP server asks Hermes’ model to write something. It doesn’t choose tools.", table: .bots) },
                     symbol: "point.3.connected.trianglepath.dotted"),
        "title_generation": Words(title: { AppLocalization.string("Chat titles", table: .bots) },
                                  caption: { AppLocalization.string("Names new chats.", table: .bots) },
                                  symbol: "textformat"),
        "review": Words(title: { AppLocalization.string("Code review", table: .bots) },
                        caption: { AppLocalization.string("Runs the /review command's reviewer.", table: .bots) },
                        symbol: "doc.text.magnifyingglass"),
        VoiceReplyModelSetting.task: Words(
            title: { AppLocalization.string("Voice replies") },
            caption: { AppLocalization.string("The model Hermes answers you with in a voice conversation. Reasoning is off by default so replies start sooner; typed messages keep the chat's model. Hermes Desktop uses this setting too.") },
            symbol: "waveform.circle"
        ),
        "triage_specifier": Words(title: { AppLocalization.string("Kanban task details", table: .bots) },
                                  caption: { AppLocalization.string("Fills in a new Kanban task's details.", table: .bots) },
                                  symbol: "list.bullet.rectangle"),
        "kanban_decomposer": Words(title: { AppLocalization.string("Kanban task splitting", table: .bots) },
                                   caption: { AppLocalization.string("Splits a Kanban task into smaller ones.", table: .bots) },
                                   symbol: "square.split.2x2"),
        "profile_describer": Words(title: { AppLocalization.string("Profile descriptions", table: .bots) },
                                   caption: { AppLocalization.string("Writes a profile's description.", table: .bots) },
                                   symbol: "person.text.rectangle"),
        "curator": Words(title: { AppLocalization.string("Skill curator", table: .bots) },
                         caption: { AppLocalization.string("Reviews how skills are used and suggests improvements.", table: .bots) },
                         symbol: "sparkles"),
        // Listed by the Conduit plugin from 0.184.0 until Hermes lists it
        // (issue 2871). Hermes ignores its reasoning while it runs on the
        // chat's model, which keeps the chat's prompt cache.
        backgroundReview: Words(title: { AppLocalization.string("Background review", table: .bots) },
                                caption: { AppLocalization.string("Every few turns, looks back over a chat to decide what goes into memory and which skills to improve. Its reasoning applies only on a model of its own, which starts without the chat’s prompt cache.", table: .bots) },
                                symbol: "brain.head.profile"),
        // Listed by the Conduit plugin from 0.186.0 until Hermes lists it
        // (issue 2909); Group Settings links here under Pick who answers
        // automatically.
        groupRouter: Words(title: { AppLocalization.string("Group router", table: .bots) },
                           caption: { AppLocalization.string("Picks who answers a message that names nobody, in group chats set to pick automatically. Hermes uses this profile’s choice for every group chat on this Hermes.", table: .bots) },
                           symbol: "arrow.triangle.branch"),
        predictions: Words(title: { AppLocalization.string("Conduit predictions", table: .bots) },
                                 caption: { AppLocalization.string("Suggested replies and draft guesses in Conduit, when Predictive uses the fast model.", table: .bots) },
                                 symbol: "wand.and.stars"),
        workWatch: Words(title: { AppLocalization.string("Conduit work watch", table: .bots) },
                         caption: { AppLocalization.string("Reads what a bot’s workstreams report while they work and tells its Bot Chat when one may affect another.", table: .bots) },
                         symbol: "binoculars"),
    ]

    private static func title(task: String, label: String?) -> String {
        if let words = builtIn[task] { return words.title() }
        let label = label?.trimmingCharacters(in: .whitespaces) ?? ""
        if !label.isEmpty { return label }
        // A slot a newer Hermes added: its key, readable.
        let spaced = task.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static func caption(task: String, hint: String?) -> String {
        if let words = builtIn[task] { return words.caption() }
        return hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// What the helper model screens need from the app.
struct HelperModelsSettingsModel {
    var kept: () -> [HelperModelSlot]?
    /// Throws when Hermes didn't answer.
    var load: () async throws -> [HelperModelSlot]
    /// A slot's page: Voice replies' section, for that slot.
    var slot: (HelperModelSlot) -> VoiceReplyModelSettingsModel
    /// Its on/off switch and intervals, for a helper that has one.
    var onOff: (HelperModelSlot) -> HelperModelSwitchModel? = { _ in nil }
}

/// A helper's on/off switch and its intervals, read and saved in the
/// profile's config, by key (HelperModelSlot.OnOff.keys).
struct HelperModelSwitchModel {
    /// As last read, kept on the phone; nil when no config is kept.
    var kept: () -> [String: ProfileSettingValue]?
    /// Nil when Hermes didn't answer.
    var load: () async -> [String: ProfileSettingValue]?
    var save: (String, ProfileSettingValue) async -> Bool
}

/// The Helper models row on Models & providers.
struct HelperModelsSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let settings: HelperModelsSettingsModel
    @State private var slots: [HelperModelSlot]?
    /// Names the newest read: an older one that answers later is dropped.
    @State private var reads = 0
    /// Hermes has no slots route (an older Hermes) and nothing is kept, so
    /// the row isn't offered. Any other failure keeps it, for the page's
    /// Try Again.
    @State private var unavailable = false

    var body: some View {
        Group {
            if !(unavailable && slots == nil) { section }
        }
        // Kept first, then Hermes, each time the page shows: a helper's
        // page may have changed one.
        .onAppear {
            if slots == nil { slots = settings.kept() }
            Task { await read() }
        }
        .onReceive(NotificationCenter.default.publisher(for: HelperModelSlot.saved)) { _ in
            Task { await read() }
        }
    }

    private var section: some View {
        ConduitSettingsSection(title: AppLocalization.string("Helper models", table: .bots), symbol: "square.stack.3d.up", tint: .conduitAura) {
            Text(AppLocalization.string("Smaller jobs Hermes runs beside your chats, like titles, compaction and reading images. Each uses the chat model unless you pick one.", table: .bots))
                .scaledFont(.footnote).foregroundStyle(.secondary)
            NavigationLink {
                HelperModelsPage(settings: settings)
                    .v2TabBarClearance()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalization.string("Helper models", table: .bots))
                            .scaledFont(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let summary {
                            Text(verbatim: summary)
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .scaledFont(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.models.helpers")
        }
    }

    private func read() async {
        reads += 1
        let read = reads
        do {
            let loaded = try await settings.load()
            guard read == reads else { return }
            slots = loaded
            unavailable = false
        } catch {
            guard read == reads else { return }
            if ProviderSettingsService.isNotFound(error) { unavailable = true }
        }
    }

    private var summary: String? {
        guard let slots, !slots.isEmpty else { return nil }
        let own = slots.filter { !$0.followsChats }.count
        return own == 0
            ? AppLocalization.string("All use the chat model", table: .bots)
            : AppLocalization.string("\(String(own)) of \(String(slots.count)) have a model of their own", table: .bots)
    }
}

/// Every helper model, each opening its own page.
struct HelperModelsPage: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let settings: HelperModelsSettingsModel
    @State private var slots: [HelperModelSlot]?
    @State private var failed = false
    /// Names the newest read: an older one that answers later is dropped.
    @State private var reads = 0

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: AppLocalization.string("Helper models", table: .bots), symbol: "square.stack.3d.up", tint: .conduitAura) {
                Text(AppLocalization.string("Hermes runs these jobs on the chat model unless you pick one. A small, fast model saves time and money on most of them.", table: .bots))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                if let slots {
                    if slots.isEmpty {
                        Text(AppLocalization.string("This Hermes has no helper models to set.", table: .bots))
                            .scaledFont(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(slots) { slot in
                        NavigationLink {
                            HelperModelPage(slot: slot, settings: settings.slot(slot), onOff: settings.onOff(slot))
                                .v2TabBarClearance()
                        } label: {
                            HelperModelRow(slot: slot)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.models.helpers.\(slot.id)")
                    }
                } else if !failed {
                    ProgressView().frame(maxWidth: .infinity).accessibilityLabel(AppLocalization.string("Loading…"))
                }
                if failed {
                    // What's listed stays up; Hermes didn't answer.
                    ModelCatalogPlaceholder(state: .failed) { Task { await read() } }
                }
            }
        }
        .navigationTitle(AppLocalization.string("Helper models", table: .bots))
        // Again on coming back from a helper's page.
        .onAppear {
            if slots == nil { slots = settings.kept() }
            Task { await read() }
        }
        .onReceive(NotificationCenter.default.publisher(for: HelperModelSlot.saved)) { _ in
            Task { await read() }
        }
    }

    private func read() async {
        reads += 1
        let read = reads
        do {
            let loaded = try await settings.load()
            guard read == reads else { return }
            slots = loaded
            failed = false
        } catch {
            guard read == reads else { return }
            failed = true
        }
    }
}

private struct HelperModelRow: View {
    let slot: HelperModelSlot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: slot.symbol)
                .foregroundStyle(Color.conduitAura)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: slot.title)
                    .scaledFont(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(verbatim: slot.value)
                    .scaledFont(.caption)
                    .foregroundStyle(slot.followsChats ? Color.secondary : Color.conduitAccent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .scaledFont(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One helper's model and reasoning, and its on/off switch when it has one.
struct HelperModelPage: View {
    let slot: HelperModelSlot
    let settings: VoiceReplyModelSettingsModel
    var onOff: HelperModelSwitchModel? = nil

    var body: some View {
        SettingsDetailContainer {
            VoiceReplyModelSettingsSection(settings: settings, helper: slot)
            if let onOff, let words = HelperModelSlot.onOff(task: slot.id) {
                HelperModelSwitchSection(words: words, settings: onOff)
            }
        }
        .navigationTitle(slot.title)
    }
}

/// A helper's on/off switch and its intervals: they open on the kept
/// config, then Hermes' answer, and go back if a save fails. The intervals
/// rest while the switch is off.
private struct HelperModelSwitchSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let words: HelperModelSlot.OnOff
    let settings: HelperModelSwitchModel
    /// Nil until read, kept or from Hermes.
    @State private var values: [String: ProfileSettingValue]?
    /// The setting being saved: one at a time, as the profile pages do.
    @State private var savingKey: String?
    /// Counts saves as they start and land, so a read asked before or
    /// during one doesn't undo it on landing.
    @State private var saves = 0
    /// Hermes didn't answer and nothing is kept: Try Again.
    @State private var failed = false
    /// What's typed in an interval's field, until saved.
    @State private var drafts: [String: String] = [:]
    /// Under an interval's field: a number it can't take, or a failed save.
    @State private var errors: [String: String] = [:]

    private var isOn: Bool { values.map(words.isOn(in:)) ?? words.defaultValue }

    var body: some View {
        ConduitSettingsSection(title: words.title(), symbol: "clock.arrow.circlepath", tint: .conduitAura) {
            Toggle(words.label(), isOn: Binding(get: { isOn }, set: { save(words.key, .bool($0)) }))
                .tint(.conduitAccent)
                .disabled(values == nil || savingKey != nil)
                .accessibilityLabel(Text(verbatim: words.title()))
                .accessibilityIdentifier("settings.models.helpers.onOff")
            Text(verbatim: words.caption())
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(words.intervals) { interval in
                intervalRow(interval)
            }
            if failed && values == nil {
                ModelCatalogPlaceholder(state: .failed) { Task { await read() } }
            }
        }
        .onAppear { if values == nil { values = settings.kept() } }
        .task { await read() }
    }

    private func intervalRow(_ interval: HelperModelSlot.Interval) -> some View {
        let shown = values.map { String(interval.value(in: $0)) } ?? ""
        let draft = drafts[interval.key] ?? shown
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: interval.label())
                .scaledFont(.subheadline.weight(.semibold))
            AdaptiveStack(spacing: 8) {
                // No placeholder until a value is known: "10" would read as
                // the setting.
                TextField(values == nil ? "" : String(interval.defaultValue), text: Binding(
                    get: { draft },
                    set: {
                        drafts[interval.key] = $0
                        errors[interval.key] = nil
                    }
                ))
                .keyboardType(.numberPad)
                .padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 44).conduitGlassSurface(cornerRadius: 14)
                .accessibilityLabel(Text(verbatim: interval.label()))
                .accessibilityIdentifier("settings.models.helpers.interval.\(interval.key)")
                Button(AppLocalization.string("Save")) { saveInterval(interval, raw: draft) }
                    .buttonStyle(.settingsPrimary)
                    .disabled(savingKey != nil || draft == shown)
                    .accessibilityLabel(Text(verbatim: "\(AppLocalization.string("Save")): \(interval.label())"))
            }
            Text(verbatim: interval.caption())
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = errors[interval.key] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .disabled(values == nil || !isOn)
        .opacity(isOn ? 1 : 0.5)
    }

    private func read() async {
        let asked = saves
        let answer = await settings.load()
        guard asked == saves else { return }
        guard let answer else {
            failed = true
            return
        }
        failed = false
        values = answer
    }

    private func saveInterval(_ interval: HelperModelSlot.Interval, raw: String) {
        guard let number = HelperModelSlot.Interval.parse(raw) else {
            errors[interval.key] = AppLocalization.string("Enter a whole number, 0 or more.", table: .bots)
            return
        }
        // The draft stays until Hermes took it, so a failed save keeps what
        // was typed for Try Again.
        save(interval.key, .number(Double(number))) { saved in
            if saved, drafts[interval.key] == raw { drafts[interval.key] = nil }
        }
    }

    private func save(_ key: String, _ value: ProfileSettingValue, then done: @escaping (Bool) -> Void = { _ in }) {
        let before = values
        values = (values ?? [:]).merging([key: value]) { _, new in new }
        savingKey = key
        saves += 1
        errors[key] = nil
        Task {
            let saved = await settings.save(key, value)
            // A read asked while this save was on its way may answer with
            // the config before it: counting again drops it.
            saves += 1
            savingKey = nil
            if !saved {
                values = before
                if key != words.key { errors[key] = AppLocalization.string("Couldn’t save that change. Try again.", table: .bots) }
            }
            done(saved)
            // A read dropped for this save may have held the other keys'
            // values: read them all again.
            if saved { await read() }
        }
    }
}
