//
//  WatchDirectWire.swift
//  Conduit and the Conduit Watch app
//
//  Between the link's direct-call messages and the Gemini Live code both
//  devices share (designs/apple-watch-voice-direct.md): the token, the
//  setup's instructions and function declarations, and what the iPhone's
//  tool bridge asks the call to send. Nothing here changes what reaches
//  Gemini: the Watch's session builds its setup from the same values the
//  iPhone's would.
//

import Foundation

extension WatchVoiceWire.DirectToken {
    init(_ token: GeminiLiveToken) {
        self.init(
            token: token.token,
            expiresAt: token.expiresAt,
            newSessionExpiresAt: token.newSessionExpiresAt,
            model: token.model,
            webSocketURL: token.webSocketURL.absoluteString
        )
    }

    /// Nil if the URL can't be read.
    var geminiToken: GeminiLiveToken? {
        guard let url = URL(string: webSocketURL) else { return nil }
        return GeminiLiveToken(token: token, expiresAt: expiresAt, newSessionExpiresAt: newSessionExpiresAt, model: model, webSocketURL: url)
    }
}

extension WatchVoiceWire.DirectSetup {
    init(systemInstruction: String, functions: [GeminiLiveProtocol.FunctionDeclaration]) {
        self.init(
            systemInstruction: systemInstruction,
            functions: functions.compactMap { try? JSONSerialization.data(withJSONObject: $0.json, options: [.sortedKeys]) }
        )
    }

    /// The declarations as the iPhone built them; nil if one can't be read.
    var declarations: [GeminiLiveProtocol.FunctionDeclaration]? {
        var declarations: [GeminiLiveProtocol.FunctionDeclaration] = []
        for data in functions {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = object["name"] as? String,
                  let description = object["description"] as? String,
                  let parameters = object["parameters"] as? [String: Any],
                  let behavior = (object["behavior"] as? String).flatMap(GeminiLiveProtocol.FunctionBehavior.init(rawValue:)) else {
                return nil
            }
            declarations.append(.init(name: name, description: description, parameters: parameters, behavior: behavior))
        }
        return declarations
    }

    /// zlib-compressed JSON, and its size before compression.
    func compressed() -> (data: Data, bytes: Int)? {
        guard let json = try? JSONEncoder().encode(self),
              let data = try? (json as NSData).compressed(using: .zlib) as Data else { return nil }
        return (data, json.count)
    }

    init?(compressed data: Data) {
        guard let json = try? (data as NSData).decompressed(using: .zlib) as Data,
              let setup = try? JSONDecoder().decode(Self.self, from: json) else { return nil }
        self = setup
    }
}

extension WatchVoiceWire.DirectOutgoing {
    /// What the session sends Gemini for it. Nil for the end, which the
    /// call acts on itself once the goodbye has played.
    var clientMessage: LiveVoiceClientMessage? {
        switch self {
        case .toolResponse(let id, let name, let result, let scheduling, _):
            return .toolResponse(id: id, name: name, result: result, scheduling: scheduling.flatMap(GeminiLiveProtocol.Scheduling.init(rawValue:)))
        case .textWhenIdle(let text):
            return .textTurn(text)
        case .contextWhenIdle(let text):
            return .contextNote(text)
        case .endConversation:
            return nil
        }
    }

    /// Waits for a quiet moment, as the iPhone's call holds its updates.
    var waitsForQuiet: Bool {
        switch self {
        case .textWhenIdle, .contextWhenIdle: return true
        case .toolResponse, .endConversation: return false
        }
    }
}
