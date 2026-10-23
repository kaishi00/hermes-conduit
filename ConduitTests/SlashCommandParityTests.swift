import XCTest
@testable import Conduit

/// Slash-command parity with Hermes (#1078 follow-up): the live
/// `commands.catalog` list without the commands Hermes refuses for Conduit,
/// the subcommand words that complete an argument, and the refusal note.
/// An extension so the smoke run picks it up with its class.
extension ComposerDraftStoreTests {
    private static let catalog: AnyCodable = .object([
        "categories": .array([
            .object([
                "name": .string("Session"),
                "pairs": .array([
                    .array([.string("/steer"), .string("Inject a message after the next tool call")]),
                    .array([.string("/undo"), .string("Back up N user turns")]),
                    .array([.string("/save"), .string("Export the current conversation")]),
                    .array([.string("/goal"), .string("Set a standing goal")])
                ])
            ]),
            .object([
                "name": .string("Configuration"),
                "pairs": .array([
                    .array([.string("/fast"), .string("Fast mode")]),
                    .array([.string("/skin"), .string("Show or change the display skin")])
                ])
            ])
        ]),
        "canon": .object(["/s": .string("/steer"), "/steer": .string("/steer")]),
        "sub": .object([
            "/fast": .array([.string("normal"), .string("fast"), .string("ultrafast")]),
            "/skills": .array([.string("search"), .string("install"), .string("pending")]),
            "/queue": .array([.string("list"), .string("add")]),
            "/skin": .array([.string("dark")])
        ]),
        "commands": .object([
            "/skills": .object(["desktop_subcommands": .array([.string("pending")])])
        ])
    ])

    func testCatalogLeavesOutCommandsHermesRefusesForConduit() {
        let names = Set(AppState.normalizedSlashCatalog(Self.catalog).map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["steer", "goal", "fast", "stop", "queue", "undo"]))
        XCTAssertTrue(names.isDisjoint(with: ["save", "skin", "agents", "rollback", "tools"]))
        XCTAssertEqual(
            AppState.normalizedSlashCatalog(Self.catalog).first { $0.name == "steer" }?.aliases,
            ["s"]
        )
    }

    func testBuiltInsOfferOnlyCommandsConduitCanRun() {
        for command in AppState.builtInSlashCommands {
            XCTAssertFalse(
                AppState.slashCommandsWithoutConduitRoute.contains(command.name),
                "/\(command.name) is listed but Hermes refuses it for Conduit"
            )
        }
    }

    func testSubcommandsComeFromTheCatalogNarrowedForClients() {
        let map = AppState.slashSubcommandMap(Self.catalog)
        XCTAssertEqual(map["fast"], ["normal", "fast", "ultrafast"])
        XCTAssertEqual(map["skills"], ["pending"], "desktop_subcommands narrows the words a client may send")
        XCTAssertNil(map["queue"], "Conduit's /queue only adds a message")
        XCTAssertNil(map["skin"], "A command Conduit can't run offers no words")
    }

    func testArgumentSuggestionsCompleteTheFirstWord() {
        let commands = AppState.normalizedSlashCatalog(Self.catalog)
        let subs = AppState.slashSubcommandMap(Self.catalog)

        XCTAssertEqual(
            ComposerBar.slashArgumentSuggestions(for: "/fast ul", commands: commands, subcommands: subs).map(\.name),
            ["fast ultrafast"]
        )
        XCTAssertEqual(
            ComposerBar.slashArgumentSuggestions(for: "/fast ", commands: commands, subcommands: subs).map(\.name),
            ["fast normal", "fast fast", "fast ultrafast"]
        )
        XCTAssertTrue(
            ComposerBar.slashArgumentSuggestions(for: "/fast ultrafast", commands: commands, subcommands: subs).isEmpty,
            "A finished word needs no suggestion"
        )
        XCTAssertTrue(
            ComposerBar.slashArgumentSuggestions(for: "/fast fast now", commands: commands, subcommands: subs).isEmpty,
            "Only the first argument word completes"
        )
        XCTAssertEqual(
            ComposerBar.slashArgumentSuggestions(for: "/fast  ul", commands: commands, subcommands: subs).map(\.name),
            ["fast ultrafast"],
            "Extra spaces before the word still complete it"
        )
        XCTAssertTrue(ComposerBar.shouldShowSlashSuggestions(for: "/fast u", isProgrammaticDraftRestore: false))
        XCTAssertNil(ComposerBar.slashArgumentQuery(in: "/fast\nu"))
    }

    func testRefusedCommandSaysSoWithHermesHint() {
        let refusal = RpcError(
            code: 4001,
            message: "unsupported_command",
            reason: "unsupported_command",
            detail: "Run `hermes profile export [name] -o <file>` in a terminal."
        )
        XCTAssertEqual(
            AppState.slashFailureNote(command: "export", error: refusal),
            "Hermes doesn't run /export for Conduit chats.\nRun `hermes profile export [name] -o <file>` in a terminal."
        )
        XCTAssertEqual(
            AppState.slashFailureNote(command: "save", error: RpcError(code: 4001, message: "unsupported_command", reason: "unsupported_command")),
            "Hermes doesn't run /save for Conduit chats."
        )
        XCTAssertEqual(
            AppState.slashFailureNote(command: "status", error: RpcError(code: 4009, message: "session busy")),
            "⚠️ Command failed: session busy"
        )
    }

    func testRewindSnapshotKeepsOnlyTurnsAPersonTyped() {
        let resume: [String: AnyCodable] = [
            "revision": .number(9),
            "execution_generation": .number(3),
            "messages": .array([
                .object(["role": .string("user"), "row_id": .number(1), "content": .string("hello")]),
                .object(["role": .string("assistant"), "row_id": .number(2), "content": .string("hi")]),
                .object(["role": .string("user"), "row_id": .number(3), "content": .string("old"), "archived": .bool(true)]),
                .object(["role": .string("user"), "row_id": .number(4), "content": .string("ping"), "display_kind": .string("process_complete")]),
                .object(["role": .string("user"), "row_id": .number(5), "content": .string("go left"), "display_kind": .string("steer")]),
                .object(["role": .string("user"), "content": .string("not saved yet")]),
                .object(["role": .string("user"), "row_id": .number(6), "content": .array([
                    .object(["type": .string("text"), "text": .string("look")]),
                    .object(["type": .string("image_url"), "image_url": .object([:])])
                ])]),
                .object(["role": .string("user"), "row_id": .number(7), "content": .string("summary"), "_compressed_summary": .bool(true)])
            ])
        ]
        let snapshot = SessionRewindSnapshot(resume: resume)
        XCTAssertEqual(snapshot.turns.map(\.rowID), [1, 5, 6])
        XCTAssertEqual(snapshot.turns.map(\.text), ["hello", "go left", nil])
        XCTAssertEqual(snapshot.revision, 9)
        XCTAssertEqual(snapshot.generation, 3)
    }

    func testRewindReceiptReadsTheRewoundTurn() {
        let receipt = SessionRewindReceipt(result: .object([
            "status": .string("applied"),
            "rewound_count": .number(4),
            "target_message": .object(["content": .array([.object(["type": .string("text"), "text": .string("redo this")])])])
        ]))
        XCTAssertEqual(receipt, SessionRewindReceipt(rewoundCount: 4, text: "redo this"))
        XCTAssertEqual(
            SessionRewindReceipt(result: .object(["status": .string("nothing"), "rewound_count": .number(0)])).rewoundCount,
            0
        )
        XCTAssertEqual(
            SessionRewindReceipt(result: .object(["status": .string("applied")])).rewoundCount,
            1,
            "An applied rewind without its count still took the target back"
        )
        XCTAssertNil(SessionRewindSnapshot.text(of: .array([])), "No parts is not a text turn")
    }

    func testRewindRefusalsReadAsWords() {
        XCTAssertEqual(
            AppState.rewindFailureNote(command: "undo", error: RpcError(code: 4009, message: "session_busy", reason: "session_busy")),
            "Wait for the reply to finish, or /stop it, then try again."
        )
        XCTAssertEqual(
            AppState.rewindFailureNote(command: "undo", error: RpcError(
                code: 4002,
                message: "invalid_params",
                reason: "invalid_params",
                detail: "compacted: target user message was summarized when the session was compressed"
            )),
            "That message was summarized when the chat was compressed, so it can't be taken back."
        )
        XCTAssertEqual(
            AppState.rewindFailureNote(command: "retry", error: RpcError(code: 4009, message: "session busy")),
            "⚠️ Command failed: session busy"
        )
    }

    func testRpcErrorReadsDetail() throws {
        let data = Data(#"{"code":4001,"message":"unsupported_command","data":{"reason":"unsupported_command","detail":"Use the app."}}"#.utf8)
        let error = try JSONDecoder().decode(RpcError.self, from: data)
        XCTAssertEqual(error.reason, "unsupported_command")
        XCTAssertEqual(error.detail, "Use the app.")
    }
}
