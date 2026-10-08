import Foundation

enum DashboardPath {
    static func encodedQueryComponent(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: queryComponentAllowedCharacters)
    }

    static func withProfile(_ path: String, profile: String) -> String {
        guard profile != "default" else { return path }
        return withExplicitProfile(path, profile: profile)
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

    static func withExplicitProfile(_ path: String, profile: String) -> String {
        guard !profile.isEmpty,
              let encoded = encodedQueryComponent(profile) else {
            return path
        }
        return "\(path)\(path.contains("?") ? "&" : "?")profile=\(encoded)"
    }

    private static let queryComponentAllowedCharacters: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-._~")
        return characters
    }()
}
