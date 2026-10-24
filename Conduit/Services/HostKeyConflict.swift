//
//  HostKeyConflict.swift
//  Conduit
//
//  The notifier answers 409 for several conflicts on its phone, location
//  and health routes. Only some mean it has no usable key for this phone
//  (`unknown_key`, `bad_seal`); the others (too many devices, a store
//  written by a newer plugin, a layer that's off) can't be fixed by
//  agreeing a new key. A store written by a newer plugin (`schema`) is
//  fixed by updating the plugin, so it asks for that. Its dashboard routes
//  send the message as `detail` and the code beside it, and the app's
//  bridges pass on only the message, so the message is what's read here.
//  The codes are matched too, should a host send one as the detail.
//

import Foundation

enum HostKeyConflict {
    private static let keyLossMarkers = [
        // The codes, should a host send them.
        "unknown_key",
        "bad_seal",
        "unknown key",
        // unknown_key: "This device's location (health) key isn't on this
        // profile; set it up again"
        "key isn't on this profile",
        // bad_seal: "The body didn't open with this device's key; set up …
        // again"
        "didn't open with this device's key",
    ]

    /// Whether a 409's detail says the host lost or replaced this phone's
    /// key.
    static func isKeyLoss(_ detail: String) -> Bool {
        let normalized = normalize(detail)
        return keyLossMarkers.contains { normalized.contains($0) }
    }

    /// Whether a 409's detail says the host's store was written by a newer
    /// plugin (`schema`): "This calendar (health, location) store was
    /// written by a newer plugin; update the plugin". Updating the plugin
    /// fixes it; a new key wouldn't.
    static func isNewerPluginStore(_ detail: String) -> Bool {
        let normalized = normalize(detail)
        return normalized == "schema" || normalized.contains("written by a newer plugin")
    }

    private static func normalize(_ detail: String) -> String {
        detail.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
