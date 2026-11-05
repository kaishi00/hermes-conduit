//
//  WorkspaceFilesTests.swift
//  ConduitTests
//
//  The Folder tab (#1389): the plugin's answers read into entries, file
//  paths in replies made tappable, the link they open and the path it
//  names. Written as an extension of an existing suite: the CI test
//  planner keeps new XCTestCase classes to a budget.
//

import XCTest
@testable import Conduit

@MainActor
extension HermesVoiceGatewayTimeoutTests {
    private func workspaceClient(
        answer: @escaping @MainActor (String, String, [String: Any]?) -> [String: Any],
        requests: @escaping @MainActor (String, String, [String: Any]?) -> Void = { _, _, _ in }
    ) -> WorkspaceFilesClient {
        WorkspaceFilesClient(profile: "work") { path, method, body in
            requests(path, method, body)
            return answer(path, method, body)
        }
    }

    func testWorkspaceListingReadsEntriesWithSizesAndDates() async throws {
        var asked: [String] = []
        let client = workspaceClient(answer: { _, _, _ in
            [
                "ok": true,
                "path": "/w/app",
                "truncated": false,
                "entries": [
                    ["name": "src", "path": "/w/app/src", "isDirectory": true, "mtime": 1_700_000_000.5],
                    ["name": "README.md", "path": "/w/app/README.md", "isDirectory": false, "size": 1234, "mtime": 1_700_000_100],
                    ["name": "", "path": "/w/app/blank"],
                ],
            ]
        }, requests: { path, method, _ in asked.append("\(method) \(path)") })

        let listing = try await client.list(root: "/w/app", path: "/w/app")

        XCTAssertEqual(listing.entries.map(\.name), ["src", "README.md"], "a row without a name is left out")
        XCTAssertTrue(listing.entries[0].isDirectory)
        XCTAssertEqual(listing.entries[1].size, 1234)
        XCTAssertEqual(listing.entries[1].modified, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].hasPrefix("GET /api/plugins/conduit_push/workspace/list?"), asked[0])
        XCTAssertTrue(asked[0].contains("root=%2Fw%2Fapp"), asked[0])
        XCTAssertTrue(asked[0].contains("profile=work"), asked[0])
    }

    /// A folder's listing and recent files are kept as the plugin gave
    /// them, so the folder opens on them next time (#1533), as one
    /// folder's of many; an answer without ok, or one the folder can't
    /// read, isn't kept over them.
    func testWorkspaceListingAndRecentFilesAreKeptForNextTime() async throws {
        var saved: [String: [String: Any]] = [:]
        let answers = KeptAnswers(
            kept: { saved[$0] },
            keep: { route, _, read in
                let answer = try await read()
                saved[route] = answer
                return answer
            }
        )
        var ok = true
        var readable = true
        let client = workspaceClient(answer: { path, _, _ in
            guard readable else { return ["ok": true] }
            return path.contains("/recent")
                ? ["ok": ok, "entries": [["name": "notes.md", "path": "/w/app/notes.md", "mtime": 1_700_000_200]]]
                : ["ok": ok, "truncated": true, "entries": [["name": "src", "path": "/w/app/src", "isDirectory": true]]]
        })

        let listing = try await client.list(root: "/w/app", path: "/w/app", keptIn: answers)
        let recent = try await client.recent(root: "/w/app", keptIn: answers)
        _ = try await client.list(root: "/w/app", path: "/w/app/src")

        XCTAssertEqual(saved.count, 2, "a folder opened in the tree isn't kept unless asked")
        XCTAssertTrue(saved.keys.allSatisfy { $0.hasPrefix(OfflineChatCacheStore.lastOpenedRoutePrefix) })
        XCTAssertEqual(client.keptListing(root: "/w/app", path: "/w/app", in: answers), listing)
        XCTAssertEqual(client.keptListing(root: "/w/app", path: "/w/app", in: answers)?.truncated, true)
        XCTAssertEqual(client.keptRecent(root: "/w/app", in: answers), recent)
        XCTAssertNil(client.keptListing(root: "/w/other", path: "/w/other", in: answers), "another folder")

        ok = false
        _ = try? await client.list(root: "/w/app", path: "/w/app", keptIn: answers)
        XCTAssertEqual(client.keptListing(root: "/w/app", path: "/w/app", in: answers), listing)
        ok = true
        readable = false
        _ = try? await client.list(root: "/w/app", path: "/w/app", keptIn: answers)
        _ = try? await client.recent(root: "/w/app", keptIn: answers)
        XCTAssertEqual(client.keptListing(root: "/w/app", path: "/w/app", in: answers), listing)
        XCTAssertEqual(client.keptRecent(root: "/w/app", in: answers), recent)

        // What's kept from the plugin's routes shows until it says what it
        // serves, and only while that includes them.
        let capability = WorkspaceFilesClient.capability
        XCTAssertTrue(NotifierPluginStatus(state: .unknown).mayServe(capability))
        XCTAssertTrue(NotifierPluginStatus(state: .reported(version: "0.122.0", capabilities: [capability])).mayServe(capability))
        XCTAssertFalse(NotifierPluginStatus(state: .reported(version: "0.108.0", capabilities: ["artifacts"])).mayServe(capability))
        XCTAssertFalse(NotifierPluginStatus(state: .predatesCapabilities).mayServe(capability), "no plugin, or one older than 0.4")
        // The Artifacts list's update notice waits the same way, kept rows
        // or none.
        XCTAssertTrue(NotifierPluginStatus(state: .unknown).mayServe(ArtifactsClient.capability))
        XCTAssertFalse(NotifierPluginStatus(state: .predatesCapabilities).mayServe(ArtifactsClient.capability))
    }

    func testWorkspaceSearchReadsNamesAndMatchedLines() async throws {
        let client = workspaceClient(answer: { _, _, _ in
            [
                "ok": true,
                "truncated": true,
                "names": [["name": "notes.md", "path": "/w/notes.md"]],
                "matches": [[
                    "path": "/w/src/main.py",
                    "lines": [["line": 12, "text": "    print('hello')", "matchStart": 11, "matchLength": 5]],
                ]],
            ]
        })

        let result = try await client.search(root: "/w", query: "hello")

        XCTAssertEqual(result.query, "hello")
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.names.map(\.path), ["/w/notes.md"])
        XCTAssertEqual(result.matches.first?.name, "main.py", "a match without a name takes its file's")
        XCTAssertEqual(result.matches.first?.lines, [.init(number: 12, text: "    print('hello')", matchStart: 11, matchLength: 5)])
    }

    func testWorkspaceAnswerWithoutOKIsRefused() async {
        let client = workspaceClient(answer: { _, _, _ in ["entries": []] })
        do {
            _ = try await client.recent(root: "/w")
            XCTFail("an answer without ok isn't read as an empty folder")
        } catch {}
    }

    func testAReplysFileNameIsResolvedForTheChat() async throws {
        var asked = ""
        var answer: [String: Any] = ["ok": true, "path": "/root/audits/Conduit/AppState.swift", "via": "chat"]
        let client = workspaceClient(answer: { _, _, _ in answer }, requests: { path, method, _ in
            asked = path
            XCTAssertEqual(method, "GET")
        })
        let found = try await client.resolve(path: "Conduit/App State.swift", sessionIDs: ["live-1", "20261105_a"])
        XCTAssertEqual(found, "/root/audits/Conduit/AppState.swift")
        XCTAssertTrue(asked.hasPrefix("/api/plugins/conduit_push/workspace/resolve?path=Conduit%2FApp%20State.swift"), asked)
        XCTAssertTrue(asked.contains("session_id=live-1&session_id=20261105_a"), asked)
        XCTAssertTrue(asked.contains("profile=work"), asked)

        answer = ["ok": true, "path": NSNull()]
        let missing = try await client.resolve(path: "gone.md", sessionIDs: ["live-1"])
        XCTAssertNil(missing, "no such file on the host")

        answer = ["ok": true]
        do {
            _ = try await client.resolve(path: "gone.md", sessionIDs: ["live-1"])
            XCTFail("an answer without a path is a failed lookup, not a missing file")
        } catch {}
    }

    func testWorkspaceSaveSendsTheDateItWasReadAt() async throws {
        var sent: [String: Any]?
        var path = ""
        let client = workspaceClient(answer: { _, _, _ in ["ok": true] }, requests: { asked, _, body in
            path = asked
            sent = body
        })

        try await client.save(root: "/w", path: "/w/a.txt", content: "new", readAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(sent?["expected_mtime"] as? Double, 1_700_000_000)
        XCTAssertTrue(path.hasPrefix("/api/plugins/conduit_push/workspace/save"), path)

        try await client.save(root: "/w", path: "/w/a.txt", content: "new", readAt: nil)
        XCTAssertNil(sent?["expected_mtime"], "Replace It saves over whatever is there")
    }

    func testCodeThatNamesAPathLinksToTheFile() throws {
        for path in ["docs/guide.md", "/srv/app/main.py", "~/notes.txt", "README.md", "src/app/", "./run.sh"] {
            let url = try XCTUnwrap(WorkspacePathLinks.url(forCode: path), path)
            XCTAssertEqual(ConduitAppLink(url: url), .file(path: path))
        }
        for code in ["let x = 1", "https://example.com/a.md", "--flag", "@bot", "1/2", "v1.2", "e.g.", "/"] {
            XCTAssertNil(WorkspacePathLinks.url(forCode: code), code)
        }
    }

    func testPlainTextLinksOnlyPathsWithAFolderAndAFileType() {
        let text = "I wrote meta-app-review/tutorial.md and ~/notes/today.txt. Use and/or e.g. v1.2 here."
        let found = WorkspacePathLinks.links(inText: text).map { (text as NSString).substring(with: $0.range) }
        XCTAssertEqual(found, ["meta-app-review/tutorial.md", "~/notes/today.txt"], "a sentence's period stays out")
    }

    func testMarkdownLinksToHostFilesOpenInTheFolder() throws {
        let cases: [(String, String)] = [
            ("clients/acme/report.xlsx", "clients/acme/report.xlsx"),
            ("report.json", "report.json"),
            ("/srv/out/summary.pdf", "/srv/out/summary.pdf"),
            ("~/notes/today.md", "~/notes/today.md"),
            ("./out/a.csv#L12", "./out/a.csv"),
            ("file:///srv/data/notes.txt", "/srv/data/notes.txt"),
            ("Client%20Files/Q3%20report.xlsx", "Client Files/Q3 report.xlsx"),
            ("C:/work/a.md", "C:/work/a.md"),
        ]
        for (destination, path) in cases {
            let link = try XCTUnwrap(URL(string: destination), destination)
            let url = try XCTUnwrap(WorkspacePathLinks.url(forLink: link), destination)
            XCTAssertEqual(ConduitAppLink(url: url), .file(path: path), destination)
        }
        for destination in [
            "https://example.com/a.md", "mailto:me@example.com", "#section-2", "guide", "docs/guide",
            "example.com/a.html", "conduit://session/abc", "file://nas/share/a.md", "tel:123",
        ] {
            let link = try XCTUnwrap(URL(string: destination), destination)
            XCTAssertNil(WorkspacePathLinks.url(forLink: link), destination)
        }
    }

    func testAReplysMarkdownFileLinkIsDrawnAsAFolderLink() throws {
        let markdown = "Saved [the report](clients/acme/report.xlsx) and [site](https://example.com)."
        let attributed = try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full))
        let bridged = SelectableTextView.bridge(attributed, defaultFont: .systemFont(ofSize: 17), defaultColor: .label, linkColor: .link)
        var links: [URL] = []
        bridged.enumerateAttribute(.link, in: NSRange(location: 0, length: bridged.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.first.flatMap(ConduitAppLink.init(url:)), .file(path: "clients/acme/report.xlsx"))
        XCTAssertEqual(links.last?.absoluteString, "https://example.com")
    }

    func testFileLinksOpenOnlyInsideTheApp() throws {
        let url = ConduitAppLink.file(path: "/w/a b+c.md").url
        XCTAssertEqual(ConduitAppLink(url: url), .file(path: "/w/a b+c.md"))
        XCTAssertNil(ConduitAppLink(externalURL: url))
        XCTAssertNil(ConduitAppLink(url: try XCTUnwrap(URL(string: "conduit://file?path=%20"))))
    }

    func testRelativePathsInRepliesAreInTheChatsFolder() throws {
        let suite = "WorkspaceFilesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)

        XCTAssertEqual(appState.absoluteWorkspacePath("docs/a.md"), "docs/a.md", "no folder reported yet")
        appState.runtime.cwd = "/home/me/app/"
        XCTAssertEqual(appState.absoluteWorkspacePath("docs/a.md"), "/home/me/app/docs/a.md")
        XCTAssertEqual(appState.absoluteWorkspacePath("./docs/a.md"), "/home/me/app/docs/a.md")
        XCTAssertEqual(appState.absoluteWorkspacePath("/etc/hosts"), "/etc/hosts")
        XCTAssertEqual(appState.absoluteWorkspacePath("~/x.txt"), "~/x.txt")
        XCTAssertEqual(appState.absoluteWorkspacePath("C:\\work\\a.md"), "C:\\work\\a.md")

        appState.revealWorkspaceFile("docs/a.md", line: 3)
        XCTAssertEqual(appState.workspaceReveal?.path, "/home/me/app/docs/a.md")
        XCTAssertEqual(appState.workspaceReveal?.line, 3)
    }

    func testAFileLookupOpensTheFileOrSaysItIsntOnTheServer() throws {
        let suite = "WorkspaceFilesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.runtime.cwd = "/home/me/app"

        appState.showWorkspaceLookup(.success("/root/audits/AppState.swift"), for: "AppState.swift", line: 4)
        XCTAssertEqual(appState.workspaceReveal?.path, "/root/audits/AppState.swift")
        XCTAssertEqual(appState.workspaceReveal?.line, 4)

        appState.workspaceReveal = nil
        appState.showWorkspaceLookup(.success(nil), for: "out/gone.xlsx", line: nil)
        XCTAssertNil(appState.workspaceReveal, "nothing to open")
        // Said above the composer, which shows while the chat is connected.
        XCTAssertEqual(appState.composerNotice?.hasPrefix("gone.xlsx isn"), true, appState.composerNotice ?? "")

        appState.showWorkspaceLookup(.failure(URLError(.timedOut)), for: "docs/a.md", line: nil)
        XCTAssertEqual(appState.workspaceReveal?.path, "/home/me/app/docs/a.md", "a failed lookup keeps the chat's folder")
        XCTAssertNil(appState.composerNotice, "a later tap's answer takes the earlier notice away")

        appState.composerNotice = "Your message wasn't sent. It's back in the composer."
        appState.showWorkspaceLookup(.success("/w/a.md"), for: "a.md", line: nil)
        XCTAssertEqual(appState.composerNotice, "Your message wasn't sent. It's back in the composer.", "other notices stay")
        appState.showWorkspaceLookup(.success(nil), for: "gone.xlsx", line: nil)
        XCTAssertEqual(appState.composerNotice?.hasPrefix("gone.xlsx isn"), true)
        appState.showWorkspaceLookup(.success("/w/b.md"), for: "b.md", line: nil)
        XCTAssertEqual(appState.composerNotice, "Your message wasn't sent. It's back in the composer.",
                       "the message that came back has its notice again")

        appState.composerNotice = nil
        appState.showWorkspaceLookup(.success(nil), for: "gone.xlsx", line: nil)
        appState.activeSessionId = "another-chat"
        XCTAssertNil(appState.composerNotice, "the notice was about the chat left")
    }

    func testToolsThatChangeFilesRefreshTheFolder() throws {
        let suite = "WorkspaceFilesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)

        appState.noteWorkspaceToolCompleted("read_file")
        XCTAssertEqual(appState.workspaceChanges, 0)
        appState.noteWorkspaceToolCompleted("write_file")
        appState.noteWorkspaceToolCompleted("Terminal")
        XCTAssertEqual(appState.workspaceChanges, 2)
    }

    func testWorkspaceRootsStartAtTheChatsFolderThenProjectsOnce() throws {
        let suite = "WorkspaceFilesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.runtime.cwd = "/w/app"

        let roots = appState.workspaceRoots(includingChat: true)
        XCTAssertEqual(roots.first?.path, "/w/app")
        XCTAssertEqual(roots.first?.kind, .chat)
        XCTAssertTrue(appState.workspaceRoots(includingChat: false).allSatisfy { $0.kind == .project })
    }

    // MARK: - New Project (issue 1661)

    func testProjectFolderPickerGoesUpToTheTopOfTheDisk() {
        XCTAssertEqual(AppState.parentWorkspacePath("/home/me/app"), "/home/me")
        XCTAssertEqual(AppState.parentWorkspacePath("/home/me/app/"), "/home/me")
        XCTAssertEqual(AppState.parentWorkspacePath("/home"), "/")
        XCTAssertNil(AppState.parentWorkspacePath("/"))
        XCTAssertEqual(AppState.parentWorkspacePath("~/work"), "~")
        XCTAssertNil(AppState.parentWorkspacePath("~"))
        XCTAssertEqual(AppState.parentWorkspacePath("C:\\Users\\me"), "C:\\Users")
        XCTAssertEqual(AppState.parentWorkspacePath("C:\\Users"), "C:\\")
        XCTAssertNil(AppState.parentWorkspacePath("C:\\"))
        XCTAssertNil(AppState.parentWorkspacePath(""))
        XCTAssertEqual(AppState.parentWorkspacePath("/home/me/a\\b"), "/home/me", "a backslash in a POSIX name isn't a separator")
    }

    func testProjectFolderPickerStartsInTheChatsFolderElseHomes() throws {
        let suite = "WorkspaceFilesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)

        XCTAssertEqual(appState.projectFolderPickerRoot, "", "no chat and no projects yet")
        appState.setProjectsForTesting([
            ProjectSummary(id: "home", title: "Home", primaryPath: "/home/me", isHome: true, sessionCount: 0, previewSessions: []),
        ])
        XCTAssertEqual(appState.projectFolderPickerRoot, "/home/me", "Home's folder with no chat open")
        appState.runtime.cwd = "/home/me/app"
        XCTAssertEqual(appState.projectFolderPickerRoot, "/home/me", "a folder left from a chat that's closed isn't used")
        appState.activeSessionId = "chat"
        XCTAssertEqual(appState.projectFolderPickerRoot, "/home/me/app", "the open chat's folder first")
    }

    func testNewProjectRefusesAnotherProjectsNameOrFolder() throws {
        let suite = "WorkspaceFilesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.setProjectsForTesting([
            ProjectSummary(id: "home", title: "Home", primaryPath: "/home/me", isHome: true, sessionCount: 0, previewSessions: []),
            ProjectSummary(id: "p_1", title: "Skunkworks", primaryPath: "/home/me/skunk", isHome: false, sessionCount: 0, previewSessions: []),
            ProjectSummary(id: "repo", title: "found-repo", primaryPath: "/home/me/found-repo", isHome: false, isAuto: true,
                           sessionCount: 0, previewSessions: []),
        ])

        XCTAssertNil(appState.projectCreationProblem(name: "Atlas", folders: ["/home/me/atlas"]))
        XCTAssertNotNil(appState.projectCreationProblem(name: " skunkworks ", folders: ["/home/me/atlas"]))
        XCTAssertNotNil(appState.projectCreationProblem(name: "Atlas", folders: ["/home/me/skunk/"]))
        XCTAssertNil(appState.projectCreationProblem(name: "Home", folders: ["/home/me"]), "Home has no record to clash with")
        XCTAssertNil(appState.projectCreationProblem(name: "found-repo", folders: ["/home/me/found-repo"]),
                     "a repo Hermes found on its own can become a project")
    }

    func testNewProjectNeverWritesOverAnIdea() {
        XCTAssertTrue(AppState.folderHasProjectIdea([WorkspaceEntry(name: "idea.MD", path: "/p/idea.MD", isDirectory: false)]))
        XCTAssertFalse(AppState.folderHasProjectIdea([WorkspaceEntry(name: "README.md", path: "/p/README.md", isDirectory: false)]))
        XCTAssertFalse(AppState.folderHasProjectIdea([]))
    }

    func testAFailedCreateFindsTheProjectHermesMadeAnyway() {
        let old = ProjectSummary(id: "p_1", title: "Atlas", primaryPath: "/home/me/old", isHome: false, sessionCount: 0, previewSessions: [])
        let other = ProjectSummary(id: "p_2", title: "Atlas", primaryPath: "/home/me/elsewhere", isHome: false, sessionCount: 0, previewSessions: [])
        let made = ProjectSummary(id: "p_3", title: "Atlas", primaryPath: "/home/me/atlas/", isHome: false, sessionCount: 0, previewSessions: [])
        let list = [old, other, made]

        XCTAssertEqual(AppState.projectMadeAnyway(name: "atlas", firstFolder: "/home/me/atlas", knownIDs: ["p_1"], in: list)?.id, "p_3")
        XCTAssertNil(AppState.projectMadeAnyway(name: "Atlas", firstFolder: "/home/me/old", knownIDs: ["p_1"], in: list),
                     "a project that was there before isn't this one")
        XCTAssertNil(AppState.projectMadeAnyway(name: "Atlas", firstFolder: "/home/me/new", knownIDs: [], in: list),
                     "a name alone could be another device's")
    }
}
