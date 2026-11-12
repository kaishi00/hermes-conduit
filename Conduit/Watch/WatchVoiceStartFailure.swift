//
//  WatchVoiceStartFailure.swift
//  Conduit
//
//  Why the iPhone couldn't start or serve a call the Apple Watch asked
//  for, as the Watch shows it (designs/apple-watch-voice-direct.md).
//

import Foundation

enum WatchVoiceStartFailure {
    static var hermesUnreachable: String { AppLocalization.string("Conduit on your iPhone couldn't reach Hermes. Open it once and try again.", table: .watchCarPlay) }
    static var ended: String { AppLocalization.string("The call ended before it connected.", table: .watchCarPlay) }
    static var callRunning: String { AppLocalization.string("A voice call is already running on your iPhone.", table: .watchCarPlay) }
    static var connectionChanged: String { AppLocalization.string("Conduit on your iPhone switched to another Hermes profile or server, so this call ended.", table: .watchCarPlay) }
    static var versionMismatch: String { AppLocalization.string("Update Conduit on your iPhone and Watch to the same version.", table: .watchCarPlay) }
}
