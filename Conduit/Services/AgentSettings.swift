//
//  AgentSettings.swift
//  Conduit
//
//  Hermes changes Conduit settings. Conduit shares a list of its settings
//  with the notifier plugin (key, meaning, choices, value and tier), and
//  the plugin's `conduit_settings` tool keeps Hermes' requested changes for
//  Conduit to pick up (PUT /api/plugins/conduit_push/conduit-settings, both
//  ways in one call). Conduit stays the owner: it checks every request
//  against its own list again, applies a small one with an Undo when the
//  user allows that, asks the user for the rest, and reports each outcome
//  on the next sync. Anything not in the list (credentials, wake phrase
//  setup, Calls from Hermes, Watch access, the mode itself) is out of
//  Hermes' reach. Design: designs/agent-configures-conduit.md.
//

import Foundation
import UIKit

/// The user's "Let Hermes change settings" choice, per device.
enum AgentSettingsMode: String, CaseIterable, Identifiable {
    case off
    case ask
    case small

    static let storageKey = "conduit.agentSettings.mode.v1"
    /// Eric's choice (2026-10-12): every change asks until the user says otherwise.
    static let defaultMode: AgentSettingsMode = .ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return AppLocalization.string("Off")
        case .ask: return AppLocalization.string("Ask me every time")
        case .small: return AppLocalization.string("Small changes without asking")
        }
    }

    var summary: String {
        switch self {
        case .off:
            return AppLocalization.string("Hermes can explain Conduit's settings but can't change them.")
        case .ask:
            return AppLocalization.string("When you ask Hermes to change a setting, Conduit shows the change and waits for you to approve it.")
        case .small:
            return AppLocalization.string("Changes to how voice sounds apply right away with an Undo. Anything that costs money, shares more with a voice model or keeps the microphone on still asks.")
        }
    }

    static func stored(in defaults: UserDefaults) -> AgentSettingsMode {
        defaults.string(forKey: storageKey).flatMap(AgentSettingsMode.init(rawValue:)) ?? defaultMode
    }
}

/// How much a setting matters: a small one may apply with an Undo; any
/// other asks the user every time.
enum AgentSettingTier: String {
    case small
    case ask
}

enum AgentSettingValue: Equatable {
    case bool(Bool)
    case string(String)

    init?(json: Any?) {
        // NSNumber bridges both; a JSON boolean arrives as a CFBoolean.
        if let number = json as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
        } else if let text = json as? String {
            self = .string(text)
        } else {
            return nil
        }
    }

    var json: Any {
        switch self {
        case .bool(let value): return value
        case .string(let value): return value
        }
    }
}

/// One setting Conduit lets Hermes see. `title` and `description` are
/// written for the model (English, like the live models' instructions);
/// `displayTitle` and `displayValue` are what the user reads.
struct AgentSettingDescriptor {
    enum Kind {
        case bool
        /// Each choice's stored value and its title for the model.
        case choice([(value: String, title: String)])
    }

    let key: String
    let section: String
    let title: String
    let description: String
    let kind: Kind
    let tier: AgentSettingTier
    let displayTitle: () -> String
    let displayValue: (AgentSettingValue) -> String
    let read: @MainActor () -> AgentSettingValue
    let write: @MainActor (AgentSettingValue) -> Void

    func accepts(_ value: AgentSettingValue) -> Bool {
        switch (kind, value) {
        case (.bool, .bool): return true
        case (.choice(let choices), .string(let text)): return choices.contains { $0.value == text }
        default: return false
        }
    }

    @MainActor
    func payload() -> [String: Any] {
        var entry: [String: Any] = [
            "key": key,
            "title": title,
            "section": section,
            "description": description,
            "tier": tier.rawValue,
            "value": read().json,
        ]
        switch kind {
        case .bool:
            entry["kind"] = "bool"
        case .choice(let choices):
            entry["kind"] = "choice"
            entry["choices"] = choices.map { ["value": $0.value, "title": $0.title] }
        }
        return entry
    }

    static func onOff(_ value: AgentSettingValue) -> String {
        if case .bool(let on) = value { return on ? AppLocalization.string("On") : AppLocalization.string("Off") }
        return ""
    }
}

/// A change Hermes asked for, as the plugin hands it back.
struct AgentSettingRequest: Equatable, Identifiable {
    let id: String
    let key: String
    let value: AgentSettingValue
    /// The value Hermes saw when it asked.
    let from: AgentSettingValue?
    let reason: String

    init?(json: Any) {
        guard let object = json as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.count <= 64,
              let key = object["key"] as? String, !key.isEmpty,
              let value = AgentSettingValue(json: object["value"]) else { return nil }
        self.id = id
        self.key = key
        self.value = value
        from = AgentSettingValue(json: object["from"])
        reason = (object["reason"] as? String).map { String($0.prefix(200)) } ?? ""
    }

    init(id: String, key: String, value: AgentSettingValue, from: AgentSettingValue?, reason: String) {
        self.id = id
        self.key = key
        self.value = value
        self.from = from
        self.reason = reason
    }
}

/// What becomes of a request, decided on the phone.
enum AgentSettingDecision: Equatable {
    /// Apply now, with an Undo.
    case apply
    /// Ask the user.
    case review
    /// Answer the plugin without changing anything.
    case answer(status: String, note: String)

    /// The phone's own check of a request: its list, its tier and the
    /// user's mode, never the tier the request claims.
    @MainActor
    static func decide(_ request: AgentSettingRequest, descriptor: AgentSettingDescriptor?, mode: AgentSettingsMode) -> AgentSettingDecision {
        guard let descriptor, descriptor.accepts(request.value) else {
            return .answer(status: "refused", note: "Conduit doesn't let Hermes change this setting to that value.")
        }
        guard mode != .off else {
            return .answer(status: "refused", note: "The user turned off Hermes changing Conduit settings.")
        }
        let current = descriptor.read()
        if current == request.value {
            return .answer(status: "applied", note: "It already had that value.")
        }
        if let from = request.from, from != current {
            return .answer(status: "conflict", note: "The user changed this setting after Hermes read it; the user's value was kept.")
        }
        return mode == .small && descriptor.tier == .small ? .apply : .review
    }
}

/// A change waiting for the user's tap.
struct AgentSettingsReviewItem: Identifiable, Equatable {
    let request: AgentSettingRequest
    let title: String
    let oldValue: String
    let newValue: String
    var id: String { request.id }
}

/// Changes Conduit just applied for Hermes, kept for their Undo.
struct AgentSettingsAppliedNotice: Equatable, Identifiable {
    struct Change: Equatable {
        let request: AgentSettingRequest
        let previous: AgentSettingValue
        let title: String
    }

    let id = UUID()
    let changes: [Change]

    var message: String {
        if changes.count == 1, let change = changes.first {
            return AppLocalization.string("Hermes changed \(change.title)")
        }
        return AppLocalization.string("Hermes changed \(changes.count) settings")
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// The sync with the plugin and the changes it brings, for the active
/// dashboard and profile.
@MainActor
final class AgentSettingsSync: ObservableObject {
    static let path = "/api/plugins/conduit_push/conduit-settings"
    static let capability = "conduit-settings"
    private static let installationKey = "conduit.agentSettings.installationID.v1"
    private static let resultsKey = "conduit.agentSettings.results.v1"
    /// Answers kept per host and profile until a sync delivers them.
    private static let maxResults = 40

    typealias Request = @MainActor (_ path: String, _ body: [String: Any]) async throws -> [String: Any]

    @Published private(set) var review: [AgentSettingsReviewItem] = []
    @Published var applied: AgentSettingsAppliedNotice?
    /// Bumped whenever Conduit applies a change for Hermes, so open
    /// settings pages reload their values.
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private var syncing = false
    private var syncAgain = false
    /// Where the review items came from; they're shown only there.
    private var reviewScope: String?

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var mode: AgentSettingsMode { AgentSettingsMode.stored(in: defaults) }

    var installationID: String {
        if let stored = defaults.string(forKey: Self.installationKey), !stored.isEmpty { return stored }
        let made = UUID().uuidString
        defaults.set(made, forKey: Self.installationKey)
        return made
    }

    /// One sync: upload the settings and the answers waiting, take what
    /// Hermes asked for. Overlapping calls run one more sync afterwards.
    func sync(
        scope: String, profile: String, catalog: [AgentSettingDescriptor],
        isCurrent: @MainActor () -> Bool = { true }, request: Request
    ) async {
        if syncing {
            syncAgain = true
            return
        }
        syncing = true
        defer { syncing = false }
        // A sync that answered requests runs once more so Hermes hears the
        // answers straight away; at most a few rounds.
        var rounds = 0
        repeat {
            syncAgain = false
            rounds += 1
            await syncOnce(scope: scope, profile: profile, catalog: catalog, isCurrent: isCurrent, request: request)
        } while syncAgain && rounds < 3
    }

    private func syncOnce(
        scope: String, profile: String, catalog: [AgentSettingDescriptor],
        isCurrent: @MainActor () -> Bool, request: Request
    ) async {
        let answers = results(for: scope)
        let body: [String: Any] = [
            "installation_id": installationID,
            "device": UIDevice.current.name,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "mode": mode.rawValue,
            "settings": catalog.map { $0.payload() },
            "results": answers,
        ]
        let response: [String: Any]
        do {
            response = try await request(DashboardPath.withProfile(Self.path, profile: profile), body)
        } catch {
            return
        }
        // The profile or host changed during the request: the catalog would
        // read one profile and write another. The requests wait on the host.
        guard response["ok"] as? Bool == true, isCurrent() else { return }
        // Delivered: only answers added during the request are kept.
        let sentIDs = Set(answers.compactMap { $0["id"] as? String })
        setResults(results(for: scope).filter { !sentIDs.contains($0["id"] as? String ?? "") }, for: scope)
        // Requests just answered are never decided twice, even if the host
        // lists them again.
        let pending = (response["pending"] as? [Any] ?? []).compactMap(AgentSettingRequest.init(json:))
            .filter { !sentIDs.contains($0.id) }
        // The mode now, not when the request left: the user may have
        // switched it to Off meanwhile.
        if take(pending, scope: scope, catalog: catalog, mode: mode) { syncAgain = true }
    }

    /// Decides each waiting request; the ones for the user replace the
    /// review list. True when some got an answer for the plugin.
    @discardableResult
    func take(_ pending: [AgentSettingRequest], scope: String, catalog: [AgentSettingDescriptor], mode: AgentSettingsMode) -> Bool {
        let byKey = Dictionary(catalog.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let alreadyAnswered = answeredIDs(for: scope)
        var forReview: [AgentSettingsReviewItem] = []
        var appliedNow: [AgentSettingsAppliedNotice.Change] = []
        var answered = false
        var seen = Set<String>()
        // One decision per id, even if the host lists a request twice.
        for request in pending where !alreadyAnswered.contains(request.id) && seen.insert(request.id).inserted {
            let descriptor = byKey[request.key]
            switch AgentSettingDecision.decide(request, descriptor: descriptor, mode: mode) {
            case .answer(let status, let note):
                record(request.id, status: status, note: note, scope: scope)
                answered = true
            case .apply:
                guard let descriptor else { continue }
                let previous = descriptor.read()
                descriptor.write(request.value)
                record(request.id, status: "applied", note: "", scope: scope)
                answered = true
                appliedNow.append(.init(request: request, previous: previous, title: descriptor.displayTitle()))
            case .review:
                guard let descriptor else { continue }
                forReview.append(AgentSettingsReviewItem(
                    request: request,
                    title: descriptor.displayTitle(),
                    oldValue: descriptor.displayValue(descriptor.read()),
                    newValue: descriptor.displayValue(request.value)
                ))
            }
        }
        reviewScope = scope
        if forReview != review { review = forReview }
        if !appliedNow.isEmpty {
            revision += 1
            applied = AgentSettingsAppliedNotice(changes: appliedNow)
        }
        return answered
    }

    /// The review items for `scope`; none from another dashboard or profile.
    func reviewItems(for scope: String?) -> [AgentSettingsReviewItem] {
        scope != nil && scope == reviewScope ? review : []
    }

    /// The user's answer to items in the review list.
    func resolve(_ items: [AgentSettingsReviewItem], apply: Bool, scope: String, catalog: [AgentSettingDescriptor]) {
        guard scope == reviewScope else { return }
        let byKey = Dictionary(catalog.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for item in items {
            guard apply else {
                record(item.id, status: "dismissed", note: "", scope: scope)
                continue
            }
            guard let descriptor = byKey[item.request.key], descriptor.accepts(item.request.value) else {
                record(item.id, status: "refused", note: "Conduit no longer lets Hermes change this setting to that value.",
                       scope: scope)
                continue
            }
            // The user changed it while the request waited: their value stays.
            if let from = item.request.from, descriptor.read() != from {
                record(item.id, status: "conflict",
                       note: "The user changed this setting after Hermes read it; the user's value was kept.", scope: scope)
                continue
            }
            descriptor.write(item.request.value)
            changed = true
            record(item.id, status: "applied", note: "The user approved it.", scope: scope)
        }
        let resolved = Set(items.map(\.id))
        review.removeAll { resolved.contains($0.id) }
        if changed { revision += 1 }
    }

    /// Puts back the values a notice's changes replaced, unless the user
    /// changed the setting again since.
    func undo(_ notice: AgentSettingsAppliedNotice, scope: String, catalog: [AgentSettingDescriptor]) {
        // A notice from another dashboard or profile never writes here.
        guard scope == reviewScope, applied == notice else { return }
        applied = nil
        let byKey = Dictionary(catalog.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for change in notice.changes {
            guard let descriptor = byKey[change.request.key], descriptor.read() == change.request.value else { continue }
            descriptor.write(change.previous)
            record(change.request.id, status: "undone", note: "The user tapped Undo.", scope: scope)
        }
        revision += 1
    }

    /// Forgets review items when the dashboard or profile changes; their
    /// requests stay on the host for the next visit.
    func leave(scope: String?) {
        guard scope != reviewScope else { return }
        review = []
        applied = nil
        reviewScope = scope
    }

    // MARK: Answers waiting for the next sync

    private func record(_ id: String, status: String, note: String, scope: String) {
        var list = results(for: scope).filter { ($0["id"] as? String) != id || status == "undone" }
        var entry: [String: Any] = ["id": id, "status": status]
        if !note.isEmpty { entry["note"] = note }
        list.append(entry)
        setResults(Array(list.suffix(Self.maxResults)), for: scope)
    }

    private func answeredIDs(for scope: String) -> Set<String> {
        Set(results(for: scope).compactMap { $0["id"] as? String })
    }

    private func results(for scope: String) -> [[String: Any]] {
        let all = defaults.dictionary(forKey: Self.resultsKey) as? [String: [[String: Any]]] ?? [:]
        return all[scope] ?? []
    }

    private func setResults(_ list: [[String: Any]], for scope: String) {
        var all = defaults.dictionary(forKey: Self.resultsKey) as? [String: [[String: Any]]] ?? [:]
        all[scope] = list.isEmpty ? nil : list
        defaults.set(all, forKey: Self.resultsKey)
    }
}
