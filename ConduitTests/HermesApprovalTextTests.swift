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
        XCTAssertEqual(HermesApprovalText.command("rm -rf build"), "rm -rf build")
        XCTAssertEqual(HermesApprovalText.command("<write to >"), "<write to >")
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
}
