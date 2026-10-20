//
//  TurnSurface.swift
//  Conduit
//
//  Where in Conduit a message was sent from, for Hermes (#888). Hermes
//  knows a turn came from Conduit but not whether the user typed it on an
//  iPad or said it to CarPlay while driving, so it answered both with the
//  same long Markdown. Just before a send, Conduit tells the notifier
//  plugin (its `turn-surface` capability) the surface, how the message was
//  entered and the hash of the exact text it sends; the plugin adds one
//  line to the context of the turn with that text, such as
//  "[Conduit: this message came from CarPlay in the user's car, spoken.]".
//  `prompt.submit` refuses keys Hermes doesn't know, so it can't ride there.
//

import CryptoKit
import UIKit

struct TurnSurface: Equatable {
    /// The plugin's wire values. The plugin's own Watch turns name the
    /// Watch themselves.
    enum Place: String {
        case iphone, ipad, mac, vision, carplay, siri
    }

    enum Input: String {
        case typed, spoken
    }

    var place: Place
    /// Unknown for a Shortcut, which may have been spoken or run on its own.
    var input: Input?

    static let capability = "turn-surface"
    static let path = "/api/plugins/conduit_push/turn-surface"
    /// The send waits at most this long for the plugin, then goes anyway:
    /// a turn without the line is only what Hermes had before.
    static let wait: Duration = .milliseconds(600)
    /// The request's own limit; a send only ever waits `wait` for it.
    static let timeoutMilliseconds = 3_000

    /// Whether the connected plugin takes reports.
    static func isTaken(by plugin: NotifierPluginStatus) -> Bool {
        plugin.reports(capability)
    }

    /// The device this app runs on.
    @MainActor static var device: Place {
        if ProcessInfo.processInfo.isiOSAppOnMac { return .mac }
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return .ipad
        case .vision: return .vision
        case .mac: return .mac
        default: return .iphone
        }
    }

    /// A message typed or spoken in the app. A spoken one counts as CarPlay's
    /// while CarPlay presents the conversation.
    @MainActor static func message(spoken: Bool, carPlay: Bool, device: Place? = nil) -> TurnSurface {
        let device = device ?? Self.device
        guard spoken else { return TurnSurface(place: device, input: .typed) }
        return TurnSurface(place: carPlay ? .carplay : device, input: .spoken)
    }

    static let shortcut = TurnSurface(place: .siri, input: nil)

    /// `text` is exactly what `prompt.submit` sends: the plugin matches the
    /// turn by it, so a message that steers a running turn labels no other.
    func body(runtimeSessionID: String, text: String) -> [String: Any] {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        var body: [String: Any] = ["session_id": runtimeSessionID, "text_sha256": digest, "surface": place.rawValue]
        if let input { body["input"] = input.rawValue }
        return body
    }
}
