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

    def test_points_the_map_at_the_new_file(self):
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        text = (self.repo / split.MAP).read_text()
        self.assertIn("`Conduit/Services/AppState+Connection.swift` (connect), "
                      "`Conduit/Services/AppState.swift` (openChat)", text)
        self.assertIn("**Checked:** 2026-11-12, #42 (the code it lists moved out of AppState.swift, "
                      "issue 828); 2026-11-01, #1.", text)


if __name__ == "__main__":
    unittest.main()
