//
//  AppState+HandsFreeProfile.swift
//  Conduit
//
//  The profile a call started away from the iPhone's screen runs on (#1564):
//  the Apple Watch's calls, and Siri's or the Action button's when the
//  shortcut names no profile. Off (nil) follows the profile open on the
//  iPhone, as every call did before. Saved per dashboard on this device.
//
//  A Watch call runs on it without switching the iPhone: the Watch's
//  setup, tokens, jobs and saved call all read the call's own profile
//  (WatchDirectConnection.profile). A Siri start switches the iPhone to it,
//  as a Siri start that names a profile always has, since its call shows
//  on the iPhone.
//

import Foundation

extension AppState {
    nonisolated static let handsFreeProfileKeyPrefix = "voice.handsFreeProfile."

    private var handsFreeProfileKey: String? {
        activeDashboardID.map { Self.handsFreeProfileKeyPrefix + $0.uuidString }
    }

    /// The profile picked in Settings > Voice > Watch and Siri calls for
    /// the active dashboard, or nil to follow the iPhone.
    var handsFreeProfileChoice: String? {
        guard let key = handsFreeProfileKey else { return nil }
        let stored = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? nil : stored
    }

    func setHandsFreeProfileChoice(_ profile: String?) {
        guard let key = handsFreeProfileKey else { return }
        let value = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value != (handsFreeProfileChoice ?? "") else { return }
        objectWillChange.send()
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
        // The Watch's voices are checked on the profile its calls use now.
        Task { await refreshWatchCallVoices() }
    }

    /// The profile a hands-free call starts on: the one picked, while this
    /// dashboard still has it, else the one open on the iPhone.
    var handsFreeProfile: String {
        Self.handsFreeProfile(choice: handsFreeProfileChoice, profiles: profiles, active: activeProfile)
    }

    /// A choice the dashboard no longer lists (deleted or renamed away)
    /// follows the iPhone rather than failing every call. Before the list
    /// has loaded the choice is kept: the host answers for it.
    nonisolated static func handsFreeProfile(choice: String?, profiles: [String], active: String) -> String {
        guard let choice, !choice.isEmpty else { return active }
        if profiles.isEmpty { return choice }
        return profiles.first { profilesMatch($0, choice) } ?? active
    }

    /// The profile a Watch call runs on: a call from Hermes it answers
    /// keeps that call's own profile (on the dashboard in use; a push that
    /// names none is the iPhone's, as on the iPhone); any other starts on
    /// the hands-free profile.
    func watchCallProfile(answering target: ConduitNotificationTarget?) -> String {
        guard let target else { return handsFreeProfile }
        let profile = target.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !profile.isEmpty, target.dashboardID == nil || target.dashboardID == activeDashboardID else { return activeProfile }
        return profile
    }

    /// A Siri or Action button start that names no profile takes the
    /// hands-free one. Every other start is left as it came.
    func applyingHandsFreeProfile(to intent: PendingVoiceIntent) -> PendingVoiceIntent {
        guard intent.source == .siri,
              (intent.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty,
              handsFreeProfileChoice != nil else { return intent }
        var intent = intent
        intent.profile = handsFreeProfile
        return intent
    }

    /// `profile` as jobs and chats name it: nil for the profile in use.
    func jobProfile(for profile: String) -> String? {
        profilesMatch(profile, activeProfile) ? nil : profile
    }
}
