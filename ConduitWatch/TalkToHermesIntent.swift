//
//  TalkToHermesIntent.swift
//  Conduit Watch
//
//  One press to a call: the Action button on Apple Watch Ultra, Control
//  Center and the Smart Stack (as a control, watchOS 26), Siri and the
//  Shortcuts app run this intent; the watch face complication opens
//  WatchCallURL.talk. Built into the Watch app and its widget extension,
//  as a control that opens its app needs (WidgetKit, "Creating controls
//  to perform actions across the system"); the call starts in the app.
//

import AppIntents
import Foundation

struct TalkToHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Talk to Hermes"
    static var description = IntentDescription("Starts a voice call to Hermes on your Watch.")

    /// watchOS before 26 (the Watch app's floor). A boolean literal: the
    /// App Intents metadata processor reads it.
    @available(watchOS, deprecated: 26.0, message: "Use supportedModes on watchOS 26+; retained for watchOS 10–25.")
    static var openAppWhenRun: Bool = true

    /// The call needs the app in front: the microphone and the call screen
    /// belong to it.
    @available(watchOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchCallRequests.handler?("intent")
        return .result()
    }
}

/// Where a call asked for from outside the app goes: the Watch app sets
/// it at launch; the widget extension has none and only opens the app.
enum WatchCallRequests {
    @MainActor static var handler: (@MainActor (String) -> Void)?
}

/// The URL the watch face complication opens the app with.
enum WatchCallURL {
    static let talk = URL(string: "conduitwatch://talk")!

    static func isTalk(_ url: URL) -> Bool {
        url.scheme == talk.scheme && url.host == talk.host
    }
}
