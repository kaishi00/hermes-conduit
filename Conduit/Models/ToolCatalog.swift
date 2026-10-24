import Foundation

/// What Hermes' tools catalog (the dashboard's `/api/tools/toolsets`) says
/// each tool belongs to: the toolset's name ("Spotify", "Searxng") and its
/// one-line description. A step row Conduit has no words of its own for
/// reads "Used Spotify" instead of "Used a tool". Hermes isn't translated,
/// so a name is shown as Hermes writes it.
struct ToolCatalog: Equatable {
    struct Entry: Equatable, Codable {
        let label: String
        let description: String?
    }

    private(set) var entries: [String: Entry] = [:]

    init() {}

    init(entries: [String: Entry]) {
        self.entries = entries
    }

    /// A tool listed by several toolsets takes the smallest one's name: a
    /// toolset of one tool says more about it than one of twenty.
    init(toolsets: [CapabilityToolset]) {
        var sizes: [String: Int] = [:]
        for toolset in toolsets {
            let tools = toolset.tools ?? []
            guard !tools.isEmpty else { continue }
            // The name Settings > Capabilities shows for the toolset.
            let label = CapabilityToolsetOrdering.label(toolset)
            guard !label.isEmpty else { continue }
            let description = toolset.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = Entry(label: label, description: description?.isEmpty == false ? description : nil)
            for tool in tools {
                let key = Self.key(tool)
                guard !key.isEmpty, tools.count < sizes[key] ?? .max else { continue }
                sizes[key] = tools.count
                entries[key] = entry
            }
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    func entry(for toolName: String) -> Entry? {
        entries[Self.key(toolName)]
    }

    private static func key(_ toolName: String) -> String {
        toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Saved copy

    /// The last catalog each profile's Hermes sent, so a chat opened before
    /// the dashboard answers (or offline) still names its tools.
    static func saved(key: String, defaults: UserDefaults = .standard) -> ToolCatalog {
        guard let data = defaults.data(forKey: defaultsKey(key)),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return ToolCatalog() }
        return ToolCatalog(entries: entries)
    }

    func save(key: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey(key))
    }

    private static func defaultsKey(_ key: String) -> String { "toolCatalog.\(key)" }
}
