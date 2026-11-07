import Foundation

enum DashboardPath {
    static func encodedQueryComponent(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: queryComponentAllowedCharacters)
    }

    /// Hermes 0.22.3+ runs a plugin request whose `?profile=` names a
    /// profile other than the one the dashboard started with in that
    /// profile's own plugin host, which carries no WebSockets and none of the
    /// dashboard's state. A plugin that reports `dashboard-profiles` takes
    /// the profile as `?conduit_profile=` instead on the routes that need the
    /// dashboard (voice and Watch calls, chat takeover, Desktop views,
    /// predictions), so they stay there: a workaround until Hermes carries
    /// them (#1336).
    static let conduitProfileParameter = "conduit_profile"
    static let dashboardProfilesCapability = "dashboard-profiles"
    /// Linked Rooms' new drafts and room setup take `?conduit_profile=`
    /// too, from a plugin that reports this (notifier #419): a draft starts
    /// in the room service of the profile's session authority, which only
    /// the dashboard has. Their own capability, since a plugin that reports
    /// `dashboard-profiles` without them would act for the dashboard's own
    /// profile there.
    static let roomDashboardProfilesCapability = "room-dashboard-profiles"

    /// A socket's profile query: `?profile=` as these sockets always sent it,
    /// or `?conduit_profile=`, which leaves out the dashboard's own profile
    /// as `withProfile` does.
    static func socketProfileItems(_ profile: String, parameter: String) -> [URLQueryItem] {
        guard parameter != "profile" else { return [URLQueryItem(name: parameter, value: profile)] }
        guard !profile.isEmpty, profile != "default" else { return [] }
        return [URLQueryItem(name: parameter, value: profile)]
    }

    static func withProfile(_ path: String, profile: String, parameter: String = "profile") -> String {
        guard profile != "default" else { return path }
        return withExplicitProfile(path, profile: profile, parameter: parameter)
    }

    /// Hermes' `PATCH /api/sessions/{id}` reads the owning profile from the
    /// JSON body, not the `?profile=` query, so a named profile's rename or
    /// archive must carry it there too or the server looks in the default
    /// profile's database and the change silently reverts.
    static func bodyWithProfile(_ body: [String: Any], profile: String) -> [String: Any] {
        guard profile != "default", !profile.isEmpty else { return body }
        var scoped = body
        scoped["profile"] = profile
        return scoped
    }

    static func withExplicitProfile(_ path: String, profile: String, parameter: String = "profile") -> String {
        guard !profile.isEmpty,
              let encoded = encodedQueryComponent(profile) else {
            return path
        }
        return "\(path)\(path.contains("?") ? "&" : "?")\(parameter)=\(encoded)"
    }

    private static let queryComponentAllowedCharacters: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-._~")
        return characters
    }()
}
