//
//  AppState+V2Shell.swift
//  Conduit
//
//  Read-only lookups the V2 navigation shell draws from. They add no state:
//  everything here derives from the catalog, read state and roster AppState
//  already owns.
//

import SwiftUI

extension AppState {
    /// The color the backdrop's warm glow takes for a profile: the one
    /// picked for it or drawn from its photo (`profileGlowColors`), else the
    /// color its bot was given in Hermes, or nil (the gold accent). The bot
    /// branch resolves the roster row like every other bot lookup
    /// (`linkedBot`), so it also answers a RENAME — an old name surviving
    /// only in previousNames — and it applies to any profile name that
    /// resolves to a roster bot, a workspace profile's name included.
    func profileGlowTint(_ profile: String) -> Color? {
        if let glow = profileGlowColors()[profile] { return glow.color }
        // The common case has no roster at all: one check, no passes.
        guard !botRoster.isEmpty else { return nil }
        guard let bot = Self.linkedBot(named: profile, in: botRoster),
              let color = bot.appearanceColor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !color.isEmpty else { return nil }
        return BotAvatarView.color(for: color, name: bot.name)
    }

    /// Which of `profiles` have a listed conversation with activity the
    /// user hasn't seen. Only rows this device has listed count, so a profile
    /// never opened here shows no dot rather than a guess (All lists the
    /// other profiles' rows). One walk of the
    /// catalog for the whole profile strip, which redraws with every top bar.
    func profilesWithUnread(among profiles: [String]) -> Set<String> {
        var unread = Set<String>()
        // Owners repeat across rows, so each distinct one is matched once.
        var profilesByOwner: [String: [String]] = [:]
        // All's combined read lists the other profiles' rows too.
        let others = isAllProfilesChatsOn && allProfilesCatalog.dashboardID == activeDashboardID
            ? allProfilesCatalog.sessions : []
        for session in sessions + others {
            guard unread.count < profiles.count else { break }
            guard let owner = session.profile else { continue }
            let matched: [String]
            if let known = profilesByOwner[owner] {
                matched = known
            } else {
                matched = profiles.filter { profilesMatch(owner, $0) }
                profilesByOwner[owner] = matched
            }
            for profile in matched where !unread.contains(profile) {
                if chatReadState.isUnread(session, profile: profile) { unread.insert(profile) }
            }
        }
        return unread
    }

    /// Whether a voice call's screen is up or on its way up. Opening a call
    /// uncovers the chat the old drawer hid; the V2 shell keeps its list.
    var isVoiceCallScreenPresented: Bool {
        showVoiceSheet || showQwenLiveSheet || showGeminiLiveSheet || showGPTLiveSheet || showGrokLiveSheet || showLocalLiveSheet
    }

    /// The conversation a nested row (a call's job, a chat's call) sits
    /// under in the session list, for the gold "back to parent" link.
    func nestingParent(of session: SessionSummary) -> SessionSummary? {
        guard let key = sessionNestingParentKey(for: session), !key.isEmpty else { return nil }
        let candidates = activeProfileSessions + activeProfileCronSessions
        return candidates.first { candidate in
            candidate.id != session.id && (candidate.id == key || candidate.storedSessionId == key)
        }
    }
}
