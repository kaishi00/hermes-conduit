//
//  HostKeyConflict.swift
//  Conduit
//
//  The notifier answers 409 for several conflicts on its location and
//  health routes. Only some mean it has no usable key for this phone
//  (`unknown_key`, `bad_seal`); the others (too many devices, a store
//  written by a newer plugin, a layer that's off) can't be fixed by
//  agreeing a new key. Its dashboard routes send the message, not the
//  code, as `detail`, so both are recognized.
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
        let normalized = detail.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return keyLossMarkers.contains { normalized.contains($0) }
    }
}
