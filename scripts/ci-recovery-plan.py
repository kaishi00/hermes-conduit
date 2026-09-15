#!/usr/bin/env python3
"""Plan the fresh-runner recovery matrix from finished unit lane artifacts.

Runs on ubuntu after the original unit matrix completes (workflow job
`unit-recovery-plan`, `if: always()`). Reads every `lane-unit-*` artifact's
lane-result.json, classifies each lane via scripts/ci_lane_recovery.py
(single source of truth, cross-checked against the classification embedded
at write time), and emits a GitHub Actions matrix that re-runs ONLY the
recoverable lanes - each as a new macos-26 job (fresh hosted runner) with
the EXACT original lane inputs.

The plan artifact remains the authority for lane membership: every recovery
entry is rebuilt from plan.json, never copied out of failed-run metadata,
and every lane result must agree with the plan (kind, membership, target,
watchdog) or this script fails closed. Missing/undecidable metadata also
fails closed - an unknown lane state must never turn into a recovery.

An empty matrix is the healthy outcome: no recoverable lanes, nothing to
re-run. When the unit matrix never ran (skipped/cancelled upstream), the
matrix is also empty and the CI Gate fails the run on the coarse checks.

Stdlib only; deterministic for identical inputs.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ci_lane_recovery

EXIT_OK = 0
EXIT_FAIL_CLOSED = 1


def warn(msg: str) -> None:
    print(f"::warning::ci-recovery-plan: {msg}", file=sys.stderr)


def fail(msg: str) -> None:
    print(f"::error::ci-recovery-plan: {msg}", file=sys.stderr)


def load_plan(path) -> dict:
    with open(path, encoding="utf-8") as fh:
        plan = json.load(fh)
    if not isinstance(plan, dict) or not isinstance(plan.get("unit_lanes"), list):
        raise ValueError("plan artifact has no unit_lanes list")
    return plan


def recovery_matrix_entry(plan: dict, lane: str) -> dict:
    """The COMPLETE original lane inputs for one lane, rebuilt from the
    plan (same shape as plan-tests.py matrix_json). A plan entry missing
    any required field fails closed with a precise message instead of a
    traceback."""
    entry = next((e for e in plan["unit_lanes"] if e.get("lane") == lane), None)
    if entry is None:
        raise ValueError(f"plan has no entry for lane {lane!r}")
    estimates = plan.get("estimates")
    missing = [c for c in entry.get("classes", [])
               if not isinstance(estimates, dict) or c not in estimates]
    if missing:
        raise ValueError(
            f"plan is missing estimates for classes: {', '.join(missing)}")
    for field in ("target", "predicted_s", "timeout_s", "job_timeout_min"):
        if entry.get(field) is None:
            raise ValueError(f"plan entry for lane {lane!r} lacks {field!r}")
    return {
        "lane": entry["lane"],
        "target": entry["target"],
        "classes": ",".join(entry["classes"]),
        "class_estimates": ",".join(
            "{0}={1:.1f}".format(c, estimates[c]) for c in entry["classes"]),
        "predicted_s": entry["predicted_s"],
        "timeout_s": entry["timeout_s"],
        "job_timeout_min": entry["job_timeout_min"],
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan-json", required=True)
    parser.add_argument("--lanes-dir", required=True,
                        help="directory of extracted lane-unit-* artifacts")
    parser.add_argument("--unit-result", required=True,
                        help="needs.unit.result (success|failure|skipped|cancelled)")
    parser.add_argument("--matrix-out", required=True)
    args = parser.parse_args(argv)

    empty = {"include": []}
    if args.unit_result not in ("success", "failure"):
        # The unit matrix never ran (build failed -> skipped, or the run was
        # cancelled). There is nothing to recover and no artifacts to trust;
        # the empty matrix lets the workflow finish while the CI Gate fails
        # the run on its coarse checks.
        print(f"unit matrix result is {args.unit_result!r}; nothing to recover")
        with open(args.matrix_out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(empty, sort_keys=False) + "\n")
        return EXIT_OK

    try:
        plan = load_plan(args.plan_json)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        fail(f"plan artifact unreadable ({exc}) - failing closed")
        return EXIT_FAIL_CLOSED

    records = ci_lane_recovery.scan_lane_results(args.lanes_dir)
    for record in records:
        if record.doc is None:
            fail(f"unreadable lane result {record.path}: {record.error}")
    unit_docs, conflicts = ci_lane_recovery.dedupe_lane_results(records)
    for problem in conflicts:
        fail(problem)
    failed_closed = bool(conflicts) or any(r.doc is None for r in records)

    include = []
    for entry in plan["unit_lanes"]:
        lane = entry.get("lane")
        record = unit_docs.get(lane)
        if record is None:
            fail(f"lane {lane}: no lane-result artifact found - failing closed")
            failed_closed = True
            continue
        mismatches = ci_lane_recovery.plan_disagreements(
            entry, record.doc, record, primary=True)
        if mismatches:
            fail(f"lane {lane}: lane result disagrees with the plan: "
                 + "; ".join(mismatches) + " - failing closed")
            failed_closed = True
            continue
        embedded = ci_lane_recovery.embedded_classification(record.doc)
        classification, reason = ci_lane_recovery.classify_lane_result(record.doc)
        if embedded is None:
            fail(f"lane {lane}: lane result has no embedded recovery "
                 "classification (fail closed)")
            failed_closed = True
            continue
        if embedded != classification:
            fail(f"lane {lane}: embedded classification {embedded!r} != "
                 f"re-derived {classification!r} (fail closed)")
            failed_closed = True
            continue
        print(f"lane {lane}: {classification} ({reason})")
        if classification == ci_lane_recovery.CLASS_RECOVERABLE_TIMEOUT_ZERO_FAILURES:
            try:
                include.append(recovery_matrix_entry(plan, lane))
            except ValueError as exc:
                fail(str(exc) + " - failing closed")
                failed_closed = True
                continue

    if failed_closed:
        return EXIT_FAIL_CLOSED

    # Self-check: every recovery lane must exist in the plan exactly once.
    planned_lanes = [e.get("lane") for e in plan["unit_lanes"]]
    for item in include:
        if item["lane"] not in planned_lanes:
            fail(f"recovery lane {item['lane']!r} is not in the plan - failing closed")
            return EXIT_FAIL_CLOSED
    if len(include) > len(planned_lanes):
        fail("more recovery lanes than planned lanes - failing closed")
        return EXIT_FAIL_CLOSED

    with open(args.matrix_out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps({"include": include}, sort_keys=False) + "\n")
    if include:
        print(f"fresh-runner recovery needed for: "
              f"{', '.join(item['lane'] for item in include)}")
    else:
        print("every unit lane finished green (or finally red); no recovery needed")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
