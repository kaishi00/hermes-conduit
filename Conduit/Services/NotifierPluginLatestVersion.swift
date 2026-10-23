import Foundation

/// The newest Conduit plugin: the version on its repository's main branch,
/// which is what a one-tap update installs. TestFlight builds offer the
/// update whenever the host is below it, so a plugin release reaches testers
/// without waiting for a Conduit build. App Store builds only nag up to the
/// stable version (`channels.yaml` on main), which the plugin's maintainer
/// raises when App Store users should update; see NotifierPluginNoticeChannel.
/// `NotifierPluginStatus.recommendedVersion` stays the floor this build needs
/// when GitHub can't be reached.
enum NotifierPluginLatestVersion {
    static let url = mainFile("plugin.yaml")
    static let channelsURL = mainFile("channels.yaml")
    /// What each version brings (NotifierPluginChangelog).
    static let changelogURL = mainFile("CHANGELOG.md")

    private static func mainFile(_ name: String) -> URL {
        guard let url = URL(string: "https://raw.githubusercontent.com/\(NotifierPluginStatus.repository)/main/\(name)") else {
            preconditionFailure("The plugin file address is a fixed literal")
        }
        return url
    }

    /// What one ask of GitHub learned.
    struct Answer: Equatable {
        /// The plugin version on main.
        var latest: String?
        /// The version App Store builds offer.
        var stable: String?
        /// CHANGELOG.md, when it answered and reads.
        var changelog: NotifierPluginChangelog?
    }

    static let versionKey = "conduit.notifierPlugin.latestVersion"
    static let stableKey = "conduit.notifierPlugin.stableVersion"
    static let checkedKey = "conduit.notifierPlugin.latestVersionCheckedAt"
    /// GitHub is asked at most this often; connects in between use the
    /// saved answer.
    static let interval: TimeInterval = 60 * 60

    static func cached(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: versionKey)
    }

    static func cachedStable(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: stableKey)
    }

    /// The `version:` line of a plugin.yaml, when it's a dotted number.
    static func version(fromPluginYAML yaml: String) -> String? {
        version(forKey: "version", in: yaml)
    }

    /// The `stable:` line of channels.yaml, when it's a dotted number.
    static func stableVersion(fromChannelsYAML yaml: String) -> String? {
        version(forKey: "stable", in: yaml)
    }

    private static func version(forKey key: String, in yaml: String) -> String? {
        let prefix = key + ":"
        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let line = rawLine.drop(while: \.isWhitespace)
            guard line.hasPrefix(prefix) else { continue }
            let value = line.dropFirst(prefix.count)
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
    /// not, and saves what it says. Nil when it wasn't asked; an answer's
    /// version is nil when its file didn't answer.
    static func refresh(
        defaults: UserDefaults,
        now: Date = Date(),
        fetch: (URL) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(from: $0) }
    ) async -> Answer? {
        if let checked = defaults.object(forKey: checkedKey) as? Date, now.timeIntervalSince(checked) < interval {
            return nil
        }
        // An offline phone waits the interval too.
        defaults.set(now, forKey: checkedKey)
        let latest = await text(at: url, fetch: fetch).flatMap(version(fromPluginYAML:))
        let stable = await text(at: channelsURL, fetch: fetch).flatMap(stableVersion(fromChannelsYAML:))
        let changelogText = await text(at: changelogURL, fetch: fetch)
        let changelog = changelogText.flatMap(NotifierPluginChangelog.init(markdown:))
        if let latest { defaults.set(latest, forKey: versionKey) }
        if let stable { defaults.set(stable, forKey: stableKey) }
        if changelog != nil { defaults.set(changelogText, forKey: NotifierPluginChangelog.cacheKey) }
        return Answer(latest: latest, stable: stable, changelog: changelog)
    }

    private static func text(at url: URL, fetch: (URL) async throws -> (Data, URLResponse)) async -> String? {
        guard let answer = try? await fetch(url),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(bytes: answer.0, encoding: .utf8)
    }
}
