//
//  WatchCallVoices.swift
//  Conduit and the Conduit Watch app
//
//  Which of the Watch's voices can start, as the iPhone last found them for
//  the active dashboard and profile. Calls from Hermes ring the Watch only
//  when the voice it answers with can start (Eric chose "Live only",
//  2026-10-11; designs/hermes-calls-watch.md): the Watch has no Classic
//  voice to fall back on, so an answered call there would only fail. The
//  iPhone keeps this, holds the Watch's token back from the relay while its
//  voice can't start, and shares it with the Watch app, which says what to
//  set up.
//

import Foundation

struct WatchCallVoices: Codable, Equatable {
    /// The Watch's voices (WatchVoiceEngine.callVoice).
    enum Voice: String, CaseIterable {
        case geminiLive
        case gptLive
        case grokLive
    }

    /// The dashboard and profile the checks were for.
    var scope = ""
    /// Each voice's last check, by raw value; one not checked yet is missing.
    var ready: [String: Bool] = [:]

    /// Whether a call from Hermes rings the Watch whose voice is `engine`
    /// (a raw value). An older Watch app doesn't say (nil), and a voice not
    /// checked yet isn't known: both ring, as before.
    func rings(engine: String?) -> Bool {
        guard let engine else { return true }
        return ready[engine] ?? true
    }

    /// One voice's check. Checks for another dashboard or profile go first:
    /// they say nothing about this one.
    mutating func note(_ voice: Voice, ready isReady: Bool, scope: String) {
        if scope != self.scope { self = WatchCallVoices(scope: scope) }
        ready[voice.rawValue] = isReady
    }
}

/// What the iPhone shares with the Watch app as its WatchConnectivity
/// application context: only the latest counts, and the Watch reads it
/// whenever it runs next.
struct WatchPhoneContext: Codable, Equatable {
    /// Each Watch voice's last check (WatchCallVoices.ready).
    var voices: [String: Bool] = [:]
    /// Calls from Hermes ring the iPhone: the Watch says its own voice
    /// keeps them off the Watch only then.
    var callsRing = false

    static let key = "phoneContext"

    /// Whether `voice` is known not to start.
    func notSetUp(_ voice: WatchCallVoices.Voice) -> Bool {
        voices[voice.rawValue] == false
    }

    func encoded() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.key: data]
    }

    static func decode(_ context: [String: Any]) -> WatchPhoneContext? {
        guard let data = context[key] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchPhoneContext.self, from: data)
    }
}
