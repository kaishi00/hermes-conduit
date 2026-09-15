"""Regression coverage for scripts/ci-gate.py (stable branch-protection check).

The gate v3 contract: the raw needs.unit.result is no longer the unit truth.
Every planned unit lane is adjudicated from its lane-result.json against the
plan, and exactly one fresh-runner recovery pass redeems a lane whose
primary invocation stalled with zero identified test failures. Anything
missing, malformed, duplicated, unplanned, or inconsistent with the plan
fails closed.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "ci_gate", os.path.join(SCRIPTS_DIR, "ci-gate.py"))
ci_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ci_gate)

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


def lane_doc(lane="unit-1", cls="AlphaTests", status="pass", attempts=None,
             failures=None, timeout_s=600, target="ConduitTests",
             hung=None, schema=1, isolation=None):
    """A lane-result document in the shape ci-test-lane.sh produces."""
    if attempts is None:
        attempts = [{"mode": "lane", "n": 1, "status": "passed"}]
    doc = {
        "schema_version": schema,
        "lane": lane,
        "kind": "unit",
        "target": target,
        "classes": [cls],
        "status": status,
        "predicted_s": 10.0,
        "timeout_s": timeout_s,
        "actual_s": 321.0,
        "started_at": "2026-09-15T10:00:00Z",
        "finished_at": "2026-09-15T10:05:21Z",
        "attempts": attempts,
        "simulator_reset": False,
        "simulator_erase": False,
        "hung_class": hung,
        "retried_classes": [],
        "infra_recovered_classes": [],
        "persistent_infra_classes": [],
        "isolation": isolation,
    }
    if failures is not None:
        doc["failures"] = failures
    return doc


def embed(doc, fresh=False):
    """Attach the recovery block exactly like extract-test-timings.py: the
    fresh-runner flag is part of the document BEFORE classification runs."""
    doc["fresh_runner_recovery"] = fresh
    classification, reason = ci_lane_recovery.classify_lane_result(doc)
    doc["recovery"] = None if classification is None else {
        "classification": classification,
        "reason": reason,
        "eligible": (classification in ci_lane_recovery.RECOVERY_ELIGIBLE_CLASSES
                     and not fresh),
    }
    return doc


# The demonstrated stall shape (PR #175 run 34926435961, unit-2).
STALL_ATTEMPTS = [
    {"mode": "lane", "n": 1, "status": "timeout"},
    {"mode": "isolation", "status": "incomplete"},
]


class World:
    """A synthetic artifact layout matching the workflow downloads."""

    def __init__(self, tmp):
        self.root = Path(tmp)
        (self.root / "plan").mkdir(parents=True, exist_ok=True)
        (self.root / "plan" / "plan.json").write_text(
            json.dumps(PLAN), encoding="utf-8")
        (self.root / "lanes").mkdir(exist_ok=True)
        (self.root / "recovery").mkdir(exist_ok=True)

    def primary(self, doc, attempt=1, artifact_lane=None):
        lane = artifact_lane or doc["lane"]
        d = self.root / "lanes" / f"lane-{lane}-attempt-{attempt}" / lane
        d.mkdir(parents=True, exist_ok=True)
        (d / "lane-result.json").write_text(
            json.dumps(doc), encoding="utf-8")

    def recovery(self, doc, attempt=1, artifact_lane=None):
        lane = artifact_lane or doc["lane"]
        d = (self.root / "recovery" /
             f"lane-recovery-{lane}-attempt-{attempt}" / lane)
        d.mkdir(parents=True, exist_ok=True)
        (d / "lane-result.json").write_text(
            json.dumps(doc), encoding="utf-8")


def gate_args(world, **results):
    values = {"plan": "success", "build": "success", "unit": "success",
              "ui": "success", "self_test": "success",
              "recovery_plan": "success", "recovery": "skipped"}
    values.update(results)
    return [
        sys.executable, os.path.join(SCRIPTS_DIR, "ci-gate.py"),
        "--plan", values["plan"], "--build", values["build"],
        "--unit", values["unit"], "--ui", values["ui"],
        "--self-test", values["self_test"],
        "--recovery-plan", values["recovery_plan"],
        "--recovery", values["recovery"],
        "--plan-json", str(world.root / "plan" / "plan.json"),
        "--unit-lanes-dir", str(world.root / "lanes"),
        "--recovery-lanes-dir", str(world.root / "recovery"),
    ]


def run_gate(world, **results):
    return subprocess.run(gate_args(world, **results),
                          capture_output=True, text=True)


def standard_world(tmp, unit1_doc, unit2_doc):
    world = World(tmp)
    world.primary(unit1_doc)
    world.primary(unit2_doc)
    return world


class GateWorldTests(unittest.TestCase):
    """Scenario coverage against a realistic artifact layout."""

    # 1. all original unit lanes pass -> no recovery -> gate passes
    def test_all_lanes_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(lane_doc("unit-2", cls="BetaTests")))
            proc = run_gate(world)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("final: PASS", proc.stdout)

    # 2. one original lane has an ordinary test failure -> gate fails,
    #    never recovery eligible
    def test_ordinary_test_failure_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            failing = lane_doc("unit-2", cls="BetaTests", status="fail",
                               attempts=[{"mode": "lane", "n": 1,
                                          "status": "test-failures"}],
                               failures=[{"class": "BetaTests",
                                          "test": "testTruth()"}])
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(failing))
            proc = run_gate(world, unit="failure", recovery="skipped")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("test-failure", proc.stdout)

    # 4. recoverable stall + fresh-runner PASS -> gate passes (recovered)
    def test_recovered_stall_passes_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            stalled = lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS)
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(stalled))
            world.recovery(embed(lane_doc("unit-2", cls="BetaTests"),
                                 fresh=True))
            proc = run_gate(world, unit="failure", recovery="success")
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("recovered infrastructure PASS", proc.stdout)

    # 5. recoverable stall + fresh-runner test failure -> gate fails
    def test_recovered_then_test_failure_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            stalled = lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS)
            retry_failed = lane_doc(
                "unit-2", cls="BetaTests", status="fail",
                attempts=[{"mode": "lane", "n": 1, "status": "test-failures"}],
                failures=[{"class": "BetaTests", "test": "testTruth()"}])
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(stalled))
            world.recovery(embed(retry_failed, fresh=True))
            proc = run_gate(world, unit="failure", recovery="failure")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("test-failure", proc.stdout)

    # 6. recoverable stall + fresh-runner timeout -> gate fails
    def test_recovered_then_timeout_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            stalled = lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS)
            retry_stalled = lane_doc(
                "unit-2", cls="BetaTests", status="timeout",
                attempts=[{"mode": "lane", "n": 1, "status": "timeout"},
                          {"mode": "isolation", "status": "incomplete"}])
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(stalled))
            world.recovery(embed(retry_stalled, fresh=True))
            proc = run_gate(world, unit="failure", recovery="failure")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no further attempt", proc.stdout)

    # 7. recovery missing -> gate fails
    def test_recoverable_without_recovery_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            stalled = lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS)
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(stalled))
            proc = run_gate(world, unit="failure", recovery="skipped")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("recovery missing", proc.stdout)

    # 8. recovery result for an unplanned lane -> gate fails
    def test_recovery_for_unplanned_lane_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(lane_doc("unit-2", cls="BetaTests")))
            stray = lane_doc("unit-9", cls="GammaTests")
            world.recovery(embed(stray, fresh=True), artifact_lane="unit-9")
            proc = run_gate(world)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("unplanned lane", proc.stdout)

    def test_recovery_for_lane_that_did_not_need_one(self):
        # A non-pass fresh-runner result attached to a lane that passed (or
        # genuinely failed) is a fence violation.
        with tempfile.TemporaryDirectory() as tmp:
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(lane_doc("unit-2", cls="BetaTests")))
            stray = lane_doc("unit-2", cls="BetaTests", status="timeout",
                             attempts=STALL_ATTEMPTS)
            world.recovery(embed(stray, fresh=True))
            proc = run_gate(world)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("not recovery-eligible", proc.stdout)

    # 9. duplicate recovery result -> gate fails (ambiguous duplicates fail
    #    closed; a sanctioned re-run wins via newest finished_at instead)
    def test_ambiguous_duplicate_recovery_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            stalled = lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS)
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(stalled))
            passed = lane_doc("unit-2", cls="BetaTests")
            contradicted = lane_doc("unit-2", cls="BetaTests", status="fail",
                                    attempts=[{"mode": "lane", "n": 1,
                                               "status": "test-failures"}],
                                    failures=[{"class": "BetaTests",
                                               "test": "testTruth()"}])
            world.recovery(embed(passed, fresh=True), attempt=1)
            world.recovery(embed(contradicted, fresh=True), attempt=2)
            # Same finished_at stamp -> dedupe cannot order them -> conflict.
            proc = run_gate(world, unit="failure", recovery="failure")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("share finished_at", proc.stdout)

    def test_recovery_rerun_newest_attempt_wins(self):
        # The sanctioned "re-run failed jobs" flow: attempt 2 of the recovery
        # leg passed and is newer - it supersedes the failed attempt 1.
        with tempfile.TemporaryDirectory() as tmp:
            stalled = lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS)
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(stalled))
            older = lane_doc("unit-2", cls="BetaTests", status="fail",
                             attempts=[{"mode": "lane", "n": 1,
                                        "status": "test-failures"}],
                             failures=[{"class": "BetaTests",
                                        "test": "testTruth()"}])
            older["finished_at"] = "2026-09-15T10:20:00Z"
            newer = lane_doc("unit-2", cls="BetaTests")
            newer["finished_at"] = "2026-09-15T10:30:00Z"
            world.recovery(embed(older, fresh=True), attempt=1)
            world.recovery(embed(newer, fresh=True), attempt=2)
            proc = run_gate(world, unit="failure", recovery="failure")
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    # 10. malformed/missing original lane-result metadata -> gate fails closed
    def test_missing_lane_artifact_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            world = World(tmp)
            world.primary(embed(lane_doc("unit-1")))
            # unit-2 planned but no artifact at all.
            proc = run_gate(world)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no lane-result artifact", proc.stdout)

    def test_malformed_lane_artifact_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            world = World(tmp)
            world.primary(embed(lane_doc("unit-1")))
            d = world.root / "lanes" / "lane-unit-2-attempt-1" / "unit-2"
            d.mkdir(parents=True)
            (d / "lane-result.json").write_text("{not json", encoding="utf-8")
            proc = run_gate(world)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("unreadable lane result", proc.stdout)

    def test_doc_without_recovery_metadata_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   lane_doc("unit-2", cls="BetaTests"))
            proc = run_gate(world)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no embedded classification", proc.stdout)

    def test_inconsistent_lane_artifact_fails_gate(self):
        # Membership disagreement with the plan fails closed.
        with tempfile.TemporaryDirectory() as tmp:
            world = standard_world(
                tmp, embed(lane_doc("unit-1")),
                embed(lane_doc("unit-2", cls="GammaTests")))
            proc = run_gate(world)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("differs from the plan", proc.stdout)

    def test_tampered_classification_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            doctored = lane_doc("unit-2", cls="BetaTests", status="timeout",
                                attempts=STALL_ATTEMPTS)
            doctored["recovery"] = {"classification": "pass", "reason": "lie",
                                    "eligible": False}
            doctored["fresh_runner_recovery"] = False
            world = standard_world(tmp, embed(lane_doc("unit-1")), doctored)
            proc = run_gate(world)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("re-derived", proc.stdout)

    def test_recovery_disagreeing_with_plan_fails_gate(self):
        # A recovery that executed the wrong membership never satisfies the
        # lane's coverage, even when it passed.
        with tempfile.TemporaryDirectory() as tmp:
            stalled = lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS)
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(stalled))
            wrong = lane_doc("unit-2", cls="GammaTests")
            world.recovery(embed(wrong, fresh=True))
            proc = run_gate(world, unit="failure", recovery="success")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("differs from the plan", proc.stdout)

    def test_recovery_without_embedded_metadata_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            stalled = lane_doc("unit-2", cls="BetaTests", status="timeout",
                               attempts=STALL_ATTEMPTS)
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(stalled))
            bare = lane_doc("unit-2", cls="BetaTests")
            bare["fresh_runner_recovery"] = True  # flag but no recovery block
            world.recovery(bare)
            proc = run_gate(world, unit="failure", recovery="success")
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("no embedded classification", proc.stdout)

    # 12. a fresh-runner retry can never be recovery-eligible again
    def test_fresh_retry_stall_is_nonrecoverable(self):
        stalled = lane_doc("unit-1", status="timeout",
                           attempts=STALL_ATTEMPTS)
        classification, _ = ci_lane_recovery.classify_lane_result(
            embed(stalled, fresh=True))
        self.assertEqual(
            classification,
            ci_lane_recovery.CLASS_NONRECOVERABLE_INFRASTRUCTURE)

    # 15. a recovered run must not be rejected merely because the raw unit
    #     result is failure (coarse checks accept unit == failure)
    def test_unit_failure_with_recovery_success_is_adjudicable(self):
        passed, reason = ci_gate.verdict(
            "success", "success", "failure", "skipped", "success",
            "success", "success", ci_lane_recovery.Adjudication())
        self.assertTrue(passed, reason)

    def test_plan_artifact_missing_fails_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(lane_doc("unit-2", cls="BetaTests")))
            (world.root / "plan" / "plan.json").unlink()
            proc = run_gate(world)
            self.assertNotEqual(proc.returncode, 0)


class VerdictTests(unittest.TestCase):
    """Coarse job-result policy (unchanged semantics where applicable)."""

    @staticmethod
    def ok():
        return ci_lane_recovery.Adjudication()

    def test_all_success_passes(self):
        passed, _ = ci_gate.verdict(
            "success", "success", "success", "success", "success",
            "success", "skipped", self.ok())
        self.assertTrue(passed)

    def test_ui_skipped_passes(self):
        passed, _ = ci_gate.verdict(
            "success", "success", "success", "skipped", "success",
            "success", "skipped", self.ok())
        self.assertTrue(passed)

    def test_ui_cancelled_fails_gate(self):
        passed, reason = ci_gate.verdict(
            "success", "success", "success", "cancelled", "success",
            "success", "skipped", self.ok())
        self.assertFalse(passed)
        self.assertIn("ui", reason)

    def test_build_failure_fails_gate(self):
        passed, _ = ci_gate.verdict(
            "success", "failure", "skipped", "skipped", "skipped",
            "skipped", "skipped", None)
        self.assertFalse(passed)

    def test_plan_failure_fails_gate(self):
        passed, _ = ci_gate.verdict(
            "failure", "skipped", "skipped", "skipped", "skipped",
            "skipped", "skipped", None)
        self.assertFalse(passed)

    def test_plan_cancelled_fails_gate(self):
        passed, _ = ci_gate.verdict(
            "cancelled", "success", "success", "success", "success",
            "success", "skipped", self.ok())
        self.assertFalse(passed)

    def test_unit_cancelled_fails_gate(self):
        passed, reason = ci_gate.verdict(
            "success", "success", "cancelled", "success", "success",
            "success", "skipped", self.ok())
        self.assertFalse(passed)
        self.assertIn("unit", reason)

    def test_unit_skipped_fails_gate(self):
        passed, _ = ci_gate.verdict(
            "success", "success", "skipped", "skipped", "success",
            "success", "skipped", self.ok())
        self.assertFalse(passed)

    def test_self_test_failure_fails_gate(self):
        passed, reason = ci_gate.verdict(
            "success", "success", "success", "success", "failure",
            "success", "skipped", self.ok())
        self.assertFalse(passed)
        self.assertIn("self-test", reason)

    def test_self_test_skipped_fails_gate(self):
        passed, _ = ci_gate.verdict(
            "success", "success", "success", "success", "skipped",
            "success", "skipped", self.ok())
        self.assertFalse(passed)

    def test_recovery_plan_failure_fails_gate(self):
        passed, reason = ci_gate.verdict(
            "success", "success", "success", "success", "success",
            "failure", "skipped", self.ok())
        self.assertFalse(passed)
        self.assertIn("recovery-plan", reason)

    def test_recovery_cancelled_fails_gate(self):
        passed, _ = ci_gate.verdict(
            "success", "success", "failure", "success", "success",
            "success", "cancelled", self.ok())
        self.assertFalse(passed)

    def test_adjudication_failures_fail_gate(self):
        adjudication = ci_lane_recovery.Adjudication()
        adjudication.fail("unit-2: no lane-result artifact found (fail closed)")
        passed, reason = ci_gate.verdict(
            "success", "success", "success", "success", "success",
            "success", "skipped", adjudication)
        self.assertFalse(passed)
        self.assertIn("unit-2", reason)

    def test_missing_adjudication_fails_gate(self):
        passed, reason = ci_gate.verdict(
            "success", "success", "success", "success", "success",
            "success", "skipped", None)
        self.assertFalse(passed)
        self.assertIn("adjudication", reason)


class CliTests(unittest.TestCase):
    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            world = standard_world(tmp, embed(lane_doc("unit-1")),
                                   embed(lane_doc("unit-2", cls="BetaTests")))
            self.assertEqual(run_gate(world).returncode, 0)
            self.assertEqual(run_gate(world, ui="skipped").returncode, 0)
            self.assertNotEqual(run_gate(world, build="failure").returncode, 0)
            self.assertNotEqual(
                run_gate(world, self_test="failure").returncode, 0)
            self.assertNotEqual(run_gate(world, plan="failure").returncode, 0)


if __name__ == "__main__":
    unittest.main()
