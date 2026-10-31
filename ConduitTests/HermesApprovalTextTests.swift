//
//  HermesApprovalTextTests.swift
//
//  Hermes' approval texts in the App Language (#1589): the texts Hermes
//  writes show translated, with the names in them as sent; anything else
//  shows as Hermes sent it. In NotificationCopyTests, which already pins the
//  App Language for each test.
//

import XCTest
@testable import Conduit

extension NotificationCopyTests {
    private static let protectedWrite = "Write to protected agent-instruction file(s): AGENTS.md. These files steer future agent behavior; approval is always required (not bypassed by auto-approve)."

    func testProtectedFileApprovalFollowsTheAppLanguage() {
        XCTAssertEqual(HermesApprovalText.description(Self.protectedWrite), Self.protectedWrite)
        XCTAssertEqual(HermesApprovalText.command("<write to AGENTS.md>"), "<write to AGENTS.md>")

        UserDefaults.standard.set("pt-BR", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(
            HermesApprovalText.description(Self.protectedWrite),
            "Escrever em arquivo(s) protegido(s) de instruções do agente: AGENTS.md. Esses arquivos orientam o comportamento futuro do agente; a aprovação é sempre necessária (a aprovação automática não se aplica)."
        )
        XCTAssertEqual(HermesApprovalText.command("<write to AGENTS.md, SOUL.md>"), "<escrever em AGENTS.md, SOUL.md>")
    }

    func testFlaggedCommandPatternsFollowTheAppLanguage() {
        UserDefaults.standard.set("pt-BR", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(HermesApprovalText.description("recursive delete"), "exclusão recursiva")
        XCTAssertEqual(HermesApprovalText.description(" git reset --hard (destroys uncommitted changes)\n"),
                       "git reset --hard (destrói alterações não confirmadas)")
        XCTAssertEqual(HermesApprovalText.description("arbitrary program execution via find -exec"),
                       "execução de qualquer programa via find -exec")
        XCTAssertEqual(
            HermesApprovalText.description("Server 'github' is configured 'trust: untrusted'. Approve to run 'create_issue' once, for this session, or always, or deny to block it."),
            "O servidor 'github' está configurado como 'trust: untrusted'. Aprove para executar 'create_issue' uma vez, nesta sessão ou sempre, ou negue para bloquear."
        )
    }

    func testUnknownApprovalTextAndRealCommandsShowAsSent() {
        UserDefaults.standard.set("pt-BR", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(HermesApprovalText.description("Deploys to production"), "Deploys to production")
        XCTAssertEqual(HermesApprovalText.description("recursive delete, twice"), "recursive delete, twice")
        XCTAssertEqual(HermesApprovalText.description("Plugin requires approval for "), "Plugin requires approval for ")
        XCTAssertEqual(HermesApprovalText.description("Plugin requires approval for deleting the cache at /x"),
                       "Plugin requires approval for deleting the cache at /x", "a plugin's own reason")
        XCTAssertEqual(HermesApprovalText.description("Plugin requires approval for clear_cache"),
                       "Um plugin exige aprovação para clear_cache")
        XCTAssertEqual(HermesApprovalText.description("arbitrary program execution via find -exec rm"),
                       "arbitrary program execution via find -exec rm")
        XCTAssertEqual(HermesApprovalText.command("rm -rf build"), "rm -rf build")
        XCTAssertEqual(HermesApprovalText.command("<write to >"), "<write to >")
        XCTAssertEqual(HermesApprovalText.command("<write to a> && rm -rf ~ #>"), "<write to a> && rm -rf ~ #>")
        XCTAssertEqual(HermesApprovalText.description("Codex requests exec in production, not staging"),
                       "Codex requests exec in production, not staging")
    }

    func testApprovalNotificationBodyFollowsTheAppLanguage() {
        UserDefaults.standard.set("pt-BR", forKey: AppLanguageStore.defaultsKey)
        let preview = NotificationCopy.preview([
            "title_label": "approval.needed", "session_title": "Docs", "body": "recursive delete",
        ])
        XCTAssertEqual(preview.body, "exclusão recursiva")
        let reply = NotificationCopy.preview(["title_label": "response.ready", "body": "recursive delete"])
        XCTAssertEqual(reply.body, "recursive delete", "only an approval's body is Hermes' approval text")
    }

    func testSpokenApprovalLinesFollowTheAppLanguage() {
        UserDefaults.standard.set("pt-BR", forKey: AppLanguageStore.defaultsKey)
        func approval(_ description: String, command: String = "rm -rf build") -> ApprovalActivity {
            ApprovalActivity(sessionId: "s", requestId: "r", command: command, description: description,
                             choices: nil, allowPermanent: false, smartDenied: false,
                             status: .pending, choice: nil, error: nil)
        }
        XCTAssertEqual(LocalLiveTurnRunner.approvalLine(approval("recursive delete")),
                       "O Hermes precisa do seu OK para continuar: exclusão recursiva. Diga sim para permitir uma vez, ou não.")
        XCTAssertEqual(LocalLiveTurnRunner.approvalLine(approval("", command: "<write to AGENTS.md>")),
                       "O Hermes precisa do seu OK para continuar: <escrever em AGENTS.md>. Diga sim para permitir uma vez, ou não.")
        XCTAssertEqual(LocalLiveTurnRunner.approvalLine(approval("Deploys to production")),
                       "O Hermes precisa do seu OK para continuar: Deploys to production. Diga sim para permitir uma vez, ou não.")

        var job = VoiceBackgroundJob(id: UUID(), title: "Limpar", instructions: "x", status: .needsInput, startedAt: Date())
        job.waitingApproval = approval("recursive delete")
        XCTAssertEqual(VoiceBackgroundJobSupervisor.waitingNotice(for: job),
                       "O trabalho Limpar precisa do seu OK para continuar: exclusão recursiva. Diga sim para permitir uma vez, ou não.")
    }

    func testCallFromHermesSaysTheApprovalInTheAppLanguage() {
        UserDefaults.standard.set("pt-BR", forKey: AppLanguageStore.defaultsKey)
        XCTAssertEqual(HermesApprovalText.description("Codex requests exec in /Users/me/My Project"),
                       "O Codex pede para executar em /Users/me/My Project")
        XCTAssertEqual(HermesCallCopy.summary(kind: .approval, title: nil, reason: "recursive delete"),
                       HermesCallCopy.outcome(kind: .approval, title: nil) + " exclusão recursiva")
        XCTAssertEqual(HermesCallCopy.summary(kind: .question, title: nil, reason: "recursive delete"),
                       HermesCallCopy.outcome(kind: .question, title: nil) + " recursive delete",
                       "a question's reason is Hermes' own words")
        XCTAssertEqual(NotificationCopy.callLine(["kind": "approval", "reason": "recursive delete"]),
                       AppLocalization.string("Hermes needs your OK.") + " exclusão recursiva")

        let waiting = HermesCallWaiting(host: ["kind": "approval", "description": "recursive delete", "command": "rm -rf build"])
        let call = HermesCallOpening(kind: .approval, title: nil, result: nil, reason: "recursive delete")
        XCTAssertTrue(call.spokenBrief(waiting: waiting).hasSuffix("exclusão recursiva. Diga sim para permitir uma vez, ou não."))
        XCTAssertEqual(waiting.map { $0.block.contains("Why: recursive delete") }, true, "the model's brief keeps Hermes' words")
    }
}
