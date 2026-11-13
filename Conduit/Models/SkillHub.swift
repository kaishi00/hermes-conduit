//
//  SkillHub.swift
//  Conduit
//
//  Hermes' skill hub, as Settings > Capabilities > Skills > Browse Skill
//  Hub reads it: the sources Hermes searches (official, the Hermes Index,
//  skills.sh, GitHub, ClawHub...), the index's featured skills, a search
//  across them, and a skill's security scan before it installs. Shapes
//  follow Hermes' `/api/skills/hub/sources`, `/search` and `/scan` routes,
//  the ones Hermes Desktop's skill catalog reads.
//

import Foundation

/// A skill a hub source offers (`_skill_meta_to_payload`).
struct HubSkill: Identifiable, Equatable, Codable {
    var id: String { identifier }
    let name: String
    let identifier: String
    let description: String
    let source: String
    /// builtin, trusted or community.
    let trustLevel: String
    let repo: String?
    let tags: [String]

    init?(_ value: Any) {
        guard let dict = value as? [String: Any],
              let identifier = SkillHub.text(dict["identifier"]) ?? SkillHub.text(dict["name"]) else { return nil }
        // A registry row's name can be a stray front-matter delimiter: the
        // identifier's last part reads instead, as on Desktop.
        let name = SkillHub.text(dict["name"]).flatMap { name in
            name.contains { $0.isLetter || $0.isNumber } ? name : nil
        }
        self.name = name ?? identifier.split(separator: "/").last.map(String.init) ?? identifier
        self.identifier = identifier
        description = SkillHub.text(dict["description"]) ?? ""
        source = SkillHub.text(dict["source"]) ?? ""
        trustLevel = SkillHub.text(dict["trust_level"]) ?? "community"
        repo = SkillHub.text(dict["repo"])
        tags = (dict["tags"] as? [Any])?.compactMap { SkillHub.text($0) } ?? []
    }

    init(name: String, identifier: String, description: String = "", source: String = "", trustLevel: String = "community", repo: String? = nil, tags: [String] = []) {
        self.name = name
        self.identifier = identifier
        self.description = description
        self.source = source
        self.trustLevel = trustLevel
        self.repo = repo
        self.tags = tags
    }

    /// The repository page, a web address only.
    var repoURL: URL? {
        guard let repo else { return nil }
        if let url = URL(string: repo), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil {
            return url
        }
        // `owner/name` is a GitHub repository.
        let parts = repo.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } }) else { return nil }
        return URL(string: "https://github.com/\(repo)")
    }
}

/// A source Hermes searches for skills.
struct SkillHubSource: Identifiable, Equatable, Codable {
    let id: String
    let label: String
    /// Searched on its own: false when the Hermes Index already covers it.
    let searchable: Bool
    let rateLimited: Bool
}

/// What `/api/skills/hub/sources` says: the sources, the index's featured
/// skills, and which hub skills the profile has installed.
struct SkillHubSnapshot: Equatable, Codable {
    var sources: [SkillHubSource]
    var indexAvailable: Bool
    var featured: [HubSkill]
    /// Identifier -> installed skill's name.
    var installed: [String: String]

    init(sources: [SkillHubSource] = [], indexAvailable: Bool = false, featured: [HubSkill] = [], installed: [String: String] = [:]) {
        self.sources = sources
        self.indexAvailable = indexAvailable
        self.featured = featured
        self.installed = installed
    }

    init(_ response: [String: Any]) {
        sources = (response["sources"] as? [Any] ?? []).compactMap { value in
            guard let dict = value as? [String: Any], let id = SkillHub.text(dict["id"]) else { return nil }
            return SkillHubSource(
                id: id,
                label: SkillHub.text(dict["label"]) ?? id,
                searchable: dict["searchable"] as? Bool ?? true,
                rateLimited: dict["rate_limited"] as? Bool ?? false
            )
        }
        indexAvailable = response["index_available"] as? Bool ?? false
        featured = SkillHub.unique((response["featured"] as? [Any] ?? []).compactMap { HubSkill($0) })
        installed = SkillHub.installed(response["installed"])
    }

    /// The sources a search can be narrowed to, in Hermes' order.
    var searchableSources: [SkillHubSource] { sources.filter(\.searchable) }
}

/// One search's answer.
struct SkillHubResults: Equatable {
    var results: [HubSkill]
    /// Sources that didn't answer in time.
    var timedOut: [String]
    var installed: [String: String]

    init(results: [HubSkill] = [], timedOut: [String] = [], installed: [String: String] = [:]) {
        self.results = results
        self.timedOut = timedOut
        self.installed = installed
    }

    init(_ response: [String: Any]) {
        results = SkillHub.unique((response["results"] as? [Any] ?? []).compactMap { HubSkill($0) })
        timedOut = (response["timed_out"] as? [Any] ?? []).compactMap { SkillHub.text($0) }
        installed = SkillHub.installed(response["installed"])
    }
}

/// Hermes' install-time scan of a hub skill, without installing it.
struct SkillHubScan: Equatable {
    enum Policy: String {
        /// Installs as it is.
        case allow
        /// Hermes would ask first.
        case ask
        /// Hermes refuses it.
        case block
    }

    struct Finding: Equatable, Identifiable {
        let id: Int
        let severity: String
        let category: String
        let file: String?
        let line: Int?
        let description: String

        /// Where it was found, `file:line`.
        var location: String? {
            guard let file else { return nil }
            return line.map { "\(file):\($0)" } ?? file
        }
    }

    let verdict: String
    let summary: String?
    let policy: Policy
    let policyReason: String?
    let findings: [Finding]

    init(_ response: [String: Any]) {
        verdict = SkillHub.text(response["verdict"]) ?? ""
        summary = SkillHub.text(response["summary"])
        policy = SkillHub.text(response["policy"]).flatMap(Policy.init(rawValue:)) ?? .ask
        policyReason = SkillHub.text(response["policy_reason"])
        let rows = (response["findings"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        findings = rows.enumerated().map { index, row in
            Finding(
                id: index,
                severity: SkillHub.text(row["severity"])?.lowercased() ?? "low",
                category: SkillHub.text(row["category"]) ?? "",
                file: SkillHub.text(row["file"]),
                line: (row["line"] as? NSNumber)?.intValue,
                description: SkillHub.text(row["description"]) ?? ""
            )
        }
        .sorted { lhs, rhs in
            let left = SkillHub.severityRank(lhs.severity)
            let right = SkillHub.severityRank(rhs.severity)
            return left != right ? left < right : lhs.id < rhs.id
        }
    }
}

enum SkillHub {
    /// The longest search Hermes takes, and what a page asks for.
    static let searchLimit = 50

    static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// First of each identifier, in Hermes' order.
    static func unique(_ skills: [HubSkill]) -> [HubSkill] {
        var seen = Set<String>()
        return skills.filter { seen.insert($0.identifier).inserted }
    }

    static func installed(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (identifier, entry) in dict {
            let name = (entry as? [String: Any]).flatMap { text($0["name"]) }
            out[identifier] = name ?? identifier
        }
        return out
    }

    static func severityRank(_ severity: String) -> Int {
        switch severity {
        case "critical": return 0
        case "high": return 1
        case "medium": return 2
        case "low": return 3
        default: return 4
        }
    }

}

/// A hub skill with a newer version at its source: one row of
/// `GET /api/skills/hub/updates` (`hermes skills check`).
struct HubSkillUpdate: Identifiable, Equatable {
    let name: String
    let identifier: String
    let source: String

    var id: String { identifier.isEmpty ? name : identifier }

    init?(_ row: Any) {
        guard let row = row as? [String: Any] else { return nil }
        let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let identifier = (row["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty || !identifier.isEmpty else { return nil }
        self.name = name.isEmpty ? identifier : name
        self.identifier = identifier
        source = (row["source"] as? String) ?? ""
    }
}

/// The Skills tab's Check for Updates.
enum HubSkillUpdatesState: Equatable {
    case checking
    /// Hermes' answer: the hub skills that have updates, none when every
    /// one is current.
    case found([HubSkillUpdate])
    case failed(String)
}
