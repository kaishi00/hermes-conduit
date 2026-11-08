import Foundation

/// Opt-in ways to shorten the shared bar. Defaults keep every chip and
/// control: switching profiles still takes one tap until the user opts out.
enum V2SessionsBarPreferences {
    /// Every profile's chip, or just the active one opening the profiles list.
    enum Profiles: String, CaseIterable, Identifiable {
        case all
        case currentOnly = "current"

        var id: String { rawValue }
        static let key = "conduit.v2.sessionsBar.profiles"
        static let defaultValue = Profiles.all
    }

    static let showsProjectsKey = "conduit.v2.sessionsBar.projects"
    static let showsPulseKey = "conduit.v2.sessionsBar.pulse"
    static let showsArtifactsKey = "conduit.v2.sessionsBar.artifacts"
    static let showsProjectsDefault = true
    static let showsPulseDefault = true
    static let showsArtifactsDefault = true
}

/// One read-only resolution for the bar and its list, so a hidden control
/// cannot leave the list on a page the user can no longer switch away from.
struct V2SessionsBarControls: Equatable {
    enum Presentation: String { case sessions, projects }

    let profiles: V2SessionsBarPreferences.Profiles
    let showsProjects: Bool
    let showsPulse: Bool
    let showsArtifacts: Bool
    let presentation: Presentation

    /// Current only leaves the bar one chip, so the way between All and a
    /// single profile has to live in the two sheets: the profiles sheet a
    /// single profile's chip opens carries the way into All while All chats
    /// is off, and the All-profiles sheet carries the way back out while it's
    /// on. Both read here, so the pair can be tested without a device: the
    /// first going missing is what made All unreachable under Current only
    /// (Greptile, #2020).
    static func showsAllChatsRow(profiles: V2SessionsBarPreferences.Profiles,
                                 allProfilesChatsOn: Bool,
                                 allProfilesAvailable: Bool) -> Bool {
        profiles == .currentOnly && !allProfilesChatsOn && allProfilesAvailable
    }

    static func showsShowOnlyRow(profiles: V2SessionsBarPreferences.Profiles,
                                 allProfilesChatsOn: Bool) -> Bool {
        profiles == .currentOnly && allProfilesChatsOn
    }

    /// Pulse remains inside the profile's own capability gate. Hidden
    /// Projects, or All profiles' chats-only list, resolves even an old value
    /// or another window's write to Sessions without writing during a render.
    static func resolve(defaults: UserDefaults = .standard,
                        pulseAvailable: Bool,
                        allProfilesChatsOn: Bool) -> V2SessionsBarControls {
        let profiles = defaults.string(forKey: V2SessionsBarPreferences.Profiles.key)
            .flatMap(V2SessionsBarPreferences.Profiles.init(rawValue:))
            ?? V2SessionsBarPreferences.Profiles.defaultValue
        let projects = defaults.object(forKey: V2SessionsBarPreferences.showsProjectsKey) as? Bool
            ?? V2SessionsBarPreferences.showsProjectsDefault
        let pulse = defaults.object(forKey: V2SessionsBarPreferences.showsPulseKey) as? Bool
            ?? V2SessionsBarPreferences.showsPulseDefault
        let artifacts = defaults.object(forKey: V2SessionsBarPreferences.showsArtifactsKey) as? Bool
            ?? V2SessionsBarPreferences.showsArtifactsDefault
        let showsProjectsPage = projects && !allProfilesChatsOn
            && defaults.string(forKey: V2ChatsView.presentationKey) == "projects"
        return V2SessionsBarControls(
            profiles: profiles,
            showsProjects: projects,
            showsPulse: pulseAvailable && pulse,
            showsArtifacts: artifacts,
            presentation: showsProjectsPage ? .projects : .sessions
        )
    }
}
