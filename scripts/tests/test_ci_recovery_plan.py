"""Regression coverage for scripts/ci-recovery-plan.py.

The recovery planner consumes finished unit lane artifacts plus the
authoritative plan and decides which lanes (if any) get a fresh-runner
retry. Core properties pinned here: only the recoverable stall shape
(watchdog timeout, zero identified failures) is eligible, every entry is
rebuilt from the plan, and any disagreement/ambiguity fails closed.
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from _util import SCRIPTS_DIR

sys.path.insert(0, SCRIPTS_DIR)
import ci_lane_recovery  # noqa: E402  (fixture embedding mirrors the runner)

PLAN = {
    "schema_version": 1,
    "inventory": {"unit": ["AlphaTests", "BetaTests", "GammaTests"], "ui": []},
    "estimates": {"AlphaTests": 10.0, "BetaTests": 12.0, "GammaTests": 8.0},
    "unit_lanes": [
        {"lane": "unit-1", "target": "ConduitTests", "classes": ["AlphaTests"],
         "predicted_s": 10.0, "timeout_s": 600, "job_timeout_min": 42},
        {"lane": "unit-2", "target": "ConduitTests", "classes": ["BetaTests"],
         "predicted_s": 12.0, "timeout_s": 600, "job_timeout_min": 42},
    ],
}

STALL_ATTEMPTS = [
    {"mode": "lane", "n": 1, "status": "timeout"},
    {"mode": "isolation", "status": "incomplete"},
]


def lane_doc(lane="unit-1", cls="AlphaTests", status="pass", attempts=None,
             failures=None):
    if attempts is None:
        attempts = [{"mode": "lane", "n": 1, "status": "passed"}]
    doc = {
        "schema_version": 1,
        "lane": lane,
        "kind": "unit",
        "target": "ConduitTests",
        "classes": [cls],
        "status": status,
        "predicted_s": 10.0,
        "timeout_s": 600,
        "actual_s": 321.0,
        "started_at": "2026-09-15T10:00:00Z",
        "finished_at": "2026-09-15T10:05:21Z",
        "attempts": attempts,
        "hung_class": None,
        "isolation": None,
    }
    if failures is not None:
        doc["failures"] = failures
    return doc


def embed(doc, fresh=False):
    doc["fresh_runner_recovery"] = fresh
    classification, reason = ci_lane_recovery.classify_lane_result(doc)
    doc["recovery"] = None if classification is None else {
        "classification": classification, "reason": reason,
        "eligible": (classification in ci_lane_recovery.RECOVERY_ELIGIBLE_CLASSES
                     and not fresh)}
    return doc


def run_plan(tmp, unit_result="failure", plan=PLAN, lanes=None, mutate=None):
    root = Path(tmp)
    (root / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
    lanes_dir = root / "lanes"
    lanes_dir.mkdir(exist_ok=True)
    for doc in lanes or []:
        lane = doc["lane"]
        d = lanes_dir / f"lane-{lane}-attempt-1" / lane
        d.mkdir(parents=True, exist_ok=True)
        (d / "lane-result.json").write_text(json.dumps(doc), encoding="utf-8")
    out = root / "unit-recovery-matrix.json"
    args = [sys.executable, os.path.join(SCRIPTS_DIR, "ci-recovery-plan.py"),
            "--plan-json", str(root / "plan.json"),
            "--lanes-dir", str(lanes_dir),
            "--unit-result", unit_result,
            "--matrix-out", str(out)]
    proc = subprocess.run(args, capture_output=True, text=True)
    matrix = None
    if out.exists():
        matrix = json.loads(out.read_text(encoding="utf-8"))
    if mutate:
        mutate(proc, matrix)
    return proc, matrix


class RecoveryPlanTests(unittest.TestCase):
    def test_unit_skipped_yields_empty_matrix(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, matrix = run_plan(tmp, unit_result="skipped")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(matrix, {"include": []})

    def test_unit_cancelled_yields_empty_matrix(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, matrix = run_plan(tmp, unit_result="cancelled")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(matrix, {"include": []})

    def test_all_lanes_pass_no_recovery_matrix(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, matrix = run_plan(tmp, lanes=[
                embed(lane_doc("unit-1")),
                embed(lane_doc("unit-2", cls="BetaTests"))])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(matrix, {"include": []})

    def test_watchdog_zero_failures_yields_exactly_that_lane(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, matrix = run_plan(tmp, lanes=[
                embed(lane_doc("unit-1")),
                embed(lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS))])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(len(matrix["include"]), 1)
            entry = matrix["include"][0]
            # The COMPLETE original lane inputs, derived from the plan.
            self.assertEqual(entry, {
                "lane": "unit-2",
                "target": "ConduitTests",
                "classes": "BetaTests",
                "class_estimates": "BetaTests=12.0",
                "predicted_s": 12.0,
                "timeout_s": 600,
                "job_timeout_min": 42,
            })

    def test_hang_identified_by_isolation_is_also_recoverable(self):
        # Isolation "hung" names a class but is not an assertion failure; the
        # demonstrated failure domain includes stalls that persist into
        # isolation on the wedged host. The fresh runner is the arbiter.
        with tempfile.TemporaryDirectory() as tmp:
            hung = lane_doc("unit-1", status="timeout",
                            attempts=[{"mode": "lane", "n": 1,
                                       "status": "timeout"},
                                      {"mode": "isolation", "status": "hung"}])
            hung["hung_class"] = "AlphaTests"
            proc, matrix = run_plan(tmp, lanes=[
                embed(hung),
                embed(lane_doc("unit-2", cls="BetaTests"))])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual([e["lane"] for e in matrix["include"]], ["unit-1"])

    def test_test_failure_is_not_eligible(self):
        with tempfile.TemporaryDirectory() as tmp:
            failing = lane_doc("unit-1", status="fail",
                               attempts=[{"mode": "lane", "n": 1,
                                          "status": "test-failures"}],
                               failures=[{"class": "AlphaTests",
                                          "test": "testTruth()"}])
            proc, matrix = run_plan(tmp, lanes=[
                embed(failing),
                embed(lane_doc("unit-2", cls="BetaTests"))])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(matrix, {"include": []})

    def test_unclassifiable_is_not_eligible(self):
        with tempfile.TemporaryDirectory() as tmp:
            unclassifiable = lane_doc("unit-1", status="fail",
                                      attempts=[{"mode": "lane", "n": 1,
                                                 "status": "unclassified"}])
            proc, matrix = run_plan(tmp, lanes=[
                embed(unclassifiable),
                embed(lane_doc("unit-2", cls="BetaTests"))])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(matrix, {"include": []})

    def test_retry_timeout_without_primary_watchdog_not_eligible(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = lane_doc("unit-1", status="timeout",
                           attempts=[{"mode": "lane", "n": 1,
                                      "status": "infra-error"},
                                     {"mode": "lane-retry", "n": 2,
                                      "status": "timeout"},
                                     {"mode": "isolation",
                                      "status": "incomplete"}])
            proc, matrix = run_plan(tmp, lanes=[
                embed(doc),
                embed(lane_doc("unit-2", cls="BetaTests"))])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(matrix, {"include": []})

    def test_multiple_recoverable_lanes_each_exactly_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = json.loads(json.dumps(PLAN))
            plan["unit_lanes"].append(
                {"lane": "unit-3", "target": "ConduitTests",
                 "classes": ["GammaTests"], "predicted_s": 8.0,
                 "timeout_s": 600, "job_timeout_min": 42})
            proc, matrix = run_plan(tmp, plan=plan, lanes=[
                embed(lane_doc("unit-1", status="timeout",
                               attempts=STALL_ATTEMPTS)),
                embed(lane_doc("unit-2", cls="BetaTests")),
                embed(lane_doc("unit-3", cls="GammaTests", status="timeout",
                               attempts=STALL_ATTEMPTS))])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual([e["lane"] for e in matrix["include"]],
                             ["unit-1", "unit-3"])

    def test_missing_lane_artifact_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, matrix = run_plan(tmp, lanes=[embed(lane_doc("unit-1"))])
            self.assertNotEqual(proc.returncode, 0)
            self.assertIsNone(matrix)
            self.assertIn("no lane-result artifact", proc.stderr)

    def test_malformed_lane_artifact_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "plan.json").write_text(json.dumps(PLAN), encoding="utf-8")
            lanes_dir = root / "lanes"
            d = lanes_dir / "lane-unit-1-attempt-1" / "unit-1"
            d.mkdir(parents=True)
            (d / "lane-result.json").write_text("{nope", encoding="utf-8")
            out = root / "matrix.json"
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "ci-recovery-plan.py"),
                 "--plan-json", str(root / "plan.json"),
                 "--lanes-dir", str(lanes_dir),
                 "--unit-result", "failure",
                 "--matrix-out", str(out)],
                capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("unreadable lane result", proc.stderr)

    def test_membership_disagreement_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, _ = run_plan(tmp, lanes=[
                embed(lane_doc("unit-1", cls="BetaTests")),  # wrong class
                embed(lane_doc("unit-2", cls="BetaTests"))])
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("differs from the plan", proc.stderr)

    def test_doc_without_embedded_classification_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, _ = run_plan(tmp, lanes=[
                lane_doc("unit-1"),  # no recovery block at all
                embed(lane_doc("unit-2", cls="BetaTests"))])
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no embedded recovery", proc.stderr)

    def test_missing_plan_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lanes_dir = root / "lanes"
            lanes_dir.mkdir()
            out = root / "matrix.json"
            proc = subprocess.run(
                [sys.executable, os.path.join(SCRIPTS_DIR, "ci-recovery-plan.py"),
                 "--plan-json", str(root / "absent.json"),
                 "--lanes-dir", str(lanes_dir),
                 "--unit-result", "failure",
                 "--matrix-out", str(out)],
                capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("fail", proc.stderr)


if __name__ == "__main__":
    unittest.main()
