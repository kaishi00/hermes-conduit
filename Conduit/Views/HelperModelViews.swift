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

    /// Posted once Hermes took a slot's new model: a list read asked before
    /// it may answer with the old one, so the lists read again.
    static let saved = Notification.Name("conduit.helperModels.saved")

    /// The slots of a `/api/model/auxiliary` answer, in Hermes' order:
    /// built-ins, then the plugins'.
    static func slots(in response: [String: Any]) -> [HelperModelSlot] {
        let rows = response["tasks"] as? [[String: Any]] ?? []
        let titles = Dictionary(
            rows.compactMap { row -> (String, String)? in
                guard let task = row["task"] as? String else { return nil }
                return (task, title(task: task, label: row["label"] as? String))
            },
            uniquingKeysWith: { first, _ in first }
        )
        return rows.compactMap { row in
            guard let setting = VoiceReplyModelSetting(row: row), !setElsewhere.contains(setting.task) else { return nil }
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

    /// The model it runs on, or what it follows.
    var value: String {
        if setting.followsChats {
            return followsTitle.map { AppLocalization.string("Same as \($0)") } ?? AppLocalization.string("Same as chats")
        }
        return setting.model
    }

    /// "Same as chats" in the model picker, or the slot it follows.
    var followTitle: String {
        followsTitle.map { AppLocalization.string("Same as \($0)") } ?? AppLocalization.string("Same as chats")
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
        "vision": Words(title: { AppLocalization.string("Image reading") },
                        caption: { AppLocalization.string("Reads pictures and screenshots for a chat model that can't see them.") },
                        symbol: "eye"),
        "compression": Words(title: { AppLocalization.string("Compaction") },
                             caption: { AppLocalization.string("Summarizes a long chat so it still fits the model's context.") },
                             symbol: "arrow.down.right.and.arrow.up.left"),
        "skills_hub": Words(title: { AppLocalization.string("Skill search") },
                            caption: { AppLocalization.string("Finds skills in the Skills Hub.") },
                            symbol: "magnifyingglass"),
        "approval": Words(title: { AppLocalization.string("Smart approvals") },
                          caption: { AppLocalization.string("Decides which commands are safe to run without asking you, when smart approvals are on.") },
                          symbol: "checkmark.shield"),
        "mcp": Words(title: { AppLocalization.string("MCP tool routing") },
                     caption: { AppLocalization.string("Picks which MCP tools a turn needs.") },
                     symbol: "point.3.connected.trianglepath.dotted"),
        "title_generation": Words(title: { AppLocalization.string("Chat titles") },
                                  caption: { AppLocalization.string("Names new chats.") },
                                  symbol: "textformat"),
        "review": Words(title: { AppLocalization.string("Code review") },
                        caption: { AppLocalization.string("Runs the /review command's reviewer.") },
                        symbol: "doc.text.magnifyingglass"),
        VoiceReplyModelSetting.task: Words(
            title: { AppLocalization.string("Voice replies") },
            caption: { AppLocalization.string("The model Hermes answers you with in a voice conversation. Reasoning is off by default so replies start sooner; typed messages keep the chat's model. Hermes Desktop uses this setting too.") },
            symbol: "waveform.circle"
        ),
        "triage_specifier": Words(title: { AppLocalization.string("Kanban task details") },
                                  caption: { AppLocalization.string("Fills in a new Kanban task's details.") },
                                  symbol: "list.bullet.rectangle"),
        "kanban_decomposer": Words(title: { AppLocalization.string("Kanban task splitting") },
                                   caption: { AppLocalization.string("Splits a Kanban task into smaller ones.") },
                                   symbol: "square.split.2x2"),
        "profile_describer": Words(title: { AppLocalization.string("Profile descriptions") },
                                   caption: { AppLocalization.string("Writes a profile's description.") },
                                   symbol: "person.text.rectangle"),
        "curator": Words(title: { AppLocalization.string("Skill curator") },
                         caption: { AppLocalization.string("Reviews how skills are used and suggests improvements.") },
                         symbol: "sparkles"),
        "conduit_predict": Words(title: { AppLocalization.string("Conduit predictions") },
                                 caption: { AppLocalization.string("Suggested replies and draft guesses in Conduit, when Predictive uses the fast model.") },
                                 symbol: "wand.and.stars"),
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
}

/// The Helper models row on Models & providers.
struct HelperModelsSettingsSection: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let settings: HelperModelsSettingsModel
    @State private var slots: [HelperModelSlot]?
    /// Names the newest read: an older one that answers later is dropped.
    @State private var reads = 0

    var body: some View {
        ConduitSettingsSection(title: AppLocalization.string("Helper models"), symbol: "square.stack.3d.up", tint: .conduitAura) {
            Text(AppLocalization.string("Smaller jobs Hermes runs beside your chats, like titles, compaction and reading images. Each uses the chat model unless you pick one."))
                .scaledFont(.footnote).foregroundStyle(.secondary)
            NavigationLink {
                HelperModelsPage(settings: settings)
                    .v2TabBarClearance()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalization.string("Helper models"))
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

    private func read() async {
        reads += 1
        let read = reads
        guard let loaded = try? await settings.load(), read == reads else { return }
        slots = loaded
    }

    private var summary: String? {
        guard let slots else { return nil }
        let own = slots.filter { !$0.setting.followsChats }.count
        return own == 0
            ? AppLocalization.string("All use the chat model")
            : AppLocalization.string("\(String(own)) of \(String(slots.count)) have a model of their own")
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
            ConduitSettingsSection(title: AppLocalization.string("Helper models"), symbol: "square.stack.3d.up", tint: .conduitAura) {
                Text(AppLocalization.string("Hermes runs these jobs on the chat model unless you pick one. A small, fast model saves time and money on most of them."))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                if let slots {
                    if slots.isEmpty {
                        Text(AppLocalization.string("This Hermes has no helper models to set."))
                            .scaledFont(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(slots) { slot in
                        NavigationLink {
                            HelperModelPage(slot: slot, settings: settings.slot(slot))
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
        .navigationTitle(AppLocalization.string("Helper models"))
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
                    .foregroundStyle(slot.setting.followsChats ? Color.secondary : Color.conduitAccent)
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

/// One helper's model and reasoning.
struct HelperModelPage: View {
    let slot: HelperModelSlot
    let settings: VoiceReplyModelSettingsModel

    var body: some View {
        SettingsDetailContainer {
            VoiceReplyModelSettingsSection(settings: settings, helper: slot)
        }
        .navigationTitle(slot.title)
    }
}
