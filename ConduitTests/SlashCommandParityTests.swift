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
        XCTAssertTrue(names.isSuperset(of: ["steer", "goal", "fast", "stop", "queue"]))
        XCTAssertTrue(names.isDisjoint(with: ["undo", "save", "skin", "agents", "rollback", "tools", "retry"]))
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

    func testRpcErrorReadsDetail() throws {
        let data = Data(#"{"code":4001,"message":"unsupported_command","data":{"reason":"unsupported_command","detail":"Use the app."}}"#.utf8)
        let error = try JSONDecoder().decode(RpcError.self, from: data)
        XCTAssertEqual(error.reason, "unsupported_command")
        XCTAssertEqual(error.detail, "Use the app.")
    }
}
