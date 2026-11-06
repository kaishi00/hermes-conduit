//
//  LiveVoiceStyle.swift
//  Conduit
//
//  How live voice calls (Gemini Live, GPT-Live, Grok Live) sound, chosen
//  per profile (#290): a tone, whether the model backchannels ("mm-hmm")
//  while the user talks, an optional greeting when a call connects so the
//  user knows it's live, how much the model says, and the user's own
//  instructions, added after Conduit's rules. An unset tone or backchannel
//  changes nothing: the host's own persona decides. Answer length always
//  has a rule, Default unless the user picks another.
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

/// How much a live model says when the user asks something. Told only to
/// keep replies short, voice models answered in a line and left the user
/// asking follow-ups, so Default asks for the details; Concise is for users
/// who want just the point.
enum LiveVoiceAnswerLength: String, Codable, CaseIterable, Identifiable {
    case concise
    case standard
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .concise: return AppLocalization.string("Concise")
        case .standard: return AppLocalization.string("Default")
        case .detailed: return AppLocalization.string("Detailed")
        }
    }

    /// The answer-length rule in the live model's instructions. Written for
    /// the model, not shown as UI copy, so not localized. A call with no
    /// read-backs (a Watch call, #451) leaves out the read-back exception.
    func instructions(readsBack: Bool) -> String {
        let lead: String
        switch self {
        case .concise:
            lead = "Keep answers short and to the point: lead with the answer itself and the one or two specifics that make it useful (the number, name or step that matters), usually one to three sentences. Leave out background and caveats unless they change the answer; the user will ask if they want more. Still give a real answer, never a vague headline."
        case .standard:
            lead = "Say enough to be useful. Answer a real question fully the first time: the answer, then the details that make it useful (the reasons, numbers, names, steps or options that matter, and any caveat), usually several sentences and more when the topic needs it. Don't leave the user asking follow-up questions to get the substance, and don't stop at a headline or end on an offer to say more instead of saying it."
        case .detailed:
            lead = "Be thorough. Answer a real question in depth the first time: the answer, then the reasoning behind it, the numbers, names, steps and options that matter, an example where it helps, and the caveats worth knowing, often several paragraphs of speech. Don't leave the user asking follow-up questions to get the full picture, and don't end on an offer to say more instead of saying it."
        }
        let scope = readsBack
            ? " This goes for everything you say, Hermes' results included, except a read-back: when the user asks to hear a reply again or in full and Conduit gives it to you to read, read all of it word for word, however long."
            : " This goes for everything you say, Hermes' results included."
        let speech = scope + " It is still speech: say it in natural spoken sentences, not lists, headings or Markdown, and never read out URLs. When the detail is on the user's screen, that takes the place of a long spoken answer."
        return self == .concise ? lead + speech : lead + speech + " Keep it short only for greetings, small talk, acknowledgements and confirmations."
    }
}

struct LiveVoiceStyle: Equatable {
    /// Nil keeps the voice model's own tone.
    var tone: LiveVoiceTone? = nil
    var backchannels = true
    /// Nil: the call stays silent until the user speaks. Empty: a short
    /// greeting in the model's own words. Text: that greeting.
    var greeting: String? = nil
    /// Goes into the instructions' rules, not `instructions` below: one
    /// answer-length rule per call.
    var answerLength: LiveVoiceAnswerLength = .standard
    /// Whether a call starts holding each request for the user's OK before
    /// it goes to Hermes (#451). The call's own switch can change it.
    var asksBeforeSending = false
    /// The user's own instructions for the voice model (issue 583), added
    /// after Conduit's rules, never in place of them: those carry the tools,
    /// jobs and approvals a call depends on. Nil or empty adds nothing.
    var extraInstructions: String? = nil

    static let maxGreetingCharacters = 200
    /// Room for a real persona or house rules, short enough that a small
    /// local model still starts talking quickly.
    static let maxExtraInstructionsCharacters = 2_000

    /// The user's instructions trimmed and clipped; nil when nothing's left.
    static func cleanedExtraInstructions(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxExtraInstructionsCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
            lines.append("Tone: professional, at a brisk pace. No small talk, filler or pleasantries: spend the words on substance.")
        case nil:
            break
        }
        if !backchannels {
            lines.append("Backchannels: none. Don't say \"mm-hmm\", \"right\", \"I see\" or similar while the user talks or before you answer.")
        }
        let style = lines.isEmpty ? "" : "\n\n[Voice style the user chose in Conduit. It replaces any tone, pace or backchannel guidance above.]\n"
            + lines.joined(separator: "\n")
        return style + userInstructions
    }

    /// The user's own instructions, last of the style: they may shape the
    /// voice, wording and personality, but the rules above keep the call's
    /// tools, jobs and approvals working, so those win where the two differ.
    private var userInstructions: String {
        guard let text = Self.cleanedExtraInstructions(extraInstructions) else { return "" }
        let body = text.replacingOccurrences(of: "</user_instructions>", with: "</ user_instructions>", options: .caseInsensitive)
        return "\n\n[The user's own instructions for you, written in Conduit's settings. Follow them, except where they conflict with the rules above about tools, jobs, approvals, and never saying something was started or done unless a tool said so: those rules always come first.]\n<user_instructions>\n\(body)\n</user_instructions>"
    }

    /// Whether the call starts asking first (#451), after the rules that
    /// say how it works. Per call, not per style: the call's own switch can
    /// change it. Not UI copy.
    static func askFirstInstructions(on: Bool) -> String {
        on
            ? "\n\nAsking first is on for this call: a new request goes to Hermes only once the user OKs it."
            : "\n\nAsking first is off for this call: new requests go to Hermes straight away."
    }

    /// The turn that makes the model greet the user when the call connects.
    /// Not UI copy.
    var openingPrompt: String? {
        greeting.map(LiveVoiceGreeting.turn)
    }
}
