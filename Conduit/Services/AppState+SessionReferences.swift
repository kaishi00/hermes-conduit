//
//  AppState+SessionReferences.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Session references (durable
//  conversation identity); Secondary profile title recovery.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Session references (durable conversation identity)

    /// The typed reference for a conversation being selected. The kind decides
    /// how the selection is restored later, so it is resolved from EVERY
    /// identity the conversation currently answers to — the id being persisted,
    /// the active id, and the scroll identity's confirmed aliases — never from
    /// the persisted id alone. A resume can rotate the runtime id, and the
    /// rotated id is registered by the reconcile that adopted it; judging by a
    /// single id would let a Bot Chat be recorded as an ordinary conversation
    /// of whatever workspace happened to be active.
    func sessionReference(
        forPersistedID persistedID: String,
        activeSessionID: String?
    ) -> SessionReference {
        // ONLY ids that positively belong to the conversation being recorded.
        // Everything else here would classify a foreign conversation:
        // - the scroll identity's alias set is deliberately widened when a
        //   resume continues the conversation it replaced;
        // - `reconciliation.requestedSessionId` is the PREVIOUS conversation's
        //   id during an open (the boundary is taken before the new id lands).
        // A rotated runtime id is still covered: it is the active id by the time
        // this runs, and the reconcile publishes it as `resolvedSessionId`.
        let candidates = Set([persistedID, activeSessionID, reconciliation?.resolvedSessionId]
            .compactMap { $0 })
        let ownership = botOwnership
        if let botProfile = ownership.botProfileName(owningAny: candidates) {
            // The label captured when the conversation was opened wins over
            // the roster's current label: the open applied that string to the
            // visible surface, and a roster refresh must not silently rename
            // the restored conversation.
            // Ordered candidates, never the Set's iteration order: two
            // identities of one conversation can carry different captured
            // labels, and the restored title must not vary by launch.
            let orderedCandidates = [persistedID, activeSessionID]
                .compactMap { $0 }
                .reduce(into: candidates.sorted()) { result, id in
                    result.removeAll { $0 == id }
                    result.insert(id, at: 0)
                }
            let captured = orderedCandidates
                .compactMap { ChatScrollIdentityNormalization.sessionID($0) }
                .compactMap { botChatSessionLabels[$0] }.first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rosterLabel = ownership.bot(owningAny: candidates)?.displayLabel
            return .bot(
                botName: botProfile,
                label: (captured?.isEmpty == false ? captured : nil) ?? rosterLabel,
                sessionID: persistedID
            )
        }
        // A `.dashboard` write made while bot evidence is UNREADABLE is not a
        // verified ordinary conversation: a bot chat can be sitting in the
        // workspace store during a failed/pending probe, and recording it as
        // typed would let the next launch trust that classification for good.
        // It is recorded as unverified instead, so the authority gates apply to
        // it exactly as they do to a migrated id — and `referenceIfBot` heals it
        // in the one direction that matters once evidence returns.
        return .dashboard(
            profile: activeProfile,
            sessionID: persistedID,
            isUnverified: !botEvidenceIsAvailable
        )
    }

    /// Every identity that can be positively linked to a stored reference
    /// right now: the current scroll identity's confirmed aliases, plus every
    /// id of the catalog row the reference resolves to (including its lineage
    /// root). Bot evidence can live on any of them — a compaction tip or a
    /// rotated runtime is a perfectly normal place for it — while the stored
    /// value names the durable row.
    /// Evidence is taken from the catalog ROW that names the stored id: the
    /// row's own ids are positive provenance. The scroll identity's aliases
    /// are deliberately NOT used here — it unions the aliases of the
    /// conversation a resume continues, and a foreign bot id must never heal
    /// an ordinary conversation into Bot Mode.
    static func aliasesForStoredReference(
        _ reference: SessionReference?,
        catalog: [SessionSummary]
    ) -> Set<String> {
        guard let sessionID = reference?.sessionID else { return [] }
        var aliases = Set<String>()
        if let row = catalog.first(where: { session in
            session.id == sessionID
                || session.storedSessionId == sessionID
                || session.alternateIds.contains(sessionID)
                || session.lineageRootId == sessionID
        }) {
            aliases.formUnion([row.id, row.storedSessionId, row.lineageRootId].compactMap { $0 })
            aliases.formUnion(row.alternateIds)
        }
        aliases.remove(sessionID)
        return aliases
    }

    /// Adopts a restored reference as the active conversation. A Bot Mode
    /// reference re-registers its runtime identity BEFORE anything resumes, so
    /// the follow-up sync addresses the BOT's profile store, presents the
    /// bot's label, and never writes the dashboard's title cache — while an
    /// ordinary conversation restores exactly as it always did.
    func adoptSessionReference(
        _ reference: SessionReference?,
        for profile: String
    ) {
        guard let reference else {
            activeSessionId = nil
            activeSessionTitle = activeSessionTitlesByProfile[profile]
                ?? AppLocalization.string("New conversation")
            publishWidgetSnapshot()
            return
        }
        switch reference.kind {
        case .dashboard:
            activeSessionId = reference.sessionID
            activeSessionTitle = activeSessionTitlesByProfile[profile]
                ?? AppLocalization.string("New conversation")
        case .bot:
            noteBotChatSession(
                reference.sessionID,
                profile: reference.botName ?? reference.scopeProfile,
                label: reference.botLabel
            )
            activeSessionId = reference.sessionID
            activeSessionTitle = Self.botConversationTitle(for: reference, mainName: profileDisplayName("default"))
        }
        publishWidgetSnapshot()
    }

    /// The header title for a restored Bot Chat. The bot's display label when
    /// the reference carries one, else the BOT PROFILE NAME capitalized — the
    /// same last-resort fallback `BotProfile.displayLabel` uses. Never the reserved
    /// wire title: that constant is an identity used for the exact-title lookup,
    /// not a user-facing string, and it would tell the user nothing about which
    /// bot they are looking at.
    /// `mainName` names the main bot, as AppState.profileDisplayName does.
    static func botConversationTitle(for reference: SessionReference, mainName: String = ProfileAppearanceStore.defaultName) -> String {
        let label = reference.botLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (reference.botName ?? reference.scopeProfile)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The main bot by its name now, not one saved before a rename.
        if BotManagement.isDefaultProfile(name) { return mainName }
        // A label that is only the id (saved before #1448) names it as the id does.
        if !label.isEmpty, label != name { return label }
        return name.isEmpty
            ? AppLocalization.string("New conversation")
            : String(name.prefix(1)).uppercased() + String(name.dropFirst())
    }

    /// Registers a Bot Mode reference's identity so the conversation resolves
    /// through the bot's profile for the rest of the process. Idempotent, and
    /// deliberately never writes the dashboard profile's title cache: the
    /// reserved wire title is an identity, not a user-facing dashboard title.
    func registerBotSessionReference(_ reference: SessionReference) {
        guard reference.kind == .bot else { return }
        noteBotChatSession(
            reference.sessionID,
            profile: reference.botName ?? reference.scopeProfile,
            label: reference.botLabel
        )
    }

    /// Shows the bot's name for a restored Bot Chat. The label is
    /// conversation presentation (the bot's display label, never the reserved
    /// wire title) and stays out of the workspace's persisted title cache.
    func applyBotSessionLabel(_ reference: SessionReference) {
        guard reference.kind == .bot else { return }
        // Same resolver as the relaunch path, so a Bot Chat cannot show one
        // title when restored and another when re-adopted.
        activeSessionTitle = Self.botConversationTitle(for: reference, mainName: profileDisplayName("default"))
    }

    /// Writes only a change: every chat open calls this, and a write to the
    /// defaults redraws each `@AppStorage` view.
    func persistActiveSessionTitles() {
        let stored = defaults.dictionary(forKey: activeSessionTitlesByProfileKey) as? [String: String] ?? [:]
        guard stored != activeSessionTitlesByProfile else { return }
        defaults.set(activeSessionTitlesByProfile, forKey: activeSessionTitlesByProfileKey)
    }

    // MARK: - Secondary profile title recovery

    func cancelSecondaryProfileTitleRecovery() {
        sessionTitleRecoveryTracker.cancelAll()
    }

    func cancelSecondaryProfileTitleRecovery(
        profile: String,
        sessionIDs: [String]
    ) async {
        let taskKeys = Set(
            sessionIDs.filter { !$0.isEmpty }.map {
                Self.secondaryTitleRecoveryTaskKey(profile: profile, sessionID: $0)
            }
        )
        await sessionTitleRecoveryTracker.cancel(taskKeys)
    }

    /// One source of truth for the secondary-recovery task key. The scheduler,
    /// its cancellation, and the observability seam below must agree: a
    /// key-format change made in only one of them would silently disable
    /// another (and quietly turn a test pinning the boundary vacuous).
    static func secondaryTitleRecoveryTaskKey(
        profile: String,
        sessionID: String
    ) -> String {
        "\(profile)|\(sessionID)"
    }

    /// Whether a secondary automatic title-recovery task is registered for
    /// this conversation. Canonical Bot Chats are excluded from that
    /// machinery outright (see `scheduleSecondaryProfileTitleRecovery`), so
    /// this answers `false` for them, while ordinary conversations keep the
    /// historical behaviour. Internal rather than private so regression
    /// tests can pin the boundary without waiting out the recovery delay.
    func hasSecondaryTitleRecoveryScheduled(forSessionID sessionID: String) -> Bool {
        sessionTitleRecoveryTracker.hasTask(
            for: Self.secondaryTitleRecoveryTaskKey(
                profile: activeProfile,
                sessionID: sessionID
            )
        )
    }

    private func titleGenerationSettings(for profile: String) async -> TitleGenerationSettings? {
        guard let dashboardTicketBridge else { return nil }
        do {
            let config = try await dashboardTicketBridge.requestJSON(
                path: dashboardPath("/api/config", profile: profile)
            )
            guard profile == activeProfile else { return nil }
            let enabledSetting = profileSettingValue(
                in: config,
                key: "auxiliary.title_generation.enabled"
            )
            let enabled: Bool
            if let explicit = enabledSetting?.boolValue {
                enabled = explicit
            } else if let raw = enabledSetting?.textValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() {
                enabled = !["false", "0", "off", "no"].contains(raw)
            } else {
                // Hermes defaults this feature to enabled when the setting is
                // absent, so preserve that behavior.
                enabled = true
            }
            let language = profileSettingValue(
                in: config,
                key: "auxiliary.title_generation.language"
            )?.textValue
            return TitleGenerationSettings(enabled: enabled, language: language)
        } catch {
            // Do not spend a title-generation request when we cannot confirm
            // the user's setting through the authenticated dashboard.
            titleGenerationLog.error(
                "Could not read title settings for \(profile, privacy: .public): \(LogRedaction.message(error), privacy: .public)"
            )
            return nil
        }
    }

    func scheduleSecondaryProfileTitleRecovery(
        sessionId: String,
        messages: [ChatMessage]
    ) {
        guard let firstUser = messages.first(where: { $0.role == .user })?.content,
              let firstAssistant = messages.first(where: {
                  $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              })?.content else { return }
        scheduleSecondaryProfileTitleRecovery(
            sessionId: sessionId,
            userMessage: firstUser,
            assistantMessage: firstAssistant
        )
    }

    func scheduleSecondaryProfileTitleRecovery(
        sessionId: String,
        userMessage: String,
        assistantMessage: String
    ) {
        // A canonical Bot Chat never participates in automatic title
        // generation: its identity IS the exact title "Bot Chat", so a
        // generated rename would break the exact-title lookup that resolves
        // the profile's forever chat (and could make the bot unmintable or
        // mintable-twice downstream). Registry identity — never a title
        // comparison — decides ownership, so this returns before any RPC,
        // settings read, or task registration.
        guard botConversationProfile(for: sessionId) == nil else { return }
        let profile = activeProfile
        guard profile != "default",
              let client,
              !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assistantMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let taskKey = Self.secondaryTitleRecoveryTaskKey(profile: profile, sessionID: sessionId)
        guard !sessionTitleRecoveryTracker.isSuppressed(taskKey),
              !sessionTitleRecoveryTracker.hasTask(for: taskKey) else { return }
        let token = UUID()
        let task = Task { [weak self, weak client] in
            defer {
                self?.sessionTitleRecoveryTracker.finish(token, for: taskKey)
            }
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }
            guard let self,
                  let client,
                  !Task.isCancelled,
                  self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                  self.activeProfile == profile,
                  self.client === client else { return }

            do {
                // Give Hermes' built-in asynchronous title task precedence.
                // The profile field is self-describing even though current
                // Hermes session.title resolution is session-scoped: bot
                // conversations address their own profile explicitly.
                if let existingTitle = try await client.sessionTitle(
                    sessionId,
                    profile: botConversationProfile(for: sessionId)
                ) {
                    guard !Task.isCancelled,
                          self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                          self.activeProfile == profile,
                          self.client === client else { return }
                    self.applyRecoveredSessionTitle(existingTitle, sessionIDs: [sessionId])
                    titleGenerationLog.notice(
                        "Used Hermes title for \(sessionId, privacy: .private(mask: .hash)) in \(profile, privacy: .public)"
                    )
                    return
                }
                guard let settings = await self.titleGenerationSettings(for: profile),
                      settings.enabled,
                      !Task.isCancelled,
                      self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                      self.activeProfile == profile,
                      self.client === client else { return }
                guard let generated = try await client.generateSessionTitle(
                    sessionId,
                    userMessage: userMessage,
                    assistantMessage: assistantMessage,
                    language: settings.language
                ), let title = Self.normalizedGeneratedSessionTitle(generated),
                      !Task.isCancelled,
                      self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                      self.activeProfile == profile,
                      self.client === client else { return }

                try await client.setSessionTitle(sessionId, title: title)
                guard !Task.isCancelled,
                      self.sessionTitleRecoveryTracker.isCurrent(token, for: taskKey),
                      self.activeProfile == profile,
                      self.client === client else { return }
                self.applyRecoveredSessionTitle(title, sessionIDs: [sessionId])
                titleGenerationLog.notice(
                    "Generated title for \(sessionId, privacy: .private(mask: .hash)) in \(profile, privacy: .public)"
                )
            } catch {
                // Automatic naming is cosmetic. A failed recovery must not
                // interrupt the chat or surface an unrelated error.
                titleGenerationLog.error(
                    "Title recovery failed for \(sessionId, privacy: .private(mask: .hash)) in \(profile, privacy: .public): \(LogRedaction.message(error), privacy: .public)"
                )
            }
        }
        sessionTitleRecoveryTracker.register(task, token: token, for: taskKey)
    }

    static func normalizedGeneratedSessionTitle(_ value: String) -> String? {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let withoutThinking = (try? NSRegularExpression(
            pattern: "(?is)<think\\b[^>]*>.*?</think\\s*>"
        ))?.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: ""
        ) ?? value
        var title = withoutThinking
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.lowercased().hasPrefix("title:") {
            title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
        guard !title.isEmpty else { return nil }
        return String(title.prefix(80))
    }

    func applyRecoveredSessionTitle(_ title: String, sessionIDs: [String]) {
        let result = SessionRenameOperation.Result(title: title, sessionIDs: sessionIDs)
        let titleSessionIDs = Set(sessionIDs.filter { !$0.isEmpty })
        guard !titleSessionIDs.isEmpty else { return }
        var matchesActiveSession = result.matches(sessionID: activeSessionId)
        func updated(_ session: SessionSummary) -> SessionSummary {
            let updated = result.updating(session)
            guard updated != session else { return session }
            if let activeSessionId,
               Set([session.id] + session.alternateIds).contains(activeSessionId) {
                matchesActiveSession = true
            }
            return updated
        }
        // Assigned only on a change: each publish redraws every screen that
        // observes AppState, the open chat included, and a background chat's
        // title event usually names a title the list already shows.
        var listsChanged = false
        let retitled = sessions.map(updated)
        if retitled != sessions { sessions = retitled; listsChanged = true }
        let retitledCron = cronSessions.map(updated)
        if retitledCron != cronSessions { cronSessions = retitledCron; listsChanged = true }
        let retitledArchived = archivedSessions.map(updated)
        if retitledArchived != archivedSessions { archivedSessions = retitledArchived; listsChanged = true }
        // Catalog rows may carry the recovered title either way, but the
        // ACTIVE ordinary persisted title must not: a .sessionTitle event
        // for a canonical Bot Chat would otherwise displace the bot's
        // display label and persist the literal wire title into the
        // dashboard profile's cache. Registry identity — never a title
        // comparison — decides ownership.
        if matchesActiveSession {
            if let activeSessionId, botConversationProfile(for: activeSessionId) == nil {
                setActiveSessionTitle(title)
            }
        }
        if listsChanged || matchesActiveSession { publishWidgetSnapshot() }
    }
}
