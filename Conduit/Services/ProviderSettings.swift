//
//  ProviderSettings.swift
//  Conduit
//
//  The model providers a profile can use, and adding, changing and removing
//  them: an account Hermes signs in to, an API key in the profile's .env,
//  or a custom OpenAI-compatible endpoint in its config. Settings > Model's
//  Providers section, the Add a provider sheet and a provider's page read
//  and write through here.
//
//  Keys only ever go up. Conduit never asks Hermes for a saved key
//  (`/api/env/reveal`), never shows the masked preview Hermes sends, and
//  never keeps a key on the phone: what's kept for the page to open on is a
//  summary of which providers are connected, with no key or preview in it.
//

import Foundation

/// One provider Hermes can route models through, with each way this
/// profile can reach it.
struct ProviderEntry: Identifiable, Equatable {
    /// An API key. A shared key is a row in the main profile's credential
    /// pool, which Hermes uses for every profile with no pool rows of its
    /// own for the provider. A profile's own key is a row in its own pool.
    /// A key in a profile's `.env` doesn't override a shared one: Hermes
    /// copies the shared row into that profile's pool first and the copy
    /// comes first (tested on Hermes 0.22.2).
    struct KeyAccess: Equatable {
        /// Variables Hermes reads the key from, the provider's own first.
        var vars: [String]
        /// The variables Hermes reports set in this profile's `.env`.
        var savedVars: [String]
        /// The shared keys: the main profile's pool rows for the provider
        /// that a key was pasted into (not ones read from its `.env`, which
        /// another profile has no variable to read them from).
        var sharedRows: [PoolRow] = []
        /// The rows this profile's pool lists for the provider, in Hermes'
        /// order, first used first: its own, or the shared ones it falls
        /// back to. Empty on the main profile, whose pool is the shared one.
        var profileRows: [PoolRow] = []
        /// The variable that overrides the provider's base URL, if it has one.
        var baseURLVar: String?
        var baseURLSaved = false
        /// Where to get a key.
        var signupURL: String?

        enum State: Equatable {
            case none
            /// The profile uses the shared key.
            case shared
            /// The profile uses a key of its own.
            case own
            /// The profile uses a copy of a shared key since replaced.
            case oldCopy
            /// The main profile has a key in its `.env`, which no other
            /// profile can use.
            case mainProfileOnly
        }

        var saved: Bool { !savedVars.isEmpty }
        var shared: Bool { !sharedRows.isEmpty }
        var sharedIDs: Set<String> { Set(sharedRows.map(\.id)) }

        /// Which key the profile uses. `onMainProfile`: the profile is the
        /// one whose pool holds the shared keys.
        func state(onMainProfile: Bool) -> State {
            if onMainProfile {
                if shared { return .shared }
                return saved ? .mainProfileOnly : .none
            }
            // No rows listed: Hermes falls back to the shared ones, which
            // come ahead of a `.env` key once it reads it.
            guard let first = profileRows.first else { return shared ? .shared : (saved ? .own : .none) }
            if sharedIDs.contains(first.id) { return .shared }
            return first.label == PoolRow.sharedLabel ? .oldCopy : .own
        }

        /// Rows this profile holds that aren't the shared key: its own keys,
        /// its `.env` rows and old copies. Removing them puts it back on
        /// the shared key.
        var ownRows: [PoolRow] { profileRows.filter { !sharedIDs.contains($0.id) } }
        /// A new or replacement key goes under the provider's own variable,
        /// so a shared fallback another provider reads is never overwritten.
        var writeVar: String { vars.first ?? "" }
    }

    /// One row of a credential pool.
    struct PoolRow: Equatable {
        /// Rows Conduit adds for all profiles, and for one, are labelled so
        /// a copy of a replaced shared key can be told from a profile's own.
        static let sharedLabel = "Conduit (all profiles)"
        static let profileLabel = "Conduit (this profile)"

        let id: String
        /// Its 1-based place in the pool, which removal names.
        let index: Int
        var label = ""
        var source = ""
    }

    /// An account Hermes signs in to, on the main profile: every profile
    /// without a sign-in of its own uses it.
    struct AccountAccess: Equatable {
        enum Flow: String, Equatable {
            /// Hermes shows a code to enter on the provider's page.
            case deviceCode = "device_code"
            /// Signing in runs on the host's own command line.
            case external
        }
        var flow: Flow
        var signedIn: Bool
        /// The host command that signs in, for an external account.
        var command: String?
        var docsURL: String?
        /// Hermes can sign it out here; some only sign out where they signed in.
        var signsOutHere: Bool
    }

    /// A custom OpenAI-compatible endpoint in the profile's config.
    struct EndpointAccess: Equatable {
        /// The config's `providers` key.
        var endpointID: String
        var baseURL: String
        var model: String
        var models: [String]
        /// "" lets Hermes work it out.
        var apiMode: String
        var keySaved: Bool
        /// The default model runs on it.
        var isCurrent: Bool
    }

    enum Status: Equatable {
        case customEndpoint, signedIn, sharedKey, ownKey, oldCopy, mainProfileOnly, notConnected
    }

    /// The provider's slug, or `endpoint:<key>` for a custom endpoint, so an
    /// endpoint named like a built-in provider stays its own row.
    let id: String
    var name: String
    var key: KeyAccess?
    var account: AccountAccess?
    var endpoint: EndpointAccess?

    /// Whether the profile is the main one, whose pool holds the shared keys.
    var onMainProfile = true

    var isConnected: Bool { status != .notConnected }

    var keyState: KeyAccess.State { key?.state(onMainProfile: onMainProfile) ?? .none }

    var status: Status {
        if endpoint != nil { return .customEndpoint }
        if account?.signedIn == true { return .signedIn }
        switch keyState {
        case .shared: return .sharedKey
        case .own: return .ownKey
        case .oldCopy: return .oldCopy
        case .mainProfileOnly: return .mainProfileOnly
        case .none: return .notConnected
        }
    }

    /// The names Hermes' model catalog may list this provider under.
    var catalogNames: [String] {
        guard let endpoint else { return [id] }
        // Not its display name: one named like a built-in provider would
        // take that provider's catalog row.
        return [endpoint.endpointID, "custom:\(endpoint.endpointID)"]
    }

    /// The catalog row serving this provider's models, if Hermes lists one.
    func catalogRow(in providers: [ProviderInfo]) -> ProviderInfo? {
        providers.first { row in catalogNames.contains(where: row.matches) }
    }

    static func endpointEntryID(_ endpointID: String) -> String { "endpoint:\(endpointID)" }
}

/// Builds the provider list from Hermes' three answers, and the summary of
/// it kept on the phone.
enum ProviderCatalog {
    /// `env` is the profile's `GET /api/env`, `accounts` the main profile's
    /// `GET /api/providers/oauth`, `endpoints` the profile's
    /// `GET /api/providers/custom-endpoints` and `sharedPool` the main
    /// profile's `GET /api/credentials/pool`; `profilePool` is the profile's
    /// own, nil on the main profile. A nil answer adds nothing.
    static func entries(
        env: [String: Any]?, accounts: [String: Any]?, endpoints: [String: Any]?,
        sharedPool: [String: Any]? = nil, profilePool: [String: Any]? = nil, onMainProfile: Bool = true
    ) -> [ProviderEntry] {
        var byID: [String: ProviderEntry] = [:]
        var order: [String] = []
        func update(_ id: String, name: String, _ change: (inout ProviderEntry) -> Void) {
            if byID[id] == nil {
                byID[id] = ProviderEntry(id: id, name: name)
                order.append(id)
            }
            change(&byID[id]!)
        }

        for (variable, value) in env ?? [:] {
            guard let row = value as? [String: Any], row["category"] as? String == "provider" else { continue }
            let isSet = row["is_set"] as? Bool ?? false
            let isPassword = row["is_password"] as? Bool ?? false
            let advanced = row["advanced"] as? Bool ?? false
            for profile in providerProfiles(of: row) {
                if isPassword {
                    update(profile.slug, name: profile.label) { entry in
                        var key = entry.key ?? ProviderEntry.KeyAccess(vars: [], savedVars: [])
                        if profile.primary { key.vars.insert(variable, at: 0) } else { key.vars.append(variable) }
                        if isSet { key.savedVars.append(variable) }
                        if key.signupURL == nil { key.signupURL = profile.url }
                        entry.key = key
                    }
                } else if advanced, variable.hasSuffix("_BASE_URL") {
                    update(profile.slug, name: profile.label) { entry in
                        var key = entry.key ?? ProviderEntry.KeyAccess(vars: [], savedVars: [])
                        key.baseURLVar = variable
                        key.baseURLSaved = isSet
                        entry.key = key
                    }
                }
            }
        }
        // A provider whose only variable is a base URL has no key to add.
        for id in order where byID[id]?.key?.vars.isEmpty == true {
            byID[id]?.key = nil
        }
        // Several primaries can't happen, but keep the order stable when the
        // dictionary's order changes: the provider's own variable, then the rest.
        for id in order {
            guard var key = byID[id]?.key else { continue }
            if key.vars.count > 1 {
                let first = key.vars[0]
                key.vars = [first] + key.vars.dropFirst().sorted()
            }
            key.savedVars.sort()
            byID[id]?.key = key
        }

        // A key pasted into the main profile's pool is shared. Rows the pool
        // read from that profile's own `.env` (`env:` sources) are not:
        // another profile has no such variable to read them from.
        for (id, rows) in poolRows(sharedPool) where byID[id]?.key != nil {
            byID[id]?.key?.sharedRows = rows.filter { !$0.source.hasPrefix("env:") }
        }
        if !onMainProfile {
            for (id, rows) in poolRows(profilePool) where byID[id]?.key != nil {
                byID[id]?.key?.profileRows = rows
            }
        }
        for id in order { byID[id]?.onMainProfile = onMainProfile }

        for row in accounts?["providers"] as? [[String: Any]] ?? [] {
            guard let id = nonEmpty(row["id"]), let flow = ProviderEntry.AccountAccess.Flow(rawValue: row["flow"] as? String ?? "") else { continue }
            let status = row["status"] as? [String: Any] ?? [:]
            let name = nonEmpty(row["name"]) ?? id
            update(id, name: name) { entry in
                entry.name = name
                entry.account = ProviderEntry.AccountAccess(
                    flow: flow,
                    signedIn: status["logged_in"] as? Bool ?? false,
                    command: nonEmpty(row["cli_command"]),
                    docsURL: nonEmpty(row["docs_url"]),
                    signsOutHere: row["disconnectable"] as? Bool ?? false
                )
            }
        }

        for row in endpoints?["endpoints"] as? [[String: Any]] ?? [] {
            guard let endpointID = nonEmpty(row["id"]), let baseURL = nonEmpty(row["base_url"]) else { continue }
            let name = nonEmpty(row["name"]) ?? endpointID
            update(ProviderEntry.endpointEntryID(endpointID), name: name) { entry in
                entry.endpoint = ProviderEntry.EndpointAccess(
                    endpointID: endpointID,
                    baseURL: baseURL,
                    model: row["model"] as? String ?? "",
                    models: (row["models"] as? [Any] ?? []).compactMap { $0 as? String },
                    apiMode: row["api_mode"] as? String ?? "",
                    keySaved: row["has_api_key"] as? Bool ?? false,
                    isCurrent: row["is_current"] as? Bool ?? false
                )
            }
        }

        return order.compactMap { byID[$0] }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// A pool answer's API-key rows by provider, in Hermes' order.
    static func poolRows(_ answer: [String: Any]?) -> [String: [ProviderEntry.PoolRow]] {
        var rows: [String: [ProviderEntry.PoolRow]] = [:]
        for provider in answer?["providers"] as? [[String: Any]] ?? [] {
            guard let id = nonEmpty(provider["provider"]) else { continue }
            rows[id] = (provider["entries"] as? [[String: Any]] ?? []).compactMap(poolRow)
        }
        return rows
    }

    private static func poolRow(_ row: [String: Any]) -> ProviderEntry.PoolRow? {
        guard row["auth_type"] as? String ?? "api_key" == "api_key",
              let rowID = nonEmpty(row["id"]), let index = row["index"] as? Int else { return nil }
        return ProviderEntry.PoolRow(id: rowID, index: index, label: row["label"] as? String ?? "",
                                     source: row["source"] as? String ?? "")
    }

    private struct ProviderProfile {
        let slug: String
        let label: String
        let url: String?
        let primary: Bool
    }

    /// One credential can serve several providers (`provider_profiles`);
    /// each gets it on its own card.
    private static func providerProfiles(of row: [String: Any]) -> [ProviderProfile] {
        let shared = (row["provider_profiles"] as? [[String: Any]] ?? []).compactMap { profile -> ProviderProfile? in
            guard let slug = nonEmpty(profile["provider"]) else { return nil }
            return ProviderProfile(slug: slug, label: nonEmpty(profile["provider_label"]) ?? slug,
                                   url: nonEmpty(profile["url"]), primary: profile["primary"] as? Bool ?? false)
        }
        if !shared.isEmpty { return shared }
        guard let slug = nonEmpty(row["provider"]) else { return [] }
        return [ProviderProfile(slug: slug, label: nonEmpty(row["provider_label"]) ?? slug,
                                url: nonEmpty(row["url"]), primary: row["provider_primary"] as? Bool ?? false)]
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    // MARK: The summary kept on the phone

    /// Which providers are connected and how, for the page to open on. It
    /// names the variables a key goes under and the pool rows, never a key
    /// or Hermes' preview of one, and an endpoint's host but not its path.
    static func summary(_ entries: [ProviderEntry]) -> [String: Any] {
        ["providers": entries.map { entry -> [String: Any] in
            var row: [String: Any] = ["id": entry.id, "name": entry.name, "on_main_profile": entry.onMainProfile]
            if let key = entry.key {
                var access: [String: Any] = [
                    "vars": key.vars, "vars_saved": key.savedVars, "base_url_saved": key.baseURLSaved,
                    "shared_rows": key.sharedRows.map(encode), "profile_rows": key.profileRows.map(encode),
                ]
                if let baseURLVar = key.baseURLVar { access["base_url_var"] = baseURLVar }
                if let signupURL = key.signupURL { access["signup_url"] = signupURL }
                row["env"] = access
            }
            if let account = entry.account {
                var access: [String: Any] = ["flow": account.flow.rawValue, "signed_in": account.signedIn, "signs_out_here": account.signsOutHere]
                if let command = account.command { access["command"] = command }
                if let docsURL = account.docsURL { access["docs_url"] = docsURL }
                row["account"] = access
            }
            if let endpoint = entry.endpoint {
                row["endpoint"] = [
                    "endpoint_id": endpoint.endpointID, "base_url": keptAddress(endpoint.baseURL), "model": endpoint.model,
                    "models": endpoint.models, "api_mode": endpoint.apiMode,
                    "secret_saved": endpoint.keySaved, "is_current": endpoint.isCurrent,
                ] as [String: Any]
            }
            return row
        }]
    }

    /// An endpoint's address as kept: its scheme, host and port only, since
    /// a path can carry a token. The page edits the full one, from Hermes.
    static func keptAddress(_ address: String) -> String {
        guard var parts = URLComponents(string: address), parts.host != nil else { return "" }
        parts.user = nil
        parts.password = nil
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? ""
    }

    /// A pool row as kept: no key or preview, only which row it is.
    private static func encode(_ row: ProviderEntry.PoolRow) -> [String: Any] {
        ["id": row.id, "index": row.index, "label": row.label, "source": row.source]
    }

    static func entries(summary: [String: Any]?) -> [ProviderEntry]? {
        guard let rows = summary?["providers"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let id = nonEmpty(row["id"]) else { return nil }
            var entry = ProviderEntry(id: id, name: nonEmpty(row["name"]) ?? id)
            entry.onMainProfile = row["on_main_profile"] as? Bool ?? true
            if let access = row["env"] as? [String: Any] {
                entry.key = ProviderEntry.KeyAccess(
                    vars: access["vars"] as? [String] ?? [],
                    savedVars: access["vars_saved"] as? [String] ?? [],
                    baseURLVar: nonEmpty(access["base_url_var"]),
                    baseURLSaved: access["base_url_saved"] as? Bool ?? false,
                    signupURL: nonEmpty(access["signup_url"])
                )
                entry.key?.sharedRows = (access["shared_rows"] as? [[String: Any]] ?? []).compactMap(poolRow)
                entry.key?.profileRows = (access["profile_rows"] as? [[String: Any]] ?? []).compactMap(poolRow)
            }
            if let access = row["account"] as? [String: Any],
               let flow = ProviderEntry.AccountAccess.Flow(rawValue: access["flow"] as? String ?? "") {
                entry.account = ProviderEntry.AccountAccess(
                    flow: flow,
                    signedIn: access["signed_in"] as? Bool ?? false,
                    command: nonEmpty(access["command"]),
                    docsURL: nonEmpty(access["docs_url"]),
                    signsOutHere: access["signs_out_here"] as? Bool ?? false
                )
            }
            if let access = row["endpoint"] as? [String: Any], let endpointID = nonEmpty(access["endpoint_id"]) {
                entry.endpoint = ProviderEntry.EndpointAccess(
                    endpointID: endpointID,
                    baseURL: access["base_url"] as? String ?? "",
                    model: access["model"] as? String ?? "",
                    models: access["models"] as? [String] ?? [],
                    apiMode: access["api_mode"] as? String ?? "",
                    keySaved: access["secret_saved"] as? Bool ?? false,
                    isCurrent: access["is_current"] as? Bool ?? false
                )
            }
            return entry
        }
    }
}

/// A key or endpoint check: Hermes tried it without saving it.
struct ProviderCheck: Equatable {
    /// The provider took it.
    var ok: Bool
    /// Hermes could reach the provider. When it couldn't, the key may still
    /// be fine, so a save goes ahead with a note.
    var reachable: Bool
    var message: String
    /// The models an endpoint check found.
    var models: [String] = []

    init(ok: Bool, reachable: Bool, message: String, models: [String] = []) {
        self.ok = ok; self.reachable = reachable; self.message = message; self.models = models
    }

    init(answer: [String: Any]) {
        ok = answer["ok"] as? Bool ?? false
        reachable = answer["reachable"] as? Bool ?? true
        message = (answer["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        models = (answer["models"] as? [Any] ?? []).compactMap { $0 as? String }
    }

    /// A save waits only for a check that says the key is wrong.
    var blocksSave: Bool { !ok && reachable }
}

/// A sign-in Hermes started: the code to enter and where.
struct ProviderSignIn: Equatable {
    let sessionID: String
    let userCode: String
    let verificationURL: URL?
    let pollInterval: Int

    init?(answer: [String: Any]) {
        guard let sessionID = answer["session_id"] as? String, !sessionID.isEmpty else { return nil }
        self.sessionID = sessionID
        userCode = answer["user_code"] as? String ?? ""
        verificationURL = (answer["verification_url"] as? String).flatMap(URL.init(string:))
        pollInterval = max(1, (answer["poll_interval"] as? Int) ?? 5)
    }

    enum Outcome: Equatable {
        case pending
        case approved
        case failed(String)

        init(answer: [String: Any]) {
            switch answer["status"] as? String ?? "pending" {
            case "pending": self = .pending
            case "approved": self = .approved
            case "denied": self = .failed(AppLocalization.string("The sign-in was declined."))
            case "expired": self = .failed(AppLocalization.string("The code expired. Start again."))
            case "cancelled": self = .failed(AppLocalization.string("The sign-in was cancelled."))
            default:
                let message = (answer["error_message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                self = .failed(message.isEmpty ? AppLocalization.string("The sign-in didn’t finish.") : message)
            }
        }
    }
}

/// What a custom endpoint is saved with. `key` nil leaves a saved key as
/// it is: Hermes would read an empty one as "remove the key", which
/// Conduit doesn't offer.
struct CustomEndpointDraft: Equatable {
    var endpointID = ""
    var name = ""
    var baseURL = ""
    var key: String?
    var apiMode = ""
    var model = ""
    var models: [String] = []
    var makeDefault = false

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The config key for a new endpoint, made from its name and kept clear
    /// of the ones the profile has: "Lab vLLM" is `lab-vllm`, then `lab-vllm-2`.
    static func endpointID(forName name: String, taken: Set<String>) -> String {
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let base = words.isEmpty ? "endpoint" : words.joined(separator: "-")
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }
    var trimmedBaseURL: String { baseURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSave: Bool { !trimmedName.isEmpty && !trimmedBaseURL.isEmpty && !model.isEmpty }

    /// The body Hermes' endpoint routes take.
    func body(forCheck: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "id": endpointID, "name": trimmedName, "base_url": trimmedBaseURL,
            "model": model, "api_mode": apiMode, "discover_models": true,
        ]
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            body["api_key"] = key
        }
        if !forCheck {
            body["make_default"] = makeDefault
            if !models.isEmpty { body["models"] = models }
        }
        return body
    }
}

@MainActor
final class ProviderSettingsService: ObservableObject {
    /// The kept summary's route. It is Conduit's own, not a read's answer.
    static let keptRoute = "conduit:providers"

    @Published private(set) var entries: [ProviderEntry] = []
    /// Hermes answered the last read. Until then the list is the kept one.
    @Published private(set) var answered = false
    @Published private(set) var loadFailed = false
    @Published private(set) var isLoading = false

    let profile: String
    /// The profile's name as Conduit shows it (see Profile names).
    let profileName: String
    /// Where shared keys and sign-ins live: the main profile, whose
    /// credential pool every other profile falls back to per provider.
    static let sharedProfile = "default"
    var isSharedProfile: Bool { profile == Self.sharedProfile }
    private let requester: DashboardJSONRequester
    private let answers: KeptAnswers?
    /// Raised after every change, so the model lists around the page read
    /// Hermes' catalog again.
    @Published private(set) var changes = 0

    /// The profiles on this Hermes, for clearing copies of a replaced
    /// shared key out of each one's pool.
    private let profiles: () -> [String]

    init(requester: DashboardJSONRequester, profile: String, profileName: String? = nil, answers: KeptAnswers? = nil,
         profiles: @escaping () -> [String] = { [] }) {
        self.requester = requester
        self.profile = profile
        self.profileName = profileName ?? profile
        self.answers = answers
        self.profiles = profiles
        entries = ProviderCatalog.entries(summary: answers?.kept(Self.keptRoute)) ?? []
    }

    var connected: [ProviderEntry] { entries.filter(\.isConnected) }
    var hasList: Bool { answered || !entries.isEmpty }

    func entry(_ id: String) -> ProviderEntry? { entries.first { $0.id == id } }

    // MARK: Reads

    /// Counts reloads, so one that started before a later one can't put
    /// back what was there before a write.
    private var reloadGeneration = 0

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        loadFailed = false
        defer { if generation == reloadGeneration { isLoading = false } }
        let onMain = isSharedProfile
        var fresh: [ProviderEntry]?
        let read = { [self] () async throws -> [String: Any] in
            // A route an older Hermes lacks adds nothing; any other failure
            // fails the read, so a dropped pool read never shows a shared
            // key as missing.
            let envPath = scoped("/api/env")
            let accountsPath = shared("/api/providers/oauth")
            let endpointsPath = scoped("/api/providers/custom-endpoints")
            let sharedPoolPath = shared("/api/credentials/pool")
            let profilePoolPath = onMain ? nil : named("/api/credentials/pool", profile: profile)
            async let env = request(envPath)
            async let accounts = optionalRoute(accountsPath)
            async let endpoints = optionalRoute(endpointsPath)
            async let sharedPool = optionalRoute(sharedPoolPath)
            async let profilePool = optionalRoute(profilePoolPath)
            let built = ProviderCatalog.entries(
                env: try await env, accounts: try await accounts, endpoints: try await endpoints,
                sharedPool: try await sharedPool, profilePool: try await profilePool, onMainProfile: onMain
            )
            fresh = built
            return ProviderCatalog.summary(built)
        }
        do {
            let summary: [String: Any]
            if let answers {
                summary = try await answers.keep(Self.keptRoute, false, read)
            } else {
                summary = try await read()
            }
            guard generation == reloadGeneration else { return }
            // What Hermes just said, in full; the kept summary is what the
            // page opens on next time.
            entries = fresh ?? ProviderCatalog.entries(summary: summary) ?? []
            answered = true
        } catch {
            guard generation == reloadGeneration else { return }
            loadFailed = true
        }
    }

    // MARK: Keys

    /// Hermes tries the key without saving it.
    func check(key value: String, for variable: String) async -> ProviderCheck {
        do {
            let answer = try await request("/api/providers/validate", method: "POST", body: ["key": variable, "value": value])
            return ProviderCheck(answer: answer)
        } catch {
            return ProviderCheck(ok: false, reachable: false, message: UserFacingError.message(for: error))
        }
    }

    /// Shares a key with every profile: a row in the main profile's pool,
    /// which every profile without a key of its own uses. The shared key it
    /// replaces goes, and so do the copies of it Hermes made in other
    /// profiles' pools, which would otherwise keep the old key in use.
    /// Nothing on the phone keeps the key.
    /// On the main profile a key in its own `.env`, which Hermes reads into
    /// the pool ahead of the new row, goes too: the pasted key replaces it.
    /// Returns false when the key was saved but something it replaces
    /// couldn't be removed.
    @discardableResult
    func share(key value: String, for entry: ProviderEntry) async throws -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        let replaced = entry.key?.sharedIDs ?? []
        let mainVars = isSharedProfile ? entry.key?.savedVars ?? [] : []
        _ = try await request(shared("/api/credentials/pool"), method: "POST",
                              body: ["provider": entry.id, "api_key": value, "label": ProviderEntry.PoolRow.sharedLabel])
        return await cleanUp {
            if !replaced.isEmpty {
                try await removeRows(provider: entry.id, ids: replaced, profile: Self.sharedProfile)
                await removeCopies(provider: entry.id, ids: replaced)
            }
            try await removeVariables(mainVars)
        }
    }

    /// Removes the provider's shared key, and Hermes' copies of it: every
    /// profile without a key of its own loses it.
    func unshare(_ entry: ProviderEntry) async throws {
        let ids = entry.key?.sharedIDs ?? []
        guard !ids.isEmpty else { return }
        try await afterWrite {
            try await removeRows(provider: entry.id, ids: ids, profile: Self.sharedProfile)
            await removeCopies(provider: entry.id, ids: ids)
        }
    }

    /// Gives this profile a key of its own, which it uses instead of the
    /// shared one. Adding it copies the shared rows into this profile's
    /// pool, ahead of it; those copies go, and so does every other row it
    /// held (an earlier key of its own, an old copy of a replaced shared
    /// key), so its new key is the one it uses.
    @discardableResult
    func override(key value: String, for entry: ProviderEntry) async throws -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSharedProfile else { return true }
        let stale = (entry.key?.sharedIDs ?? []).union((entry.key?.ownRows ?? []).map(\.id))
        _ = try await request(named("/api/credentials/pool", profile: profile), method: "POST",
                              body: ["provider": entry.id, "api_key": value, "label": ProviderEntry.PoolRow.profileLabel])
        return await cleanUp {
            try await removeRows(provider: entry.id, ids: stale, profile: profile)
        }
    }

    /// Puts this profile back on the shared key: its own rows go (a `.env`
    /// row's removal takes the variable out of its `.env` too), and so do
    /// the `.env` variables left over. One already gone is fine.
    func useShared(_ entry: ProviderEntry) async throws {
        guard !isSharedProfile, let key = entry.key else { return }
        try await afterWrite {
            try await removeRows(provider: entry.id, ids: Set(key.ownRows.map(\.id)), profile: profile)
            try await removeVariables(key.savedVars)
        }
    }

    /// Runs the rest of a write that has already changed something on the
    /// host, then reads the page again whether or not the rest worked.
    /// Takes variables out of this profile's `.env`; one already gone is fine.
    private func removeVariables(_ variables: [String]) async throws {
        for variable in variables {
            do {
                _ = try await request(scoped("/api/env"), method: "DELETE", body: ["key": variable, "profile": profile])
            } catch where Self.isNotFound(error) {
                continue
            }
        }
    }

    /// The cleanup after a key was added: the key is saved whatever
    /// happens, so a failure here is reported as false, not thrown.
    private func cleanUp(_ rest: () async throws -> Void) async -> Bool {
        do {
            try await rest()
            await changed()
            return true
        } catch {
            await changed()
            return false
        }
    }

    private func afterWrite(_ rest: () async throws -> Void) async throws {
        do {
            try await rest()
        } catch {
            await changed()
            throw error
        }
        await changed()
    }

    /// Saves a value to this profile's `.env`: a base URL override, or the
    /// main profile's own key. Nothing on the phone keeps it.
    func save(key value: String, for variable: String) async throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !variable.isEmpty else { return }
        _ = try await request(scoped("/api/env"), method: "PUT",
                              body: ["key": variable, "value": value, "profile": profile, "provider_setup": true])
        await changed()
    }

    func remove(variable: String) async throws {
        _ = try await request(scoped("/api/env"), method: "DELETE", body: ["key": variable, "profile": profile])
        await changed()
    }

    /// Removal names a row by its place, which shifts as rows go, so the
    /// places are read again and the rows removed from the last one up.
    private func removeRows(provider: String, ids: Set<String>, profile: String) async throws {
        guard !ids.isEmpty else { return }
        let pool = try await request(named("/api/credentials/pool", profile: profile))
        let indices = (ProviderCatalog.poolRows(pool)[provider] ?? []).filter { ids.contains($0.id) }.map(\.index)
        for index in indices.sorted(by: >) {
            _ = try await request(named("/api/credentials/pool/\(component(provider))/\(index)", profile: profile), method: "DELETE")
        }
    }

    /// Clears copies of shared rows, gone from the main profile now, out of
    /// every other profile's pool. A profile that only falls back to the
    /// main pool lists none of them any more, so only real copies go. A
    /// profile that can't be read keeps its copy; its page says so.
    private func removeCopies(provider: String, ids: Set<String>) async {
        for name in profiles() where name != Self.sharedProfile {
            try? await removeRows(provider: provider, ids: ids, profile: name)
        }
    }

    // MARK: Accounts

    func startSignIn(_ providerID: String) async throws -> ProviderSignIn {
        let answer = try await request(shared("/api/providers/oauth/\(component(providerID))/start"), method: "POST", body: [:])
        guard let signIn = ProviderSignIn(answer: answer) else {
            throw ProviderSettingsError.unexpectedAnswer
        }
        return signIn
    }

    /// Waits up to about 20 seconds for the sign-in to end.
    func poll(_ providerID: String, signIn: ProviderSignIn) async throws -> ProviderSignIn.Outcome {
        let path = shared("/api/providers/oauth/\(component(providerID))/poll/\(component(signIn.sessionID))?wait=20")
        let answer = try await request(path, timeout: 30_000)
        let outcome = ProviderSignIn.Outcome(answer: answer)
        if outcome == .approved { await changed() }
        return outcome
    }

    func cancel(_ signIn: ProviderSignIn) async {
        _ = try? await request(shared("/api/providers/oauth/sessions/\(component(signIn.sessionID))"), method: "DELETE")
    }

    func signOut(_ providerID: String) async throws {
        _ = try await request(shared("/api/providers/oauth/\(component(providerID))"), method: "DELETE")
        await changed()
    }

    // MARK: Custom endpoints

    /// Hermes asks the endpoint for its models without saving anything.
    func check(endpoint draft: CustomEndpointDraft) async -> ProviderCheck {
        do {
            let answer = try await request("/api/providers/custom-endpoints/validate", method: "POST",
                                           body: draft.body(forCheck: true), timeout: 30_000)
            return ProviderCheck(answer: answer)
        } catch {
            return ProviderCheck(ok: false, reachable: false, message: UserFacingError.message(for: error))
        }
    }

    /// Saves the endpoint to the profile's config, in turn with every other
    /// config write.
    func save(endpoint draft: CustomEndpointDraft) async throws {
        let path = scoped("/api/providers/custom-endpoints")
        let body = draft.body(forCheck: false)
        _ = try await ProfileConfigWriteQueue.runThrowing { [self] in
            try await request(path, method: "POST", body: body, timeout: 30_000)
        }
        await changed()
    }

    func remove(endpoint endpointID: String) async throws {
        let path = scoped("/api/providers/custom-endpoints/\(component(endpointID))")
        _ = try await ProfileConfigWriteQueue.runThrowing { [self] in
            try await request(path, method: "DELETE")
        }
        await changed()
    }

    // MARK: Plumbing

    private func changed() async {
        answers?.noteWrite(Self.keptRoute)
        changes += 1
        await reload()
    }

    private func scoped(_ path: String) -> String {
        DashboardPath.withProfile(path, profile: profile)
    }

    /// Named even though it's the default: an unnamed profile means the one
    /// the dashboard was started with, and Hermes refuses an unnamed removal
    /// when it serves several.
    private func shared(_ path: String) -> String {
        named(path, profile: Self.sharedProfile)
    }

    private func named(_ path: String, profile: String) -> String {
        DashboardPath.withExplicitProfile(path, profile: profile)
    }

    /// A route an older Hermes may not have: nil when it says so, or when
    /// there's no path to read.
    private func optionalRoute(_ path: String?) async throws -> [String: Any]? {
        guard let path else { return nil }
        do {
            return try await request(path)
        } catch where Self.isNotFound(error) {
            return nil
        }
    }

    static func isNotFound(_ error: Error) -> Bool {
        guard case DashboardTicketBridgeError.http(let status, _) = error else { return false }
        return status == 404 || status == 405 || status == 410
    }

    private func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? value
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: Int = 15_000) async throws -> [String: Any] {
        try await requester.requestJSON(
            path: path, method: method, body: body,
            timeoutMilliseconds: timeout, maxResponseBytes: DataURLLimits.maxJSONResponseBytes
        )
    }
}

enum ProviderSettingsError: LocalizedError {
    case unexpectedAnswer

    var errorDescription: String? {
        AppLocalization.string("Hermes gave an answer Conduit didn’t expect. Update Hermes and try again.")
    }
}
