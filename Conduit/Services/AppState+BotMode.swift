//
//  AppState+BotMode.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Bot Mode; Bot Mode (roster +
//  canonical chat); Bot management (create / edit / delete / avatars).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Bot Mode

    /// The in-flight roster refresh, held so a replacement `.task` can JOIN
    /// it instead of racing it (see `refreshBotRoster`). Unstructured on
    /// purpose: a SwiftUI `.task(id:)` identity change cancels the VIEW
    /// task, never this work. Class box: `Task` is a value with no identity,
    /// and the joiner must be able to tell its (completed) flight from a
    /// newer one's before clearing the handle.
    final class BotRosterRefreshFlight {
        let task: Task<Void, Never>
        init(task: Task<Void, Never>) { self.task = task }
    }

    /// One resolve/create/open flight per bot name: double-tapping a row must
    /// not mint two canonical chats (upstream `canonicalCreations`). The box
    /// exists so a stale flight's cleanup can never evict a newer flight's
    /// entry (identity-checked removal), and so a server switch can cancel
    /// the underlying task.
    final class BotChatOpenFlight {
        var task: Task<Bool, Never>?
        /// The navigation the flight's open owns (`chatViewportTransition`):
        /// once a newer one has begun, a tap on the same bot opens on its
        /// own rather than join a flight that will stand down.
        var transition: UInt64?
    }

    /// A Bot Chat a tap, a link or a new bot is opening, with the navigation
    /// its open began. Bots pushes the chat's screen as its list closes,
    /// before Hermes' lookup lands (#1700), so until then the active chat is
    /// still the one open before: another bot's, a session or a room. The
    /// screen covers that chat meanwhile (`botChatComingOverAnother`); a newer
    /// navigation, or the open's end, takes it away.
    struct BotChatOnItsWay: Equatable {
        let bot: String
        let label: String
        let transition: UInt64
    }

    /// The coming bot's name while the screen still holds another chat
    /// (`botChatOnItsWay`): its chat screen shows this bot's name over a
    /// cover, never the chat open before. Nil once its own chat is open.
    var botChatComingOverAnother: String? {
        guard let coming = botChatOnItsWay else { return nil }
        if activeRoomSurface == nil, let open = activeBotChatProfile, profilesMatch(open, coming.bot) { return nil }
        return coming.label
    }

    func invalidateBotOwnershipCache() {
        botOwnershipGeneration &+= 1
    }

    var botOwnership: SessionBotOwnership {
        if let cached = cachedBotOwnership, cached.generation == botOwnershipGeneration {
            return cached.ownership
        }
        let ownership = SessionBotOwnership(
            roster: botRoster,
            registryProfiles: botChatSessionProfiles
        )
        cachedBotOwnership = (botOwnershipGeneration, ownership)
        return ownership
    }

    var botOwnedSessionIDs: Set<String> {
        botOwnership.botOwnedIDs
    }

    /// Whether bot evidence can be READ right now: a roster the SERVER confirmed
    /// on the CURRENT connection, or a gateway that cannot host bots at all. A
    /// failed, pending, or inherited-from-a-previous-connection roster leaves
    /// evidence unavailable, which is what makes an unverified reference
    /// non-authoritative (see `profileOwnershipVerdict`, which draws the same
    /// line for cross-profile routing).
    var botEvidenceIsAvailable: Bool {
        botModePhase == .gatewayUnsupported
            || (botModePhase == .available && botRosterVerifiedForCurrentConnection)
    }

    /// The bot list was read on this connection, or the gateway can't host
    /// bots: what it leaves out is gone, so the widget's Do it doesn't read
    /// it again for a saved bot it lacks.
    var pulseDoItBotRosterRead: Bool { botEvidenceIsAvailable }

    /// Refuses a push whose target is bot-owned, with copy that matches how
    /// confident the match is: ownership folds case, so an exact spelling IS that
    /// bot's profile while a case-only match may be an unrelated workspace that
    /// merely shares the name. Every bot-owned refusal goes through here, so
    /// the copy reflects how confident the match was, not which check fired.
    private func refuseBotOwnedRouting(for profile: String) {
        let exact = botOwnership.botProfileMatch(for: profile)?.isExact ?? true
        errorMessage = exact
            ? AppLocalization.string(
                "This decision belongs to a Bot Chat. Open Bots to answer it."
            )
            : AppLocalization.string(
                "Could not tell this notification's workspace apart from a Bot Chat. Open Bots or the workspace list to continue."
            )
    }

    /// A push from a Bot Chat opens that Bot Chat the way Bots opens it:
    /// under the bot's own profile, with the workspace left as it is. A
    /// reply opens where it was written, a decision opens where it is
    /// answered (the resume reads the bot's pending approvals and clarify
    /// cards from the gateway), and an answered call opens voice there.
    /// Only a bot positively named as the chat's owner opens: `rowIDs` are
    /// the catalog row's ids, and `canonicalProfile` is a profile the
    /// gateway confirmed this is the canonical chat of. A chat that only
    /// carries the reserved title proves no owner and stays refused, and so
    /// does a reply or decision whose profile names the owner only with case
    /// folded: on a case-sensitive host that is a different profile. A call
    /// keeps opening as it did before, by the chat's ids alone. A decision
    /// the push carries is recorded for the bot's chat before it opens.
    func routeBotOwnedNotification(
        _ target: ConduitNotificationTarget,
        notifiedProfile: String,
        rowIDs: Set<String> = [],
        canonicalProfile: String? = nil,
        attemptID: UUID,
        transitionGeneration: UInt64
    ) async -> NotificationOpenOutcome {
        guard let bot = botOwningNotificationTarget(target, rowIDs: rowIDs, canonicalProfile: canonicalProfile),
              target.call != nil || !Self.namesProfileOnlyWithCaseFolded(notifiedProfile, bot: bot) else {
            refuseBotOwnedRouting(for: notifiedProfile)
            return .failed
        }
        if target.call != nil {
            HermesCallTrace.shared.note("Call from a Bot Chat: opening it in Bots")
        }
        // A decision raised while the app was backgrounded rides the push
        // (a relay clarify exists nowhere else), so its card is recorded in
        // the bot's namespace under the id the push named, and the open
        // promotes it into the chat, as the workspace route does.
        let requestedID = target.sessionId
        var migrationIDs: Set<String> = []
        if let decision = target.decision {
            recordNotificationDecision(
                decision,
                sessionIDs: [requestedID] + [target.durableSessionID].compactMap { $0 },
                cacheSessionIDs: [requestedID],
                profile: bot.name
            )
            migrationIDs = [requestedID]
        }
        guard await openBotChat(
            for: bot,
            presentationMigrationSessionIDs: migrationIDs,
            viewportTransitionGeneration: transitionGeneration
        ) else {
            // A failed open evicts the pre-open card, as the workspace route
            // does, so no later open promotes it from the push-named id.
            if let decision = target.decision,
               let evictionKey = Self.pendingDecisionEvictionKey(for: decision) {
                sessionPresentationCache.removePendingDecision(
                    key: evictionKey,
                    profile: bot.name,
                    sessionIDs: [requestedID]
                )
            }
            return .retry
        }
        // The resume restores cards only from the chat's tip ids, and the
        // card may sit under the durable id the push named. Once the chat is
        // on screen, a relay clarify still missing is recorded under the open
        // chat's own ids and merged into its transcript. Approvals are left
        // to the gateway's pending list, which the open already read.
        // A newer notification tap that replaced this attempt owns the
        // screen: the cache is still settled, but nothing is published over
        // it. (The chat open reused this attempt's viewport transition, so a
        // newer chat open already superseded it before it selected a chat.)
        let attemptIsCurrent = activeNotificationOpenAttemptID == attemptID
        if let decision = target.decision,
           let evictionKey = Self.pendingDecisionEvictionKey(for: decision),
           let openID = activeSessionId,
           activeBotChatProfile == bot.name {
            let openIDs = presentationCacheSessionIDs(for: openID)
            // Hermes' own card for the question already on screen means the
            // copy stays out: one question is one card.
            let hermesCardIsThere = Self.notificationClarifyActivity(for: decision).map { pushed in
                messages.contains { message in
                    guard let live = message.clarify,
                          !live.requestId.hasPrefix(PendingDecisionPayload.relayRequestPrefix) else { return false }
                    return Self.pushCardSupersededBy(pushed, live: live)
                }
            } ?? false
            if hermesCardIsThere {
                sessionPresentationCache.removePendingDecision(
                    key: evictionKey,
                    profile: bot.name,
                    sessionIDs: [requestedID] + [target.durableSessionID].compactMap { $0 } + openIDs
                )
            }
            let restoresClarify = evictionKey.hasPrefix("clarify:")
                && !hermesCardIsThere
                && !messages.contains(where: { SessionPresentationCache.decisionKey(for: $0) == evictionKey })
            if restoresClarify {
                recordNotificationDecision(
                    decision,
                    sessionIDs: [requestedID] + [target.durableSessionID].compactMap { $0 } + openIDs,
                    cacheSessionIDs: openIDs,
                    profile: bot.name
                )
            }
            // A pre-open copy the open did not promote (a joined flight
            // carries the first caller's ids only) is dropped rather than
            // left to linger under the push-named id.
            let trimmedRequestedID = requestedID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !openIDs.contains(where: {
                $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedRequestedID
            }) {
                sessionPresentationCache.removePendingDecision(
                    key: evictionKey,
                    profile: bot.name,
                    sessionIDs: [requestedID]
                )
            }
            if restoresClarify, attemptIsCurrent {
                messages = sessionPresentationCache.merge(
                    messages,
                    profile: bot.name,
                    sessionIDs: openIDs,
                    includePendingClarifications: true
                )
            }
        }
        guard attemptIsCurrent else { return .retry }
        showSidebar = false
        return .opened
    }

    /// Whether a push's profile stamp differs from the owning bot's name
    /// only by case. An empty stamp names no profile.
    private static func namesProfileOnlyWithCaseFolded(_ profile: String, bot: BotProfile) -> Bool {
        let stamped = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stamped.isEmpty, stamped != name else { return false }
        return stamped.caseInsensitiveCompare(name) == .orderedSame
    }

    /// The roster's bot that owns the chat a push names: the bot whose
    /// canonical chat is one of its ids, else the bot this process
    /// registered for one of them, else the bot of `canonicalProfile`. An id
    /// registered to a bot the roster doesn't list names no other bot.
    private func botOwningNotificationTarget(
        _ target: ConduitNotificationTarget,
        rowIDs: Set<String>,
        canonicalProfile: String?
    ) -> BotProfile? {
        let ids = [target.sessionId, target.durableSessionID].compactMap {
            ChatScrollIdentityNormalization.sessionID($0)
        } + rowIDs.compactMap { ChatScrollIdentityNormalization.sessionID($0) }.sorted()
        if let bot = botOwnership.bot(owningAny: Set(ids)) { return bot }
        if let registered = ids.lazy.compactMap({ self.botConversationProfile(for: $0) }).first {
            return Self.linkedBot(named: registered, in: botRoster)
        }
        return canonicalProfile.flatMap { Self.linkedBot(named: $0, in: botRoster) }
    }

    /// Whether a push's conversation is a bot's canonical chat, by any id the
    /// push carried (the runtime id and the durable row). This is the only
    /// thing that separates a Bot Chat decision from a workspace one: bots are
    /// ordinary Hermes profiles, and the workspace profile itself is on the
    /// roster.
    func notificationTargetIsBotChat(_ target: ConduitNotificationTarget) -> Bool {
        let ids = Set([target.sessionId, target.durableSessionID].compactMap {
            ChatScrollIdentityNormalization.sessionID($0)
        })
        return !ids.isDisjoint(with: botOwnedSessionIDs)
    }

    /// `profile`'s canonical Bot Chat lookup, through the tests' seam when
    /// one is set.
    func botChatLookupRows(_ client: HermesClient, profile: String) async throws -> [BotChatLookupRow] {
        if let findBotChat = chatResumeLifecycleOperations.findBotChat {
            return try await findBotChat(client, profile)
        }
        return try await client.findBotChatSession(profile: profile)
    }

    /// Asks `profile` for its canonical Bot Chat (exact-title lookup, which
    /// the gateway resolves to the lineage tip) and reports whether the push
    /// names it. Throws when the lookup cannot be made or fails.
    func notificationTargetIsCanonicalChat(
        _ target: ConduitNotificationTarget,
        of profile: String
    ) async throws -> Bool {
        guard let client else { throw HermesError.invalidResponse }
        let rows: [BotChatLookupRow]
        if let findBotChat = chatResumeLifecycleOperations.findBotChat {
            rows = try await findBotChat(client, profile)
        } else {
            rows = try await client.findBotChatSession(profile: profile)
        }
        let pushIDs = Set([target.sessionId, target.durableSessionID].compactMap {
            ChatScrollIdentityNormalization.sessionID($0)
        })
        return rows.contains { row in
            row.isCanonicalTitle() && !Set([row.id, row.resolvedID].compactMap {
                ChatScrollIdentityNormalization.sessionID($0)
            }).isDisjoint(with: pushIDs)
        }
    }

    /// What the client can PROVE about a profile a decision wants to switch the
    /// dashboard to. A profile name alone proves nothing: bots are ordinary
    /// Hermes profiles, so only bot evidence (or its verified absence)
    /// distinguishes a workspace from a bot. No production path reads this
    /// verdict any more: notification routing decides by conversation
    /// (`notificationTargetIsBotChat` and the target's canonical lookup) and
    /// reads `botEvidenceIsAvailable` directly. It is retained only as the
    /// test surface pinning that evidence rule's three outcomes.
    func profileOwnershipVerdict(for profile: String) -> ProfileOwnershipVerdict {
        // Positive evidence first, whatever the capability phase says.
        if botOwnership.ownsProfile(profile) { return .botOwned }
        if botModePhase == .gatewayUnsupported {
            // `profiles.list` IS the Bot Mode capability probe: a gateway that
            // does not implement it has no Bot Mode, so no profile on it can be
            // a bot's — refusing every cross-profile route here would break
            // working routing (profiles are discovered over the HTTP bridge,
            // not this RPC) to protect against bots that cannot exist.
            return .ordinary
        }
        // Refusal is case-INsensitive on purpose, and asymmetric on purpose: two
        // Hermes profiles can differ only by case on a case-sensitive host, but
        // refusing a workspace switch is recoverable and visible ("Open Bots…"),
        // while adopting a bot's profile as the dashboard workspace is the
        // failure this path exists to prevent. Audit both directions before
        // changing this to an exact match.
        // Absence means something only when evidence was VERIFIED for this
        // connection: a roster retained across a failed refresh, a reconnect,
        // or a pending probe is stale in the one direction that matters here —
        // a bot registered since the last successful answer would be missing
        // from it and would read as an ordinary workspace. Same predicate as the
        // resume path (`botEvidenceIsAvailable`), so the two cannot drift.
        return botEvidenceIsAvailable ? .ordinary : .unverifiable
    }

    /// The bot profile a conversation's RPCs must ride, from every source of
    /// authority the process has, in order: this process's bot-chat registry
    /// (it opened the conversation and recorded the scope), the roster's
    /// canonical registries, and finally the durable reference the open
    /// persisted — the only authority for a conversation opened in an EARLIER
    /// process, before the connect-time roster load has an answer.
    ///
    /// Nil means an ordinary conversation of the dashboard profile. The
    /// registry alone is not enough: it is cleared at every server-identity
    /// boundary and empty after a relaunch, and resolving a bot chat's scope
    /// as the dashboard profile addresses the wrong store.
    func botScopeProfile(
        forSessionIDs sessionIDs: Set<String>,
        workspaceProfile: String? = nil
    ) -> String? {
        let identityIDs = Set(sessionIDs.compactMap { ChatScrollIdentityNormalization.sessionID($0) })
        guard !identityIDs.isEmpty else { return nil }
        // Registry first, as a plain dictionary lookup: this runs on the
        // presentation path (every stream event resolves a namespace), and
        // building the ownership value there would re-scan the roster for
        // each event. The roster is consulted only on a miss.
        // The fast path answers from this process's own observation, but only
        // while there is no roster to be authoritative about spelling: a scope
        // persisted by a build that case-folded it must not outlive the
        // roster's verbatim `bot.name` (see `botProfileName`).
        if botRoster.isEmpty {
            for id in identityIDs.sorted() {
                if let scope = botChatSessionProfiles[id] { return scope }
            }
        }
        if let rosterScope = botOwnership.botProfileName(owningAny: identityIDs) {
            return rosterScope
        }
        // The durable reference is recorded per WORKSPACE profile, and this is
        // called while opening a conversation that may not be the active one
        // yet (a transition), so the caller names the workspace it is acting
        // in rather than relying on `activeProfile`.
        guard let reference = chatResumeCoordinator.lastSession(for: workspaceProfile ?? activeProfile),
              reference.kind == .bot,
              identityIDs.contains(reference.sessionID) else { return nil }
        return reference.resumeProfileScope
    }

    /// Kept as a computed compatibility surface for views that only need the
    /// currently-running flag. New code should use `turnState` for actions.
    var isBusy: Bool { turnState.isRunning }

    /// Voice from the open chat while its reply runs. A live call works
    /// beside the turn (it hands work to Hermes as jobs; Local Live says
    /// it's busy), but classic voice talks in the chat's own turn, so it
    /// waits for Stop or the end of the reply (#762).
    var voiceWaitsForRunningTurn: Bool {
        Self.voiceWaitsForRunningTurn(isBusy: isBusy, liveEngine: configuredLiveVoiceEngine(profile: activeProfile))
    }

    nonisolated static func voiceWaitsForRunningTurn(isBusy: Bool, liveEngine: VoiceCallEngine?) -> Bool {
        isBusy && liveEngine == nil
    }

    /// The read-only offline copy never accepts input: nothing typed there
    /// could be delivered, and it is not the live conversation. Nor does a
    /// New Chat Hermes hasn't created yet.
    var composerIsEnabled: Bool {
        turnState.acceptsComposerActions && offlineChatPresentation == nil && !showsPendingNewChat
    }

    func composerAction(hasText: Bool, hasAttachments: Bool) -> ComposerAction {
        // A chat on its way takes a message to send once it's ready;
        // attachments wait for the chat itself (AppState+PendingSend.swift).
        if composerWaitsForChat {
            // A waiting send must not hide Stop for a live running turn.
            // Further text still joins the pending message, preserving order.
            if !hasText, turnState.isRunning, composerIsEnabled, isConnected { return .stop }
            return hasText && !hasAttachments ? .send : .unavailable
        }
        guard offlineChatPresentation == nil, !showsPendingNewChat else { return .unavailable }
        // A workstream's turn runs in the plugin: Stop stops it from here.
        if !hasText, !hasAttachments, !turnState.isRunning, composerIsEnabled, isConnected,
           workstreamStoppedByComposer != nil {
            return .stop
        }
        return turnState.composerAction(
            hasText: hasText,
            hasAttachments: hasAttachments,
            busyInputMode: busyInputMode
        )
    }

    var composerPlaceholder: String {
        composerPlaceholder(namingAgent: true)
    }

    /// The placeholder without the agent's or profile's name, for a field
    /// too narrow to hold the whole hint on one line at an accessibility
    /// Text Size (ComposerPlaceholderText).
    var composerShortPlaceholder: String {
        composerPlaceholder(namingAgent: false)
    }

    private func composerPlaceholder(namingAgent: Bool) -> String {
        // A chat on its way takes a message like any chat: the header says
        // Conduit is connecting, and the message says it will send then.
        // A New Chat is the workspace profile's; an open chat waiting on
        // Hermes names its own agent, the bot inside a Bot Chat (issue 2025).
        if composerWaitsForChat {
            let name = composerChatOnScreen == .newChat
                ? profileDisplayName(activeProfile)
                : conversationAgentIdentity.name
            return namingAgent
                ? AppLocalization.string("Message \(name)…")
                : AppLocalization.string("Message…")
        }
        // A saved copy reads as the chat while Hermes is on its way, as a
        // New Chat does; only a real offline state says it is a copy.
        let savedCopyWaits = offlineChatPresentation != nil && (isConnected || isRecoveringConnection)
        if showsPendingNewChat || savedCopyWaits {
            return isConnected
                ? AppLocalization.string("Checking agent activity…")
                : AppLocalization.string("Connecting…")
        }
        if offlineChatPresentation != nil {
            return AppLocalization.string("Read-only saved copy")
        }
        switch turnState {
        case .running:
            if busyInputMode == .queue {
                return namingAgent
                    ? AppLocalization.string("Queue a message for \(conversationAgentIdentity.name)…")
                    : AppLocalization.string("Queue a message…")
            }
            return namingAgent
                ? AppLocalization.string("\(busyInputMode.title) \(conversationAgentIdentity.name)…")
                : AppLocalization.string("\(busyInputMode.title)…")
        case .synchronizing, .reconnecting:
            return AppLocalization.string("Checking agent activity…")
        case .unsupportedGateway:
            return AppLocalization.string("Update Hermes to use chat controls")
        case .idle:
            return namingAgent
                ? AppLocalization.string("Message \(conversationAgentIdentity.name)…")
                : AppLocalization.string("Message…")
        }
    }

    // MARK: - Bot Mode (roster + canonical chat)

    /// Refreshes the roster and the Bot Mode capability phase. Safe to call
    /// on every Bots-surface appearance: an established roster is refreshed
    /// in place, an empty one shows the loading phase. Responses fenced
    /// against the dashboard/profile epoch so a stale async answer can never
    /// describe the wrong server.
    func refreshBotRoster() async {
        if let running = botRosterRefreshFlight {
            // JOIN the in-flight refresh instead of bailing on the
            // single-flight guard. A `.task(id:)` identity change cancels
            // the previous view task while its refresh is in flight; that
            // holder releases the claim without committing a phase, so a
            // replacement that merely returned could strand `.loading`.
            // The work runs unstructured, so the join always sees it run to
            // completion, and its epoch/dashboard guard still discards
            // results captured before a server or dashboard transition.
            await running.task.value
            if botRosterRefreshFlight === running {
                botRosterRefreshFlight = nil
            }
            // A joined refresh that was superseded by an identity
            // transition discards its snapshot and commits nothing; fall
            // through and run once for the current identity instead of
            // leaving the empty roster stuck on `.loading`.
            if !(botRoster.isEmpty && botModePhase == .loading) {
                return
            }
        }
        guard !isRefreshingBotRoster, botRosterRefreshFlight == nil else { return }
        let flight = BotRosterRefreshFlight(task: Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performBotRosterRefresh()
        })
        botRosterRefreshFlight = flight
        await flight.task.value
        if botRosterRefreshFlight === flight {
            botRosterRefreshFlight = nil
        }
    }

    /// The single-flight roster refresh. Runs unstructured (never cancelled
    /// by a view task identity change) and keeps the token-based claim
    /// release: only the holder of the CURRENT token may clear
    /// `isRefreshingBotRoster`, so a superseded or invalidated refresh can
    /// never clear a newer refresh's claim.
    private func performBotRosterRefresh() async {
        let epoch = botRosterEpoch
        let dashboardID = activeDashboardID
        let avatarWriteSerial = profileAvatarWriteSerial
        guard let client, isConnected else {
            // Bots on screen, Hermes' or the kept ones, stay without a word.
            if shownBotRoster.isEmpty, botModePhase != .gatewayUnsupported {
                botModePhase = .failed(
                    message: AppLocalization.string("Connect to Hermes to see your bots.")
                )
            }
            return
        }
        isRefreshingBotRoster = true
        let refreshToken = UUID()
        botRosterRefreshToken = refreshToken
        // Ownership-checked release: only the refresh holding the CURRENT
        // token releases the flag. A refresh superseded by invalidation
        // (token cleared) or by a newer refresh (token replaced) never
        // clears someone else's claim, and no identity transition can
        // strand the flag.
        defer {
            if botRosterRefreshToken == refreshToken {
                botRosterRefreshToken = nil
                isRefreshingBotRoster = false
            }
        }
        if botRoster.isEmpty {
            botModePhase = .loading
        }
        do {
            var snapshot: BotRosterSnapshot?
            // Kept for the Bots list to open on (#1533).
            _ = try await keepingRead(as: KeptRoute.botRoster, profile: KeptRoute.everyProfile, owner: currentDashboardRuntimeOwner()) {
                let read: BotRosterSnapshot
                if let botRoster = self.chatResumeLifecycleOperations.botRoster {
                    read = try await botRoster(client)
                } else {
                    read = try await client.botRoster()
                }
                snapshot = read
                return KeptBotRoster(bots: BotProfile.displayOrder(read.bots), desktopGroups: read.desktopGroups).cappingPictures()
            }
            guard let snapshot, botModeStateIsCurrent(epoch: epoch, dashboardID: dashboardID) else { return }
            // The FULL roster is kept: sessions-list hygiene must know every
            // bot's canonical registry (including meta-hidden bots), while
            // the roster VIEW hides meta-hidden rows for display only.
            // Names first: the roster's didSet publishes the widget, which
            // shows the profile's name.
            adoptProfileHermesNames(snapshot.bots.map { (profile: $0.name, displayName: $0.displayName) })
            adoptProfileBotTitles(snapshot.bots.map { (profile: $0.name, title: $0.botTitle ?? "") })
            botRoster = BotProfile.displayOrder(snapshot.bots)
            readUnreadBotsWork()
            desktopGroupChats = snapshot.desktopGroups
            botRosterSupportsProtocol = snapshot.supportsBotProtocol
            botModePhase = .available
            botRosterVerifiedForCurrentConnection = true
            botRosterRetry.succeeded()
            syncProfileAvatarsWithHermes(rosterWriteSerial: avatarWriteSerial)
        } catch {
            guard botModeStateIsCurrent(epoch: epoch, dashboardID: dashboardID),
                  !Task.isCancelled else { return }
            if HermesClient.isMissingRPCMethod(error) {
                botModePhase = .gatewayUnsupported
            } else if shownBotRoster.isEmpty {
                botModePhase = .failed(
                    message: AppLocalization.string("Could not load bots.")
                )
            } else {
                // An established roster, or the kept one, stays on screen;
                // the failure renders as a non-blocking notice above it.
                botModePhase = .failed(
                    message: AppLocalization.string("Could not refresh bots.")
                )
            }
            if case .failed = botModePhase {
                botRosterRetry.schedule { [weak self] in
                    guard let self, self.isConnected,
                          self.botModeStateIsCurrent(epoch: epoch, dashboardID: dashboardID),
                          case .failed = self.botModePhase else { return }
                    await self.refreshBotRoster()
                }
            }
        }
    }

    private func botModeStateIsCurrent(
        epoch: Int,
        dashboardID: UUID?
    ) -> Bool {
        // The roster is gateway-wide: the epoch (server identity) and the
        // dashboard fence it; the dashboard's own profile selection is
        // irrelevant to a profiles.list answer.
        epoch == botRosterEpoch && dashboardID == activeDashboardID
    }

    // MARK: - Bot management (create / edit / delete / avatars)

    /// Pull-to-refresh: the roster plus every avatar. The roster carries no
    /// avatar version, and another client (Desktop) may have changed one.
    func reloadBotRoster() async {
        botAvatarGeneration &+= 1
        botAvatarsReloadedAt = Date()
        await refreshBotRoster()
    }

    /// How old the pictures may be before opening the Profiles sheet reads
    /// them all again. A picture changed on Desktop shows within this, or
    /// at once on a pull in the Bots list.
    static let botPictureRecheckInterval: TimeInterval = 10 * 60

    /// The Profiles sheet's read each time it opens: the roster, and every
    /// picture again only once they're `botPictureRecheckInterval` old.
    /// Each open used to download every bot's picture, up to 2 MB each
    /// (issue 1967).
    func refreshBotRosterAndStalePictures(now: Date = Date()) async {
        if let reloadedAt = botAvatarsReloadedAt,
           now.timeIntervalSince(reloadedAt) < Self.botPictureRecheckInterval {
            await refreshBotRoster()
        } else {
            await reloadBotRoster()
        }
    }

    /// The bot's picture: the one fetched from its profile, else the copy
    /// of Hermes' picture the profile pictures keep on the phone, so a row
    /// shows it before the fetch, or offline (#1533).
    func botAvatarImage(for bot: BotProfile) -> UIImage? {
        guard bot.hasAvatar else { return nil }
        return botAvatarImages[bot.name] ?? profileAvatarURLs[bot.name].flatMap { ProfileAvatarImageCache.image(at: $0) }
    }

    /// The bot's picture to play where its face is the focus, when it moves
    /// (an APNG made from a GIF or a video, AnimatedAvatar): the phone's copy
    /// of its Hermes picture. Nil for a still.
    func botAvatarPlayback(for bot: BotProfile) -> AnimatedAvatarPlayback? {
        guard bot.hasAvatar else { return nil }
        return profileAvatarPlayback(for: bot.name)
    }

    func profileAvatarPlayback(for profile: String) -> AnimatedAvatarPlayback? {
        guard let url = profileAvatarURLs[profile], ProfileAvatarImageCache.isAnimated(at: url) else { return nil }
        return .file(url, revision: ProfileAvatarImageCache.revision(of: url))
    }

    /// The roster has answered on this dashboard: Hermes' bots, or that it
    /// has no Bot Mode.
    private var botRosterAnswered: Bool {
        botModePhase == .available || botModePhase == .gatewayUnsupported
    }

    /// The bots as the Bots list and chats name them: Hermes' roster, else,
    /// until it answers on this dashboard, the bots it gave last time
    /// (#1533). A kept bot's row opens its Bot Chat; nothing writes it
    /// (`BotProfile.isKeptCopy`).
    var shownBotRoster: [BotProfile] {
        guard botRoster.isEmpty, !botRosterAnswered else { return orderedBots(botRoster) }
        return orderedBots(keptBotRoster()?.bots ?? [])
    }

    /// Desktop's group chats, from the roster or its kept copy, as the bots.
    var shownDesktopGroupChats: [DesktopGroupChat] {
        guard botRoster.isEmpty, !botRosterAnswered else { return desktopGroupChats }
        return keptBotRoster()?.desktopGroups ?? []
    }

    /// Fires when the bots `shownBotRoster` names may have changed: Hermes'
    /// roster, or its answer ending the kept copy's stand-in. @Published
    /// fires before the change lands, so it's read on the next turn; on
    /// subscribing too, with the bots shown then.
    var shownBotRosterChanged: AnyPublisher<Void, Never> {
        Publishers.Merge($botRoster.map { _ in () }, $botModePhase.map { _ in () })
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// The roster kept on this dashboard, decoded once per answer kept, its
    /// main bot going by its Conduit name.
    private func keptBotRoster() -> KeptBotRoster? {
        let mainName = profileDisplayName("default")
        let turn = keptAnswerTurn(KeptRoute.botRoster, profile: KeptRoute.everyProfile)
        let key = "\(activeDashboardID?.uuidString ?? "-")|\(offlineChatCache.removals)|\(turn)|\(mainName)"
        if let memo = keptBotRosterMemo, memo.key == key { return memo.roster }
        var roster = keptRead(KeptBotRoster.self, KeptRoute.botRoster, profile: KeptRoute.everyProfile)
        if let bots = roster?.bots {
            roster?.bots = bots.map { bot in
                var bot = bot
                bot.isKeptCopy = true
                if BotManagement.isDefaultProfile(bot.name) { bot.conduitName = mainName }
                return bot
            }
        }
        keptBotRosterMemo = (key, roster)
        return roster
    }

    /// Loads the bot's picture, retrying a failed fetch a few times with
    /// backoff while the calling view stays on screen (its `.task` cancels
    /// the wait when it goes away).
    func loadBotAvatarRetrying(_ bot: BotProfile) async {
        for delay in [UInt64(0), 3, 10, 30] {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            if Task.isCancelled { return }
            if await loadBotAvatarIfNeeded(bot) { return }
        }
    }

    /// Fetches the bot's picture from its profile's asset store once per
    /// avatar generation. `has_avatar` on the roster row gates the call, so
    /// a bot without a picture costs nothing. Returns false when the
    /// picture is not settled yet (failed, in flight elsewhere, or offline)
    /// and a later retry could help.
    @discardableResult
    func loadBotAvatarIfNeeded(_ bot: BotProfile) async -> Bool {
        let name = bot.name
        guard bot.hasAvatar else {
            if botAvatarImages[name] != nil { botAvatarImages[name] = nil }
            botAvatarFetchedGeneration[name] = nil
            return true
        }
        let generation = botAvatarGeneration
        guard botAvatarFetchedGeneration[name] != generation else { return true }
        // In flight elsewhere or offline: not done yet, so a retrying caller
        // checks again after its backoff instead of trusting the other fetch.
        guard botAvatarFetchInflight[name] != generation,
              let client, isConnected else { return false }
        let epoch = botRosterEpoch
        let dashboardID = activeDashboardID
        let writeMark = profileAvatarLastWrite[name]
        botAvatarFetchInflight[name] = generation
        defer {
            if epoch == botRosterEpoch, botAvatarFetchInflight[name] == generation {
                botAvatarFetchInflight[name] = nil
            }
        }
        do {
            let data = try await client.botAvatar(name: name)
            let image = await Self.botAvatarThumbnail(data)
            guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return true }
            // An older generation's fetch landing late never replaces a newer
            // one, nor a picture this app wrote meanwhile.
            if let fetched = botAvatarFetchedGeneration[name], fetched > generation { return true }
            guard profileAvatarLastWrite[name] == writeMark else { return true }
            // A read with no usable bytes keeps the last picture and is not
            // pinned to the generation, so a retry can still land it.
            guard let data, let image else { return false }
            botAvatarFetchedGeneration[name] = generation
            botAvatarImages[name] = image
            mirrorHermesPicture(data, for: name, dashboardID: dashboardID)
            // Rooms over Links show it too (digest-gated, RoomLooks.swift).
            Task { await self.shareRoomLooksIfNeeded() }
            return true
        } catch {
            // Not pinned to the generation, so the caller can retry; whatever
            // picture is shown stays. (`has_avatar` and `profiles.get_asset`
            // ship together, so a gateway without the method never sends
            // rows that call it.)
            return false
        }
    }

    /// The skills, toolsets and MCP servers a new bot starting from
    /// `profile` would have (`profiles.describe` of that profile).
    func loadBotCapabilities(startingFrom profile: String) async -> BotCapabilities? {
        await readBotDetails(profile: profile)?.capabilities
    }

    /// What `loadBotCapabilities` kept for the profile on this dashboard.
    func keptBotCapabilities(startingFrom profile: String) -> BotCapabilities? {
        keptRead(BotProfileDetails.self, KeptRoute.botDetails, profile: profile)?.capabilities
    }

    /// The profile's installed skills from the dashboard (`/api/skills`),
    /// for the bot editor's Skills page: `profiles.describe` names them
    /// only, and this adds each one's category and description. Kept in
    /// the profile's answers as Capabilities' own read is, so the page
    /// opens on them next time. Nil when the read fails.
    func loadBotSkillDetails(profile: String) async -> [CapabilitySkill]? {
        guard let runtime = currentDashboardRuntimeOwner(),
              let answer = try? await readKeepingAnswer(KeptRoute.skills, profile: profile, owner: runtime) else { return nil }
        return capabilitySkills(from: answer)
    }

    /// What `loadBotSkillDetails` (or Capabilities) kept for the profile on
    /// this dashboard.
    func keptBotSkillDetails(profile: String) -> [CapabilitySkill]? {
        keptAnswer(KeptRoute.skills, profile: profile).map(capabilitySkills(from:))
    }

    /// The MCP catalog and the bot's servers' sign-in state, for Edit Bot's
    /// MCP page, kept for it to open on (#1533). Nil when Hermes doesn't
    /// offer them (an older gateway), so the page keeps its plain on/off
    /// list.
    func loadBotMcpSetup(profile: String) async -> BotMcpSetupSnapshot? {
        guard let client, isConnected else { return nil }
        let operations = chatResumeLifecycleOperations
        // A servers list that failed isn't the bot's servers: the read then
        // keeps nothing, and the page shows Hermes' catalog with the
        // sign-ins kept last time, as a read that failed whole keeps them.
        var serversRead = true
        let answer = try? await keepingRead(
            as: KeptRoute.botMcpSetup,
            profile: profile,
            owner: currentDashboardRuntimeOwner(),
            keeps: { _ in serversRead }
        ) {
            let catalog: [BotMcpCatalogEntry]
            if let read = operations.botMcpCatalog {
                catalog = try await read(client, profile)
            } else {
                catalog = try await client.botMcpCatalog(profile: profile)
            }
            var servers: [BotMcpServerSummary] = []
            do {
                if let read = operations.botMcpServers {
                    servers = try await read(client, profile)
                } else {
                    servers = try await client.botMcpServers(profile: profile)
                }
            } catch {
                serversRead = false
            }
            return BotMcpSetupSnapshot(
                catalog: catalog,
                servers: Dictionary(servers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            )
        }
        guard var setup = answer else { return nil }
        if !serversRead {
            setup.servers = keptBotMcpSetup(profile: profile)?.servers ?? [:]
        }
        return setup
    }

    /// What `loadBotMcpSetup` kept for the bot on this dashboard.
    func keptBotMcpSetup(profile: String) -> BotMcpSetupSnapshot? {
        keptRead(BotMcpSetupSnapshot.self, KeptRoute.botMcpSetup, profile: profile)
    }

    /// A catalog server Hermes added to a bot's profile, kept as Hermes now
    /// holds it (#1533): on in the bot's lists, installed in its catalog,
    /// and, signing in with OAuth, waiting for a sign-in.
    private func keepBotMcpServerAdded(
        _ entry: BotMcpCatalogEntry,
        oauth: Bool,
        profile: String,
        on owner: DashboardRuntimeOwner?
    ) {
        keepWrittenChange(BotProfileDetails.self, KeptRoute.botDetails, profile: profile, on: owner) { details in
            guard !details.capabilities.mcpServers.contains(where: { $0.name == entry.name }) else { return }
            details.capabilities.mcpServers.append(BotCapability(name: entry.name, description: entry.description, enabled: true))
        }
        keepWrittenChange(BotMcpSetupSnapshot.self, KeptRoute.botMcpSetup, profile: profile, on: owner) { setup in
            setup.catalog = setup.catalog.map { listed in
                guard listed.name == entry.name else { return listed }
                return BotMcpCatalogEntry(name: listed.name, description: listed.description, requires: listed.requires, installed: true)
            }
            if oauth {
                setup.servers[entry.name] = BotMcpServerSummary(name: entry.name, auth: "oauth", oauthTokensPresent: false)
            }
        }
    }

    /// Adds a catalog server to the bot's profile with the keys typed for
    /// it (Desktop's Set Up): Hermes writes it at once, as on Desktop, so
    /// it stays even when the editor is cancelled. Blank keys are skipped.
    func addBotMcpServer(
        profile: String,
        entry: BotMcpCatalogEntry,
        keys: [String: String]
    ) async -> BotMcpInstallOutcome {
        guard let client, isConnected else {
            return .failed(AppLocalization.string("Connect to Hermes to manage bots."))
        }
        // Every step is checked against the Hermes it started on: after a
        // switch, keys and tests must not go to the other one.
        let epoch = botRosterEpoch
        let owner = currentDashboardRuntimeOwner()
        let moved = BotMcpInstallOutcome.failed(AppLocalization.string("Conduit switched to another Hermes, so the setup stopped."))
        var oauth = false
        if !entry.installed {
            do {
                let added = try await client.addBotMcpServer(profile: profile, name: entry.name, preset: entry.name)
                oauth = BotMcpSetup.addedServer(from: added, name: entry.name)?.auth?.lowercased() == "oauth"
                keepBotMcpServerAdded(entry, oauth: oauth, profile: profile, on: owner)
            } catch {
                return .failed(AppLocalization.string("Could not add \(entry.name): \(UserFacingError.message(for: error))"))
            }
        } else if let summary = (try? await client.botMcpServers(profile: profile))?.first(where: { $0.name == entry.name }) {
            oauth = summary.auth?.lowercased() == "oauth"
        }
        for envVar in entry.requires {
            let value = (keys[envVar] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return moved }
            do {
                try await client.setBotMcpKey(profile: profile, name: entry.name, envVar: envVar, value: value)
            } catch {
                return .addedWithProblem(AppLocalization.string("Could not save \(envVar): \(UserFacingError.message(for: error))"))
            }
        }
        if oauth { return .needsSignIn }
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return moved }
        do {
            let tested = BotMcpSetup.testResult(try await client.testBotMcpServer(profile: profile, name: entry.name))
            return tested.ok
                ? .ready
                : .addedWithProblem(tested.error ?? AppLocalization.string("It did not connect."))
        } catch {
            return .addedWithProblem(UserFacingError.message(for: error))
        }
    }

    /// Signs a bot's OAuth MCP server in. Hermes runs the flow and keeps the
    /// tokens; the browser comes back to a loopback on this phone, which
    /// hands the redirect to Hermes (`client_redirect_uri`, as Desktop does
    /// for a remote Hermes). `open` shows the sign-in page.
    func signInBotMcpServer(
        profile: String,
        name: String,
        open: @MainActor (URL) -> Void
    ) async -> BotMcpSignInOutcome {
        guard let client, isConnected else {
            return .failed(AppLocalization.string("Connect to Hermes to manage bots."))
        }
        let epoch = botRosterEpoch
        let owner = currentDashboardRuntimeOwner()
        let outcome = await NativeMCPSignIn.run(
            profile: profile, name: name,
            rpc: { try await client.botMcpOAuth($0, params: $1) },
            isCurrent: { self.botOpenFenceIsCurrent(epoch: epoch, client: client) },
            open: open
        )
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else {
            return .failed(AppLocalization.string("Conduit switched to another Hermes, so the setup stopped."))
        }
        if outcome == .signedIn { keepMcpSignedIn(profile: profile, name: name, on: owner) }
        return outcome
    }

    /// A sign-in Hermes took, from Edit Bot or the Connectors page: the
    /// bot editor's MCP page opens on it signed in (#1533, #1640).
    func keepMcpSignedIn(profile: String, name: String, on owner: DashboardRuntimeOwner?) {
        keepWrittenChange(BotMcpSetupSnapshot.self, KeptRoute.botMcpSetup, profile: profile, on: owner) {
            $0.servers[name] = BotMcpServerSummary(name: name, auth: "oauth", oauthTokensPresent: true)
        }
    }

    /// `profiles.describe` for the edit sheet: the description and SOUL.md.
    func loadBotDetails(_ bot: BotProfile) async -> BotProfileDetails? {
        await readBotDetails(profile: bot.name)
    }

    /// What `loadBotDetails` kept for the bot on this dashboard: what the
    /// editor shows until Hermes answers.
    func keptBotDetails(_ bot: BotProfile) -> BotProfileDetails? {
        keptRead(BotProfileDetails.self, KeptRoute.botDetails, profile: bot.name)
    }

    /// Settings > Edit profile > Personality: the profile's SOUL.md, read
    /// and kept as Edit Bot reads it, so both open on the same copy.
    func loadProfileSoul(_ profile: String) async -> String? {
        await readBotDetails(profile: profile)?.soul
    }

    /// What Edit Bot or Edit profile kept of the profile's SOUL.md.
    func keptProfileSoul(_ profile: String) -> String? {
        keptRead(BotProfileDetails.self, KeptRoute.botDetails, profile: profile)?.soul
    }

    /// Whether Settings > Edit profile can edit the profile's SOUL.md: it's
    /// written as Edit Bot writes it, through the bot-profile calls.
    var canEditProfileSoul: Bool {
        botModePhase == .available && isConnected
    }

    /// Edit profile's Personality save: only the SOUL, as Edit Bot's
    /// `profiles.configure` writes it, kept for both to open on next.
    /// Returns a message when it was not saved.
    func saveProfileSoul(_ soul: String, profile: String) async -> String? {
        guard let client, isConnected else {
            return AppLocalization.string("Connect to Hermes to change the personality.")
        }
        let owner = currentDashboardRuntimeOwner()
        let result: AnyCodable
        do {
            if let configure = chatResumeLifecycleOperations.configureBotSections {
                result = try await configure(client, profile, ["soul": soul])
            } else {
                result = try await client.configureBotProfile(name: profile, soul: soul)
            }
        } catch {
            return AppLocalization.string("The personality was not saved: \(UserFacingError.message(for: error))")
        }
        guard client === self.client else {
            // Conduit moved to another Hermes mid-save: its outcome is unknown.
            return AppLocalization.string("The personality was not saved.")
        }
        guard BotConfigureSections.failed(in: result, among: ["soul"]).isEmpty else {
            return AppLocalization.string("The personality was not saved.")
        }
        keepBotDetailsWritten(profile, on: owner) { $0.soul = soul }
        return nil
    }

    /// `profiles.describe` of a profile, kept in that profile's answers for
    /// the bot editor to open on (#1533), so a deleted bot takes its own.
    private func readBotDetails(profile: String) async -> BotProfileDetails? {
        guard let client, isConnected else { return nil }
        return try? await keepingRead(as: KeptRoute.botDetails, profile: profile, owner: currentDashboardRuntimeOwner()) {
            if let read = self.chatResumeLifecycleOperations.describeBotProfile { return try await read(client, profile) }
            return try await client.describeBotProfile(name: profile)
        }
    }

    /// A bot's details as Hermes took a write to them, kept for the editor
    /// to open on next time, even if the read after it fails.
    private func keepBotDetailsWritten(
        _ profile: String,
        on owner: DashboardRuntimeOwner?,
        _ change: (inout BotProfileDetails) -> Void
    ) {
        keepWrittenChange(BotProfileDetails.self, KeptRoute.botDetails, profile: profile, on: owner, change)
    }

    /// Asks Hermes whether it can generate pictures (`image.generate`
    /// probe). Asked each time a picture screen opens: the owner may set a
    /// backend up meanwhile. Nil when Hermes wasn't asked (offline, or the
    /// server changed), so no screen says to set a backend up.
    @discardableResult
    func refreshPictureGeneration() async -> Bool? {
        guard let client, isConnected else { return nil }
        let available = await client.imageGenerationAvailable()
        // The answer belongs to the server it came from.
        guard self.client === client else { return nil }
        // No answer keeps the last one: only Hermes saying no hides Generate.
        if let available, canGeneratePictures != available { canGeneratePictures = available }
        return available
    }

    /// One generated picture from `prompt`, decoded. Throws with a message
    /// fit to show.
    func generatePicture(prompt: String) async throws -> UIImage {
        guard let client, isConnected else {
            throw PictureGenerationError(message: AppLocalization.string("Connect to Hermes to generate pictures."))
        }
        let result: AnyCodable
        do {
            result = try await client.generateImage(prompt: prompt)
        } catch {
            throw PictureGenerationError(message: AppLocalization.string(
                "Could not generate a picture: \(UserFacingError.message(for: error))"
            ))
        }
        let data: Data
        switch PictureGeneration.outcome(of: result) {
        case .image(let bytes):
            data = bytes
        case .remote(let url):
            // Bounded like any picture Conduit fetches: the backend's URL
            // could answer with anything.
            guard case .downloaded(let bytes, _) = await MediaPreviewPresenter.boundedDownloadResult(url) else {
                throw PictureGenerationError(message: AppLocalization.string("The picture was made but could not be downloaded."))
            }
            // The server may have changed during the download.
            guard !Task.isCancelled, self.client === client, isConnected else {
                throw PictureGenerationError(message: AppLocalization.string("Connect to Hermes to generate pictures."))
            }
            data = bytes
        case .failed(let reason):
            if let reason {
                throw PictureGenerationError(message: AppLocalization.string("Could not generate a picture: \(reason)"))
            }
            throw PictureGenerationError(message: AppLocalization.string("Could not generate a picture."))
        }
        guard let image = UIImage(data: data) else {
            throw PictureGenerationError(message: AppLocalization.string("That picture could not be used."))
        }
        return image
    }

    /// The profile id a new bot named `name` gets, and whether it is free.
    func newBotSlug(for name: String) -> (slug: String, isValid: Bool, isTaken: Bool) {
        let slug = BotProfileSlug.slug(from: name)
        let taken = botRoster.contains { $0.name.caseInsensitiveCompare(slug) == .orderedSame }
            || profiles.contains { $0.caseInsensitiveCompare(slug) == .orderedSame }
        return (slug, BotProfileSlug.isValid(slug), taken)
    }

    /// Creates a bot the way Desktop's New Bot dialog does: the profile
    /// (`profiles.create`, with a composed SOUL), then its look in ui_meta
    /// and its picture in the asset store. The look and picture are
    /// best-effort — the bot exists either way and Edit can finish the job —
    /// so their failures come back as a warning, not a failure.
    func createBot(_ draft: BotEditorDraft) async -> BotSaveResult {
        guard let client, isConnected else {
            return .failed(AppLocalization.string("Connect to Hermes to manage bots."))
        }
        let identity = newBotSlug(for: draft.name)
        guard identity.isValid else {
            return .failed(AppLocalization.string("Give the bot a name with at least one letter or number."))
        }
        guard !identity.isTaken else {
            return .failed(AppLocalization.string("A profile named \(identity.slug) already exists."))
        }
        let slug = identity.slug
        let title = BotProfileSlug.title(forName: draft.name)
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let soul = BotSoul.compose(
            name: slug,
            title: title,
            description: description,
            customSoul: draft.soul,
            serverInjectsProtocol: botRosterSupportsProtocol,
            roster: botRoster
        )
        let epoch = botRosterEpoch
        let createParams = BotCreateRequest.params(slug: slug, description: description, soul: soul, draft: draft)
        let modelPinned: Bool
        do {
            let created = try await client.createBotProfile(params: createParams)
            modelPinned = BotCreateRequest.modelPinned(createParams, result: created)
        } catch {
            return .failed(AppLocalization.string("Could not create the bot: \(UserFacingError.message(for: error))"))
        }
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else {
            // The server changed mid-save: the bot exists, its look,
            // picture and staged tool choices were never written.
            var warning = AppLocalization.string(
                "The bot was created, but its picture or look was not saved. Edit the bot to try again."
            )
            if let edited = draft.capabilities, let baseline = draft.capabilitiesBaseline,
               !BotCapabilities.configureParams(original: baseline, edited: edited).isEmpty {
                warning += " " + AppLocalization.string("The skills, tools or MCP choices were not saved.")
            }
            return .saved(warning: warning)
        }

        // The picture goes first so ui_meta only claims a photo the asset
        // store actually holds (Desktop renders from `imageKind`).
        var photoSaved = true
        if let png = draft.newAvatarPNG {
            photoSaved = await storeBotAvatar(png, for: slug, client: client, epoch: epoch)
        }
        var meta: [String: Any] = ["created": Int(Date().timeIntervalSince1970 * 1000)]
        if !title.isEmpty { meta["title"] = title }
        if let color = draft.color {
            meta["color"] = color
            meta["custom"] = true
        }
        if draft.newAvatarPNG != nil, photoSaved {
            meta["imageKind"] = "photo"
            meta["custom"] = true
        }
        // Skills, tools and MCP picks staged from the Start From profile
        // ride the same write; the profile holds the source's set already.
        var sections: [String: Any] = [:]
        if let edited = draft.capabilities, let baseline = draft.capabilitiesBaseline {
            sections = BotCapabilities.configureParams(original: baseline, edited: edited)
            // Skipping the bundled skills leaves nothing to toggle.
            if draft.noSkills { sections["disabled_skills"] = nil }
        }
        var lookSaved = true
        var capabilitiesSaved = true
        do {
            let result = try await client.configureBotProfile(name: slug, botMeta: meta, sections: sections)
            lookSaved = BotMetaWriteOutcome(configureResult: result) != .failed
            capabilitiesSaved = BotConfigureSections.failed(
                in: result,
                among: BotCapabilities.appliedSections(for: sections)
            ).isEmpty
        } catch {
            lookSaved = false
            capabilitiesSaved = sections.isEmpty
        }
        // The introduction is a real model turn: a bot whose profile has no
        // usable model skips it and says so, instead of a failed first turn.
        let needsModel = BotRuntimeCheck.needsModel(await client.botRuntimeCheck(profile: slug))
        await refreshBotRosterAfterWrite()
        await loadProfiles()
        var warnings: [String] = []
        if !lookSaved || !photoSaved {
            warnings.append(AppLocalization.string(
                "The bot was created, but its picture or look was not saved. Edit the bot to try again."
            ))
        }
        if !modelPinned {
            warnings.append(AppLocalization.string("The model was not saved."))
        }
        if !capabilitiesSaved {
            warnings.append(AppLocalization.string("The skills, tools or MCP choices were not saved."))
        }
        if needsModel {
            warnings.append(AppLocalization.string(
                "No model is ready for this bot yet, so it skipped its introduction. Edit the bot and pick a model."
            ))
        }
        return .saved(warning: warnings.isEmpty ? nil : warnings.joined(separator: " "), needsModel: needsModel)
    }

    /// A just-created bot's Bot Chat, opened as from the list that marked
    /// it (`openBotChatFromList`), and with `introduces` its first turn:
    /// Desktop's kickoff ("Hey, tell me about yourself!"), sent only into
    /// the new bot's own empty chat.
    func openNewBotChat(for bot: BotProfile, introduces: Bool) async {
        guard await openBotChatFromList(bot), introduces,
              let sessionId = activeSessionId,
              botChatSessionProfiles[sessionId]?.caseInsensitiveCompare(bot.name) == .orderedSame,
              messages.isEmpty, !turnState.isRunning else { return }
        _ = await submitComposer(text: AppLocalization.string("Hey, tell me about yourself!"))
    }

    /// Pins the bot's own model (`profiles.configure` model + provider).
    /// A guarded pick comes back as `.confirmModel` with the gateway's
    /// message until it is resent `confirmed`. `refreshesRoster` false
    /// leaves the roster refresh to a caller that writes more.
    func saveBotModel(
        _ bot: BotProfile,
        provider: String,
        model: String,
        confirmed: Bool,
        refreshesRoster: Bool = true
    ) async -> BotSaveResult {
        guard let client, isConnected else {
            return .failed(AppLocalization.string("Connect to Hermes to manage bots."))
        }
        let owner = currentDashboardRuntimeOwner()
        do {
            let result = try await client.configureBotModel(
                name: bot.name,
                provider: provider,
                model: model,
                confirmed: confirmed
            )
            if let message = BotModelConfirmation.message(in: result) { return .confirmModel(message) }
            let saved = BotConfigureSections.failed(in: result, among: ["model"]).isEmpty
            // The editor opens on the model Hermes took (#1533).
            if saved {
                keepBotDetailsWritten(bot.name, on: owner) { details in
                    details.provider = provider
                    details.model = model
                }
            }
            if refreshesRoster { await refreshBotRosterAfterWrite() }
            guard saved else { return .saved(warning: AppLocalization.string("The model was not saved.")) }
            return .saved(warning: nil)
        } catch {
            return .saved(warning: AppLocalization.string("The model was not saved."))
        }
    }

    /// Saves the edit sheet: ui_meta (title, color, picture kind) as a
    /// compare-and-swap against the roster snapshot, the description and
    /// SOUL only when they changed, and the picture through the asset store.
    func updateBot(
        _ bot: BotProfile,
        draft: BotEditorDraft,
        loadedDetails: BotProfileDetails?
    ) async -> BotSaveResult {
        guard let client, isConnected, !bot.isKeptCopy else {
            return .failed(AppLocalization.string("Connect to Hermes to manage bots."))
        }
        let epoch = botRosterEpoch
        var problems: [String] = []
        // Ordering keeps ui_meta's `imageKind` (what Desktop renders from)
        // from ever claiming a photo the asset store lacks: a new picture is
        // uploaded before `imageKind = photo` is written, and a removal
        // deletes the asset only after `imageKind = shape` is confirmed.
        var uploaded = false
        if let png = draft.newAvatarPNG {
            uploaded = await storeBotAvatar(png, for: bot.name, client: client, epoch: epoch)
            if !uploaded {
                problems.append(AppLocalization.string("The picture was not saved."))
            }
        }
        let removing = draft.newAvatarPNG == nil && draft.removesAvatar
        var patch: [String: Any?] = [:]
        let title = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if title != (bot.botTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines) {
            patch.updateValue(title.isEmpty ? nil : title, forKey: "title")
        }
        if draft.color != bot.appearanceColor {
            patch.updateValue(draft.color, forKey: "color")
            patch["custom"] = true
        }
        let changesNameOrColor = !patch.isEmpty
        if uploaded {
            patch["imageKind"] = "photo"
            patch["custom"] = true
        } else if removing {
            patch["imageKind"] = "shape"
        }
        let originalDescription = loadedDetails?.description ?? bot.profileDescription
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionChanged = description != originalDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // SOUL is only editable once `profiles.describe` answered, so an
        // unloaded editor can never blank a bot's personality.
        let soulChanged = loadedDetails.map { draft.soul != $0.soul } ?? false
        let owner = currentDashboardRuntimeOwner()
        let capabilitySections = loadedDetails.flatMap { details in
            draft.capabilities.map { BotCapabilities.configureParams(original: details.capabilities, edited: $0) }
        } ?? [:]
        let modelChanged = loadedDetails.map { details in
            !draft.provider.isEmpty && !draft.model.isEmpty
                && (draft.provider != details.provider || draft.model != details.model)
        } ?? false
        /// The later writes a save that stops early never reaches.
        func laterWritesSkipped() -> [String] {
            var skipped: [String] = []
            if !capabilitySections.isEmpty {
                skipped.append(AppLocalization.string("The skills, tools or MCP choices were not saved."))
            }
            if modelChanged { skipped.append(AppLocalization.string("The model was not saved.")) }
            return skipped
        }

        /// The warnings for a meta write that did not land.
        func metaNotSaved() -> [String] {
            var notes: [String] = []
            if changesNameOrColor {
                notes.append(AppLocalization.string("The name or color was not saved."))
            }
            if uploaded {
                notes.append(AppLocalization.string("The picture was saved, but its look was not."))
            }
            if removing {
                notes.append(AppLocalization.string("The picture was not removed."))
            }
            return notes
        }

        var metaPersisted = patch.isEmpty
        if !patch.isEmpty || descriptionChanged || soulChanged {
            do {
                let result = try await client.configureBotProfile(
                    name: bot.name,
                    botMeta: patch.isEmpty ? nil : BotMetaPatch.merged(existing: bot.botMeta, patch: patch),
                    expectedMetaRevision: patch.isEmpty ? nil : bot.botMetaRevision,
                    description: descriptionChanged ? description : nil,
                    soul: soulChanged ? draft.soul : nil
                )
                guard botOpenFenceIsCurrent(epoch: epoch, client: client) else {
                    // The server changed mid-save: the meta write's outcome
                    // is unknown, so a pending removal never runs.
                    problems += metaNotSaved() + laterWritesSkipped()
                    return .saved(warning: problems.isEmpty ? nil : problems.joined(separator: " "))
                }
                var sections: [String] = []
                if descriptionChanged { sections.append("description") }
                if soulChanged { sections.append("soul") }
                let failed = BotConfigureSections.failed(in: result, among: sections)
                if !failed.isEmpty {
                    problems.append(AppLocalization.string("The description or personality was not saved."))
                }
                // What Hermes took is what the editor opens on next (#1533).
                if failed.count < sections.count {
                    keepBotDetailsWritten(bot.name, on: owner) { details in
                        if descriptionChanged, !failed.contains("description") { details.description = description }
                        if soulChanged, !failed.contains("soul") { details.soul = draft.soul }
                    }
                }
                if !patch.isEmpty {
                    var outcome = BotMetaWriteOutcome(configureResult: result)
                    if outcome == .conflict {
                        outcome = await retryBotMetaWrite(bot.name, patch: patch, client: client, epoch: epoch)
                    }
                    metaPersisted = outcome == .persisted || outcome == .unsupported
                    if !metaPersisted {
                        problems += metaNotSaved()
                    }
                }
            } catch {
                guard uploaded else {
                    return .failed(AppLocalization.string("Could not save the bot: \(UserFacingError.message(for: error))"))
                }
                // The picture already landed; only the other fields failed.
                problems += metaNotSaved()
                if descriptionChanged || soulChanged {
                    problems.append(AppLocalization.string("The description or personality was not saved."))
                }
                problems += laterWritesSkipped()
                await refreshBotRosterAfterWrite()
                return .saved(warning: problems.joined(separator: " "))
            }
        }
        // The main profile goes by its Conduit name, so a rename here is
        // that name too.
        if metaPersisted, patch.keys.contains("title"), botOpenFenceIsCurrent(epoch: epoch, client: client) {
            // saveDefaultProfileName renames the main bot's Bot Chats itself,
            // from the title as written: the roster refresh comes later.
            if BotManagement.isDefaultProfile(bot.name) {
                var titles = profileBotTitles
                titles[bot.name] = title.isEmpty || title == bot.name ? nil : title
                if titles != profileBotTitles {
                    profileBotTitles = titles
                    profileAppearanceStore.saveBotTitles(titles, dashboardID: activeDashboardID)
                }
                saveDefaultProfileName(title)
            } else {
                renameCapturedBotChatLabels(for: bot.name, to: title)
            }
        }
        if removing, metaPersisted {
            do {
                try await client.setBotAvatar(name: bot.name, png: nil)
                if botOpenFenceIsCurrent(epoch: epoch, client: client) {
                    forgetHermesPicture(for: bot.name)
                }
            } catch {
                problems.append(AppLocalization.string("The picture was not removed."))
            }
        }
        // The server may have changed during the writes above: the tool
        // choices and the model pick must not land on a same-named bot
        // elsewhere.
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else {
            problems += laterWritesSkipped()
            return .saved(warning: problems.isEmpty ? nil : problems.joined(separator: " "))
        }
        // Skills, tools and MCP: only the sections the user changed, and
        // only once the editor loaded them from the bot itself.
        if !capabilitySections.isEmpty {
            do {
                let result: AnyCodable
                if let configure = chatResumeLifecycleOperations.configureBotSections {
                    result = try await configure(client, bot.name, capabilitySections)
                } else {
                    result = try await client.configureBotProfile(name: bot.name, sections: capabilitySections)
                }
                let sections = BotCapabilities.appliedSections(for: capabilitySections)
                let failed = BotConfigureSections.failed(in: result, among: sections)
                if !failed.isEmpty {
                    problems.append(AppLocalization.string("The skills, tools or MCP choices were not saved."))
                }
                if let edited = draft.capabilities, failed.count < sections.count {
                    keepBotDetailsWritten(bot.name, on: owner) { details in
                        details.capabilities = details.capabilities.taking(sections.filter { !failed.contains($0) }, from: edited)
                    }
                }
            } catch {
                problems.append(AppLocalization.string("The skills, tools or MCP choices were not saved."))
            }
        }
        // And again for the model, after the capabilities await.
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else {
            if modelChanged { problems.append(AppLocalization.string("The model was not saved.")) }
            return .saved(warning: problems.isEmpty ? nil : problems.joined(separator: " "))
        }
        // The model goes last and on its own: a pick the gateway wants
        // confirmed must not hold back the rest of the save.
        if modelChanged {
            switch await saveBotModel(
                bot,
                provider: draft.provider,
                model: draft.model,
                confirmed: false,
                refreshesRoster: false
            ) {
            case .confirmModel(let message):
                await refreshBotRosterAfterWrite()
                // Another part already failed: report that rather than ask.
                guard problems.isEmpty else {
                    problems.append(AppLocalization.string("The model was not saved."))
                    return .saved(warning: problems.joined(separator: " "))
                }
                return .confirmModel(message)
            case .saved(let warning, _):
                if let warning { problems.append(warning) }
            case .failed(let message):
                problems.append(message)
            }
        }
        await refreshBotRosterAfterWrite()
        return .saved(warning: problems.isEmpty ? nil : problems.joined(separator: " "))
    }

    /// Pins or unpins a bot (ui_meta `pinned`, shared with Desktop).
    func setBotPinned(_ bot: BotProfile, pinned: Bool) async -> String? {
        guard let client, isConnected, !bot.isKeptCopy else {
            return AppLocalization.string("Connect to Hermes to manage bots.")
        }
        let epoch = botRosterEpoch
        let patch: [String: Any?] = ["pinned": pinned]
        do {
            let result = try await client.configureBotProfile(
                name: bot.name,
                botMeta: BotMetaPatch.merged(existing: bot.botMeta, patch: patch),
                expectedMetaRevision: bot.botMetaRevision
            )
            var outcome = BotMetaWriteOutcome(configureResult: result)
            if outcome == .conflict {
                outcome = await retryBotMetaWrite(bot.name, patch: patch, client: client, epoch: epoch)
            }
            await refreshBotRosterAfterWrite()
            return outcome == .failed || outcome == .conflict
                ? AppLocalization.string("Could not update \(bot.displayLabel).")
                : nil
        } catch {
            return AppLocalization.string("Could not update \(bot.displayLabel).")
        }
    }

    /// Hides or shows a bot in the Bots list (ui_meta `hidden`, shared with
    /// Desktop). A hidden bot keeps working, stays mentionable and keeps its
    /// group rooms; it just isn't offered for a new group, whose picker
    /// lists visible bots only.
    func setBotHidden(_ bot: BotProfile, hidden: Bool) async -> String? {
        guard let client, isConnected, !bot.isKeptCopy else {
            return AppLocalization.string("Connect to Hermes to manage bots.")
        }
        let epoch = botRosterEpoch
        let patch: [String: Any?] = ["hidden": hidden]
        do {
            let result = try await client.configureBotProfile(
                name: bot.name,
                botMeta: BotMetaPatch.merged(existing: bot.botMeta, patch: patch),
                expectedMetaRevision: bot.botMetaRevision
            )
            var outcome = BotMetaWriteOutcome(configureResult: result)
            if outcome == .conflict {
                outcome = await retryBotMetaWrite(bot.name, patch: patch, client: client, epoch: epoch)
            }
            await refreshBotRosterAfterWrite()
            return outcome == .failed || outcome == .conflict
                ? AppLocalization.string("Could not update \(bot.displayLabel).")
                : nil
        } catch {
            return AppLocalization.string("Could not update \(bot.displayLabel).")
        }
    }

    /// Duplicate (Desktop's `duplicateBot`): a full copy of the bot's profile
    /// as `<name>-2`, with its look and a "(copy)" title. Returns the notice
    /// to show: what was made, or why not.
    func duplicateBot(_ bot: BotProfile) async -> String {
        guard let client, isConnected, !bot.isKeptCopy else {
            return AppLocalization.string("Connect to Hermes to manage bots.")
        }
        guard let name = BotDuplicate.name(for: bot.name, taken: botRoster.map(\.name) + profiles) else {
            return AppLocalization.string("No free name for the copy of \(bot.displayLabel).")
        }
        let epoch = botRosterEpoch
        do {
            _ = try await client.createBotProfile(params: BotDuplicate.createParams(name: name, source: bot))
        } catch {
            return AppLocalization.string("Could not duplicate the bot: \(UserFacingError.message(for: error))")
        }
        var lookSaved = false
        var metaSaved = false
        if botOpenFenceIsCurrent(epoch: epoch, client: client) {
            // A clone copies the config, not the asset store: the photo is
            // copied first, so the look only claims one the copy holds.
            var photoCopied = !bot.hasAvatar
            if bot.hasAvatar, let png = try? await client.botAvatar(name: bot.name),
               botOpenFenceIsCurrent(epoch: epoch, client: client) {
                photoCopied = await storeBotAvatar(png, for: name, client: client, epoch: epoch)
            }
            var result: AnyCodable?
            if botOpenFenceIsCurrent(epoch: epoch, client: client) {
                result = try? await client.configureBotProfile(
                    name: name,
                    botMeta: BotDuplicate.meta(from: bot, photoCopied: photoCopied)
                )
            }
            metaSaved = result.map { BotMetaWriteOutcome(configureResult: $0) != .failed } ?? false
            lookSaved = photoCopied && result.map { BotMetaWriteOutcome(configureResult: $0) != .failed } ?? false
        }
        await refreshBotRosterAfterWrite()
        await loadProfiles()
        if lookSaved {
            return AppLocalization.string("Made \(name), a full copy of \(bot.displayLabel).")
        }
        return metaSaved
            ? AppLocalization.string("Made \(name), a full copy of \(bot.displayLabel), but its picture was not copied.")
            : AppLocalization.string("Made \(name), a full copy of \(bot.displayLabel), but its look was not copied.")
    }

    /// Whether Conduit lets this bot be deleted: never the gateway's primary
    /// profile, and never the profile this dashboard is working in.
    func canDeleteBot(_ bot: BotProfile) -> Bool {
        !bot.isKeptCopy && bot.isDeletable && bot.name.caseInsensitiveCompare(activeProfile) != .orderedSame
    }

    /// Permanently deletes the bot's Hermes profile through the dashboard
    /// (`DELETE /api/profiles/{name}`, the route Desktop's delete uses),
    /// leaving its Bot Chat first if that is the open conversation.
    func deleteBot(_ bot: BotProfile) async -> String? {
        guard canDeleteBot(bot) else {
            return AppLocalization.string("This profile can't be deleted from here.")
        }
        guard let bridge = dashboardTicketBridge, isConnected else {
            return AppLocalization.string("Connect to Hermes to manage bots.")
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let encodedName = bot.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? bot.name
        let dashboardID = activeDashboardID
        let rosterOwner = currentDashboardRuntimeOwner()
        do {
            // The gateway waits up to 10 s for a running profile gateway to
            // stop before removing the directory.
            _ = try await bridge.requestJSON(
                path: "/api/profiles/\(encodedName)",
                method: "DELETE",
                timeoutMilliseconds: 30_000
            )
        } catch {
            return AppLocalization.string("Could not delete \(bot.displayLabel): \(UserFacingError.message(for: error))")
        }
        // Its pinned replies keep reply text: they go while the dashboard
        // is still the open one, even if its bridge was rebuilt meanwhile.
        if activeDashboardID == dashboardID {
            forgetPinnedReplies(profile: bot.name)
            forgetBotChatPinnedReplies(of: bot)
        }
        // Its chats' raw rows, kept for the history page, go on any
        // dashboard, and so do its settings pages' kept answers.
        if let dashboardID {
            offlineChatCache.removeHeldRows(dashboardID: dashboardID, profile: bot.name)
            offlineChatCache.removeKeptAnswers(dashboardID: dashboardID, profile: bot.name)
        }
        // And it leaves the roster kept there, its bridge rebuilt or not.
        forgetKeptBot(bot.name, on: rosterOwner)
        guard dashboardTicketBridge === bridge else { return nil }
        sessionStars.forget(profile: bot.name)
        sessionStars.save(to: defaults)
        if let sessionId = activeSessionId,
           let owner = botChatSessionProfiles[sessionId],
           owner.caseInsensitiveCompare(bot.name) == .orderedSame {
            clearActiveConversation(replacement: .delete)
        }
        forgetHermesPicture(for: bot.name)
        await refreshBotRosterAfterWrite()
        await loadProfiles()
        return nil
    }

    /// Drops a deleted bot from the roster kept on the dashboard it was
    /// deleted from, as a write, so the Bots list doesn't open on it if the
    /// read after the delete fails, nor keeps a read asked before it.
    private func forgetKeptBot(_ name: String, on owner: DashboardRuntimeOwner?) {
        guard let owner else { return }
        guard var kept = keptAnswer(KeptRoute.botRoster, profile: KeptRoute.everyProfile, on: owner),
              let bots = kept["bots"] as? [Any] else {
            noteKeptAnswerWrite(for: KeptRoute.botRoster, profile: KeptRoute.everyProfile, owner: owner)
            return
        }
        kept["bots"] = bots.filter { ($0 as? [String: Any])?["name"] as? String != name }
        keepWrittenAnswer(kept, for: KeptRoute.botRoster, profile: KeptRoute.everyProfile, owner: owner, removals: offlineChatCache.removals)
    }

    /// A Bot Chat's pins are kept under the profile in use, not the bot's,
    /// so deleting the bot drops the ones made in its chats under every
    /// profile (a pin made while another profile was active stays under
    /// that one): the sessions this process saw opened as the bot's, and
    /// its canonical chat.
    func forgetBotChatPinnedReplies(of bot: BotProfile) {
        var ids = Set(botChatSessionProfiles.compactMap { id, owner in
            owner.caseInsensitiveCompare(bot.name) == .orderedSame ? id : nil
        })
        for id in [bot.canonicalSession?.id, bot.canonicalSession?.resolvedID] {
            if let id = ChatScrollIdentityNormalization.sessionID(id) { ids.insert(id) }
        }
        guard !ids.isEmpty else { return }
        var changed = false
        for (profile, stored) in pinnedRepliesByProfile {
            let remaining = stored.filter { !ids.contains($0.sessionID) }
            guard remaining.count != stored.count else { continue }
            pinnedRepliesByProfile[profile] = remaining.isEmpty ? nil : remaining
            changed = true
        }
        guard changed else { return }
        if let reveal = pendingPinnedReplyReveal, ids.contains(reveal.pin.sessionID) {
            pendingPinnedReplyReveal = nil
        }
        persistPinnedReplies()
    }

    /// The largest bot face is 72 pt (Bots Home), and Dynamic Type grows
    /// it; 512 px covers that at 3x. Hermes takes pictures up to 2 MB, and
    /// a 3000 px one decoded whole is 36 MB per bot (#1829).
    nonisolated static let botAvatarMaxPixelSize: CGFloat = 512

    /// A bot's picture decoded once, downsampled and off the main actor, as
    /// the profile photos and room pictures are. Nil for bytes ImageIO
    /// can't read (or that claim more pixels than memory holds).
    nonisolated static func botAvatarThumbnail(_ data: Data?) async -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard case .image(let image) = BoundedRemoteImage.decode(data, maxPixelSize: botAvatarMaxPixelSize)
            else { return nil }
            return image
        }.value
    }

    func storeBotAvatar(_ png: Data, for name: String, client: HermesClient, epoch: Int) async -> Bool {
        // Decoded before the upload, so nothing waits between the upload
        // landing and the picture taking its place.
        let image = await Self.botAvatarThumbnail(png)
        // The generation the write belongs to: a reload that starts while it
        // is in flight must still refetch, in case it read the older asset.
        let generation = botAvatarGeneration
        let dashboardID = activeDashboardID
        // The decode waited: a write mark is by name, so it goes on only
        // while this dashboard is still the one open.
        if botOpenFenceIsCurrent(epoch: epoch, client: client) { noteProfileAvatarWrite(name) }
        do {
            try await client.setBotAvatar(name: name, png: png)
        } catch {
            return false
        }
        guard botOpenFenceIsCurrent(epoch: epoch, client: client) else { return true }
        // Again after it landed: a fetch that started during the upload may
        // have read the older picture.
        noteProfileAvatarWrite(name)
        if let image {
            // The upload is the newest picture, but the recorded generation
            // never moves backwards past a newer fetch.
            botAvatarImages[name] = image
            botAvatarFetchedGeneration[name] = max(botAvatarFetchedGeneration[name] ?? generation, generation)
            mirrorHermesPicture(png, for: name, dashboardID: dashboardID)
            Task { await self.shareRoomLooksIfNeeded() }
        }
        return true
    }
}

extension AppState {
    // MARK: - Resetting Bot Mode's state

    /// Drops all Bot Mode runtime state at a server-identity boundary. The
    /// epoch bump fences every in-flight roster response; in-flight bot
    /// opens are cancelled so a stale flight can never navigate the UI or
    /// mutate state against the outgoing server.
    func invalidateBotModeState() {
        botRosterEpoch += 1
        botRosterRetry.succeeded()
        botWork.clear()
        // Another server's hosts may or may not have a Bot Screen.
        botScreens.reset()
        botRosterVerifiedForCurrentConnection = false
        botChatOpenFlights.values.forEach { $0.task?.cancel() }
        botChatSessionProfiles.removeAll()
        botChatSessionLabels.removeAll()
        botChatOpenFlights.removeAll()
        // Another server's list: an earlier one's failed open isn't its,
        // and the marks its taps made, and the cover over the chat, go
        // with the opens they were for (issue 2085).
        botsListNotice = nil
        botChatOpening = nil
        botChatMarks.removeAll()
        botChatLatestMark = nil
        botChatOnItsWay = nil
        botRoster = []
        botAvatarImages = [:]
        botAvatarFetchedGeneration.removeAll()
        botAvatarFetchInflight.removeAll()
        botRosterSupportsProtocol = false
        botRosterRefreshToken = nil
        // The in-flight refresh, if any, still completes but its epoch guard
        // discards the stale snapshot; drop the join handle so the next
        // identity's first refresh cannot join a dead flight.
        botRosterRefreshFlight = nil
        isRefreshingBotRoster = false
        botModePhase = .idle
        invalidateGroupChatState()
    }
}
