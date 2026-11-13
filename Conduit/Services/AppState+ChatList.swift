//
//  AppState+ChatList.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Saved chat list; Stars (#757);
//  Read state (#454).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Saved chat list

    /// Lists the scope's saved Chats list while its live list hasn't landed:
    /// the same rows, icons, nests and project pages the list showed last
    /// time. A no-op once this scope's live list is in.
    func presentSavedChatListIfAvailable(dashboardID: UUID) {
        let profile = activeProfile
        guard dashboardID == activeDashboardID,
              savedChatListForActiveScope == nil,
              sessions.isEmpty, cronSessions.isEmpty,
              !liveChatListLanded(dashboardID: dashboardID, profile: profile),
              let saved = offlineChatCache.loadChatList(dashboardID: dashboardID, profile: profile),
              !saved.sessions.isEmpty || !saved.cronSessions.isEmpty else { return }
        let list = saved.relabeled()
        savedChatList = SavedChatListPresentation(dashboardID: dashboardID, profile: profile, list: list)
        // The rows' call and job icons and nests until the host's tags
        // answer, which merge over these.
        let tagKey = voiceHistoryKey(profile: profile)
        if voiceSessionTagsByKey[tagKey] == nil, !list.voiceTags.isEmpty {
            voiceSessionTagsByKey[tagKey] = list.voiceTags
        }
        // Project chats stay on their project pages until the tree loads.
        if list.supportsProjects, projects.isEmpty, !supportsProjects {
            projects = list.projects
            supportsProjects = true
            projectsSeededFromSavedList = true
        }
        noteConnectionStep("Saved chat list, \(list.sessions.count + list.cronSessions.count) rows")
    }

    /// Saves the Chats list as it shows now, for the next launch or switch
    /// to this profile. Only a list Hermes sent since the saved files were
    /// last wiped is saved, and only while signed in: a list still in memory
    /// from before a sign-in failure may be another account's.
    func recordSavedChatList() {
        guard connection != nil, !showLogin,
              let dashboardID = activeDashboardID,
              savableChatListScope == WidgetWorkspaceID(dashboardID: dashboardID, profile: activeProfile),
              !isShowingSavedChatList else { return }
        let list = SavedChatList.capture(
            sessions: listedSessions,
            cronSessions: activeProfileCronSessions,
            isPinned: isSessionPinned,
            voiceTags: voiceSessionTagsByKey[voiceHistoryKey(profile: activeProfile)] ?? [:],
            projects: projects,
            supportsProjects: supportsProjects
        )
        offlineChatCache.recordChatList(list, dashboardID: dashboardID, profile: activeProfile)
    }

    /// This scope's live list just landed and replaces the saved one. A
    /// newest page alone keeps the saved pinned rows it lacks until the rest
    /// loads, so an older pinned chat doesn't blink out meanwhile.
    func savedChatListReplacedByLiveList(newestPageOnly: Bool, dashboardID: UUID?) {
        ResponsivenessSignposts.signposter.emitEvent("Live Chats list")
        savableChatListScope = dashboardID.map { WidgetWorkspaceID(dashboardID: $0, profile: activeProfile) }
        if let dashboardID { prefetchSavedChats(dashboardID: dashboardID) }
        guard savedChatList != nil else { return }
        guard newestPageOnly, let saved = savedChatListForActiveScope else {
            savedChatList = nil
            return
        }
        // Pinned on the phone, or in the saved list: after a dashboard switch
        // the phone's pins start over from the newest page's alone.
        savedChatList = saved.keepingPinnedRows(
            missingFrom: activeProfileSessions,
            isPinned: { self.isSessionPinned($0) || saved.showedAsPinned($0) }
        )
    }

    /// The saved copies of this profile's chats opened last that the store
    /// reads ahead once the live list is in, and the profiles it reads
    /// ahead for a switch (each one's saved list and the chat it opens on).
    static let prefetchedSavedCopies = 6

    static let prefetchedSwitchProfiles = 8

    /// Reads ahead, off the main thread, what a tap shows next, so it comes
    /// from memory: the copies of this profile's chats opened last and its
    /// screens' kept answers, and for a profile switch, each other profile's
    /// saved list and last chat. The store does it once per profile until
    /// something is removed.
    private func prefetchSavedChats(dashboardID: UUID) {
        offlineChatCache.prefetch(
            dashboardID: dashboardID,
            profile: activeProfile,
            transcripts: Self.prefetchedSavedCopies,
            answers: true
        )
        // The answers about the whole Hermes (the Bots list's).
        offlineChatCache.prefetch(dashboardID: dashboardID, profile: KeptRoute.everyProfile, transcripts: 0, answers: true)
        for profile in profiles.filter({ $0 != activeProfile }).prefix(Self.prefetchedSwitchProfiles) {
            offlineChatCache.prefetch(dashboardID: dashboardID, profile: profile, transcripts: 1)
        }
    }

    func dismissSavedChatList() {
        chatPickedFromSavedList = nil
        // Project pages the saved list brought leave with it, unless Hermes'
        // own have replaced them.
        if projectsSeededFromSavedList {
            projects = []
            supportsProjects = false
        }
        guard savedChatList != nil else { return }
        savedChatList = nil
    }

    /// A row the saved list put there: every row while it shows, then the
    /// kept pinned ones. It takes no actions, which would act on a list
    /// Hermes hasn't sent yet.
    func isSavedChatRow(_ session: SessionSummary) -> Bool {
        // Another profile's row in All comes from Hermes' own listing.
        guard !isOtherProfileRow(session), let saved = savedChatListForActiveScope else { return false }
        return saved.isShowingSavedRows || saved.isKeptRow(session)
    }

    /// A tap on a Chats row. While the list is still the saved one, the chat
    /// shows at once (its saved copy, or its title while it opens) and opens
    /// for real once the live list lands.
    func openListedSession(_ session: SessionSummary) {
        // Another profile's row in All opens the way a link to it does:
        // the switch to its profile, then the chat.
        let owner = rowProfile(session)
        if owner != activeProfile {
            // A switch ends a call: say so here, where the tap was.
            guard !isVoiceCallInProgress else {
                showSessionMutationNotice(AppLocalization.string("End the call to open a chat in another profile."))
                return
            }
            Task { @MainActor [weak self] in await self?.routeLinkedSession(session.id, toProfile: owner) }
            return
        }
        guard isShowingSavedChatList, let dashboardID = activeDashboardID else {
            // A kept row isn't in the live list yet: it opens by its saved
            // durable id, as a pick does.
            requestOpenSession(isSavedChatRow(session) ? session.storedSessionId ?? session.id : session.id)
            return
        }
        // A newer destination than a New Chat or widget action on its way.
        widgetLaunchCoordinator.supersede()
        let profile = activeProfile
        let ids = Set(session.nestingIDs)
        let durableID = session.storedSessionId ?? session.id
        chatPickedFromSavedList = SavedChatListPick(
            dashboardID: dashboardID,
            profile: profile,
            sessionIDs: ids,
            openID: durableID,
            rowID: session.id
        )
        let snapshot = offlineChatPresentation.flatMap { $0.dashboardID == dashboardID && $0.profile == profile ? $0.snapshot : nil }
            ?? offlineChatCache.load(dashboardID: dashboardID, profile: profile)
            ?? OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: [])
        let saved = snapshot.transcripts.first { ids.contains($0.sessionID) }
        offlineChatPresentation = OfflineChatPresentation(
            dashboardID: dashboardID,
            profile: profile,
            snapshot: snapshot,
            displayedTranscript: saved.flatMap {
                offlineChatCache.loadTranscript($0.sessionID, dashboardID: dashboardID, profile: profile)
            },
            picked: OfflineChatPresentation.PickedChat(title: session.title, sessionIDs: ids, durableSessionID: durableID)
        )
    }

    /// Reads a listed chat's saved copy into memory off the main thread as
    /// its row shows, so tapping it shows the copy from memory rather than
    /// reading its file first (issue 1725).
    func warmSavedCopy(of session: SessionSummary) {
        guard let dashboardID = activeDashboardID else { return }
        // Another profile's row in All opens in its own profile: its copy is
        // kept under that one.
        // Its stored id first, where a copy is most often saved, then every
        // other id the row answers to, as the open looks it up.
        let ids = [session.storedSessionId].compactMap { $0 } + session.nestingIDs
        offlineChatCache.warmTranscript(ids, dashboardID: dashboardID, profile: rowProfile(session))
    }

    /// A chat opened while connected shows its saved copy until its own
    /// transcript lands, as a chat picked in the saved list does, so going
    /// back to a chat never shows it blank first (#1352). A chat with no
    /// copy opens as before, and so does one already picked in the saved
    /// list (its copy is up).
    ///
    /// A copy in memory shows at once. One that isn't is read off the main
    /// thread while the open goes ahead (issue 1826), and shows when it's
    /// in if this open (`transition`, `reconcileToken`) still owns the chat
    /// and Hermes' rows haven't come first.
    func presentSavedCopyWhileOpening(
        _ session: SessionSummary,
        openedAs sessionID: String,
        transition: UInt64,
        reconcileToken: UUID
    ) {
        guard let dashboardID = activeDashboardID else { return }
        var ids = Set(session.nestingIDs)
        ids.insert(sessionID)
        // A Bot Chat's row can turn up in the workspace's list (a stray from
        // older server data): its copy is the one kept in memory, never a file.
        guard botStoreProfile(forSessionIDs: Array(ids)) == nil else { return }
        if let picked = offlineChatPresentation?.picked, !picked.sessionIDs.isDisjoint(with: ids) { return }
        let durableID = session.storedSessionId ?? session.id
        let profile = activeProfile
        offlineChatCache.readTranscript(durableID, dashboardID: dashboardID, profile: profile) { [weak self] saved in
            guard let self, let saved,
                  self.chatViewportTransitionIsCurrent(generation: transition),
                  self.reconciliationToken == reconcileToken,
                  self.reconciliation?.token == reconcileToken,
                  self.activeSessionId == sessionID,
                  self.activeDashboardID == dashboardID,
                  self.activeProfile == profile,
                  self.messages.isEmpty else { return }
            self.offlineChatPresentation = OfflineChatPresentation(
                dashboardID: dashboardID,
                profile: profile,
                snapshot: OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: []),
                displayedTranscript: saved,
                picked: OfflineChatPresentation.PickedChat(title: session.title, sessionIDs: ids, durableSessionID: durableID)
            )
            ResponsivenessSignposts.signposter.emitEvent("Saved rows shown")
        }
    }

    /// The chat a profile switched to opens on: the outgoing profile's
    /// transcript and any reply still streaming into it leave with it (it
    /// showed under the new chat's title for the whole switch, #1442). Its saved copy shows while Hermes sends it,
    /// or nothing does. A chat opened in that profile (All chats, a
    /// notification, a link) replaces it with its own as it opens.
    func presentRestoredChatAfterProfileChange() {
        messages = []
        clearStreamingText()
        resetReasoningTurn()
        dismissOfflineChatPresentation()
        guard let sessionID = activeSessionId else { return }
        if let bot = botConversationProfile(for: sessionID) {
            presentKeptBotChatCopy(bot: bot, openedAs: sessionID, title: activeSessionTitle)
            return
        }
        // Copies are saved under the chat's stored id, and the restored
        // reference can hold its runtime id: the saved list's row maps one
        // to the other. A row that owns the id wins over one that only
        // borrows it, and an alias two rows borrow maps to neither.
        let rows = savedChatListForActiveScope?.list.sessions ?? []
        let aliasRows = rows.filter { $0.nestingIDs.contains(sessionID) }
        let row = rows.first { $0.id == sessionID || $0.storedSessionId == sessionID }
            ?? (aliasRows.count == 1 ? aliasRows.first : nil)
        let durableID = row.map { $0.storedSessionId ?? $0.id } ?? sessionID
        guard let dashboardID = activeDashboardID else { return }
        let profile = activeProfile
        let sessionIDs = Set([sessionID] + (row?.nestingIDs ?? []))
        // Off the main thread when it isn't in memory (issue 1826): it shows
        // if the switch still opens on this chat with nothing else up yet.
        offlineChatCache.readTranscript(durableID, dashboardID: dashboardID, profile: profile) { [weak self] saved in
            guard let self, let saved,
                  self.activeSessionId == sessionID,
                  self.activeDashboardID == dashboardID,
                  self.activeProfile == profile,
                  self.messages.isEmpty,
                  self.offlineChatPresentation == nil else { return }
            self.offlineChatPresentation = OfflineChatPresentation(
                dashboardID: dashboardID,
                profile: profile,
                snapshot: OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: []),
                displayedTranscript: saved,
                picked: OfflineChatPresentation.PickedChat(
                    title: self.activeSessionTitle,
                    sessionIDs: sessionIDs,
                    durableSessionID: durableID
                )
            )
        }
    }

    /// A Bot Chat has no row of its own, so it keeps no copy on the phone:
    /// the one on screen is kept in memory when it's left, by dashboard and
    /// bot, to show while it opens again (#1352).
    struct KeptBotChatCopy {
        let sessionIDs: Set<String>
        let transcript: OfflineCachedTranscript
    }

    private static func keptBotChatCopyKey(dashboardID: UUID, bot: String) -> String {
        "\(dashboardID.uuidString)|\(bot)"
    }

    /// A chat left after Load earlier brought in rows older than Hermes'
    /// newest page: its loaded rows and paging window, kept in memory so
    /// opening it again grafts Hermes' newest page onto them, as a reconnect
    /// does, instead of starting again from one page (issue 1825). Only such
    /// chats are kept: any other one's rows are its saved copy and the page
    /// the open reads anyway.
    struct LeftBackfilledTranscript {
        /// Nil for a connection with no saved dashboard.
        let dashboardID: UUID?
        let sessionIDs: Set<String>
        let messages: [ChatMessage]
        let window: PersistedTranscriptWindowState
    }

    static let maxLeftBackfilledTranscripts = 3

    /// How many rows a chat holds before it lets go of the oldest pages
    /// Load earlier brought in: twice the saved copy's 500 (issue 1828).
    static let loadedHistoryRowLimit = 1_000

    /// The reader is back at the newest row: a chat past the limit lets go
    /// of its oldest loaded pages, out of sight above them, and Load earlier
    /// brings them back from Hermes (Eric, 2026-11-05, issue 1828). Only
    /// between turns and on Hermes' own rows.
    func trimLoadedHistoryIfLong() {
        guard turnState == .idle,
              !chatReaderIsUpInOlderRows,
              offlineChatPresentation == nil,
              reconciliation == nil,
              let window = persistedTranscriptWindow,
              persistedTranscriptWindowOwnershipIsCurrent(window),
              let trimmed = PersistedTranscriptWindow.trimmingLoadedHistory(
                messages, window: window, keeping: Self.loadedHistoryRowLimit
              ) else { return }
        messages = trimmed.messages
        persistedTranscriptWindow = trimmed.window
    }

    /// Keeps the chat on screen as it's left, when Load earlier brought in
    /// its older rows: Hermes' rows only, never saved rows standing in.
    func keepLeftBackfilledTranscript() {
        guard offlineChatPresentation == nil,
              turnState != .synchronizing,
              !messages.isEmpty,
              let window = persistedTranscriptWindow, window.hasBackfilledPrefix else { return }
        let dashboardID = activeDashboardID
        // The ids its window's own open vouched for together, never the
        // scroll identity's aliases, which can name the chat it replaced.
        let sessionIDs = window.trustedSessionIDs
        leftBackfilledTranscripts.removeAll {
            $0.dashboardID == dashboardID && !$0.sessionIDs.isDisjoint(with: sessionIDs)
        }
        // A long chat lets go of its oldest pages as it's left between
        // turns from its newest row (issue 1828). A reader up in the older
        // rows keeps them, so their place there comes back with the chat.
        // A Load earlier still in flight is dropped by the open.
        var leftWindow = window
        leftWindow.isLoadingEarlier = false
        let trimmed = turnState == .idle && !chatReaderIsUpInOlderRows
            ? PersistedTranscriptWindow.trimmingLoadedHistory(
                messages, window: leftWindow, keeping: Self.loadedHistoryRowLimit
            )
            : nil
        let kept = trimmed ?? (messages: messages, window: leftWindow)
        guard kept.window.hasBackfilledPrefix else { return }
        leftBackfilledTranscripts.append(LeftBackfilledTranscript(
            dashboardID: dashboardID,
            sessionIDs: sessionIDs,
            messages: kept.messages,
            window: kept.window
        ))
        if leftBackfilledTranscripts.count > Self.maxLeftBackfilledTranscripts {
            leftBackfilledTranscripts.removeFirst(leftBackfilledTranscripts.count - Self.maxLeftBackfilledTranscripts)
        }
    }

    /// An open that never landed (cancelled, or overtaken by a newer one)
    /// puts back the kept rows it took, for the next open.
    func putBackLeftBackfilledTranscript(_ kept: LeftBackfilledTranscript) {
        guard !leftBackfilledTranscripts.contains(where: {
            $0.dashboardID == kept.dashboardID && !$0.sessionIDs.isDisjoint(with: kept.sessionIDs)
        }) else { return }
        leftBackfilledTranscripts.append(kept)
        if leftBackfilledTranscripts.count > Self.maxLeftBackfilledTranscripts {
            leftBackfilledTranscripts.removeFirst(leftBackfilledTranscripts.count - Self.maxLeftBackfilledTranscripts)
        }
    }

    /// The kept chat a reconcile into an empty chat is (an open, the chat a
    /// profile switch opens on), taken from memory: the transcript it builds
    /// is the chat's from here, kept again when it's left. The reconcile
    /// grafts onto it only when its window owns the conversation Hermes
    /// resumed and Hermes' page overlaps its rows, as a reconnect's graft
    /// does; otherwise Hermes' page stands alone.
    func takeLeftBackfilledTranscript(for sessionIDs: Set<String>, profile: String) -> LeftBackfilledTranscript? {
        let dashboardID = activeDashboardID
        guard let index = leftBackfilledTranscripts.lastIndex(where: {
                  $0.dashboardID == dashboardID
                      && profilesMatch($0.window.profile, profile)
                      && !$0.sessionIDs.isDisjoint(with: sessionIDs)
              }) else { return nil }
        return leftBackfilledTranscripts.remove(at: index)
    }

    /// Kept chats go with their saved copies: a deleted chat, a removed
    /// dashboard, a sign-out, Delete saved chats.
    func forgetLeftBackfilledTranscripts(dashboardID: UUID?, sessionIDs: Set<String>? = nil) {
        leftBackfilledTranscripts.removeAll { kept in
            (dashboardID == nil || kept.dashboardID == dashboardID)
                && sessionIDs.map { !kept.sessionIDs.isDisjoint(with: $0) } != false
        }
    }

    /// Keeps the Bot Chat on screen, as `recordOfflineChatCopy` saves any
    /// other chat: connected, authoritative rows only.
    func keepBotChatCopy() {
        guard isConnected,
              offlineChatPresentation == nil,
              turnState != .synchronizing,
              let dashboardID = activeDashboardID,
              let sessionID = activeSessionId,
              let identities = offlineChatIdentities(),
              // The bot owning the id the chat is open as: the registry names
              // the bot each open was for. Never one the chat's other ids name:
              // the scroll identity's aliases can still name the chat it
              // replaced, another bot's, or a Bot Chat an ordinary chat
              // replaced (#1352).
              let bot = ChatResumeStore.rpcProfileName(botChatCopyOwner(openAs: sessionID)) else { return }
        let rows = messages.compactMap(OfflineCachedMessage.init)
            .suffix(OfflineChatCacheStore.maxMessagesPerTranscript)
        guard !rows.isEmpty else { return }
        let key = Self.keptBotChatCopyKey(dashboardID: dashboardID, bot: bot)
        // Up to 500 rows each, so the copies kept in memory are bounded by
        // count too: the least recently kept goes (#1831).
        if let oldest = Self.keptBotChatCopyToDrop(keptAt: keptBotChatCopies.mapValues(\.transcript.savedAt), adding: key) {
            keptBotChatCopies[oldest] = nil
        }
        keptBotChatCopies[key] = KeptBotChatCopy(
            sessionIDs: identities.union([sessionID]),
            transcript: OfflineCachedTranscript(
                sessionID: sessionID,
                title: activeSessionTitle,
                savedAt: Date(),
                messages: Array(rows)
            )
        )
    }

    /// The bot whose copy the chat open as `sessionID` is, as it was before
    /// any bot open since noted its destination over that id.
    private func botChatCopyOwner(openAs sessionID: String) -> String? {
        if let outgoing = outgoingBotChatCopyOwner, outgoing.sessionID == sessionID {
            return outgoing.bot
        }
        return botConversationProfile(for: sessionID)
            ?? botStoreProfile(forSessionIDs: [sessionID])
    }

    /// Notes the ids a bot open is for, after taking the owner of the chat
    /// on screen: the open keeps that chat's copy when it flushes, and a
    /// destination sharing its id must not take it.
    func noteBotChatOpen(_ sessionIDs: [String?], bot: BotProfile) {
        if let active = activeSessionId, outgoingBotChatCopyOwner?.sessionID != active {
            outgoingBotChatCopyOwner = (active, botChatCopyOwner(openAs: active))
        }
        for sessionID in sessionIDs {
            noteBotChatSession(sessionID, profile: bot.name, label: bot.displayLabel)
        }
    }

    /// `presentSavedCopyWhileOpening` for a Bot Chat: its kept copy, when
    /// the chat being opened is one of the ids it was kept under. It is what
    /// was on screen when the chat was left, a /new's compaction included.
    func presentKeptBotChatCopy(bot: String, openedAs sessionID: String, title: String?) {
        // Spelled as the registry spells the bot the copy was kept for.
        guard let dashboardID = activeDashboardID,
              let bot = ChatResumeStore.rpcProfileName(bot),
              let kept = keptBotChatCopies[Self.keptBotChatCopyKey(dashboardID: dashboardID, bot: bot)],
              kept.sessionIDs.contains(sessionID) else { return }
        // Under the id it opens as, the Bot Chat's own: the one it was kept
        // under was that run's runtime id, and words typed while it opens
        // must keep to a draft the chat finds again.
        let transcript = OfflineCachedTranscript(
            sessionID: sessionID,
            title: kept.transcript.title,
            savedAt: kept.transcript.savedAt,
            messages: kept.transcript.messages
        )
        offlineChatPresentation = OfflineChatPresentation(
            dashboardID: dashboardID,
            profile: activeProfile,
            snapshot: OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: []),
            displayedTranscript: transcript,
            picked: OfflineChatPresentation.PickedChat(
                title: title ?? kept.transcript.title,
                sessionIDs: kept.sessionIDs.union([sessionID]),
                durableSessionID: sessionID
            )
        )
    }

    /// The chat picked in the saved list for this scope, as the id to open it
    /// by: its live row's when the live list has it, else its saved durable
    /// id. Forgotten once taken; a pick from another scope is dropped.
    func takeChatPickedFromSavedList(dashboardID: UUID?, profile: String) -> String? {
        guard let pick = chatPickedFromSavedList else { return nil }
        chatPickedFromSavedList = nil
        guard pick.dashboardID == dashboardID, pick.profile == profile else {
            if offlineChatPresentation?.isPickedChat == true { dismissOfflineChatPresentation() }
            return nil
        }
        let ids = pick.sessionIDs
        if let live = (activeProfileSessions + activeProfileCronSessions).first(where: { !ids.isDisjoint(with: $0.nestingIDs) }) {
            // The open goes by the live row's id, which may be new (a fresh
            // runtime id): its saved copy stays up for that open too.
            if offlineChatPresentation?.picked?.sessionIDs.isDisjoint(with: ids) == false {
                offlineChatPresentation?.picked?.sessionIDs.formUnion(live.nestingIDs)
            }
            return live.id
        }
        return pick.openID
    }

    /// Opens the chat picked in the saved list. An open that fails takes its
    /// copy down too, so a read-only chat doesn't stay up with nothing on
    /// its way.
    func openChatPickedFromSavedList(_ sessionID: String) {
        requestOpenSession(sessionID) { [weak self] _ in
            guard let self, self.offlineChatPresentation?.isPickedChat == true else { return }
            self.dismissOfflineChatPresentation()
        }
    }

    /// The widget coordinator's pending link changed. A New Chat on its way
    /// shows as its chat, except during a call, which refuses it. A Talk on
    /// its way shows its call screen.
    func widgetLaunchPendingLinkChanged(_ link: WidgetLaunchLink?) {
        if link?.action == .talk {
            presentWaitingCallIfNeeded()
        } else {
            endWaitingCall(owner: .widget)
        }
        let pending = link?.action == .newChat && !isVoiceCallInProgress ? link?.workspace : nil
        guard pending != pendingNewChat else { return }
        pendingNewChat = pending
        // The new chat is the one on screen now, not a chat picked in the
        // saved list before it.
        guard pending != nil else { return }
        chatPickedFromSavedList = nil
        if offlineChatPresentation?.isPickedChat == true { dismissOfflineChatPresentation() }
    }

#if DEBUG
    var chatPickedFromSavedListIDForTesting: String? { chatPickedFromSavedList?.rowID }
#endif

    func wipeOfflineChatCache(dashboardID: UUID?) {
        if let dashboardID {
            offlineChatCache.removeDashboard(dashboardID)
            keptBotChatCopies = keptBotChatCopies.filter { !$0.key.hasPrefix("\(dashboardID.uuidString)|") }
        } else {
            offlineChatCache.removeAll()
            keptBotChatCopies.removeAll()
        }
        forgetLeftBackfilledTranscripts(dashboardID: dashboardID)
        // Chat pictures kept on the phone go with the chats. Their files are
        // named by a hash, so they cannot be told apart by server.
        TranscriptImageCache.purge()
        TranscriptPictureMemory.forgetAll()
        HTMLPreviewDocuments.shared.removeAll(dashboardID: dashboardID)
        // So do the open dashboard's pinned replies (#918): they keep reply
        // text, and the next sign-in may be another account.
        if dashboardID == nil || dashboardID == activeDashboardID { clearPinnedReplies() }
        // So do its confirmations' answers still waiting to reach the host:
        // a Say instead keeps the user's words (issue 2041).
        presentedScreens.forgetAnswers(dashboardID: dashboardID)
        // So do the summaries describing its runs of steps.
        forgetStepSummaries(scopePrefix: dashboardID.map { "\(Self.dashboardPreferenceBucket($0))." })
        // And the open dashboard's predictions: guesses, the draft they
        // read, hidden follow-ups and the checks still waiting.
        if dashboardID == nil || dashboardID == activeDashboardID { forgetPredictiveState() }
        leaveSavedChats(dashboardID: dashboardID)
    }

    /// What of the saved chats is in memory (the copy and list on screen,
    /// picture reads under way, whether the list may be saved) leaves with
    /// its dashboard, whether the dashboard's files are wiped or kept.
    func leaveSavedChats(dashboardID: UUID?) {
        inlineImageRowsUnavailable.removeAll()
        inlineImageRowFetches.values.forEach { $0.cancel() }
        inlineImageRowFetches.removeAll()
        if offlineChatPresentation.map({ dashboardID == nil || $0.dashboardID == dashboardID }) == true {
            offlineChatPresentation = nil
        }
        if savedChatList.map({ dashboardID == nil || $0.dashboardID == dashboardID }) == true {
            dismissSavedChatList()
        }
        if savableChatListScope.map({ dashboardID == nil || $0.dashboardID == dashboardID }) == true {
            savableChatListScope = nil
        }
        // So does a message waiting for one of its chats: its file stays for
        // the next visit there unless the dashboard's saved chats are wiped.
        leaveComposerSends(dashboardID: dashboardID)
    }

    /// Settings' Delete Saved Chats: every dashboard's saved Chats lists,
    /// conversation copies, kept pictures and the answers its screens last
    /// showed, on this phone. The chat in use and its picture reads carry
    /// on; the list is saved again once Hermes next sends it.
    func deleteSavedChats() {
        // Pending messages are the user's words, including those parked
        // on other dashboards. Keep their files rather than rewriting only
        // the messages currently loaded in memory.
        offlineChatCache.removeSavedChats()
        keptBotChatCopies.removeAll()
        forgetLeftBackfilledTranscripts(dashboardID: nil)
        TranscriptImageCache.purge()
        TranscriptPictureMemory.forgetAll()
        HTMLPreviewDocuments.shared.removeAll()
        // The summaries describing runs of steps go with the chats.
        forgetStepSummaries(scopePrefix: nil)
        if connection == nil, let copy = offlineChatPresentation {
            // Until this launch's sign-in goes through, the copy is what keeps
            // the app and its Retry up: it stays, with nothing saved in it.
            offlineChatPresentation = OfflineChatPresentation(
                dashboardID: copy.dashboardID,
                profile: copy.profile,
                snapshot: OfflineChatSnapshot(lastSessionID: nil, sessions: [], transcripts: []),
                displayedTranscript: nil
            )
        } else {
            dismissOfflineChatPresentation()
        }
        dismissSavedChatList()
        savableChatListScope = nil
    }

    var offlineChatCacheForTesting: OfflineChatCacheStore { offlineChatCache }

    /// Assigns the active profile and fences deferred presentation-cache
    /// work: any coalesced flush scheduled under another profile becomes
    /// stale the moment the identity changes. Call this instead of assigning
    /// `activeProfile` directly so no mutation site can skip the fence.
    ///
    /// Deliberately NOT flushing here: on rollbacks (failed switches) the
    /// still-active identity does not own the restored in-memory content,
    /// so the synchronous outgoing-transcript flush belongs at each forward
    /// transition site (`switchProfile`, `connect(with:profile:)`) where
    /// that ownership is guaranteed. Both fence conditions in
    /// `schedulePresentationCacheFlush` are intentionally redundant — string
    /// equality is the readable guard, the wrapping `&+= 1` (overflows only
    /// after ~9.2×10^18 switches — unreachable) catches A→B→A round-trips —
    /// do not simplify either away.
    func setActiveProfile(_ newValue: String) {
        guard newValue != activeProfile else { return }
        activeProfile = newValue
        // A chat error waiting behind a room was the outgoing profile's chat's.
        chatErrorBehindRoom = nil
        widgetSettledCatalogOwner = nil
        keepDelegateAgents(of: [])
        publishWidgetCurrentWorkspace(dashboardID: activeDashboardID, profile: newValue)
        presentationCacheProfileEpoch &+= 1
        // The saved copy and list belong to the outgoing profile's scope.
        dismissOfflineChatPresentation()
        dismissSavedChatList()
        // So do the unsaved voice calls Voice settings counts.
        publishVoiceCallSaveStatus()
        // And the Watch voice checks: this profile's decide whether calls
        // ring the Watch. Rescoped here, not only by the refresh below, so
        // a Watch call before that refresh's first await can't read the
        // outgoing profile's checks.
        rescopeWatchCallVoices()
        Task { await refreshWatchCallVoices() }
    }

#if DEBUG
    /// Deterministic-test access to the pending coalesced flush. Awaiting its
    /// value settles every deferred-write decision (cancelled, fenced, or
    /// completed) without wall-clock timing. Test-only plumbing; compiled out
    /// of release builds.
    var presentationCacheFlushOperationForTesting: Task<Void, Never>? {
        presentationCacheFlushTask
    }

    func setActiveProfileForTesting(_ profile: String) {
        setActiveProfile(profile)
    }

    func setProjectsForTesting(_ projects: [ProjectSummary]) {
        self.projects = projects
    }
#endif

    // MARK: - Stars (#757)

    func isSessionStarred(_ session: SessionSummary) -> Bool {
        sessionStars.isStarred(session, profile: rowProfile(session))
    }

    func toggleSessionStarred(_ session: SessionSummary) {
        let profile = rowProfile(session)
        guard sessionBelongsToProfile(session, profile: profile) else { return }
        setSessionStarred(session, starred: !isSessionStarred(session), profile: profile)
    }

    func setSessionStarred(_ session: SessionSummary, starred: Bool, profile: String) {
        var stars = sessionStars
        stars.set(session, starred: starred, profile: profile)
        guard stars != sessionStars else { return }
        sessionStars = stars
        stars.save(to: defaults)
    }

    // MARK: - Read state (#454)

    func isSessionUnread(_ session: SessionSummary) -> Bool {
        chatReadState.isUnread(session, profile: rowProfile(session))
    }

    /// Whether a turn is running in the conversation or it waits on the user.
    /// The open chat's own running turn is authoritative for "working", so
    /// its row says what its working line says; the registry snapshot can
    /// lag it by a poll.
    func sessionLiveStatus(_ session: SessionSummary) -> SessionLiveStatus? {
        // A snapshot from before a disconnect may be long stale.
        let registry = isConnected && liveSessionStatusProfile == activeProfile
            ? liveSessionStatusIndex.status(for: session)
            : nil
        // Another profile's row reads its own profile's registry, read by
        // name, since Hermes' session authority lists only the profile it's
        // asked for; until that read lands, the profile in use's, which on
        // the legacy dashboard lists every profile's (#1353). Never the open
        // chat, which is the profile in use's.
        guard !isOtherProfileRow(session) else { return otherProfileLiveStatus(session, fallback: registry) }
        if sessionMatchesActiveSession(session) {
            if registry == .needsInput { return .needsInput }
            // Running while the chat shows its working line, stale or not:
            // a Mac window that isn't frontmost goes inactive, which marks
            // the turn state stale while its events keep coming, and the
            // row had gone quiet beside a chat still saying it worked
            // (issue 1615).
            if isBusy { return .working }
            // A known idle is fresher than a poll; while the chat is still
            // syncing, or its idle is stale, the registry decides.
            let localIdleKnown = !turnStateIsStale && turnState == .idle
            return localIdleKnown ? nil : registry
        }
        return registry
    }

    /// Re-reads the live registry while the chat list is on screen. Cheap: an
    /// in-memory snapshot that resumes and changes nothing. Gateways without
    /// `session.active_list` just leave the filters empty. The rows also go
    /// through the identity index on purpose: each snapshot is the same
    /// authoritative evidence the foreground probe records, and re-recording
    /// an unchanged binding is a no-op.
    ///
    /// Returns false when the read failed (a gateway without the method
    /// counts as read: there is nothing to ask).
    @discardableResult
    func refreshLiveSessionStatuses() async -> Bool {
        // Its own task: a slow plugin read must not hold up live status.
        Task { [weak self] in await self?.refreshDesktopViewsIfDue() }
        guard sceneIsInView, let client, isConnected else { return false }
        guard client !== activeListUnsupportedClient else { return true }
        // The other profiles on screen are read at the same time, by name.
        let others = startOtherProfilesLiveStatusReads(client)
        let read = await readOwnLiveSessionStatuses(client)
        await finishOtherProfilesLiveStatusReads(others, client: client)
        return read
    }

    /// The profile in use's registry (no profile named: the client's own).
    private func readOwnLiveSessionStatuses(_ client: HermesClient) async -> Bool {
        let profile = activeProfile
        do {
            let rows: [LiveSessionStatus]
            if let probeActiveSessions = chatResumeLifecycleOperations.probeActiveSessions {
                rows = try await probeActiveSessions(client)
            } else {
                rows = try await client.activeSessions()
            }
            guard profile == activeProfile, self.client === client else { return true }
            // Assigned only on a change: every publish redraws the chat list.
            if !liveSessionStatusAvailable { liveSessionStatusAvailable = true }
            activeListFailureLoggedClient = nil
            recordActiveListEvidence(rows, profile: profile)
            latestActiveList = (rows, profile, ObjectIdentifier(client), chatSyncNow())
            return true
        } catch {
            // Stop asking a gateway that doesn't have the method; a new
            // connection probes again. Other failures retry on the next tick.
            if isMethodUnavailable(error) {
                activeListUnsupportedClient = client
                if self.client === client, liveSessionStatusAvailable { liveSessionStatusAvailable = false }
                return true
            } else if client !== activeListFailureLoggedClient {
                activeListFailureLoggedClient = client
                sessionCatalogLog.notice(
                    "Live status poll failed: \(LogRedaction.describing(error), privacy: .public)"
                )
            }
            return false
        }
    }

    static let desktopViewsInterval: TimeInterval = 15

    /// Reads which chats Hermes Desktop (or the web dashboard) had on the
    /// host (notifier plugin 0.12+), so reading a chat there reads it here.
    /// The chat Desktop has selected stays seen for as long as it stays
    /// selected there (Eric's call on #454). Hermes' own read flag stays
    /// untouched: writing it would put Desktop's unread dot on the chat it
    /// has open.
    func refreshDesktopViewsIfDue() async {
        guard isSceneActive, let bridge = dashboardTicketBridge else { return }
        // Keyed by host, not bridge: a sign-in or header change rebuilds the
        // bridge for the same host, whose record still holds.
        if bridge.baseURL != desktopViewsHost { resetDesktopViews(host: bridge.baseURL) }
        switch notifierPlugin.state {
        case .reported(_, let capabilities) where capabilities.contains("desktop-views"):
            break
        case .unknown:
            return
        case .reported, .predatesCapabilities:
            // The host answered without the route: its record goes too.
            if !chatReadState.desktopSeenThrough.isEmpty { resetDesktopViews(host: bridge.baseURL) }
            return
        }
        let profile = activeProfile
        let now = Date()
        if let last = desktopViewsFetchedAt[profile], now.timeIntervalSince(last) < Self.desktopViewsInterval { return }
        desktopViewsFetchedAt[profile] = now
        var path = "/api/plugins/conduit_push/sessions/desktop-views"
        if let cursor = desktopViewsCursor[profile] { path += "?since=\(cursor)" }
        let response: [String: Any]
        do {
            // The hook watching Desktop runs in the dashboard process (#1336).
            response = try await bridge.requestJSON(
                path: DashboardPath.withProfile(path, profile: profile, parameter: notifierPlugin.dashboardProfileParameter))
        } catch {
            // The next tick past the interval asks again; one line per host.
            if !desktopViewsFailureLogged {
                desktopViewsFailureLogged = true
                sessionCatalogLog.notice(
                    "Desktop views read failed: \(LogRedaction.describing(error), privacy: .public)"
                )
            }
            return
        }
        guard isSceneActive, bridge === dashboardTicketBridge, profile == activeProfile,
              let update = Self.desktopViewsUpdate(from: response, cursor: desktopViewsCursor[profile])
        else { return }
        desktopViewsFailureLogged = false
        desktopViewsCursor[profile] = update.cursor
        guard !update.seen.isEmpty else { return }
        updateChatReadState { $0.recordDesktopViews(update.seen, profile: profile) }
        observeChatReadState()
    }

    func resetDesktopViews(host: String?) {
        desktopViewsHost = host
        desktopViewsFetchedAt = [:]
        desktopViewsCursor = [:]
        desktopViewsFailureLogged = false
        updateChatReadState { $0.forgetDesktopViews() }
    }

    /// Parses the plugin's `desktop-views` reply into each chat's
    /// `seen_through` time and the next `since` cursor, or nil when the reply
    /// isn't a successful read.
    nonisolated static func desktopViewsUpdate(
        from response: [String: Any],
        cursor: TimeInterval?
    ) -> (seen: [String: TimeInterval], cursor: TimeInterval)? {
        guard response["ok"] as? Bool == true, let views = response["views"] as? [String: Any] else { return nil }
        var seen: [String: TimeInterval] = [:]
        var next = cursor ?? 0
        for (id, value) in views {
            guard let entry = value as? [String: Any],
                  let time = (entry["seen_through"] as? NSNumber)?.doubleValue, time.isFinite else { continue }
            seen[id] = time
            // A chat still selected reports the moment of this read; only
            // settled times move the "newer than" cursor.
            if entry["open"] as? Bool != true { next = max(next, time) }
        }
        return (seen, next)
    }

    func markSessionRead(_ session: SessionSummary) {
        let profile = rowProfile(session)
        let flagged = chatReadState.serverUnread(session, profile: profile)
        updateChatReadState { $0.markSeen(session, profile: profile) }
        if flagged {
            writeSessionUnreadFlag(session, unread: false, profile: profile)
        }
    }

    func markSessionUnread(_ session: SessionSummary) {
        let profile = rowProfile(session)
        updateChatReadState { $0.markUnread(session, profile: profile) }
        writeSessionUnreadFlag(session, unread: true, profile: profile)
    }

    func markAllSessionsRead() {
        // What All lists: the chats and pinned cron runs (#485), and in the
        // All profiles view the other profiles' chats too.
        let others = isAllProfilesChatsOn ? chatListSessions.filter(isOtherProfileRow) : []
        markSessionsRead(activeProfileSessions + activeProfileCronSessions.filter { isSessionPinned($0) } + others)
    }

    /// Marks a whole nest read at once (#556 follow-up): a parent row's
    /// "Mark as read" clears the aggregate dot it shows — its own unread
    /// and every descendant's.
    func markSessionNestRead(_ sessions: [SessionSummary]) {
        markSessionsRead(sessions)
    }

    /// One mark-seen ledger update for the batch (each server-flagged
    /// session records its own generation), then one request at a time
    /// through the dashboard bridge.
    private func markSessionsRead(_ sessions: [SessionSummary]) {
        // Each row under its own profile: All lists several.
        let unread = sessions.filter { !$0.isArchived && isSessionUnread($0) }
            .map { (session: $0, profile: rowProfile($0)) }
        guard !unread.isEmpty else { return }
        let flagged = unread.filter { chatReadState.serverUnread($0.session, profile: $0.profile) }
        updateChatReadState { state in
            for row in unread { state.markSeen(row.session, profile: row.profile) }
        }
        let writes = flagged.compactMap { preparedUnreadFlagWrite($0.session, unread: false, profile: $0.profile) }
        guard !writes.isEmpty else { return }
        Task {
            for write in writes { await write() }
        }
    }

    /// Applies a change and persists the ledger when it moved. Publishes only
    /// on a real change: listings arrive often and most change nothing here.
    func updateChatReadState(_ change: (inout ChatReadState) -> Void) {
        var next = chatReadState
        change(&next)
        guard next != chatReadState else { return }
        let ledgerChanged = next.ledger != chatReadState.ledger
        chatReadState = next
        if ledgerChanged, let data = try? JSONEncoder().encode(next.ledger) {
            defaults.set(data, forKey: chatReadLedgerKey)
        }
    }

    /// The rows the chat list shows with read state: the chats plus cron
    /// runs, which the Cron filter lists (#485).
    private var readStateSessions: [SessionSummary] {
        activeProfileSessions + activeProfileCronSessions
    }

    func observeChatReadState() {
        let profile = activeProfile
        // The same rows every read-state query sees.
        let listed = readStateSessions
        var seenThrough = Set<String>()
        updateChatReadState { seenThrough = $0.observe(listed, profile: profile) }
        clearHermesFlagsSeenHere(listed.filter { seenThrough.contains(ChatReadState.durableID(for: $0)) }, profile: profile)
        noteActiveChatSeen(respectingMarks: true)
    }

    /// Rows whose latest activity the user saw in the chat before leaving
    /// it: Hermes flags them unread (the activity postdates the watermark
    /// written when the chat opened), so the flag is cleared, as reading the
    /// chat to the end would have. A mark (Mark as Unread, here or on
    /// Desktop) stays.
    private func clearHermesFlagsSeenHere(_ rows: [SessionSummary], profile: String) {
        for session in rows where !session.isArchived
            && chatReadState.serverUnread(session, profile: profile)
            && !chatReadState.isExplicitlyUnread(session, profile: profile)
            && chatReadState.mayRewritePassively(session, profile: profile) {
            writeSessionUnreadFlag(session, unread: false, profile: profile)
        }
    }

    /// The open chat counts as seen while it is actually on screen: the app is
    /// in front and the sessions drawer isn't covering it. Seeing it also
    /// clears Hermes' flag when activity set it. Opening a chat reads it
    /// outright. Anything else (a listing refresh, closing the drawer,
    /// returning to the app) leaves a chat the user, or Desktop, explicitly
    /// marked unread alone, the way Desktop keeps a marked chat unread until
    /// you open it again.
    /// Not while a Bot Chat on its way covers it (`botChatCoversOpenChat`),
    /// whoever asks: a catalog refresh meanwhile reads nothing into it.
    func noteActiveChatSeen(respectingMarks: Bool = false) {
        guard isSceneActive, !showSidebar, !botChatCoversOpenChat,
              let session = readStateSessions.first(where: sessionMatchesActiveSession) else { return }
        let profile = activeProfile
        if respectingMarks {
            if chatReadState.isExplicitlyUnread(session, profile: profile) { return }
            // Catch-up never re-sends a write Hermes hasn't confirmed yet.
            if !chatReadState.mayRewritePassively(session, profile: profile) {
                updateChatReadState { state in
                    state.markSeen(session, profile: profile)
                    if state.serverUnread(session, profile: profile) {
                        state.recordLocalRead(session, profile: profile)
                    }
                }
                return
            }
        }
        markSessionRead(session)
    }

    /// The user was looking at this chat until now (switched to another, or
    /// left the app): what the next listing reports for it, up to this moment,
    /// was seen.
    func noteChatLeft(_ sessionID: String?) {
        guard isSceneActive,
              let sessionID,
              let session = readStateSessions.first(where: { ([$0.id] + $0.alternateIds).contains(sessionID) }),
              !chatReadState.isExplicitlyUnread(session, profile: activeProfile) else { return }
        let profile = activeProfile
        updateChatReadState { $0.markSeen(session, profile: profile, restamp: true) }
    }

    /// Writes Hermes' shared read flag, which Desktop shows and clears too.
    /// Best-effort: a gateway without the flag (or a failed request) leaves
    /// Conduit's own read state working on its own.
    private func writeSessionUnreadFlag(_ session: SessionSummary, unread: Bool, profile: String) {
        guard let write = preparedUnreadFlagWrite(session, unread: unread, profile: profile) else { return }
        Task { await write() }
    }

    /// Records the write as pending now and returns the request to send.
    private func preparedUnreadFlagWrite(
        _ session: SessionSummary,
        unread: Bool,
        profile: String
    ) -> (@MainActor () async -> Void)? {
        guard let dashboardTicketBridge else { return nil }
        var generation: UInt64 = 0
        updateChatReadState { generation = $0.recordServerWrite(session, profile: profile, unread: unread) }
        let writtenGeneration = generation
        return { [weak self] in
            do {
                guard let self else { return }
                try await self.sendSessionMutation(
                    session.id,
                    body: ["unread": unread],
                    profile: profile,
                    bridge: dashboardTicketBridge
                )
            } catch {
                self?.updateChatReadState {
                    $0.discardServerWrite(session, profile: profile, generation: writtenGeneration)
                }
            }
        }
    }
}
