//
//  WatchVoiceStartFailure.swift
//  Conduit
//
//  Why the iPhone couldn't start a call the Apple Watch asked for, as the
//  Watch shows it (designs/apple-watch-voice.md). A test build's text, so
//  English only.
//

import Foundation

enum WatchVoiceStartFailure {
    static let hermesUnreachable = "Conduit on your iPhone couldn't reach Hermes. Open it once and try again."
    static let ended = "The call ended before it connected."
    static let callRunning = "A voice call is already running on your iPhone."
    static let unsupportedMode = "This test build talks through Gemini Live or Grok Live. Turn one on in Conduit's Voice settings on your iPhone."
}
