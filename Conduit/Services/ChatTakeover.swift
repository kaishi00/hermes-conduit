//
//  ChatTakeover.swift
//  Conduit
//
//  Taking a chat over from Hermes Desktop or a terminal (#304). Hermes lets
//  one app own a chat at a time, and Desktop keeps its claim until the chat
//  is closed there, so a send from Conduit is refused with
//  SESSION_NOT_OWNED. The conduit_push plugin's takeover route drops the
//  other app's claim (never while it is running a turn), and the next send
//  claims the chat for Conduit.
//

import Foundation

/// The takeover offer or progress for the chat that was refused.
struct ChatTakeoverState: Equatable {
    enum Phase: Equatable {
        /// The send was refused; Conduit offers to take the chat over.
        case offered
        /// The other app is running a turn; Conduit asks again shortly.
        case waiting
        /// The chat is Conduit's now; the composer sends its draft again.
        case ready
        /// Taking over failed; the message says why. Tapping again retries.
        case failed(String)
        /// Taking over can't work until the host changes (plugin missing or
        /// too old, Hermes too old); the message says what to update.
        case unavailable(String)
        /// Conduit on another device, or the Hermes web chat, holds the
        /// chat. The host never takes it from them, so there's no retry.
        case heldHere
    }

    let sessionID: String
    /// Every id the chat goes by: the host matches its claim on any of them.
    let sessionIDs: [String]
    /// The app that holds the chat (`desktop`, `cli`, …), when Hermes named it.
    let surface: String?
    /// The text whose send was refused. The composer only resends after a
    /// takeover when its draft is this message, so a refused voice or other
    /// non-composer turn never sends an unrelated draft.
    var refusedText = ""
    var phase: Phase
    /// Changes every time a takeover finishes, so the composer resends once.
    var readyToken = 0

    /// The app that holds the chat, as the sentences below name it.
    enum Owner: Equatable {
        case desktop, terminal, otherWindow
    }

    var owner: Owner { Self.owner(surface) }

    static func owner(_ surface: String?) -> Owner {
        switch surface?.lowercased() {
        case "desktop": return .desktop
        case "cli", "tui": return .terminal
        default: return .otherWindow
        }
    }

    // Each sentence names its owner whole: languages with case endings
    // inflect the owner differently after "in", "from" and as the subject.

    /// The offer, while another app holds the chat.
    var openElsewhereMessage: String {
        switch owner {
        case .desktop: return AppLocalization.string("This chat is open in Hermes Desktop. Take it over to send from here.")
        case .terminal: return AppLocalization.string("This chat is open in a Hermes terminal. Take it over to send from here.")
        case .otherWindow: return AppLocalization.string("This chat is open in another Hermes window. Take it over to send from here.")
        }
    }

    /// Progress, while Conduit waits for the other app to let go.
    var takingOverMessage: String {
        switch owner {
        case .desktop: return AppLocalization.string("Taking this chat over from Hermes Desktop. If it's replying, Conduit waits for the reply to finish.")
        case .terminal: return AppLocalization.string("Taking this chat over from a Hermes terminal. If it's replying, Conduit waits for the reply to finish.")
        case .otherWindow: return AppLocalization.string("Taking this chat over from another Hermes window. If it's replying, Conduit waits for the reply to finish.")
        }
    }

    /// The failure when the other app is still running a turn at the deadline.
    var stillReplyingMessage: String {
        switch owner {
        case .desktop: return AppLocalization.string("Hermes Desktop is still replying in this chat. Try again when it finishes.")
        case .terminal: return AppLocalization.string("A Hermes terminal is still replying in this chat. Try again when it finishes.")
        case .otherWindow: return AppLocalization.string("Another Hermes window is still replying in this chat. Try again when it finishes.")
        }
    }

    /// The stored session id and surface from the refusal's `Details:` line:
    /// "Details: session <id> opened by <surface> 5m ago."
    static func details(fromRefusal message: String) -> (sessionID: String?, surface: String?) {
        guard let range = message.range(of: "Details: session ") else { return (nil, nil) }
        let words = message[range.upperBound...]
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
        let sessionID = words.first.flatMap { $0.isEmpty ? nil : $0 }
        guard words.count >= 4, words[1] == "opened", words[2] == "by" else { return (sessionID, nil) }
        var surface = words[3]
        if surface.hasSuffix(".") { surface.removeLast() }
        return (sessionID, surface.isEmpty ? nil : surface)
    }
}

enum ChatTakeoverPreference {
    /// Device-only: take a chat over as soon as a send is refused.
    static let automaticKey = "conduit.takeOverChatsAutomatically"
}

enum ChatTakeoverError: Error, Equatable {
    /// The plugin predates the takeover route (or isn't installed).
    case pluginMissing
    /// The Hermes host has no ownership registry to change.
    case unsupported
    case malformed
}

/// The host's answer to one takeover request.
enum ChatTakeoverOutcome: Equatable {
    /// The other app's claim is gone (or there was none): send again.
    case ready
    /// The other app is running a turn on the chat: ask again shortly.
    case busy
    /// This dashboard process itself holds the chat (Conduit on another
    /// device, or the web chat). The route never touches that claim.
    case sameHost
}

/// The conduit_push plugin's takeover route.
@MainActor
final class ChatTakeoverClient {
    static let path = "/api/plugins/conduit_push/sessions/takeover"
    static let maxSessionIDs = 4

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    private let request: Request

    init(request: @escaping Request) {
        self.request = request
    }

    func takeOver(sessionIDs: [String], profile: String) async throws -> ChatTakeoverOutcome {
        let body: [String: Any] = ["session_ids": Array(sessionIDs.prefix(Self.maxSessionIDs))]
        do {
            let response = try await request(DashboardPath.withProfile(Self.path, profile: profile), "POST", body)
            return try Self.outcome(from: response)
        } catch let error as DashboardTicketBridgeError {
            throw Self.mapped(error) ?? error
        }
    }

    static func mapped(_ error: DashboardTicketBridgeError) -> ChatTakeoverError? {
        guard case .http(let status, _) = error else { return nil }
        switch status {
        case 404, 405: return .pluginMissing
        case 501: return .unsupported
        default: return nil
        }
    }

    static func outcome(from response: [String: Any]) throws -> ChatTakeoverOutcome {
        guard response["ok"] as? Bool == true, let status = response["status"] as? String else {
            throw ChatTakeoverError.malformed
        }
        switch status {
        case "taken_over", "free": return .ready
        case "busy": return .busy
        case "same_host": return .sameHost
        default: throw ChatTakeoverError.malformed
        }
    }
}

extension ChatTakeoverState {
    /// Whether `draft` is the refused message, ignoring surrounding whitespace.
    /// An attachment-only send matches an empty draft that still has attachments.
    func isRefusedMessage(_ draft: String, hasAttachments: Bool = false) -> Bool {
        let refused = refusedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if refused.isEmpty { return draft.isEmpty && hasAttachments }
        return refused == draft
    }
}
