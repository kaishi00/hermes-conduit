import Foundation

/// The newest Conduit plugin: the version on its repository's main branch,
/// which is what a one-tap update installs. Conduit offers the update
/// whenever the host is below it, so a plugin release reaches users without
/// waiting for a Conduit build. `NotifierPluginStatus.recommendedVersion`
/// stays the floor this build needs when GitHub can't be reached.
enum NotifierPluginLatestVersion {
    static let url: URL = {
        guard let url = URL(string: "https://raw.githubusercontent.com/\(NotifierPluginStatus.repository)/main/plugin.yaml") else {
            preconditionFailure("The plugin.yaml address is a fixed literal")
        }
        return url
    }()
    static let versionKey = "conduit.notifierPlugin.latestVersion"
    static let checkedKey = "conduit.notifierPlugin.latestVersionCheckedAt"
    /// GitHub is asked at most this often; connects in between use the
    /// saved answer.
    static let interval: TimeInterval = 60 * 60

    static func cached(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: versionKey)
    }

    /// The `version:` line of a plugin.yaml, when it's a dotted number.
    static func version(fromPluginYAML yaml: String) -> String? {
        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let line = rawLine.drop(while: \.isWhitespace)
            guard line.hasPrefix("version:") else { continue }
            let value = line.dropFirst("version:".count)
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else {
                return nil
            }
            return trimmed
        }
        return nil
    }

    /// Asks GitHub when it was last asked over `interval` ago, answered or
    /// not, and saves what it says. Nil when it wasn't asked or didn't answer.
    static func refresh(
        defaults: UserDefaults,
        now: Date = Date(),
        fetch: (URL) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(from: $0) }
    ) async -> String? {
        if let checked = defaults.object(forKey: checkedKey) as? Date, now.timeIntervalSince(checked) < interval {
            return nil
        }
        // An offline phone waits the interval too.
        defaults.set(now, forKey: checkedKey)
        guard let answer = try? await fetch(url),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200,
              let text = String(bytes: answer.0, encoding: .utf8),
              let version = version(fromPluginYAML: text) else { return nil }
        defaults.set(version, forKey: versionKey)
        return version
    }
}
