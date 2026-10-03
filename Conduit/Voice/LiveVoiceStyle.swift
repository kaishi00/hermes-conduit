//
//  LiveVoiceStyle.swift
//  Conduit
//
//  How live voice calls (Gemini Live, GPT-Live, Grok Live) sound, chosen
//  per profile (#290): a tone, whether the model backchannels ("mm-hmm")
//  while the user talks, and an optional greeting when a call connects so
//  the user knows it's live. Nothing set changes nothing: the host's own
//  persona decides.
//

import Foundation

enum LiveVoiceTone: String, Codable, CaseIterable, Identifiable {
    case relaxed
    case neutral
    case professional

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relaxed: return AppLocalization.string("Relaxed")
        case .neutral: return AppLocalization.string("Neutral")
        case .professional: return AppLocalization.string("Professional")
        }
    }
}

struct LiveVoiceStyle: Equatable {
    /// Nil keeps the voice model's own tone.
    var tone: LiveVoiceTone? = nil
    var backchannels = true
    /// Nil: the call stays silent until the user speaks. Empty: a short
    /// greeting in the model's own words. Text: that greeting.
    var greeting: String? = nil

    static let maxGreetingCharacters = 200

    /// The user's greeting on one line, without double quotes (it is quoted
    /// to the model), clipped.
    static func cleanedGreeting(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\"", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(oneLine.prefix(maxGreetingCharacters))
    }

    /// Added after the persona, so it wins over the tone and backchannels
    /// the persona asks for. Written for the model, not shown as UI copy, so
    /// not localized.
    var instructions: String {
        var lines: [String] = []
        switch tone {
        case .relaxed?:
            lines.append("Tone: relaxed and warm, at an easy, unhurried pace.")
        case .neutral?:
            lines.append("Tone: neutral and matter-of-fact, at a normal conversational pace. Skip filler and pleasantries.")
        case .professional?:
            lines.append("Tone: professional and concise, at a brisk pace. No small talk, filler or pleasantries.")
        case nil:
            break
        }
        if !backchannels {
            lines.append("Backchannels: none. Don't say \"mm-hmm\", \"right\", \"I see\" or similar while the user talks or before you answer.")
        }
        guard !lines.isEmpty else { return "" }
        return "\n\n[Voice style the user chose in Conduit. It replaces any tone, pace or backchannel guidance above.]\n"
            + lines.joined(separator: "\n")
    }

    /// The turn that makes the model greet the user when the call connects.
    /// Not UI copy.
    var openingPrompt: String? {
        guard let greeting else { return nil }
        let say = greeting.isEmpty ? "" : " Say: \"\(greeting)\""
        return "[The call just connected. Greet the user in one short sentence so they know you're there and listening.\(say) Then wait for them.]"
    }
}
