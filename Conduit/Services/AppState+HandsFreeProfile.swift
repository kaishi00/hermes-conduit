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

    /// The profile picked in Settings > Voice > Watch and Siri calls for
    /// the active dashboard, or nil to follow the iPhone.
    var handsFreeProfileChoice: String? {
        activeDashboardID.flatMap { Self.handsFreeProfileChoice(in: .standard, dashboard: $0) }
    }

    func setHandsFreeProfileChoice(_ profile: String?) {
        guard let dashboard = activeDashboardID,
              (profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") != (handsFreeProfileChoice ?? "") else { return }
        objectWillChange.send()
        Self.storeHandsFreeProfileChoice(profile, in: .standard, dashboard: dashboard)
        // The Watch's voices are checked on the profile its calls use now.
        Task { await refreshWatchCallVoices() }
    }

    nonisolated static func handsFreeProfileChoice(in defaults: UserDefaults, dashboard: UUID) -> String? {
        let stored = defaults.string(forKey: handsFreeProfileKeyPrefix + dashboard.uuidString)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? nil : stored
    }

    /// Saves `profile` (nil or blank: follow the iPhone) for `dashboard`.
    /// False when it was already the choice.
    @discardableResult
    nonisolated static func storeHandsFreeProfileChoice(
        _ profile: String?,
        in defaults: UserDefaults,
        dashboard: UUID
    ) -> Bool {
        let value = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value != (handsFreeProfileChoice(in: defaults, dashboard: dashboard) ?? "") else { return false }
        let key = handsFreeProfileKeyPrefix + dashboard.uuidString
        if value.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
        return true
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
        Self.watchCallProfile(
            answers: target != nil,
            callerProfile: target?.profile,
            callerOnActiveDashboard: target.map { $0.dashboardID == nil || $0.dashboardID == activeDashboardID } ?? false,
            handsFree: handsFreeProfile,
            active: activeProfile,
            profiles: profiles
        )
    }

    /// The caller's profile in the dashboard's own spelling, so the phone
    /// tools' checks match it.
    nonisolated static func watchCallProfile(
        answers: Bool,
        callerProfile: String?,
        callerOnActiveDashboard: Bool,
        handsFree: String,
        active: String,
        profiles: [String]
    ) -> String {
        guard answers else { return handsFree }
        let profile = callerProfile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !profile.isEmpty, callerOnActiveDashboard else { return active }
        return profiles.first { profilesMatch($0, profile) } ?? profile
    }

    /// A Siri or Action button start that names no profile takes the
    /// hands-free one. Every other start is left as it came.
    func applyingHandsFreeProfile(to intent: PendingVoiceIntent) -> PendingVoiceIntent {
        Self.applyingHandsFreeProfile(handsFreeProfileChoice == nil ? nil : handsFreeProfile, to: intent)
    }

    /// `handsFree` nil: none picked, the start is left as it came.
    nonisolated static func applyingHandsFreeProfile(_ handsFree: String?, to intent: PendingVoiceIntent) -> PendingVoiceIntent {
        guard let handsFree, intent.source == .siri,
              (intent.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else { return intent }
        var intent = intent
        intent.profile = handsFree
        return intent
    }

    /// `profile` as jobs and chats name it: nil for the profile in use.
    func jobProfile(for profile: String) -> String? {
        profilesMatch(profile, activeProfile) ? nil : profile
    }
}
