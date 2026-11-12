//
//  AppState+OpenChat.swift
//  Conduit
//
//  Opening a chat: a widget's or a bot's Bot Chat, a room's chat, a saved
//  session, a notification's target, and the profile a conversation
//  belongs to. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Opening chats

    func openWidgetConversation(
        _ reference: WidgetConversationReference,
        workspace: WidgetWorkspaceID,
        lease: WidgetLaunchLease
    ) async -> WidgetLaunchOutcome {
        guard lease.isCurrent, activeDashboardID == workspace.dashboardID,
              activeProfile == workspace.profile, let client, isConnected else { return .deferred }
        if reference.kind == .dashboard {
            guard reference.scopeProfile == workspace.profile,
                  activeProfileSessions.contains(where: { $0.id == reference.sessionID
                    || $0.alternateIds.contains(reference.sessionID)
                    || $0.storedSessionId == reference.sessionID }) else {
                return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
            }
            let transition = beginExplicitChatViewportTransition(ownedBy: lease)
            guard lease.isCurrent else {
                finishChatViewportTransition(generation: transition)
                return .deferred
            }
            let outcome = await performSessionOpen(
                reference.sessionID,
                reusing: transition,
                widgetLease: lease
            )
            guard lease.isCurrent else {
                finishChatViewportTransition(generation: transition)
                return .deferred
            }
            if outcome != .opened { finishChatViewportTransition(generation: transition) }
            return outcome == .opened ? .handled : .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
        }

        // A kept bot opens as its Bots list row does: Hermes' lookup below
        // confirms the chat.
        guard let botName = reference.botName,
              botName == reference.scopeProfile,
              let bot = shownBotRoster.first(where: { $0.name == botName && !$0.isHiddenByMeta }) else {
            return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
        }
        do {
            let rows: [BotChatLookupRow]
            if let lookup = chatResumeLifecycleOperations.findBotChat {
                rows = try await lookup(client, bot.name)
            } else {
                rows = try await client.findBotChatSession(profile: bot.name)
            }
            guard lease.isCurrent, self.client === client else { return .deferred }
            guard case .success(.openExisting(let registryID, let resumeID)) = BotChatResolver.resolve(
                rows: rows,
                rosterCanonicalID: bot.canonicalSessionID
            ), registryID == reference.sessionID || resumeID == reference.sessionID else {
                return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
            }
            let transition = beginExplicitChatViewportTransition(ownedBy: lease)
            guard lease.isCurrent else {
                finishChatViewportTransition(generation: transition)
                return .deferred
            }
            noteBotChatOpen([resumeID, registryID], bot: bot)
            let outcome = await performSessionOpen(
                resumeID,
                reusing: transition,
                conversationProfile: bot.name,
                preferredTitle: bot.displayLabel,
                widgetLease: lease
            )
            guard lease.isCurrent else {
                finishChatViewportTransition(generation: transition)
                return .deferred
            }
            if outcome != .opened { finishChatViewportTransition(generation: transition) }
            return outcome == .opened ? .handled : .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
        } catch {
            return lease.isCurrent
                ? .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
                : .deferred
        }
    }

    func openWidgetVoice(workspace: WidgetWorkspaceID, lease: WidgetLaunchLease) async -> WidgetLaunchOutcome {
        guard lease.isCurrent,
              activeDashboardID == workspace.dashboardID,
              activeProfile == workspace.profile else { return .deferred }
        guard !isVoiceCallInProgress else {
            return .failed(AppLocalization.string("End the call before starting another voice conversation."))
        }
        let authorization = lease.initialCaptureAuthorization()
        let intent = PendingVoiceIntent(profile: workspace.profile, startsFreshConversation: true, source: .newCall)
        let opened = await openVoiceConversation(intent, widgetLease: lease, initialCaptureAuthorization: authorization)
        guard lease.isCurrent || authorization.mayStartCapture else { return .deferred }
        return opened ? .handled : .deferred
    }

    /// Opens a bot's canonical Bot Chat: consult the name-identity registry,
    /// open the confirmed chat (lineage tip), or — only once absence is
    /// CONFIRMED — create the one hidden "Bot Chat". Fail-closed throughout:
    /// a failed or unconfirmable lookup NEVER mints a chat, because that is
    /// the one remaining way to fork a bot's forever chat. Concurrent opens
    /// of the same bot share one flight. `presentationMigrationSessionIDs`
    /// are the ids a notification recorded its decision card under; the
    /// open (existing, created or adopted chat) promotes that card into the
    /// chat (a flight already running for the bot keeps its own).
    /// `viewportTransitionGeneration` is the transition a notification open
    /// already began: the chat open reuses it, so a newer tap that began its
    /// own supersedes this open before it selects the chat.
    @discardableResult
    func openBotChat(
        for bot: BotProfile,
        presentationMigrationSessionIDs: Set<String> = [],
        viewportTransitionGeneration: UInt64? = nil
    ) async -> Bool {
        await openBotChatOutcome(
            for: bot,
            presentationMigrationSessionIDs: presentationMigrationSessionIDs,
            viewportTransitionGeneration: viewportTransitionGeneration
        ) == .opened
    }

    /// How a Bot Chat's open ended: `.failed` only when it didn't open and
    /// nothing newer took over, so the chat on screen is still the one open
    /// before this open began.
    enum BotChatOpenOutcome: Equatable {
        case opened, superseded, failed
    }

    /// `openBotChat`, saying whether a failed open was superseded. An open
    /// that brings no navigation of its own (a tap, a link, a new bot)
    /// begins one before Hermes' lookup, not after it: a newer tap then
    /// supersedes this open even while its lookup is out, so the bot tapped
    /// last is the one that opens, never the one whose lookup came back last.
    func openBotChatOutcome(
        for bot: BotProfile,
        presentationMigrationSessionIDs: Set<String> = [],
        viewportTransitionGeneration: UInt64? = nil
    ) async -> BotChatOpenOutcome {
        guard let client, isConnected else {
            errorMessage = AppLocalization.string("Connect to Hermes to chat with bots.")
            return .failed
        }
        let flightKey = bot.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A flight whose navigation a newer one took over will stand down:
        // a tap on its bot now opens on its own.
        if let flight = botChatOpenFlights[flightKey],
           viewportTransitionGeneration != nil || chatViewportTransitionIsCurrent(flight.transition) {
            let joined = await flight.task?.value ?? false
            // A notification that joined a flight its own newer transition
            // superseded would otherwise inherit that stand-down and do
            // nothing. While its transition is still current, it opens the
            // chat itself; the finished flight has left the map, so the
            // one-flight-per-bot fence still holds.
            guard !joined,
                  let viewportTransitionGeneration,
                  chatViewportTransitionIsCurrent(generation: viewportTransitionGeneration),
                  isConnected, client === self.client,
                  botChatOpenFlights[flightKey] == nil else {
                // A tap that joined: its chat opened, but a newer navigation
                // since then owns the screen, so the tap doesn't act on it.
                if joined {
                    return chatViewportTransitionIsCurrent(viewportTransitionGeneration ?? flight.transition)
                        ? .opened : .superseded
                }
                return chatViewportTransitionIsCurrent(flight.transition) ? .failed : .superseded
            }
        }
        let beganTransition = viewportTransitionGeneration == nil
        let epoch = botRosterEpoch
        let transition = viewportTransitionGeneration ?? beginExplicitChatViewportTransition()
        if beganTransition {
            botChatOnItsWay = BotChatOnItsWay(bot: bot.name, label: bot.displayLabel, transition: transition)
        }
        // The closure captures the box WEAKLY: a strong capture would form
        // a flight<->task retain cycle that outlives the map entry.
        let flight = BotChatOpenFlight()
        flight.transition = transition
        let task = Task { @MainActor [weak self, weak flight] () -> Bool in
            // `flight` is retained strongly by the creating scope across
            // `await task.value`, so the weak capture only breaks the
            // box<->task cycle — it can never fire nil here.
            guard let self, let flight else { return false }
            // Identity-checked cleanup: a flight orphaned by a server switch
            // (map cleared, then a newer flight for the same bot) must never
            // evict that newer flight's entry.
            defer {
                if self.botChatOpenFlights[flightKey] === flight {
                    self.botChatOpenFlights.removeValue(forKey: flightKey)
                }
            }
            return await self.resolveAndOpenBotChat(
                bot,
                client: client,
                presentationMigrationSessionIDs: presentationMigrationSessionIDs,
                viewportTransitionGeneration: transition
            )
        }
        flight.task = task
        botChatOpenFlights[flightKey] = flight
        let opened = await task.value
        if botChatOnItsWay?.transition == transition { botChatOnItsWay = nil }
        // As a tap that joined: a navigation newer than this open, in the hop
        // back from its task, owns the screen, so the caller doesn't act on it
        // (Pulse's Do it would leave its words in that other chat).
        if opened { return chatViewportTransitionIsCurrent(generation: transition) ? .opened : .superseded }
        guard chatViewportTransitionIsCurrent(generation: transition) else { return .superseded }
        // Nothing replaced the chat on screen: its viewport goes on as it was.
        if beganTransition { finishChatViewportTransition(generation: transition) }
        // A server switch cancelled it: what it says is the outgoing
        // server's, never the next one's (issue 2085).
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return .superseded }
        return .failed
    }

    /// Opens `bot`'s Bot Chat for a list of bots (a Bots Home portrait or
    /// its overview's Chat, a Bots list row, a new bot, Bots Home's voice
    /// menu), which marked it with `beginOpeningBotChat` first; ends the
    /// mark. The shell pushed the chat's screen as the list closed, over the
    /// chat open before: an open that fails, while still the latest
    /// navigation, goes back to the list rather than leave another chat
    /// under this bot's tap. True when it opened.
    @discardableResult
    func openBotChatFromList(_ bot: BotProfile) async -> Bool {
        let writes = errorMessageWrites
        let epoch = botRosterEpoch
        let outcome = await openBotChatOutcome(for: bot)
        // A server switch retired the list's marks with the rest of Bot
        // Mode's state: this open has no mark left to end, and a tap on the
        // next server's list may have made one under the same name.
        guard epoch == botRosterEpoch else { return outcome == .opened }
        let pushed = botChatMarks[bot.name]?.pushed ?? false
        // The list shows (it went back, or it never closed): the error
        // shows with a chat's composer, which isn't there, so the list
        // says it instead.
        if outcome == .failed, pushed || showSidebar {
            showSidebar = true
            // This open's own error, even when it reads like the one
            // already showing (a retry that failed the same way).
            if let error = errorMessage, errorMessageWrites != writes {
                botsListNotice = error
                errorMessage = nil
            } else {
                botsListNotice = AppLocalization.string("Could not open \(bot.displayLabel)'s Bot Chat.")
            }
        }
        endOpeningBotChat(bot.name)
        return outcome == .opened
    }

    /// A bot open spans several awaited RPCs. Every step re-validates that
    /// the server identity this flight captured is still current; a server
    /// switch mid-flight (invalidation cancels the task AND bumps the epoch)
    /// abandons the flight silently — the user has moved on.
    func botOpenFenceIsCurrent(epoch: Int, client: HermesClient) -> Bool {
        epoch == botRosterEpoch && client === self.client
    }

    private func resolveAndOpenBotChat(
        _ bot: BotProfile,
        client: HermesClient,
        presentationMigrationSessionIDs: Set<String> = [],
        viewportTransitionGeneration: UInt64? = nil
    ) async -> Bool {
        let epoch = botRosterEpoch
        // THE identity lookup, on the bot's own profile. A failed RPC is not
        // "no Bot Chat exists" — it is "unknown", and unknown means retry.
        let rows: [BotChatLookupRow]
        do {
            if let findBotChat = chatResumeLifecycleOperations.findBotChat {
                rows = try await findBotChat(client, bot.name)
            } else {
                rows = try await client.findBotChatSession(profile: bot.name)
            }
        } catch {
            guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return false }
            return failBotChatOpen(bot, error: error, stage: .lookup, transition: viewportTransitionGeneration)
        }
        // A newer navigation took over while the lookup was out (another
        // bot tapped): this open says nothing and makes nothing.
        guard botOpenFenceIsCurrent(epoch: epoch, client: client),
              chatViewportTransitionIsCurrent(viewportTransitionGeneration) else { return false }
        switch BotChatResolver.resolve(rows: rows, rosterCanonicalID: bot.canonicalSessionID) {
        case .failure(.unconfirmedAbsence):
            refuseBotChatConfirmation(bot, transition: viewportTransitionGeneration)
            return false
        case .success(.openExisting(let registryID, let resumeID)):
            return await openCanonicalBotChat(
                bot,
                registryID: registryID,
                resumeID: resumeID,
                epoch: epoch,
                client: client,
                presentationMigrationSessionIDs: presentationMigrationSessionIDs,
                viewportTransitionGeneration: viewportTransitionGeneration
            )
        case .success(.create):
            return await createAndOpenBotChat(
                bot,
                client: client,
                epoch: epoch,
                presentationMigrationSessionIDs: presentationMigrationSessionIDs,
                viewportTransitionGeneration: viewportTransitionGeneration
            )
        }
    }

    /// Opens an existing canonical chat through the ordinary session
    /// machinery: `requestOpenSession`'s full path (identity capture,
    /// admission gate, hydration, reconcile). The resume rides the bot's
    /// profile scope; nothing bot-specific runs beside it.
    private func openCanonicalBotChat(
        _ bot: BotProfile,
        registryID: String,
        resumeID: String,
        epoch: Int,
        client: HermesClient,
        presentationMigrationSessionIDs: Set<String> = [],
        viewportTransitionGeneration: UInt64? = nil
    ) async -> Bool {
        let writes = errorMessageWrites
        noteBotChatOpen([resumeID, registryID], bot: bot)
        let outcome = await performSessionOpen(
            resumeID,
            reusing: viewportTransitionGeneration,
            presentationMigrationSessionIDs: presentationMigrationSessionIDs,
            conversationProfile: bot.name,
            preferredTitle: bot.displayLabel
        )
        // Only a GENUINE failure owned by this invocation may publish: a
        // superseded open (the user navigated elsewhere, or re-tapped this
        // same bot so a newer open owns the viewport) is navigation state,
        // not an error.
        if outcome == .failed, !Task.isCancelled,
           botOpenFenceIsCurrent(epoch: epoch, client: client),
           // The open's own failure says more, even when its text matches
           // the error already showing (a retry that failed the same way);
           // an error from before it doesn't.
           errorMessage == nil || errorMessageWrites == writes {
            errorMessage = AppLocalization.string(
                "Could not open \(bot.displayLabel)'s Bot Chat."
            )
        }
        return outcome == .opened
    }

    /// A room's new chat (RoomChats.swift), in `profile` (nil for the
    /// dashboard's).
    func createRoomChatSession(
        using client: HermesClient,
        profile: String?
    ) async throws -> ChatResumeLifecycleOperations.BranchResult {
        if let createRoomChat = chatResumeLifecycleOperations.createRoomChat {
            return try await createRoomChat(client, profile)
        }
        return try await client.createSession(inProfile: profile)
    }

    /// A room's new chat titled, by the id it runs under.
    func titleRoomChatSession(_ runtimeID: String, title: String, using client: HermesClient,
                              profile: String?) async throws {
        if let titleRoomChat = chatResumeLifecycleOperations.titleRoomChat {
            try await titleRoomChat(client, runtimeID, title, profile)
        } else {
            try await client.setSessionTitle(runtimeID, title: title, profile: profile)
        }
    }

    /// Opens a room's chat (RoomChats.swift) as an ordinary chat of
    /// `profile`: here, or in another profile than the dashboard's through
    /// a chat link's route, which switches to it first, as All's other
    /// profiles' chats open. Never as a Bot Chat, whose registry would
    /// route its pushes to the bot's own chat and hide it from its
    /// profile's list. A chat Hermes refused (gone, or another one) reads
    /// gone, and the restore error the refusal left is put back: the
    /// opener replaces the chat.
    func openRoomChatSession(_ chatID: String, profile: String, title: String) async -> RoomChatOpenOutcome {
        let shownError = errorMessage
        guard !profilesMatch(profile, activeProfile) else {
            let result = await performSessionOpenNotingRefusal(
                chatID,
                reusing: nil,
                preferredTitle: title
            )
            switch result.outcome {
            case .opened: return .opened
            case .superseded: return .superseded
            case .failed:
                guard result.refused else { return .failed }
                errorMessage = shownError
                return .gone
            }
        }
        let outcome = await openNotificationTargetOutcome(
            ConduitNotificationTarget(
                profile: profile, sessionId: chatID, dashboardID: activeDashboardID, type: nil, isChatLink: true
            )
        )
        switch outcome {
        case .opened: return .opened
        case .failed:
            // Gone only once the route reached the chat's profile and Hermes refused it there: a dashboard
            // that couldn't be reached, or a call that started meanwhile, is no answer about the chat.
            guard !isVoiceCallInProgress, profilesMatch(profile, activeProfile) else { return .failed }
            errorMessage = shownError
            return .gone
        case .retry, .unverified, .afterCall: return .failed
        }
    }

    /// Creates the bot's ONE forever chat (lookup confirmed absence): hidden,
    /// titled "Bot Chat", following the profile's current config. The eager
    /// `session.title` write materializes the lazy row BEFORE any open, so a
    /// second click can never mint a duplicate while the first is in flight.
    /// A title-uniqueness rejection — at the title write, or at `session.create`
    /// itself on gateways that enforce the canonical name at create time —
    /// means another writer won the canonical title in between:
    /// adopt-before-mint. Re-run the authoritative lookup and open the
    /// winner instead of forking. The in-memory registry is only seeded
    /// AFTER the canonical title has landed, so an abandoned lazy session
    /// never leaves a stale entry behind.
    private func createAndOpenBotChat(
        _ bot: BotProfile,
        client: HermesClient,
        epoch: Int,
        presentationMigrationSessionIDs: Set<String> = [],
        viewportTransitionGeneration: UInt64? = nil
    ) async -> Bool {
        let created: (sessionId: String, storedSessionId: String?)
        do {
            if let createBotChat = chatResumeLifecycleOperations.createBotChat {
                created = try await createBotChat(client, bot.name)
            } else {
                created = try await client.createBotChatSession(profile: bot.name)
            }
        } catch {
            if BotChatTitleCollision.isError(error) {
                return await adoptWinningBotChat(
                    bot,
                    client: client,
                    epoch: epoch,
                    presentationMigrationSessionIDs: presentationMigrationSessionIDs,
                    viewportTransitionGeneration: viewportTransitionGeneration
                )
            }
            guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return false }
            return failBotChatOpen(bot, error: error, stage: .create, transition: viewportTransitionGeneration)
        }
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return false }
        do {
            if let titleBotChat = chatResumeLifecycleOperations.titleBotChat {
                try await titleBotChat(client, created.sessionId, BotMode.canonicalChatTitle, bot.name)
            } else {
                try await client.setSessionTitle(
                    created.sessionId,
                    title: BotMode.canonicalChatTitle,
                    profile: bot.name
                )
            }
        } catch {
            if BotChatTitleCollision.isError(error) {
                return await adoptWinningBotChat(
                    bot,
                    client: client,
                    epoch: epoch,
                    presentationMigrationSessionIDs: presentationMigrationSessionIDs,
                    viewportTransitionGeneration: viewportTransitionGeneration
                )
            }
            guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return false }
            return failBotChatOpen(bot, error: error, stage: .title, transition: viewportTransitionGeneration)
        }
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return false }
        noteBotChatOpen([created.sessionId], bot: bot)
        // The open resumes the STORED id, as Desktop's does: Hermes finds a
        // chat by its stored key (the live session it just made, or the row
        // the title wrote) and answers 4007 for a runtime id. Opening the
        // runtime id failed the open, so a new bot's first message went to
        // a chat Conduit never had open, and it was gone on the way back.
        // A create that named no stored id is found by its title instead,
        // which just landed: the lookup gives the row to open.
        guard let storedID = created.storedSessionId else {
            return await adoptWinningBotChat(
                bot,
                client: client,
                epoch: epoch,
                presentationMigrationSessionIDs: presentationMigrationSessionIDs,
                viewportTransitionGeneration: viewportTransitionGeneration
            )
        }
        return await openCanonicalBotChat(
            bot,
            registryID: storedID,
            resumeID: storedID,
            epoch: epoch,
            client: client,
            presentationMigrationSessionIDs: presentationMigrationSessionIDs,
            viewportTransitionGeneration: viewportTransitionGeneration
        )
    }

    /// The canonical title was taken by another writer between our registry
    /// miss and the eager title. Re-consult the registry; adopt the winner.
    /// Our abandoned lazy session holds zero messages and the gateway prunes
    /// it. If the winner cannot be confirmed, fail closed — never open our
    /// untitled stray, never mint again. A create that named no stored id
    /// comes here too, after its own title landed: the winner is our chat.
    private func adoptWinningBotChat(
        _ bot: BotProfile,
        client: HermesClient,
        epoch: Int,
        presentationMigrationSessionIDs: Set<String> = [],
        viewportTransitionGeneration: UInt64? = nil
    ) async -> Bool {
        let rows: [BotChatLookupRow]
        do {
            if let findBotChat = chatResumeLifecycleOperations.findBotChat {
                rows = try await findBotChat(client, bot.name)
            } else {
                rows = try await client.findBotChatSession(profile: bot.name)
            }
        } catch {
            // A cancelled or server-switched flight abandons silently, like
            // every other stage; only a current flight speaks.
            guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return false }
            refuseBotChatConfirmation(bot, transition: viewportTransitionGeneration)
            return false
        }
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return false }
        if case .success(.openExisting(let registryID, let resumeID)) =
            BotChatResolver.resolve(rows: rows, rosterCanonicalID: bot.canonicalSessionID) {
            return await openCanonicalBotChat(
                bot,
                registryID: registryID,
                resumeID: resumeID,
                epoch: epoch,
                client: client,
                presentationMigrationSessionIDs: presentationMigrationSessionIDs,
                viewportTransitionGeneration: viewportTransitionGeneration
            )
        }
        refuseBotChatConfirmation(bot, transition: viewportTransitionGeneration)
        return false
    }

    private enum BotChatOpenStage {
        case lookup
        case create
        case title
    }

    /// Publishes a failed open's reason, unless a newer navigation took
    /// over from `transition` (another bot tapped): that one owns the
    /// screen, and this open says nothing over it.
    private func failBotChatOpen(
        _ bot: BotProfile,
        error: Error,
        stage: BotChatOpenStage,
        transition: UInt64?
    ) -> Bool {
        if HermesClient.isMissingRPCMethod(error) {
            // True of the gateway whoever owns the screen.
            botModePhase = .gatewayUnsupported
            guard chatViewportTransitionIsCurrent(transition) else { return false }
            errorMessage = AppLocalization.string("Update Hermes to use Bot Mode.")
        } else if !Task.isCancelled, chatViewportTransitionIsCurrent(transition) {
            switch stage {
            case .lookup:
                errorMessage = AppLocalization.string(
                    "Could not check \(bot.displayLabel)'s Bot Chat — not starting a new chat."
                )
            case .create:
                errorMessage = AppLocalization.string(
                    "Could not create \(bot.displayLabel)'s Bot Chat."
                )
            case .title:
                errorMessage = AppLocalization.string(
                    "Could not title \(bot.displayLabel)'s Bot Chat — not starting a new chat."
                )
            }
        }
        return false
    }

    private func refuseBotChatConfirmation(_ bot: BotProfile, transition: UInt64?) {
        guard chatViewportTransitionIsCurrent(transition) else { return }
        errorMessage = AppLocalization.string(
            "Could not confirm \(bot.displayLabel)'s Bot Chat — not starting a new chat."
        )
    }

    /// A rename names the profile's open Bot Chats too: the label each
    /// captured when it opened is the old name. An empty name lets the
    /// roster's label name them again.
    func renameCapturedBotChatLabels(for profile: String, to name: String) {
        guard let scope = ChatResumeStore.rpcProfileName(profile) else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for (sessionID, owner) in botChatSessionProfiles where owner == scope {
            botChatSessionLabels[sessionID] = label.isEmpty ? nil : label
        }
        // The saved selection carries the label for a cold launch too.
        if let saved = chatResumeCoordinator.lastSession(for: activeProfile), saved.kind == .bot,
           let botName = saved.botName, ChatResumeStore.rpcProfileName(botName) == scope {
            chatResumeCoordinator.rememberSession(
                .bot(botName: botName, label: label.isEmpty ? nil : label, sessionID: saved.sessionID),
                for: activeProfile
            )
        }
        if let open = activeBotChatProfile, ChatResumeStore.rpcProfileName(open) == scope {
            activeSessionTitle = label.isEmpty ? profileDisplayName(profile) : label
        }
    }

    func noteBotChatSession(
        _ sessionID: String?,
        profile: String,
        label: String? = nil
    ) {
        // The KEY is normalized exactly like every lookup that reads this map
        // (`botScopeProfile` normalizes its query ids), so a padded id cannot
        // register an entry the fast path will never find.
        guard let sessionID = ChatScrollIdentityNormalization.sessionID(sessionID),
              let scope = ChatResumeStore.rpcProfileName(profile) else { return }
        botChatSessionProfiles[sessionID] = scope
        invalidateBotOwnershipCache()
        // A label that is only the profile id is no label: the roster's
        // displayLabel names the bot instead.
        // The main bot's label follows its Conduit name (the roster's), so
        // one saved before a rename isn't kept.
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
           label != profile.trimmingCharacters(in: .whitespacesAndNewlines), !BotManagement.isDefaultProfile(profile) {
            botChatSessionLabels[sessionID] = label
        }
    }

    #if DEBUG
    func noteBotChatSessionForTesting(_ sessionID: String, profile: String) {
        noteBotChatSession(sessionID, profile: profile)
    }

    /// The bot profile a conversation is scoped to, or nil for an ordinary
    /// conversation. Test-only read of the in-memory registry, so a test can
    /// pin WHICH scope a restored conversation would address.
    func botConversationProfileForTesting(_ sessionID: String) -> String? {
        botConversationProfile(for: sessionID)
    }

    func persistedTailProfileForTesting(_ sessionID: String) -> String {
        persistedTailProfile(for: sessionID)
    }

    /// The ids a chat's voice call cards and Resume Call match it by.
    func chatOwnSessionIDsForTesting(_ sessionID: String) -> Set<String> {
        chatOwnSessionIDs(for: sessionID)
    }

    /// The saved review rows a chat shows when its history loads.
    func cachedReviewRowsForTesting(_ sessionID: String) -> [ChatMessage] {
        mergeCachedReviews(into: [], sessionId: sessionID)
    }

    /// The ownership verdict a cross-profile decision would reach for this
    /// profile, so tests can pin all three cases without driving a switch.
    func profileOwnershipVerdictForTesting(_ profile: String) -> ProfileOwnershipVerdict {
        profileOwnershipVerdict(for: profile)
    }

    func adoptActiveSessionForWidgetTesting(_ sessionID: String) {
        setActiveSessionState(id: sessionID)
    }

    /// Whether the ownership match for a name was spelled exactly, so a test can
    /// pin the diagnostic copy's input without driving a routed push.
    func botProfileMatchForTesting(_ profile: String) -> (name: String, isExact: Bool)? {
        botOwnership.botProfileMatch(for: profile)
    }

    /// Simulates the next connection boundary for evidence freshness: the roster
    /// on hand becomes unverified (as it does at every connect/reconnect)
    /// without clearing it, so a test can pin that absence stops being evidence.
    func unverifyBotRosterForCurrentConnectionForTesting() {
        botRosterVerifiedForCurrentConnection = false
    }

    /// Drops the in-memory bot-chat registry AND its captured labels — the
    /// two pieces `invalidateBotModeState` clears — while leaving the durable
    /// reference in place, so a test can pin that the reference alone still
    /// resolves the conversation's scope. The roster is deliberately left
    /// alone: tests that need the server-identity boundary drive
    /// `prepareChatResumeForConnection`, which also clears the resume store.
    func clearBotChatRegistryForTesting() {
        botChatSessionProfiles.removeAll()
        botChatSessionLabels.removeAll()
        invalidateBotOwnershipCache()
    }
    #endif

    /// The bot whose chat is open, if the open conversation is a Bot Chat:
    /// the same evidence the resume's scope reads (`botScopeProfile`: this
    /// run's registry, the roster, the saved last-chat reference). The
    /// registry alone is empty after a relaunch or a server boundary until
    /// the resume lands, so a Bot Chat back from the background read as the
    /// workspace's chat for that second: its title the bot's, its composer
    /// and reply headers the workspace profile's (issue 2025).
    var activeBotChatProfile: String? {
        guard let activeSessionId else { return nil }
        return botScopeProfile(forSessionIDs: [activeSessionId], workspaceProfile: activeProfile)
    }

    /// The profile the open conversation's agent identity draws from: the
    /// owning bot's profile inside a Bot Chat, else the active workspace
    /// profile. The working line's glow tint follows this, so a Bot Chat
    /// breathes in the bot's color, not the workspace's.
    var conversationIdentityProfile: String {
        activeBotChatProfile ?? activeProfile
    }

    /// The agent identity the open conversation presents — the owning bot
    /// inside a Bot Chat (its label, picture and Desktop color), else the
    /// active workspace profile's name and photo. Everything drawn over
    /// the open conversation's replies — the settled and streaming headers,
    /// the working line, the composer's placeholder, the reaction chips —
    /// renders THIS, so a Bot Chat never presents the workspace's (the
    /// default profile's) name and picture instead of the bot the user is
    /// talking to.
    var conversationAgentIdentity: ConversationAgentIdentity {
        guard let botProfile = activeBotChatProfile else {
            return ConversationAgentIdentity.workspace(
                name: profileDisplayName(activeProfile),
                photoURL: profileAvatarURL(for: activeProfile)
            )
        }
        // linkedBot, not a bare name match: a bot renamed on the desktop
        // carries its old name in previousNames and must keep its picture
        // and color in an already-open chat.
        // The kept bots until Hermes answers, so a kept row's chat opens
        // with its face (#1533).
        let bot = Self.linkedBot(named: botProfile, in: shownBotRoster)
        return ConversationAgentIdentity(
            name: botChatDisplayLabel(profile: botProfile, rosterBot: bot),
            photoURL: nil,
            botFace: bot.map { bot in
                // Trimmed and emptied-to-nil so the equality key is
                // canonical: a gateway flipping between `""`, `" "` and
                // absence must not re-open settled rows over nothing.
                let raw = bot.appearanceColor?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ConversationAgentIdentity.BotFace(
                    name: bot.name,
                    colorString: raw?.isEmpty == true ? nil : raw,
                    image: botAvatarImage(for: bot)
                )
            }
        )
    }

    /// The name a Bot Chat presents for its owning bot: the label captured
    /// when the conversation was opened — the same string the nav title
    /// pinned, and the same captured-label-wins authority
    /// `sessionReference(forPersistedID:)` documents, so a roster refresh
    /// never renames the reply headers nor the title — else the roster's
    /// CURRENT label, else the capitalized profile name, like the rest of
    /// the chat surface.
    private func botChatDisplayLabel(profile: String, rosterBot: BotProfile?) -> String {
        let captured = activeSessionId
            .flatMap(ChatScrollIdentityNormalization.sessionID)
            .flatMap {
                botChatSessionLabels[$0]?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .flatMap { $0.isEmpty ? nil : $0 }
        return captured
            ?? savedBotChatLabel(profile: profile)
            ?? rosterBot?.displayLabel
            ?? profileDisplayName(profile)
    }

    /// The name the saved last-chat reference gives the open Bot Chat: the
    /// title's own (`botConversationTitle`, so a label that is only the
    /// profile id, or none, is the id capitalized), which the title shows
    /// after a relaunch before the resume captures a label again (issue
    /// 2025: the composer named another bot meanwhile). The main bot's
    /// follows its Conduit name, as `noteBotChatSession` keeps.
    private func savedBotChatLabel(profile: String) -> String? {
        guard !BotManagement.isDefaultProfile(profile),
              let saved = chatResumeCoordinator.lastSession(for: activeProfile),
              saved.kind == .bot,
              let open = ChatScrollIdentityNormalization.sessionID(activeSessionId),
              ChatScrollIdentityNormalization.sessionID(saved.sessionID) == open else { return nil }
        return Self.botConversationTitle(for: saved)
    }

    #if DEBUG
    /// Test seam for the avatar cache the roster's pictures load into.
    func setBotAvatarImageForTesting(_ image: UIImage?, for bot: BotProfile) {
        botAvatarImages[bot.name] = image
    }
    #endif

    /// The bot profile an in-flight or active conversation belongs to, when
    /// that conversation is a canonical Bot Chat. Nil for ordinary sessions —
    /// the ordinary dashboard scope applies.
    func botConversationProfile(for sessionID: String) -> String? {
        // Normalized like the KEYS `noteBotChatSession` writes and like
        // `botScopeProfile`'s fast path: a padded id must not resolve in one
        // place and miss in the other, which would classify a Bot Chat as an
        // ordinary conversation and write the dashboard's title cache.
        guard let normalized = ChatScrollIdentityNormalization.sessionID(sessionID) else {
            return nil
        }
        return botChatSessionProfiles[normalized]
    }

    /// The store a conversation's persisted rows are read from: a Bot
    /// Chat's bot profile, resolved exactly like the resume's scope
    /// (`botScopeProfile`), else the workspace. The registry alone is empty
    /// after a relaunch or a server boundary; the read then asked the
    /// workspace's store, got 404, took it for a Hermes without the history
    /// route and resumed with the whole transcript, which on a long Bot
    /// Chat outgrew the socket and dropped the connection after every send.
    func persistedTailProfile(for sessionID: String) -> String {
        botScopeProfile(forSessionIDs: [sessionID], workspaceProfile: activeProfile) ?? activeProfile
    }

    /// The bot whose store keeps a conversation (`botScopeProfile`), nil
    /// for the workspace's own chats: a Bot Chat's files are listed from
    /// there.
    func botStoreProfile(forSessionIDs sessionIDs: [String]) -> String? {
        botScopeProfile(forSessionIDs: Set(sessionIDs), workspaceProfile: activeProfile)
    }

    /// The presentation-cache namespace for a conversation. Canonical Bot
    /// Chats are partitioned under their OWN profile so presentation rows
    /// and pending decision cards survive dashboard-profile switches and
    /// reconcile under the same key they were written with; ordinary
    /// conversations resolve to the dashboard profile exactly as before.
    func presentationProfile(for sessionID: String?) -> String {
        guard let sessionID else { return activeProfile }
        // Same authority chain as the resume scope: a restored Bot Chat must
        // reconcile its presentation under the bot's namespace even when this
        // process never opened it (relaunch) and the roster has not answered.
        // The active conversation contributes its aliases only for ITSELF —
        // another conversation's ids must never inherit that namespace.
        // The addressed id ONLY: the scroll identity's aliases can include the
        // conversation this one replaced, and a foreign bot id must never
        // namespace an ordinary conversation's presentation.
        return botScopeProfile(forSessionIDs: [sessionID]) ?? activeProfile
    }

    @discardableResult
    func openSession(_ sessionId: String) async -> Bool {
        await openSessionOutcome(sessionId) == .opened
    }

    /// `openSession` with its outcome, for a caller that must tell a
    /// superseded open (navigation, never a failure) from a failed one.
    func openSessionOutcome(_ sessionId: String) async -> SessionOpenOutcome {
        await performSessionOpen(sessionId, reusing: nil)
    }

    /// `onFailure` runs when the open failed (not when a newer navigation
    /// superseded it), told whether this open's own reconcile heard the
    /// resume's not found (4007) for a chat that isn't a Kanban worker.
    @discardableResult
    func requestOpenSession(_ sessionId: String, onFailure: (@MainActor (_ sessionWasNotFound: Bool) -> Void)? = nil) -> Task<Bool, Never> {
        // Tapping the chat already open and settled reads it, and nothing
        // else: it shows Hermes' rows as they stand, streamed in live, so a
        // second open would only read them again and drop rows Load earlier
        // brought in (issue 1825). The scroll stays where it is, as a
        // re-tap of the same chat always left it.
        if openChatIsSettled(as: sessionId) {
            cancelExplicitSessionOpen()
            widgetLaunchCoordinator.supersede()
            noteActiveChatSeen()
            return Task { true }
        }
        cancelExplicitSessionOpen()
        let requestID = UUID()
        explicitSessionOpenRequestID = requestID
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            let open = await self.performSessionOpenNotingRefusal(sessionId, reusing: nil)
            let outcome = open.outcome
            if outcome == .failed, !Task.isCancelled { onFailure?(open.sessionWasNotFound) }
            let opened = outcome == .opened
            // Tapping a chat reads it, even when it was already the open one
            // (the id didn't change, so activeSessionId's didSet stayed quiet).
            if opened { self.noteActiveChatSeen() }
            guard self.explicitSessionOpenRequestID == requestID else { return opened }
            self.explicitSessionOpenRequestID = nil
            self.explicitSessionOpenTask = nil
            return opened
        }
        explicitSessionOpenTask = task
        return task
    }

    /// The chat on screen is `sessionId`'s (the same id, or one its Chats
    /// row lists beside the open one), connected, with its own rows up and
    /// nothing under way: no open, reconcile, restoration or room, no turn.
    /// A viewport transition still waiting for the chat's layout finishes on
    /// its own, as it would have under the open the tap no longer starts.
    func openChatIsSettled(as sessionId: String) -> Bool {
        guard let activeSessionId,
              client != nil,
              isConnected,
              turnState == .idle,
              !messages.isEmpty,
              offlineChatPresentation == nil,
              reconciliation == nil,
              chatResumeRestorationRequest == nil,
              chatPickedFromSavedList == nil,
              activeRoomSurface == nil,
              explicitSessionOpenTask == nil else { return false }
        if activeSessionId == sessionId { return true }
        let rows = (sessions + cronSessions).filter { $0.nestingIDs.contains(sessionId) }
        guard rows.count == 1, let row = rows.first else { return false }
        return row.nestingIDs.contains(activeSessionId)
    }

    func cancelExplicitSessionOpen() {
        explicitSessionOpenRequestID = nil
        explicitSessionOpenTask?.cancel()
        explicitSessionOpenTask = nil
    }

    /// Why an open did not complete. A SUPERSEDED open (a newer navigation
    /// owns the viewport transition) is navigation state, never a failure:
    /// callers must not publish failure text for it, even when the newer
    /// navigation re-opened the SAME session id.
    enum SessionOpenOutcome {
        case opened
        case superseded
        case failed
    }

    private func performSessionOpen(
        _ sessionId: String,
        reusing viewportTransitionGeneration: UInt64?,
        presentationMigrationSessionIDs: Set<String> = [],
        conversationProfile: String? = nil,
        preferredTitle: String? = nil,
        widgetLease: WidgetLaunchLease? = nil
    ) async -> SessionOpenOutcome {
        await performSessionOpenNotingRefusal(
            sessionId,
            reusing: viewportTransitionGeneration,
            presentationMigrationSessionIDs: presentationMigrationSessionIDs,
            conversationProfile: conversationProfile,
            preferredTitle: preferredTitle,
            widgetLease: widgetLease
        ).outcome
    }

    /// `performSessionOpen`, also saying whether a `.failed` open was
    /// refused for good (#789): the conversation belongs to another
    /// workspace, Hermes doesn't have it (4007), or Hermes resumed a
    /// different one. Any other failure (a dropped connection, a read that
    /// timed out) can pass on another try.
    private func performSessionOpenNotingRefusal(
        _ sessionId: String,
        reusing viewportTransitionGeneration: UInt64?,
        presentationMigrationSessionIDs: Set<String> = [],
        conversationProfile: String? = nil,
        preferredTitle: String? = nil,
        widgetLease: WidgetLaunchLease? = nil
    ) async -> (outcome: SessionOpenOutcome, refused: Bool, sessionWasNotFound: Bool) {
        // A failure before this open's reconcile reports no verdict and
        // leaves the reconcile flags alone: they may be another flow's,
        // read back after its own hop (#1918).
        guard let client else { return (.failed, false, false) }
        // From the tap to Hermes' rows, for a device trace (#1533).
        let signposter = ResponsivenessSignposts.signposter
        let opening = signposter.beginInterval("Chat open", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Chat open", opening) }
        // A session open takes the viewport back from any open room. A room
        // surface is presentation-only (never session state), so closing it
        // here cannot disturb the conversation being opened; the room stays
        // in the roster, resumable with one tap. The chat shows where the
        // room was, once this open has named it below: a refused or
        // superseded open hands the room's screen to nothing, rather than
        // to the chat that was open before the room. Nothing awaits in
        // between, so the shell reads the handoff only after it's settled.
        let closedRoom = activeRoomSurface != nil
        if closedRoom {
            closeRoomSurface()
        }
        let previousTurnState = turnState
        // The catalog-ownership guard protects ORDINARY opens from another
        // dashboard profile's rows. A bot open carries the conversation's
        // profile explicitly (its canonical row may legitimately surface in
        // the raw catalog as a stray from older server data), so the guard
        // would only misfire here.
        // A saved chat's row opens by its stored session id.
        let listedSession = (sessions + cronSessions).first(where: {
            $0.id == sessionId || $0.alternateIds.contains(sessionId)
        }) ?? (sessions + cronSessions).first(where: { $0.storedSessionId == sessionId })
        if conversationProfile == nil,
           let session = listedSession, !sessionBelongsToProfile(session, profile: activeProfile) {
            errorMessage = AppLocalization.string("That conversation belongs to another workspace. Switch profiles to open it.")
            return (.failed, true, false)
        }
        // Read before the open marks it read: an unread chat lands at the
        // start of its latest reply once its transcript is in (#365).
        let opensUnreadReply = listedSession.map { isSessionUnread($0) } ?? false
        let transitionGeneration: UInt64
        if let viewportTransitionGeneration {
            guard chatViewportTransitionIsCurrent(
                generation: viewportTransitionGeneration
            ) else { return (.superseded, false, false) }
            transitionGeneration = viewportTransitionGeneration
        } else {
            transitionGeneration = beginExplicitChatViewportTransition(ownedBy: widgetLease)
        }
        guard widgetLease?.isCurrent != false else { return (.superseded, false, false) }
        guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
            return (.superseded, false, false)
        }
        markChatViewportReplacement()
        // Atomically switch session identity BEFORE clearing the transcript.
        // This prevents stale stream events from the old session falling
        // through `eventBelongsToActiveSession` and repopulating the
        // cleared message array while reconciliation is in flight.
        flushPendingPresentationCache()
        // The chat on screen is kept and is being replaced: its owner,
        // taken before this open noted its ids, has done its job.
        outgoingBotChatCopyOwner = nil
        let openedIdentity = captureConversationIdentity(
            for: sessionId,
            scopeProfile: conversationProfile
        )
        let token = beginReconciliation()
        let acceptedSessionIDs = knownSessionIDs(for: sessionId)
        // A bot chat is not the dashboard workspace's ORDINARY selection, but
        // it IS the conversation the user is viewing: the recorded reference
        // carries its kind, so the Sessions surface never adopts it while a
        // cold launch still restores exactly what was on screen. Ownership
        // comes from the bot registry (seeded above), never the id's shape.
        // A chat left after Load earlier keeps its older rows for coming
        // back to it (issue 1825); the reconcile below takes them.
        keepLeftBackfilledTranscript()
        setActiveSessionState(id: sessionId)
        if closedRoom { roomHandedTo = .openedChat }
        keepDelegateAgents(of: acceptedSessionIDs)
        messages = []
        // A chat with a saved copy shows it while Hermes sends the transcript
        // (#1352): a Bot Chat the copy kept when it was left, any other the
        // one on the phone.
        // A known Bot Chat opened the ordinary way (a notification, a link)
        // is still the bot's: the registry names it.
        if let bot = conversationProfile ?? botConversationProfile(for: sessionId) {
            presentKeptBotChatCopy(bot: bot, openedAs: sessionId, title: preferredTitle)
        } else if let listedSession {
            presentSavedCopyWhileOpening(
                listedSession,
                openedAs: sessionId,
                transition: transitionGeneration,
                reconcileToken: token
            )
        }
        // Explicit navigation owns the chat surface from here. A chat picked
        // in the saved list, or opened with a saved copy, keeps that copy up
        // until its own transcript replaces it (`messages`' didSet), rather
        // than blanking first.
        if offlineChatPresentation?.picked?.sessionIDs.contains(sessionId) != true {
            dismissOfflineChatPresentation()
        }
        // An unread chat left while its latest turn ran lands at that turn's
        // reply start now, from the saved rows: Hermes' rows have the same
        // start and replace them in place, so the chat doesn't move when
        // they land (#1533). A copy whose turn has a reply waits for Hermes'
        // rows, which can start a newer turn below it.
        let landsFromSavedRows = opensUnreadReply && showsOfflineChatCopy
            && Self.savedRowsEndMidTurn(offlineChatPresentation?.displayedMessages ?? [])
        if landsFromSavedRows { chatReplyStartLandingRequest &+= 1 }
        persistedTranscriptWindow = nil
        // Freshness evidence belongs to the conversation it was captured
        // for; the reconcile below re-establishes it authoritatively.
        resetTranscriptLifecycleEvidence()
        clearStreamingText()
        activeAssistantMessageId = nil
        resetReasoningTurn()
        // A canonical Bot Chat carries its own title (the bot's display
        // label) and must never write the catalog's wire title — or any
        // title — into the dashboard profile's persisted title cache. Both
        // conditions are required: the parameter covers the roster's own
        // open, and the registry covers a KNOWN bot conversation opened
        // through the ordinary path (`requestOpenSession` and friends,
        // which pass no conversation profile).
        if conversationProfile == nil,
           botConversationProfile(for: sessionId) == nil {
            updateActiveSessionTitle(for: sessionId)
        }
        if let preferredTitle, !preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeSessionTitle = preferredTitle
        }
        let reconciled = await reconcile(
            sessionId: sessionId,
            using: client,
            token: token,
            acceptedSessionIDs: acceptedSessionIDs,
            conversationIdentity: openedIdentity,
            requiredViewportTransitionGeneration: transitionGeneration,
            presentationMigrationSessionIDs: presentationMigrationSessionIDs,
            conversationProfile: conversationProfile,
            widgetLease: widgetLease
        )
        // The picked chat's saved copy has done its job: its own transcript
        // (or none, for an empty chat) is up, or the open failed.
        if chatViewportTransitionIsCurrent(generation: transitionGeneration),
           offlineChatPresentation?.picked?.sessionIDs.contains(sessionId) == true {
            dismissOfflineChatPresentation()
        }
        guard widgetLease?.isCurrent != false else {
            // The widget launch expired with nothing newer on screen: settle
            // like a failed open, so the composer doesn't stay synchronizing
            // a transcript this open will never publish.
            if chatViewportTransitionIsCurrent(generation: transitionGeneration) {
                settleReconciliation(token)
                finishChatViewportTransition(generation: transitionGeneration)
                if turnState == .synchronizing { turnState = .idle }
            }
            return (.superseded, false, false)
        }
        guard chatViewportTransitionIsCurrent(generation: transitionGeneration) else {
            return (.superseded, false, false)
        }
        if !reconciled {
            finishChatViewportTransition(generation: transitionGeneration)
            if Task.isCancelled, turnState == .synchronizing {
                turnState = previousTurnState
            }
            // This open still owns the viewport, so the reconcile failure is
            // genuine (identity rejection and friends set their own message).
            // Read before any await: the flags describe the reconcile above,
            // unless another reconcile (an automatic resume of another chat)
            // began meanwhile and set them for its own chat (#1918).
            let verdictIsOwn = reconciliationToken == token
            return (
                .failed,
                verdictIsOwn && (reconciliationWasIdentityRejected || reconciliationSessionWasNotFound),
                verdictIsOwn && reconciliationSessionWasNotFound && !reconciliationWasKanbanWorker
            )
        }
        if opensUnreadReply, !landsFromSavedRows { chatReplyStartLandingRequest &+= 1 }
        return (.opened, false, false)
    }

    /// Whether saved rows end in a turn with no reply yet: the user's latest
    /// message has only steps after it, or nothing. Its reply starts where
    /// it will when Hermes' rows are in.
    nonisolated static func savedRowsEndMidTurn(_ rows: [ChatMessage]) -> Bool {
        guard let user = rows.lastIndex(where: { $0.role == .user }) else { return false }
        return !rows[(user + 1)...].contains { $0.role == .assistant }
    }

    /// How a notification open ended, for the route that retries it (#789):
    /// `.retry` is a read or switch that can succeed once the connection or
    /// the session catalog is ready; `.failed` means don't retry and say no
    /// more: usually the open already told the user why it can't, or
    /// something opened since owns the screen (a room open a newer
    /// navigation superseded). `.unverified` is a
    /// `.retry` whose failure has something to tell the user (the dashboard
    /// didn't connect, the workspace couldn't be checked): the route says it
    /// only once its window runs out, so a retry that passes shows no error.
    enum NotificationOpenOutcome: Equatable {
        case opened
        case retry
        case unverified(String)
        case failed
        /// The open needs a switch that would end the call running: it
        /// opens once that call has ended.
        case afterCall
    }

    /// One open with no retry after it, so an `.unverified` failure says why
    /// at once. Only a call's own open uses it: that never spares calls, so
    /// it never gets `.afterCall`, which needs the route's wait (ConduitApp).
    func openNotificationTarget(_ target: ConduitNotificationTarget) async -> Bool {
        let outcome = await openNotificationTargetOutcome(target)
        if case .unverified(let message) = outcome { errorMessage = message }
        return outcome == .opened
    }

    /// A notification tap reads the chat list again before it opens only
    /// when the list on hand lacks the chat: reading the whole list took
    /// 2-3 s on a long one (897 rows), seconds more over a remote dashboard,
    /// and the tap waited for it. A chat the list holds opens at once, and
    /// the list is read again after (Eric, 2026-11-04, issue 1724; answered
    /// calls first did this, 2026-11-02). A notification with no durable id
    /// opens at once only when its id is a row's stored id: a runtime id can
    /// be handed to another conversation, so a row that matches it alone
    /// may not be the notification's chat.
    /// A bot's workstream never needs it: it isn't in the list here (Hermes
    /// hides an open one, and this app leaves a resolved one out), so the
    /// read can't find its row and only held the open up for seconds
    /// (Eric's build 248 test, a secondary bot's work link or card).
    nonisolated static func notificationOpenNeedsAuthoritativeRead(
        target: ConduitNotificationTarget,
        catalog: [SessionSummary],
        isWorkstream: Bool = false
    ) -> Bool {
        if isWorkstream { return false }
        // The route resolves to the payload's durable id first, so that id
        // must be on hand too, or the bot-chat check would miss its row.
        guard catalogListsSession(target.sessionId, in: catalog) else { return true }
        guard let durable = target.durableSessionID else {
            return !catalogListsStoredSession(target.sessionId, in: catalog)
        }
        return !catalogListsSession(durable, in: catalog)
    }

    /// Whether `sessionID` is a row's stored (durable) id.
    nonisolated static func catalogListsStoredSession(_ sessionID: String, in catalog: [SessionSummary]) -> Bool {
        guard let wanted = ChatScrollIdentityNormalization.sessionID(sessionID) else { return false }
        return catalog.contains { row in
            row.storedSessionId.map { ChatScrollIdentityNormalization.sessionID($0) == wanted } ?? false
        }
    }

    /// Whether `sessionID` names a row of `catalog`: its id, stored id or
    /// one of its alternates.
    nonisolated static func catalogListsSession(_ sessionID: String, in catalog: [SessionSummary]) -> Bool {
        guard let wanted = ChatScrollIdentityNormalization.sessionID(sessionID) else { return false }
        return catalog.contains { row in
            ([row.id, row.storedSessionId].compactMap { $0 } + row.alternateIds)
                .contains { ChatScrollIdentityNormalization.sessionID($0) == wanted }
        }
    }

    /// Routes a notification to its originating profile/session without
    /// allowing the ordinary cold-start session restoration to win first.
    func openNotificationTargetOutcome(_ target: ConduitNotificationTarget) async -> NotificationOpenOutcome {
        let outcome = await openNotificationTargetOutcomeRouted(target)
        // A wait's notification whose id the open resolved to another (a
        // runtime id from an older notifier): its card is in the chat that
        // opened, so the reveal names that one (issue 1705).
        if outcome == .opened, let type = target.type, NeedsYouStore.notificationTypes.contains(type),
           let reveal = pendingNeedsYouReveal, !isShowingChat(for: reveal),
           let opened = activeSessionId, !opened.isEmpty {
            pendingNeedsYouReveal = NeedsYouReveal(opening: opened)
        }
        return outcome
    }

    private func openNotificationTargetOutcomeRouted(_ target: ConduitNotificationTarget) async -> NotificationOpenOutcome {
        widgetLaunchCoordinator.supersede()
        // Where an open for a call from Hermes stopped (#449).
        var traceStage = "dashboard check"
        defer { HermesCallTrace.shared.note("Chat open ended at: \(traceStage)") }
        // Switching dashboard or profile ends a call that's running, so an
        // open that needs a switch stops while one runs. A call from Hermes
        // opening its own chat (answered, or its notification tapped, a
        // missed call's included) still switches: talking to Hermes leaves
        // the other call.
        let sparesCalls = target.call == nil
        // A chat link can be tapped again once the call ends; a tapped
        // notification is gone, so it waits for the call instead.
        let callOutcome: NotificationOpenOutcome = target.isChatLink ? .failed : .afterCall
        // Dashboard ownership gate (#148 / B3): a push from dashboard A is
        // never processed against active dashboard B, even when profile,
        // session, and request ids all collide. A push belonging to another
        // KNOWN dashboard switches to it first — the decision card is
        // recorded only after the owning dashboard is active, so it can
        // never land in the outgoing dashboard's state. Unknown or unscoped
        // identities fail closed.
        switch NotificationDashboardOwnership.resolve(
            targetDashboardID: target.dashboardID,
            hasMalformedDashboardID: target.hasMalformedDashboardID,
            activeDashboardID: activeDashboardID,
            savedDashboardIDs: savedDashboardRegistry.dashboards.map(\.id),
            targetGatewayID: target.relayGatewayID,
            activeDashboardGatewayIDs: activeDashboardRelayGatewayIDs
        ) {
        case .route:
            guard connection != nil else {
                traceStage = "dashboard check (not connected)"
                return .retry
            }
        case .switchFirst(let dashboardID):
            traceStage = "dashboard check (switching to another saved dashboard)"
            // A notification tapped during a call, or a chat link routed
            // before one started, stops here: switching dashboards would
            // tear that call down.
            if sparesCalls, isVoiceCallInProgress {
                traceStage = "call in progress"
                showCallRefusal(target.isChatLink
                    ? AppLocalization.string("End the call to open a chat in another workspace.")
                    : AppLocalization.string("This notification opens in the other workspace when the call ends."))
                return callOutcome
            }
            await switchDashboard(to: dashboardID)
            // The switch flipped `isConnected`, which restarts this route's
            // task; the run it restarted opens the tap once the dashboard is
            // connected, so this one stops (issue 1888).
            if Task.isCancelled { return .retry }
            guard isConnected, activeDashboardID == dashboardID, client != nil else {
                // The switch failed: the target stays selected with its
                // sign-in/repair surface, and the notification routes
                // nowhere. No other dashboard is auto-connected.
                let message = AppLocalization.string("Could not connect to that dashboard to open this notification.")
                // A restore that failed on the network reconnects by itself,
                // and the reconnect retries the tap (the dashboard is active
                // now, so without switching again). Signing in is the user's
                // step, and another dashboard picked meanwhile owns the
                // screen: neither passes on a retry.
                guard activeDashboardID == dashboardID, !showLogin else {
                    errorMessage = message
                    return .failed
                }
                return .unverified(message)
            }
        case .failClosed(let failure):
            switch failure {
            case .unrecognizedDashboard:
                traceStage = "dashboard check (unrecognized dashboard)"
                errorMessage = AppLocalization.string("This notification belongs to a dashboard this device doesn't recognize. Add that dashboard again to continue.")
            case .unscopedPush:
                traceStage = "dashboard check (unscoped push)"
                errorMessage = AppLocalization.string("This notification predates multi-dashboard pairing. Update the notifier on the sending gateway and pair it again to continue.")
            }
            return .failed
        }
        // A turn's reply, failure, background task or approval in a group
        // room this Hermes hosts opens the room, where an approval has its
        // card: the chat it names is the bot's hidden one there, not a chat
        // to open (issue 2064). Rooms are the dashboard's, whichever
        // profile's bot it was, so no profile switch.
        if let roomID = target.roomID {
            traceStage = "group room"
            return await openNotificationRoom(roomID)
        }
        // An approval one of your agents waits for in a room someone else
        // hosts: its notification names the hidden chat the turn runs in,
        // which approval.respond can't answer for, so its card opens
        // instead (RoomApprovals.swift). It can't open over a call's screen.
        if case .approval(let sessionKey, _, _) = target.decision, target.call == nil, canAnswerRoomApprovals {
            traceStage = "room approval check"
            let keys = [sessionKey, target.durableSessionID, target.sessionId].compactMap { $0 }
            if let approval = await roomApproval(matching: keys) {
                // A newer tap or a reconnect started this route over meanwhile.
                guard !Task.isCancelled else { return .retry }
                guard !isVoiceCallInProgress else {
                    showCallRefusal(AppLocalization.string("This approval opens when the call ends."))
                    return callOutcome
                }
                presentedRoomApproval = approval
                return .opened
            }
        }
        if await opensPulseScreen(for: target) {
            traceStage = "pulse"
            return .opened
        }
        traceStage = "open start"
        // An approval's or a question's notification lands on its card, as
        // the Needs you list's Open does (issue 1705).
        if let type = target.type, NeedsYouStore.notificationTypes.contains(type) {
            pendingNeedsYouReveal = NeedsYouReveal(opening: target.durableSessionID ?? target.sessionId)
        }
        let notificationAttemptID = UUID()
        activeNotificationOpenAttemptID = notificationAttemptID
        isOpeningNotificationSession = true
        let transitionGeneration = beginExplicitChatViewportTransition()
        defer {
            // Ends with no transcript of its own laid out (a profile switch
            // it lent the transition to marks a replacement but replaces no
            // transcript): the viewport is released, not left frozen.
            finishChatViewportTransitionIfNoTranscriptReplacement(generation: transitionGeneration)
            finishNotificationOpenAttempt(id: notificationAttemptID)
        }
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else { return .retry }
        // A push is a Bot Chat decision when its CONVERSATION is a bot's
        // canonical chat, never because of the profile it names. Every Hermes
        // profile is listed by `profiles.list` (the Bots roster), and the
        // notifier stamps its own profile on every push, so a name match would
        // refuse every push once the roster had loaded, including replies and
        // background turns from the workspace the dashboard is showing. The
        // refusal copy still reads the name the PUSH carried, so a case-only
        // match keeps its own diagnostic.
        if notificationTargetIsBotChat(target) {
            traceStage = "bot chat"
            return await routeBotOwnedNotification(
                target,
                notifiedProfile: target.profile ?? "",
                attemptID: notificationAttemptID,
                transitionGeneration: transitionGeneration
            )
        }
        let targetProfile = notificationProfileID(target.profile)
        // What a notification or a chat link for another profile says when a
        // call keeps it from switching; nil for a call's own open.
        let profileCallRefusal: String? = sparesCalls
            ? (target.isChatLink
                ? AppLocalization.string("End the call to open a chat in another profile.")
                : AppLocalization.string("This notification opens in the other profile when the call ends."))
            : nil
        if let notified = target.profile, let targetProfile,
           targetProfile != activeProfile,
           botModePhase != .gatewayUnsupported {
            // Crossing into another profile reads the roster as ABSENCE
            // evidence (this conversation is no bot's chat), so it must be
            // evidence from NOW. The roster is otherwise loaded once per
            // connection and when the Bots surface opens, which leaves a
            // window: a Bot Chat created after that load is missing from a
            // roster that still reports `.available`. One refresh at this
            // user-initiated decision (single-flight, epoch-fenced) closes it,
            // and a refresh that fails leaves the evidence unverifiable, which
            // refuses.
            traceStage = "bot roster"
            await refreshBotRoster()
            // The refresh ALWAYS suspends (it creates or joins a task), so
            // this attempt must re-prove it still owns the route before it
            // reads the evidence or writes an error: a newer tap can have
            // replaced the attempt and begun its own viewport transition
            // while this one was waiting.
            guard notificationOpenAttemptIsCurrent(
                id: notificationAttemptID,
                transitionGeneration: transitionGeneration
            ) else { return .retry }
            if notificationTargetIsBotChat(target) {
                // Opened in Bots, never by switching: making the bot's
                // profile this dashboard's workspace would turn its Bot Chat
                // into the workspace's own context.
                traceStage = "bot chat"
                return await routeBotOwnedNotification(
                    target,
                    notifiedProfile: notified,
                    attemptID: notificationAttemptID,
                    transitionGeneration: transitionGeneration
                )
            }
            guard botEvidenceIsAvailable else {
                // No usable Bot Mode evidence (the roster could not be
                // loaded): the conversation may be a bot's chat, and adopting
                // its profile would hand it the workspace's context. Fail
                // closed rather than guess. The roster can load on a retry
                // (it's read again above), so nothing is adopted until then.
                // During a call that retry waits for the call to end, as the
                // switch would: retried now, it could run out of time first.
                if let profileCallRefusal, isVoiceCallInProgress {
                    traceStage = "call in progress (bot roster)"
                    showCallRefusal(profileCallRefusal)
                    return callOutcome
                }
                return .unverified(AppLocalization.string(
                    "Could not verify that workspace for this notification. Reconnect and try again."
                ))
            }
            // Ask the TARGET profile for its canonical Bot Chat before
            // adopting it: the exact-title lookup reads the lineage tip
            // server-side, so a Bot Chat that compacted since the roster was
            // read is still recognized here, BEFORE the switch rather than
            // after it. A failed lookup proves nothing and fails closed.
            traceStage = "bot chat lookup"
            let pushesCanonicalChat: Bool
            do {
                pushesCanonicalChat = try await notificationTargetIsCanonicalChat(
                    target,
                    of: targetProfile
                )
            } catch {
                guard notificationOpenAttemptIsCurrent(
                    id: notificationAttemptID,
                    transitionGeneration: transitionGeneration
                ) else { return .retry }
                // A lookup that failed proves nothing either way: it is
                // asked again on a retry, and nothing is adopted until then.
                // During a call, the retry waits for the call to end.
                if let profileCallRefusal, isVoiceCallInProgress {
                    traceStage = "call in progress (bot chat lookup)"
                    showCallRefusal(profileCallRefusal)
                    return callOutcome
                }
                return .unverified(AppLocalization.string(
                    "Could not verify that workspace for this notification. Reconnect and try again."
                ))
            }
            guard notificationOpenAttemptIsCurrent(
                id: notificationAttemptID,
                transitionGeneration: transitionGeneration
            ) else { return .retry }
            if pushesCanonicalChat {
                traceStage = "bot chat"
                return await routeBotOwnedNotification(
                    target,
                    notifiedProfile: notified,
                    canonicalProfile: targetProfile,
                    attemptID: notificationAttemptID,
                    transitionGeneration: transitionGeneration
                )
            }
        }
        if let notified = target.profile, let targetProfile,
           targetProfile == activeProfile,
           botModePhase != .gatewayUnsupported {
            // Same lookup for a push on the profile already on screen: a Bot
            // Chat that compacted since the roster was read is hidden from
            // the session catalog, so only the canonical lookup can name its
            // tip. No profile is adopted here, so a failed lookup does not
            // block the push; the catalog check below still applies.
            traceStage = "bot chat lookup"
            let pushesCanonicalChat = (try? await notificationTargetIsCanonicalChat(
                target,
                of: targetProfile
            )) ?? false
            guard notificationOpenAttemptIsCurrent(
                id: notificationAttemptID,
                transitionGeneration: transitionGeneration
            ) else { return .retry }
            if pushesCanonicalChat {
                traceStage = "bot chat"
                return await routeBotOwnedNotification(
                    target,
                    notifiedProfile: notified,
                    canonicalProfile: targetProfile,
                    attemptID: notificationAttemptID,
                    transitionGeneration: transitionGeneration
                )
            }
        }
        if let targetProfile, targetProfile != activeProfile {
            // A call can have started (one from Hermes needs no tap) while
            // the checks above waited on the gateway; a notification or a
            // chat link never ends it with the switch.
            if let profileCallRefusal, isVoiceCallInProgress {
                traceStage = "call in progress"
                showCallRefusal(profileCallRefusal)
                return callOutcome
            }
            traceStage = "profile switch"
            guard await switchProfile(
                to: targetProfile,
                reusing: transitionGeneration,
                refusingCallsWith: profileCallRefusal
            ) else {
                // A call that started during the switch refuses it the
                // same way, and says so; anything else may pass on a retry.
                guard sparesCalls, isVoiceCallInProgress else { return .retry }
                traceStage = "call in progress (profile switch)"
                return callOutcome
            }
        }
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else {
            return .retry
        }
        if let targetProfile, activeProfile != targetProfile { return .retry }
        guard client != nil else { return .retry }
        showSidebar = false

        // Pushes can arrive before this device has seen the scheduled run.
        // Replace the cached catalog first, then prefer the catalog's stored
        // ID for the notification's runtime/alternate ID. Otherwise the next
        // cold-start recovery only sees the old normal-session list and jumps
        // back to its newest entry.
        // Do not share the sidebar refresh guard here. A chat the list on
        // hand lacks takes one authoritative read even if a visual refresh
        // is already in progress, otherwise it can resolve against the stale
        // catalog. When the list already holds the chat, the route resolves
        // against that list: reading the whole list again took 2-3 s on a
        // long list (897 rows, Ul'dah 2026-11-02). A row that matches the
        // notification's id by any of its ids is its chat even if the host
        // has since rotated its runtime id, and the read after the open
        // brings the row up to date (issue 1724).
        var readsListAfterOpen = false
        var openedFromListOnHand = false
        defer {
            if readsListAfterOpen {
                // Quiet: the chat opened, and a failed list read after it
                // is no error on it; the list's poll reads again.
                Task { @MainActor [weak self] in
                    _ = await self?.loadSessions(
                        forceRefresh: true,
                        requiredViewportTransitionGeneration: nil,
                        reportsFailure: false
                    )
                }
            }
        }
        if !Self.notificationOpenNeedsAuthoritativeRead(
            target: target,
            catalog: sessions + cronSessions,
            isWorkstream: isWorkstreamSession(target.sessionId)
        ) {
            traceStage = "session list (on hand)"
            openedFromListOnHand = true
        } else {
            traceStage = "session list"
            guard await loadSessions(
                forceRefresh: true,
                requiredViewportTransitionGeneration: transitionGeneration
            ) else { return .retry }
        }
        traceStage = "bot chat check"
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else {
            return .retry
        }
        let requestedID = target.sessionId
        // The catalog is fresh, or (for an answered call) already lists the
        // call's chat; its labeled rows are committed to the identity index,
        // so resolution runs through the
        // evidence hierarchy: explicit durable id from the payload, catalog
        // alias, confirmed index alias — and only then the legacy raw
        // runtime resume. An unknown runtime id is never reinterpreted as
        // some other conversation's durable id.
        let route = NotificationSessionResolver.route(
            target: target,
            catalog: sessions + cronSessions,
            identityIndex: conversationIdentityIndex,
            profile: activeProfile
        )
        // Last look at Bot Chat ownership, with the fresh catalog of the
        // (now active) profile: a Bot Chat linked to its canonical id only
        // through the row's lineage root or aliases goes to Bots before it
        // opens as this workspace's conversation. The same row-level rules
        // the sessions list and resume selection use decide it. A
        // cross-profile Bot Chat already went to Bots before the switch, by
        // the target's canonical lookup.
        let routedIDs = Set([requestedID, route.resumeTargetID, route.durableSessionID].compactMap {
            ChatScrollIdentityNormalization.sessionID($0)
        })
        let botOwned = botOwnedSessionIDs
        if let botRow = sessions.first(where: { row in
            let rowIDs = Set([row.id, row.storedSessionId].compactMap { $0 } + row.alternateIds)
            return !rowIDs.isDisjoint(with: routedIDs)
                && (BotChatHygiene.isCanonicalBotChatRow(row, roster: botRoster)
                    || BotChatHygiene.isBotOwnedRow(row, botOwnedSessionIDs: botOwned)
                    || BotChatHygiene.isReservedCanonicalTitleRow(row))
        }) {
            traceStage = "bot chat"
            return await routeBotOwnedNotification(
                target,
                notifiedProfile: target.profile ?? activeProfile,
                rowIDs: Set([botRow.id, botRow.storedSessionId, botRow.lineageRootId].compactMap { $0 } + botRow.alternateIds),
                attemptID: notificationAttemptID,
                transitionGeneration: transitionGeneration
            )
        }
        // A decision raised while the app was backgrounded is delivered as a
        // structured payload on the notification (the one-shot gateway stream
        // event was missed). The card is recorded BEFORE the open — the
        // upcoming resume's `merge` restores it into the live transcript —
        // but persisted ONLY under the identity the push itself named
        // (`requestedID`): that id provably belonged to the notified
        // conversation at push time. The payload's durable claim is NOT
        // written while unproven — a rejected open must not leave a card
        // under a durable it merely claimed. When the open succeeds, the
        // admitted resume's consolidation migrates the card to the durable
        // key and retires the runtime key.
        if let decision = target.decision {
            let knownKeys = route.durableSessionID.map { durable in
                [route.resumeTargetID, requestedID, durable]
            } ?? [route.resumeTargetID, requestedID]
            recordNotificationDecision(
                decision,
                sessionIDs: knownKeys,
                cacheSessionIDs: [requestedID]
            )
        }
        traceStage = "session open"
        // A failure that isn't a refusal is retried with backoff, so the
        // error it sets is not the last word: it is put back below and
        // shown only if the window runs out with no chat opened.
        let routeErrorBeforeOpen = chatSyncErrorMessage
        let (outcome, refused, _) = await performSessionOpenNotingRefusal(
            route.resumeTargetID,
            reusing: transitionGeneration,
            // The push-named runtime id is a PRESENTATION MIGRATION SOURCE,
            // never an identity alias: a pending decision card recorded
            // under it before the open must be promoted into the admitted
            // durable conversation now that admission succeeded. On a
            // rejected open nothing migrates (the hook only runs on
            // admission success).
            presentationMigrationSessionIDs: [requestedID]
        )
        let opened = outcome == .opened
        // An open that landed, or one Hermes refused (the chat is gone, so
        // the list drops its row), reads the list after it; a superseded or
        // passing failure leaves it to the list's poll.
        readsListAfterOpen = openedFromListOnHand && (opened || refused)
        traceStage = "session open, \(outcome)"
        // Commit the payload's dual identity as positive evidence only once
        // the open actually succeeded — a failed resume (e.g. the durable
        // conversation was deleted server-side) must not leave a mapping
        // that dead-routes future notifications.
        if opened, let durable = route.durableSessionID {
            if let conflict = conversationIdentityIndex.record(
                runtimeID: requestedID,
                durableID: durable,
                profile: activeProfile,
                source: .notification
            ) {
                sessionCatalogLog.fault(
                    "Notification identity conflict: runtime \(requestedID, privacy: .private(mask: .hash)) keeps confirmed durable \(conflict.confirmedDurableID, privacy: .private(mask: .hash)); payload claimed \(durable, privacy: .private(mask: .hash))"
                )
            }
        }
        if !opened, let decision = target.decision,
           let evictionKey = Self.pendingDecisionEvictionKey(for: decision) {
            // The claim was rejected: evict the pre-open card from the
            // push-named runtime key. Without this, the stale card would
            // still sit under that runtime id and a LATER legitimate open
            // of the true owner would promote it into the wrong durable
            // conversation.
            sessionPresentationCache.removePendingDecision(
                key: evictionKey,
                profile: presentationProfile(for: requestedID),
                sessionIDs: [requestedID]
            )
        }
        guard notificationOpenAttemptIsCurrent(
            id: notificationAttemptID,
            transitionGeneration: transitionGeneration
        ) else { return .retry }
        if opened {
            discardNotificationRouteFailure(for: target)
            return .opened
        }
        // Hermes answered that the conversation is gone, or is another one:
        // the same open would get the same answer.
        if refused {
            discardNotificationRouteFailure(for: target)
            return .failed
        }
        // Another attempt is due: keep this attempt's words for the window's
        // end, and put back whatever the chat had said before, so a retry
        // that opens the chat never leaves it wearing an error. An attempt
        // that lost its answer without a message of its own leaves the
        // earlier one standing, since that is still the last thing known.
        if let failure = chatSyncErrorMessage, failure != routeErrorBeforeOpen {
            notificationRouteFailure = (target, failure)
        }
        chatSyncErrorMessage = routeErrorBeforeOpen
        return .retry
    }

    /// The stable decision key a push-delivered card was recorded under
    /// (`approval:<sessionKey>` / `clarify:<requestId>`) — used to evict a
    /// pre-open card when its open is rejected. Batch clarifies share the
    /// scalar key shape via their relay request id.
    static func pendingDecisionEvictionKey(
        for decision: PendingDecisionPayload
    ) -> String? {
        switch decision {
        case .approval(let sessionKey, _, _):
            return "approval:\(sessionKey)"
        case .clarify(let requestId, _, _):
            return "clarify:\(requestId)"
        case .clarifyBatch(let requestId, _):
            return "clarify:\(requestId)"
        }
    }

    /// Caches a push-delivered decision card so the resume merge can restore
    /// it. The card is recorded as pending and answerable through the existing
    /// `respondToApproval` path; the bounded unconfirmed marker is stamped by
    /// `SessionPresentationCache` so a stale card expires rather than lingering.
    /// The decision's session key must match one of the routed session
    /// identities — a mismatched key could not be answered via
    /// `approval.respond` and would only duplicate or contradict the live card.
    /// `cacheSessionIDs` is the (durable-owned) key set the card persists
    /// under; `sessionIDs` remains the answerability guard.
    /// The card a notification's clarify would draw, for matching it
    /// against Hermes' own card. Nil for an approval.
    static func notificationClarifyActivity(for decision: PendingDecisionPayload) -> ClarifyActivity? {
        switch decision {
        case .approval:
            return nil
        case let .clarify(requestId, question, choices):
            return ClarifyActivity(
                requestId: requestId,
                question: question,
                choices: choices.map { ClarifyChoice(label: $0, value: $0) },
                status: .pending,
                answer: nil,
                error: nil
            )
        case let .clarifyBatch(requestId, questions):
            return ClarifyActivity(requestId: requestId, questions: questions)
        }
    }

    func recordNotificationDecision(
        _ decision: PendingDecisionPayload,
        sessionIDs: [String],
        cacheSessionIDs: [String]? = nil,
        profile: String? = nil
    ) {
        let persistedIDs = cacheSessionIDs ?? sessionIDs
        // The notified conversation's own namespace: the live session on
        // screen is not necessarily the conversation the push named, and
        // the later open/eviction of the named conversation must find the
        // card under the same key it was recorded under.
        // A Bot Chat's card names its bot's namespace outright.
        let recordProfile = profile ?? presentationProfile(for: persistedIDs.first ?? activeSessionId)
        switch decision {
        case let .approval(sessionKey, description, choices):
            // Compare trimmed on both sides: the payload parser trims the
            // session key, but the routed ids arrive as the notification
            // delivered them.
            let knownKeys = sessionIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard knownKeys.contains(sessionKey) else { return }
            let activity = ApprovalActivity(
                sessionId: sessionKey,
                command: "",
                description: description,
                choices: choices,
                allowPermanent: false,
                smartDenied: false,
                status: .pending,
                choice: nil,
                error: nil
            )
            let message = ChatMessage(
                id: "approval-\(sessionKey)",
                role: .approval,
                content: description,
                timestamp: Self.localTimestamp(),
                approval: activity
            )
            sessionPresentationCache.recordPendingDecision(
                message,
                profile: recordProfile,
                sessionIDs: persistedIDs
            )
        case let .clarify(requestId, question, choices):
            // Relay-delivered clarify: the plugin middleware minted this id and
            // is polling the relay, so the standard card renders with working
            // buttons routed through respondToRelayClarify.
            let activity = ClarifyActivity(
                requestId: requestId,
                question: question,
                choices: choices.map { ClarifyChoice(label: $0, value: $0) },
                status: .pending,
                answer: nil,
                error: nil
            )
            let message = ChatMessage(
                id: "clarify-\(requestId)",
                role: .clarify,
                content: activity.displayQuestion,
                timestamp: Self.localTimestamp(),
                clarify: activity
            )
            sessionPresentationCache.recordPendingDecision(
                message,
                profile: recordProfile,
                sessionIDs: persistedIDs
            )
        case let .clarifyBatch(requestId, questions):
            // Batch relay decision (current notifier): the SAME batch
            // ClarifyActivity/ClarifyCard model as native clarifies — the
            // transport is the only difference.
            let activity = ClarifyActivity(requestId: requestId, questions: questions)
            let message = ChatMessage(
                id: "clarify-\(requestId)",
                role: .clarify,
                content: activity.displayQuestion,
                timestamp: Self.localTimestamp(),
                clarify: activity
            )
            sessionPresentationCache.recordPendingDecision(
                message,
                profile: recordProfile,
                sessionIDs: persistedIDs
            )
        }
    }

    private func notificationOpenAttemptIsCurrent(
        id: UUID,
        transitionGeneration: UInt64
    ) -> Bool {
        let current = activeNotificationOpenAttemptID == id
            && chatViewportTransitionIsCurrent(generation: transitionGeneration)
        if !current {
            HermesCallTrace.shared.note(
                "Chat open superseded (different open: \(activeNotificationOpenAttemptID != id), newer chat open: \(!chatViewportTransitionIsCurrent(generation: transitionGeneration)))"
            )
        }
        return current
    }

    /// The route has no attempt left: say why the last one failed, if it had
    /// anything to say. A retry that opened the chat cleared it already, and
    /// a failure another tap's route left behind is not this route's to say.
    func publishNotificationRouteFailure(for target: ConduitNotificationTarget) {
        guard let failure = notificationRouteFailure, failure.target == target else { return }
        notificationRouteFailure = nil
        chatSyncErrorMessage = failure.message
    }

    /// The route ended somewhere that explained itself (`unverified`'s own
    /// message): an earlier attempt's failure is older news than that, and
    /// saying both would leave the newer explanation under an older one.
    func discardNotificationRouteFailure(for target: ConduitNotificationTarget) {
        guard let failure = notificationRouteFailure, failure.target == target else { return }
        notificationRouteFailure = nil
    }

    private func finishNotificationOpenAttempt(id: UUID) {
        guard activeNotificationOpenAttemptID == id else { return }
        activeNotificationOpenAttemptID = nil
        isOpeningNotificationSession = false
    }

    func notificationProfileID(_ notifiedProfile: String?) -> String? {
        guard let notifiedProfile else { return nil }
        let normalized = notifiedProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.caseInsensitiveCompare("default") == .orderedSame
            || normalized.caseInsensitiveCompare(defaultProfileName) == .orderedSame {
            return "default"
        }
        return profiles.first { $0.caseInsensitiveCompare(normalized) == .orderedSame } ?? normalized
    }
}
