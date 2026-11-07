//
//  DelegationRouting.swift
//  Conduit
//
//  Settings > Memory & delegation > Subagent routing: how each subagent
//  gets its model (`delegation.backend`), and the routes of the chosen
//  mode (`delegation.backends.model_map` and `.profile_routes`, which the
//  Advanced Delegation plugin runs). Hermes Desktop's Model > Subagents >
//  Routing is the reference. A route's `api_key` comes back only as a
//  preview; sending the preview back keeps the stored key.
//

import Foundation

/// `GET /api/delegation/routing`.
struct DelegationRouting: Equatable {
    static let defaultMode = "default"
    static let modelMapMode = "model_map"
    static let profileRoutesMode = "profile_routes"
    /// The modes this page edits: Default, then the plugin's two.
    static let pluginModes = [modelMapMode, profileRoutesMode]
    static let modes = [defaultMode] + pluginModes

    /// One way of running subagents: `default` or a plugin's backend.
    struct Backend: Equatable, Identifiable {
        let name: String
        let label: String
        /// The backend's own one line, for a third party's.
        let summary: String
        /// It can run for this profile now.
        let available: Bool
        /// Why it can't, in Hermes' words.
        let reason: String
        let builtin: Bool
        var id: String { name }
    }

    /// One named model route (`model_map.options[]`). Every key Hermes sent
    /// stays in `fields`, so a save never drops one this page doesn't edit
    /// (fallbacks, an endpoint, a key's preview).
    struct ModelRoute: Equatable, Identifiable {
        var fields: [String: AnyCodable]
        var id: String { name }
        var name: String { text("name") }
        var description: String { text("description") }
        var provider: String { text("provider") }
        var model: String { text("model") }
        var baseURL: String { text("base_url") }
        var reasoningEffort: String { text("reasoning_effort") }
        var serviceTier: String { text("service_tier") }

        init(fields: [String: AnyCodable]) { self.fields = fields }

        private func text(_ key: String) -> String {
            fields[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        /// What the row says under the description: where it runs and how.
        var facts: [String] {
            [
                provider.isEmpty ? baseURL : provider,
                model,
                reasoningEffort.isEmpty ? "" : AppLocalization.string("effort \(reasoningEffort)"),
                serviceTier,
            ].filter { !$0.isEmpty }
        }
    }

    /// One profile subagents may run as (`profile_routes.profiles[]`).
    struct ProfileRoute: Equatable, Identifiable {
        var name: String
        var description: String = ""
        var id: String { name }

        var jsonObject: [String: Any] {
            description.isEmpty ? ["name": name] : ["name": name, "description": description]
        }
    }

    /// The saved `delegation.backend`; `default` when unset.
    var configured: String
    /// Why the saved mode can't run here; nil when it runs. Hermes refuses
    /// every subagent meanwhile, it never quietly runs Default.
    var blockedReason: String?
    var backends: [Backend]
    var modelRoutes: [ModelRoute]
    var defaultModelRoute: String?
    var profileRoutes: [ProfileRoute]
    var defaultProfileRoute: String?
    /// The profiles on this Hermes a profile route may name.
    var profiles: [String]

    init(configured: String = defaultMode, blockedReason: String? = nil, backends: [Backend] = [], modelRoutes: [ModelRoute] = [], defaultModelRoute: String? = nil, profileRoutes: [ProfileRoute] = [], defaultProfileRoute: String? = nil, profiles: [String] = []) {
        self.configured = configured
        self.blockedReason = blockedReason
        self.backends = backends
        self.modelRoutes = modelRoutes
        self.defaultModelRoute = defaultModelRoute
        self.profileRoutes = profileRoutes
        self.defaultProfileRoute = defaultProfileRoute
        self.profiles = profiles
    }

    /// Nil when the answer isn't the routing (no `configured`).
    init?(json: [String: Any]) {
        guard let configured = json["configured"] as? String else { return nil }
        let blocked = (json["blocked_reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelMap = json["model_map"] as? [String: Any] ?? [:]
        let profileRoutes = json["profile_routes"] as? [String: Any] ?? [:]
        self.init(
            configured: configured.isEmpty ? Self.defaultMode : configured,
            blockedReason: blocked?.isEmpty == false ? blocked : nil,
            backends: (json["backends"] as? [Any] ?? []).compactMap { item in
                guard let row = item as? [String: Any], let name = row["name"] as? String, !name.isEmpty else { return nil }
                return Backend(
                    name: name,
                    label: row["label"] as? String ?? "",
                    summary: row["description"] as? String ?? "",
                    available: row["available"] as? Bool ?? false,
                    reason: row["reason"] as? String ?? "",
                    builtin: row["builtin"] as? Bool ?? false
                )
            },
            modelRoutes: Self.modelRoutes(from: modelMap),
            defaultModelRoute: Self.nonEmpty(modelMap["default"]),
            profileRoutes: Self.profileRoutes(from: profileRoutes),
            defaultProfileRoute: Self.nonEmpty(profileRoutes["default"]),
            profiles: (json["profiles"] as? [Any] ?? []).compactMap { $0 as? String }
        )
    }

    static func modelRoutes(from block: [String: Any]) -> [ModelRoute] {
        (block["options"] as? [Any] ?? []).compactMap { item in
            guard let row = item as? [String: Any], let name = row["name"] as? String, !name.isEmpty else { return nil }
            return ModelRoute(fields: row.mapValues(AnyCodable.init(jsonObject:)))
        }
    }

    static func profileRoutes(from block: [String: Any]) -> [ProfileRoute] {
        (block["profiles"] as? [Any] ?? []).compactMap { item in
            guard let row = item as? [String: Any], let name = row["name"] as? String, !name.isEmpty else { return nil }
            return ProfileRoute(name: name, description: (row["description"] as? String) ?? "")
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    // MARK: Modes

    /// Every mode the picker lists: the three this page edits, each other
    /// backend a plugin registers, then a saved one nothing registers, so
    /// the saved choice is always on screen even when it can't run.
    var modeChoices: [String] {
        let others = backends.filter { !$0.builtin && !Self.modes.contains($0.name) }.map(\.name)
        let names = Self.modes + others
        return names.contains(configured) ? names : names + [configured]
    }

    /// Default always runs; a plugin's mode once its backend can.
    func isAvailable(_ mode: String) -> Bool {
        mode == Self.defaultMode || backends.contains { $0.name == mode && $0.available }
    }

    func backend(_ mode: String) -> Backend? { backends.first { $0.name == mode } }

    /// Any mode but Default picks each subagent's model itself, so the
    /// Delegate model card doesn't apply then.
    var routesOwnSubagentModel: Bool { configured != Self.defaultMode }

    // MARK: Model routes

    /// A default route always exists while routes do.
    private static func withDefault(_ names: [String], preferred: String?) -> String? {
        if let preferred, names.contains(preferred) { return preferred }
        return names.first
    }

    /// Adds `route` (`original` nil) or replaces the route named `original`;
    /// a rename carries the default along.
    func upsertingModelRoute(_ route: ModelRoute, replacing original: String?) -> DelegationRouting {
        var next = self
        if let original, let index = modelRoutes.firstIndex(where: { $0.name == original }) {
            next.modelRoutes[index] = route
        } else {
            next.modelRoutes.append(route)
        }
        let preferred = original != nil && defaultModelRoute == original ? route.name : defaultModelRoute
        next.defaultModelRoute = Self.withDefault(next.modelRoutes.map(\.name), preferred: preferred)
        return next
    }

    func removingModelRoute(_ name: String) -> DelegationRouting {
        var next = self
        next.modelRoutes.removeAll { $0.name == name }
        next.defaultModelRoute = Self.withDefault(next.modelRoutes.map(\.name), preferred: defaultModelRoute == name ? nil : defaultModelRoute)
        return next
    }

    func defaultingModelRoute(_ name: String) -> DelegationRouting {
        var next = self
        next.defaultModelRoute = Self.withDefault(modelRoutes.map(\.name), preferred: name)
        return next
    }

    /// `PUT /api/delegation/backends/model_map`'s body: each route as Hermes
    /// sent it, edits included, a key's preview with it so Hermes keeps the
    /// stored key.
    var modelMapBody: [String: Any] {
        ["options": modelRoutes.map { $0.fields.mapValues(\.anyValue) }, "default": defaultModelRoute.map { $0 as Any } ?? NSNull()]
    }

    // MARK: Profile routes

    /// Checks or unchecks a profile; the first checked one becomes the
    /// default when none is.
    func togglingProfileRoute(_ name: String, on: Bool) -> DelegationRouting {
        var next = self
        if on {
            if !profileRoutes.contains(where: { $0.name == name }) { next.profileRoutes.append(ProfileRoute(name: name)) }
        } else {
            next.profileRoutes.removeAll { $0.name == name }
        }
        next.defaultProfileRoute = Self.withDefault(next.profileRoutes.map(\.name), preferred: defaultProfileRoute)
        return next
    }

    func describingProfileRoute(_ name: String, _ description: String) -> DelegationRouting {
        var next = self
        if let index = profileRoutes.firstIndex(where: { $0.name == name }) {
            next.profileRoutes[index].description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return next
    }

    func defaultingProfileRoute(_ name: String) -> DelegationRouting {
        var next = self
        next.defaultProfileRoute = Self.withDefault(profileRoutes.map(\.name), preferred: name)
        return next
    }

    var profileRoutesBody: [String: Any] {
        ["profiles": profileRoutes.map(\.jsonObject), "default": defaultProfileRoute.map { $0 as Any } ?? NSNull()]
    }
}

/// The Add route / Edit route sheet's fields. Every other key of the route
/// it edits goes back as Hermes sent it.
struct DelegationModelRouteDraft: Equatable {
    /// Saved as written: `normal` turns a provider's own Fast setting off,
    /// none leaves it alone.
    static let serviceTiers = ["normal", "fast", "ultrafast"]
    static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    var name = ""
    var description = ""
    var provider = ""
    var model = ""
    var reasoningEffort = ""
    var serviceTier = ""

    init() {}

    init(route: DelegationRouting.ModelRoute) {
        name = route.name
        description = route.description
        provider = route.provider
        model = route.model
        reasoningEffort = route.reasoningEffort
        serviceTier = route.serviceTier
    }

    enum Problem: Error, Equatable {
        case name, nameSpaces, nameTaken, description, provider, model

        var message: String {
            switch self {
            case .name: AppLocalization.string("Give the route a name.")
            case .nameSpaces: AppLocalization.string("A route's name can't have spaces.")
            case .nameTaken: AppLocalization.string("Another route has that name.")
            case .description: AppLocalization.string("Say what the route is for: the agent reads it to choose one.")
            case .provider: AppLocalization.string("Pick a provider.")
            case .model: AppLocalization.string("Pick a model.")
            }
        }
    }

    /// The route this draft saves as, or the first thing to fix. `taken`
    /// names the other routes. A route Hermes keeps with only an endpoint
    /// (written by hand) keeps it and needs no provider.
    func route(taken: [String], editing previous: DelegationRouting.ModelRoute?) -> Result<DelegationRouting.ModelRoute, Problem> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.name) }
        guard !name.contains(where: \.isWhitespace) else { return .failure(.nameSpaces) }
        guard !taken.contains(name) else { return .failure(.nameTaken) }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return .failure(.description) }
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty || !(previous?.baseURL.isEmpty ?? true) else { return .failure(.provider) }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return .failure(.model) }

        var fields = previous?.fields ?? [:]
        // An edited route names the one it came from, so Hermes keeps its
        // stored key through a rename.
        if let previous { fields["original_name"] = .string(previous.name) }
        for (key, value) in [("name", name), ("description", description), ("provider", provider), ("model", model),
                             ("reasoning_effort", reasoningEffort), ("service_tier", serviceTier)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = trimmed.isEmpty ? nil : .string(trimmed)
        }
        return .success(DelegationRouting.ModelRoute(fields: fields))
    }
}
