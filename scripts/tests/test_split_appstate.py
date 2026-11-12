"""scripts/split-appstate.py on a small AppState: what moves, what stays and
which private names it widens."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("split_appstate", ROOT / "scripts/split-appstate.py")
split = importlib.util.module_from_spec(spec)
spec.loader.exec_module(split)

SOURCE = '''//
//  AppState.swift
//

import SwiftUI

private let lifecycleLog = Logger(subsystem: "s", category: "c")

/// A helper type.
enum HelperType {
    static func help() -> Int { 1 }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Connection

    @Published var isConnected = false {
        didSet { note("}") }
    }
    private var token: String?
    private(set) var attempts = 0
    private(set) var readOnly = 0
    fileprivate var lastError: String?
    private struct Claim { var kind: ClaimKind }
    private enum ClaimKind { case server }
    private var claims: [Claim] = []
    var isReady: Bool {
        isConnected && token != nil
    }

    /// Connects.
    func connect() {
        attempts += 1
        lastError = nil
        _ = claims
        lifecycleLog.info("connect \\(readOnly)")
        let text = """
        a { brace in a string
        """
        _ = text
    }

    // MARK: - Chats

    private func note(_ s: String) {}

    func openChat() {
        note("open")
        hideRoom()
        let kept = """
        first


        after two blank lines
        """
        _ = kept
    }

    init() {}
}

// MARK: - Rooms

extension AppState {
    private func hideRoom() {}
}
'''

STEPS = [{"AppState+Connection.swift": ["Connection"], "HelperType.swift": ["file:HelperType"],
          "AppState+Rooms.swift": ["outer:Rooms"]}]


class SplitAppStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        (self.repo / "Conduit/Services").mkdir(parents=True)
        (self.repo / "Shared").mkdir()
        (self.repo / "docs").mkdir()
        (self.repo / split.APP_STATE).write_text(SOURCE)
        (self.repo / split.MAP).write_text(
            "## Connecting\n\n- State: `Conduit/Services/AppState.swift` (connect, openChat)\n\n"
            "**Checked:** 2026-11-01, #1.\n")
        self.saved = split.STEPS
        split.STEPS = STEPS

    def tearDown(self):
        split.STEPS = self.saved
        self.tmp.cleanup()

    def read(self, name):
        return (self.repo / "Conduit/Services" / name).read_text()

    def test_moves_code_and_keeps_stored_properties(self):
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        app = self.read("AppState.swift")
        moved = self.read("AppState+Connection.swift")
        self.assertIn("extension AppState {\n    // MARK: - Connection", moved)
        for kept in ("@Published var isConnected", "var token: String?", "init() {}", "func openChat()"):
            self.assertIn(kept, app)
        for gone in ("func connect()", "var isReady: Bool", "enum HelperType"):
            self.assertNotIn(gone, app)
            self.assertIn(gone, moved if gone != "enum HelperType" else self.read("HelperType.swift"))
        self.assertIn("/// Connects.\n    func connect()", moved)
        self.assertIn('a { brace in a string', moved)

    def test_widens_only_what_another_file_uses(self):
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        app = self.read("AppState.swift")
        self.assertIn("\n    var token: String?", app, "read by isReady, now in another file")
        self.assertIn("\n    var attempts = 0", app, "written by connect")
        self.assertIn("private(set) var readOnly = 0", app, "only read elsewhere")
        self.assertIn("private func note(", app, "only AppState.swift calls it")
        self.assertIn("\nlet lifecycleLog", app)
        self.assertIn("\n    var lastError: String?", app, "fileprivate is widened too")
        self.assertIn("\n    var claims: [Claim]", app)
        moved = self.read("AppState+Connection.swift")
        self.assertIn("\n    struct Claim {", moved, "the widened property's type")
        self.assertIn("\n    enum ClaimKind {", moved, "and the types that type shows")

    def test_widens_a_moved_extensions_members(self):
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        self.assertIn("\n    func hideRoom()", self.read("AppState+Rooms.swift"), "openChat calls it")

    def test_leaves_blank_lines_in_strings_alone(self):
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        self.assertIn("first\n\n\n        after two blank lines", self.read("AppState.swift"))

    def test_refuses_before_writing_anything(self):
        (self.repo / "Conduit/Services/HelperType.swift").write_text("// already here\n")
        with self.assertRaises(SystemExit):
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        self.assertFalse((self.repo / "Conduit/Services/AppState+Connection.swift").exists())
        self.assertEqual((self.repo / split.APP_STATE).read_text(), SOURCE)

    def test_a_map_it_cant_read_stops_it_before_any_file_is_written(self):
        (self.repo / split.MAP).unlink()
        with self.assertRaises(FileNotFoundError):
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        self.assertFalse((self.repo / "Conduit/Services/AppState+Connection.swift").exists())
        self.assertEqual((self.repo / split.APP_STATE).read_text(), SOURCE)

    def test_appends_to_an_existing_extension_file(self):
        (self.repo / "Conduit/Services/AppState+Connection.swift").write_text(
            "import SwiftUI\n\nextension AppState {\n    func old() {}\n}\n")
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        text = self.read("AppState+Connection.swift")
        self.assertTrue(text.startswith("import SwiftUI\n\nextension AppState {\n    func old() {}\n}\n\n"
                                        "extension AppState {\n    // MARK: - Connection"), text)
        with self.assertRaises(SystemExit):
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")

    def test_appending_under_a_title_the_file_has_keeps_one_mark(self):
        (self.repo / "Conduit/Services/AppState+Connection.swift").write_text(
            "import SwiftUI\n\nextension AppState {\n    // MARK: - Connecting\n\n    func old() {}\n}\n")
        saved, split.MARK_TITLES = split.MARK_TITLES, {"AppState+Connection.swift": "Connecting"}
        try:
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        finally:
            split.MARK_TITLES = saved
        text = self.read("AppState+Connection.swift")
        self.assertEqual(text.count("// MARK: - Connecting"), 1, text)
        self.assertIn("    func old() {}\n}\n\nextension AppState {\n", text)
        self.assertIn("func connect()", text)

    def test_appending_brings_the_imports_the_code_used(self):
        (self.repo / "Conduit/Services/AppState+Connection.swift").write_text(
            "//\n//  AppState+Connection.swift\n//\n\nimport Foundation\n\nextension AppState {\n    func old() {}\n}\n")
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        text = self.read("AppState+Connection.swift")
        self.assertIn("\nimport Foundation\nimport SwiftUI\n\nextension AppState {\n    func old()", text)

    def test_repeated_and_numbered_region_names(self):
        (self.repo / split.APP_STATE).write_text('''import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // MARK: - Stars (#757)

    var starred: Set<String> = []

    func star() {}

    // MARK: - Tools

    func tools() {}

    // MARK: - Tools

    func moreTools() {}
}
''')
        split.STEPS = [{"AppState+Stars.swift": ["Stars (#757)", "Tools@2"]}]
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        moved = self.read("AppState+Stars.swift")
        app = self.read("AppState.swift")
        self.assertIn("    // MARK: - Stars (#757)\n\n    func star() {}", moved)
        self.assertIn("    // MARK: - Tools\n\n    func moreTools() {}", moved)
        self.assertNotIn("@2", moved)
        self.assertIn("func tools()", app, "the first Tools region stays")
        self.assertIn("    // MARK: - Stars (#757) (AppState+Stars.swift)\n\n    var starred", app,
                      "a MARK whose code moved keeps its blank line")

    def test_a_mutating_call_counts_as_a_write(self):
        (self.repo / "Shared/LoadState.swift").write_text(
            "struct LoadState {\n    var n = 0\n    mutating func reset() { n = 0 }\n}\n")
        (self.repo / split.APP_STATE).write_text('''import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // MARK: - Connection

    private(set) var loadState = LoadState()
    private(set) var other = LoadState()
    private(set) var count = 0
    private(set) var bits = 0
    private(set) var masks = [0]
    private(set) var shifted = LoadState()
    private(set) var unshifted = 0
    private(set) var weakly = 0
    private(set) var order = [0]

    func connect() {
        loadState.reset()
        _ = other.n
        count &+= 1
        bits &<<= 1
        masks[0] &>>= 2
        shifted.n &<<= 3
        _ = unshifted &<< 1
        Task { [weak self] in self?.weakly = 1 }
        order.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
    }
}
''')
        split.STEPS = [{"AppState+Connection.swift": ["Connection"]}]
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        app = self.read("AppState.swift")
        self.assertIn("\n    var loadState = LoadState()", app)
        self.assertIn("private(set) var other = LoadState()", app)
        self.assertIn("\n    var count = 0", app, "&+= writes it")
        self.assertIn("\n    var bits = 0", app, "&<<= writes it")
        self.assertIn("\n    var masks = [0]", app, "&>>= through a subscript writes it")
        self.assertIn("\n    var shifted = LoadState()", app, "&<<= through a property writes it")
        self.assertIn("private(set) var unshifted = 0", app, "a plain shift only reads it")
        self.assertIn("\n    var weakly = 0", app, "self?. writes it")
        self.assertIn("\n    var order = [0]", app, "move(fromOffsets:toOffset:) writes it")

    def test_widens_another_types_fileprivate_member_the_moved_code_writes(self):
        (self.repo / split.APP_STATE).write_text('''import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // MARK: - Connection

    let projection = Projection()

    func connect() {
        projection.text = "on"
        _ = projection.count
        projection.load.reset()
        swap(&projection.n, &projection.m)
        bump(&rows[0].k)
    }
}

final class Projection {
    fileprivate(set) var text = ""
    fileprivate(set) var count = 0
    fileprivate var hidden = 0
    fileprivate(set) var load = Load()
    fileprivate(set) var n = 0
    fileprivate(set) var m = 0
    fileprivate(set) var k = 0
}
''')
        (self.repo / "Shared/Load.swift").write_text(
            "struct Load {\n    var v = 0\n    mutating func reset() { v = 0 }\n}\n")
        split.STEPS = [{"AppState+Connection.swift": ["Connection"]}]
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        app = self.read("AppState.swift")
        self.assertIn("\n    var text = \"\"", app, "written as projection.text from the new file")
        self.assertIn("fileprivate(set) var count = 0", app, "only read")
        self.assertIn("fileprivate var hidden = 0", app, "not used")
        self.assertIn("\n    var load = Load()", app, "a mutating call writes it")
        self.assertIn("\n    var n = 0", app, "passed inout")
        self.assertIn("\n    var k = 0", app, "passed inout through a subscript")

    def test_one_mark_for_two_regions_under_one_title(self):
        split.STEPS = [{"AppState+Both.swift": ["Connection|from connect", "Chats|from openChat"]}]
        saved, split.MARK_TITLES = split.MARK_TITLES, {"AppState+Both.swift": "Both"}
        try:
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        finally:
            split.MARK_TITLES = saved
        both = self.read("AppState+Both.swift")
        self.assertEqual(both.count("// MARK: - Both"), 1, both)
        self.assertIn("func openChat()", both)

    def test_cuts_a_long_region_at_a_declaration(self):
        split.STEPS = [{"AppState+Connection.swift": ["Connection|until connect"],
                        "AppState+Connect.swift": ["Connection|from connect"]}]
        saved, split.MARK_TITLES = split.MARK_TITLES, {"AppState+Connect.swift": "Connecting"}
        try:
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        finally:
            split.MARK_TITLES = saved
        self.assertIn("var isReady: Bool", self.read("AppState+Connection.swift"))
        connect = self.read("AppState+Connect.swift")
        self.assertIn("    // MARK: - Connecting\n\n    /// Connects.\n    func connect()", connect)
        self.assertNotIn("isReady", connect)
        with self.assertRaises(SystemExit):
            split.STEPS = [{"AppState+Connection.swift": ["Connection|from nothing"]}]
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")

    def test_cuts_at_one_of_a_names_overloads(self):
        (self.repo / split.APP_STATE).write_text('''import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // MARK: - Picking

    func pick(_ n: Int) {}

    func pick(_ s: String) {}

    func last() {}
}
''')
        with self.assertRaises(SystemExit, msg="pick is two declarations"):
            split.STEPS = [{"AppState+Pick.swift": ["Picking|from pick"]}]
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        split.STEPS = [{"AppState+Pick.swift": ["Picking|from pick#2"]}]
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        self.assertIn("func pick(_ n: Int)", self.read("AppState.swift"))
        pick = self.read("AppState+Pick.swift")
        self.assertIn("func pick(_ s: String)", pick)
        self.assertIn("func last()", pick)

    def test_cuts_a_slice_between_two_declarations(self):
        with self.assertRaises(SystemExit, msg="nothing between"):
            split.STEPS = [{"AppState+Ready.swift": ["Connection|from connect until isReady"]}]
            split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        split.STEPS = [{"AppState+Ready.swift": ["Connection|from isReady until connect"],
                        "AppState+Connect.swift": ["Connection|from connect"]}]
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        ready = self.read("AppState+Ready.swift")
        self.assertIn("var isReady: Bool", ready)
        self.assertNotIn("func connect()", ready)
        self.assertIn("func connect()", self.read("AppState+Connect.swift"))
        self.assertIn("// MARK: - Connection (AppState+Ready.swift, AppState+Connect.swift)\n",
                      self.read("AppState.swift"), "the MARK left over stored properties names both files")

    def test_a_mark_cut_again_keeps_the_files_it_named(self):
        split.STEPS = [{"AppState+Ready.swift": ["Connection|until connect"]}]
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        region = "Connection (AppState+Ready.swift)"
        split.STEPS = [{"AppState+Connect.swift": [region]}]
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        self.assertIn("// MARK: - Connection (AppState+Ready.swift, AppState+Connect.swift)\n",
                      self.read("AppState.swift"))

    def test_points_the_map_at_the_new_file(self):
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        text = (self.repo / split.MAP).read_text()
        self.assertIn("`Conduit/Services/AppState+Connection.swift` (connect), "
                      "`Conduit/Services/AppState.swift` (openChat)", text)
        self.assertIn("**Checked:** 2026-11-12, #42 (the code it lists moved out of AppState.swift, "
                      "issue 828); 2026-11-01, #1.", text)


if __name__ == "__main__":
    unittest.main()
