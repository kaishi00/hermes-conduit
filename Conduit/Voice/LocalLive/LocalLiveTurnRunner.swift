//
//  LocalLiveTurnRunner.swift
//  Conduit
//
//  A Local Live call's turns, run as Hermes chat turns. The speech server
//  asks for each reply through the plugin (`conduit.turn`); the words go to
//  the call's chat as a spoken turn, and Hermes' reply streams back as it
//  is written, for the server to speak.
//
//  One turn at a time, as the plugin sends them. A turn that arrives while
//  Hermes is still on the last one (the user spoke again) goes into that
//  reply as a correction, which keeps its work so far, rather than starting
//  a second turn the chat couldn't take. A cancelled turn only stops being
//  spoken: Hermes' reply still lands in the chat.
//
//  What the reply writes to be seen (a table, code, links) isn't spoken:
//  unless Hermes showed it with `conduit_show`, it goes on the call's
//  screen when the reply ends (SpokenVisualSplitter).
//

import Foundation

@MainActor
final class LocalLiveTurnRunner {
    /// A chat a turn runs in: its live runtime, and the bot profile a Bot
    /// Chat lives in (nil for the profile in use).
    struct Chat: Equatable {
        var runtimeID: String
        var profile: String? = nil
    }

    enum Submission: Equatable {
        /// Hermes started the turn on this runtime.
        case started(runtimeID: String)
        /// Hermes took the words without starting a turn for them; the call
        /// says `message` instead.
        case notStarted(message: String)
    }

    struct Backend {
        /// The chat the next turn runs in, live: the call's chat (resumed
        /// when it isn't), or one made for a call that has none.
        var resolveChat: @MainActor () async throws -> Chat
        /// Whether a turn (typed, or from another device) runs there now.
        /// Throws when that can't be read: the words aren't sent then, so a
        /// typed turn is never steered.
        var isBusy: @MainActor (_ chat: Chat) async throws -> Bool
        /// Sends `text` as the chat's next spoken turn. Throws
        /// `VoiceThreadBusyError` when a turn got there first.
        var submit: @MainActor (_ chat: Chat, _ text: String) async throws -> Submission
        /// Puts `text` into the reply running on `runtimeID`.
        var redirect: @MainActor (_ runtimeID: String, _ text: String) async throws -> VoiceRedirectResult
        /// Answers the one card waiting on the user when `text` is a plain
        /// yes or no to it; true when it did.
        var answerWaiting: @MainActor (_ text: String) async -> Bool = { _ in false }
        /// Answers the approval the followed reply waits on ("once" or
        /// "deny"); true when Hermes took it.
        var respondToApproval: @MainActor (_ approval: ApprovalActivity, _ choice: String, _ profile: String?) async -> Bool
            = { _, _, _ in false }
        /// Answers one question of the clarify the followed reply waits on
        /// (`questionID` nil for a single question; `answer` nil leaves one
        /// of a form blank); the card as it stands after, or nil when
        /// Hermes didn't take it.
        var respondToClarify: @MainActor (_ clarify: ClarifyActivity, _ questionID: String?, _ answer: String?) async -> ClarifyActivity?
            = { _, _, _ in nil }
    }

    var onDelta: (@MainActor (_ turnID: String, _ text: String) -> Void)?
    var onDone: (@MainActor (_ turnID: String) -> Void)?
    /// Puts what a reply wrote to be seen on the call's screen; false when
    /// there's no screen to put it on.
    var onVisual: (@MainActor (_ markdown: String) -> Bool)?

    private let backend: Backend

    /// The plugin's open turn, still waiting for its words.
    private var turn: (id: String, spoke: Bool)?
    /// The Hermes reply the call follows, from its send until it ends.
    private struct Reply {
        let token = UUID()
        var runtimeID: String
        /// A correction is on its way to Hermes: its marker or the reply's
        /// end can arrive before Hermes answers the redirect.
        var correcting = false
        /// The completion that arrived while correcting, until Hermes says
        /// what it did with the words.
        var heldCompletion: String??
        /// A correction went into it: the marker for the words it cut off
        /// isn't its end.
        var skipsInterruption = false
        /// Corrections Hermes queued behind it: the current reply's end
        /// isn't the one the call waits for.
        var skipsCompletions = 0
        /// The command approval the reply is paused on, which the user's
        /// next yes or no answers.
        var waitingApproval: ApprovalActivity?
        /// The question the reply is paused on, which the user's next words
        /// answer.
        var waitingQuestion: ClarifyActivity?
        /// The profile of the chat it runs in.
        var profile: String?
    }
    private var reply: Reply?
    /// The open turn's words, with what's to be seen kept out.
    private var splitter = SpokenVisualSplitter()
    /// Hermes showed something with `conduit_show` while answering the
    /// open turn: what its reply writes isn't shown again.
    private var showedCard = false
    /// What the open turn said so far ends a line (or nothing was said).
    private var endedLine = true
    private var task: Task<Void, Never>?
    /// Bumped by every new turn and reset, so older work stops at its next step.
    private var generation = 0

    init(backend: Backend) {
        self.backend = backend
    }

    /// Whether a reply is still being followed (for tests and the trace).
    var isFollowingReply: Bool { reply != nil }
    /// Whether a correction is still on its way to Hermes (for tests).
    var isCorrecting: Bool { reply?.correcting == true }

    func start(turnID: String, text: String) {
        // The plugin cancels a turn before sending the next: whatever is
        // still open here has nobody waiting for it.
        turn = (turnID, false)
        splitter.reset()
        showedCard = false
        endedLine = true
        generation += 1
        let generation = generation
        // After the last turn's work: one send or correction at a time, in
        // the order the user spoke.
        let previous = task
        task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.run(turnID: turnID, text: text, generation: generation)
        }
    }

    /// Whether the turn sending now is still the newest and not cancelled,
    /// for a send that waits (a chat takeover, #1061) before going out
    /// again: a turn the call moved past stops waiting and isn't sent.
    func currentTurnCheck() -> () -> Bool {
        let generation = generation
        let turnID = turn?.id
        return { [weak self] in
            guard let self else { return false }
            return self.generation == generation && self.turn?.id == turnID
        }
    }

    func cancel(turnID: String) {
        guard turn?.id == turnID else { return }
        turn = nil
    }

    /// The connection the turns came on ended: none can be answered. The
    /// reply Hermes is writing is still followed, for the next turn.
    func dropTurn() {
        turn = nil
    }

    /// The call ended.
    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        turn = nil
        reply = nil
        splitter.reset()
        showedCard = false
        endedLine = true
    }

    private func run(turnID: String, text: String, generation: Int) async {
        // A newer turn came while this one waited: the plugin let it go.
        guard generation == self.generation else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            finish(turnID)
            return
        }
        // A yes or no to the approval the reply is paused on: Hermes takes
        // it and the reply goes on to answer this turn.
        if let approval = reply?.waitingApproval {
            let choice: String? = VoiceCallDecisionOutcome.isYes(words) ? "once"
                : VoiceThreadRouting.heldRequestAnswer(words) == .no(change: nil) ? "deny" : nil
            if let choice, await backend.respondToApproval(approval, choice, reply?.profile) {
                if reply?.waitingApproval == approval { reply?.waitingApproval = nil }
                return
            }
            guard generation == self.generation else { return }
        }
        // The answer to the question the reply is paused on: a choice the
        // words point at sends what its tap sends. A batch reads out its
        // next question.
        if let clarify = reply?.waitingQuestion, let question = HermesCallWaiting(clarify: clarify)?.openQuestion {
            let value = HermesCallWaiting.answerValue(for: words, question: question)
            if let after = await backend.respondToClarify(clarify, clarify.questions.count == 1 ? nil : question.id, value) {
                guard reply?.waitingQuestion?.requestId == clarify.requestId else { return }
                if let next = HermesCallWaiting(clarify: after)?.openQuestion {
                    reply?.waitingQuestion = after
                    say(HermesCallWaiting.spokenQuestion(next), to: turnID, generation: generation)
                } else {
                    reply?.waitingQuestion = nil
                }
                return
            }
            guard generation == self.generation else { return }
        }
        // A yes or no to what waits on the user, answered as a tap would.
        // When Hermes' reply is paused on it, the words aren't put into the
        // reply: it goes on and answers this turn. Otherwise Hermes hears
        // them as a turn, as in Classic voice.
        if await backend.answerWaiting(words), reply != nil { return }
        guard generation == self.generation else { return }
        var sentToken: UUID?
        do {
            if let running = reply {
                reply?.correcting = true
                reply?.skipsInterruption = true
                let result: VoiceRedirectResult
                do {
                    result = try await backend.redirect(running.runtimeID, words)
                } catch {
                    _ = settleCorrection(running.token, result: .notRunning)
                    throw error
                }
                let startsTurn = settleCorrection(running.token, result: result)
                guard generation == self.generation, startsTurn else { return }
            }
            let chat = try await backend.resolveChat()
            guard generation == self.generation else { return }
            if try await backend.isBusy(chat) {
                say(Self.busyLine, to: turnID, generation: generation)
                return
            }
            guard generation == self.generation else { return }
            // Its events are this turn's from the send on.
            let following = Reply(runtimeID: chat.runtimeID, profile: chat.profile)
            reply = following
            sentToken = following.token
            switch try await backend.submit(chat, words) {
            case .started(let runtimeID):
                if reply?.token == following.token, !runtimeID.isEmpty { reply?.runtimeID = runtimeID }
            case .notStarted(let message):
                if reply?.token == following.token { reply = nil }
                say(message, to: turnID, generation: generation)
            }
        } catch {
            if let sentToken, reply?.token == sentToken { reply = nil }
            say(Self.spokenFailure(for: error), to: turnID, generation: generation)
        }
    }

    /// What Hermes did with a correction: true when nothing was running to
    /// take it, so the words start a turn of their own.
    private func settleCorrection(_ token: UUID, result: VoiceRedirectResult) -> Bool {
        // The reply ended meanwhile (an error said so): nothing more here.
        guard var current = reply, current.token == token else { return false }
        let held = current.heldCompletion
        current.correcting = false
        current.heldCompletion = nil
        switch result {
        case .redirected:
            // The running reply carries on with the new words; a completion
            // that came first was the cut-off reply's.
            reply = current
            return false
        case .queued:
            // Hermes runs the words after the reply it was finishing. If that
            // reply already ended, the next completion is theirs.
            current.skipsInterruption = false
            if held == nil { current.skipsCompletions += 1 }
            reply = current
            return false
        case .notRunning:
            reply = nil
            return true
        }
    }

    // MARK: Hermes' events

    func observe(_ event: StreamEvent) {
        guard let current = reply else { return }
        if case .toolStart(let id, let name, _, _) = event, id == current.runtimeID, name == PresentedCard.toolName {
            showedCard = true
        }
        switch event {
        case .messageStart(let id), .reasoningDelta(let id, _), .messageInterim(let id, _, _),
             .toolStart(let id, _, _, _), .toolComplete(let id, _, _, _):
            guard id == current.runtimeID else { return }
            // Hermes is writing again after the correction: a marker after
            // this ends the reply.
            if !current.correcting { reply?.skipsInterruption = false }
            // Writing again: whatever it waited on was answered.
            reply?.waitingApproval = nil
            reply?.waitingQuestion = nil
        case .messageDelta(let id, let text):
            guard id == current.runtimeID else { return }
            // Until Hermes takes the correction, the words are the reply
            // the user talked over: the new turn doesn't say them.
            guard !current.correcting else { return }
            reply?.skipsInterruption = false
            speak(text)
        case .messageComplete(let id, _, let content, _, _):
            guard id == current.runtimeID else { return }
            // The notice for a reply a correction cut off is never its answer.
            if VoiceBackgroundJobSupervisor.isInterruptionNotice(content) { return }
            if current.correcting {
                reply?.heldCompletion = .some(content)
                return
            }
            if current.skipsCompletions > 0 {
                reply?.skipsCompletions -= 1
                return
            }
            reply = nil
            if let turn, !turn.spoke, let content { speak(content) }
            finishTurn()
        case .messageInterrupted(let id):
            guard id == current.runtimeID else { return }
            if current.skipsInterruption {
                reply?.skipsInterruption = false
                return
            }
            reply = nil
            finishTurn()
        case .messageError(let id, _):
            guard id == current.runtimeID else { return }
            reply = nil
            if let turn { say(Self.errorLine, to: turn.id, generation: generation) }
        case .approval(let id, let activity):
            guard id == current.runtimeID else { return }
            reply?.waitingApproval = activity
            guard let turn else { return }
            say(Self.approvalLine(activity), to: turn.id, generation: generation)
        case .clarify(let id, let activity):
            guard id == current.runtimeID else { return }
            reply?.waitingQuestion = activity
            guard let turn else { return }
            // Hermes asks: the call reads the question out with its
            // choices, and the user's next words answer it.
            if let question = HermesCallWaiting(clarify: activity)?.openQuestion {
                say(HermesCallWaiting.spokenQuestion(question), to: turn.id, generation: generation)
            } else {
                say(Self.needsInputLine, to: turn.id, generation: generation)
            }
        case .inputPrompt(let id, _):
            guard id == current.runtimeID, let turn else { return }
            // Hermes waits on the user: the call says where to answer, and
            // the reply is still followed for the turn after.
            say(Self.needsInputLine, to: turn.id, generation: generation)
        default:
            return
        }
    }

    // MARK: Speaking

    /// Hermes' words, as they come.
    private func speak(_ text: String) {
        guard let current = turn, !text.isEmpty else { return }
        turn?.spoke = true
        let spoken = splitter.feed(text)
        if !spoken.isEmpty {
            endedLine = spoken.hasSuffix("\n")
            onDelta?(current.id, spoken)
        }
    }

    /// A line of the call's own instead of Hermes' reply.
    private func say(_ text: String, to turnID: String, generation: Int) {
        guard generation == self.generation, turn?.id == turnID else { return }
        turn?.spoke = true
        // What the reply still held ends with it: nothing of it follows the
        // call's line.
        splitter.reset()
        onDelta?(turnID, text)
        finish(turnID)
    }

    private func finishTurn() {
        guard let current = turn else { return }
        finish(current.id)
    }

    private func finish(_ turnID: String) {
        guard turn?.id == turnID else { return }
        let rest = splitter.finish()
        if !rest.isEmpty {
            endedLine = rest.hasSuffix("\n")
            onDelta?(turnID, rest)
        }
        if splitter.hasVisual, !showedCard, onVisual?(splitter.visualMarkdown) == true {
            onDelta?(turnID, (endedLine ? "" : "\n") + Self.onScreenLine)
        }
        splitter.reset()
        showedCard = false
        endedLine = true
        turn = nil
        onDone?(turnID)
    }

    // Spoken to the user by their speech server.
    static var busyLine: String {
        AppLocalization.string("Hermes is still busy in this chat. Try again in a moment.")
    }

    /// What the call says when a turn couldn't go to Hermes: the reason,
    /// when the send gave one (the chat is open in Hermes Desktop, #1061).
    static func spokenFailure(for error: Error) -> String {
        if error is VoiceThreadBusyError { return busyLine }
        if case .unavailable(let reason)? = error as? VoiceAudioError, !reason.isEmpty { return reason }
        return failureLine
    }

    static var failureLine: String {
        AppLocalization.string("Hermes couldn't take that just now.")
    }

    static var errorLine: String {
        AppLocalization.string("Hermes ran into a problem with that.")
    }

    static var onScreenLine: String {
        AppLocalization.string("The rest is on your screen.")
    }

    /// The command Hermes asks to run, which a yes or no answers here.
    static func approvalLine(_ approval: ApprovalActivity) -> String {
        let asked = approval.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = asked.isEmpty ? approval.command : asked
        let clipped = what.count > 200 ? String(what.prefix(200)) + "…" : what
        return AppLocalization.string("Hermes needs your OK to go on: \(clipped). Say yes to allow it once, or no.")
    }

    static var needsInputLine: String {
        AppLocalization.string("Hermes needs your answer in the chat before it can go on.")
    }
}
