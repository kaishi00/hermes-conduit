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
///
/// Gemini, Qwen, Grok and Local Live speak of the work as their own: to
/// the user the voice and Hermes are one assistant, and a model that kept
/// saying it "sent that to Hermes" sounded like a go-between (issue 583).
/// GPT-Live keeps naming Hermes, at most once a call: its send-claim
/// fallback finds a request it said it sent but never delegated by that
/// name in every shipped language, and by a bare acknowledgement only in
/// English (`delegationRule`).
enum LiveVoiceAcknowledgement {
    static let rule = "Keep that acknowledgement to a word or a few, in your own words and different each time; \"Sure.\", \"On it.\" or \"Okay, give me a moment.\" only show the length, so don't reuse them word for word. " + firstPerson + " If you just told the user what you're about to do, that was the acknowledgement: don't add another."

    /// To the user the voice and Hermes are one assistant (issue 583).
    static let firstPerson = "To the user, you and Hermes are one assistant: speak of the work in the first person, as your own (\"I'll check.\", \"I'm on it.\", \"I found it.\"), never as something you send, pass or hand to Hermes or ask Hermes to do. Speaking in the first person never makes work started or done: until a tool says it started, say what you will do, not what you're doing. Name Hermes only when the user asks who's doing the work or how you work."

    /// GPT-Live's: it names Hermes at most once a call (see above).
    static let delegationRule = "Keep that acknowledgement to a word or a few, in your own words and different each time; \"Sure.\", \"On it.\" or \"Okay, give me a moment.\" only show the length, so don't reuse them word for word. Don't keep saying you'll ask, tell or check with Hermes: say Hermes is on it at most once on a call, or when the user asks who's doing it. If you just told the user what you're about to do, that was the acknowledgement: don't add another."
}
