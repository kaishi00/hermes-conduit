//
//  AppState+HelperModels.swift
//  Conduit
//
//  The model routes a profile keeps: model providers, helper models, the
//  voice reply and voice job models, and the live voice status. Moved out
//  of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Model providers, helper models and the voice reply model

    /// Switches write through the dashboard: offline, with only the kept
    /// lists to show, they wait for it instead of flipping back unsaid.
    var canChangeCapabilities: Bool { dashboardTicketBridge != nil }

    /// Gemini wins when a merged blob has both on, as configuredLiveVoiceEngine reads it.
    var isQwenLiveEnabled: Bool {
        let preferences = loadVoiceProfilePreferences(profile: activeProfile)
        return preferences.qwenLiveEnabled && !preferences.geminiLiveEnabled
    }

    /// Gemini Live is an opt-in, per-profile Voice mode (off by default).
    var isGeminiLiveEnabled: Bool {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLiveEnabled
    }

    /// Voice-job model and reasoning (nil = the profile's defaults).
    func setVoiceJobModel(provider: String?, model: String?, reasoningEffort: String?) {
        var preferences = loadVoiceProfilePreferences(profile: activeProfile)
        preferences.voiceJobProvider = model == nil ? nil : provider
        preferences.voiceJobModel = model
        preferences.voiceJobReasoningEffort = reasoningEffort
        objectWillChange.send()
        saveVoiceProfilePreferences(preferences, profile: activeProfile)
    }

    /// The models Hermes offers, for the model pickers (the model sheet,
    /// the bot editor's, Voice and Pulse settings'): the gateway's
    /// `model.options`, kept on the phone as the same answer Usage keeps
    /// (#1533). The model sheet asks for its chat's session. Nil when
    /// Hermes didn't answer, so a picker keeps the models it shows.
    /// `refresh` is Refresh models: Hermes fetches every provider's live
    /// list first (issue 1807).
    func loadModelProviders(sessionId: String? = nil, refresh: Bool = false) async -> [ProviderInfo]? {
        let profile = activeProfile
        guard let client else { return nil }
        let read = { try await client.modelOptionsAnswer(sessionId: sessionId, refresh: refresh) }
        let answer: [String: Any]?
        if let owner = currentDashboardRuntimeOwner() {
            answer = try? await keepingAnswer(profile: profile, owner: owner, keptAs: { _ in KeptRoute.providerQuotas }, read)
        } else {
            answer = try? await read()
        }
        guard let answer, profile == activeProfile else { return nil }
        return Self.modelProviders(in: answer)
    }

    /// Those models as last read, kept on the phone, for the pickers to
    /// open on.
    func keptModelProviders() -> [ProviderInfo] {
        keptAnswer(KeptRoute.providerQuotas).map(Self.modelProviders(in:)) ?? []
    }

    /// The models Hermes offers in `profile`, which may not be the one
    /// open: Settings > Pulse's, for the profile Pulse runs in, where its
    /// model is set (issue 1681). Another profile's come from the
    /// dashboard's route for it, kept as the Model page keeps them. Nil when
    /// Hermes didn't answer, or the dashboard changed meanwhile.
    func loadModelProviders(inProfile profile: String) async -> [ProviderInfo]? {
        if profilesMatch(profile, activeProfile) { return await loadModelProviders() }
        guard let owner = currentDashboardRuntimeOwner(),
              let answer = try? await readKeepingAnswer(KeptRoute.modelOptions, profile: profile, owner: owner),
              ownsDashboardRuntime(owner) else { return nil }
        return Self.modelProviders(in: answer)
    }

    /// `profile`'s models as last read, kept on the phone.
    func keptModelProviders(inProfile profile: String) -> [ProviderInfo] {
        if profilesMatch(profile, activeProfile) { return keptModelProviders() }
        return keptAnswer(KeptRoute.modelOptions, profile: profile).map(Self.modelProviders(in:)) ?? []
    }

    /// The providers of a `model.options` answer.
    static func modelProviders(in answer: [String: Any]) -> [ProviderInfo] {
        (AnyCodable.from(answer).objectValue?["providers"]?.arrayValue ?? []).compactMap(ProviderInfo.init(from:))
    }

    /// Hermes' voice reply model (`auxiliary.voice_chat`) for this profile,
    /// or nil when this Hermes has no such slot; it throws when Hermes
    /// didn't answer. The answer is kept for the section to open on (#1533).
    func loadVoiceReplyModel() async throws -> VoiceReplyModelSetting? {
        try await loadHelperModel(task: VoiceReplyModelSetting.task)
    }

    /// The voice reply model as Hermes gave it last, kept on the phone.
    func keptVoiceReplyModel() -> VoiceReplyModelSetting? {
        keptHelperModel(task: VoiceReplyModelSetting.task)
    }

    /// Hermes' helper model slots (`/api/model/auxiliary`) for this
    /// profile, as Models & providers lists them; throws when Hermes didn't
    /// answer. Kept, with Voice replies' read, for the page to open on.
    func loadHelperModels() async throws -> [HelperModelSlot] {
        HelperModelSlot.slots(in: try await readHelperModels())
    }

    /// The helper models as Hermes gave them last, kept on the phone;
    /// Pulse's too with `includingSetElsewhere`.
    func keptHelperModels(includingSetElsewhere: Bool = false) -> [HelperModelSlot]? {
        keptAnswer(KeptRoute.modelAuxiliary).map { HelperModelSlot.slots(in: $0, includingSetElsewhere: includingSetElsewhere) }
    }

    /// One helper model slot, or nil when this Hermes has no such slot.
    func loadHelperModel(task: String) async throws -> VoiceReplyModelSetting? {
        VoiceReplyModelSetting(auxiliaryResponse: try await readHelperModels(), task: task)
    }

    func keptHelperModel(task: String) -> VoiceReplyModelSetting? {
        keptAnswer(KeptRoute.modelAuxiliary).flatMap { VoiceReplyModelSetting(auxiliaryResponse: $0, task: task) }
    }

    /// Whether the kept helper models list the slot, or nil when none are
    /// kept.
    func keptHelperModelListed(task: String) -> Bool? {
        keptAnswer(KeptRoute.modelAuxiliary).map { VoiceReplyModelSetting(auxiliaryResponse: $0, task: task) != nil }
    }

    /// `profile`'s helper model slots, which may not be the open profile's:
    /// Edit Bot > Work sets its bot's work watch there. The open profile's
    /// share its read; another's come from the dashboard's route for it,
    /// kept as Models & providers keeps them.
    func loadHelperModels(inProfile profile: String) async throws -> [HelperModelSlot] {
        HelperModelSlot.slots(in: try await readHelperModels(inProfile: profile))
    }

    func keptHelperModels(inProfile profile: String) -> [HelperModelSlot]? {
        if profilesMatch(profile, activeProfile) { return keptHelperModels() }
        return keptAnswer(KeptRoute.modelAuxiliary, profile: profile).map { HelperModelSlot.slots(in: $0) }
    }

    func loadHelperModel(task: String, inProfile profile: String) async throws -> VoiceReplyModelSetting? {
        VoiceReplyModelSetting(auxiliaryResponse: try await readHelperModels(inProfile: profile), task: task)
    }

    func keptHelperModel(task: String, inProfile profile: String) -> VoiceReplyModelSetting? {
        if profilesMatch(profile, activeProfile) { return keptHelperModel(task: task) }
        return keptAnswer(KeptRoute.modelAuxiliary, profile: profile).flatMap { VoiceReplyModelSetting(auxiliaryResponse: $0, task: task) }
    }

    private func readHelperModels(inProfile profile: String) async throws -> [String: Any] {
        if profilesMatch(profile, activeProfile) { return try await readHelperModels() }
        guard let owner = currentDashboardRuntimeOwner() else { throw DashboardTicketBridgeError.notReady }
        let answer = try await readKeepingAnswer(KeptRoute.modelAuxiliary, profile: profile, owner: owner)
        guard ownsDashboardRuntime(owner) else { throw CancellationError() }
        return answer
    }

    /// Hermes' `/api/model/auxiliary` answer, carried from the read to
    /// every reader sharing it.
    struct HelperModelsAnswer: @unchecked Sendable { let json: [String: Any] }

    private func readHelperModels() async throws -> [String: Any] {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { throw DashboardTicketBridgeError.notReady }
        let task: Task<HelperModelsAnswer, Error>
        if let read = helperModelsRead, profilesMatch(read.profile, profile), ownsDashboardRuntime(read.owner) {
            task = read.task
        } else {
            task = Task { [self] in
                HelperModelsAnswer(json: try await readKeepingAnswer(KeptRoute.modelAuxiliary, profile: profile, owner: owner))
            }
            helperModelsRead = (profile, owner, task)
        }
        let result = await task.result
        if helperModelsRead?.task == task { helperModelsRead = nil }
        guard profilesMatch(profile, activeProfile) else { throw CancellationError() }
        return try result.get().json
    }

    /// A live voice mode's status line on Voice settings as its last check
    /// said (GPT-Live's, the billing's on screen), kept on the phone so the
    /// line opens on it (#1533).
    func keptLiveVoiceStatus(_ mode: LiveVoiceModeName) -> LiveVoiceStatusLine? {
        keptAnswer(Self.liveVoiceStatusRoute(mode, billing: gptLiveBilling)).flatMap(LiveVoiceStatusLine.init(answer:))
    }

    /// Keeps what a check of `mode` said, for the dashboard and profile
    /// Voice settings showed when this was made; nothing once another
    /// dashboard took over, or after a wipe. GPT-Live's checks keep through
    /// gptLiveStatusKeeper.
    func liveVoiceStatusKeeper(_ mode: LiveVoiceModeName) -> (LiveVoiceStatusLine) -> Void {
        let keep = statusLineKeeper()
        let route = Self.liveVoiceStatusRoute(mode, billing: gptLiveBilling)
        return { keep($0, route) }
    }

    /// GPT-Live's, under the billing its check asked about: the billing can
    /// change while a check is out.
    func gptLiveStatusKeeper() -> (LiveVoiceStatusLine, GPTLiveBilling) -> Void {
        let keep = statusLineKeeper()
        return { keep($0, Self.liveVoiceStatusRoute(.gptLive, billing: $1)) }
    }

    private func statusLineKeeper() -> (LiveVoiceStatusLine, String) -> Void {
        let profile = activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return { _, _ in } }
        let removals = offlineChatCache.removals
        return { [weak self] line, route in
            guard let self else { return }
            // A check's line is kept as a read's answer is, the last to land.
            self.keepAnswer(
                line.answer, for: route, profile: profile, owner: owner, removals: removals,
                turn: self.nextKeptAnswerTurn(), writes: false
            )
        }
    }

    /// GPT-Live's per billing, as each checks another sign-in.
    private static func liveVoiceStatusRoute(_ mode: LiveVoiceModeName, billing: GPTLiveBilling) -> String {
        KeptRoute.liveVoiceStatus + (mode == .gptLive ? "\(mode.storageID)/\(billing.rawValue)" : mode.storageID)
    }

    /// How Hermes took the voice reply model, for the section to show
    /// beside the pickers (#1533). `confirmed` answers Hermes' price check.
    func setVoiceReplyModel(_ setting: VoiceReplyModelSetting, confirmed: Bool = false) async -> HelperModelSaveResult {
        await setHelperModel(
            setting, confirmed: confirmed,
            offline: AppLocalization.string("Connect to Hermes to configure voice for this profile."),
            failure: { AppLocalization.string("Could not save the voice reply model: \($0)") }
        )
    }

    /// Writes a helper model slot (Models & providers > Helper models), in
    /// `profile` when given (Edit Bot > Work's work watch, for its bot).
    func setHelperModel(_ setting: VoiceReplyModelSetting, confirmed: Bool, profile: String? = nil) async -> HelperModelSaveResult {
        await setHelperModel(
            setting, confirmed: confirmed, profile: profile,
            offline: AppLocalization.string("Connect to Hermes to change this profile's models."),
            failure: { AppLocalization.string("Could not save the helper model: \($0)") }
        )
    }

    private func setHelperModel(
        _ setting: VoiceReplyModelSetting, confirmed: Bool, profile: String? = nil, offline: String, failure: (String) -> String
    ) async -> HelperModelSaveResult {
        let profile = profile ?? activeProfile
        guard let owner = currentDashboardRuntimeOwner() else { return .refused(offline) }
        let dashboardTicketBridge = owner.bridge
        do {
            // Hermes writes the profile config for it: in turn with every
            // other config save.
            let result = try await ProfileConfigWriteQueue.runThrowing { [self] in
                try await dashboardTicketBridge.requestJSON(
                    path: dashboardPath("/api/model/set", profile: profile),
                    method: "POST",
                    body: setting.assignmentBody(profile: profile, confirmed: confirmed)
                )
            }
            if result["confirm_required"] as? Bool == true {
                return .needsConfirmation(
                    result["confirm_message"] as? String ?? AppLocalization.string("Hermes requires confirmation before using this model.")
                )
            }
            // The kept slots take the save at once, so the pages open on
            // it even if the read after it never lands, and an answer to a
            // read asked before it isn't kept over it (#1533).
            keepHelperModelWrite(setting, profile: profile, owner: owner)
            // A save drops the read of the profile it saved, even one that
            // isn't open now (a switch leaves a read under way); another
            // profile's save (Edit Bot > Work's work watch) leaves it alone.
            if let read = helperModelsRead, profilesMatch(read.profile, profile) { helperModelsRead = nil }
            // An open list's read asked before the save is dropped for one
            // asked after it.
            NotificationCenter.default.post(name: HelperModelSlot.saved, object: nil)
            guard ownsDashboardRuntime(owner), profile == activeProfile else { return .saved }
            // The shared read, so the open lists' reads after the save
            // join it.
            Task { [weak self] in
                _ = try? await self?.readHelperModels()
            }
            return .saved
        } catch {
            return .refused(failure(UserFacingError.message(for: error)))
        }
    }

    /// The kept `/api/model/auxiliary` answer with `setting`'s slot as
    /// Hermes took it; with nothing kept, the write is still counted.
    private func keepHelperModelWrite(_ setting: VoiceReplyModelSetting, profile: String, owner: DashboardRuntimeOwner) {
        guard var answer = keptAnswer(KeptRoute.modelAuxiliary, profile: profile, on: owner),
              var tasks = answer["tasks"] as? [[String: Any]],
              let index = tasks.firstIndex(where: { $0["task"] as? String == setting.task }) else {
            noteKeptAnswerWrite(for: KeptRoute.modelAuxiliary, profile: profile, owner: owner)
            return
        }
        var row = tasks[index]
        row["provider"] = setting.provider.isEmpty ? "auto" : setting.provider
        row["model"] = setting.model
        row["reasoning_effort"] = setting.reasoningEffort ?? ""
        // Hermes kept the endpoint (a save never sends one); the kept row
        // keeps the one it had, as Hermes answered.
        if setting.baseURL == nil { row["base_url"] = "" }
        tasks[index] = row
        answer["tasks"] = tasks
        keepWrittenAnswer(answer, for: KeptRoute.modelAuxiliary, profile: profile, owner: owner, removals: offlineChatCache.removals)
    }

    /// Where Gemini Live's quick lookups search on this profile.
    var geminiLiveSearchMode: GeminiLiveSearchMode {
        loadVoiceProfilePreferences(profile: activeProfile).geminiLiveSearch ?? .automatic
    }
}
