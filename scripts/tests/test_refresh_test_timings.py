"""Regression coverage for scripts/refresh-test-timings.py."""

import json
import os
import tempfile
import unittest

from _util import load_module

ref = load_module("refresh_test_timings", "refresh-test-timings.py")

LOG = """\
2026-11-16T08:40:01.1Z Test Suite 'BotModeTests' started at 2026-11-16 08:40:01.100.
2026-11-16T08:40:18.6Z Test Suite 'BotModeTests' passed at 2026-11-16 08:40:18.600.
2026-11-16T08:40:18.6Z \t Executed 268 tests, with 0 failures (0 unexpected) in 17.2 (17.487) seconds
2026-11-16T08:40:30.0Z Test Suite 'PulseFeedTests' failed at 2026-11-16 08:40:30.000.
2026-11-16T08:40:30.0Z \t Executed 73 tests, with 1 failure (0 unexpected) in 1.9 (1.987) seconds
2026-11-16T08:40:30.1Z Test Suite 'ConduitTests.xctest' passed at 2026-11-16 08:40:30.100.
2026-11-16T08:40:30.1Z \t Executed 341 tests, with 1 failure (0 unexpected) in 19.1 (19.474) seconds
2026-11-16T08:40:30.2Z Test Suite 'Selected tests' passed at 2026-11-16 08:40:30.200.
2026-11-16T08:40:30.2Z \t Executed 341 tests, with 1 failure (0 unexpected) in 19.1 (19.5) seconds
2026-11-16T08:41:00.0Z Test Suite 'BotModeTests' passed at 2026-11-16 08:41:00.000.
2026-11-16T08:41:00.0Z \t Executed 268 tests, with 0 failures (0 unexpected) in 9.0 (9.5) seconds
"""


class RefreshTestTimingsTests(unittest.TestCase):
    def test_measures_each_class_and_keeps_its_longest_time(self):
        found = ref.measure(LOG.splitlines())
        self.assertEqual(found, {"BotModeTests": 17.487, "PulseFeedTests": 1.987})

    def test_measured_classes_replace_their_entries_and_the_rest_stay(self):
        baseline = {"schema_version": 1, "updated_at": "2026-08-28T15:10:22Z",
                    "classes": {"BotModeTests": 3.0, "LoginKeyboardUITests": 80.0}}
        out = ref.refresh(baseline, {"BotModeTests": 17.4871, "PulseFeedTests": 1.987},
                          "2026-11-17T05:00:00Z")
        self.assertEqual(out["classes"], {"BotModeTests": 17.487,
                                          "LoginKeyboardUITests": 80.0,
                                          "PulseFeedTests": 1.987})
        self.assertEqual(out["updated_at"], "2026-11-17T05:00:00Z")
        self.assertEqual(out["schema_version"], 1)

    def test_logs_without_timings_leave_the_baseline_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = os.path.join(tmp, "timings.json")
            log = os.path.join(tmp, "empty.log")
            with open(base, "w") as fh:
                json.dump({"classes": {"A": 1.0}}, fh)
            with open(log, "w") as fh:
                fh.write("build only\n")
            self.assertEqual(ref.main(["--baseline", base, log]), 1)
            with open(base) as fh:
                self.assertEqual(json.load(fh), {"classes": {"A": 1.0}})

    def test_two_shard_logs_keep_each_class_longest_time(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = os.path.join(tmp, "timings.json")
            with open(base, "w") as fh:
                json.dump({"classes": {"BotModeTests": 3.0}}, fh)
            logs = []
            for i, seconds in enumerate(("4.5", "12.25")):
                path = os.path.join(tmp, f"shard{i}.log")
                with open(path, "w") as fh:
                    fh.write("Test Suite 'BotModeTests' passed at 2026-11-16 08:40:18.600.\n"
                             f"\t Executed 268 tests, with 0 failures (0 unexpected) in 1 ({seconds}) seconds\n")
                logs.append(path)
            self.assertEqual(ref.main(["--baseline", base] + logs), 0)
            with open(base) as fh:
                self.assertEqual(json.load(fh)["classes"], {"BotModeTests": 12.25})

    def test_a_missing_log_fails_cleanly(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(ref.main(["--baseline", os.path.join(tmp, "b.json"),
                                       os.path.join(tmp, "missing.log")]), 2)


if __name__ == "__main__":
    unittest.main()
