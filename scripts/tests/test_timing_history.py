"""Regression coverage for scripts/update-timing-history.py (EWMA cache)."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from _util import SCRIPTS_DIR

updater = None  # exercised via CLI; module import would shadow argparse


def run_update(tmp, observations, inventory, history=None, extra_args=None):
    out = Path(tmp) / "history-out.json"
    args = [sys.executable, str(Path(SCRIPTS_DIR) / "update-timing-history.py"),
            "--observations", *[str(o) for o in observations],
            "--inventory", str(inventory), "--out", str(out)]
    if history is not None:
        args += ["--history", str(history)]
    args += (extra_args or [])
    proc = subprocess.run(args, capture_output=True, text=True)
    doc = None
    if out.exists():
        doc = json.loads(out.read_text(encoding="utf-8"))
    return proc, doc


def write_json(path, doc):
    Path(path).write_text(json.dumps(doc), encoding="utf-8")
    return Path(path)


def observation_file(tmp, name, classes):
    return write_json(Path(tmp) / name, {
        "schema_version": 1, "classes": classes})


def inventory_file(tmp, unit, ui=()):
    return write_json(Path(tmp) / "plan.json", {
        "inventory": {"unit": unit, "ui": list(ui)}})


class EwmaTests(unittest.TestCase):
    def test_ewma_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            obs = [observation_file(tmp, "o1.json", {"AlphaTests": 20.0})]
            hist = write_json(Path(tmp) / "h.json", {
                "schema_version": 1, "classes": {"AlphaTests": 10.0}})
            proc, doc = run_update(tmp, obs, inv, hist)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertAlmostEqual(doc["classes"]["AlphaTests"], 12.5)  # .75*10+.25*20

    def test_first_observation_taken_verbatim(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            obs = [observation_file(tmp, "o1.json", {"AlphaTests": 7.25})]
            proc, doc = run_update(tmp, obs, inv, None)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertAlmostEqual(doc["classes"]["AlphaTests"], 7.25)

    def test_extreme_outlier_is_clamped(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            obs = [observation_file(tmp, "o1.json", {"AlphaTests": 1000.0})]
            hist = write_json(Path(tmp) / "h.json", {
                "schema_version": 1, "classes": {"AlphaTests": 10.0}})
            proc, doc = run_update(tmp, obs, inv, hist)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            # clamped to prev*ratio = 50, then ewma: .75*10 + .25*50 = 20
            self.assertAlmostEqual(doc["classes"]["AlphaTests"], 20.0)

    def test_max_seconds_caps_after_repeated_outliers(self):
        # A permanently slow runner drags estimates up 25% per run, clamped to
        # prev*5 each time; the absolute cap must still hold in the output.
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            obs = [observation_file(tmp, "o1.json", {"AlphaTests": 10000.0})]
            args = ["--max-seconds", "600"]
            hist = None
            seen = []
            for round_no in range(12):
                proc, doc = run_update(tmp, obs, inv, hist, extra_args=args)
                hist = Path(tmp) / ("h" + str(round_no) + ".json")
                hist.write_text(json.dumps(doc), encoding="utf-8")
                seen.append(doc["classes"]["AlphaTests"])
            self.assertLessEqual(max(seen), 600.0 + 1e-9)

    def test_one_slow_runner_does_not_reshape_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests", "BetaTests"])
            hist = write_json(Path(tmp) / "h.json", {
                "schema_version": 1,
                "classes": {"AlphaTests": 10.0, "BetaTests": 10.0}})
            obs = [observation_file(tmp, "o1.json",
                                    {"AlphaTests": 500.0, "BetaTests": 10.0})]
            _proc, doc = run_update(tmp, obs, inv, hist)
            self.assertLess(doc["classes"]["AlphaTests"], 30.0)
            self.assertAlmostEqual(doc["classes"]["BetaTests"], 10.0)


class PruneAndSafetyTests(unittest.TestCase):
    def test_prune_to_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AliveTests"])
            hist = write_json(Path(tmp) / "h.json", {
                "schema_version": 1,
                "classes": {"AliveTests": 5.0, "DeletedTests": 8.0}})
            obs = [observation_file(tmp, "o1.json", {"AliveTests": 6.0})]
            proc, doc = run_update(tmp, obs, inv, hist)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(sorted(doc["classes"]), ["AliveTests"])

    def test_corrupt_history_starts_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            obs = [observation_file(tmp, "o1.json", {"AlphaTests": 4.0})]
            hist = Path(tmp) / "h.json"
            hist.write_text("{{{ not json", encoding="utf-8")
            proc, doc = run_update(tmp, obs, inv, hist)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertAlmostEqual(doc["classes"]["AlphaTests"], 4.0)

    def test_corrupt_observations_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            bad = Path(tmp) / "bad.json"
            bad.write_text("nope", encoding="utf-8")
            good = observation_file(tmp, "good.json", {"AlphaTests": 3.0})
            proc, doc = run_update(tmp, [bad, good], inv, None)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertAlmostEqual(doc["classes"]["AlphaTests"], 3.0)

    def test_non_positive_observation_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            obs = [observation_file(tmp, "o1.json", {"AlphaTests": 0.0})]
            proc, doc = run_update(tmp, obs, inv, None)
            self.assertEqual(proc.returncode, 0)
            self.assertNotIn("AlphaTests", doc["classes"])

    def test_decay_weights_must_sum_to_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            obs = [observation_file(tmp, "o1.json", {"AlphaTests": 1.0})]
            proc, _doc = run_update(tmp, obs, inv, None,
                                    extra_args=["--decay-prev", "0.5",
                                                "--decay-new", "0.25"])
            self.assertNotEqual(proc.returncode, 0)

    def test_boolean_observation_rejected(self):
        # Python treats True as an int; a JSON true must never become 1.0s.
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            obs = [write_json(Path(tmp) / "o1.json", {
                "schema_version": 1, "classes": {"AlphaTests": True}})]
            proc, doc = run_update(tmp, obs, inv, None)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn("AlphaTests", doc["classes"])

    def test_ui_inventory_included(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"], ["SelectionObserverUITests"])
            obs = [observation_file(tmp, "o1.json",
                                    {"SelectionObserverUITests": 68.0})]
            proc, doc = run_update(tmp, obs, inv, None)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertAlmostEqual(doc["classes"]["SelectionObserverUITests"], 68.0)


class LaneResultGateTests(unittest.TestCase):
    """--lane-results pairs each observations file with its lane result:
    only clean primary passes merge; stalled lanes and fresh-runner recovery
    artifacts are excluded from history."""

    def _lane_dir(self, tmp, name):
        d = Path(tmp) / name
        d.mkdir(parents=True, exist_ok=True)
        return d

    def _lane_result(self, directory, status, fresh=False):
        doc = {"schema_version": 1, "lane": directory.name, "status": status,
               "finished_at": "2026-09-15T10:00:00Z",
               "fresh_runner_recovery": fresh}
        path = directory / "lane-result.json"
        path.write_text(json.dumps(doc), encoding="utf-8")
        return path

    def _run(self, tmp, observations, lane_results, inventory):
        out = Path(tmp) / "out.json"
        proc = subprocess.run(
            [sys.executable, str(Path(SCRIPTS_DIR) / "update-timing-history.py"),
             "--observations", *[str(o) for o in observations],
             "--lane-results", *[str(lr) for lr in lane_results],
             "--inventory", str(inventory), "--out", str(out)],
            capture_output=True, text=True)
        doc = None
        if out.exists():
            doc = json.loads(out.read_text(encoding="utf-8"))
        return proc, doc

    def test_passing_lane_merges(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            lane = self._lane_dir(tmp, "unit-1")
            obs = write_json(lane / "observations.json",
                             {"schema_version": 1, "classes": {"AlphaTests": 20.0}})
            lr = self._lane_result(lane, "pass")
            proc, doc = self._run(tmp, [obs], [lr], inv)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertAlmostEqual(doc["classes"]["AlphaTests"], 20.0)

    def test_stalled_lane_excluded(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            lane = self._lane_dir(tmp, "unit-2")
            obs = write_json(lane / "observations.json",
                             {"schema_version": 1, "classes": {"AlphaTests": 900.0}})
            lr = self._lane_result(lane, "timeout")
            proc, doc = self._run(tmp, [obs], [lr], inv)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn("AlphaTests", doc["classes"])

    def test_recovery_artifact_excluded(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests"])
            lane = self._lane_dir(tmp, "unit-2")
            obs = write_json(lane / "observations.json",
                             {"schema_version": 1, "classes": {"AlphaTests": 55.0}})
            lr = self._lane_result(lane, "pass", fresh=True)
            proc, doc = self._run(tmp, [obs], [lr], inv)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertNotIn("AlphaTests", doc["classes"])

    def test_mixed_lanes_merge_only_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            inv = inventory_file(tmp, ["AlphaTests", "BetaTests"])
            lane1 = self._lane_dir(tmp, "unit-1")
            obs1 = write_json(lane1 / "observations.json",
                              {"schema_version": 1, "classes": {"AlphaTests": 12.0}})
            lane2 = self._lane_dir(tmp, "unit-2")
            obs2 = write_json(lane2 / "observations.json",
                              {"schema_version": 1, "classes": {"BetaTests": 777.0}})
            lr1 = self._lane_result(lane1, "pass")
            lr2 = self._lane_result(lane2, "timeout")
            proc, doc = self._run(tmp, [obs1, obs2], [lr1, lr2], inv)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertAlmostEqual(doc["classes"]["AlphaTests"], 12.0)
            self.assertNotIn("BetaTests", doc["classes"])


if __name__ == "__main__":
    unittest.main()
