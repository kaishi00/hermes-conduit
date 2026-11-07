//
//  LiveVoiceLanguage.swift
//  Conduit
//

import Foundation

/// The language a live call speaks. Every live model gets this rule (Gemini,
/// Qwen, Grok, GPT-Live and Local Live's agent mode, on the phone, CarPlay,
/// a call from Hermes and the Watch), because everything else they read is
/// English: Conduit's rules, Hermes' persona, the opening turn, job notes.
/// Told nothing, GPT-Live opened every call in English and drifted back to
/// it after a job's result, even for a user who asked for German.
///
/// The language is the user's: the App Language when they picked one, else
/// the iPhone's first language, shipped by Conduit or not. Written for the
/// model, so not localized.
enum LiveVoiceLanguage {
    /// The user's language as a speech tag ("de", "zh-TW"), or nil.
    static var current: String? { OnDeviceSpeechStream.appLanguage }

    /// The rule for a call in `language` (a speech tag); without one, only
    /// the part about following the user.
    static func rule(language: String?) -> String {
        let follow = "If the user speaks to you in another language, or asks you to switch, use theirs from then on, for the rest of the call."
        // A read-back is the one exception: it reads Hermes' words as
        // written (#451).
        let hold = "This holds whatever language these instructions, the persona, Hermes' replies, job results or Conduit's notes are in: put what they say into the call's language. The one exception is a reply you read back word for word because the user asked to hear it: read it as written."
        guard let language, let name = name(of: language) else {
            return "\nLanguage: answer in the language the user speaks to you. \(follow) \(hold)"
        }
        return "\nLanguage: speak \(name), the user's language, from your first words, the call's opening included. \(follow) \(hold)"
    }

    /// The language's English name ("German", "Chinese (Traditional characters)"), so
    /// the model reads it whatever language it was trained on most.
    static func name(of language: String) -> String? {
        let english = Locale(identifier: "en")
        let tag = Locale.Language(identifier: language)
        guard let code = tag.languageCode?.identifier,
              let name = english.localizedString(forLanguageCode: code) else { return nil }
        guard code == "zh" else { return name }
        // OnDeviceSpeech's tags name Chinese by region: TW is Traditional.
        let traditional = tag.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(tag.region?.identifier ?? "")
        return name + (traditional ? " (Traditional characters)" : " (Simplified characters)")
    }
}
