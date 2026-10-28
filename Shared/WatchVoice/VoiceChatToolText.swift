//
//  VoiceChatToolText.swift
//  Conduit and the Conduit Watch app
//
//  What a live call's voice model hears from the chat tools (find_chat,
//  open_chat, read_chat, and GPT-Live's "Find chat:", "Open chat:" and
//  "Read chat:" delegations), shared by the iPhone's bridges and a Watch
//  call's relayed answers, so both say the same. A Watch call can't open a
//  chat (`opens` false): its words never mention opening one. The matches
//  and the chat itself come fenced as data (VoiceChatFinder on the iPhone,
//  the host plugin's watch chats on the relay). Written for the model, not
//  shown, so not localized.
//

import Foundation

enum VoiceChatToolText {
    static let findChat = "find_chat"
    static let openChat = "open_chat"
    static let readChat = "read_chat"

    // MARK: Gemini Live and Grok Live

    /// What to do with a search's matches.
    static func searchNext(count: Int, opens: Bool) -> String {
        if count == 1 {
            return opens
                ? "One chat matches. If it fits what the user asked for, call open_chat with number 1, or read_chat with number 1 to talk about it."
                : "One chat matches. If it fits what the user asked for, call read_chat with number 1 to talk about it."
        }
        return (opens
            ? "If one clearly fits what the user asked for, call open_chat with its number, or read_chat with its number to talk about it."
            : "If one clearly fits what the user asked for, call read_chat with its number to talk about it.")
            + " Otherwise say the titles of the likeliest two or three, with when, and ask which one."
    }

    static let noMatches = "No chats match that. Tell the user, and offer to try other words."
    static let unknownForRead = "That number isn't one of the chats find_chat returned. Call find_chat first, then read_chat with a number from its list."

    /// How to use a chat read into the call.
    static let readNote = "Talk about this chat from what it says: answer what the user asked about it, or say in a few sentences what it was about. Don't read it out word for word unless they ask; skip code, links and long lists. If it doesn't hold what they asked about, say so."

    static func emptyChat(title: String) -> String {
        let title = plainTitle(title)
        return "\(title.isEmpty ? "That chat" : "\"\(title)\"") has no messages to read. Tell the user."
    }

    /// A chat title outside the fence: one line, clipped, without angle or
    /// square brackets, so it can't open or close a tag or a bracketed note.
    static func plainTitle(_ raw: String) -> String {
        let line = String(raw.unicodeScalars.filter { !"<>[]".unicodeScalars.contains($0) }.map(Character.init))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count <= 120 ? line : String(line.prefix(119)) + "…"
    }

    static func failed(_ reason: String) -> String {
        reason + " Tell the user in a few words."
    }

    /// find_chat's result: `summary` is the fenced, numbered matches.
    static func searchResult(summary: String, count: Int, opens: Bool) -> [String: String] {
        count == 0
            ? ["chats": "", "message": noMatches]
            : ["chats": summary, "message": searchNext(count: count, opens: opens)]
    }

    /// read_chat's result for a chat that was read: `chat` is the fenced
    /// text. An attached file is named, not given by its path.
    static func readResult(chat: String) -> [String: String] {
        ["chat": GatewayMediaTags.namingFiles(in: chat), "message": readNote]
    }

    static func emptyReadResult(title: String) -> [String: String] {
        ["chat": "", "message": emptyChat(title: title)]
    }

    /// GeminiLiveConversationController.fallbackText for the chat tools:
    /// said instead when the call's connection is gone.
    static func fallbackText(for result: [String: String], name: String) -> String? {
        if name == findChat {
            // Its matches stay numbered where they were found, so the next
            // tool call can still name one.
            if let chats = result["chats"], !chats.isEmpty {
                return "[The chat search you just made found these:\n\(chats)\n\(result["message"] ?? "")]"
            }
            if let error = result["error"], !error.isEmpty {
                return "[The chat search you just made failed: \(error)]"
            }
            return result["message"].map { "[The chat search you just made: \($0)]" }
        }
        if name == openChat {
            if result["status"] == "opened", let message = result["message"] { return "[The chat you just asked to open: \(message)]" }
            return result["error"].map { "[Opening the chat failed: \($0)]" }
        }
        if name == readChat {
            if let chat = result["chat"], !chat.isEmpty {
                return "[The chat you just asked to read:\n\(chat)\n\(result["message"] ?? "")]"
            }
            if let error = result["error"], !error.isEmpty { return "[Reading the chat failed: \(error)]" }
            return result["message"].map { "[The chat you just asked to read: \($0)]" }
        }
        return nil
    }

    // MARK: GPT-Live delegations

    /// "Find chat: GPU setup" at the very start of a delegation: the words
    /// to look the chat up by.
    static func findChatMarker(in request: String) -> String? {
        guard let range = request.range(of: #"^\s*find\s+(?:a\s+|the\s+|my\s+)?chats?\s*:"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(request[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Open chat: 2" (or "Open chat 2:", or just "Open chat 2") at the very
    /// start of a delegation: the number of the found chat to open.
    static func openChatMarker(in request: String) -> String? {
        chatNumberMarker(verb: "open", in: request)
    }

    /// "Read chat: 2", like "Open chat: 2": the number of the found chat to read.
    static func readChatMarker(in request: String) -> String? {
        chatNumberMarker(verb: "read", in: request)
    }

    private static func chatNumberMarker(verb: String, in request: String) -> String? {
        let pattern = #"^\s*"# + verb + #"\s+(?:the\s+|my\s+)?(?:chats?|conversations?)\s*(?:(?:number\s*|#\s*)?(\d{1,2})\s*(?::|$)|:\s*(?:number\s*|#\s*)?(\d{1,2})\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: request, range: NSRange(request.startIndex..., in: request)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: request) { return String(request[range]) }
        }
        return nil
    }

    /// What a "Find chat:" delegation is answered with when matches came back.
    static func delegatedSearchFound(summary: String, count: Int, opens: Bool) -> String {
        let next: String
        if count == 1 {
            next = opens
                ? "One chat matches. If it fits what the user asked for, delegate \"Open chat: 1\", or \"Read chat: 1\" to talk about it."
                : "One chat matches. If it fits what the user asked for, delegate \"Read chat: 1\" to talk about it."
        } else {
            next = (opens
                ? "If one clearly fits what the user asked for, delegate \"Open chat:\" with its number, like \"Open chat: 2\", or \"Read chat:\" with its number to talk about it."
                : "If one clearly fits what the user asked for, delegate \"Read chat:\" with its number, like \"Read chat: 2\", to talk about it.")
                + " Otherwise say the titles of the likeliest two or three, with when, and ask which one; don't read the lines out."
        }
        return "[Chats that match:\n\(summary)\n\(next)]"
    }

    static let delegatedNoMatches = "[No chats match that. Tell the user, and offer to try other words.]"

    static func delegatedSearchFailed(_ reason: String) -> String {
        "[Conduit couldn't search the chats: \(reason) Tell the user in a few words.]"
    }

    static func delegatedRead(chat: String) -> String {
        "[\(GatewayMediaTags.namingFiles(in: chat))\n\(readNote)]"
    }

    static func delegatedEmptyChat(title: String) -> String {
        "[\(emptyChat(title: title))]"
    }

    static let delegatedUnknownChat = "[That isn't one of the chats found. Delegate \"Find chat:\" with a few words from the topic first.]"

    static func delegatedReadFailed(_ reason: String) -> String {
        "[Conduit couldn't read the chat: \(reason) Tell the user in a few words.]"
    }
}
