"""Regression coverage for scripts/check-hermes-slash-parity.py."""

import os
import unittest

from _util import SCRIPTS_DIR, load_module

check = load_module("check_hermes_slash_parity", "check-hermes-slash-parity.py")
ROOT = os.path.dirname(SCRIPTS_DIR)

PARITY = """\
| Command | Gateway (`slash.exec`) | Classic CLI | Ink | Desktop | ACP | Notes |
|---|---|---|---|---|---|---|
| `/agents` (/tasks) | refused | x | x | action: agents | x |  |
| `/fast` | control | x | x | unavailable: advanced | x |  |
| `/steer` (/s) | refused | x | x | action: steer | x |  |
| `/status` | read | x | x | x | x |  |
"""

COMMANDS = """\
COMMAND_REGISTRY = [
    CommandDef("fast", "Fast mode", "Configuration",
               subcommands=("normal", "fast", "auto"), desktop="advanced"),
    CommandDef("skills", "Skills", "Tools",
               subcommands=("search", "pending"),
               desktop_subcommands=("pending",)),
]
"""


class CheckHermesSlashParityTests(unittest.TestCase):
    def drift(self, hidden=frozenset({"agents", "tasks"}), native=frozenset({"steer", "s"}), fast=frozenset({"normal", "fast"})):
        return check.find_drift(
            check.parse_parity_table(PARITY),
            check.parse_registry_subcommands(COMMANDS),
            set(hidden),
            set(native),
            {"fast": set(fast)},
        )

    def test_matching_lists_report_nothing(self):
        self.assertEqual(self.drift(), [])

    def test_a_refused_alias_left_visible_is_reported(self):
        problems = self.drift(hidden={"agents"})
        self.assertEqual(len(problems), 1)
        self.assertIn("`/tasks`", problems[0])

    def test_a_hidden_command_hermes_now_runs_is_reported(self):
        problems = self.drift(hidden={"agents", "tasks", "status"})
        self.assertEqual(len(problems), 1)
        self.assertIn("Hermes now runs `/status`", problems[0])

    def test_a_new_hermes_word_and_a_dropped_one_are_reported(self):
        problems = self.drift(fast={"normal", "fast", "turbo"})
        self.assertEqual(problems, ["Conduit sends `/fast turbo`, which Hermes no longer offers."])
        check.ACKNOWLEDGED_WORDS["fast"].discard("auto")
        try:
            self.assertIn("Hermes offers `/fast auto`", self.drift()[0])
        finally:
            check.ACKNOWLEDGED_WORDS["fast"].add("auto")

    def test_registry_reads_subcommands_not_the_desktop_narrowing(self):
        self.assertEqual(check.parse_registry_subcommands(COMMANDS)["skills"], ["search", "pending"])

    def test_conduit_sources_parse(self):
        with open(os.path.join(ROOT, check.APP_STATE), encoding="utf-8") as fh:
            app_state = fh.read()
        with open(os.path.join(ROOT, check.MODEL_PICKER), encoding="utf-8") as fh:
            picker = fh.read()
        native = check.parse_native_routes(app_state)
        self.assertTrue({"steer", "queue", "stop", "new", "compress", "undo", "retry"} <= native)
        self.assertIn("save", check.parse_swift_string_set(app_state, "slashCommandsWithoutConduitRoute"))
        self.assertEqual(check.parse_swift_enum_raw_values(picker, "ModelSpeed"), {"normal", "fast", "ultrafast"})
        self.assertIn("none", check.parse_swift_enum_raw_values(picker, "ReasoningEffortLevel"))


if __name__ == "__main__":
    unittest.main()
