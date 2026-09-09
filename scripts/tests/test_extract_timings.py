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

    def test_nested_suites_attribute_to_nearest_suite(self):
        inner = {"nodeType": "Test Suite", "name": "InnerSuite", "result": "Passed",
                 "children": [case_node("t()", 0.5)]}
        outer = {"nodeType": "Test Suite", "name": "OuterSuite", "result": "Passed",
                 "children": [case_node("t2()", 1.0), inner]}
        out = ext.extract_from_doc(unit_doc(outer), "x.xcresult")
        # nearest enclosing suite wins: t2 -> OuterSuite, t -> InnerSuite
        self.assertEqual(out["classes"], {"OuterSuite": 1.0, "InnerSuite": 0.5})

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
            obs.write_text(json.dumps({
                "schema_version": 1, "classes": {"AlphaTests": 3.0},
            }), encoding="utf-8")
            detail = Path(tmp) / "detail.json"
            detail.write_text(json.dumps({
                "schema_version": 1,
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
                hung_class="", retried_classes="", observations=str(obs),
                detail=str(detail), out=str(out))
            rc = ext.lane_result(args)
            self.assertEqual(rc, ext.EXIT_OK)
            doc = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(doc["status"], "fail")
            self.assertEqual(doc["class_seconds"], {"AlphaTests": 3.0})
            self.assertEqual(doc["failures"][0]["test"], "AlphaTests/testBad()")
            self.assertTrue(doc["simulator_reset"])
            self.assertFalse(doc["simulator_erase"])
            self.assertIsNone(doc["hung_class"])
            self.assertEqual(doc["retried_classes"], [])

    def test_lane_result_records_runner_level_retried_classes(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "lane-result.json"
            args = SimpleNamespace(
                lane="ui-2", kind="ui", target="ConduitUITests",
                classes="AlphaUITests,BetaUITests", status="pass",
                predicted_s=120.0, timeout_s=900, actual_s=150.0,
                started_at="2026-09-08T00:00:00Z",
                attempts_json='[{"n": 1, "mode": "class", "class": "AlphaUITests", "status": "passed"},'
                              ' {"n": 1, "mode": "class", "class": "BetaUITests", "status": "test-failures"},'
                              ' {"n": 2, "mode": "class-retry", "class": "BetaUITests", "status": "passed"}]',
                isolation_json="", simulator_reset=False, simulator_erase=False,
                hung_class="", retried_classes="BetaUITests",
                observations="", detail="", out=str(out))
            rc = ext.lane_result(args)
            self.assertEqual(rc, ext.EXIT_OK)
            doc = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(doc["retried_classes"], ["BetaUITests"])
            self.assertEqual([a["status"] for a in doc["attempts"]],
                             ["passed", "test-failures", "passed"])


class MergePartsTests(unittest.TestCase):
    def _write_part(self, parts, name, doc):
        path = parts / name
        path.write_text(json.dumps(doc), encoding="utf-8")

    def _observation(self, classes, bundles=None, cases=1):
        return {"schema_version": 1, "generated_at": "2026-09-08T00:00:00Z",
                "xcresult": "x.xcresult", "bundles": bundles or ["ConduitUITests"],
                "classes": classes, "counts": {"classes": len(classes), "cases": cases}}

    def test_merge_parts_last_attempt_wins_per_class(self):
        with tempfile.TemporaryDirectory() as tmp:
            parts = Path(tmp) / "parts"
            parts.mkdir()
            self._write_part(parts, "observations-AlphaUITests-a1.json",
                             self._observation({"AlphaUITests": 30.0}))
            self._write_part(parts, "observations-AlphaUITests-a2.json",
                             self._observation({"AlphaUITests": 41.0}))
            self._write_part(parts, "observations-BetaUITests-a1.json",
                             self._observation({"BetaUITests": 12.0}))
            obs_out = Path(tmp) / "observations.json"
            det_out = Path(tmp) / "detail.json"
            rc = ext.merge_parts(str(parts), str(obs_out), str(det_out))
            self.assertEqual(rc, ext.EXIT_OK)
            obs = json.loads(obs_out.read_text(encoding="utf-8"))
            # the retried class keeps its PASSING (last) attempt's duration
            self.assertEqual(obs["classes"], {"AlphaUITests": 41.0, "BetaUITests": 12.0})

    def test_merge_parts_folds_details_across_classes(self):
        with tempfile.TemporaryDirectory() as tmp:
            parts = Path(tmp) / "parts"
            parts.mkdir()
            self._write_part(parts, "detail-AlphaUITests-a1.json", {
                "schema_version": 1, "generated_at": "t", "xcresult": "a1",
                "attempts": [{"class": "AlphaUITests", "test": "testA()",
                              "attempts": [{"result": "Failed", "seconds": 1.0}],
                              "final": "Failed", "attempts_count": 1}],
                "failures": [{"class": "AlphaUITests", "test": "testA()"}],
                "retried": [],
            })
            self._write_part(parts, "detail-BetaUITests-a1.json", {
                "schema_version": 1, "generated_at": "t", "xcresult": "b1",
                "attempts": [{"class": "BetaUITests", "test": "testB()",
                              "attempts": [{"result": "Passed", "seconds": 2.0}],
                              "final": "Passed", "attempts_count": 1}],
                "failures": [],
                "retried": [],
            })
            det_out = Path(tmp) / "detail.json"
            rc = ext.merge_parts(str(parts), "", str(det_out))
            self.assertEqual(rc, ext.EXIT_OK)
            det = json.loads(det_out.read_text(encoding="utf-8"))
            self.assertEqual(len(det["attempts"]), 2)
            self.assertEqual(len(det["failures"]), 1)
            self.assertEqual([a["class"] for a in det["attempts"]],
                             ["AlphaUITests", "BetaUITests"])

    def test_merge_parts_orders_attempts_numerically(self):
        # a10 must sort after a2, not before (lexicographic trap).
        with tempfile.TemporaryDirectory() as tmp:
            parts = Path(tmp) / "parts"
            parts.mkdir()
            self._write_part(parts, "observations-GammaUITests-a2.json",
                             self._observation({"GammaUITests": 22.0}))
            self._write_part(parts, "observations-GammaUITests-a10.json",
                             self._observation({"GammaUITests": 99.0}))
            obs_out = Path(tmp) / "observations.json"
            self.assertEqual(ext.merge_parts(str(parts), str(obs_out), ""), ext.EXIT_OK)
            obs = json.loads(obs_out.read_text(encoding="utf-8"))
            self.assertEqual(obs["classes"]["GammaUITests"], 99.0)

    def test_merge_parts_ignores_corrupt_parts(self):
        with tempfile.TemporaryDirectory() as tmp:
            parts = Path(tmp) / "parts"
            parts.mkdir()
            (parts / "observations-BadUITests-a1.json").write_text(
                "{ not json", encoding="utf-8")
            self._write_part(parts, "observations-GoodUITests-a1.json",
                             self._observation({"GoodUITests": 5.0}))
            obs_out = Path(tmp) / "observations.json"
            self.assertEqual(ext.merge_parts(str(parts), str(obs_out), ""), ext.EXIT_OK)
            obs = json.loads(obs_out.read_text(encoding="utf-8"))
            self.assertEqual(obs["classes"], {"GoodUITests": 5.0})

    def test_merge_parts_without_parts_reports_schema_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            parts = Path(tmp) / "parts"
            parts.mkdir()
            self.assertEqual(
                ext.merge_parts(str(parts), "", ""), ext.EXIT_SCHEMA)
            self.assertEqual(
                ext.merge_parts(str(Path(tmp) / "missing"), "", ""), ext.EXIT_SCHEMA)


class AggregateTests(unittest.TestCase):
    def _write_plan(self, tmp, ui_plan=None):
        plan = {
            "unit_lanes": [
                {"lane": "unit-1", "classes": ["AlphaTests"], "predicted_s": 5.0},
                {"lane": "unit-2", "classes": ["BetaTests"], "predicted_s": 5.0},
            ],
        }
        if ui_plan is None:
            ui_plan = {"ui_lanes": [
                {"lane": "ui-1", "classes": ["SelectionObserverUITests"],
                 "predicted_s": 60.0},
                {"lane": "ui-2", "classes": ["LoginKeyboardUITests"],
                 "predicted_s": 30.0},
            ]}
        plan.update(ui_plan)
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

    def test_lane_result_ignores_corrupt_side_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            obs = Path(tmp) / "observations.json"
            obs.write_text("{ not json", encoding="utf-8")
            detail = Path(tmp) / "detail.json"
            detail.write_text('{"schema_version": 1, "failures": [], "retried": []}', encoding="utf-8")
            out = Path(tmp) / "lane-result.json"
            args = SimpleNamespace(
                lane="unit-1", kind="unit", target="ConduitTests",
                classes="AlphaTests", status="pass",
                predicted_s=5.0, timeout_s=300, actual_s=4.0,
                started_at="2026-08-29T00:00:00Z",
                attempts_json="[not valid json",
                isolation_json="", simulator_reset=False,
                simulator_erase=False, hung_class="", retried_classes="",
                observations=str(obs), detail=str(detail), out=str(out))
            rc = ext.lane_result(args)
            self.assertEqual(rc, ext.EXIT_OK)
            doc = json.loads(out.read_text(encoding="utf-8"))
            self.assertNotIn("class_seconds", doc)  # corrupt side file ignored
            self.assertEqual(doc["attempts"], [])   # malformed attempts ignored
            self.assertEqual(doc["status"], "pass")

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

    def test_report_tolerates_malformed_timestamps(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp)
            d = Path(tmp) / "unit-1"
            d.mkdir(parents=True)
            doc = {"lane": "unit-1", "status": "pass", "actual_s": 4.0,
                   "predicted_s": 5.0, "started_at": "not-a-timestamp",
                   "finished_at": "also-bad", "flaky": [], "failures": [],
                   "class_seconds": {}}
            (d / "lane-result.json").write_text(json.dumps(doc), encoding="utf-8")
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result="", out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            self.assertNotIn("Overall wall clock", out.read_text(encoding="utf-8"))

    def test_report_tolerates_mixed_null_actual_durations(self):
        # A lane result without a measured duration (actual_s: null) must not
        # crash the imbalance math and must be reported as incomplete.
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp)
            d1 = Path(tmp) / "unit-1"
            d1.mkdir(parents=True, exist_ok=True)
            doc1 = {"lane": "unit-1", "status": "pass", "actual_s": 4.0,
                    "predicted_s": 5.0, "started_at": "2026-08-29T10:00:00Z",
                    "finished_at": "2026-08-29T10:02:00Z",
                    "flaky": [], "failures": [], "class_seconds": {}}
            (d1 / "lane-result.json").write_text(json.dumps(doc1), encoding="utf-8")
            d2 = Path(tmp) / "unit-2"
            d2.mkdir(parents=True, exist_ok=True)
            doc2 = {"lane": "unit-2", "status": "pass", "actual_s": None,
                    "predicted_s": 5.0, "started_at": "2026-08-29T10:00:00Z",
                    "finished_at": "2026-08-29T10:02:00Z",
                    "flaky": [], "failures": [], "class_seconds": {}}
            (d2 / "lane-result.json").write_text(json.dumps(doc2), encoding="utf-8")
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result="", out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            text = out.read_text(encoding="utf-8")
            self.assertIn("incomplete", text)

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
            self.assertIn("ui-1", text)
            self.assertIn("ui-2", text)

    def test_report_renders_parallel_ui_lanes(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp)
            self._write_lane(tmp, "ui-1", "pass", 70.0)
            self._write_lane(tmp, "ui-2", "pass", 33.0)
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result="", out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            text = out.read_text(encoding="utf-8")
            self.assertIn("per-class watchdog", text)
            self.assertIn("a retry applies only to the failed class", text)

    def test_report_falls_back_to_legacy_ui_lane_shape(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp, ui_plan={
                "ui_lane": {"lane": "ui", "classes": ["OldUITests"],
                            "predicted_s": 60.0}})
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result="", out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            self.assertIn("| ui |", out.read_text(encoding="utf-8"))

    def test_report_flags_runner_level_retried_class(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp)
            self._write_lane(tmp, "ui-1", "pass", 70.0)
            d = Path(tmp) / "ui-2"
            d.mkdir(parents=True, exist_ok=True)
            doc = {"lane": "ui-2", "status": "pass", "actual_s": 45.0,
                   "predicted_s": 30.0, "timeout_s": 420,
                   "started_at": "2026-08-29T10:00:00Z",
                   "finished_at": "2026-08-29T10:02:00Z",
                   "flaky": [], "failures": [], "class_seconds": {},
                   "retried_classes": ["LoginKeyboardUITests"],
                   "attempts": [
                       {"n": 1, "mode": "class", "class": "LoginKeyboardUITests",
                        "status": "test-failures"},
                       {"n": 2, "mode": "class-retry", "class": "LoginKeyboardUITests",
                        "status": "passed"}]}
            (d / "lane-result.json").write_text(json.dumps(doc), encoding="utf-8")
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result="", out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            text = out.read_text(encoding="utf-8")
            self.assertIn("LoginKeyboardUITests", text)
            self.assertIn("PASSED on the targeted retry", text)
            self.assertIn("FLAKE WARNING", text)

    def test_report_lists_not_diagnosed_ui_classes(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = self._write_plan(tmp)
            self._write_lane(tmp, "ui-1", "pass", 70.0)
            d = Path(tmp) / "ui-2"
            d.mkdir(parents=True, exist_ok=True)
            doc = {"lane": "ui-2", "status": "timeout", "actual_s": 400.0,
                   "predicted_s": 30.0, "timeout_s": 420,
                   "started_at": "2026-08-29T10:00:00Z",
                   "finished_at": "2026-08-29T10:08:00Z",
                   "flaky": [], "failures": [], "class_seconds": {},
                   "retried_classes": [], "hung_class": "LoginKeyboardUITests",
                   "attempts": [
                       {"n": 1, "mode": "class", "class": "LoginKeyboardUITests",
                        "status": "timeout"},
                       {"n": 2, "mode": "class-retry", "class": "LoginKeyboardUITests",
                        "status": "timeout"},
                       {"n": 0, "mode": "skipped", "class": "SelectionObserverUITests",
                        "status": "not_diagnosed"}]}
            (d / "lane-result.json").write_text(json.dumps(doc), encoding="utf-8")
            out = Path(tmp) / "summary.md"
            args = SimpleNamespace(plan=str(plan), lanes_dir=str(tmp),
                                   build_result="", out=str(out))
            rc = ext.aggregate(args)
            self.assertEqual(rc, ext.EXIT_OK)
            text = out.read_text(encoding="utf-8")
            self.assertIn("HANG identified", text)
            self.assertIn("not_diagnosed", text)


if __name__ == "__main__":
    unittest.main()
