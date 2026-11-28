//
//  HermesAutoAnswer.swift
//  Conduit
//
//  "Answer automatically" in Calls from Hermes (issue 3421): a call from a
//  bot connects on its own a few seconds after it starts ringing, so a call
//  the user asked for hands-free (a Siri shortcut's "call me now", the
//  iPhone locked) needs no tap and no spoken "Answer". iOS's own
//  Auto-Answer Calls answers every caller, people included, so it can't
//  stand in. Kept per bot on this iPhone, as its ringtone is: the host and
//  the relay never hear of it, and the Watch keeps ringing until the
//  iPhone answers. Only a call CallKit rings answers: one a Focus silences,
//  or one the host held back ("Don't call me while I'm at"), never reaches
//  it.
//

import Foundation

enum HermesAutoAnswer: Int, CaseIterable, Identifiable {
    case off = 0
    case after3 = 3
    case after5 = 5
    case after10 = 10

    var id: Int { rawValue }

    /// How long the call rings before it answers; nil when it doesn't.
    var delay: Duration? {
        self == .off ? nil : .seconds(rawValue)
    }

    var title: String {
        switch self {
        case .off: return AppLocalization.string("Off")
        case .after3: return AppLocalization.string("After 3 seconds", table: .voice)
        case .after5: return AppLocalization.string("After 5 seconds", table: .voice)
        case .after10: return AppLocalization.string("After 10 seconds", table: .voice)
        }
    }
}

/// Each bot's "Answer automatically", on this iPhone.
struct HermesAutoAnswerStore {
    static let botsKey = "hermesCalls.autoAnswer.bots"
    var defaults: UserDefaults = .standard

    /// A bot is its profile's address, as for its contact and its ringtone:
    /// the same bot on two dashboards answers alike. The main profile has
    /// one too, so its calls can answer on their own as well: Settings
    /// names it "default" and a call may name no profile, so both read the
    /// same key.
    static func bot(_ profile: String?) -> String {
        let id = profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HermesCallerName.contactAddress(profile: id.isEmpty ? "default" : id)
    }

    private var bots: [String: Int] {
        get { defaults.dictionary(forKey: Self.botsKey) as? [String: Int] ?? [:] }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.botsKey)
            } else {
                defaults.set(newValue, forKey: Self.botsKey)
            }
        }
    }

    /// Off until it's picked, and for a wait this build doesn't offer.
    func choice(profile: String?) -> HermesAutoAnswer {
        bots[Self.bot(profile)].flatMap(HermesAutoAnswer.init(rawValue:)) ?? .off
    }

    func set(_ choice: HermesAutoAnswer, profile: String?) {
        var kept = bots
        kept[Self.bot(profile)] = choice == .off ? nil : choice.rawValue
        bots = kept
    }
}
