//
//  HermesRingtones.swift
//  Conduit
//
//  The sound a call from Hermes rings with (issue 2445): iOS's own
//  ringtone, or one of the tones Conduit ships, for every bot or for one
//  bot alone, so a call can be told from a person's and one bot's from
//  another's by ear. CallKit rings only with the system's default or a
//  sound file in the app bundle: an app can't use the ringtones in iOS's
//  Settings. The choice is made on the iPhone and kept there; the Apple
//  Watch gets it with the iPhone's context (WatchPhoneContext) and keeps
//  its own copy. The host and the relay never hear of it. The tones are
//  written by scripts/make-ringtones.py.
//

import Foundation

enum HermesRingtone: String, CaseIterable, Identifiable {
    /// The system's own ringtone, as calls rang before there was a choice.
    case system = "default"
    case chime
    case lantern
    case ripple
    case signal
    case beacon
    case orbit

    var id: String { rawValue }

    /// The tone's file in the app bundle, by the name CallKit takes; nil
    /// for the system's own.
    var fileName: String? {
        self == .system ? nil : "ringtone-\(rawValue).wav"
    }

    /// The file, when the bundle has it.
    var bundledURL: URL? {
        guard self != .system else { return nil }
        return Bundle.main.url(forResource: "ringtone-\(rawValue)", withExtension: "wav")
    }

    /// What CallKit's provider is given: nil rings with the system's own,
    /// as does a tone whose file the bundle doesn't have.
    var ringtoneSound: String? {
        bundledURL == nil ? nil : fileName
    }
}

/// The ringtone for every bot's calls, and the bots that have their own.
struct HermesRingtoneStore {
    static let allKey = "hermesCalls.ringtone"
    static let botsKey = "hermesCalls.ringtone.bots"
    var defaults: UserDefaults = .standard

    /// A bot is its profile, as for the address its calls ring from and the
    /// contact that holds it: the same bot on two dashboards rings alike.
    /// Nil for a call that names no profile, which has no bot's own tone.
    static func bot(_ profile: String?) -> String? {
        let address = HermesCallerName.contactAddress(profile: profile)
        return address == HermesCallerName.contactAddress(profile: nil) ? nil : address
    }

    /// The ringtone of every bot that has none of its own.
    var forAll: HermesRingtone {
        get { defaults.string(forKey: Self.allKey).flatMap(HermesRingtone.init(rawValue:)) ?? .system }
        nonmutating set {
            if newValue == .system {
                defaults.removeObject(forKey: Self.allKey)
            } else {
                defaults.set(newValue.rawValue, forKey: Self.allKey)
            }
        }
    }

    /// Each bot's own ringtone, by the bot (`bot(_:)`), as kept and as the
    /// iPhone shares them with the Watch.
    var bots: [String: String] {
        get { defaults.dictionary(forKey: Self.botsKey) as? [String: String] ?? [:] }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.botsKey)
            } else {
                defaults.set(newValue, forKey: Self.botsKey)
            }
        }
    }

    /// The bot's own ringtone; nil when it rings like the others.
    func own(profile: String?) -> HermesRingtone? {
        guard let bot = Self.bot(profile) else { return nil }
        return bots[bot].flatMap(HermesRingtone.init(rawValue:))
    }

    /// Nil puts the bot back with the others.
    func setOwn(_ ringtone: HermesRingtone?, profile: String?) {
        guard let bot = Self.bot(profile) else { return }
        var kept = bots
        kept[bot] = ringtone?.rawValue
        bots = kept
    }

    /// What a call from this profile rings with.
    func ringtone(profile: String?) -> HermesRingtone {
        own(profile: profile) ?? forAll
    }

    /// The Watch keeps what the iPhone shared. A context from an older
    /// iPhone app names no ringtone and changes nothing.
    func keep(_ context: WatchPhoneContext?) {
        guard let context, let all = context.ringtone else { return }
        forAll = HermesRingtone(rawValue: all) ?? .system
        bots = context.botRingtones ?? [:]
    }
}
