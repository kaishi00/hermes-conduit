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
    var isReady: Bool {
        isConnected && token != nil
    }

    /// Connects.
    func connect() {
        attempts += 1
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
    }

    init() {}
}
'''

STEPS = [{"AppState+Connection.swift": ["Connection"], "HelperType.swift": ["file:HelperType"]}]


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

    def test_points_the_map_at_the_new_file(self):
        split.run(self.repo, 1, True, pr=42, today="2026-11-12")
        text = (self.repo / split.MAP).read_text()
        self.assertIn("`Conduit/Services/AppState+Connection.swift` (connect), "
                      "`Conduit/Services/AppState.swift` (openChat)", text)
        self.assertIn("**Checked:** 2026-11-12, #42 (the code it lists moved out of AppState.swift, "
                      "issue 828); 2026-11-01, #1.", text)


if __name__ == "__main__":
    unittest.main()
