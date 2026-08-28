"""Regression coverage for scripts/plan-tests.py (CI v2 planner)."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from _util import SCRIPTS_DIR, default_cfg, load_module, make_repo

planner = load_module("plan_tests", "plan-tests.py")


def plan_from_tree(root, estimates=None, cfg=None):
    discovery = planner.discover_test_classes(str(root))
    return discovery, planner.build_plan(discovery, cfg or default_cfg(), estimates or {})


def errors_from_tree(root, estimates=None, cfg=None):
    discovery, plan = plan_from_tree(root, estimates, cfg)
    return discovery, plan, planner.validate_plan(plan, discovery)


class DiscoveryTests(unittest.TestCase):
    def test_discovers_direct_subclasses_per_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests", "BetaTests"], ["UiOneTests"]))
            discovery = planner.discover_test_classes(str(root))
            self.assertEqual([e["name"] for e in discovery["unit"]], ["AlphaTests", "BetaTests"])
            self.assertEqual([e["name"] for e in discovery["ui"]], ["UiOneTests"])
            self.assertEqual(discovery["errors"], [])

    def test_duplicate_class_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_repo(root, ["AlphaTests"])
            (root / "ConduitTests" / "CopyAlphaTests.swift").write_text(
                "final class AlphaTests: XCTestCase {}\n", encoding="utf-8")
            discovery, _plan = plan_from_tree(root)
            self.assertTrue(any("duplicate" in e for e in discovery["errors"]))

    def test_tests_named_class_without_xctestcase_is_malformed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_repo(root, [], [], extra_files={
                "ConduitTests/BrokenTests.swift":
                    "final class BrokenTests: SomeService {}\n"})
            discovery, _plan = plan_from_tree(root)
            self.assertTrue(any("malformed" in e for e in discovery["errors"]))

    def test_transitive_test_class_is_planned(self):
        content = {
            "ConduitTests/BaseTests.swift":
                "import XCTest\nclass BaseTests: XCTestCase {\n"
                "    func testBaseBehavior() {}\n}\n",
            "ConduitTests/SubTests.swift":
                "final class SubTests: BaseTests {}\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], [], extra_files=content))
            discovery, plan = plan_from_tree(root)
            self.assertEqual(sorted(plan["inventory"]["unit"]), ["BaseTests", "SubTests"])

    def test_helper_mock_is_not_planned(self):
        content = {
            "ConduitTests/Support.swift":
                "import XCTest\nclass TestSupportBase: XCTestCase {}\n"
                "final class MockGateway: TestSupportBase {}\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["RealTests"], [], extra_files=content))
            discovery, plan = plan_from_tree(root)
            # Zero-test XCTestCase subclasses without a Tests suffix (direct or
            # indirect) enumerate zero tests at runtime, so they are helpers,
            # not lanes: -only-testing entries for them would match nothing.
            self.assertEqual(plan["inventory"]["unit"], ["RealTests"])
            self.assertEqual(
                sorted(h["name"] for h in discovery["helpers"]),
                ["MockGateway", "TestSupportBase"])

    def test_directory_decides_target_not_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], ["SomethingTests"]))
            discovery = planner.discover_test_classes(str(root))
            self.assertEqual([e["name"] for e in discovery["ui"]], ["SomethingTests"])
            self.assertEqual(discovery["unit"], [])


class PlanningTests(unittest.TestCase):
    def test_every_unit_class_appears_exactly_once(self):
        names = ["C{0:02d}Tests".format(i) for i in range(40)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, ["UiTests"]))
            _discovery, plan = plan_from_tree(root)
            assigned = [c for lane in plan["unit_lanes"] for c in lane["classes"]]
            self.assertEqual(sorted(assigned), sorted(names))
            self.assertEqual(len(assigned), len(set(assigned)))

    def test_ui_classes_never_enter_unit_lanes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AakesTests"], ["SelectionObserverUITests"]))
            _discovery, plan = plan_from_tree(root)
            for lane in plan["unit_lanes"]:
                self.assertNotIn("SelectionObserverUITests", lane["classes"])
            self.assertEqual(plan["ui_lane"]["classes"], ["SelectionObserverUITests"])

    def test_unknown_timing_entries_do_not_break_planning(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"], []))
            estimates = {"AlphaTests": 5.0, "GhostFromThePastTests": 999.0}
            _discovery, plan = plan_from_tree(root, estimates)
            self.assertNotIn("GhostFromThePastTests", plan["estimates"])
            self.assertEqual(plan["estimates"]["AlphaTests"], 5.0)

    def test_new_class_receives_default_weight(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["BrandNewTests"], []))
            _discovery, plan = plan_from_tree(root, {"AlphaTests": 5.0})
            self.assertEqual(plan["estimates"]["BrandNewTests"], 20.0)

    def test_deleted_classes_are_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AliveTests"], []))
            estimates = {"DeletedTests": 42.0, "AliveTests": 3.0}
            discovery, plan = plan_from_tree(root, estimates)
            self.assertEqual(errors_from_tree(root, estimates)[2], [])
            self.assertNotIn("DeletedTests", plan["inventory"]["unit"])

    def test_deterministic_output(self):
        names = ["D{0:02d}Tests".format(i) for i in range(25)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, ["UiTests"]))
            estimates = {n: 3.0 + (i % 5) for i, n in enumerate(names)}
            _d1, plan1 = plan_from_tree(root, dict(estimates))
            _d2, plan2 = plan_from_tree(root, dict(estimates))
            self.assertEqual(
                json.dumps(plan1, sort_keys=True), json.dumps(plan2, sort_keys=True))

    def test_lpt_balances_loads(self):
        items = sorted([("Heavy10", 10.0), ("Big8", 8.0), ("Mid6", 6.0), ("Small4", 4.0)],
                       key=lambda kv: (-kv[1], kv[0]))
        estimates = dict(items)
        lanes = planner.longest_processing_time_first(items, 2)
        loads = [sum(estimates[name] for name in lane) for lane in lanes]
        self.assertEqual(sorted(loads), [14.0, 14.0])

    def test_lane_count_stays_in_bounds(self):
        tiny = ["T{0}Tests".format(i) for i in range(3)]
        huge = ["H{0:03d}Tests".format(i) for i in range(200)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), tiny, []))
            _d, plan = plan_from_tree(root, {n: 5.0 for n in tiny})
            self.assertLessEqual(plan["lane_count"], 3)  # never more lanes than classes
            root2 = Path(make_repo(Path(tmp) / "huge", huge, []))
            _d2, plan2 = plan_from_tree(root2, {n: 100.0 for n in huge})
            self.assertEqual(plan2["lane_count"], 8)  # saturates at max_lanes

    def test_no_empty_lanes_generated(self):
        names = ["E{0}Tests".format(i) for i in range(9)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, []))
            _d, plan = plan_from_tree(root)
            for lane in plan["unit_lanes"]:
                self.assertTrue(lane["classes"])
            self.assertEqual(len(plan["unit_lanes"]), plan["lane_count"])

    def test_malformed_timing_json_falls_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"], []))
            bad = Path(tmp) / "bad.json"
            bad.write_text("{ not json !!!", encoding="utf-8")
            estimates, warns = planner.load_estimates(str(bad), "history")
            self.assertEqual(estimates, {})
            self.assertTrue(warns)
            _d, plan = plan_from_tree(root, estimates)
            self.assertEqual(plan["estimates"]["AlphaTests"], 20.0)

    def test_no_history_still_generates_valid_plan(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests", "BetaTests"], ["UiTests"]))
            discovery, plan = plan_from_tree(root, {})
            self.assertEqual(planner.validate_plan(plan, discovery), [])

    def test_timeouts_derived_from_prediction(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["SlowTests"], ["UiTests"]))
            estimates = {"SlowTests": 200.0, "UiTests": 60.0}
            _d, plan = plan_from_tree(root, estimates)
            lane = plan["unit_lanes"][0]
            self.assertEqual(lane["predicted_s"], 200.0)
            self.assertEqual(lane["timeout_s"], 600)  # floor wins: max(600, 500)
            self.assertEqual(
                plan["ui_lane"]["timeout_s"], 600)  # floor wins: max(600, 150)

    def test_job_ceiling_covers_worst_in_script_path(self):
        # Ceiling must fit attempt1 + attempt2 + a full isolation pass plus
        # two bounded simulator resets (3*T + margin) - and stay under
        # GitHub's 6-hour hard limit in every configurable case.
        for timeout in (300, 500, 900, 1800):
            cfg = default_cfg()
            ceiling_s = planner.job_timeout_min(timeout, cfg) * 60
            worst_case = 3 * timeout + cfg["job_timeout_margin_s"]
            self.assertGreaterEqual(ceiling_s, worst_case,
                                    f"ceiling too small for T={timeout}")
            self.assertLess(ceiling_s, 6 * 3600)

    def test_lane_count_edges(self):
        cfg = default_cfg()
        self.assertEqual(planner.lane_count_for(0.0, 0, cfg), 0)     # no classes
        self.assertEqual(planner.lane_count_for(20.0, 1, cfg), 1)    # 1 class
        self.assertEqual(planner.lane_count_for(60.0, 3, cfg), 3)    # fewer than min
        self.assertEqual(planner.lane_count_for(2000.0, 9, cfg), 8)  # saturates at max
        self.assertEqual(planner.lane_count_for(961.0, 9, cfg), 5)   # ceil(961/240)=5

    def test_history_wins_over_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"], []))
            baseline = Path(tmp) / "baseline.json"
            baseline.write_text(json.dumps({"classes": {"AlphaTests": 3.0}}), encoding="utf-8")
            history = Path(tmp) / "history.json"
            history.write_text(json.dumps({"classes": {"AlphaTests": 33.0}}), encoding="utf-8")
            discovery = planner.discover_test_classes(str(root))
            a = type("A", (), {"repo_root": str(root), "history": str(history),
                               "baseline": str(baseline)})()
            estimates, _warns, source = planner._load_history_or_baseline(a, discovery)
            self.assertEqual(source, "timing history")
            plan = planner.build_plan(discovery, default_cfg(), estimates)
            self.assertEqual(plan["estimates"]["AlphaTests"], 33.0)


class CliTests(unittest.TestCase):
    def test_validate_cli_passes_on_clean_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"], ["UiTests"]))
            proc = subprocess.run(
                [sys.executable, str(Path(SCRIPTS_DIR) / "plan-tests.py"),
                 "validate", "--repo-root", str(root)],
                capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_validate_cli_fails_on_duplicate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"]))
            (root / "ConduitTests" / "Again.swift").write_text(
                "final class AlphaTests: XCTestCase {}\n", encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(Path(SCRIPTS_DIR) / "plan-tests.py"),
                 "validate", "--repo-root", str(root)],
                capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)

    def test_plan_cli_writes_matrix_and_is_deterministic(self):
        names = ["M{0:02d}Tests".format(i) for i in range(12)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, ["UiTests"]))
            out1 = Path(tmp) / "plan1.json"
            out2 = Path(tmp) / "plan2.json"
            mat1 = Path(tmp) / "matrix1.json"
            mat2 = Path(tmp) / "matrix2.json"
            for out, mat in ((out1, mat1), (out2, mat2)):
                proc = subprocess.run(
                    [sys.executable, str(Path(SCRIPTS_DIR) / "plan-tests.py"),
                     "plan", "--repo-root", str(root), "--out", str(out),
                     "--matrix-out", str(mat)],
                    capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(out1.read_bytes(), out2.read_bytes())
            self.assertEqual(mat1.read_bytes(), mat2.read_bytes())
            matrix = json.loads(mat1.read_text(encoding="utf-8"))
            self.assertIn("include", matrix)
            for entry in matrix["include"]:
                self.assertIn("lane", entry)
                self.assertIn("classes", entry)
                self.assertIn("timeout_s", entry)
                self.assertIn("job_timeout_min", entry)
            # no empty lanes in the matrix either
            self.assertTrue(all(entry["classes"] for entry in matrix["include"]))


class XctestrunAuditTests(unittest.TestCase):
    def _plist(self, tmp, strings):
        import plistlib
        path = Path(tmp) / "test.xctestrun"
        with open(path, "wb") as fh:
            plistlib.dump({"ConduitTests": {"TestHostPath": strings[0],
                                            "TestBundlePath": strings[1]}}, fh)
        return str(path)

    def test_workspace_and_system_paths_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._plist(tmp, [
                "/Users/runner/work/hermes-conduit/hermes-conduit/.ci-derived-data/Build/Products/a.app",
                "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest",
            ])
            violations, checked = planner.audit_xctestrun(path, "/Users/runner/work/hermes-conduit/hermes-conduit")
            self.assertEqual(violations, [])
            self.assertEqual(checked, 2)

    def test_foreign_absolute_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._plist(tmp, [
                "/Users/runner/work/hermes-conduit/hermes-conduit/.ci-derived-data/Build/Products/a.app",
                "/Users/someone/else/private/b.xctest",
            ])
            violations, _checked = planner.audit_xctestrun(
                path, "/Users/runner/work/hermes-conduit/hermes-conduit")
            self.assertEqual(violations, ["/Users/someone/else/private/b.xctest"])


if __name__ == "__main__":
    unittest.main()
