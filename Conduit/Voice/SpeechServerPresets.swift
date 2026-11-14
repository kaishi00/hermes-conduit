//
//  SpeechServerPresets.swift
//  Conduit
//
//  The speech servers the plugin knows by name (its
//  speech_server_presets.json, plugin 0.174.0). Picking one fills the speech
//  server settings in; nothing else in Conduit knows about a preset, so a
//  server that isn't listed works the same once its fields are filled in.
//

import Foundation

struct SpeechServerPreset: Equatable, Identifiable {
    var id: String
    var name: String
    /// A complete address, saved as is.
    var url: String?
    /// An example address to finish, such as one with a workspace in it.
    var urlHint: String?
    var model: String?
    var voice: String?
    var transcriptionModel: String?
    var needsKey: Bool
    /// The server has a model of its own, so Hermes answers starts on.
    var drivesTurns: Bool

    init?(response: [String: Any]) {
        guard let id = response["id"] as? String, !id.isEmpty,
              let name = response["name"] as? String, !name.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            (response[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        self.id = id
        self.name = name
        url = text("url")
        urlHint = text("url_hint")
        model = text("model")
        voice = text("voice")
        transcriptionModel = text("transcription_model")
        needsKey = response["needs_key"] as? Bool ?? false
        drivesTurns = response["drive_turns"] as? Bool ?? false
    }

    static func list(response: [String: Any]) -> [SpeechServerPreset] {
        (response["presets"] as? [[String: Any]] ?? []).compactMap(SpeechServerPreset.init(response:))
    }
}
