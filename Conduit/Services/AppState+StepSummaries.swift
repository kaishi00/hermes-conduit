//
//  AppState+StepSummaries.swift
//  Conduit
//
//  One sentence for a finished turn's run of steps (opt-in, Settings >
//  Chat): asked of Hermes with a hidden /btw once the turn ends, and kept
//  on this device per dashboard and profile (ChatStepSummaries).
//

import Foundation

extension AppState {
    /// Once a turn has settled (its reply in the transcript, nothing
    /// running): asks for its last run's sentence when the user wants
    /// them, the run is long enough and it hasn't been asked about.
    func requestStepSummaryIfWanted(sessionId: String) {
        reapStepSummaryQuestions()
        guard ChatStepSummaries.isEnabled(), !sessionId.isEmpty, !isBusy, let client,
              let run = ChatStepSummaries.lastRun(in: messages),
              let toolID = ChatStepSummaries.key(toolIDs: run.map { $0.tool?.id }) else { return }
        let target = ChatStepSummaries.Run(scope: toolCatalogKey, toolID: toolID)
        guard stepSummaries[target.scope]?[toolID] == nil, stepSummaryRequested[target] == nil else { return }
        stepSummaryRequested[target] = Date()
        let question = ChatStepSummaries.question(language: ChatStepSummaries.languageName)
        stepSummaryUnclaimed += 1
        Task { [weak self] in
            // A gateway without prompt.btw just leaves "7 steps".
            let taskId = try? await client.startSideAgent(.btw, sessionId: sessionId, text: question)
            guard let self else { return }
            stepSummaryUnclaimed = max(0, stepSummaryUnclaimed - 1)
            if let taskId, let early = stepSummaryEarlyAnswers.removeValue(forKey: taskId) {
                // Unless the question was forgotten meanwhile (waited too
                // long, or its dashboard signed out).
                if let asked = stepSummaryRequested[target], Date().timeIntervalSince(asked) < ChatStepSummaries.answerWait {
                    recordStepSummary(early, for: target)
                } else {
                    stepSummaryRequested[target] = nil
                }
            } else if let taskId {
                stepSummaryTasks[taskId] = target
            } else {
                stepSummaryRequested[target] = nil
            }
            if stepSummaryUnclaimed == 0 { stepSummaryEarlyAnswers = [:] }
        }
    }

    /// Takes a summary's answer out of the stream: true when the event was
    /// one, whichever chat is open. An answer to the summary question is
    /// always taken, even one no run waits for (late, replayed, or asked
    /// by another device), so it never shows as a /btw note; the user's
    /// own /btw never asks that exact question.
    func takeStepSummaryAnswer(_ event: StreamEvent) -> Bool {
        guard case .sideAgentComplete(_, .btw, let taskId, let text, let question) = event else { return false }
        if let target = stepSummaryTasks.removeValue(forKey: taskId) {
            // An answer after `answerWait` is forgotten like an unanswered
            // question: that run keeps the count.
            if let asked = stepSummaryRequested[target], Date().timeIntervalSince(asked) < ChatStepSummaries.answerWait {
                recordStepSummary(text, for: target)
            } else {
                stepSummaryRequested[target] = nil
            }
            return true
        }
        guard ChatStepSummaries.isQuestion(question) else { return false }
        if stepSummaryUnclaimed > 0, !taskId.isEmpty { stepSummaryEarlyAnswers[taskId] = text }
        return true
    }

    /// Each time a turn settles, questions unanswered after `answerWait` are
    /// forgotten with their task ids, so the bookkeeping stays small. A
    /// late answer is still kept out of the chat (`isQuestion`); its run
    /// keeps the count.
    private func reapStepSummaryQuestions(now: Date = Date()) {
        let waited = stepSummaryRequested.filter { now.timeIntervalSince($0.value) >= ChatStepSummaries.answerWait }
        guard !waited.isEmpty else { return }
        for run in waited.keys { stepSummaryRequested[run] = nil }
        stepSummaryTasks = stepSummaryTasks.filter { stepSummaryRequested[$0.value] != nil }
    }

    /// The sentences describe chats, so they leave with a dashboard's saved
    /// chats (sign-out, removal), with any question still waiting.
    func forgetStepSummaries(scopePrefix: String?) {
        ChatStepSummaries.remove(scopePrefix: scopePrefix)
        stepSummaries = ChatStepSummaries.saved()
        stepSummaryTasks = [:]
        stepSummaryRequested = [:]
        stepSummaryEarlyAnswers = [:]
    }

    private func recordStepSummary(_ text: String, for target: ChatStepSummaries.Run) {
        stepSummaryRequested[target] = nil
        guard let summary = ChatStepSummaries.cleaned(text) else { return }
        ChatStepSummaries.save(summary, for: target)
        // Read back, so memory holds what the saved limit kept.
        stepSummaries = ChatStepSummaries.saved()
    }
}
