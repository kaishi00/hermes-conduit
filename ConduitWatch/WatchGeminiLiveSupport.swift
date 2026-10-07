//
//  WatchGeminiLiveSupport.swift
//  Conduit Watch
//
//  What the Gemini Live code shared with the iPhone (Shared/GeminiLive)
//  calls from the iPhone app, in the Watch's plain form: its text in the
//  development language, and errors as they describe themselves. The test
//  build ships no translations.
//

import Foundation

enum AppLocalization {
    static func string(_ keyAndValue: String.LocalizationValue, table: String? = nil) -> String {
        String(localized: keyAndValue, table: table)
    }
}

enum UserFacingError {
    static func message(for error: Error) -> String {
        error.localizedDescription
    }
}
