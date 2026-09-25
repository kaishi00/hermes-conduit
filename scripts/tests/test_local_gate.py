"""Regression tests for the local exhaustive gate tooling.

Covers scripts/local-gate.py (plan projection, classification, verdict) with
synthetic plan/run artifacts, so the gate's fail-closed behavior is pinned on
Linux CI without a Mac: an unreadable artifact, a class that never executed,
a genuine assertion failure, an infrastructure failure, or an assertion that
was re-run until it passed must never produce a PASS verdict.
"""

import contextlib
import io
import json
import os
import shlex
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

from _util import SCRIPTS_DIR, load_module

local_gate = load_module("local_gate", "local-gate.py")


UNIT_LANE = {
    "lane": "unit-1",
    "target": "ConduitTests",
    "classes": ["AlphaTests", "BetaTests", "GammaTests"],
    "batches": [
        {"classes": ["AlphaTests", "BetaTests"], "predicted_s": 10.0, "timeout_s": 600},
        {"classes": ["GammaTests"], "predicted_s": 5.0, "timeout_s": 500},
    ],
    "batch_count": 2,
    "predicted_s": 15.0,
    "timeout_s": 1100,
}

UI_LANE = {
    "lane": "ui-1",
    "target": "ConduitUITests",
    "classes": ["LaunchUITests"],
    "class_timeouts": "LaunchUITests=420",
    "class_estimates": "LaunchUITests=100.0",
    "predicted_s": 100.0,
    "timeout_s": 1400,
}


def make_plan(unit_lanes=None, ui_lanes=None, **overrides):
    plan = {
        "schema_version": 2,
        "inventory": {"unit": ["AlphaTests", "BetaTests", "GammaTests"],
                      "ui": ["LaunchUITests"]},
        "unit_lanes": [UNIT_LANE] if unit_lanes is None else unit_lanes,
        "ui_lanes": [UI_LANE] if ui_lanes is None else ui_lanes,
        "lane_count": 1,
        "ui_lane_count": 1,
        "total_predicted_s": 15.0,
        "ui_predicted_s": 100.0,
        "imbalance_predicted_pct": 0.0,
        "ui_imbalance_predicted_pct": 0.0,
        "estimates": {},
        "config": {},
    }
    plan.update(overrides)
    return plan


def write_json(path, doc):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2), encoding="utf-8")


def write_workers(run_dir, records):
    """Write the run's worker evidence exactly as local-ci-gate.sh does.

    workers.tsv columns: name, device name, device UDID, exit code, wall
    seconds, completed, sim-prep failed, log path (relative to the run dir).
    The per-worker log files are written too: the summarizer requires the
    evidence it points at to exist.
    """
    run_dir = Path(run_dir)
    lines = []
    for rec in records:
        lines.append("\t".join([
            rec["name"],
            rec["device_name"],
            rec["udid"],
            rec.get("exit_code", "0"),
            str(rec.get("wall_s", 60)),
            "1" if rec.get("completed", True) else "0",
            "1" if rec.get("sim_prep_failed") else "0",
            rec.get("log", "workers/{0}/worker.log".format(rec["name"])),
        ]))
    path = run_dir / "workers.tsv"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    for rec in records:
        if rec.get("write_log", True):
            log = run_dir / rec.get("log", "workers/{0}/worker.log".format(rec["name"]))
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text("worker log\n", encoding="utf-8")
    return path


def lane_artifacts(lane_dir, *, status="pass", classes=("AlphaTests",),
                   cases=4, failures=(), attempts=None, batches=None,
                   retried=(), infra_recovered=(), persistent_infra=(),
                   observations=True, detail=True, lane_result=True,
                   lane_classes=None, simulator=None):
    """Write the three artifacts ci-test-lane.sh leaves behind.

    An artifact that the caller disabled is DELETED, not left over from an
    earlier write: tests that model a missing extraction must start from a
    directory without one, otherwise the fixture silently passes for the
    wrong reason.

    Fixture hazard: `batches` defaults to a PASSING batch, whose attempt
    chain appends `passed` onto whatever `attempts` says - a fixture that
    passes failing `attempts` without matching `batches=` gets its status
    laundered (the work item reads as recovered). Always pass both together
    when modelling a failure.
    """
    lane_dir = Path(lane_dir)
    lane_dir.mkdir(parents=True, exist_ok=True)
    for name, wanted in (("lane-result.json", lane_result),
                         ("observations.json", observations),
                         ("detail.json", detail)):
        target = lane_dir / name
        if not wanted and target.exists():
            target.unlink()
    if lane_result:
        write_json(lane_dir / "lane-result.json", {
            "schema_version": 1,
            "lane": "unit-1",
            "kind": "unit",
            "target": "ConduitTests",
            # lane_classes models the production UI shape: the runner writes
            # its DECLARED class list even when the invocation produced no
            # results, and a lane with per-class invocations carries no
            # `batches` array - the declared list is the only name the
            # shard-level work item has.
            "classes": list(lane_classes if lane_classes is not None
                            else classes),
            "status": status,
            "predicted_s": 15.0,
            "timeout_s": 1100,
            "actual_s": 42,
            "attempts": attempts if attempts is not None else [
                {"mode": "batch", "n": 1, "class": "all", "status": "passed"}],
            "batches": batches if batches is not None else [
                {"batch": 1, "classes": list(classes), "timeout_s": 600,
                 "status": "pass",
                 "attempts": [{"attempt": 1, "status": "passed",
                               "seconds": 1.0, "failures": 0}]}],
            "retried_classes": list(retried),
            "infra_recovered_classes": list(infra_recovered),
            "persistent_infra_classes": list(persistent_infra),
            "simulator": ({"name": simulator[0], "udid": simulator[1]}
                          if simulator else None),
        })
    if observations:
        write_json(lane_dir / "observations.json", {
            "schema_version": 1,
            "classes": {c: 1.0 for c in classes},
            "counts": {"classes": len(classes), "cases": cases},
        })
    if detail:
        write_json(lane_dir / "detail.json", {
            "schema_version": 1,
            "attempts": [
                {"class": c, "test": "testSomething", "attempts_count": 1,
                 "final": "Passed", "attempts": []}
                for c in classes
            ],
            "failures": list(failures),
            "retried": [],
        })
    return lane_dir


class LaneProjectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def _lanes(self, plan, json_out=None):
        plan_path = self.root / "plan.json"
        write_json(plan_path, plan)
        out = self.root / "lanes.env"
        args = ["lanes", "--plan", str(plan_path), "--out", str(out)]
        if json_out is not None:
            args += ["--json-out", str(json_out)]
        with contextlib.redirect_stdout(io.StringIO()):
            code = local_gate.main(args)
        return code, out

    def test_projects_single_unit_and_ui_lane(self):
        audit_path = self.root / "projection.json"
        code, out = self._lanes(make_plan(), json_out=audit_path)
        self.assertEqual(code, 0)
        text = out.read_text(encoding="utf-8")
        self.assertIn("GATE_UNIT_CLASS_COUNT=3", text)
        self.assertIn("GATE_UNIT_BATCH_COUNT=2", text)
        self.assertIn("GATE_UI_PRESENT=1", text)
        self.assertIn("GATE_UI_CLASS_TIMEOUTS=", text)
        # The audit copy is the plan projection the summarizer reads back for
        # its completeness check, so it lands at the path the shell passed.
        audit = json.loads(audit_path.read_text(encoding="utf-8"))
        self.assertEqual(audit["unit"]["classes"], ["AlphaTests", "BetaTests",
                                                   "GammaTests"])
        self.assertEqual(len(audit["unit"]["batches"]), 2)

    def test_default_audit_path_is_the_env_path_with_json_suffix(self):
        code, out = self._lanes(make_plan())
        self.assertEqual(code, 0)
        self.assertTrue((self.root / "lanes.json").exists())

    def test_refuses_multi_lane_plan(self):
        """The gate is exhaustive: a sharded plan would silently mean "the
        suites were split", so it must refuse rather than pick a lane."""
        plan = make_plan(unit_lanes=[UNIT_LANE, dict(UNIT_LANE, lane="unit-2")])
        code, _ = self._lanes(plan)
        self.assertEqual(code, 3)

    def test_refuses_lane_without_batches(self):
        plan = make_plan(unit_lanes=[dict(UNIT_LANE, batches=[])])
        code, _ = self._lanes(plan)
        self.assertEqual(code, 3)

    def test_no_ui_lane_is_allowed(self):
        code, out = self._lanes(make_plan(ui_lanes=[]))
        self.assertEqual(code, 0)
        self.assertIn("GATE_UI_PRESENT=0", out.read_text(encoding="utf-8"))


class RepeatSpecTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plan_path = self.root / "plan.json"
        write_json(self.plan_path, make_plan())

    def _spec(self, classes, cap=900, iterations=3, tsv_out=None):
        out = self.root / "repeats.json"
        args = ["repeat-spec", "--plan", str(self.plan_path), "--classes", classes,
                "--iterations", str(iterations), "--timeout-cap", str(cap),
                "--out", str(out)]
        if tsv_out is not None:
            args += ["--tsv-out", str(tsv_out)]
        with contextlib.redirect_stdout(io.StringIO()):
            code = local_gate.main(args)
        return code, out

    def test_tsv_lands_where_the_caller_says(self):
        """The shell reads this file line by line; if the two sides disagree
        about its path the loop silently runs zero iterations while the lane
        status still says "pass" - exactly the silent no-op this pins."""
        tsv = self.root / "custom-name.tsv"
        code, _ = self._spec("AlphaTests", tsv_out=tsv)
        self.assertEqual(code, 0)
        self.assertTrue(tsv.exists())
        line = tsv.read_text(encoding="utf-8").strip()
        self.assertTrue(line.startswith("AlphaTests\t"))
        # And the explicitly named file differs from what a derived name would
        # have produced, so the assertion above cannot pass by accident.
        self.assertFalse((self.root / "repeats.tsv").exists())

    def test_whitespace_in_the_class_list_is_tolerated(self):
        code, _ = self._spec("AlphaTests, BetaTests")
        self.assertEqual(code, 0)
        spec = json.loads((self.root / "repeats.json").read_text(encoding="utf-8"))
        self.assertEqual([t["class"] for t in spec["tasks"]],
                         ["AlphaTests", "BetaTests"])

    def test_uses_planner_batch_budget_and_caps_it(self):
        code, out = self._spec("AlphaTests")
        self.assertEqual(code, 0)
        spec = json.loads(out.read_text(encoding="utf-8"))
        task = spec["tasks"][0]
        self.assertEqual(task["class"], "AlphaTests")
        self.assertEqual(task["planner_batch_timeout_s"], 600)
        self.assertEqual(task["timeout_s"], 600)
        self.assertFalse(task["timeout_capped"])
        tsv = (self.root / "repeats.tsv").read_text(encoding="utf-8").strip()
        self.assertTrue(tsv.startswith("AlphaTests\t"))

    def test_caps_a_huge_planner_budget(self):
        second = dict(UNIT_LANE["batches"][1], timeout_s=5000)
        plan = make_plan(unit_lanes=[dict(UNIT_LANE, batches=[UNIT_LANE["batches"][0],
                                                             second])])
        write_json(self.plan_path, plan)
        code, out = self._spec("GammaTests", cap=900)
        self.assertEqual(code, 0)
        task = json.loads(out.read_text(encoding="utf-8"))["tasks"][0]
        self.assertEqual(task["planner_batch_timeout_s"], 5000)
        self.assertEqual(task["timeout_s"], 900)
        self.assertTrue(task["timeout_capped"])

    def test_unknown_repeat_class_fails_closed(self):
        """A repeat class that left the suite means the repeat policy quietly
        stopped covering what it promises - that must fail, not warn."""
        code, _ = self._spec("AlphaTests,DoesNotExistTests")
        self.assertEqual(code, 3)


class NotRunBatchesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plan_path = self.root / "plan.json"
        write_json(self.plan_path, make_plan())

    def _continuation(self, batch_statuses):
        lane_result = self.root / "lane-result.json"
        write_json(lane_result, {
            "schema_version": 1, "lane": "unit-1", "status": "fail",
            "batches": [{"batch": i, "classes": batch["classes"],
                         "timeout_s": batch["timeout_s"], "status": status,
                         "attempts": []}
                        for i, (batch, status) in
                        enumerate(zip(UNIT_LANE["batches"], batch_statuses), start=1)],
        })
        out = self.root / "cont.env"
        with contextlib.redirect_stdout(io.StringIO()):
            code = local_gate.main(["not-run-batches", "--plan", str(self.plan_path),
                                    "--lane-result", str(lane_result),
                                    "--out", str(out)])
        values = {}
        for line in out.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            values[key] = shlex.split(value)[0] if value.strip() else ""
        return code, values

    def test_projects_the_never_reached_batches(self):
        code, values = self._continuation(["test-failures", "not_run"])
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_CONT_PRESENT"], "1")
        self.assertEqual(values["GATE_CONT_BATCH_COUNT"], "1")
        self.assertEqual(values["GATE_CONT_BATCH_INDICES"], "2")
        self.assertEqual(values["GATE_CONT_CLASSES"], "GammaTests")
        # The continuation reuses the planner's own batch object, including
        # its watchdog, rather than inventing a budget.
        self.assertEqual(values["GATE_CONT_TIMEOUT"], "500")
        self.assertEqual(values["GATE_CONT_PREDICTED"], "5.0")

    def test_no_continuation_when_nothing_was_left_behind(self):
        code, values = self._continuation(["pass", "pass"])
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_CONT_PRESENT"], "0")

    def test_missing_lane_result_fails_closed(self):
        out = self.root / "cont.env"
        with contextlib.redirect_stdout(io.StringIO()):
            code = local_gate.main(["not-run-batches", "--plan", str(self.plan_path),
                                    "--lane-result", str(self.root / "nope.json"),
                                    "--out", str(out)])
        self.assertEqual(code, 3)
        self.assertFalse(out.exists())


class RecoveryVerdictTests(unittest.TestCase):
    """End-to-end verdicts for the bounded recovery round.

    Builds run directories that model the three outcomes a recovery round can
    have: it recovered the work, it hit the same infrastructure class again, or
    it never ran because a genuine assertion was present.
    """

    SHA = "1" * 40
    WEDGE_FAILURE = [{"class": "System Failures",
                      "test": "Conduit encountered an error", "attempts": []}]
    BUSY_LOG = 'iOSSimulator: Failed to launch app with identifier: com.milim.relay ' \
               '(BSErrorCodeDescription=Busy)'
    WEDGE_ATTEMPTS = [{"mode": "batch", "n": 1, "class": "all",
                       "status": "test-failures"},
                      {"mode": "batch", "n": 2, "class": "all",
                       "status": "not_run"}]
    WEDGE_BATCHES = [
        {"batch": 1, "classes": ["AlphaTests", "BetaTests"], "timeout_s": 600,
         "status": "test-failures",
         "attempts": [{"attempt": 1, "status": "test-failures",
                       "seconds": 1.0, "failures": 1}]},
        {"batch": 2, "classes": ["GammaTests"], "timeout_s": 500,
         "status": "not_run", "attempts": []},
    ]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        # Under a subdirectory: one test moves this tree into a path whose name
        # contains "recovery", and a move into its own descendant is invalid.
        self.run_dir = Path(self.tmp.name) / "fixture"
        self.run_dir.mkdir(parents=True, exist_ok=True)
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests", "BetaTests", "GammaTests"]},
            "ui": {"classes": ["LaunchUITests"]},
        })
        write_json(self.run_dir / "meta.json", {
            "schema_version": 1, "requested_ref": "origin/main",
            "tested_sha": self.SHA, "xcode_version": "Xcode 27.0",
            "simulator": {"name": "Conduit CI Gate", "runtime": "iOS 26.5",
                          "udid": "GATE-DEVICE"},
            "started_at": "2026-09-21T00:00:00Z",
            "finished_at": "2026-09-21T01:00:00Z", "wall_s": 3600,
            "allowed_recovered_infrastructure": False,
            "static_checks_enabled": True,
            "repeat_policy_enabled": True,
            "run_flags": {"lock_used": True, "simulator_prep": True},
            "expected": {"unit_classes": 3, "unit_batches": 2, "ui_classes": 1,
                         "repeat_classes": [], "repeat_iterations": 0},
        })
        write_json(self.run_dir / "static" / "phase.json", {
            "schema_version": 1, "phase": "static", "status": "pass",
            "duration_s": 5, "checks": [
                {"name": "plan-validate", "status": "pass", "duration_s": 1},
                {"name": "ci-tooling-regression", "status": "pass", "duration_s": 1},
                {"name": "localization-coverage", "status": "pass", "duration_s": 1},
            ]})
        write_json(self.run_dir / "build" / "phase.json", {
            "schema_version": 1, "phase": "build", "status": "pass",
            "duration_s": 60, "details": {"xctestrun": "/tmp/x.xctestrun"}})
        write_workers(self.run_dir, [
            {"name": "unit", "device_name": "Conduit CI Gate",
             "udid": "GATE-DEVICE"},
            {"name": "ui", "device_name": "Conduit CI Gate",
             "udid": "GATE-DEVICE"},
        ])
        lane_artifacts(self.run_dir / "lanes" / "ui", status="pass",
                       classes=("LaunchUITests",), cases=3,
                       simulator=("Conduit CI Gate", "GATE-DEVICE"))

    def _wedge_log(self, lane_dir):
        logs = lane_dir / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "batch-1-a1.log").write_text(self.BUSY_LOG + "\n", encoding="utf-8")

    def _recovery_phase(self, status="pass"):
        write_json(self.run_dir / "recovery" / "phase.json", {
            "schema_version": 1, "phase": "recovery", "status": status,
            "duration_s": 0, "checks": [
                {"name": "round-1", "status": status, "duration_s": 0}]})

    def _summarize(self):
        out = self.run_dir / "gate-result.json"
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = local_gate.main(["summarize", "--run-dir", str(self.run_dir),
                                    "--out", str(out),
                                    "--markdown", str(self.run_dir / "summary.md")])
        self.human = buffer.getvalue()
        return code, json.loads(out.read_text(encoding="utf-8"))

    def _primary(self, *, observed, cases):
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=observed, cases=cases,
                       failures=self.WEDGE_FAILURE, attempts=self.WEDGE_ATTEMPTS,
                       batches=self.WEDGE_BATCHES)
        self._wedge_log(self.run_dir / "lanes" / "unit")

    def _faithful_unit_round(self):
        """The real wedge sequence, faithfully shaped.

        Batch 1 was refused before any of its classes produced results; the
        continuation ran the batch the stopped lane never reached; the round
        re-ran exactly the classes left without results - batch 1's own. The
        round's evidence therefore covers the batch its event names, which is
        what makes the event legitimately healed.
        """
        self._primary(observed=(), cases=0)
        lane_artifacts(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("GammaTests",), cases=1)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("AlphaTests", "BetaTests"), cases=2)
        self._recovery_phase("pass")

    def test_recovered_retry_passes_overall(self):
        """Same-suite recovery that OBSERVED the wedged work item -> the event
        is recovered by the round and the run PASSes, with the retry recorded
        in the result document."""
        self._faithful_unit_round()
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")
        self.assertEqual(doc["unit"]["classes_missing"], [])
        self.assertEqual(doc["unit"]["executions"], 3,
                         "one execution per class across all passes")
        infra = doc["infrastructure"]
        self.assertEqual(infra["failures"], 1)
        self.assertEqual(infra["retries"], 1)
        # The wedge event is healed by the round: reported as recovered, with
        # the round recorded as its healer - not as a bare "it got better".
        self.assertEqual(infra["recovered"], 1)
        self.assertEqual(infra["persistent"], 0)
        self.assertEqual(
            infra["events"]["infrastructure_failures"][0]["recovered_by"],
            "gate recovery round")
        self.assertEqual(infra["retry_detail"][0]["name"], "round-1")
        self.assertEqual(len(doc["unit"]["passes"]), 3,
                         "primary, continuation and recovery")
        # The round is recorded, never hidden: both the machine-readable
        # document and the human summary carry it.
        self.assertIn("recovered", self.human)
        self.assertIn("recovery", json.dumps(doc))

    def test_a_round_that_never_reran_the_work_item_does_not_heal_it(self):
        """Same-suite round runs, but does NOT observe the failing work item
        -> FAIL.

        The round re-ran Gamma (the class left without results) while the
        wedged batch's own classes already had results, so the batch's event
        names work the round never re-ran. Before the per-suite evidence
        discipline it was stamped "healed" and this run passed on a round it
        never earned.
        """
        self._primary(observed=("AlphaTests", "BetaTests"), cases=2)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("GammaTests",), cases=1)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        unit_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if e.get("lane") == "unit"]
        self.assertTrue(unit_infra, doc["infrastructure"]["events"])
        self.assertFalse(
            any(e.get("recovered_by") == "gate recovery round"
                for e in unit_infra),
            "the round may not claim work its own pass never observed")
        self.assertEqual(doc["infrastructure"]["persistent"], 1)
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("persistent infrastructure" in p
                            for p in doc["problems"]), doc["problems"])

    def test_a_unit_recovery_never_heals_ui_infrastructure(self):
        """Cross-suite: a unit round that healed the unit wedge must not touch
        an unrelated UI event. The UI event's work was never re-run by
        anything, so it stays persistent and the run FAILS."""
        self._faithful_unit_round()
        # The UI invocation was refused while the shard's class already had
        # results (the wedge alternates per launch); nothing re-ran it.
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=("LaunchUITests",), cases=3,
                       failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["LaunchUITests"],
                                 "timeout_s": 600, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0,
                                               "failures": 1}]}])
        self._wedge_log(self.run_dir / "lanes" / "ui")
        code, doc = self._summarize()
        ui_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if e.get("lane") == "ui"]
        self.assertTrue(ui_infra, doc["infrastructure"]["events"])
        self.assertFalse(
            any(e.get("recovered_by") == "gate recovery round"
                for e in ui_infra),
            "a unit recovery must never heal UI evidence")
        self.assertEqual(
            [e["lane"] for e in
             doc["infrastructure"]["events"]["infrastructure_persistent"]],
            ["ui"],
            "the persistent event is the UI one - not a unit event healed "
            "or lost along the way")
        self.assertTrue(any("persistent infrastructure" in p
                            for p in doc["problems"]), doc["problems"])
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")

    def test_a_ui_recovery_never_heals_unit_infrastructure(self):
        """Cross-suite, the mirror: a UI round that healed the UI wedge must
        not touch an unrelated unit event - that event stays persistent."""
        # Observations say every unit class has results while WEDGE_BATCHES
        # still carries the refusal: that divergence IS the cross-suite trap
        # under test - coverage is complete, yet nothing re-ran the event.
        self._primary(observed=("AlphaTests", "BetaTests", "GammaTests"), cases=3)
        # The UI shard was refused with no results, and the UI round re-ran it.
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=(), cases=0, failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["LaunchUITests"],
                                 "timeout_s": 600, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0,
                                               "failures": 1}]}])
        self._wedge_log(self.run_dir / "lanes" / "ui")
        lane_artifacts(self.run_dir / "lanes" / "ui-recovery", status="pass",
                       classes=("LaunchUITests",), cases=3)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        unit_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if e.get("lane") == "unit"]
        ui_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if e.get("lane") == "ui"]
        self.assertTrue(unit_infra and ui_infra,
                        doc["infrastructure"]["events"])
        self.assertFalse(
            any(e.get("recovered_by") == "gate recovery round"
                for e in unit_infra),
            "a UI recovery must never heal unit evidence")
        self.assertTrue(
            all(e.get("recovered_by") == "gate recovery round"
                for e in ui_infra),
            "the UI round healed its OWN wedge - that much is legitimate")
        self.assertEqual(
            [e["lane"] for e in
             doc["infrastructure"]["events"]["infrastructure_persistent"]],
            ["unit"],
            "the persistent event is the unit one - not a UI event healed "
            "or lost along the way")
        self.assertTrue(any("persistent infrastructure" in p
                            for p in doc["problems"]), doc["problems"])
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")

    def test_an_incomplete_other_suite_does_not_blank_a_real_recovery(self):
        """Per-suite gates: the unit round ran and left the unit suite
        complete, so its healed event stays recorded as recovered even though
        the UI suite is incomplete for its own unrelated reason. The run still
        FAILS - on the UI suite's missing class, not on a blanked recovery
        record."""
        self._faithful_unit_round()
        # The UI shard was refused with no results and NO UI round ran.
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=(), cases=0, failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["LaunchUITests"],
                                 "timeout_s": 600, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0,
                                               "failures": 1}]}])
        self._wedge_log(self.run_dir / "lanes" / "ui")
        code, doc = self._summarize()
        unit_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if e.get("lane") == "unit"]
        self.assertTrue(unit_infra, doc["infrastructure"]["events"])
        self.assertTrue(
            all(e.get("recovered_by") == "gate recovery round"
                for e in unit_infra),
            "the unit round really did re-run this work - its record must "
            "say so even while the other suite fails for its own reason")
        self.assertIn("LaunchUITests", doc["ui"]["classes_missing"])
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")

    def _watchdog_lane_with_partial_results(self):
        """Batch 1 [Alpha, Beta] hit its watchdog with Alpha's results
        already written; batch 2 never ran. The shape a wedge-induced hang
        leaves behind when it strikes mid-batch.
        """
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests",), cases=1,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "timeout"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "not_run"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "timeout",
                            "attempts": [{"attempt": 1, "status": "timeout",
                                          "seconds": 600.0, "failures": 0}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "not_run",
                            "attempts": []},
                       ])
        self._wedge_log(self.run_dir / "lanes" / "unit")

    def test_a_hang_the_round_never_reran_stays_persistent(self):
        """A hang is healed ONLY when the round re-ran every class it names.

        Here the continuation completed batch 2 and the round re-ran only the
        class that was missing (Beta): Alpha's remaining cases were never
        executed again, so healing this hang would flip a must-FAIL run into
        PASS on coverage the round never produced.
        """
        self._watchdog_lane_with_partial_results()
        lane_artifacts(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("GammaTests",), cases=1)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery",
                       status="pass", classes=("BetaTests",), cases=1)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        # Coverage IS complete - only the un-healed hang can fail this run.
        self.assertEqual(doc["unit"]["classes_missing"], [])
        timeouts = doc["infrastructure"]["events"]["timeouts"]
        self.assertEqual(len(timeouts), 1, doc)
        self.assertFalse(
            timeouts[0].get("recovered"),
            "a hang whose classes the round never re-ran must stay persistent")
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(
            any("persistent infrastructure failure(s)/hang(s)" in p
                for p in doc["problems"]), doc["problems"])

    def test_a_hang_the_round_actually_reran_is_healed(self):
        """The other direction of the same rule: when the round re-ran EVERY
        class the hang names, the hang is healed - that retry is exactly what
        the round exists for.
        """
        self._watchdog_lane_with_partial_results()
        lane_artifacts(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("GammaTests",), cases=1)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery",
                       status="pass",
                       classes=("AlphaTests", "BetaTests"), cases=2)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        timeouts = doc["infrastructure"]["events"]["timeouts"]
        self.assertEqual(len(timeouts), 1, doc)
        self.assertTrue(timeouts[0].get("recovered"))
        self.assertEqual(timeouts[0].get("recovered_by"),
                         "gate recovery round")
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")

    def test_the_rerun_message_counts_only_lane_retry_timeouts(self):
        """The "recovered by a bounded retry" problem must not attribute the
        ROUND's healed hang to the lane retry: the message tells the operator
        to rerun, and a hang the round already healed has no business in it.
        """
        # Primary: batch 1 hung with Alpha's results already written, and
        # batch 2 recovered by the runner's OWN same-batch retry - a
        # classifier-recovered INFRA event whose healer is nobody (no
        # `recovered_by`), which is what triggers the message.
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "GammaTests"), cases=2,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "timeout"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "infra-error"},
                                 {"mode": "batch-retry", "n": 2,
                                  "class": "all", "status": "passed"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "timeout",
                            "attempts": [{"attempt": 1, "status": "timeout",
                                          "seconds": 600.0, "failures": 0}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "pass",
                            "attempts": [{"attempt": 1,
                                          "status": "infra-error",
                                          "seconds": 1.0, "failures": 0},
                                         {"attempt": 2, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                       ])
        self._wedge_log(self.run_dir / "lanes" / "unit")
        # The round re-ran EVERY class the hang names -> healed by the round.
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery",
                       status="pass",
                       classes=("AlphaTests", "BetaTests"), cases=2)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        retry_msgs = [p for p in doc["problems"] if "bounded retry" in p]
        self.assertEqual(len(retry_msgs), 1, doc["problems"])
        self.assertIn("(1 infra, 0 timeout: GammaTests)", retry_msgs[0],
                      "the message counts only the LANE-retry evidence, not "
                      "the hang the gate's round healed")
        self.assertNotIn("AlphaTests", retry_msgs[0])
        self.assertEqual(code, 1, doc["problems"])

    def test_allow_recovered_does_not_claim_a_downgrade_it_did_not_perform(self):
        """With ONLY round-healed evidence present the flag changed nothing:
        the verdict was already PASS, so its caveat would describe a
        downgrade that never happened.
        """
        meta = json.loads(
            (self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["allowed_recovered_infrastructure"] = True
        write_json(self.run_dir / "meta.json", meta)
        self._watchdog_lane_with_partial_results()
        lane_artifacts(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("GammaTests",), cases=1)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery",
                       status="pass",
                       classes=("AlphaTests", "BetaTests"), cases=2)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")
        self.assertFalse(
            any("--allow-recovered-infrastructure" in c
                for c in doc["caveats"]),
            "the flag downgraded nothing here, so it must not claim to have: "
            "{0}".format(doc["caveats"]))

    def test_a_double_wedged_repetition_stays_fatal_after_a_healed_round(self):
        """The round never re-runs a repetition: a repeat iteration AND its
        one retry both lost to the launch wedge must stay PERSISTENT and fail
        the run. Stamping them 'gate recovery round' would launder a
        repetition that never executed into a PASS.
        """
        self._faithful_unit_round()
        meta = json.loads(
            (self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["expected"]["repeat_classes"] = ["AlphaTests"]
        meta["expected"]["repeat_iterations"] = 1
        write_json(self.run_dir / "meta.json", meta)
        base = self.run_dir / "repeats" / "AlphaTests"
        for name in ("iter-1", "iter-1-retry"):
            lane_artifacts(base / name, status="fail",
                           classes=("AlphaTests",), cases=1,
                           failures=self.WEDGE_FAILURE,
                           attempts=[{"mode": "batch", "n": 1,
                                      "class": "all",
                                      "status": "test-failures"}],
                           # The batch chain must carry the wedge too: the
                           # default (passing) batch would chain a `passed`
                           # onto the attempt and classify the work item as
                           # recovered - the exact laundering under test.
                           batches=[{"batch": 1,
                                     "classes": ["AlphaTests"],
                                     "timeout_s": 600,
                                     "status": "test-failures",
                                     "attempts": [{"attempt": 1,
                                                   "status": "test-failures",
                                                   "seconds": 1.0,
                                                   "failures": 1}]}])
            logs = base / name / "logs"
            logs.mkdir(parents=True, exist_ok=True)
            (logs / "batch-1-a1.log").write_text(self.BUSY_LOG + chr(10),
                                                 encoding="utf-8")
        code, doc = self._summarize()
        # The unit wedge WAS healed by the round; the repeat was not touched
        # by it - exactly one persistent event may remain, and it is the
        # repetition's.
        self.assertEqual(doc["unit"]["classes_missing"], [])
        repeat_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if str(e.get("lane") or "").startswith("repeat:")]
        self.assertTrue(repeat_infra, doc["infrastructure"]["events"])
        self.assertFalse(
            any(e.get("recovered_by") == "gate recovery round"
                for e in repeat_infra),
            "the round may not claim a repetition it never ran")
        self.assertEqual(doc["infrastructure"]["persistent"], 1)
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(
            any("persistent infrastructure" in p for p in doc["problems"]),
            doc["problems"])

    def _lane_retry_healed_hang(self):
        """Batch 1's watchdog stalled and the lane runner's own same-batch
        retry passed it - a hang recovered by the LANE, no round involved.
        """
        lane_artifacts(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=3,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "timeout"},
                                 {"mode": "batch-retry", "n": 1,
                                  "class": "all", "status": "passed"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "passed"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "pass",
                            "attempts": [{"attempt": 1, "status": "timeout",
                                          "seconds": 600.0, "failures": 0},
                                         {"attempt": 2, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "pass",
                            "attempts": [{"attempt": 1, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                       ])

    def test_a_timeout_the_lane_retry_healed_is_still_fatal(self):
        """A hang the LANE's own retry passed is recovered evidence with the
        lane as its healer: fatal by default, exactly like infrastructure -
        never a silent PASS with nothing recorded anywhere.
        """
        self._lane_retry_healed_hang()
        code, doc = self._summarize()
        retry_msgs = [p for p in doc["problems"] if "bounded retry" in p]
        self.assertEqual(len(retry_msgs), 1, doc["problems"])
        self.assertIn("(0 infra, 1 timeout: AlphaTests,BetaTests)",
                      retry_msgs[0])
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")

    def test_allow_recovered_downgrades_a_lane_retry_healed_hang(self):
        """The flag's positive direction for hangs: the same lane-retry-
        healed hang that is fatal by default becomes PASS, with the caveat
        naming the downgrade it actually performed.
        """
        meta = json.loads(
            (self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["allowed_recovered_infrastructure"] = True
        write_json(self.run_dir / "meta.json", meta)
        self._lane_retry_healed_hang()
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")
        self.assertTrue(
            any("--allow-recovered-infrastructure" in c
                for c in doc["caveats"]),
            "the downgrade must be recorded as a caveat: {0}".format(
                doc["caveats"]))

    def test_an_incomplete_suite_heals_nothing_even_when_it_observed_the_work(self):
        """The round must leave its suite COMPLETE before it heals anything.

        Here the round re-ran exactly the batch its event names (coverage
        holds), yet a third class never executed anywhere: the suite is
        incomplete, so the event stays persistent and the run FAILS. This is
        what the per-suite `complete` conjunct is for - observation alone is
        not enough.
        """
        self._primary(observed=(), cases=0)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("AlphaTests", "BetaTests"), cases=2)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        unit_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if e.get("lane") == "unit"]
        self.assertTrue(unit_infra, doc["infrastructure"]["events"])
        self.assertFalse(
            any(e.get("recovered_by") == "gate recovery round"
                for e in unit_infra),
            "an incomplete suite may not heal even the work it observed")
        self.assertIn("GammaTests", doc["unit"]["classes_missing"])
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")

    def test_recurrence_after_recovery_fails_as_infrastructure(self):
        """The same class comes back after the round -> FAIL (infrastructure),
        and no third attempt is made."""
        self._primary(observed=("AlphaTests", "BetaTests"), cases=2)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="fail",
                       classes=(), cases=0, failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["GammaTests"],
                                 "timeout_s": 500, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0, "failures": 1}]}])
        self._wedge_log(self.run_dir / "lanes" / "unit-recovery")
        self._recovery_phase("pass")
        code, doc = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("same simulator launch-refusal class" in p
                            for p in doc["problems"]), doc["problems"])
        self.assertIn("GammaTests", doc["unit"]["classes_missing"])
        self.assertEqual(doc["infrastructure"]["retries"], 1)
        self.assertTrue(doc["infrastructure"]["persistent"] >= 1)

    def test_genuine_assertion_never_enters_recovery(self):
        """With a real assertion present the round is not even projected, and
        the gate fails on the assertion."""
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=3,
                       failures=[{"class": "BetaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        self._wedge_log(self.run_dir / "lanes" / "unit")
        code, doc = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["failures"], 1)
        self.assertEqual(doc["infrastructure"]["retries"], 0)
        self.assertFalse(os.path.isdir(self.run_dir / "lanes" / "unit-recovery"))

    def test_counts_are_not_double_counted_across_passes(self):
        """A class that a later pass re-reported is counted once, and the
        re-run is visible rather than silently buried."""
        self._primary(observed=("AlphaTests", "BetaTests", "GammaTests"), cases=3)
        # A recovery pass that re-ran everything (which the gate never does:
        # only uncompleted work is retried) must not inflate the total.
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=3)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["unit"]["executions"], 3,
                         "3 executions, not 6, across two passes")
        self.assertEqual(sorted(doc["unit"]["reread_classes"]),
                         ["AlphaTests", "BetaTests", "GammaTests"])
        self.assertTrue(any("more than one pass" in c for c in doc["caveats"]),
                        "the re-run is reported as a caveat, not hidden")

    def test_stale_not_executed_for_a_whole_batch_is_dropped(self):
        """A "not executed" entry names work as a batch ("A,B"), so it is only
        stale when BOTH classes have results - and the coverage check has to
        split the name to see that (a whole-string match never would)."""
        lane_artifacts(self.run_dir / "lanes" / "unit", status="fail",
                       classes=(), cases=0,
                       failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "not_run"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests"],
                            "timeout_s": 600, "status": "test-failures",
                            "attempts": [{"attempt": 1, "status": "test-failures",
                                          "seconds": 1.0, "failures": 1}]},
                           {"batch": 2, "classes": ["BetaTests", "GammaTests"],
                            "timeout_s": 500, "status": "not_run",
                            "attempts": []}])
        self._wedge_log(self.run_dir / "lanes" / "unit")
        # The continuation ran the batch the stopped lane never reached; the
        # round re-ran the batch 1 lost (so its event is healed too).
        lane_artifacts(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("BetaTests", "GammaTests"),
                       cases=2)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("AlphaTests",), cases=1)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["unit"]["not_executed"], [],
                         "both classes of the batch have results now")
        self.assertFalse(any("not executed" in p for p in doc["problems"]))

    def test_a_wedged_repetition_is_satisfied_by_its_one_retry(self):
        """A repetition lost to the launcher is retried once and counts as
        passed when that retry is clean - the wedge is not the test's fault."""
        self._primary(observed=("AlphaTests", "BetaTests", "GammaTests"), cases=3)
        meta = json.loads((self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["expected"]["repeat_classes"] = ["AlphaTests"]
        meta["expected"]["repeat_iterations"] = 1
        write_json(self.run_dir / "meta.json", meta)
        base = self.run_dir / "repeats" / "AlphaTests"
        lane_artifacts(base / "iter-1", status="fail", classes=(), cases=0,
                       failures=[{"class": "System Failures",
                                  "test": "Conduit encountered an error",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests"],
                                 "timeout_s": 600, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0, "failures": 1}]}])
        self._wedge_log(base / "iter-1")
        lane_artifacts(base / "iter-1-retry", status="pass",
                       classes=("AlphaTests",), cases=2)
        self._recovery_phase("pass")
        code, doc = self._summarize()
        entry = doc["focused_repeats"]["classes"][0]
        self.assertTrue(entry["iterations"][0]["satisfied"])
        self.assertEqual(entry["iterations"][0]["attempts_count"], 2)
        self.assertFalse(any("AlphaTests iteration 1" in p
                             for p in doc["problems"]), doc["problems"])

    def test_a_genuine_failure_is_final_across_attempts(self):
        """A genuine failing test is never satisfied by a later attempt: the
        repetition failed, and no retry may launder it."""
        self._primary(observed=("AlphaTests", "BetaTests", "GammaTests"), cases=3)
        meta = json.loads((self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["expected"]["repeat_classes"] = ["AlphaTests"]
        meta["expected"]["repeat_iterations"] = 1
        write_json(self.run_dir / "meta.json", meta)
        base = self.run_dir / "repeats" / "AlphaTests"
        lane_artifacts(base / "iter-1", status="fail",
                       classes=("AlphaTests",), cases=2,
                       failures=[{"class": "AlphaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        lane_artifacts(base / "iter-1-retry", status="pass",
                       classes=("AlphaTests",), cases=2)
        code, doc = self._summarize()
        entry = doc["focused_repeats"]["classes"][0]
        self.assertTrue(entry["iterations"][0]["genuine_failure"])
        self.assertFalse(entry["iterations"][0]["satisfied"])
        self.assertEqual(code, 1)
        self.assertTrue(any("genuine test failure" in p for p in doc["problems"]))

    def test_a_run_dir_named_recovery_cannot_fake_a_healed_round(self):
        """`_is_recovery_pass` matches a pass's directory BASENAME, never the
        run-dir path: otherwise --run-dir ~/gate-recovery/... would claim a
        round ran, let every test-runner failure be marked recovered, and turn
        a must-FAIL run into a PASS with an erase+retry that never happened.
        """
        # The whole fixture moves under a run-dir whose PATH contains the word
        # "recovery" - that is the mutation under test.
        target = Path(self.tmp.name) / "gate-recovery" / "run1"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(self.run_dir), str(target))
        self.run_dir = target
        # A complete unit lane with a launch-refusal event and NO recovery pass.
        self._primary(observed=("AlphaTests", "BetaTests", "GammaTests"), cases=3)
        code, doc = self._summarize()
        self.assertEqual(code, 1, doc["problems"])
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["infrastructure"]["persistent"], 1,
                         "an unhealed wedge must stay persistent")
        self.assertEqual(doc["infrastructure"]["retries"], 0,
                         "no recovery pass ran")
        self.assertFalse(any(e.get("recovered_by")
                             for e in doc["infrastructure"]["events"]
                             .get("infrastructure_failures", [])),
                         "nothing may claim the gate healed it")

    def test_gate_simulator_is_recorded(self):
        self._primary(observed=("AlphaTests", "BetaTests"), cases=2)
        lane_artifacts(self.run_dir / "lanes" / "unit-recovery", status="pass",
                       classes=("GammaTests",), cases=1)
        self._recovery_phase("pass")
        _, doc = self._summarize()
        self.assertEqual(doc["simulator"]["name"], "Conduit CI Gate")
        self.assertEqual(doc["simulator"]["udid"], "GATE-DEVICE")


class UIRecoveryVerdictTests(unittest.TestCase):
    """UI recovery is judged exactly like unit recovery.

    The shell writes a UI retry's evidence to lanes/ui-recovery; if the
    summarizer ignored it, recovered classes would be reported as never
    executed while the run's own recovery record claimed the opposite.
    """

    SHA = "1" * 40
    WEDGE_FAILURE = [{"class": "System Failures",
                      "test": "Conduit encountered an error", "attempts": []}]
    BUSY_LOG = ("Simulator device failed to launch com.milim.relay "
                "(BSErrorCodeDescription=Busy)")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run_dir = Path(self.tmp.name)
        # Two UI classes so a partial recovery is expressible.
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests", "BetaTests", "GammaTests"]},
            "ui": {"classes": ["LaunchUITests", "SettingsUITests"]},
        })
        write_json(self.run_dir / "meta.json", {
            "schema_version": 1, "requested_ref": "origin/main",
            "tested_sha": self.SHA, "xcode_version": "Xcode 27.0",
            "simulator": {"name": "Conduit CI Gate", "runtime": "iOS 26.5",
                          "udid": "6D08B063-B890-4D18-893B-D1E89E119919"},
            "started_at": "2026-09-22T00:00:00Z",
            "finished_at": "2026-09-22T01:00:00Z", "wall_s": 3600,
            "allowed_recovered_infrastructure": False,
            "static_checks_enabled": True, "repeat_policy_enabled": False,
            "run_flags": {"lock_used": True, "simulator_prep": True},
            "expected": {"unit_classes": 3, "unit_batches": 1, "ui_classes": 2,
                         "repeat_classes": [], "repeat_iterations": 0},
        })
        write_json(self.run_dir / "static" / "phase.json", {
            "schema_version": 1, "phase": "static", "status": "pass",
            "duration_s": 5, "checks": [{"name": "plan-validate",
                                         "status": "pass", "duration_s": 1}]})
        write_json(self.run_dir / "build" / "phase.json", {
            "schema_version": 1, "phase": "build", "status": "pass",
            "duration_s": 30, "details": {"xctestrun": "/tmp/x.xctestrun"}})
        write_workers(self.run_dir, [
            {"name": "unit", "device_name": "Conduit CI Gate",
             "udid": "6D08B063-B890-4D18-893B-D1E89E119919"},
            {"name": "ui", "device_name": "Conduit CI Gate",
             "udid": "6D08B063-B890-4D18-893B-D1E89E119919"},
        ])
        # A clean unit lane so only the UI suite decides the verdict.
        lane_artifacts(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=3, simulator=("Conduit CI Gate",
                                           "6D08B063-B890-4D18-893B-D1E89E119919"),
                       batches=[{"batch": 1,
                                          "classes": ["AlphaTests", "BetaTests",
                                                      "GammaTests"],
                                          "timeout_s": 600, "status": "pass",
                                          "attempts": [{"attempt": 1,
                                                        "status": "passed",
                                                        "seconds": 1.0,
                                                        "failures": 0}]}])
        # A round that did not run: the two recovery tests upgrade it below,
        # and a genuine failure must leave retries at 0.
        write_json(self.run_dir / "recovery" / "phase.json", {
            "schema_version": 1, "phase": "recovery", "status": "skipped",
            "duration_s": 0, "checks": []})

    def _wedge_lane(self, lane_dir, batch_classes=("LaunchUITests",
                                                   "SettingsUITests")):
        """A UI invocation the launcher refused, NAMING the work it lost.

        The name is what the round's evidence is judged against: the event is
        healed only when a UI recovery pass observed every class named here.
        """
        lane_artifacts(lane_dir, status="fail", classes=(), cases=0,
                       failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1,
                                 "classes": list(batch_classes),
                                 "timeout_s": 600, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0,
                                               "failures": 1}]}])
        logs = Path(lane_dir) / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "batch-a1.log").write_text(self.BUSY_LOG + chr(10),
                                           encoding="utf-8")

    def test_a_ui_shard_without_batches_is_named_by_its_declared_classes(self):
        """Production UI lanes write per-class invocations and an EMPTY
        `batches` array, so the shard-level item must be named by the lane's
        own declared classes: a synthetic "batch-1" name can never be covered
        by the round's evidence, and a healed UI run would then fail as
        persistent (the regression the Mac shell suite caught).
        """
        self._round_ran()
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=(), cases=0, batches=[],
                       lane_classes=("LaunchUITests", "SettingsUITests"),
                       failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "incomplete"},
                                 {"mode": "class", "n": 1,
                                  "class": "LaunchUITests",
                                  "status": "test-failures"}])
        logs = self.run_dir / "lanes" / "ui" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "batch-a1.log").write_text(self.BUSY_LOG + chr(10),
                                           encoding="utf-8")
        lane_artifacts(self.run_dir / "lanes" / "ui-recovery", status="pass",
                       classes=("LaunchUITests", "SettingsUITests"), cases=4)
        code, doc = self._summarize()
        ui_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if e.get("lane") == "ui"]
        self.assertTrue(ui_infra, doc["infrastructure"]["events"])
        self.assertTrue(
            all(e.get("recovered_by") == "gate recovery round"
                for e in ui_infra),
            "every UI event must name work the round re-ran: {0}".format(
                [(e.get("name"), e.get("recovered_by")) for e in ui_infra]))
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")

    def test_a_partially_healed_ui_shard_item_is_still_healed(self):
        """A mid-shard refusal can leave only SOME of the shard's classes
        missing. The item names the lane's declared classes, each of which ran
        as its own invocation: the round re-ran the missing one, so the item
        is covered (every named class has a result from some pass) and a
        legitimately healed shard is not reported persistent.
        """
        self._round_ran()
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=("LaunchUITests",), cases=1, batches=[],
                       lane_classes=("LaunchUITests", "SettingsUITests"),
                       failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "incomplete"},
                                 {"mode": "class", "n": 1,
                                  "class": "SettingsUITests",
                                  "status": "test-failures"}])
        logs = self.run_dir / "lanes" / "ui" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "batch-a1.log").write_text(self.BUSY_LOG + chr(10),
                                           encoding="utf-8")
        lane_artifacts(self.run_dir / "lanes" / "ui-recovery", status="pass",
                       classes=("SettingsUITests",), cases=2)
        code, doc = self._summarize()
        ui_infra = [
            e for e in doc["infrastructure"]["events"]["infrastructure_failures"]
            if e.get("lane") == "ui"]
        self.assertTrue(ui_infra, doc["infrastructure"]["events"])
        self.assertTrue(
            all(e.get("recovered_by") == "gate recovery round"
                for e in ui_infra),
            "the round re-ran the missing class - both events must be "
            "healed: {0}".format([(e.get("name"), e.get("recovered_by"))
                                  for e in ui_infra]))
        self.assertEqual(doc["ui"]["classes_missing"], [])
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")

    def _round_ran(self):
        write_json(self.run_dir / "recovery" / "phase.json", {
            "schema_version": 1, "phase": "recovery", "status": "pass",
            "duration_s": 0, "checks": [{"name": "round-1", "status": "pass",
                                         "duration_s": 0}]})

    def _summarize(self):
        out = self.run_dir / "gate-result.json"
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = local_gate.main(["summarize", "--run-dir", str(self.run_dir),
                                    "--out", str(out),
                                    "--markdown", str(self.run_dir / "summary.md")])
        self.human = buffer.getvalue()
        return code, json.loads(out.read_text(encoding="utf-8"))

    def test_ui_infrastructure_failure_recovered_by_the_round_passes(self):
        self._round_ran()
        self._wedge_lane(self.run_dir / "lanes" / "ui")
        lane_artifacts(self.run_dir / "lanes" / "ui-recovery", status="pass",
                       classes=("LaunchUITests", "SettingsUITests"), cases=4)
        code, doc = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")
        ui = doc["ui"]
        self.assertEqual(ui["classes_missing"], [],
                         "recovered classes must count as executed")
        self.assertEqual(ui["executions"], 4)
        self.assertTrue(any("recovery" in str(p.get("name"))
                            for p in ui["passes"]),
                        "the recovery pass must appear in the UI passes")
        self.assertEqual(doc["infrastructure"]["retries"], 1)
        self.assertEqual(ui["failures"], 0)

    def test_ui_recovery_that_recurs_fails_as_infrastructure(self):
        self._round_ran()
        self._wedge_lane(self.run_dir / "lanes" / "ui")
        self._wedge_lane(self.run_dir / "lanes" / "ui-recovery")
        code, doc = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["ui"]["classes_missing"],
                         ["LaunchUITests", "SettingsUITests"])
        self.assertGreaterEqual(doc["infrastructure"]["persistent"], 1)
        self.assertTrue(any("UI recovery round hit the same simulator" in p
                            for p in doc["problems"]), doc["problems"])
        self.assertEqual(doc["ui"]["failures"], 0,
                         "a wedge is never an assertion failure")

    def test_genuine_ui_assertion_is_not_recovered(self):
        # A product failure: no recovery pass exists, and the assertion stands.
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=("LaunchUITests",), cases=1,
                       failures=[{"class": "LaunchUITests",
                                  "test": "testLaunch", "attempts": []}],
                       attempts=[{"mode": "class", "n": 1,
                                  "class": "LaunchUITests",
                                  "status": "test-failures"}])
        code, doc = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["ui"]["failures"], 1)
        self.assertEqual(len(doc["ui"]["passes"]), 1,
                         "a genuine failure must not add a recovery pass")
        self.assertEqual(doc["infrastructure"]["retries"], 0)

    def test_only_the_failed_subset_is_recovered_without_double_counting(self):
        self._round_ran()
        # The shard ran LaunchUITests but was refused before SettingsUITests
        # produced results; the round retries only the incomplete class - and
        # the event names exactly that class, which is what it must do for
        # the round's own evidence to cover it.
        lane_artifacts(self.run_dir / "lanes" / "ui", status="fail",
                       classes=("LaunchUITests",), cases=1, batches=[],
                       failures=self.WEDGE_FAILURE,
                       attempts=[{"mode": "class", "n": 1,
                                  "class": "SettingsUITests",
                                  "status": "test-failures"}])
        logs = self.run_dir / "lanes" / "ui" / "logs"
        logs.mkdir(parents=True, exist_ok=True)
        (logs / "batch-a1.log").write_text(self.BUSY_LOG + chr(10),
                                           encoding="utf-8")
        lane_artifacts(self.run_dir / "lanes" / "ui-recovery", status="pass",
                       classes=("SettingsUITests",), cases=2)
        code, doc = self._summarize()
        ui = doc["ui"]
        self.assertEqual(ui["classes_missing"], [],
                         "completed only during recovery, so not unexecuted")
        # 1 case before + 2 after, counted once each: no class twice.
        self.assertEqual(ui["executions"], 3, ui.get("observed_names"))
        self.assertEqual(doc["infrastructure"]["retries"], 1)
        self.assertEqual(ui["failures"], 0)
        self.assertEqual(code, 0, doc["problems"])
        self.assertTrue(any("recovery" in c for c in doc.get("caveats", [])),
                        "the recovered run must carry a caveat")


class RecoverySpecTests(unittest.TestCase):
    """The bounded recovery round: what it is allowed for, and what it does."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plan_path = self.root / "plan.json"
        write_json(self.plan_path, make_plan())
        self.lane_dir = self.root / "lanes" / "unit"
        self.lane_dir.mkdir(parents=True, exist_ok=True)

    def _lane(self, *, status="fail", classes=("AlphaTests",), cases=4,
              failures=(), attempts=None, batches=None, log_lines=None):
        lane_artifacts(self.lane_dir, status=status, classes=classes,
                       cases=cases, failures=failures, attempts=attempts,
                       batches=batches)
        logs = self.lane_dir / "logs"
        logs.mkdir(exist_ok=True)
        for index, line in enumerate(log_lines or [], start=1):
            (logs / "batch-{0}-a1.log".format(index)).write_text(
                line + "\n", encoding="utf-8")

    WEDGE_FAILURE = [{"class": "System Failures",
                      "test": "Conduit encountered an error", "attempts": []}]
    BUSY_LOG = ['iOSSimulator: 6930ECCE: Failed to launch app with identifier: '
                'com.milim.relay (error = ... BSErrorCodeDescription=Busy)']
    WEDGE_ATTEMPTS = [{"mode": "batch", "n": 1, "class": "all",
                       "status": "test-failures"},
                      {"mode": "batch", "n": 2, "class": "all",
                       "status": "not_run"}]
    WEDGE_BATCHES = [
        {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
         "timeout_s": 600, "status": "test-failures",
         "attempts": [{"attempt": 1, "status": "test-failures",
                       "seconds": 1.0, "failures": 1}]},
        {"batch": 2, "classes": ["GammaTests"], "timeout_s": 500,
         "status": "not_run", "attempts": []},
    ]

    def _spec(self, **overrides):
        args = {"plan": str(self.plan_path), "lane": str(self.lane_dir),
                "out": str(self.root / "recovery.env")}
        args.update(overrides)
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = local_gate.main(["recovery-spec"] + [
                item for key, value in args.items() for item in ("--" + key, value)])
        values = {}
        env = self.root / "recovery.env"
        if env.exists():
            for line in env.read_text(encoding="utf-8").splitlines():
                key, _, value = line.partition("=")
                values[key] = shlex.split(value)[0] if value.strip() else ""
        return code, values

    def test_refused_when_a_genuine_assertion_is_present(self):
        """A product failure must never be retried around - the round is not
        even projected."""
        self._lane(classes=("AlphaTests", "BetaTests"), cases=7,
                   failures=[{"class": "BetaTests", "test": "testBoom",
                              "attempts": []}],
                   attempts=[{"mode": "batch", "n": 1, "class": "all",
                              "status": "test-failures"}],
                   log_lines=self.BUSY_LOG)
        code, _ = self._spec()
        self.assertEqual(code, 3)
        self.assertFalse((self.root / "recovery.env").exists())

    def test_refused_without_launch_refusal_evidence(self):
        """Infrastructure that is not the verified launch-refusal class is not
        recoverable: no synthetic entry, no Busy signature."""
        self._lane(status="fail", classes=("AlphaTests",), cases=1,
                   attempts=[{"mode": "batch", "n": 1, "class": "all",
                              "status": "unclassified"}])
        code, _ = self._spec()
        self.assertEqual(code, 3)

    def test_projects_the_incomplete_classes_for_the_wedge(self):
        self._lane(classes=("AlphaTests", "BetaTests"), cases=2,
                   failures=self.WEDGE_FAILURE, attempts=self.WEDGE_ATTEMPTS,
                   batches=self.WEDGE_BATCHES, log_lines=self.BUSY_LOG)
        code, values = self._spec()
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_RECOVERY_PRESENT"], "1")
        # Only work no pass completed: GammaTests (batch 2 never ran).
        self.assertEqual(values["GATE_RECOVERY_CLASSES"], "GammaTests")
        # The retry list is ONE TSV row: a single invocation for the whole
        # retry set (the wedge alternates per launch, so the round minimises
        # launches), carrying the planner's own batch budgets.
        tsv = (self.root / "recovery.tsv").read_text(encoding="utf-8").strip()
        self.assertEqual(tsv.count("\n") + 1, 1)
        self.assertTrue(tsv.startswith("retry-set\t"))
        self.assertIn('"timeout_s":500', tsv)

    def test_nothing_to_retry_when_everything_ran(self):
        self._lane(status="pass", classes=("AlphaTests", "BetaTests", "GammaTests"),
                   cases=3, log_lines=self.BUSY_LOG)
        code, values = self._spec()
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_RECOVERY_PRESENT"], "0")

    def test_ui_kind_projects_the_ui_classes(self):
        write_json(self.plan_path, make_plan())
        # The UI shard never launched, so no class has a result yet.
        self._lane(status="fail", classes=(), cases=0,
                   failures=self.WEDGE_FAILURE, batches=[],
                   attempts=[{"mode": "class", "n": 1, "class": "LaunchUITests",
                              "status": "test-failures"}],
                   log_lines=self.BUSY_LOG)
        code, values = self._spec(kind="ui")
        self.assertEqual(code, 0)
        self.assertEqual(values["GATE_RECOVERY_CLASSES"], "LaunchUITests")
        # The UI class's own watchdog travels with the retried class.
        self.assertIn("LaunchUITests=420", values["GATE_RECOVERY_CLASS_TIMEOUTS"])


class IsInfraOnlyTests(unittest.TestCase):
    """The gate's ONE retry decision point.

    A repeat iteration is re-run only when its failure is infrastructure; a
    genuine failing test is final. Both directions are pinned here, because a
    mutation either way would otherwise keep the whole suite green (the shell
    suite never drives a wedged repetition) while a real run either
    re-executed a genuine assertion or stopped retrying wedged repetitions.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.lane_dir = Path(self.tmp.name) / "lane"
        self.lane_dir.mkdir(parents=True, exist_ok=True)

    def _decide(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer), \
                contextlib.redirect_stderr(io.StringIO()):
            return local_gate.main(["is-infra-only",
                                    "--lane-dir", str(self.lane_dir)])

    def test_a_genuine_assertion_is_never_retryable(self):
        lane_artifacts(self.lane_dir, status="fail",
                       classes=("AlphaTests",), cases=2,
                       failures=[{"class": "AlphaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        self.assertEqual(self._decide(), 1,
                         "a genuine failing test must be final - never retried")

    def test_a_launch_wedge_is_retryable(self):
        lane_artifacts(self.lane_dir, status="fail",
                       classes=("AlphaTests",), cases=1,
                       failures=[{"class": "System Failures",
                                  "test": "Conduit encountered an error",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        logs = self.lane_dir / "logs"
        logs.mkdir(exist_ok=True)
        (logs / "batch-1-a1.log").write_text(
            "Simulator device failed to launch com.milim.relay "
            "(BSErrorCodeDescription=Busy)" + chr(10), encoding="utf-8")
        self.assertEqual(self._decide(), 0,
                         "the verified launch wedge is exactly what may be "
                         "retried once")

    def test_a_genuine_assertion_wins_over_simultaneous_wedge_evidence(self):
        """A genuine failure AND the Busy signature in the SAME lane: the
        genuine failure decides (exit 1, final). A mutation that consulted
        the infrastructure evidence first would hand a real failing test to
        the retry - the ordering itself is the invariant.
        """
        lane_artifacts(self.lane_dir, status="fail",
                       classes=("AlphaTests",), cases=2,
                       failures=[{"class": "AlphaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        logs = self.lane_dir / "logs"
        logs.mkdir(exist_ok=True)
        (logs / "batch-1-a1.log").write_text(
            "Simulator device failed to launch com.milim.relay "
            "(BSErrorCodeDescription=Busy)" + chr(10), encoding="utf-8")
        self.assertEqual(self._decide(), 1,
                         "a genuine failing test stays final even when the "
                         "launch wedge evidence is present beside it")

    def test_unclassifiable_infrastructure_is_retryable(self):
        lane_artifacts(self.lane_dir, status="fail",
                       classes=(), cases=0,
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "unclassified"}])
        self.assertEqual(self._decide(), 0)

    def test_a_clean_lane_is_not_retryable(self):
        lane_artifacts(self.lane_dir, status="pass",
                       classes=("AlphaTests",), cases=1)
        self.assertEqual(self._decide(), 1,
                         "there is nothing to retry in a clean lane")


class SimulatorTests(unittest.TestCase):
    def test_picks_newest_ios_runtime(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        devices = root / "devices.json"
        write_json(devices, {"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
                {"name": "iPhone 17 Pro", "udid": "OLD"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-10": [
                {"name": "iPhone 17 Pro", "udid": "NEW"}],
            "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [
                {"name": "iPhone 17 Pro", "udid": "WATCH"}],
        }})
        out = root / "simulator.json"
        code = local_gate.main(["simulator", "--devices", str(devices),
                                "--name", "iPhone 17 Pro", "--out", str(out)])
        self.assertEqual(code, 0)
        doc = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(doc["udid"], "NEW")
        self.assertEqual(doc["runtime"], "iOS 26.10")

    def test_missing_device_is_recorded_not_invented(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        devices = root / "devices.json"
        write_json(devices, {"devices": {}})
        out = root / "simulator.json"
        code = local_gate.main(["simulator", "--devices", str(devices),
                                "--name", "iPhone 17 Pro", "--out", str(out)])
        self.assertEqual(code, 0)
        doc = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(doc["udid"], "")
        self.assertEqual(doc["runtime"], "")


class SummarizeTests(unittest.TestCase):
    SHA = "1" * 40

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.run_dir = Path(self.tmp.name)

    def _layout(self, *, repeat_classes=("AlphaTests",), iterations=3,
                unit_classes=3, ui_classes=1, allow_recovered=False,
                static=True, unit_batches=1, mode="release", workers=2,
                unit_udid="U", ui_udid="U2", worker_overrides=None,
                lane_simulator="__default__"):
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests", "BetaTests", "GammaTests"]},
            "ui": ({"classes": ["LaunchUITests"]} if ui_classes else None),
        })
        meta = {
            "schema_version": 1,
            "requested_ref": "origin/main",
            "tested_sha": self.SHA,
            "xcode_version": "Xcode 27.0 Build version 27A1",
            "mode": mode,
            "workers": workers,
            "simulator": {"name": "iPhone 17 Pro", "runtime": "iOS 26.0",
                          "udid": unit_udid},
            "started_at": "2026-09-21T00:00:00Z",
            "finished_at": "2026-09-21T01:00:00Z",
            "wall_s": 3600,
            "allowed_recovered_infrastructure": allow_recovered,
            "static_checks_enabled": static,
            "repeat_policy_enabled": bool(repeat_classes) and iterations > 0,
            "expected": {
                "unit_classes": unit_classes,
                "unit_batches": unit_batches,
                "ui_classes": ui_classes,
                "repeat_classes": list(repeat_classes),
                "repeat_iterations": iterations,
            },
        }
        # A fanned-out run records its second project-owned device; a
        # one-worker run records none.
        if workers > 1:
            meta["simulator2"] = {"name": "iPhone 17 Pro 2",
                                  "runtime": "iOS 26.0", "udid": ui_udid}
        write_json(self.run_dir / "meta.json", meta)
        worker_records = [
            {"name": "unit", "device_name": "iPhone 17 Pro", "udid": unit_udid},
        ]
        if ui_classes:
            worker_records.append({
                "name": "ui", "device_name": "iPhone 17 Pro 2" if workers > 1 else "iPhone 17 Pro",
                "udid": ui_udid if workers > 1 else unit_udid})
        for override in (worker_overrides or []):
            for rec in worker_records:
                if rec["name"] == override.get("name"):
                    rec.update(override)
        write_workers(self.run_dir, worker_records)
        write_json(self.run_dir / "static" / "phase.json", {
            "schema_version": 1, "phase": "static", "status": "pass",
            "duration_s": 30, "checks": [
                {"name": "plan-validate", "status": "pass", "duration_s": 1},
                {"name": "ci-tooling-regression", "status": "pass", "duration_s": 20},
                {"name": "localization-coverage", "status": "pass", "duration_s": 2},
            ]})
        write_json(self.run_dir / "build" / "phase.json", {
            "schema_version": 1, "phase": "build", "status": "pass",
            "duration_s": 300,
            "details": {"xctestrun": "/tmp/derived-data/Conduit.xctestrun"}})
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       simulator=(("iPhone 17 Pro", unit_udid)
                                  if lane_simulator == "__default__"
                                  else lane_simulator),
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "pass",
                            "attempts": [{"attempt": 1, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "pass",
                            "attempts": [{"attempt": 1, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                       ])
        if ui_classes:
            self._lane(self.run_dir / "lanes" / "ui",
                           classes=("LaunchUITests",), cases=3,
                           simulator=((
                               "iPhone 17 Pro 2" if workers > 1 else "iPhone 17 Pro",
                               ui_udid if workers > 1 else unit_udid)
                               if lane_simulator == "__default__"
                               else lane_simulator))

    def _lane(self, lane_dir, **kwargs):
        """lane_artifacts with THIS fixture's devices filled in.

        Cases that rewrite a lane after _layout() must carry the same device
        evidence the layout wrote: the summarizer requires a fanned-out run's
        lanes to say which device they used, so a fixture that dropped it would
        be modelling an artifact the gate cannot produce.
        """
        lane_dir = Path(lane_dir)
        if "simulator" not in kwargs:
            if lane_dir.name.startswith("ui"):
                kwargs["simulator"] = ("iPhone 17 Pro 2", "U2")
            else:
                kwargs["simulator"] = ("iPhone 17 Pro", "U")
        return lane_artifacts(lane_dir, **kwargs)

    def _repeat_artifacts(self, klass, iterations, status="pass", cases=2,
                          **kwargs):
        for i in range(1, iterations + 1):
            self._lane(self.run_dir / "repeats" / klass / "iter-{0}".format(i),
                           status=status, classes=(klass,), cases=cases, **kwargs)

    def _summarize(self):
        out = self.run_dir / "gate-result.json"
        markdown = self.run_dir / "summary.md"
        # The human summary is part of the contract (it must name the tested
        # commit), so it is captured rather than left to clutter the suite
        # output.
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = local_gate.main(["summarize", "--run-dir", str(self.run_dir),
                                    "--out", str(out), "--markdown", str(markdown)])
        self.human_output = buffer.getvalue()
        doc = json.loads(out.read_text(encoding="utf-8"))
        return code, doc, markdown

    def test_clean_run_passes_with_counts(self):
        self._layout(unit_batches=2)
        self._repeat_artifacts("AlphaTests", 3)
        code, doc, markdown = self._summarize()
        self.assertEqual(code, 0)
        self.assertEqual(doc["verdict"], "PASS")
        self.assertEqual(doc["tested_sha"], self.SHA)
        self.assertEqual(doc["unit"]["executions"], 11)
        self.assertEqual(doc["unit"]["failures"], 0)
        self.assertEqual(doc["ui"]["executions"], 3)
        self.assertEqual(doc["ui"]["failures"], 0)
        self.assertEqual(doc["focused_repeats"]["executions"], 6)
        self.assertEqual(doc["focused_repeats"]["failures"], 0)
        self.assertEqual(doc["infrastructure"]["failures"], 0)
        self.assertFalse(doc["partial"])
        self.assertIn("PASS", markdown.read_text(encoding="utf-8"))
        # The result must name the exact tested commit, not just a ref.
        self.assertIn(self.SHA, self.human_output)
        self.assertIn(self.SHA, markdown.read_text(encoding="utf-8"))

    def test_mode_merge_is_complete_coverage_without_the_repeat_policy(self):
        """A merge run is not a degraded run - it is a different one.

        Its documented coverage is the complete unit + UI suites + static
        checks + bounded recovery; the repeat/stress layer belongs to the
        release mode. The artifact has to say which one it was, because a
        release head requires mode=release on its exact SHA.
        """
        self._layout(mode="merge", repeat_classes=(), iterations=0,
                     unit_batches=2)
        code, doc, markdown = self._summarize()
        self.assertEqual(code, 0, doc.get("problems"))
        self.assertEqual(doc["verdict"], "PASS")
        self.assertEqual(doc["mode"], "merge")
        # Complete coverage, and explicitly no repeat layer.
        self.assertEqual(doc["coverage"]["unit_suite"], "complete")
        self.assertEqual(doc["coverage"]["ui_suite"], "complete")
        self.assertTrue(doc["coverage"]["static_checks"])
        self.assertFalse(doc["coverage"]["repeat_policy"])
        self.assertEqual(doc["unit"]["classes_observed"], 3)
        self.assertEqual(doc["ui"]["classes_observed"], 1)
        # The absent repeat layer is the MODE's coverage, not a narrowing of
        # the run: marking it partial would misdescribe it as a run that was
        # cut short, and hide the real reason a release head still needs a
        # release run.
        self.assertFalse(doc["partial"])
        self.assertIn("merge", markdown.read_text(encoding="utf-8"))

    def test_disabled_repeat_policy_in_release_mode_is_still_partial(self):
        """The release mode's coverage includes the repeats: losing them there
        is a narrowing, and must be reported as one."""
        self._layout(mode="release", repeat_classes=(), iterations=0,
                     unit_batches=2)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc.get("problems"))
        self.assertTrue(doc["partial"])
        self.assertIn("repeat policy disabled", " ".join(doc["partial_reasons"]))

    def test_a_missing_worker_record_fails_the_gate(self):
        """A fanned-out run must prove every worker ran to completion."""
        self._layout(workers=2)
        write_workers(self.run_dir, [
            {"name": "unit", "device_name": "iPhone 17 Pro", "udid": "U"},
        ])
        code, doc, _ = self._summarize()
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("worker 'ui' has no record" in p
                            for p in doc["problems"]), doc["problems"])

    def test_a_worker_that_did_not_complete_fails_the_gate(self):
        self._layout(workers=2, worker_overrides=[
            {"name": "ui", "completed": False, "exit_code": "143"}])
        code, doc, _ = self._summarize()
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("worker 'ui' did not run to completion" in p
                            for p in doc["problems"]), doc["problems"])

    def test_a_worker_on_the_wrong_device_fails_the_gate(self):
        """The unit worker must hold the device the run assigned it; a worker
        that ran somewhere else means the run cannot certify what it tested."""
        self._layout(workers=2, worker_overrides=[
            {"name": "unit", "udid": "SOMEONE-ELSES-DEVICE"}])
        code, doc, _ = self._summarize()
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("worker 'unit' ran on device" in p
                            for p in doc["problems"]), doc["problems"])

    def test_a_lane_that_names_another_device_fails_the_gate(self):
        """The lane's OWN artifact has to agree with its worker's device."""
        self._layout(workers=2, lane_simulator=("iPhone 17 Pro", "NOT-THE-WORKER"))
        code, doc, _ = self._summarize()
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("the lane ran on device" in p
                            for p in doc["problems"]), doc["problems"])

    def test_a_lane_without_device_evidence_fails_the_gate(self):
        self._layout(workers=2, lane_simulator=None, unit_batches=2)
        code, doc, _ = self._summarize()
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("does not name the device it ran on" in p
                            for p in doc["problems"]), doc["problems"])

    def test_a_run_that_never_reached_the_lanes_is_not_asked_for_workers(self):
        """When the plan never got that far, the missing worker evidence is a
        symptom, not the finding: the report must name the real problem."""
        self._layout(workers=2, repeat_classes=(), unit_batches=2)
        (self.run_dir / "workers.tsv").unlink()
        shutil.rmtree(self.run_dir / "lanes")
        code, doc, _ = self._summarize()
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("unit lane results are missing" in p
                            for p in doc["problems"]), doc["problems"])
        self.assertFalse(any("worker evidence" in p for p in doc["problems"]),
                         doc["problems"])

    def test_two_workers_may_not_share_one_device(self):
        self._layout(workers=2, unit_udid="SAME", ui_udid="SAME")
        code, doc, _ = self._summarize()
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("SAME device" in p for p in doc["problems"]),
                        doc["problems"])

    def test_one_worker_runs_both_suites_on_the_primary_device(self):
        """--workers 1 keeps the complete coverage on ONE device."""
        self._layout(workers=1, repeat_classes=(), unit_batches=2)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc.get("problems"))
        self.assertEqual(doc["verdict"], "PASS")
        self.assertEqual(doc["coverage"]["workers"], 1)
        self.assertIsNone(doc["simulator2"])
        self.assertEqual([w["name"] for w in doc["workers"]], ["unit", "ui"])
        self.assertEqual({w["device"]["udid"] for w in doc["workers"]}, {"U"})

    def test_result_records_per_lane_timings_and_invocation_counts(self):
        """Where the wall clock went has to survive into the artifact: a green
        run that paid 20 xcodebuild invocations to execute 2 minutes of tests
        must be visible as such."""
        self._layout(unit_batches=2, repeat_classes=())
        # Two unit invocations (the fixture's batch logs) + one UI invocation.
        for lane, names in (("unit", ("batch-1-a1.log", "batch-2-a1.log")),
                            ("ui", ("batch-a1.log",))):
            logs = self.run_dir / "lanes" / lane / "logs"
            logs.mkdir(parents=True, exist_ok=True)
            for name in names:
                (logs / name).write_text("x", encoding="utf-8")
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc.get("problems"))
        self.assertEqual(doc["timing"]["lanes"]["unit"]["xcodebuild_invocations"], 2)
        self.assertEqual(doc["timing"]["lanes"]["ui"]["xcodebuild_invocations"], 1)
        self.assertEqual(doc["timing"]["xcodebuild_invocations"], 3)
        self.assertEqual(doc["timing"]["lanes"]["unit"]["simulator"]["udid"], "U")
        self.assertIn("static", doc["timing"]["phases"])

    def test_repeat_timings_are_keyed_per_class_and_iteration(self):
        """Every class repeats as iter-1..iter-N, so keying the repeat timings
        by directory basename would collapse them onto three keys and report a
        fraction of the run's real invocation count."""
        self._layout(repeat_classes=("AlphaTests", "BetaTests"), iterations=2,
                     unit_batches=2)
        for klass in ("AlphaTests", "BetaTests"):
            self._repeat_artifacts(klass, 2)
            for i in (1, 2):
                logs = self.run_dir / "repeats" / klass / "iter-{0}".format(i) / "logs"
                logs.mkdir(parents=True, exist_ok=True)
                (logs / "batch-1-a1.log").write_text("x", encoding="utf-8")
        # The two primary lanes' own invocations, so the total is the run's.
        for lane, names in (("unit", ("batch-1-a1.log", "batch-2-a1.log")),
                            ("ui", ("batch-a1.log",))):
            logs = self.run_dir / "lanes" / lane / "logs"
            logs.mkdir(parents=True, exist_ok=True)
            for name in names:
                (logs / name).write_text("x", encoding="utf-8")
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc.get("problems"))
        self.assertEqual(sorted(doc["timing"]["repeats"]),
                         ["AlphaTests/iter-1", "AlphaTests/iter-2",
                          "BetaTests/iter-1", "BetaTests/iter-2"])
        # 2 unit batches + 1 UI invocation + 4 repetitions.
        self.assertEqual(doc["timing"]["xcodebuild_invocations"], 7)

    def test_a_repetition_on_the_wrong_device_fails_the_gate(self):
        """Repetitions are unit-worker work: their device is checked like any
        other lane's, or one could run elsewhere and still certify."""
        self._layout(repeat_classes=("AlphaTests",), iterations=2, unit_batches=2)
        self._repeat_artifacts("AlphaTests", 2,
                               simulator=("iPhone 17 Pro 2", "U2"))
        code, doc, _ = self._summarize()
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertTrue(any("iter-1: the lane ran on device" in p
                            for p in doc["problems"]), doc["problems"])

    def test_an_unknown_worker_name_is_recorded_but_not_required(self):
        """A future gate may add a worker; the summarizer must not fail a run
        for evidence it does not yet model, but it must still verify the
        workers it DOES require."""
        self._layout(workers=2, repeat_classes=(), unit_batches=2)
        write_workers(self.run_dir, [
            {"name": "unit", "device_name": "iPhone 17 Pro", "udid": "U"},
            {"name": "ui", "device_name": "iPhone 17 Pro 2", "udid": "U2"},
            {"name": "extra", "device_name": "iPhone 17 Pro 3", "udid": "U3"},
        ])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc.get("problems"))
        self.assertEqual(sorted(w["name"] for w in doc["workers"]),
                         ["extra", "ui", "unit"])

    def test_a_prior_run_for_the_same_sha_is_a_caveat(self):
        """The (SHA, mode) registry allows exactly one escalation; a result
        that is not the first attempt for its SHA has to say so where it is
        cited from."""
        self._layout(repeat_classes=(), unit_batches=2)
        meta_path = self.run_dir / "meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        meta["prior_runs"] = 1
        meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc.get("problems"))
        self.assertTrue(any("not the first attempt" in c for c in doc["caveats"]),
                        doc["caveats"])

    def test_assertion_failure_is_reported_as_assertion(self):
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit",
                       status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       failures=[{"class": "BetaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "test-failures",
                                 "attempts": [{"attempt": 1,
                                               "status": "test-failures",
                                               "seconds": 1.0, "failures": 1}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["unit"]["failures"], 1)
        self.assertTrue(doc["unit"]["assertion_failures"])
        # An assertion failure must never be dressed up as infrastructure.
        self.assertEqual(doc["infrastructure"]["failures"], 0)

    def test_infrastructure_failure_is_reported_as_infrastructure(self):
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, failures=[],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "infra-error"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "infra-error",
                                 "attempts": [{"attempt": 1,
                                               "status": "infra-error",
                                               "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["unit"]["failures"], 0, "no test asserted anything")
        self.assertEqual(doc["infrastructure"]["failures"], 1)

    def test_recovered_infrastructure_fails_by_default(self):
        """A recovered wedge means the run is not trustworthy evidence; the
        operator reruns it. Only the explicit opt-in downgrades it."""
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, retried=("BetaTests",),
                       infra_recovered=("BetaTests",),
                       attempts=[
                           {"mode": "batch", "n": 1, "class": "all",
                            "status": "infra-error"},
                           {"mode": "batch-retry", "n": 1, "class": "all",
                            "status": "passed"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "pass",
                                 "attempts": [
                                     {"attempt": 1, "status": "infra-error",
                                      "seconds": 1.0, "failures": 0},
                                     {"attempt": 2, "status": "passed",
                                      "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["infrastructure"]["recovered"], 1)
        # `infrastructure.retries` counts the GATE's bounded recovery round; the
        # lane runner's own retry attempts are reported in events.
        self.assertEqual(doc["infrastructure"]["retries"], 0)
        self.assertEqual(len(doc["infrastructure"]["events"]["retries"]), 1)

    def test_recovered_infrastructure_may_be_allowed_explicitly(self):
        self._layout(repeat_classes=(), allow_recovered=True)
        self._lane(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, infra_recovered=("BetaTests",),
                       retried=("BetaTests",),
                       attempts=[
                           {"mode": "batch", "n": 1, "class": "all",
                            "status": "infra-error"},
                           {"mode": "batch-retry", "n": 1, "class": "all",
                            "status": "passed"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "pass",
                                 "attempts": [
                                     {"attempt": 1, "status": "infra-error",
                                      "seconds": 1.0, "failures": 0},
                                     {"attempt": 2, "status": "passed",
                                      "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertEqual(doc["verdict"], "PASS")
        self.assertEqual(doc["infrastructure"]["recovered"], 1)

    def test_assertion_retried_until_green_always_fails(self):
        self._layout(repeat_classes=(), allow_recovered=True)
        self._lane(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       failures=[{"class": "BetaTests", "test": "testFlimsy",
                                  "attempts": []}],
                       attempts=[
                           {"mode": "batch", "n": 1, "class": "all",
                            "status": "test-failures"},
                           {"mode": "batch-retry", "n": 1, "class": "all",
                            "status": "passed"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "pass",
                                 "attempts": [
                                     {"attempt": 1, "status": "test-failures",
                                      "seconds": 1.0, "failures": 2},
                                     {"attempt": 2, "status": "passed",
                                      "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["assertion_rerun_until_green"], 1)
        self.assertTrue(any("retried until they passed" in p
                            for p in doc["problems"]))

    def test_test_runner_launch_failure_is_infrastructure_not_an_assertion(self):
        """Regression: the first real gate run reported "genuine XCTest
        assertion failures present" for a Simulator that refused to launch the
        test host. The result bundle's only "failure" was XCTest's synthetic
        System Failures entry, which reports the RUN, not a test."""
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       failures=[{"class": "System Failures",
                                  "test": "Conduit encountered an error",
                                  "attempts": [{"result": "Failed",
                                                "seconds": 0.0}]}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "passed"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "test-failures"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests"], "timeout_s": 600,
                            "status": "pass",
                            "attempts": [{"attempt": 1, "status": "passed",
                                          "seconds": 1.0, "failures": 0}]},
                           {"batch": 2, "classes": ["BetaTests", "GammaTests"],
                            "timeout_s": 600, "status": "test-failures",
                            "attempts": [{"attempt": 1, "status": "test-failures",
                                          "seconds": 1.0, "failures": 1}]},
                       ])
        # The per-invocation extraction parts are what attribute the synthetic
        # failure to the invocation that produced it.
        parts = self.run_dir / "lanes" / "unit" / "parts"
        write_json(parts / "detail-batch-1-a1.json",
                   {"schema_version": 1, "failures": [], "attempts": []})
        write_json(parts / "detail-batch-2-a1.json",
                   {"schema_version": 1, "attempts": [], "failures": [
                       {"class": "System Failures",
                        "test": "Conduit encountered an error", "attempts": []}]})
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["verdict"], "FAIL")
        self.assertEqual(doc["unit"]["failures"], 0,
                         "no test asserted anything")
        self.assertEqual(doc["unit"]["synthetic_failures"], 1)
        self.assertTrue(doc["infrastructure"]["failures"] >= 1)
        self.assertTrue(any("never started the app" in p for p in doc["problems"]),
                        doc["problems"])
        self.assertFalse(any("genuine XCTest assertion failures" in p
                             for p in doc["problems"]))

    def test_real_failure_beside_a_synthetic_one_is_still_an_assertion(self):
        self._layout(repeat_classes=())
        # The merged detail document is the UNION of the per-invocation parts
        # (that is what the runner's merge-parts produces), so it carries both
        # entries while the parts attribute each one to its invocation.
        self._lane(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11,
                       failures=[{"class": "BetaTests", "test": "testBoom",
                                  "attempts": []},
                                 {"class": "System Failures",
                                  "test": "Simulator died", "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        parts = self.run_dir / "lanes" / "unit" / "parts"
        write_json(parts / "detail-batch-1-a1.json",
                   {"schema_version": 1, "attempts": [], "failures": [
                       {"class": "BetaTests", "test": "testBoom", "attempts": []},
                       {"class": "System Failures", "test": "Simulator died",
                        "attempts": []}]})
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["failures"], 1)
        self.assertEqual(doc["unit"]["synthetic_failures"], 1)
        self.assertTrue(doc["unit"]["assertion_failures"])
        self.assertTrue(any("genuine XCTest assertion failures" in p
                            for p in doc["problems"]))

    def test_unexecuted_batches_are_continued_and_merged(self):
        """One failing batch must not hide the rest of the suite: the shell
        runs the never-reached batches as a continuation, and the aggregate
        coverage is what the gate certifies."""
        self._layout(repeat_classes=(), unit_batches=2)
        # The failing batch reports the classes it DID run (observations),
        # which is what makes the aggregate coverage check meaningful: the
        # never-reached class is the one in the batch the lane stopped before.
        self._lane(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests"),
                       cases=4,
                       failures=[{"class": "AlphaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "not_run"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "test-failures",
                            "attempts": [{"attempt": 1, "status": "test-failures",
                                          "seconds": 1.0, "failures": 1}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "not_run", "attempts": []},
                       ])
        self._lane(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("GammaTests",), cases=3)
        code, doc, _ = self._summarize()
        # Still a FAIL (a real assertion failed), but now complete: every
        # planned class has a result and the verdict names the real failure.
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["classes_missing"], [])
        self.assertEqual(doc["unit"]["classes_observed"], 3)
        self.assertEqual(doc["unit"]["executions"], 7)
        self.assertEqual(doc["unit"]["failures"], 1)
        # The continuation is pass 1 of the merged passes, and it executed the
        # class the primary lane never reached.
        self.assertEqual(doc["unit"]["passes"][1]["executions"], 3)
        self.assertEqual(doc["unit"]["reread_classes"], [])
        self.assertFalse(any("classes never executed" in p
                             for p in doc["unit"]["problems"]))

    def test_persistent_infrastructure_fails_even_when_recovery_is_allowed(self):
        """The opt-in is about recovered anomalies; a persistent one is
        never acceptable evidence."""
        self._layout(repeat_classes=(), allow_recovered=True)
        self._lane(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, failures=[], persistent_infra=("BetaTests",),
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "infra-error"},
                                 {"mode": "batch-retry", "n": 1, "class": "all",
                                  "status": "infra-error"}],
                       batches=[{"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                                 "timeout_s": 600, "status": "infra-error",
                                 "attempts": [
                                     {"attempt": 1, "status": "infra-error",
                                      "seconds": 1.0, "failures": 0},
                                     {"attempt": 2, "status": "infra-error",
                                      "seconds": 1.0, "failures": 0}]}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["infrastructure"]["persistent"], 1)
        self.assertEqual(doc["infrastructure"]["recovered"], 0)

    def test_recovered_label_the_chain_cannot_explain_fails_closed(self):
        """The lane runner's own recovered-class label without matching
        attempt evidence means the record is incomplete - that is not a
        clean run."""
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, infra_recovered=("GammaTests",))
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("does not account for" in p for p in doc["problems"]))

    def test_missing_classes_fail_completeness(self):
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests"), cases=7)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertIn("GammaTests", doc["unit"]["classes_missing"])
        self.assertTrue(any("never executed" in p for p in doc["problems"]))

    def test_unreadable_extraction_fails_closed(self):
        """No observations.json means the execution count cannot be
        certified; a green lane verdict alone is not enough."""
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, observations=False)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertIsNone(doc["unit"]["executions"])

    def test_missing_lane_result_fails_closed(self):
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, lane_result=False)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["status"], "missing")

    def test_short_sha_fails(self):
        self._layout(repeat_classes=())
        meta = json.loads((self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["tested_sha"] = "deadbee"
        write_json(self.run_dir / "meta.json", meta)
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("40-character" in p for p in doc["problems"]))

    def test_repeat_iteration_missing_fails(self):
        self._layout()
        self._repeat_artifacts("AlphaTests", 2)  # policy said 3
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertIn("iterations", " ".join(doc["problems"]))

    def test_repeat_assertion_failure_fails(self):
        self._layout()
        self._repeat_artifacts("AlphaTests", 3)
        self._lane(self.run_dir / "repeats" / "AlphaTests" / "iter-2",
                       status="fail", classes=("AlphaTests",), cases=2,
                       failures=[{"class": "AlphaTests", "test": "testFlake",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"}])
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["focused_repeats"]["failures"], 1)

    def test_failed_static_phase_fails_the_gate(self):
        self._layout(repeat_classes=())
        write_json(self.run_dir / "static" / "phase.json", {
            "schema_version": 1, "phase": "static", "status": "fail",
            "duration_s": 30, "checks": [
                {"name": "localization-coverage", "status": "fail",
                 "duration_s": 2}]})
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("localization-coverage" in p for p in doc["problems"]))

    def test_skipped_static_marks_the_run_partial(self):
        self._layout(repeat_classes=(), static=False)
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0)
        self.assertTrue(doc["partial"])
        self.assertTrue(any("static checks skipped" in r
                            for r in doc["partial_reasons"]))

    def test_disabled_repeat_policy_passes_but_is_flagged_partial(self):
        """Explicitly narrowing the gate is allowed; pretending the narrowed
        run was the exhaustive one is not."""
        self._layout(repeat_classes=(), iterations=0)
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0)
        self.assertFalse(doc["focused_repeats"]["enabled"])
        self.assertTrue(doc["partial"])
        self.assertTrue(any("repeat policy disabled" in r
                            for r in doc["partial_reasons"]))
        self.assertIn("PARTIAL", self.human_output)

    def test_missing_plan_projection_is_a_problem_not_a_crash(self):
        """meta.json carries class COUNTS, not names: with no projection the
        gate cannot check coverage, and it must say so rather than crash or
        wave the run through."""
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        (self.run_dir / "lanes.json").unlink()
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("planned class list is missing" in p
                            for p in doc["problems"]))

    def test_projection_count_mismatch_is_a_problem(self):
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests"]},
            "ui": {"classes": ["LaunchUITests"]},
        })
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("lists 1 classes but the run recorded 3" in p
                            for p in doc["problems"]),
                        doc["problems"])

    def test_ui_classes_without_a_lane_is_a_problem(self):
        """A planner regression that dropped the UI lane must not read as a
        clean 'ui: skipped' pass when UI classes were expected."""
        self._layout(repeat_classes=(), ui_classes=1)
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        write_json(self.run_dir / "lanes.json", {
            "schema_version": 1,
            "unit": {"classes": ["AlphaTests", "BetaTests", "GammaTests"]},
            "ui": None,
        })
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("planned no UI lane" in p for p in doc["problems"]))

    def test_a_failed_lane_verdict_always_fails_the_gate(self):
        """The runner's own verdict is evidence in its own right: green-looking
        event classification must not be able to contradict it."""
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(any("lane runner verdict is 'fail'" in p
                            for p in doc["problems"]), doc["problems"])

    def test_ui_diagnosis_parts_are_attributed_to_their_class(self):
        """The runner writes UI diagnosis parts as detail-<Cls>-a<k>.json (no
        'class-' infix). Without that key the synthetic launch failure in a
        shard that ALSO has a real failure would be mislabeled as an
        assertion."""
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "ui", status="fail",
                       classes=("LaunchUITests",), cases=2,
                       failures=[{"class": "System Failures",
                                  "test": "Conduit encountered an error",
                                  "attempts": []}],
                       attempts=[{"mode": "class", "n": 1,
                                  "class": "LaunchUITests",
                                  "status": "test-failures"}],
                       batches=[])
        parts = self.run_dir / "lanes" / "ui" / "parts"
        write_json(parts / "detail-LaunchUITests-a1.json",
                   {"schema_version": 1, "attempts": [], "failures": [
                       {"class": "System Failures",
                        "test": "Conduit encountered an error", "attempts": []}]})
        # The unit lane is metric-neutral for this test: make it clean.
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["ui"]["synthetic_failures"], 1)
        self.assertTrue(doc["ui"]["infrastructure_failures"],
                        "the launch failure must be infrastructure, not an assertion")
        self.assertFalse(doc["ui"]["assertion_failures"])

    def test_ui_shard_targeted_retry_is_seen_as_one_work_item(self):
        """A UI shard has ONE batch, but its targeted retry is recorded under
        batch-retry with n=2: the two must be read as the same work item, or
        "failed an assertion then passed" is reported as a plain assertion."""
        self._layout(repeat_classes=())
        self._lane(self.run_dir / "lanes" / "ui", status="pass",
                       classes=("LaunchUITests",), cases=2,
                       failures=[{"class": "LaunchUITests",
                                  "test": "testSomething", "attempts": []}],
                       attempts=[
                           {"mode": "batch", "n": 1, "class": "all",
                            "status": "test-failures"},
                           {"mode": "batch-retry", "n": 2, "class": "all",
                            "status": "passed"}],
                       batches=[])
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertTrue(doc["assertion_rerun_until_green"] >= 1,
                        "the retried assertion must be reported as rerun-until-green")
        self.assertTrue(any("retried until they passed" in p
                            for p in doc["problems"]))

    def test_continuation_clears_stale_not_executed_evidence(self):
        """After the continuation runs the never-reached batches, the report
        must not still claim that work was not executed."""
        self._layout(repeat_classes=(), unit_batches=2)
        self._lane(self.run_dir / "lanes" / "unit", status="fail",
                       classes=("AlphaTests", "BetaTests"), cases=4,
                       failures=[{"class": "AlphaTests", "test": "testBoom",
                                  "attempts": []}],
                       attempts=[{"mode": "batch", "n": 1, "class": "all",
                                  "status": "test-failures"},
                                 {"mode": "batch", "n": 2, "class": "all",
                                  "status": "not_run"}],
                       batches=[
                           {"batch": 1, "classes": ["AlphaTests", "BetaTests"],
                            "timeout_s": 600, "status": "test-failures",
                            "attempts": [{"attempt": 1, "status": "test-failures",
                                          "seconds": 1.0, "failures": 1}]},
                           {"batch": 2, "classes": ["GammaTests"],
                            "timeout_s": 500, "status": "not_run", "attempts": []},
                       ])
        self._lane(self.run_dir / "lanes" / "unit-continuation",
                       status="pass", classes=("GammaTests",), cases=3)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["unit"]["not_executed"], [])
        self.assertEqual(doc["infrastructure"]["not_executed"], 0)
        self.assertFalse(any("not executed" in p for p in doc["unit"]["problems"]),
                         doc["unit"]["problems"])

    def test_weakening_flags_are_recorded_as_caveats(self):
        self._layout(repeat_classes=(), allow_recovered=True)
        meta = json.loads((self.run_dir / "meta.json").read_text(encoding="utf-8"))
        meta["run_flags"] = {"lock_used": False, "simulator_prep": False}
        write_json(self.run_dir / "meta.json", meta)
        self._lane(self.run_dir / "lanes" / "unit", status="pass",
                       classes=("AlphaTests", "BetaTests", "GammaTests"),
                       cases=11, infra_recovered=("BetaTests",))
        code, doc, markdown = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        caveats = " ".join(doc["caveats"])
        self.assertIn("--no-lock", caveats)
        self.assertIn("--no-simulator-prep", caveats)
        self.assertIn("--allow-recovered-infrastructure", caveats)
        self.assertIn("CAVEAT", markdown.read_text(encoding="utf-8"))

    def test_failed_simulator_preparation_is_a_caveat(self):
        self._layout(repeat_classes=())
        write_json(self.run_dir / "sim-prep" / "phase.json", {
            "schema_version": 1, "phase": "sim-prep", "status": "fail",
            "duration_s": 0, "checks": [
                {"name": "unit", "status": "fail", "duration_s": 12}]})
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 0, doc["problems"])
        self.assertTrue(any("Simulator preparation failed before unit" in c
                            for c in doc["caveats"]), doc["caveats"])

    def test_failed_build_fails_the_gate(self):
        self._layout(repeat_classes=(), ui_classes=0)
        write_json(self.run_dir / "build" / "phase.json", {
            "schema_version": 1, "phase": "build", "status": "fail",
            "duration_s": 60, "note": "no .xctestrun produced"})
        self._lane(self.run_dir / "lanes" / "unit",
                       classes=("AlphaTests", "BetaTests", "GammaTests"), cases=11)
        code, doc, _ = self._summarize()
        self.assertEqual(code, 1)
        self.assertEqual(doc["build"]["status"], "fail")


class ScriptContractTests(unittest.TestCase):
    """The gate script and its helper must stay wired to each other and to
    the existing tooling they reuse."""

    def setUp(self):
        self.script = Path(SCRIPTS_DIR) / "local-ci-gate.sh"
        if not self.script.exists():
            self.skipTest("local-ci-gate.sh not present")
        self.text = self.script.read_text(encoding="utf-8")

    def test_reuses_the_existing_lane_runner_and_planner(self):
        self.assertIn("ci-test-lane.sh", self.text)
        self.assertIn("plan-tests.py", self.text)
        self.assertIn("ci-build-for-testing.sh", self.text)

    def test_is_exhaustive_single_lane(self):
        self.assertIn("--min-lanes 1 --max-lanes 1", self.text)
        self.assertIn("--ui-min-lanes 1 --ui-max-lanes 1", self.text)

    def test_never_retries_genuine_assertions(self):
        # --iterations 1 is what removes Xcode's native retry from the gate.
        self.assertIn("--iterations 1", self.text)
        self.assertNotIn("--iterations 3", self.text)

    def test_uses_a_detached_throwaway_worktree(self):
        self.assertIn("worktree add --detach", self.text)
        self.assertIn("worktree remove --force", self.text)

    def test_the_gate_is_single_shot_and_never_restarts_itself(self):
        """One authoritative full-gate invocation per requested SHA.

        Whatever drives the gate must not be able to loop it into "until
        green": the script never re-executes itself after a verdict, and a
        second full run for a SHA that already has a result is refused unless
        the caller explicitly asks for one.
        """
        self.assertIn("--allow-another-run", self.text)
        self.assertIn("one authoritative full-gate invocation per requested SHA",
                      self.text)
        # No self-invocation and no self-re-exec anywhere in the RUNNABLE
        # body (the usage banner legitimately names the script).
        body = self.text.split("usage() {", 1)[-1].split("}", 1)[-1]
        for forbidden in ('bash "$0"', "bash $0", "exec bash", 'exec "$0"',
                          "local-ci-gate.sh", "while true"):
            self.assertNotIn(forbidden, body,
                             "the gate must be a single-shot program")
        # The verdict path exits exactly once, at the end.
        self.assertIn("exit 0", self.text)
        self.assertIn("exit 1", self.text)

    def test_no_bare_empty_array_expansions_survive(self):
        """`${arr[@]}` on an empty array is fatal under Bash 3.2 + set -u.

        The safe form is `${arr[@]+"${arr[@]}"}`, whose INNER half looks
        exactly like a bare expansion - so comments and that inner half are
        skipped here and only a genuinely unguarded use is reported. Running
        on a host with bash >= 4.4 cannot catch a regression (4.4 accepts the
        bare form), so the source itself is the contract.
        """
        import re
        import os as _os
        bare = re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}")
        for name in ("local-ci-gate.sh", "ci-gate-lock.sh"):
            path = _os.path.join(SCRIPTS_DIR, name)
            if not _os.path.exists(path):
                continue
            offenders = []
            with open(path, encoding="utf-8") as fh:
                for number, line in enumerate(fh, start=1):
                    if line.lstrip().startswith("#"):
                        continue
                    for match in bare.finditer(line):
                        if line[:match.start()].endswith('+"'):
                            continue  # the inner half of the safe form
                        offenders.append("{0}:{1}".format(name, number))
            self.assertEqual(offenders, [],
                             name + " has a bare empty-array expansion; "
                             "use the ${arr[@]+guard} form at " +
                             ", ".join(offenders))

    def test_never_stashes_or_touches_the_invoking_tree(self):
        for forbidden in ("git stash", "git checkout", "git reset",
                          "worktree prune", "git clean"):
            self.assertNotIn(forbidden, self.text)

    def test_requires_an_exact_ref(self):
        self.assertIn("--ref is required", self.text)

    def test_modes_are_explicit_and_default_to_the_strongest(self):
        """Both certificates are exact-SHA and host-coordinated; only their
        coverage differs, and the artifact says which one ran."""
        self.assertIn("--mode", self.text)
        self.assertIn('MODE="release"', self.text)
        self.assertIn("--mode must be 'merge' or 'release'", self.text)
        # The mode decides the repeat DEFAULT only - an explicit request wins.
        self.assertIn("REPEAT_ITERATIONS_SET", self.text)
        self.assertIn("REPEAT_CLASSES_SET", self.text)

    def test_mode_is_recorded_in_meta_and_the_sha_registry(self):
        """One authoritative run per (SHA, mode): a merge result must not block
        the release run for the same SHA, and neither may be re-run."""
        self.assertIn("registry_covers", self.text)
        self.assertIn("mode_strength", self.text)
        self.assertIn('--mode "$MODE"', self.text)
        self.assertIn('"$SHA" "$MODE"', self.text)

    def test_fans_out_over_two_project_owned_devices(self):
        """Two workers, one host lease, two UDIDs: the unit work and the UI
        work run concurrently, each on its own device."""
        self.assertIn("--second-simulator", self.text)
        self.assertIn('SIMULATOR_NAME2="$SIMULATOR_NAME 2"', self.text)
        self.assertIn("WORKERS=2", self.text)
        self.assertIn("start_worker unit", self.text)
        self.assertIn("start_worker ui", self.text)
        # The two devices must be distinct and both UDID-pinned.
        self.assertIn("--second-simulator must differ from --simulator", self.text)
        self.assertIn("refusing to run two workers on one device", self.text)
        self.assertIn("SIMULATOR2_UDID", self.text)

    def test_workers_are_reaped_and_recorded(self):
        """A torn-down run must not leave a live test chain behind, and the
        run directory must carry the per-worker evidence."""
        self.assertIn("WORKER_PIDS", self.text)
        self.assertIn("record_workers", self.text)
        self.assertIn("workers.tsv", self.text)
        self.assertIn("XCODEBUILD_POLL_INTERVAL_S", self.text)

    def test_static_checks_overlap_by_default_and_can_be_forced_serial(self):
        self.assertIn("--static-serial", self.text)
        self.assertIn("STATIC_OVERLAP=1", self.text)
        self.assertIn("overlapped_with_lanes", self.text)

    def test_unit_batch_size_is_passed_to_the_planner(self):
        """The batch layout stays the planner's policy; the gate only moves the
        chunk size it was measured at."""
        self.assertIn("--unit-batch-max-classes", self.text)
        self.assertIn("UNIT_BATCH_MAX_CLASSES=28", self.text)

    def test_no_global_simulator_shutdown_anywhere(self):
        """Automation never shuts down every device on the shared host."""
        self.assertNotIn("shutdown all", self.text)
        self.assertNotIn("erase all", self.text)

    def test_a_static_check_that_wrote_no_record_fails_the_phase(self):
        """A phase that quietly certified two of its three checks would be
        exactly the gap this gate exists to refuse: a check killed before it
        wrote its record must read as a failure, not as an omission."""
        self.assertIn("$name:missing:0", self.text)


class PythonCompatibilityTests(unittest.TestCase):
    def test_helper_compiles_under_the_ci_interpreter(self):
        path = os.path.join(SCRIPTS_DIR, "local-gate.py")
        with open(path, encoding="utf-8") as fh:
            source = fh.read()
        compile(source, path, "exec")


if __name__ == "__main__":
    unittest.main()
