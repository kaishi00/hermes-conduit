import Foundation

/// What each Conduit plugin version brings, from CHANGELOG.md on the
/// plugin's main branch (read with the latest version,
/// NotifierPluginLatestVersion.swift). The update notice and Settings >
/// Conduit plugin show the entries between the host's version and the one
/// an update installs, security fixes first, and when it was released.
///
/// The file's format is fixed and checked by the plugin's
/// tests/test_changelog.py: `## X.Y.Z (YYYY-MM-DD)`, then `### Security`,
/// `### Fixes` and `### New and improved`, one `- ` line per change
/// (wrapped lines indented).
struct NotifierPluginChangelog: Equatable {
    enum Kind: String, CaseIterable {
        case security = "Security"
        case fixes = "Fixes"
        case new = "New and improved"
    }

    struct Change: Equatable, Identifiable {
        var version: String
        var kind: Kind
        var text: String
        /// Its place in the version's entry, so repeated lines stay apart.
        var position = 0
        var id: String { "\(version)|\(position)" }
    }

    struct Entry: Equatable {
        var version: String
        /// Midnight UTC of the day the version reached main.
        var released: Date?
        var changes: [Change]
    }

    /// Newest first, as the file lists them.
    var entries: [Entry]

    static let cacheKey = "conduit.notifierPlugin.changelog"

    init(entries: [Entry]) {
        self.entries = entries
    }

    /// Nil when the text has no entry this parser reads.
    init?(markdown: String) {
        var entries: [Entry] = []
        var kind: Kind?
        for rawLine in markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("## ") {
                kind = nil
                guard let entry = Self.entry(fromHeading: line) else { continue }
                entries.append(entry)
            } else if line.hasPrefix("### ") {
                kind = Kind(rawValue: line.dropFirst(4).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("- "), let kind, !entries.isEmpty {
                let index = entries.count - 1
                let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                entries[index].changes.append(Change(version: entries[index].version, kind: kind, text: text,
                                                     position: entries[index].changes.count))
            } else if line.hasPrefix("  "), kind != nil, let index = entries.indices.last,
                      var last = entries[index].changes.popLast() {
                // A wrapped change.
                last.text += " " + line.trimmingCharacters(in: .whitespaces)
                entries[index].changes.append(last)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                kind = nil
            }
        }
        guard !entries.isEmpty else { return nil }
        self.entries = entries
    }

    private static func entry(fromHeading line: String) -> Entry? {
        // "## 0.63.0 (2026-10-23)"
        let parts = line.dropFirst(3).split(separator: " ", maxSplits: 1)
        // A heading that isn't a dotted number (isOlder counts an unreadable
        // version older than anything, "0" included) isn't a version.
        guard let version = parts.first.map(String.init),
              !NotifierPluginStatus.isOlder(version, than: "0") else { return nil }
        var released: Date?
        if parts.count == 2 {
            let date = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            released = releaseDateFormatter.date(from: date)
        }
        return Entry(version: version, released: released, changes: [])
    }

    private static let releaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The entries an update from `installed` to `target` brings: newer than
    /// the installed version, up to the target. Every entry up to the target
    /// when the installed version isn't known.
    func updateEntries(after installed: String?, through target: String) -> [Entry] {
        entries.filter { entry in
            !NotifierPluginStatus.isOlder(target, than: entry.version)
                && (installed.map { NotifierPluginStatus.isOlder($0, than: entry.version) } ?? true)
        }
    }

    /// What an update brings, security fixes first, then fixes, then new
    /// things, each newest first.
    func updateChanges(after installed: String?, through target: String) -> [Change] {
        let all = updateEntries(after: installed, through: target).flatMap(\.changes)
        return Kind.allCases.flatMap { kind in all.filter { $0.kind == kind } }
    }

    /// When `version` reached main, when the file says.
    func released(_ version: String) -> Date? {
        entries.first { $0.version == version }?.released
    }

    static func cached(in defaults: UserDefaults) -> NotifierPluginChangelog? {
        defaults.string(forKey: cacheKey).flatMap(NotifierPluginChangelog.init(markdown:))
    }
}
