//
//  LiveVoiceGreeting.swift
//  Conduit
//
//  The turn that makes a live model greet the user when a call connects,
//  for the user's greeting setting: the iPhone's live modes send it as the
//  call's first turn, and so does a GPT-Live call on the Apple Watch, whose
//  host no longer has the model speak first (notifier #541).
//

import Foundation

enum LiveVoiceGreeting {
    /// The first turn for `greeting`: "" greets in the model's own words.
    /// Not UI copy.
    static func turn(_ greeting: String) -> String {
        let say = greeting.isEmpty ? "" : " Say: \"\(greeting)\""
        return "[The call just connected. Greet the user in one short sentence so they know you're there and listening.\(say) Then wait for them.]"
    }
}
