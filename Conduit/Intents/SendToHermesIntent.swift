//
//  SendToHermesIntent.swift
//  Conduit
//
//  The "Send to Hermes" Shortcuts action: a shortcut hands Conduit some
//  text (a note, the weather, anything a Shortcut can read, on any
//  automation trigger) and Hermes gets it as a chat message, without
//  Conduit opening. With Wait for Answer on, the action gives Hermes's
//  reply back to the shortcut, so "Ask Hermes" from Siri speaks it.
//
//  It goes over the same gateway connection the app uses, so it needs no
//  plugin and works with any Hermes Conduit can reach. iOS gives an action
//  run in the background about half a minute, so a longer answer is left
//  in the chat and the shortcut is told so.
//
//  Shared shortcuts bind to this type's name and to its parameter names:
//  never rename them, and add new parameters only as optional.
//

import AppIntents
import Foundation

/// What a run asks for.
struct ShortcutSendRequest: Equatable {
    var text: String
    /// Keep every run in one chat with this name. Nil: a new chat each run.
    var chatName: String?
    /// The profile the chat lives in. Nil: the profile in use.
    var profile: String?
    var waitsForAnswer: Bool
}

enum ShortcutSendOutcome: Equatable {
    /// Hermes replied before the run's time was up.
    case answered(String)
    /// Sent; Wait for Answer was off.
    case sent
    /// Hermes was still working when the time was up.
    case stillWorking
    /// Hermes asked a question or wants an approval in the chat.
    case needsInput
    /// The named chat was busy; Hermes queued the text there.
    case queued
    /// The named chat was busy; Hermes added the text to the reply running.
    case joinedRunningReply

    /// What the shortcut gets back.
    var text: String {
        switch self {
        case .answered(let reply): return reply
        case .sent: return AppLocalization.string("Sent to Hermes.")
        case .stillWorking: return AppLocalization.string("Hermes is still working on it. The answer will be in the chat in Conduit.")
        case .needsInput: return AppLocalization.string("Hermes needs your answer. Open the chat in Conduit.")
        case .queued: return AppLocalization.string("Hermes is busy in that chat, so it will read this when its current reply finishes.")
        case .joinedRunningReply: return AppLocalization.string("Hermes added this to the reply already running in that chat.")
        }
    }
}

struct ShortcutSendError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static var empty: ShortcutSendError {
        ShortcutSendError(message: AppLocalization.string("There's no text to send. Give Send to Hermes a message."))
    }

    static var notConnected: ShortcutSendError {
        ShortcutSendError(message: AppLocalization.string("Conduit couldn't reach Hermes. Open Conduit and check the connection."))
    }
}

/// Hermes operations a run needs. Closures, so AppState binds them to the
/// client in use and tests can script them.
struct ShortcutSendBackend {
    /// Waits for the connection; false when Hermes can't be reached in time.
    var connect: @MainActor (_ deadline: Date) async -> Bool
    var activeProfile: @MainActor () -> String
    /// A new chat titled `title` in `profile`.
    var createChat: @MainActor (_ profile: String, _ title: String) async throws -> VoiceThreadTarget
    /// The runtime the chat's next turn runs on, resuming it when it isn't live.
    var resumeChat: @MainActor (_ chat: VoiceThreadTarget) async throws -> String
    var submit: @MainActor (_ chat: VoiceThreadTarget, _ runtimeID: String, _ text: String) async throws -> PromptSubmissionOutcome
    var liveSessions: @MainActor (_ profile: String) async throws -> [LiveSessionStatus]
    var latestReply: @MainActor (_ chat: VoiceThreadTarget) async -> String?
    var sleep: (_ seconds: Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    var now: () -> Date = Date.init
}

/// The chats runs with a Chat Name went to, so the next run with that name
/// joins the same chat.
struct ShortcutChatStore {
    static let storageKey = "conduit.shortcutChats.v1"
    static let maximumChats = 40

    private struct Entry: Codable {
        var key: String
        var chat: VoiceThreadTarget
        var usedAt: Date
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(name: String, profile: String) -> String {
        profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "\n"
            + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func chat(named name: String, profile: String) -> VoiceThreadTarget? {
        let key = Self.key(name: name, profile: profile)
        return entries().first { $0.key == key }?.chat
    }

    func save(_ chat: VoiceThreadTarget, named name: String, profile: String, at date: Date = Date()) {
        let key = Self.key(name: name, profile: profile)
        var list = entries().filter { $0.key != key }
        list.append(Entry(key: key, chat: chat, usedAt: date))
        list.sort { $0.usedAt > $1.usedAt }
        write(Array(list.prefix(Self.maximumChats)))
    }

    func forget(named name: String, profile: String) {
        let key = Self.key(name: name, profile: profile)
        write(entries().filter { $0.key != key })
    }

    private func entries() -> [Entry] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func write(_ list: [Entry]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// One run of the action: find or make the chat, send, and wait for the
/// reply until `deadline` when asked to.
@MainActor
struct ShortcutSender {
    static let maximumTextLength = 20_000
    static let pollInterval = 1.5

    let backend: ShortcutSendBackend
    var chats = ShortcutChatStore()

    func send(_ request: ShortcutSendRequest, deadline: Date) async throws -> ShortcutSendOutcome {
        let text = String(request.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumTextLength))
        guard !text.isEmpty else { throw ShortcutSendError.empty }
        guard await backend.connect(deadline) else { throw ShortcutSendError.notConnected }
        let profile = Self.cleaned(request.profile) ?? backend.activeProfile()
        let name = Self.cleaned(request.chatName).map { String($0.prefix(80)) }

        var chat: VoiceThreadTarget
        var runtimeID: String
        var reused = false
        if let name, let saved = chats.chat(named: name, profile: profile),
           let resumed = try? await backend.resumeChat(saved) {
            chat = saved
            runtimeID = resumed
            reused = true
        } else {
            chat = try await backend.createChat(profile, name ?? Self.title(for: text))
            runtimeID = chat.runtimeSessionID
        }
        if !runtimeID.isEmpty { chat.runtimeSessionID = runtimeID }
        if let name { chats.save(chat, named: name, profile: profile, at: backend.now()) }

        // A reused chat already has replies: only a new one answers this run.
        var earlier: String?
        if reused && request.waitsForAnswer { earlier = await backend.latestReply(chat) }
        switch try await backend.submit(chat, runtimeID, text) {
        case .accepted: break
        case .queued: return .queued
        case .steered, .redirected: return .joinedRunningReply
        }
        guard request.waitsForAnswer else { return .sent }
        return await waitForReply(in: chat, runtimeID: runtimeID, earlier: earlier, deadline: deadline)
    }

    private func waitForReply(in chat: VoiceThreadTarget, runtimeID: String, earlier: String?, deadline: Date) async -> ShortcutSendOutcome {
        var sawRunning = false
        var polls = 0
        var missed = 0
        while backend.now().addingTimeInterval(Self.pollInterval) < deadline {
            do { try await backend.sleep(Self.pollInterval) } catch { return .stillWorking }
            polls += 1
            guard let rows = try? await backend.liveSessions(chat.profile ?? backend.activeProfile()) else { continue }
            let row = rows.first {
                $0.runtimeSessionId == runtimeID || chat.owns(sessionID: $0.runtimeSessionId) || chat.owns(sessionID: $0.storedSessionId)
            }
            if let row {
                missed = 0
                if row.status == "waiting" { return .needsInput }
                if row.isRunning {
                    sawRunning = true
                    continue
                }
                // An idle row before the turn was ever seen running may be
                // the moment between the send and the turn starting.
                if !sawRunning && polls < 3 { continue }
            } else {
                // Absence counts only when it repeats.
                missed += 1
                if missed < 2 { continue }
            }
            if let reply = await newReply(in: chat, earlier: earlier) { return .answered(reply) }
            // The reply can land a moment after the turn ends.
            guard backend.now().addingTimeInterval(1) < deadline, (try? await backend.sleep(1)) != nil else { break }
            if let reply = await newReply(in: chat, earlier: earlier) { return .answered(reply) }
            break
        }
        return .stillWorking
    }

    private func newReply(in chat: VoiceThreadTarget, earlier: String?) async -> String? {
        guard let reply = await backend.latestReply(chat)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reply.isEmpty, reply != earlier?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return reply
    }

    /// A new chat's title: the text's first line, shortened.
    static func title(for text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = trimmed.count > 60 ? String(trimmed.prefix(59)) + "…" : trimmed
        return AppLocalization.string("Shortcut: \(short)")
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Background-only: the text goes to Hermes without Conduit opening.
@available(iOS 16.0, *)
struct SendToHermesIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to Hermes"
    static var description = IntentDescription(
        "Send text to your Hermes agent as a chat message. With Wait for Answer on, Hermes's reply comes back to the shortcut."
    )

    /// iOS 17–25 declaration; see `StartVoiceConversationIntent`. Must stay
    /// a boolean literal for the App Intents metadata processor.
    @available(iOS, deprecated: 26.0, message: "Use supportedModes on iOS 26+; retained for iOS 17–25.")
    static var openAppWhenRun: Bool = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .background
    }

    @Parameter(
        title: "Message",
        requestValueDialog: "What should Hermes get?",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var message: String

    @Parameter(title: "Wait for Answer", default: true)
    var waitForAnswer: Bool

    @Parameter(title: "Chat Name")
    var chatName: String?

    @Parameter(title: "Profile")
    var profile: ConduitProfileEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to Hermes") {
            \.$waitForAnswer
            \.$chatName
            \.$profile
        }
    }

    init() {}

    /// iOS lets an action run in the background for about 30 seconds.
    static let runTime: TimeInterval = 25

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let request = ShortcutSendRequest(text: message, chatName: chatName, profile: profile?.id, waitsForAnswer: waitForAnswer)
        let deadline = Date().addingTimeInterval(Self.runTime)
        let text = try await Self.run(request, deadline: deadline).text
        return .result(value: text, dialog: "\(text)")
    }

    @MainActor
    private static func run(_ request: ShortcutSendRequest, deadline: Date) async throws -> ShortcutSendOutcome {
        try await AppStateRuntimeRegistry.shared.appState.sendFromShortcut(request, deadline: deadline)
    }
}
