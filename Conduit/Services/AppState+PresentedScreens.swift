//
//  AppState+PresentedScreens.swift
//  Conduit
//
//  When Conduit exchanges confirmations with the host (on connect, coming
//  to the foreground, a push, after an answer), how an answer by tap is
//  recorded, and the live call's voice tool for them.
//  (PresentedScreens.swift, designs/v2-phase4-presented-screens.md)
//

import Combine
import Foundation

extension AppState {
    /// Exchanges when the host's plugin serves it; silent otherwise.
    func syncPresentedScreens() async {
        guard notifierPlugin.reports(PresentedScreensSync.capability),
              let scope = agentSettingsScope,
              let bridge = dashboardTicketBridge else { return }
        let profile = activeProfile
        await presentedScreens.sync(
            scope: scope, profile: profile, installationID: agentSettings.installationID,
            isCurrent: { [weak self] in bridge === self?.dashboardTicketBridge && profile == self?.activeProfile }
        ) { [weak self] path, body in
            guard let self, bridge === self.dashboardTicketBridge, profile == self.activeProfile else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(path: path, method: "POST", body: body)
        }
    }

    /// The user's answer; reported to the host right away.
    func answerPresentedConfirm(_ prompt: PresentedConfirm, outcome: PresentedConfirmOutcome,
                                via source: PresentedConfirmAnswerSource) async {
        presentedScreens.answer(prompt, outcome: outcome, via: source)
        await syncPresentedScreens()
    }

    /// Edit: Hermes hears the user wants changes, and the chat it came from
    /// opens with the preview in the composer to rework and send.
    func editPresentedConfirm(_ prompt: PresentedConfirm) async {
        presentedScreens.answer(prompt, outcome: .edit, via: .tap)
        Task { await syncPresentedScreens() }
        if let session = prompt.sessionID {
            dismissSidebarDrawer()
            guard await openSession(session) else {
                // Hermes already knows; say why the draft didn't appear.
                if errorMessage == nil {
                    errorMessage = AppLocalization.string("Couldn't open the chat to edit it. Hermes knows you want changes.")
                }
                return
            }
        }
        prefillComposer(Self.plainText(fromMarkdown: prompt.preview))
    }

    private static func plainText(fromMarkdown markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(attributed.characters)
    }

    /// The user's last turn in the running live call.
    func liveCallLastUserTurn() -> (id: UUID?, text: String) {
        let transcript: [VoiceConversationTranscriptEntry]
        if isGeminiLiveActive {
            transcript = geminiLiveController.transcript
        } else if isGrokLiveActive {
            transcript = grokLiveController.transcript
        } else if isGPTLiveActive {
            transcript = gptLiveController.transcript
        } else {
            return (nil, "")
        }
        let turn = transcript.last(where: { $0.speaker == .user })
        return (turn?.id, turn?.text ?? "")
    }

    /// The live call's confirmation tool, when the host serves them.
    var presentVoiceTools: [VoiceHostTool] {
        notifierPlugin.reports(PresentedScreensSync.capability) ? [PresentVoiceTool.tool] : []
    }

    func callPresentVoiceTool(_ arguments: [String: Any]) async -> [String: String] {
        await PresentVoiceTool.run(
            arguments, sync: presentedScreens,
            lastUserTurn: { [weak self] in self?.liveCallLastUserTurn() ?? (nil, "") }
        ) { prompt, outcome in
            presentedScreens.answer(prompt, outcome: outcome, via: .voice)
            // Reported in the background: the call hears the outcome now.
            Task { await self.syncPresentedScreens() }
        }
    }

    /// Tells the running call about each confirmation that arrives while it
    /// runs, so the user can answer it out loud.
    func watchPresentedConfirms(for mode: LiveVoiceModeName) -> AnyCancellable {
        var known = Set(presentedScreens.prompts.map(\.id))
        let turnAtStart = liveCallLastUserTurn().id
        for id in known { presentedScreens.noteShown(id, userTurn: turnAtStart) }
        return presentedScreens.$prompts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompts in
                guard let self else { return }
                let supervisor = self.voiceBackgroundJobSupervisor
                let fresh = prompts.filter { !known.contains($0.id) }
                known = Set(prompts.map(\.id))
                let turn = self.liveCallLastUserTurn().id
                for prompt in fresh { self.presentedScreens.noteShown(prompt.id, userTurn: turn) }
                guard !fresh.isEmpty, supervisor.hostToolsMode == mode,
                      self.isGeminiLiveActive || self.isGPTLiveActive || self.isGrokLiveActive else { return }
                for prompt in fresh { supervisor.notePhoneChange(PresentVoiceTool.note(for: prompt)) }
            }
    }
}
