import Foundation

enum ChatResumeBehavior: String, Codable, CaseIterable {
    case continueWhereLeftOff
    case latestActivity
}

extension ChatResumeBehavior {
    var title: String {
        switch self {
        case .continueWhereLeftOff:
            AppLocalization.string("Continue where I left off")
        case .latestActivity:
            AppLocalization.string("Jump to latest activity")
        }
    }
}

enum ChatResumeSyncPurpose: Equatable {
    case automaticReturn
    case preserveCurrent
}

enum ChatResumeSessionResolver {
    /// Returns the persisted continue-where-left-off target when the current
    /// catalog has not caught up with it yet. The caller must resume this
    /// identity directly before considering a different conversation: a
    /// partial cold-start catalog is discovery data, not authority to replace
    /// the conversation the user last selected.
    ///
    /// `botOwnedSessionIDs` are conversations the client can positively
    /// attribute to Bot Mode. They are excluded here for the same reason the
    /// Sessions surface excludes them: a Bot Chat is not this workspace's
    /// conversation, so an id that only positive bot evidence can resolve must
    /// not become the workspace's selected conversation. A bot-typed
    /// reference is restored through the Bot Mode path instead.
    static func missingSavedSessionID(
        in catalog: [SessionSummary],
        behavior: ChatResumeBehavior,
        purpose: ChatResumeSyncPurpose,
        savedSessionID: String?,
        activeProfile: String? = nil,
        botOwnedSessionIDs: Set<String> = [],
        savedSessionAliases: Set<String> = []
    ) -> String? {
        guard purpose == .automaticReturn,
              behavior == .continueWhereLeftOff,
              let savedSessionID = ChatScrollIdentityNormalization.sessionID(savedSessionID) else {
            return nil
        }
        // Bot ownership is tested across the conversation's whole identity set:
        // its durable row, the runtime id a rebind minted, a lineage tip, and
        // the aliases the scroll identity confirms. An alias-only match is
        // still the same conversation.
        let conversationIDs = savedSessionAliases.reduce(into: Set([savedSessionID])) {
            if let normalized = ChatScrollIdentityNormalization.sessionID($1) {
                $0.insert(normalized)
            }
        }
        guard conversationIDs.isDisjoint(with: botOwnedSessionIDs) else { return nil }

        let scoped = activeProfile.map { profile in
            catalog.filter { entry in
                guard let entryProfile = entry.profile else { return true }
                return entryProfile.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(profile.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
        } ?? catalog

        guard !scoped.contains(where: {
            $0.id == savedSessionID || $0.alternateIds.contains(savedSessionID)
        }) else {
            return nil
        }
        return savedSessionID
    }

    static func target(
        in catalog: [SessionSummary],
        behavior: ChatResumeBehavior,
        purpose: ChatResumeSyncPurpose,
        savedSessionID: String?,
        currentSessionID: String?,
        activeProfile: String? = nil,
        botOwnedSessionIDs: Set<String> = [],
        savedSelectionIsAuthoritative: Bool = true,
        unlistedSessionIDs: Set<String> = []
    ) -> SessionSummary? {
        // Filter to the active profile when available so sessions from
        // other profiles don't interfere with ID matching or fallback.
        // Use case-insensitive comparison to match AppState.profilesMatch.
        let scoped = activeProfile.map { profile in
            catalog.filter { entry in
                guard let entryProfile = entry.profile else { return true }
                return entryProfile.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(profile.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            }
        } ?? catalog

        // An UNTYPED stored selection whose bot evidence is unreadable is not
        // authority to adopt a catalog row: the row may be a bot chat this
        // workspace cannot identify (a lineage tip wears no reserved title),
        // so the selection falls through to the ordinary candidates instead.
        // `.preserveCurrent` is unaffected — it addresses what is on screen.
        let requestedID: String? = purpose == .preserveCurrent
            ? currentSessionID
            : (savedSelectionIsAuthoritative ? savedSessionID : nil)
        if purpose == .preserveCurrent || behavior == .continueWhereLeftOff,
           let requestedID,
           let matched = scoped.first(where: {
                $0.id == requestedID || $0.alternateIds.contains(requestedID)
           }) {
            // The saved/current id positively resolves to a row. A row the
            // client knows to be a Bot Chat is NOT this workspace's
            // conversation: the reference's kind (restored through the Bot
            // Mode path) owns it, so ordinary selection declines rather than
            // adopting it here.
            if !BotChatHygiene.isBotOwnedRow(matched, botOwnedSessionIDs: botOwnedSessionIDs) {
                return matched
            }
        }
        if purpose == .preserveCurrent {
            // Catalog absence of an ESTABLISHED current identity is not
            // navigation authority: the caller retains the request-scoped
            // identity and can resume it directly. With no current identity
            // (nil or empty) there is nothing to preserve, so the historical
            // newest-chat selection applies unchanged (and an empty catalog
            // still falls through to session.create).
            if let currentSessionID, !currentSessionID.isEmpty {
                return nil
            }
        }
        // One definition of "this row is a bot's forever chat" for both the
        // sessions surface and this selection: a second copy here could drift
        // and let the two disagree.
        //
        // RESIDUAL, stated because it is the shape of this whole fix: with NO
        // bot evidence at all (an unverified reference and a roster that was
        // never confirmed), these candidates are screened only by the reserved
        // title, so a bot chat whose title moved on is indistinguishable from an
        // ordinary conversation and can be the "latest" one. That is not
        // recoverable from local data — it is why the callers gate the
        // AUTHORITATIVE paths (the saved-id match and the catalog-absent escape
        // hatch) on evidence instead of trusting a guess.
        //
        // A chat the lists leave out (a bot's workstream, #1755, or Pulse's
        // own chat, which the Pulse screen stands in for) is left out of the
        // newest-chat pick the same way: like a Bot Chat it has no row of its
        // own in Chats, search or All profiles, so picking it would open a
        // chat no list names. The caller names those rows by the lists' own
        // rules (AppState.isUnlistedChat). The saved-selection match above
        // still resumes one the user opened.
        return latestChat(
            in: scoped.filter {
                !BotChatHygiene.isBotOwnedRow($0, botOwnedSessionIDs: botOwnedSessionIDs)
                    && !unlistedSessionIDs.contains($0.id)
            }
        )
    }

    /// The workspace's newest conversation, from the authoritative activity
    /// instant when the rows carry one. List position is NOT authoritative:
    /// the sync path prepends a retained active-turn row and merges cached
    /// rows behind live ones, so "first row" can name a conversation the
    /// server did not order first. Rows without a machine-readable timestamp
    /// rank behind every timestamped one (and, when NO candidate carries one,
    /// the historical first-row behavior stands — the server's own ordering is
    /// then the only evidence there is).
    ///
    /// Locally-created rows (a new conversation, a branch) are stamped with
    /// their creation instant, so a conversation whose first turn is in flight
    /// still outranks older dated rows. Equal instants keep the earliest
    /// catalog row (strict `>`), which is deterministic and pinned by test.
    static func latestChat(in rows: [SessionSummary]) -> SessionSummary? {
        let chats = rows.filter { $0.source == .chat }
        guard !chats.isEmpty else { return nil }
        var best: (row: SessionSummary, at: TimeInterval)?
        for row in chats {
            guard let at = row.lastActivityAt else { continue }
            guard let current = best else {
                best = (row, at)
                continue
            }
            if at > current.at {
                best = (row, at)
            }
        }
        return best?.row ?? chats.first
    }
}

enum ChatResumeViewportDestination: Equatable {
    case latest
    case anchor(String)
}

enum ChatResumeViewportResolver {
    static func destination(
        for snapshot: ChatScrollSnapshot,
        availableTargets: ChatScrollTargetAvailability
    ) -> ChatResumeViewportDestination {
        guard !snapshot.followsLatest else { return .latest }
        if let anchor = snapshot.anchorMessageID,
           availableTargets.contains(anchor),
           snapshot.anchorMetadata == nil
            || availableTargets.metadata(for: anchor) == snapshot.anchorMetadata {
            return .anchor(anchor)
        }

        guard let sourceMessageID = snapshot.anchorSourceMessageID,
              let refreshedAnchor = availableTargets.semanticID(
                forSourceMessageID: sourceMessageID
              ),
              availableTargets.metadata(for: refreshedAnchor) != nil else {
            return .latest
        }
        return .anchor(refreshedAnchor)
    }
}
