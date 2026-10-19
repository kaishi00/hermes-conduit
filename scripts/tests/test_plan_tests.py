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
            ui_assigned = [c for lane in plan["ui_lanes"] for c in lane["classes"]]
            self.assertEqual(ui_assigned, ["SelectionObserverUITests"])

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

    def test_non_finite_timing_entries_are_ignored(self):
        # nan survives a naive "secs <= 0" check and would poison every
        # ceil()/comparison in the planner; inf does the same.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"], []))
            bad = Path(tmp) / "bad.json"
            bad.write_text(
                json.dumps({"classes": {"AlphaTests": float("nan"),
                                        "BetaTests": float("inf")}}),
                encoding="utf-8")
            estimates, warns = planner.load_estimates(str(bad), "history")
            self.assertEqual(estimates, {})
            self.assertEqual(len(warns), 2)

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
            # One class -> one execution batch; the batch watchdog prices the
            # modeled invocation overhead + execution with lane headroom:
            # max(600, ceil((240 + 200) x 2.5)) = 1100. The lane watchdog is
            # the sum of its batch budgets.
            self.assertEqual(lane["predicted_s"], 200.0)
            self.assertEqual(lane["timeout_s"], 1100)
            # UI class watchdog: floor wins for a small class
            # (max(420, ceil(60 x 3)) = 420).
            ui_lane = plan["ui_lanes"][0]
            self.assertEqual(ui_lane["class_timeouts"], "UiTests=420")

    def test_ui_class_timeout_floor_and_multiplier(self):
        cfg = default_cfg()
        # Small class: the floor carries the fixed per-invocation simulator
        # overhead and wins over the estimate-based term.
        self.assertEqual(
            planner.ui_class_timeout_for(60.0, cfg["ui_class_timeout_min_s"],
                                         cfg["ui_class_timeout_multiplier"]),
            420)
        # Big class: 3x the estimate with proportional headroom; today's
        # slowest UI class (~333s) must be caught in well under 20 minutes.
        self.assertEqual(
            planner.ui_class_timeout_for(333.0, cfg["ui_class_timeout_min_s"],
                                         cfg["ui_class_timeout_multiplier"]),
            999)
        # Fractional estimates round up, never down.
        self.assertEqual(
            planner.ui_class_timeout_for(140.1, cfg["ui_class_timeout_min_s"],
                                         cfg["ui_class_timeout_multiplier"]),
            421)

    def test_job_ceiling_covers_worst_in_script_path(self):
        # Ceiling must fit the worst in-script path - EVERY batch burning its
        # budget twice (attempt 1 plus its single batch-level retry), each
        # retry paying one bounded erase-path recovery, every attempt's
        # extraction wedging to the xcresulttool bound - plus the setup
        # margin, and stay under GitHub's 6-hour hard limit for realistic
        # batch vectors.
        cfg = default_cfg()
        for budgets in ([600], [800, 800], [1100, 2625, 900], [600] * 6):
            batches = [{"timeout_s": b} for b in budgets]
            n = len(batches)
            ceiling_s = planner.unit_job_timeout_min(batches, cfg) * 60
            worst_case = (2 * sum(budgets)
                          + n * cfg["unit_batch_recovery_overhead_s"]
                          + (2 * n + 1) * cfg["ui_extract_bound_s"]
                          + cfg["job_timeout_margin_s"])
            self.assertGreaterEqual(ceiling_s, worst_case,
                                    f"ceiling too small for budgets={budgets}")
            self.assertLess(ceiling_s, 6 * 3600)

    def test_lane_count_edges(self):
        cfg = default_cfg()
        self.assertEqual(planner.lane_count_for([], cfg), 0)      # no classes
        self.assertEqual(planner.lane_count_for([("ATests", 20.0)], cfg), 1)
        # Three 20s classes: 60s of execution cannot justify a second
        # 240s invocation, so the model consolidates to one lane.
        tiny = [("ATests", 20.0), ("BTests", 20.0), ("CTests", 20.0)]
        self.assertEqual(planner.lane_count_for(tiny, cfg), 1)
        # A heavy outlier dominates every possible split: no extra lane can
        # shorten the wall clock, so the model consolidates to one lane.
        outlier = [("HostedTests", 2000.0), ("BTests", 30.0), ("CTests", 30.0)]
        self.assertEqual(planner.lane_count_for(outlier, cfg), 1)
        # Evenly huge classes keep scaling out to the configured max: every
        # added lane removes ~900s of wall clock.
        huge = [("H{0}Tests".format(i), 900.0) for i in range(8)]
        self.assertEqual(planner.lane_count_for(huge, cfg), cfg["max_lanes"])
        # 4 x 100s: modeled walls are 640/440/373/340 - lanes 3 and 4 each
        # buy less than the 120s tolerance, so the suite lands on 2 lanes.
        even = [("E{0}Tests".format(i), 100.0) for i in range(4)]
        self.assertEqual(planner.lane_count_for(even, cfg), 2)

    def test_modeled_wall_includes_invocation_overhead(self):
        # The plan must carry the modeled wall (overhead + predicted) so the
        # report shows what a lane actually costs, not just its test time.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"], []))
            _d, plan = plan_from_tree(root, {"AlphaTests": 100.0})
            cfg = default_cfg()
            lane = plan["unit_lanes"][0]
            self.assertEqual(
                lane["modeled_wall_s"],
                cfg["invocation_overhead_s"] + 100.0)

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


class UnitBatchingTests(unittest.TestCase):
    """The sequential-xcodebuild batch partition: deterministic mechanical
    chunking of each lane's class order at 7 classes, with per-batch budgets.
    These pin the exact invariants the runner's fail-closed validation and
    the batch-level recovery rely on."""

    def _batches(self, names, estimates=None, cfg=None):
        cfg = cfg or default_cfg()
        est = {n: (estimates or {}).get(n, 10.0) for n in names}
        return planner.unit_batches_for(names, est, cfg)

    def test_zero_classes_produce_no_batches(self):
        self.assertEqual(self._batches([]), [])

    def test_one_to_seven_classes_form_one_batch(self):
        for n in (1, 4, 7):
            names = ["A{0}Tests".format(i) for i in range(n)]
            batches = self._batches(names)
            self.assertEqual(len(batches), 1)
            self.assertEqual(batches[0]["classes"], names)

    def test_eight_classes_chunk_seven_plus_one(self):
        names = ["C{0}Tests".format(i) for i in range(8)]
        batches = self._batches(names)
        self.assertEqual([b["classes"] for b in batches],
                         [names[:7], names[7:]])

    def test_fourteen_classes_chunk_seven_plus_seven(self):
        names = ["D{0}Tests".format(i) for i in range(14)]
        batches = self._batches(names)
        self.assertEqual([b["classes"] for b in batches],
                         [names[:7], names[7:]])

    def test_fifteen_classes_chunk_seven_seven_one(self):
        names = ["E{0}Tests".format(i) for i in range(15)]
        batches = self._batches(names)
        self.assertEqual([b["classes"] for b in batches],
                         [names[:7], names[7:14], names[14:]])

    def test_batches_concatenate_to_exact_lane_order(self):
        # The runner replays -only-testing filters from these batches; any
        # reordering/duplication would desync coverage from the plan.
        names = ["F{0:02d}Tests".format(i) for i in range(37)]
        batches = self._batches(names)
        self.assertEqual([c for b in batches for c in b["classes"]], names)

    def test_no_duplicates_or_omissions_across_batches(self):
        names = ["G{0:02d}Tests".format(i) for i in range(23)]
        batches = self._batches(names)
        flattened = [c for b in batches for c in b["classes"]]
        self.assertEqual(len(flattened), len(set(flattened)))
        self.assertEqual(sorted(flattened), sorted(names))

    def test_every_batch_respects_the_cap(self):
        names = ["H{0:02d}Tests".format(i) for i in range(50)]
        cfg = default_cfg()
        batches = self._batches(names, cfg=cfg)
        for b in batches:
            self.assertGreaterEqual(len(b["classes"]), 1)
            self.assertLessEqual(len(b["classes"]),
                                 cfg["unit_batch_max_classes"])

    def test_batch_budgets_are_floored_overhead_inclusive_ints(self):
        # max_classes=1 forces one batch per class so each budget is checked
        # in isolation: ceil((240 + 1) x 2.5) = 603 clears the 600s floor;
        # the big batch is pure overhead-inclusive headroom:
        # ceil((240 + 300) x 2.5) = 1350.
        cfg = default_cfg(unit_batch_max_classes=1, unit_batch_timeout_min_s=600)
        est = {"BigTests": 300.0, "SmallTests": 1.0}
        batches = planner.unit_batches_for(["SmallTests", "BigTests"], est, cfg)
        self.assertEqual(batches[0]["timeout_s"], 603)
        self.assertEqual(batches[1]["timeout_s"], 1350)
        for b in batches:
            self.assertIsInstance(b["timeout_s"], int)
            self.assertGreater(b["timeout_s"], 0)

    def test_lane_timeout_is_the_sum_of_batch_budgets(self):
        names = ["I{0}Tests".format(i) for i in range(8)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, []))
            _d, plan = plan_from_tree(root, {n: 10.0 for n in names})
            lane = plan["unit_lanes"][0]
            self.assertEqual(lane["batch_count"], 2)
            self.assertEqual(
                lane["timeout_s"],
                sum(b["timeout_s"] for b in lane["batches"]))
            self.assertEqual(
                lane["job_timeout_min"],
                planner.unit_job_timeout_min(lane["batches"], default_cfg()))

    def test_validate_rejects_batch_invariant_violations(self):
        names = ["J{0}Tests".format(i) for i in range(8)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, []))
            discovery, plan = plan_from_tree(root, {n: 10.0 for n in names})
            self.assertEqual(planner.validate_plan(plan, discovery), [])

            def errors_with(mutate):
                import copy
                broken = copy.deepcopy(plan)
                mutate(broken["unit_lanes"][0])
                return planner.validate_plan(broken, discovery)

            # duplicated class across batches
            def duplicate(lane):
                lane["batches"][1]["classes"].append(lane["batches"][0]["classes"][0])
            self.assertTrue(any("reproduce" in e for e in errors_with(duplicate)))

            # omitted class
            def omit(lane):
                lane["batches"][0]["classes"].pop()
            self.assertTrue(any("reproduce" in e for e in errors_with(omit)))

            # batch over the cap
            def oversize(lane):
                lane["batches"][0]["classes"].extend(
                    lane["batches"][1]["classes"])
                lane["batches"].pop()
                lane["batch_count"] = 1
            self.assertTrue(any("cap" in e for e in errors_with(oversize)))

            # non-positive batch watchdog
            def bad_budget(lane):
                lane["batches"][0]["timeout_s"] = 0
            self.assertTrue(any("watchdog" in e for e in errors_with(bad_budget)))

            # batches removed entirely
            def no_batches(lane):
                lane["batches"] = []
            self.assertTrue(any("no execution batches" in e
                                for e in errors_with(no_batches)))

    def test_unit_matrix_carries_batches_as_compact_json(self):
        names = ["K{0}Tests".format(i) for i in range(9)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, []))
            _d, plan = plan_from_tree(root, {n: 10.0 for n in names})
            matrix = json.loads(planner.matrix_json(plan))
            entry = matrix["include"][0]
            self.assertEqual(entry["batch_count"], 2)
            batches = json.loads(entry["batches"])
            self.assertEqual([b["classes"] for b in batches],
                             [lane_b["classes"] for lane_b in
                              plan["unit_lanes"][0]["batches"]])
            self.assertTrue(all(isinstance(b["timeout_s"], int)
                                for b in batches))
            # GitHub matrix values must be scalars: the field is a STRING.
            self.assertIsInstance(entry["batches"], str)


class UnitBatchParallelismTests(unittest.TestCase):
    """The per-job batch policy: a unit lane may chain at most
    unit_max_batches_per_job sequential xcodebuild batches. Timing-aware
    lane selection stays authoritative, but the ACTUAL LPT assignment is
    verified against the policy and the lane count is incremented (never
    lowered) until it satisfies it."""

    def _plan(self, names, estimates=None, cfg=None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, []))
            est = {n: (estimates or {}).get(n, 10.0) for n in names}
            discovery, plan = plan_from_tree(root, est, cfg)
            return discovery, plan, planner.validate_plan(plan, discovery)

    def test_small_inventory_stays_one_lane(self):
        # 10 classes of ~10s: timing consolidation AND the batch floor
        # both say one lane.
        names = ['A{0}Tests'.format(i) for i in range(10)]
        discovery, plan, errors = self._plan(names)
        self.assertEqual(plan['lane_count'], 1)
        self.assertEqual(plan['unit_lanes'][0]['batch_count'], 2)
        self.assertEqual(errors, [])

    def test_twenty_eight_classes_fit_one_four_batch_job(self):
        # Tiny estimates keep the timing model on one lane; the policy only
        # needs to allow (not force) the 4-batch job.
        names = ['B{0:02d}Tests'.format(i) for i in range(28)]
        discovery, plan, errors = self._plan(
            names, {n: 3.0 for n in names})
        self.assertEqual(plan['lane_count'], 1)
        lane = plan['unit_lanes'][0]
        self.assertEqual(lane['batch_count'], 4)
        self.assertEqual([len(b['classes']) for b in lane['batches']],
                         [7, 7, 7, 7])
        self.assertEqual(errors, [])

    def test_twenty_nine_classes_need_a_second_job(self):
        # Off-by-one pin at the 7x4 boundary: 29 classes can never fit one
        # 4-batch job. (Timing alone also picks 2 lanes here, so this also
        # pins that the floor never OVER-splits a small inventory.)
        names = ['C{0:02d}Tests'.format(i) for i in range(29)]
        discovery, plan, errors = self._plan(names)
        self.assertGreaterEqual(plan['lane_count'], 2)
        for lane in plan['unit_lanes']:
            self.assertLessEqual(lane['batch_count'], 4)
        self.assertEqual(errors, [])

    def test_large_inventory_gives_every_lane_at_most_four_batches(self):
        # Real-suite scale: the floor alone demands >= 5 jobs; skewed real
        # estimates may require more - whatever it takes, every lane must
        # satisfy the policy.
        names = ['D{0:03d}Tests'.format(i) for i in range(132)]
        estimates = {n: 5.0 + (i * 7 % 40) for i, n in enumerate(names)}
        estimates[names[0]] = 400.0   # one heavy outlier, like the real suite
        discovery, plan, errors = self._plan(names, estimates)
        self.assertGreaterEqual(plan['lane_count'], 5)
        for lane in plan['unit_lanes']:
            self.assertLessEqual(lane['batch_count'], 4)
            self.assertGreaterEqual(lane['batch_count'], 1)
        self.assertEqual(errors, [])

    def test_timing_logic_can_still_exceed_the_batch_floor(self):
        # Heavy estimates make the wall-clock model demand the lane
        # maximum; the batch floor (2 lanes for 40 classes) must never
        # LOWER that.
        names = ['E{0:02d}Tests'.format(i) for i in range(40)]
        discovery, plan, errors = self._plan(
            names, {n: 900.0 for n in names})
        self.assertEqual(plan['lane_count'], 8)
        self.assertEqual(errors, [])

    def test_skewed_estimates_are_rebalanced_until_assignment_fits(self):
        # 2 huge classes + 60 tiny ones: at the naive floor (3 lanes) LPT
        # pours ALL tiny classes onto one empty lane (61 classes -> 9
        # batches), and at 4 lanes still 30/30 (5 batches). Only at 5
        # lanes does the ACTUAL assignment satisfy the policy - proving
        # the loop verifies the real assignment instead of trusting
        # ceil(N/28).
        names = (['Fhuge1Tests', 'Fhuge2Tests']
                 + ['Ftiny{0:02d}Tests'.format(i) for i in range(60)])
        estimates = {'Fhuge1Tests': 9000.0, 'Fhuge2Tests': 10000.0}
        estimates.update({n: 1.0 for n in names if n.startswith('Ftiny')})
        discovery, plan, errors = self._plan(names, estimates)
        self.assertEqual(plan['lane_count'], 5)
        for lane in plan['unit_lanes']:
            self.assertLessEqual(lane['batch_count'], 4)
        self.assertEqual(errors, [])

    def test_coverage_exactly_once_under_the_batch_policy(self):
        names = ['G{0:03d}Tests'.format(i) for i in range(100)]
        estimates = {n: 3.0 + (i % 11) for i, n in enumerate(names)}
        discovery, plan, errors = self._plan(names, estimates)
        assigned = [c for lane in plan['unit_lanes'] for c in lane['classes']]
        self.assertEqual(sorted(assigned), sorted(names))
        self.assertEqual(len(assigned), len(set(assigned)))

    def test_no_duplicate_classes_across_lanes(self):
        names = ['H{0:03d}Tests'.format(i) for i in range(80)]
        discovery, plan, _errors = self._plan(names)
        seen = [c for lane in plan['unit_lanes'] for c in lane['classes']]
        self.assertEqual(len(seen), len(set(seen)))

    def test_ui_planning_is_untouched_by_the_unit_batch_policy(self):
        # The unit per-job cap must not perturb UI lane selection: the
        # same UI inventory plans identically with the cap at 4 and at 1.
        ui_names = ['I{0}UITests'.format(i) for i in range(6)]
        est = {n: 100.0 + i * 10 for i, n in enumerate(ui_names)}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], ui_names))
            discovery = planner.discover_test_classes(str(root))
            p1 = planner.build_plan(discovery, default_cfg(), dict(est))
            p2 = planner.build_plan(
                discovery, default_cfg(unit_max_batches_per_job=1), dict(est))
            self.assertEqual(p1['ui_lanes'], p2['ui_lanes'])
            self.assertEqual(p1['ui_lane_count'], p2['ui_lane_count'])

    def test_matrix_batches_respect_the_per_job_policy(self):
        names = ['J{0:03d}Tests'.format(i) for i in range(90)]
        discovery, plan, _errors = self._plan(names)
        matrix = json.loads(planner.matrix_json(plan))
        for entry in matrix['include']:
            batches = json.loads(entry['batches'])
            self.assertEqual(entry['batch_count'], len(batches))
            self.assertLessEqual(len(batches), 4)
            self.assertTrue(all(len(b['classes']) <= 7 for b in batches))

    def test_validate_fails_closed_on_policy_violation(self):
        import copy
        names = ['K{0:02d}Tests'.format(i) for i in range(29)]
        discovery, plan, errors = self._plan(names)
        self.assertEqual(errors, [])
        broken = copy.deepcopy(plan)
        # Simulate a planner regression: two lanes folded into one,
        # leaving 29 classes (5 batches) in a single lane.
        merged = broken['unit_lanes'][0]
        other = broken['unit_lanes'].pop()
        merged['classes'] = merged['classes'] + other['classes']
        merged['batches'] = merged['batches'] + other['batches']
        merged['batch_count'] = len(merged['batches'])
        violations = planner.validate_plan(broken, discovery)
        self.assertTrue(
            any('per-job policy' in e for e in violations), violations)

    def test_invalid_policy_value_fails_closed_without_crashing(self):
        # unit_max_batches_per_job=0 must produce a structured planning
        # error, never a ZeroDivisionError (the natural "disable the cap"
        # value an operator would try first).
        names = ['M{0}Tests'.format(i) for i in range(10)]
        cfg = default_cfg(unit_max_batches_per_job=0)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, []))
            est = {n: 10.0 for n in names}
            discovery, plan = plan_from_tree(root, est, cfg)
            errors = planner.validate_plan(plan, discovery)
            self.assertTrue(
                any('unit_max_batches_per_job must be >= 1' in e
                    for e in errors), errors)

    def test_empty_inventory_passes_through_the_helper(self):
        self.assertEqual(
            planner.enforce_batches_per_job([], 0, default_cfg()), (0, []))
        self.assertEqual(
            planner.enforce_batches_per_job(
                [('OnlyTests', 1.0)], 1, default_cfg()),
            (1, [['OnlyTests']]))

    def test_overfull_lane_at_max_lanes_hands_light_classes_on(self):
        # LPT at the lane maximum puts one heavy class alone in a lane and
        # every light class in the other, past the per-job policy. The
        # suite fits: the lightest classes move to the lane with room.
        cfg = default_cfg(unit_max_batches_per_job=1, max_lanes=2)
        items = [('HeavyTests', 100.0)] + [
            ('L{0:02d}Tests'.format(i), 1.0) for i in range(13)]
        n, lanes = planner.enforce_batches_per_job(items, 2, cfg)
        self.assertEqual(n, 2)
        self.assertTrue(all(len(lane) <= 7 for lane in lanes), lanes)
        self.assertEqual(sorted(c for lane in lanes for c in lane),
                         sorted(name for name, _s in items))
        self.assertEqual(lanes, planner.enforce_batches_per_job(items, 2, cfg)[1])

    def test_policy_bounds_can_make_the_plan_fail_closed(self):
        # An inventory too large for the configured lane maximum cannot
        # satisfy the per-job policy within bounds: planning must fail
        # loudly instead of shipping a violating plan.
        cfg = default_cfg(unit_max_batches_per_job=1, max_lanes=2)
        names = ['L{0:02d}Tests'.format(i) for i in range(21)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, []))
            est = {n: 10.0 for n in names}
            discovery, plan = plan_from_tree(root, est, cfg)
            errors = planner.validate_plan(plan, discovery)
            self.assertTrue(
                any('per-job policy' in e for e in errors), errors)


class UiShardingTests(unittest.TestCase):
    ESTIMATES = {
        "ConnectionSetupTestConnectionUITests": 333.0,
        "ConnectionSetupSettingsUITests": 296.8,
        "ConnectionRepairUITests": 232.5,
        "ConnectionSetupUITests": 215.9,
        "LoginKeyboardUITests": 129.6,
        "SelectionObserverUITests": 102.7,
    }

    def test_ui_classes_partition_exactly_once_across_three_lanes(self):
        names = list(self.ESTIMATES)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], names))
            discovery, plan = plan_from_tree(root, dict(self.ESTIMATES))
            self.assertEqual(plan["ui_lane_count"], 3)
            assigned = [c for lane in plan["ui_lanes"] for c in lane["classes"]]
            self.assertEqual(sorted(assigned), sorted(names))
            self.assertEqual(len(assigned), len(set(assigned)))
            for lane in plan["ui_lanes"]:
                self.assertTrue(lane["classes"])
                self.assertEqual(lane["target"], "ConduitUITests")
                # every class carries a planned per-class watchdog
                timeouts = dict(p.split("=", 1) for p in lane["class_timeouts"].split(","))
                self.assertEqual(sorted(timeouts), sorted(lane["classes"]))
                for name, value in timeouts.items():
                    self.assertEqual(
                        int(value),
                        planner.ui_class_timeout_for(
                            self.ESTIMATES[name], 420, 3.0))
                # lane watchdog sum feeds the job ceiling: worst path is the
                # batched attempt + targeted retry, then a full per-class
                # diagnosis pass (3x), one bounded erase/reboot recovery per
                # failing class, plus setup slack.
                expected_ceiling = planner.ui_job_timeout_min(
                    lane["timeout_s"], len(lane["classes"]), default_cfg())
                self.assertEqual(lane["job_timeout_min"], expected_ceiling)
            self.assertEqual(planner.validate_plan(plan, discovery), [])

    def test_ui_lpt_balance_matches_timing_data(self):
        # Deterministic, timing-driven assignment for the live estimates:
        # heaviest class first onto the lightest lane.
        names = list(self.ESTIMATES)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], names))
            _d, plan = plan_from_tree(root, dict(self.ESTIMATES))
            loads = {
                lane["lane"]: round(
                    sum(self.ESTIMATES[c] for c in lane["classes"]), 1)
                for lane in plan["ui_lanes"]
            }
            self.assertEqual(sorted(loads.values()), [426.4, 435.7, 448.4])
            heaviest = max(plan["ui_lanes"], key=lambda l: loads[l["lane"]])
            self.assertIn("ConnectionRepairUITests", heaviest["classes"])
            self.assertIn("ConnectionSetupUITests", heaviest["classes"])

    def test_ui_lane_count_scales_and_never_exceeds_classes(self):
        # The unit selection function runs under the UI bounds.
        cfg = default_cfg()
        ui_cfg = dict(cfg, min_lanes=cfg["ui_min_lanes"], max_lanes=cfg["ui_max_lanes"])
        # no classes: no lanes
        self.assertEqual(planner.lane_count_for([], ui_cfg), 0)
        # 2 classes: never more lanes than classes, even with a 3-lane floor
        two = [("ATests", 200.0), ("BTests", 200.0)]
        self.assertEqual(planner.lane_count_for(two, ui_cfg), 2)
        # today's suite: ~1310s over 6 classes lands on the 3-lane clamp
        today = sorted(self.ESTIMATES.items(), key=lambda kv: (-kv[1], kv[0]))
        self.assertEqual(planner.lane_count_for(today, ui_cfg), 3)
        # a doubled suite scales out to the configured max (12 x ~217s: the
        # 4th lane buys 217s of wall clock, well over the tolerance)
        doubled = [("D{0}Tests".format(i), 217.0) for i in range(12)]
        self.assertEqual(planner.lane_count_for(doubled, ui_cfg), cfg["ui_max_lanes"])

    def test_default_estimates_balance_ui_lanes_without_history(self):
        names = ["New{0}UITests".format(i) for i in range(6)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], names))
            discovery, plan = plan_from_tree(root, {})
            self.assertEqual(planner.validate_plan(plan, discovery), [])
            self.assertEqual(plan["ui_lane_count"], 3)
            # unseen classes all get the conservative default, so lanes are even
            for lane in plan["ui_lanes"]:
                self.assertEqual(lane["predicted_s"], 40.0)

    def test_single_ui_class_repo_plans_and_validates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], ["LoneUITests"]))
            discovery, plan = plan_from_tree(root, {"LoneUITests": 100.0})
            errors = planner.validate_plan(plan, discovery)
            self.assertEqual(errors, [])
            self.assertEqual(plan["ui_lane_count"], 1)
            lane = plan["ui_lanes"][0]
            self.assertEqual(lane["classes"], ["LoneUITests"])
            self.assertEqual(lane["class_timeouts"], "LoneUITests=420")
            matrix = json.loads(planner.ui_matrix_json(plan))
            self.assertEqual(len(matrix["include"]), 1)
            self.assertEqual(matrix["include"][0]["classes"], "LoneUITests")

    def test_ui_job_ceiling_covers_worst_in_script_path(self):
        # The reachable worst paths, derived from the runner's invocation
        # graph (not from the formula):
        #   (a) batch timeout -> per-class diagnosis = batch (1x budget sum)
        #       + diagnosis attempt + retry (2x) = 3x;
        #   (b) batch completes with failures in EVERY class -> the targeted
        #       retry covers the full budget sum and can time out ->
        #       diagnosis of the retried classes (2x) = up to 4x. (b) wins.
        # Each failing class then pays one bounded erase/reboot recovery,
        # every diagnosis attempt's timing extraction can wedge to the
        # xcresulttool bound, and the batch's own classification extraction
        # adds one more bound - plus setup slack. The GitHub ceiling must
        # never preempt that path - otherwise the hung class is never named.
        cfg = default_cfg()
        for n_classes in (1, 2, 3, 5):
            budgets = [planner.ui_class_timeout_for(est, cfg["ui_class_timeout_min_s"],
                                                    cfg["ui_class_timeout_multiplier"])
                       for est in (333.0, 296.8, 232.5, 215.9, 129.6)[:n_classes]]
            lane_timeout = sum(budgets)
            batched_attempt = lane_timeout
            failed_retry = lane_timeout          # retry covers every class
            diagnosis = 2 * lane_timeout
            ceiling_s = planner.ui_job_timeout_min(
                lane_timeout, n_classes, cfg) * 60
            worst_path = (batched_attempt + failed_retry + diagnosis
                          + (n_classes + 1) * cfg["ui_reset_overhead_s"]
                          + (2 * n_classes + 1) * cfg["ui_extract_bound_s"]
                          + cfg["job_timeout_margin_s"])
            self.assertGreaterEqual(
                ceiling_s, worst_path,
                f"ceiling too small for {n_classes} classes")


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
            uimat1 = Path(tmp) / "uimatrix1.json"
            uimat2 = Path(tmp) / "uimatrix2.json"
            for out, mat, uimat in ((out1, mat1, uimat1), (out2, mat2, uimat2)):
                proc = subprocess.run(
                    [sys.executable, str(Path(SCRIPTS_DIR) / "plan-tests.py"),
                     "plan", "--repo-root", str(root), "--out", str(out),
                     "--matrix-out", str(mat), "--ui-matrix-out", str(uimat)],
                    capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertEqual(out1.read_bytes(), out2.read_bytes())
            self.assertEqual(mat1.read_bytes(), mat2.read_bytes())
            self.assertEqual(uimat1.read_bytes(), uimat2.read_bytes())
            matrix = json.loads(mat1.read_text(encoding="utf-8"))
            self.assertIn("include", matrix)
            for entry in matrix["include"]:
                self.assertIn("lane", entry)
                self.assertIn("classes", entry)
                self.assertIn("timeout_s", entry)
                self.assertIn("job_timeout_min", entry)
            # no empty lanes in the matrix either
            self.assertTrue(all(entry["classes"] for entry in matrix["include"]))
            ui_matrix = json.loads(uimat1.read_text(encoding="utf-8"))
            self.assertTrue(all(entry["classes"] for entry in ui_matrix["include"]))
            for entry in ui_matrix["include"]:
                self.assertIn("class_timeouts", entry)
                self.assertTrue(entry["class_timeouts"])
                self.assertIn("class_estimates", entry)
                # every planned class has both an estimate and a watchdog
                classes = entry["classes"].split(",")
                timeout_map = dict(
                    p.split("=", 1) for p in entry["class_timeouts"].split(","))
                self.assertEqual(sorted(timeout_map), sorted(classes))
                self.assertTrue(all(v.isdigit() for v in timeout_map.values()))


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
                "/Users/runner/work/hermes-conduit/hermes-conduit/ci-derived-data/Build/Products/a.app",
                "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest",
            ])
            violations, checked = planner.audit_xctestrun(
                path, "/Users/runner/work/hermes-conduit/hermes-conduit")
            self.assertEqual(violations, [])
            self.assertEqual(checked, 2)

    def test_private_var_temp_path_is_rejected(self):
        # /private/var/folders/... is per-runner temp state: a build product
        # resolved there exists only on the machine that built the artifact.
        with tempfile.TemporaryDirectory() as tmp:
            path = self._plist(tmp, [
                "/private/var/folders/zz/abc/T/x/Y/d/e/Applications/iOS/TestBuild/Products/a.app",
                "/Users/runner/work/hermes-conduit/hermes-conduit/ci-derived-data/Build/Products/b.app",
            ])
            violations, _checked = planner.audit_xctestrun(
                path, "/Users/runner/work/hermes-conduit/hermes-conduit")
            self.assertEqual(len(violations), 1)
            self.assertTrue(violations[0].startswith("/private/var/"))

    def test_foreign_absolute_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._plist(tmp, [
                "/Users/runner/work/hermes-conduit/hermes-conduit/ci-derived-data/Build/Products/a.app",
                "/Users/someone/else/private/b.xctest",
            ])
            violations, _checked = planner.audit_xctestrun(
                path, "/Users/runner/work/hermes-conduit/hermes-conduit")
            self.assertEqual(violations, ["/Users/someone/else/private/b.xctest"])

if __name__ == "__main__":
    unittest.main()
