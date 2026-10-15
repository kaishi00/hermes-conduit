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
    /// The color the backdrop's warm glow takes for a profile: the color its
    /// bot was given in Hermes, or nil (the gold accent) when it has none.
    func profileGlowTint(_ profile: String) -> Color? {
        guard let bot = botRoster.first(where: { profilesMatch($0.name, profile) }),
              let color = bot.appearanceColor?.trimmingCharacters(in: .whitespacesAndNewlines),
              !color.isEmpty else { return nil }
        return BotAvatarView.color(for: color, name: bot.name)
    }

    /// Whether any listed conversation of `profile` has activity the user
    /// hasn't seen. Only rows this device has listed count, so a profile
    /// never opened here shows no dot rather than a guess.
    func profileHasUnread(_ profile: String) -> Bool {
        sessions.contains { session in
            guard let owner = session.profile, profilesMatch(owner, profile) else { return false }
            return chatReadState.isUnread(session, profile: profile)
        }
    }

    /// Whether a voice call's screen is up or on its way up. Opening a call
    /// uncovers the chat the old drawer hid; the V2 shell keeps its list.
    var isVoiceCallScreenPresented: Bool {
        showVoiceSheet || showGeminiLiveSheet || showGPTLiveSheet || showGrokLiveSheet
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
