"""Regression coverage for scripts/extract-test-timings.py."""

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from _util import load_module

ext = load_module("extract_test_timings", "extract-test-timings.py")


def case_node(name, seconds, result="Passed"):
    return {"nodeType": "Test Case", "name": name, "result": result,
            "durationInSeconds": seconds}


def suite_node(name, cases):
    return {"nodeType": "Test Suite", "name": name, "result": "Passed",
            "children": cases}


def bundle_node(name, suites):
    kind = "UI test bundle" if name.endswith("UITests") else "Unit test bundle"
    return {"nodeType": kind, "name": name, "result": "Passed",
            "children": suites}


def doc_of(bundles):
    plan = {"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
            "children": bundles}
    return {"testNodes": [plan]}


def unit_doc(*suites):
    """Document with one ConduitTests bundle containing the given suites."""
    return doc_of([bundle_node("ConduitTests", list(suites))])


class ExtractFromDocTests(unittest.TestCase):
    def test_class_durations_are_summed(self):
        suite = suite_node("AlphaTests", [
            case_node("testOne()", 1.0),
            case_node("testTwo()", 2.5),
        ])
        out = ext.extract_from_doc(unit_doc(suite), "attempt-1.xcresult")
        self.assertEqual(out["classes"], {"AlphaTests": 3.5})
        self.assertEqual(out["counts"]["cases"], 2)

    def test_unit_and_ui_bundles_are_separated_by_node_not_name(self):
        doc = doc_of([
            bundle_node("ConduitTests", [suite_node("AaTests", [case_node("t()", 1.0)])]),
            bundle_node("ConduitUITests", [suite_node("BbUITests", [case_node("t()", 2.0)])]),
        ])
        out = ext.extract_from_doc(doc, "x.xcresult")
        self.assertEqual(sorted(out["bundles"]), ["ConduitTests", "ConduitUITests"])
        self.assertEqual(out["classes"], {"AaTests": 1.0, "BbUITests": 2.0})

    def test_failures_captured(self):
        suite = suite_node("AlphaTests", [
            case_node("testGood()", 0.1),
            case_node("testBad()", 3.0, result="Failed"),
        ])
        out = ext.extract_from_doc(unit_doc(suite), "x.xcresult")
        self.assertEqual(len(out["failures"]), 1)
        self.assertEqual(out["failures"][0]["test"], "testBad()")

    def test_retry_attempts_are_counted_and_flagged_flaky(self):
        # Native -retry-tests-on-failure reruns appear as repeated case nodes.
        suite = suite_node("FlakyTests", [
            case_node("testSometimesFails()", 1.0, result="Failed"),
            case_node("testSometimesFails()", 1.5, result="Passed"),
        ])
        out = ext.extract_from_doc(unit_doc(suite), "x.xcresult")
        attempts = out["attempts"][0]
        self.assertEqual(attempts["attempts_count"], 2)
        self.assertEqual(attempts["final"], "Passed")
        self.assertEqual(len(out["retried"]), 1)
        self.assertEqual(out["failures"], [])  # final result passed

    def test_duration_string_fallback(self):
        node = {"nodeType": "Test Case", "name": "t()", "result": "Passed",
                "duration": "1.25s"}
        suite = suite_node("STests", [node])
        out = ext.extract_from_doc(unit_doc(suite), "x.xcresult")
        self.assertEqual(out["classes"], {"STests": 1.25})

    def test_unknown_intermediate_node_still_descends(self):
        node = {"nodeType": "Mystery Grouping", "name": "?",
                "children": [case_node("t()", 0.5)]}
        suite = suite_node("STests", [node])
        out = ext.extract_from_doc(unit_doc(suite), "x.xcresult")
        self.assertEqual(out["classes"], {"STests": 0.5})

    def test_missing_testnodes_raises_schema_error(self):
        with self.assertRaises(RuntimeError):
            ext.extract_from_doc({"unexpected": {}}, "x.xcresult")

    def test_empty_result_raises(self):
        with self.assertRaises(RuntimeError):
            ext.extract_from_doc(unit_doc(), "x.xcresult")


class LaneResultTests(unittest.TestCase):
    def test_lane_result_assembly(self):
        with tempfile.TemporaryDirectory() as tmp:
            obs = Path(tmp) / "observations.json"
            obs.write_text(json.dumps({"classes": {"AlphaTests": 3.0}}), encoding="utf-8")
            detail = Path(tmp) / "detail.json"
            detail.write_text(json.dumps({
                "failures": [{"test": "AlphaTests/testBad()"}],
                "retried": [{"test": "testBad()", "class": "AlphaTests"}],
            }), encoding="utf-8")
            out = Path(tmp) / "lane-result.json"
            args = SimpleNamespace(
                lane="unit-1", kind="unit", target="ConduitTests",
                classes="AlphaTests,BetaTests", status="fail",
                predicted_s=112.0, timeout_s=300, actual_s=98.5,
                started_at="2026-08-29T00:00:00Z",
                attempts_json='[{"n": 1, "mode": "lane", "status": "test-failures"}]',
                isolation_json="", simulator_reset=True, simulator_erase=False,
                hung_class="", observations=str(obs), detail=str(detail),
                out=str(out))
            rc = ext.lane_result(args)
            self.assertEqual(rc, ext.EXIT_OK)
            doc = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(doc["status"], "fail")
            self.assertEqual(doc["class_seconds"], {"AlphaTests": 3.0})
            self.assertEqual(doc["failures"][0]["test"], "AlphaTests/testBad()")
            self.assertTrue(doc["simulator_reset"])
            self.assertFalse(doc["simulator_erase"])
            self.assertIsNone(doc["hung_class"])


class AggregateTests(unittest.TestCase):
    def _write_plan(self, tmp):
        plan = {
            "unit_lanes": [
                {"lane": "unit-1", "classes": ["AlphaTests"], "predicted_s": 5.0},
                {"lane": "unit-2", "classes": ["BetaTests"], "predicted_s": 5.0},
            ],
            "ui_lane": {"lane": "ui", "classes": ["SelectionObserverUITests"],
                        "predicted_s": 60.0},
        }
        path = Path(tmp) / "plan.json"
        path.write_text(json.dumps(plan), encoding="utf-8")
        return path

    def _write_lane(self, tmp, lane, status, actual, flaky=None, hung=None):
        d = Path(tmp) / lane
        d.mkdir(parents=True, exist_ok=True)
        doc = {"lane": lane, "status": status, "actual_s": actual,
               "predicted_s": 5.0, "timeout_s": 300,
               "started_at": "2026-08-29T10:00:00Z",
               "finished_at": "2026-08-29T10:02:00Z",
               "flaky": flaky or [], "failures": [],
               "class_seconds": {"AlphaTests": 3.0}}
        if hung:
            doc["hung_class"] = hung
            doc["attempts"] = [{"n": 1, "status": "timeout"}]
        (d / "lane-result.json").write_text(json.dumps(doc), encoding="utf-8")

    def test_report_contains_required_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp)
            self._write_lane(tmp, "unit-1", "pass", 4.8)
            self._write_lane(tmp, "unit-2", "pass", 5.2, flaky=[
                {"class": "BetaTests", "test": "testRetry()",
                 "attempts": [{"result": "Failed", "seconds": 0.2},
                              {"result": "Passed", "seconds": 0.3}],
                 "final": "Passed"}])
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result=str(Path(tmp) / "missing.json"),
                                   out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            text = out.read_text(encoding="utf-8")
            for needle in ("CI Test Report", "## Build", "## Unit lanes",
                           "unit-1", "Predicted lane imbalance",
                           "FLAKE WARNING", "Slowest test classes"):
                self.assertIn(needle, text)

    def test_hang_is_reported_prominently(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp)
            self._write_lane(tmp, "unit-1", "pass", 4.8)
            self._write_lane(tmp, "unit-2", "timeout", 300.0, hung="BetaTests")
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result="", out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            text = out.read_text(encoding="utf-8")
            self.assertIn("HANG identified by isolation mode", text)
            self.assertIn("BetaTests", text)

    def test_report_is_tolerant_to_missing_lane_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp)
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result="", out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            text = out.read_text(encoding="utf-8")
            self.assertIn("no result", text)


if __name__ == "__main__":
    unittest.main()
