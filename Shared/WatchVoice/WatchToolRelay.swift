//
//  WatchToolRelay.swift
//  Conduit and the Conduit Watch app
//
//  A Watch call's lookups through the push relay while the iPhone can't
//  be reached (designs/apple-watch-voice-direct.md, "Wrist-down tools
//  through the relay"). The Watch seals each call with its grant's key and
//  sends it to the relay; the Hermes plugin, polling the relay, opens it,
//  runs it as /web-search or /memory/recall would, and seals the answer
//  back. The relay carries bytes it can neither read nor forge.
//
//  The sealing mirrors conduit_push's dashboard/plugin_api.py, checked by
//  shared test vectors. The answers mirror what the iPhone's tool bridge
//  hands the model for the same host response, checked by a parity test.
//

import CryptoKit
import Foundation

/// The grant's sealing: HKDF-SHA256 from its 32-byte root to one
/// ChaCha20-Poly1305 key per direction, with the grant and the call's id
/// bound in as associated data, so an answer can't be replayed to
/// another call or sent back the other way.
enum WatchToolSeal {
    enum Direction: String {
        /// What the Watch asks Hermes.
        case call
        /// What Hermes answers.
        case result
    }

    enum Failure: Error, Equatable {
        case malformed
        case didNotVerify
        case tooLarge
    }

    /// A sealed message as the relay carries it: the nonce and the
    /// ciphertext with its tag, base64url.
    struct Sealed: Equatable {
        var n: String
        var ct: String
    }

    struct Keys {
        let call: SymmetricKey
        let result: SymmetricKey

        /// Nil unless `root` is 32 bytes.
        init?(root: Data) {
            guard root.count == 32 else { return nil }
            let material = SymmetricKey(data: root)
            func derive(_ direction: Direction) -> SymmetricKey {
                HKDF<SHA256>.deriveKey(
                    inputKeyMaterial: material,
                    salt: Data(WatchToolSeal.salt.utf8),
                    info: Data(WatchToolSeal.info(direction).utf8),
                    outputByteCount: 32
                )
            }
            call = derive(.call)
            result = derive(.result)
        }

        func key(_ direction: Direction) -> SymmetricKey {
            direction == .call ? call : result
        }
    }

    static let salt = "conduit-watch-tools-v1"
    /// The most a sealed call carries: a tool name and a short query.
    static let maxCallBytes = 4 * 1024

    static func info(_ direction: Direction) -> String {
        switch direction {
        case .call: return "conduit-watch-tools-v1 call watch-to-host"
        case .result: return "conduit-watch-tools-v1 result host-to-watch"
        }
    }

    static func associatedData(_ direction: Direction, grantID: String, rid: String) -> Data {
        Data(["conduit-watch-tools/1", direction.rawValue, "grant=\(grantID)", "rid=\(rid)"].joined(separator: "\n").utf8)
    }

    /// A fixed nonce is for test vectors only.
    static func seal(
        _ plaintext: Data,
        keys: Keys,
        direction: Direction,
        grantID: String,
        rid: String,
        nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> Sealed {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: keys.key(direction),
            nonce: nonce,
            authenticating: associatedData(direction, grantID: grantID, rid: rid)
        )
        let nonceBytes = box.nonce.withUnsafeBytes { Data($0) }
        return Sealed(n: base64URL(nonceBytes), ct: base64URL(box.ciphertext + box.tag))
    }

    static func open(_ sealed: Sealed, keys: Keys, direction: Direction, grantID: String, rid: String) throws -> Data {
        guard let nonceBytes = data(base64URL: sealed.n), nonceBytes.count == 12,
              let combined = data(base64URL: sealed.ct), combined.count >= 16,
              let nonce = try? ChaChaPoly.Nonce(data: nonceBytes),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: combined.dropLast(16), tag: combined.suffix(16)) else {
            throw Failure.malformed
        }
        do {
            return try ChaChaPoly.open(box, using: keys.key(direction), authenticating: associatedData(direction, grantID: grantID, rid: rid))
        } catch {
            throw Failure.didNotVerify
        }
    }

    /// A JSON object as the host reads it: sorted keys, no escaped slashes.
    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// A new call's id: 16 random bytes, base64url.
    static func newRequestID() -> String {
        base64URL(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func data(base64URL text: String) -> Data? {
        guard text.unicodeScalars.allSatisfy({ scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
            default: return false
            }
        }), text.count % 4 != 1 else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// What a relayed lookup hands the model: the result the iPhone's tool
/// bridge builds for the same host response (GeminiLiveToolBridge's
/// web_search and recall_memory, GeminiLiveTokenClient's parsing), with
/// the scheduling and fallback the iPhone's broker sends the Watch.
/// Written for the model, not shown, so not localized.
enum WatchToolAnswer {
    static let webSearch = "web_search"
    static let recallMemory = "recall_memory"
    static let tools: Set<String> = [webSearch, recallMemory]

    /// GeminiLiveTokenClient.webSearchLimit.
    static let webSearchLimit = 3
    /// GeminiLiveTokenClient.memoryRecallLimit.
    static let memoryRecallLimit = 4000
    /// GeminiLiveToolBridge.lookupAnswerNote.
    static let lookupAnswerNote = "Answer the user now from this result; don't say again that you're checking or looking it up."
    /// A lookup that outlasted its wait, as the iPhone's broker answers it.
    static let tookTooLong: [String: String] = ["error": "That took too long. Tell the user in a few words."]

    /// The trimmed query; nil when there is none.
    static func query(_ arguments: [String: String]) -> String? {
        let query = arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return query.isEmpty ? nil : query
    }

    /// What the host runs: the tool and the arguments the iPhone's client
    /// would send its route.
    static func request(name: String, query: String) -> [String: Any] {
        let arguments: [String: Any] = name == webSearch ? ["query": query, "limit": webSearchLimit] : ["query": query]
        return ["tool": name, "args": arguments]
    }

    /// The bridge's answer to a call without a query.
    static func missingQuery(name: String) -> [String: String] {
        noted(["error": "query is required"], name: name)
    }

    /// The bridge's answer for the host's response to `name`.
    static func result(name: String, body: [String: Any]) -> [String: String] {
        if name == webSearch {
            guard body["ok"] as? Bool == true, let items = body["results"] as? [[String: Any]] else {
                return noted(["error": reason(body) ?? "The Hermes web search returned no results"], name: name)
            }
            let lines = items.compactMap { item -> String? in
                guard let url = item["url"] as? String, !url.isEmpty else { return nil }
                return "\(item["title"] as? String ?? ""): \(item["snippet"] as? String ?? "") (\(url))"
            }
            guard !lines.isEmpty else { return noted(["results": "No results."], name: name) }
            let summary = lines.enumerated().map { index, line in "\(index + 1). \(line)" }.joined(separator: "\n")
            return noted(["results": summary], name: name)
        }
        guard body["ok"] as? Bool == true, body["available"] as? Bool != false,
              let results = body["results"] as? String else {
            return ["error": reason(body) ?? "Hermes memory is not available"]
        }
        let text = String(results.trimmingCharacters(in: .whitespacesAndNewlines).prefix(memoryRecallLimit))
        return ["results": text.isEmpty ? "Nothing in memory about that." : text]
    }

    /// The answer as the iPhone's broker would send it to the Watch.
    static func outgoing(id: String, name: String, result: [String: String]) -> WatchVoiceWire.DirectOutgoing {
        .toolResponse(
            id: id,
            name: name,
            result: result,
            scheduling: GeminiLiveProtocol.Scheduling.whenIdle.rawValue,
            fallback: fallbackText(for: result)
        )
    }

    /// GeminiLiveConversationController.lookupFallbackText: said instead
    /// when the call's connection is gone.
    static func fallbackText(for result: [String: String]) -> String? {
        if let results = result["results"], !results.isEmpty {
            return "[The lookup you just made returned this. Answer the user's question from it now, without another lookup; don't say again that you're checking or looking it up:\n\(results)]"
        }
        if let error = result["error"], !error.isEmpty {
            return "[The lookup you just made failed (\(error)). Tell the user in one short sentence.]"
        }
        return nil
    }

    /// Every web_search answer carries the note, a failure included.
    private static func noted(_ result: [String: String], name: String) -> [String: String] {
        guard name == webSearch else { return result }
        var result = result
        result["note"] = lookupAnswerNote
        return result
    }

    private static func reason(_ body: [String: Any]) -> String? {
        let reason = body["detail"] as? String ?? body["error"] as? String ?? body["reason"] as? String
        return reason.flatMap { $0.isEmpty ? nil : $0 }
    }
}
