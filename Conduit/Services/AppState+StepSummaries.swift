//
//  AppState+StepSummaries.swift
//  Conduit
//
//  A short look back at a finished turn's run of steps: asked of Hermes
//  as a side question once the turn ends (opt-in, Settings > Chat) or from
//  a run's menu, through the plugin's /side-question (a hidden /btw on a
//  host without it), and kept on this device per dashboard and profile
//  (ChatStepSummaries).
//

import Foundation

extension AppState {
    /// Once a turn has settled (its reply in the transcript, nothing
    /// running): asks for a summary of its last run when summaries are on,
    /// the run folds within the step limit and it hasn't been asked about.
    func requestStepSummaryIfWanted(sessionId: String) {
        reapStepSummaryQuestions()
        guard ChatStepSummaries.isEnabled(), !sessionId.isEmpty, !isBusy, canAskStepSummaries,
              let run = ChatStepSummaries.lastRun(in: messages),
              ChatStepSummaries.isAsked(
                  run,
                  showingTools: displayPreferences.showToolProgress,
                  showingReasoning: displayPreferences.showReasoning
              ),
              let toolID = ChatStepSummaries.key(toolIDs: run.map { $0.tool?.id }) else { return }
        let target = ChatStepSummaries.Run(scope: toolCatalogKey, toolID: toolID)
        guard stepSummaries[target.scope]?[toolID] == nil, stepSummaryRequested[target] == nil else { return }
        let question = ChatStepSummaries.question(
            language: ChatStepSummaries.languageName,
            words: ChatStepSummaries.words(toolCount: run.filter { $0.role == .tool }.count)
        )
        askStepSummary(question, for: target, sessionId: sessionId)
    }

    /// The plugin's route, or Hermes' own connection for a hidden /btw.
    private var canAskStepSummaries: Bool {
        stepSummarySender != nil || dashboardTicketBridge != nil || client != nil
    }

    /// Asked from a finished run's menu, whether or not summaries are on:
    /// Hermes explains that run from the calls the question lists.
    func explainStepRun(firstMessageID: String) {
        reapStepSummaryQuestions()
        guard let sessionId = activeSessionId, !sessionId.isEmpty, canAskStepSummaries,
              let start = messages.firstIndex(where: { $0.id == firstMessageID }) else { return }
        let run = messages[start...].prefix(while: ChatStepGroup.isStep)
        let steps = run.compactMap { $0.role == .tool ? $0.tool : nil }
        guard !steps.isEmpty, !steps.contains(where: { $0.status == .running }),
              let toolID = ChatStepSummaries.key(toolIDs: run.map { $0.tool?.id }) else { return }
        let target = ChatStepSummaries.Run(scope: toolCatalogKey, toolID: toolID)
        guard stepSummaryRequested[target] == nil else { return }
        let question = ChatStepSummaries.explainQuestion(
            language: ChatStepSummaries.languageName,
            words: ChatStepSummaries.explainWords(toolCount: steps.count),
            steps: steps
        )
        askStepSummary(question, for: target, sessionId: sessionId)
    }

    private func askStepSummary(_ question: String, for target: ChatStepSummaries.Run, sessionId: String) {
        let asked = Date()
        stepSummaryRequested[target] = asked
        // Unanswered by then, the run stops "looking back" and its menu
        // can ask again, without waiting for another turn to settle.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ChatStepSummaries.answerWait))
            guard let self, stepSummaryRequested[target] == asked else { return }
            stepSummaryRequested[target] = nil
            shownChat.stepSummaryTasks = shownChat.stepSummaryTasks.filter { $0.value != target }
        }
        if stepSummarySender != nil || notifierPlugin.reports(ChatStepSummaries.sideQuestionCapability) {
            askStepSummaryOfPlugin(question, for: target, asked: asked, sessionId: sessionId)
            return
        }
        guard let client else {
            stepSummaryRequested[target] = nil
            return
        }
        shownChat.stepSummaryUnclaimed += 1
        Task { [weak self] in
            // A gateway without prompt.btw just leaves "7 steps".
            let taskId = try? await client.startSideAgent(.btw, sessionId: sessionId, text: question)
            guard let self else { return }
            shownChat.stepSummaryUnclaimed = max(0, shownChat.stepSummaryUnclaimed - 1)
            let early = taskId.flatMap { self.shownChat.stepSummaryEarlyAnswers.removeValue(forKey: $0) }
            // Only while this is still the run's question: forgotten
            // meanwhile (waited too long, or its dashboard signed out), or
            // asked again since, its answer is just taken from the stream.
            if stepSummaryRequested[target] == asked {
                if let early, Date().timeIntervalSince(asked) < ChatStepSummaries.answerWait {
                    recordStepSummary(early, for: target)
                } else if early == nil, let taskId {
                    shownChat.stepSummaryTasks[taskId] = target
                } else {
                    stepSummaryRequested[target] = nil
                }
            }
            if shownChat.stepSummaryUnclaimed == 0 { shownChat.stepSummaryEarlyAnswers = [:] }
        }
    }

    /// The plugin's route answers this device alone, so no other client on
    /// the chat (Hermes Desktop) shows the question and its answer as a
    /// note. No answer, an error or a late one leaves the run's count, as an
    /// unanswered /btw does.
    private func askStepSummaryOfPlugin(
        _ question: String, for target: ChatStepSummaries.Run, asked: Date, sessionId: String
    ) {
        let body = ChatStepSummaries.sideQuestionBody(sessionID: sessionId, question: question)
        // The dashboard the question was asked of, read now: a switch while
        // it waits must not send this chat's question to another host.
        let sender = stepSummarySender
        let bridge = dashboardTicketBridge
        let path = DashboardPath.withProfile(
            ChatStepSummaries.sideQuestionPath, profile: activeProfile,
            parameter: notifierPlugin.dashboardProfileParameter
        )
        Task { [weak self] in
            let response: [String: Any]?
            if let sender {
                response = try? await sender(body)
            } else if let bridge {
                response = try? await bridge.requestJSON(
                    path: path, method: "POST", body: body,
                    timeoutMilliseconds: Int((ChatStepSummaries.sideQuestionWait + 5) * 1_000)
                )
            } else {
                response = nil
            }
            // Only while this is still the run's question: forgotten
            // meanwhile, or asked again since, its answer is dropped.
            guard let self, stepSummaryRequested[target] == asked else { return }
            if let text = response.flatMap(ChatStepSummaries.sideQuestionAnswer),
               Date().timeIntervalSince(asked) < ChatStepSummaries.answerWait {
                recordStepSummary(text, for: target)
            } else {
                stepSummaryRequested[target] = nil
            }
        }
    }

    /// Takes a summary's answer out of the stream: true when the event was
    /// one, whichever chat is open. An answer to the summary question is
    /// always taken, even one no run waits for (late, replayed, or asked
    /// by another device), so it never shows as a /btw note; the user's
    /// own /btw never asks that exact question.
    func takeStepSummaryAnswer(_ event: StreamEvent) -> Bool {
        guard case .sideAgentComplete(_, .btw, let taskId, let text, let question) = event else { return false }
        if let target = shownChat.stepSummaryTasks.removeValue(forKey: taskId) {
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
        if shownChat.stepSummaryUnclaimed > 0, !taskId.isEmpty { shownChat.stepSummaryEarlyAnswers[taskId] = text }
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
        shownChat.stepSummaryTasks = shownChat.stepSummaryTasks.filter { stepSummaryRequested[$0.value] != nil }
    }

    /// The summaries describe chats, so they leave with a dashboard's saved
    /// chats (sign-out, removal), with any question still waiting.
    func forgetStepSummaries(scopePrefix: String?) {
        ChatStepSummaries.remove(scopePrefix: scopePrefix)
        stepSummaries = ChatStepSummaries.saved()
        guard let scopePrefix else {
            shownChat.stepSummaryTasks = [:]
            stepSummaryRequested = [:]
            shownChat.stepSummaryEarlyAnswers = [:]
            return
        }
        // Another dashboard signing out leaves this one's questions be.
        // Early answers carry no scope; unclaimed, they go with their wait.
        shownChat.stepSummaryTasks = shownChat.stepSummaryTasks.filter { !$0.value.scope.hasPrefix(scopePrefix) }
        stepSummaryRequested = stepSummaryRequested.filter { !$0.key.scope.hasPrefix(scopePrefix) }
    }

    private func recordStepSummary(_ text: String, for target: ChatStepSummaries.Run) {
        stepSummaryRequested[target] = nil
        guard let summary = ChatStepSummaries.cleaned(text) else { return }
        ChatStepSummaries.save(summary, for: target)
        // Read back, so memory holds what the saved limit kept.
        stepSummaries = ChatStepSummaries.saved()
    }
}
