"""Regression coverage for scripts/ci_lane_recovery.py.

Pins the recovery taxonomy (classification table), the artifact scan/dedupe
semantics (attempt suffixes, newest finished_at wins, ambiguity fails
closed), the final unit adjudication, and the timing-history preflight CLI.
The demonstrated stall shape (PR #175) is the anchor case for eligibility.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from _util import SCRIPTS_DIR

spec = importlib.util.spec_from_file_location(
    "ci_lane_recovery", os.path.join(SCRIPTS_DIR, "ci_lane_recovery.py"))
clr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clr)

# The demonstrated stall shape (PR #175 run 34926435961, unit-2, twice).
DEMONSTRATED_STALL = {
    "schema_version": 1,
    "lane": "unit-2",
    "kind": "unit",
    "target": "ConduitTests",
    "classes": ["A"],
    "status": "timeout",
    "attempts": [{"mode": "lane", "n": 1, "status": "timeout"},
                 {"mode": "isolation", "status": "incomplete"}],
    "hung_class": None,
    "isolation": {"budget_s": 932, "classes": [
        {"class": "A", "status": "pass", "seconds": 91.0},
        {"class": "B", "status": "not_diagnosed", "seconds": 0.0}]},
    "simulator_erase": True,
}


def base_doc(**overrides):
    doc = {
        "schema_version": 1,
        "lane": "unit-1",
        "kind": "unit",
        "target": "ConduitTests",
        "classes": ["A"],
        "status": "pass",
        "predicted_s": 10.0,
        "timeout_s": 600,
        "attempts": [{"mode": "lane", "n": 1, "status": "passed"}],
        "hung_class": None,
        "isolation": None,
        "finished_at": "2026-09-15T10:00:00Z",
    }
    doc.update(overrides)
    return doc


class ClassificationTests(unittest.TestCase):
    def test_demonstrated_stall_is_recoverable(self):
        classification, reason = clr.classify_lane_result(DEMONSTRATED_STALL)
        self.assertEqual(
            classification, clr.CLASS_RECOVERABLE_TIMEOUT_ZERO_FAILURES)
        self.assertIn("zero identified test failures", reason)

    def test_stall_with_surviving_extraction_is_recoverable(self):
        doc = base_doc(status="timeout",
                       attempts=[{"mode": "lane", "n": 1, "status": "timeout"},
                                 {"mode": "isolation",
                                  "status": "incomplete"}],
                       failures=[])
        classification, _ = clr.classify_lane_result(doc)
        self.assertEqual(classification,
                         clr.CLASS_RECOVERABLE_TIMEOUT_ZERO_FAILURES)

    def test_isolation_all_passes_recovery_is_plain_pass(self):
        doc = base_doc(status="pass",
                       attempts=[{"mode": "lane", "n": 1, "status": "timeout"},
                                 {"mode": "isolation",
                                  "status": "all-classes-passed"}],
                       isolation={"classes": [{"class": "A",
                                               "status": "pass"}]})
        classification, _ = clr.classify_lane_result(doc)
        self.assertEqual(classification, clr.CLASS_PASS)

    def test_clean_pass(self):
        classification, _ = clr.classify_lane_result(base_doc())
        self.assertEqual(classification, clr.CLASS_PASS)

    def test_identified_failures_are_test_failure(self):
        doc = base_doc(status="fail",
                       attempts=[{"mode": "lane", "n": 1,
                                  "status": "test-failures"}],
                       failures=[{"class": "A", "test": "t()"}])
        classification, reason = clr.classify_lane_result(doc)
        self.assertEqual(classification, clr.CLASS_TEST_FAILURE)
        self.assertIn("1 failing", reason)

    def test_isolation_fail_is_test_failure(self):
        doc = base_doc(status="fail",
                       attempts=[{"mode": "lane", "n": 1, "status": "timeout"},
                                 {"mode": "isolation",
                                  "status": "class-failed"}],
                       isolation={"classes": [{"class": "A",
                                               "status": "fail"}]})
        classification, _ = clr.classify_lane_result(doc)
        self.assertEqual(classification, clr.CLASS_TEST_FAILURE)

    def test_unclassified_failure_is_unclassifiable(self):
        doc = base_doc(status="fail",
                       attempts=[{"mode": "lane", "n": 1,
                                  "status": "unclassified"}])
        classification, _ = clr.classify_lane_result(doc)
        self.assertEqual(classification, clr.CLASS_UNCLASSIFIABLE)

    def test_persistent_infra_error_is_nonrecoverable(self):
        doc = base_doc(status="error",
                       attempts=[{"mode": "lane", "n": 1,
                                  "status": "infra-error"},
                                 {"mode": "lane-retry", "n": 2,
                                  "status": "infra-error"}])
        classification, _ = clr.classify_lane_result(doc)
        self.assertEqual(classification,
                         clr.CLASS_NONRECOVERABLE_INFRASTRUCTURE)

    def test_retry_timeout_without_primary_watchdog_is_nonrecoverable(self):
        doc = base_doc(status="timeout",
                       attempts=[{"mode": "lane", "n": 1,
                                  "status": "infra-error"},
                                 {"mode": "lane-retry", "n": 2,
                                  "status": "timeout"},
                                 {"mode": "isolation",
                                  "status": "incomplete"}])
        classification, reason = clr.classify_lane_result(doc)
        self.assertEqual(classification,
                         clr.CLASS_NONRECOVERABLE_INFRASTRUCTURE)
        self.assertIn("did not hit its watchdog", reason)

    def test_fresh_retry_stall_is_final(self):
        doc = dict(DEMONSTRATED_STALL, fresh_runner_recovery=True)
        classification, reason = clr.classify_lane_result(doc)
        self.assertEqual(classification,
                         clr.CLASS_NONRECOVERABLE_INFRASTRUCTURE)
        self.assertIn("no further attempt", reason)

    def test_pass_with_contradictory_hung_class_is_unclassifiable(self):
        doc = base_doc(hung_class="A")
        classification, _ = clr.classify_lane_result(doc)
        self.assertEqual(classification, clr.CLASS_UNCLASSIFIABLE)

    def test_missing_attempt_chain_is_unclassifiable(self):
        doc = base_doc(attempts=[])
        classification, _ = clr.classify_lane_result(doc)
        self.assertEqual(classification, clr.CLASS_UNCLASSIFIABLE)

    def test_ui_lanes_are_out_of_scope(self):
        doc = base_doc(kind="ui")
        classification, _ = clr.classify_lane_result(doc)
        self.assertIsNone(classification)

    def test_unknown_status_fails_closed(self):
        doc = base_doc(status="mysterious")
        classification, _ = clr.classify_lane_result(doc)
        self.assertEqual(classification, clr.CLASS_UNCLASSIFIABLE)


def write_record(root, artifact_name, inner_lane, doc, filename="lane-result.json"):
    d = Path(root) / artifact_name / inner_lane
    d.mkdir(parents=True, exist_ok=True)
    (d / filename).write_text(json.dumps(doc), encoding="utf-8")
    return d / filename


class ScanDedupeTests(unittest.TestCase):
    def test_artifact_names_parse(self):
        lane, recovery, attempt = clr.parse_artifact_name(
            "lane-unit-2-attempt-3")
        self.assertEqual((lane, recovery, attempt), ("unit-2", False, 3))
        lane, recovery, attempt = clr.parse_artifact_name(
            "lane-recovery-unit-2-attempt-1")
        self.assertEqual((lane, recovery, attempt), ("unit-2", True, 1))
        lane, recovery, attempt = clr.parse_artifact_name("lane-ui-1-attempt-2")
        self.assertEqual((lane, recovery, attempt), ("ui-1", False, 2))
        self.assertIsNone(clr.parse_artifact_name("build-products"))

    def test_scan_and_newest_attempt_wins(self):
        with tempfile.TemporaryDirectory() as tmp:
            older = base_doc(finished_at="2026-09-15T10:00:00Z")
            newer = base_doc(status="pass",
                             finished_at="2026-09-15T10:30:00Z")
            write_record(tmp, "lane-unit-1-attempt-1", "unit-1", older)
            write_record(tmp, "lane-unit-1-attempt-2", "unit-1", newer)
            by_lane, conflicts = clr.dedupe_lane_results(
                clr.scan_lane_results(tmp))
            self.assertEqual(by_lane["unit-1"].doc, newer)
            self.assertEqual(conflicts, [])

    def test_same_stamp_different_docs_is_conflict(self):
        with tempfile.TemporaryDirectory() as tmp:
            a = base_doc()
            b = base_doc(status="fail")
            write_record(tmp, "lane-unit-1-attempt-1", "unit-1", a)
            write_record(tmp, "lane-unit-1-attempt-2", "unit-1", b)
            by_lane, conflicts = clr.dedupe_lane_results(
                clr.scan_lane_results(tmp))
            self.assertEqual(len(conflicts), 1)
            self.assertIn("share finished_at", conflicts[0])

    def test_undated_document_is_conflict(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = base_doc()
            del doc["finished_at"]
            write_record(tmp, "lane-unit-1-attempt-1", "unit-1", doc)
            _by_lane, conflicts = clr.dedupe_lane_results(
                clr.scan_lane_results(tmp))
            self.assertEqual(len(conflicts), 1)
            self.assertIn("finished_at", conflicts[0])


PLAN = {
    "unit_lanes": [
        {"lane": "unit-1", "target": "ConduitTests", "classes": ["A"],
         "predicted_s": 10.0, "timeout_s": 600, "job_timeout_min": 42},
        {"lane": "unit-2", "target": "ConduitTests", "classes": ["B"],
         "predicted_s": 12.0, "timeout_s": 600, "job_timeout_min": 42},
    ],
}


def embed(doc, fresh=False):
    doc["fresh_runner_recovery"] = fresh
    classification, reason = clr.classify_lane_result(doc)
    doc["recovery"] = None if classification is None else {
        "classification": classification, "reason": reason,
        "eligible": (classification in clr.RECOVERY_ELIGIBLE_CLASSES
                     and not fresh)}
    return doc


class AdjudicationTests(unittest.TestCase):
    def test_every_lane_planned_has_disposition(self):
        docs = {"unit-1": clr.LaneResultRecord("p1", "lane-unit-1-attempt-1",
                                               doc=embed(base_doc())),
                "unit-2": clr.LaneResultRecord(
                    "p2", "lane-unit-2-attempt-1",
                    doc=embed(base_doc(lane="unit-2", classes=["B"])))}
        result = clr.adjudicate_unit_lanes(PLAN, docs, {})
        self.assertTrue(result.passed, result.failures)
        self.assertEqual(len(result.dispositions), 2)
        self.assertEqual([d["final"] for d in result.dispositions],
                         [clr.FINAL_PASS, clr.FINAL_PASS])

    def test_multiple_recoverable_lanes_recovered(self):
        r1 = embed(base_doc(status="timeout",
                            attempts=[{"mode": "lane", "n": 1,
                                       "status": "timeout"},
                                      {"mode": "isolation",
                                       "status": "incomplete"}]),
                   fresh=False)
        r2 = embed(base_doc(lane="unit-2", classes=["B"], status="timeout",
                            attempts=[{"mode": "lane", "n": 1,
                                       "status": "timeout"},
                                      {"mode": "isolation",
                                       "status": "incomplete"}]))
        docs = {
            "unit-1": clr.LaneResultRecord("p1", "lane-unit-1-attempt-1", doc=r1),
            "unit-2": clr.LaneResultRecord("p2", "lane-unit-2-attempt-1", doc=r2),
        }
        recovery = {
            "unit-1": [clr.LaneResultRecord(
                "r1", "lane-recovery-unit-1-attempt-1",
                doc=embed(base_doc(), fresh=True))],
            "unit-2": [clr.LaneResultRecord(
                "r2", "lane-recovery-unit-2-attempt-1",
                doc=embed(base_doc(lane="unit-2", classes=["B"]), fresh=True))],
        }
        result = clr.adjudicate_unit_lanes(PLAN, docs, recovery)
        self.assertTrue(result.passed, result.failures)
        self.assertEqual([d["final"] for d in result.dispositions],
                         [clr.FINAL_RECOVERED, clr.FINAL_RECOVERED])


class PreflightCliTests(unittest.TestCase):
    """`ci_lane_recovery.py adjudicate` - the timing-history gate."""

    def run_adjudicate(self, tmp, plan=PLAN, unit_results=(), recovery_results=()):
        root = Path(tmp)
        (root / "plan.json").write_text(json.dumps(plan), encoding="utf-8")
        for artifact, lane, doc in unit_results:
            write_record(root / "lanes", artifact, lane, doc)
        for artifact, lane, doc in recovery_results:
            write_record(root / "recoveries", artifact, lane, doc)
        proc = subprocess.run(
            [sys.executable, os.path.join(SCRIPTS_DIR, "ci_lane_recovery.py"),
             "adjudicate",
             "--plan-json", str(root / "plan.json"),
             "--unit-lanes-dir", str(root / "lanes"),
             "--recovery-lanes-dir", str(root / "recoveries")],
            capture_output=True, text=True)
        return proc

    def test_green_run_adjudicates_green(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = self.run_adjudicate(tmp, unit_results=[
                ("lane-unit-1-attempt-1", "unit-1", embed(base_doc())),
                ("lane-unit-2-attempt-1", "unit-2",
                 embed(base_doc(lane="unit-2", classes=["B"])))])
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("final: PASS", proc.stdout)

    def test_recovered_run_adjudicates_green(self):
        with tempfile.TemporaryDirectory() as tmp:
            stalled = embed(base_doc(lane="unit-2", classes=["B"],
                                     status="timeout",
                                     attempts=[{"mode": "lane", "n": 1,
                                                "status": "timeout"},
                                               {"mode": "isolation",
                                                "status": "incomplete"}]))
            proc = self.run_adjudicate(
                tmp,
                unit_results=[
                    ("lane-unit-1-attempt-1", "unit-1", embed(base_doc())),
                    ("lane-unit-2-attempt-1", "unit-2", stalled)],
                recovery_results=[
                    ("lane-recovery-unit-2-attempt-1", "unit-2",
                     embed(base_doc(lane="unit-2", classes=["B"]),
                           fresh=True))])
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("recovered infrastructure PASS", proc.stdout)

    def test_red_run_refuses_history_update(self):
        with tempfile.TemporaryDirectory() as tmp:
            failing = embed(base_doc(lane="unit-2", classes=["B"],
                                     status="fail",
                                     attempts=[{"mode": "lane", "n": 1,
                                                "status": "test-failures"}],
                                     failures=[{"class": "B",
                                                "test": "t()"}]))
            proc = self.run_adjudicate(tmp, unit_results=[
                ("lane-unit-1-attempt-1", "unit-1", embed(base_doc())),
                ("lane-unit-2-attempt-1", "unit-2", failing)])
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("must not be updated", proc.stdout)

    def test_missing_plan_refuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "lanes").mkdir()
            (root / "recoveries").mkdir()
            proc = subprocess.run(
                [sys.executable,
                 os.path.join(SCRIPTS_DIR, "ci_lane_recovery.py"),
                 "adjudicate",
                 "--plan-json", str(root / "absent.json"),
                 "--unit-lanes-dir", str(root / "lanes"),
                 "--recovery-lanes-dir", str(root / "recoveries")],
                capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
