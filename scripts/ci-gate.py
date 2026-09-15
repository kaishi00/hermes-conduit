#!/usr/bin/env python3
"""CI Gate: the single stable branch-protection verdict for Hermes Conduit.

The unit-test matrix is dynamically sized (1-8 lanes), so individual lane
jobs must never be required directly. This job aggregates the upstream
results into one stable status context ("CI Gate").

Policy (v3 - lane-adjudicated unit verdicts):

  plan / build / self-test        must be success
  recovery-plan (unit-recovery-plan)
                                  must be success (it runs `if: always()`;
                                  any other outcome is an unadjudicated run)
  unit                            must be success OR failure - a failure is
                                  redeemable ONLY through the per-lane
                                  adjudication below (a fresh-runner
                                  recovery); cancelled/skipped fail the gate
  recovery (unit-recovery)        success / failure / skipped are all
                                  adjudicable; anything else fails
  ui                              must be success or skipped (skipped is
                                  legitimate when the repo contains no UI
                                  test classes)

The unit verdict itself is adjudicated PER LANE from artifacts against the
plan (scripts/ci_lane_recovery.py):

  original lane PASS                     -> accepted
  original recoverable stall (watchdog
    timeout, zero identified failures)
    AND exactly one fresh-runner PASS    -> accepted (recovered)
  recoverable stall, recovery missing /
    fails / times out                    -> FAIL
  original test failure                  -> FAIL (never recovered)
  original unknown/unclassifiable or
    plan disagreement                    -> FAIL (fail closed)
  fresh-runner result for an unplanned
    lane, or ambiguous duplicates        -> FAIL

Every planned lane must end with exactly one accepted disposition; missing
lanes, unreadable/malformed artifacts, and recovery results outside the
plan fail closed. A raw needs.unit.result == "failure" therefore does NOT
by itself fail the gate: a lane red for infrastructure that passed on its
one fresh-runner retry is a recovered PASS.

Duplicates: within one attempt the workflow structurally produces at most
one recovery result per lane. A sanctioned re-run of a FAILED recovery leg
uploads a new attempt artifact, and the newest finished_at supersedes the
older one - the same rule the primary lane results follow. Only genuinely
ambiguous duplicates (identical finished_at, differing documents) fail
closed.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ci_lane_recovery

REQUIRED_SUCCESS = ("plan", "build", "self-test", "recovery-plan")
UNIT_ALLOWED = ("success", "failure")
RECOVERY_ALLOWED = ("success", "failure", "skipped")
UI_ALLOWED = ("success", "skipped")


def verdict(plan: str, build: str, unit: str, ui: str, self_test: str,
            recovery_plan: str, recovery: str,
            adjudication: ci_lane_recovery.Adjudication) -> tuple:
    """Return (passed, reason). Reason lists every violated expectation."""
    results = {"plan": plan, "build": build, "ui": ui, "self-test": self_test,
               "recovery-plan": recovery_plan}
    failures = []
    for name in REQUIRED_SUCCESS:
        if results[name] != "success":
            failures.append(f"{name} must be 'success', got {results[name]!r}")
    if results["ui"] not in UI_ALLOWED:
        failures.append(
            f"ui must be 'success' or 'skipped', got {results['ui']!r}")
    if unit not in UNIT_ALLOWED:
        failures.append(
            f"unit must be 'success' or 'failure' (adjudicated per lane), "
            f"got {unit!r}")
    if recovery not in RECOVERY_ALLOWED:
        failures.append(
            f"unit-recovery must be 'success', 'failure' or 'skipped', "
            f"got {recovery!r}")
    if adjudication is None:
        failures.append("unit lane adjudication did not run (missing artifacts?)")
    else:
        failures.extend(adjudication.failures)
        if (unit == "failure" and recovery == "skipped" and adjudication.passed):
            # The only legitimate path to a green unit adjudication next to
            # needs.unit.result == 'failure' is a redeemed recovery (and
            # then recovery != 'skipped'). Anything else is contradictory
            # input - fail closed rather than guess.
            failures.append(
                "unit reported failure but every lane artifact is green "
                "with no fresh-runner recovery - inconsistent results "
                "(fail closed)")
    return (not failures), "; ".join(failures)


def _load_plan(path):
    with open(path, encoding="utf-8") as fh:
        plan = json.load(fh)
    if not isinstance(plan, dict) or not isinstance(plan.get("unit_lanes"), list):
        raise ValueError("plan artifact has no unit_lanes list")
    return plan


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--ui", required=True)
    parser.add_argument("--self-test", required=True)
    parser.add_argument("--recovery-plan", required=True,
                        help="needs.unit-recovery-plan.result")
    parser.add_argument("--recovery", required=True,
                        help="needs.unit-recovery.result")
    parser.add_argument("--plan-json", required=True,
                        help="downloaded plan.json (lane-membership authority)")
    parser.add_argument("--unit-lanes-dir", required=True,
                        help="directory of extracted lane-unit-* artifacts")
    parser.add_argument("--recovery-lanes-dir", required=True,
                        help="directory of extracted lane-recovery-* artifacts")
    args = parser.parse_args(argv)

    adjudication = None
    try:
        plan_doc = _load_plan(args.plan_json)
        all_records = ci_lane_recovery.scan_lane_results(args.unit_lanes_dir) + \
            ci_lane_recovery.scan_lane_results(args.recovery_lanes_dir)
        # Partition BEFORE dedupe: a lane's recovery document shares the lane
        # name with its primary document and must never collapse into it.
        unit_records = [r for r in all_records
                        if r.doc is None or not r.doc.get("fresh_runner_recovery")]
        recovery_records = [r for r in all_records
                            if r.doc is not None and r.doc.get("fresh_runner_recovery")]
        unit_docs, conflicts = ci_lane_recovery.dedupe_lane_results(unit_records)
        recovery_deduped, recovery_conflicts = \
            ci_lane_recovery.dedupe_lane_results(recovery_records)
        recovery_groups = {lane: [record]
                           for lane, record in recovery_deduped.items()}
        adjudication = ci_lane_recovery.adjudicate_unit_lanes(
            plan_doc, unit_docs, recovery_groups)
        # Ambiguous artifacts (same-stamp, differing documents) fail the
        # gate: the final verdict must never rest on an unorderable guess.
        for problem in conflicts + recovery_conflicts:
            adjudication.fail(problem)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"::error::CI Gate: lane adjudication failed closed: {exc}")

    passed, reason = verdict(args.plan, args.build, args.unit, args.ui,
                             args.self_test, args.recovery_plan, args.recovery,
                             adjudication)

    if adjudication is not None:
        print("Unit lane dispositions:")
        for disposition in adjudication.dispositions:
            print(f"  {ci_lane_recovery.disposition_line(disposition)}")

    if passed:
        print("CI Gate: PASS (plan/build/self-test/recovery-plan succeeded; "
              f"unit lanes adjudicated green; ui {args.ui!r}; "
              f"unit-recovery {args.recovery!r})")
        return 0
    print(f"CI Gate: FAIL - {reason}")
    print("::error::CI Gate failed: " + reason)
    return 1


if __name__ == "__main__":
    sys.exit(main())
