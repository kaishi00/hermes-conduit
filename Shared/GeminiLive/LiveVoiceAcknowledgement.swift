//
//  LiveVoiceAcknowledgement.swift
//  Conduit
//

/// How every live mode acknowledges work it hands to Hermes: Gemini and
/// Qwen (phone and Watch) before start_job, Grok and Local Live once it
/// returns (`acknowledgesOnceStarted` in the shared instructions),
/// GPT-Live before a delegation. One fixed example ("On it, I'll
/// have Hermes look into that.") was said word for word on every request,
/// and users tired of hearing "I'll ask Hermes" each time. Written for the
/// model, so not localized.
enum LiveVoiceAcknowledgement {
    static let rule = "Keep that acknowledgement to a word or a few, in your own words and different each time; \"Sure.\", \"On it.\" or \"Okay, give me a moment.\" only show the length, so don't reuse them word for word. Don't keep saying you'll ask, tell or check with Hermes: say Hermes is on it at most once on a call, or when the user asks who's doing it. If you just told the user what you're about to do, that was the acknowledgement: don't add another."
}
