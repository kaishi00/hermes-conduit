#!/usr/bin/env python3
"""Local exhaustive gate helpers for Hermes Conduit (see docs/CI.md).

`scripts/local-ci-gate.sh` owns the orchestration (worktree isolation, build
once, phase sequencing). This script owns everything that is *data*: it
projects the planner's plan into the exact invocation parameters the existing
lane runner wants, and it assembles the machine-readable gate result from the
artifacts the lane runner already writes.

Nothing here re-implements test discovery, batching, watchdog policy, or
xcresult parsing - those stay owned by plan-tests.py, ci-test-lane.sh and
extract-test-timings.py. This file only *projects* their outputs and *reads*
their results, so the gate cannot drift from the policy they enforce.

Subcommands
-----------
lanes          Project plan.json into lane-runner parameters for the gate's
               single unit lane and single UI lane.
repeat-spec    Project plan.json into per-class repeat tasks (explicit repeat
               policy for timing/performance-sensitive classes).
meta           Write the run's identity document (ref, resolved SHA, Xcode,
               simulator, expected counts, flags).
simulator      Pick the simulator/device the run actually used out of
               `xcrun simctl list devices available -j`.
phase          Write one non-lane phase's status document.
summarize      Assemble gate-result.json + summary.md, and exit 0 only when
               the whole gate passed.

Exit codes: 0 ok, 1 verdict FAIL, 2 usage error, 3 malformed artifact.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys

SCHEMA_VERSION = 1

# Attempt-status tokens emitted by ci-test-lane.sh (record_attempt /
# record_batch_attempt). The gate must classify on the runner's own tokens
# rather than re-deriving a verdict from logs.
ASSERTION_FAILURE_STATUSES = ("test-failures",)
# Environment/classification failures: the invocation did not produce a
# usable "this test asserted" verdict. ci-test-lane.sh only ever records
# `infra-error` for a nonzero exit with a KNOWN zero failing-test count;
# `unclassified`/`incomplete` mean the result could not be read at all.
INFRASTRUCTURE_STATUSES = ("infra-error", "unclassified", "incomplete")
TIMEOUT_STATUSES = ("timeout",)
NOT_EXECUTED_STATUSES = ("not_run", "not_diagnosed")
# Modes that mean "this was a second attempt at work a previous attempt
# already ran" (the runner's bounded recovery, never a policy of its own).
RETRY_MODES = ("batch-retry", "class-retry")

# XCTest does NOT only report real test cases. When the test host cannot be
# installed or launched (a wedged or "Busy" Simulator refusing
# com.milim.relay, a crashed test runner, a missing binary) the result bundle
# carries a synthetic entry under the pseudo-class "System Failures" -
# observed in the gate's first real run: class "System Failures", test
# "Conduit encountered an error", with the launch refusal in the log. Such an
# entry is NOT a test asserting anything, and counting it as an assertion
# failure is exactly the mislabeling the gate exists to prevent: it would
# report "genuine XCTest assertion failures present" for a machine that never
# managed to start the app.
SYNTHETIC_FAILURE_CLASSES = ("System Failures",)
# Belt and braces for the same condition: if a future Xcode renames or
# localizes the pseudo-class, the entry NAME is still the runner/launch
# failure the invocation reported.
SYNTHETIC_FAILURE_TESTS = (
    "encountered an error",
    "failed to install or launch the test runner",
)

REPEAT_BATCH_TIMEOUT_CAP_DEFAULT = 900

HEX40 = re.compile(r"^[0-9a-f]{40}$")
# The lane runner's per-invocation extraction part names; the group captures
# the same "class" key extract-test-timings.py's _part_class derives.
PART_NAME = re.compile(r"^detail-(?P<key>.+?)-a\d+\.json$")


def is_synthetic_failure(entry) -> bool:
    """True when a failure entry is XCTest reporting the RUN (not a test):
    reported under its pseudo-class, or naming the runner/launch failure."""
    if not isinstance(entry, dict):
        return False
    if str(entry.get("class") or "") in SYNTHETIC_FAILURE_CLASSES:
        return True
    test = str(entry.get("test") or "")
    for marker in SYNTHETIC_FAILURE_TESTS:
        if marker in test:
            # Only when it does NOT name a real test case: "testX()" style
            # entries always come from the bundle's test tree.
            return "." not in test and "()" not in test
    return False


def split_failures(failures):
    """Split extracted failures into (real_test_failures, synthetic).

    The extraction is the only place the distinction survives: the lane
    runner's own batch status cannot tell them apart (it counts failing
    entries), so the gate classifies here instead of trusting that token.
    """
    real, synthetic = [], []
    for entry in failures if isinstance(failures, list) else []:
        (synthetic if is_synthetic_failure(entry) else real).append(entry)
    return real, synthetic


def warn(msg: str) -> None:
    print("local-gate: warning: {0}".format(msg), file=sys.stderr)


def fail(msg: str) -> None:
    print("local-gate: error: {0}".format(msg), file=sys.stderr)


def load_json(path: str):
    """Best-effort read. Returns None for anything unusable - every caller
    treats a missing artifact as "not certifiable", never as "fine"."""
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_json(path: str, doc) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")


def write_env(path: str, mapping) -> None:
    """Write a shell-sourceable KEY=value file.

    Values are shell-quoted with shlex.quote, so a class name can never
    become code in the gate shell even though the names ultimately come from
    the repository's own sources.
    """
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for key in sorted(mapping):
            fh.write("{0}={1}\n".format(key, shlex.quote(str(mapping[key]))))


def _csv(values) -> str:
    return ",".join(values)


def _split_classes(raw: str):
    """Parse a comma-separated class list. Whitespace around entries is
    tolerated ("A, B") because the repeat policy is hand-edited; empty
    entries are dropped."""
    return [c.strip() for c in str(raw or "").split(",") if c.strip()]


def _single_lane(plan: dict, key: str) -> dict:
    """The gate runs the whole suite as exactly ONE lane per kind. The plan
    is generated with --min-lanes/--max-lanes forced to 1, so anything else
    is a policy violation and must fail closed."""
    lanes = plan.get(key)
    if not isinstance(lanes, list):
        return {}
    if len(lanes) != 1:
        return {}
    return lanes[0] if isinstance(lanes[0], dict) else {}


# ---------------------------------------------------------------------------
# lanes
# ---------------------------------------------------------------------------

def cmd_lanes(args) -> int:
    plan = load_json(args.plan)
    if not isinstance(plan, dict):
        fail("plan not readable: {0}".format(args.plan))
        return 3

    unit = _single_lane(plan, "unit_lanes")
    if not unit or not unit.get("classes") or not unit.get("batches"):
        fail("plan must carry exactly one unit lane with a batch layout "
             "(generate it with --min-lanes 1 --max-lanes 1)")
        return 3
    ui = _single_lane(plan, "ui_lanes")

    unit_classes = list(unit.get("classes") or [])
    ui_classes = list(ui.get("classes") or [])
    env = {
        "GATE_UNIT_PRESENT": 1,
        "GATE_UNIT_LANE": unit.get("lane") or "unit-1",
        "GATE_UNIT_TARGET": unit.get("target") or "ConduitTests",
        "GATE_UNIT_CLASSES": _csv(unit_classes),
        "GATE_UNIT_CLASS_COUNT": len(unit_classes),
        "GATE_UNIT_BATCH_COUNT": int(unit.get("batch_count") or len(unit["batches"])),
        "GATE_UNIT_BATCHES_JSON": json.dumps(unit["batches"], separators=(",", ":")),
        "GATE_UNIT_PREDICTED": unit.get("predicted_s") or 0,
        "GATE_UNIT_TIMEOUT": int(unit.get("timeout_s") or 0),
        "GATE_UI_PRESENT": 1 if ui_classes else 0,
    }
    if ui_classes:
        env.update({
            "GATE_UI_LANE": ui.get("lane") or "ui-1",
            "GATE_UI_TARGET": ui.get("target") or "ConduitUITests",
            "GATE_UI_CLASSES": _csv(ui_classes),
            "GATE_UI_CLASS_COUNT": len(ui_classes),
            "GATE_UI_CLASS_TIMEOUTS": ui.get("class_timeouts") or "",
            "GATE_UI_CLASS_ESTIMATES": ui.get("class_estimates") or "",
            "GATE_UI_PREDICTED": ui.get("predicted_s") or 0,
            "GATE_UI_TIMEOUT": int(ui.get("timeout_s") or 0),
        })
    # The audit copy is written where the shell says, not at a name derived
    # from the env file: the summarizer reads it back by that exact path to
    # check completeness against what was planned, so the two paths must not
    # be able to drift apart.
    write_env(args.out, env)
    write_json(args.json_out or (os.path.splitext(args.out)[0] + ".json"), {
        "schema_version": SCHEMA_VERSION,
        "unit": {
            "lane": env["GATE_UNIT_LANE"],
            "target": env["GATE_UNIT_TARGET"],
            "classes": unit_classes,
            "batches": unit["batches"],
            "batch_count": env["GATE_UNIT_BATCH_COUNT"],
            "predicted_s": env["GATE_UNIT_PREDICTED"],
            "timeout_s": env["GATE_UNIT_TIMEOUT"],
        },
        "ui": ({
            "lane": env["GATE_UI_LANE"],
            "target": env["GATE_UI_TARGET"],
            "classes": ui_classes,
            "class_timeouts": env["GATE_UI_CLASS_TIMEOUTS"],
            "predicted_s": env["GATE_UI_PREDICTED"],
            "timeout_s": env["GATE_UI_TIMEOUT"],
        } if ui_classes else None),
    })
    print("gate lanes: {0} unit classes in {1} batches, {2} UI classes".format(
        len(unit_classes), env["GATE_UNIT_BATCH_COUNT"], len(ui_classes)))
    return 0


# ---------------------------------------------------------------------------
# repeat-spec
# ---------------------------------------------------------------------------

def cmd_repeat_spec(args) -> int:
    """Project the repeat policy into per-class single-class lane tasks.

    The repeat policy is a GATE concept (see docs/CI.md): a class that has
    historically failed in ways that depend on scheduling is executed K
    times unconditionally and must pass every time. Repetition is therefore
    NOT the lane runner's retry (the gate calls it with --iterations 1, so
    Xcode never re-runs a failing test), and the watchdog ceiling is the
    planner's own batch budget for that class, capped by --timeout-cap so a
    single hung iteration cannot burn an unbounded wall clock.
    """
    plan = load_json(args.plan)
    if not isinstance(plan, dict):
        fail("plan not readable: {0}".format(args.plan))
        return 3
    unit = _single_lane(plan, "unit_lanes")
    if not unit or not unit.get("batches"):
        fail("plan must carry exactly one unit lane with a batch layout")
        return 3

    batches = unit["batches"]
    classes = _split_classes(args.classes)
    tasks = []
    missing = []
    duplicate = []
    for name in classes:
        found = None
        hits = 0
        for batch in batches:
            if name in (batch.get("classes") or []):
                hits += 1
                if found is None:
                    found = batch
        if found is None:
            missing.append(name)
            continue
        if hits > 1:
            # The planner partitions each class into exactly one batch today;
            # if that ever stops holding, the repeat budget would silently be
            # the wrong batch's.
            duplicate.append(name)
        budget = int(found.get("timeout_s") or 0)
        capped = min(budget, args.timeout_cap) if args.timeout_cap > 0 else budget
        tasks.append({
            "class": name,
            "target": unit.get("target") or "ConduitTests",
            "predicted_s": found.get("predicted_s") or 0,
            "timeout_s": capped,
            "planner_batch_timeout_s": budget,
            "timeout_capped": capped != budget,
        })
    if missing:
        # Fail closed: a repeat class that no longer exists in the plan means
        # the repeat policy silently stopped covering what it promises to
        # cover - that is a gate defect, not something to warn past.
        fail("repeat classes not present in the plan's unit lane: {0}".format(
            _csv(missing)))
        return 3
    if duplicate:
        warn("repeat classes appear in more than one planned batch (using the "
             "first batch's budget): {0}".format(_csv(duplicate)))

    write_json(args.out, {
        "schema_version": SCHEMA_VERSION,
        "timeout_cap_s": args.timeout_cap,
        "iterations": args.iterations,
        "tasks": tasks,
    })
    # TSV the shell reads line by line (same idiom as the runner's own
    # batch-plan.txt): class, batches-json, predicted_s, timeout_s. The shell
    # passes this path explicitly so the two sides cannot disagree about it.
    tsv = args.tsv_out or (os.path.splitext(args.out)[0] + ".tsv")
    with open(tsv, "w", encoding="utf-8", newline="\n") as fh:
        for task in tasks:
            batches_json = json.dumps(
                [{"classes": [task["class"]],
                  "predicted_s": task["predicted_s"],
                  "timeout_s": task["timeout_s"]}],
                separators=(",", ":"))
            fh.write("{0}\t{1}\t{2}\t{3}\n".format(
                task["class"], batches_json, task["predicted_s"],
                task["timeout_s"]))
    print("repeat policy: {0} class(es) x {1} iterations".format(
        len(tasks), args.iterations))
    return 0


def cmd_not_run_batches(args) -> int:
    """Project the batches a stopped unit lane never executed.

    A unit lane stops at the batch that failed, so a single failure would
    otherwise hide the rest of the suite: the gate runs those batches as a
    CONTINUATION pass so the report still covers every class. This is a
    diagnostic continuation, never a retry - the batches that already ran
    (including the one that failed) are never re-executed here.

    The continuation reuses the PLANNER's own batch objects (predicted_s,
    timeout_s) looked up by index, so its watchdogs carry the same policy as
    the lane it continues rather than a formula invented here.
    """
    plan = load_json(args.plan)
    lane_result = load_json(args.lane_result)
    if not isinstance(plan, dict) or not isinstance(lane_result, dict):
        fail("plan or lane result not readable")
        return 3
    unit = _single_lane(plan, "unit_lanes")
    planned = unit.get("batches") if unit else None
    recorded = lane_result.get("batches")
    if not isinstance(planned, list) or not isinstance(recorded, list):
        fail("plan/lane result carry no batch layout to continue from")
        return 3

    indices = []
    for batch in recorded:
        if isinstance(batch, dict) and str(batch.get("status")) == "not_run":
            idx = _int_or_zero(batch.get("batch"))
            if 1 <= idx <= len(planned):
                indices.append(idx)
    env = {"GATE_CONT_PRESENT": 0}
    if indices:
        selected = [planned[i - 1] for i in indices]
        env = {
            "GATE_CONT_PRESENT": 1,
            "GATE_CONT_BATCH_INDICES": _csv(str(i) for i in indices),
            "GATE_CONT_BATCH_COUNT": len(selected),
            "GATE_CONT_CLASSES": _csv(
                [c for b in selected for c in (b.get("classes") or [])]),
            "GATE_CONT_BATCHES_JSON": json.dumps(selected, separators=(",", ":")),
            "GATE_CONT_PREDICTED": sum(
                _num_or_zero(b.get("predicted_s")) for b in selected),
            "GATE_CONT_TIMEOUT": int(sum(
                _num_or_zero(b.get("timeout_s")) for b in selected)),
        }
    write_env(args.out, env)
    print("unit continuation: {0} batch(es) never executed{1}".format(
        len(indices), " (" + _csv(str(i) for i in indices) + ")" if indices else ""))
    return 0


def _num_or_zero(value) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def cmd_recovery_spec(args) -> int:
    """Project the bounded recovery round's retry list.

    The recovery is allowed for exactly one infrastructure class: the
    simulator/host-app launch refusal (XCTest's synthetic "System Failures"
    entry, and/or the verified Busy signature in the lane's log). A genuine
    assertion anywhere in the run disqualifies the round entirely - a real
    failure is never retried.

    The retry list is "every class the plan promised that no pass has produced
    a result for". Rework that already reported a result (passing or genuinely
    failed) is never re-executed, which is what makes the aggregate execution
    count exact across passes.
    """
    plan = load_json(args.plan)
    if not isinstance(plan, dict):
        fail("plan not readable: {0}".format(args.plan))
        return 3
    kind = "ui" if args.kind == "ui" else "unit"
    ui = kind == "ui"
    lane = _single_lane(plan, "ui_lanes" if ui else "unit_lanes")
    if not lane or not lane.get("classes"):
        fail("plan must carry exactly one {0} lane with classes".format(kind))
        return 3
    if ui and not lane.get("batches"):
        # The UI lane runs one batched invocation; its per-class watchdogs are
        # the planner's table, which travels with the lane.
        if not lane.get("class_timeouts"):
            fail("plan's UI lane carries no per-class watchdog table")
            return 3
    elif not lane.get("batches"):
        fail("plan must carry exactly one unit lane with a batch layout")
        return 3

    batches = lane.get("batches") or []
    planned = list(lane.get("classes") or [])
    class_timeouts = {}
    for pair in (lane.get("class_timeouts") or "").split(","):
        if "=" in pair:
            name, value = pair.split("=", 1)
            class_timeouts[name] = _int_or_zero(value)

    seen = set()
    genuine_failures = []
    wedge_hits = 0
    for lane_dir in [p for p in args.lane.split(",") if p]:
        read = _read_lane(lane_dir)
        seen.update(read.get("classes_observed") or [])
        genuine_failures.extend(read.get("real_failures") or [])
        wedge_hits += _int_or_zero(read.get("launch_signature_hits"))

    if genuine_failures or real_failures_in_parts(args.lane):
        # A product failure is present anywhere: the round is disqualified and
        # the gate must fail on it rather than retry around it.
        fail("recovery round refused: genuine test failures are present")
        return 3
    if wedge_hits <= 0 and not synthetic_in_parts(args.lane):
        fail("recovery round refused: no launch-refusal evidence in the "
             "given lane results")
        return 3

    # Synthetic entries name the RUN, never a planned class, so they never
    # count as coverage.
    missing = [c for c in planned if c not in seen]
    if not missing:
        write_env(args.out, {"GATE_RECOVERY_PRESENT": 0})
        print("recovery round: nothing left to retry (0 classes)")
        return 0

    tasks = []
    for name in missing:
        found = None
        for batch in batches:
            if name in (batch.get("classes") or []):
                found = batch
                break
        budget = 0
        if ui:
            budget = class_timeouts.get(name, 0)
        elif found:
            budget = int(found.get("timeout_s") or 0)
        capped = min(budget, args.timeout_cap) if args.timeout_cap > 0 else budget
        tasks.append({
            "class": name,
            "target": lane.get("target") or ("ConduitUITests" if ui else "ConduitTests"),
            "predicted_s": (found.get("predicted_s") or 0) if found else 0,
            "timeout_s": capped if capped > 0 else (budget or 600),
        })
    timeout_csv = ",".join("{0}={1}".format(t["class"], t["timeout_s"]) for t in tasks)
    env = {
        "GATE_RECOVERY_PRESENT": 1,
        "GATE_RECOVERY_KIND": "ui" if ui else "unit",
        "GATE_RECOVERY_CLASS_COUNT": len(tasks),
        "GATE_RECOVERY_CLASSES": _csv(t["class"] for t in tasks),
        "GATE_RECOVERY_CLASS_TIMEOUTS": timeout_csv,
        "GATE_RECOVERY_TIMEOUT": int(sum(t["timeout_s"] for t in tasks)),
    }
    write_env(args.out, env)
    tsv = args.tsv_out or (os.path.splitext(args.out)[0] + ".tsv")
    # TSV the shell loops over: ONE retry invocation for the whole retry set,
    # in ONE batch. The verified wedge on this machine alternates across app
    # launches (every other launch is refused, regardless of
    # terminate/uninstall/erase between them - see docs/CI.md), so the round
    # minimises the number of launches: a single launch gives the retry its
    # one chance, and a refusal of it fails the gate as infrastructure with no
    # third attempt. Chunking into many launches would make a clean round
    # impossible at the observed rate.
    batches_json = json.dumps(
        [{"classes": [t["class"] for t in tasks],
          "predicted_s": round(sum(t["predicted_s"] for t in tasks), 1),
          "timeout_s": int(sum(t["timeout_s"] for t in tasks))}],
        separators=(",", ":"))
    with open(tsv, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("{0}\t{1}\t{2}\t{3}\t{4}\n".format(
            "retry-set", _csv(t["class"] for t in tasks), batches_json,
            round(sum(t["predicted_s"] for t in tasks), 1),
            int(sum(t["timeout_s"] for t in tasks))))
    print("recovery round ({0}): retrying {1} class(es) once in one invocation".format(
        kind, len(tasks)))
    return 0


def cmd_is_infra_only(args) -> int:
    """Exit 0 when a lane's failure is the launch wedge / infrastructure and
    NOT a genuine assertion.

    The gate's retries are only ever for infrastructure: a genuine failing
    test is final. The repeat loop asks this before it retries a repetition,
    so a product failure can never be re-run by the gate.
    """
    lane = _read_lane(args.lane_dir)
    if lane.get("real_failures"):
        return 1
    if lane.get("assertion_failures"):
        return 1
    if (lane.get("infrastructure_failures") or lane.get("synthetic_failures")
            or lane.get("launch_signature_hits") or lane.get("timeouts")
            or lane.get("not_executed")):
        return 0
    return 1


def real_failures_in_parts(lane_dirs) -> bool:
    """Best-effort check across the lane directories' per-invocation parts:
    a genuine failing test anywhere disqualifies the recovery round."""
    for lane_dir in [p for p in (lane_dirs or "").split(",") if p]:
        parts_dir = os.path.join(lane_dir, "parts")
        try:
            names = sorted(os.listdir(parts_dir))
        except OSError:
            continue
        for name in names:
            match = PART_NAME.match(name)
            if not match:
                continue
            doc = load_json(os.path.join(parts_dir, name))
            if not isinstance(doc, dict):
                continue
            real, _ = split_failures(doc.get("failures"))
            if real:
                return True
    return False


def synthetic_in_parts(lane_dirs) -> bool:
    for lane_dir in [p for p in (lane_dirs or "").split(",") if p]:
        parts_dir = os.path.join(lane_dir, "parts")
        try:
            names = sorted(os.listdir(parts_dir))
        except OSError:
            continue
        for name in names:
            match = PART_NAME.match(name)
            if not match:
                continue
            doc = load_json(os.path.join(parts_dir, name))
            if not isinstance(doc, dict):
                continue
            _, synthetic = split_failures(doc.get("failures"))
            if synthetic:
                return True
    return False


# ---------------------------------------------------------------------------
# meta / phase / simulator
# ---------------------------------------------------------------------------

def cmd_meta(args) -> int:
    doc = {
        "schema_version": SCHEMA_VERSION,
        "requested_ref": args.ref,
        "tested_sha": args.sha,
        # The gate tooling's own commit (orchestrator + this assembler come
        # from the invoking checkout, not the tested tree): two results for the
        # same tested SHA produced by different gate tooling are then
        # distinguishable in release evidence.
        "tooling_sha": args.tooling_sha or "",
        "xcode_version": args.xcode,
        "simulator": {
            "name": args.simulator,
            "runtime": args.runtime or "",
            "udid": args.simulator_udid or "",
        },
        # Which certification this run is, and how it was executed. Both are
        # recorded here because the result document, not the command line, is
        # what a result is cited from.
        "mode": args.mode or "release",
        "workers": args.workers if args.workers is not None else 1,
        "unit_batch_max_classes": args.unit_batch_max_classes or 0,
        "started_at": args.started_at or "",
        "finished_at": args.finished_at or "",
        "wall_s": args.wall_s,
        "allowed_recovered_infrastructure": bool(args.allow_recovered_infrastructure),
        "static_checks_enabled": not args.skip_static,
        "repeat_policy_enabled": bool(_split_classes(args.repeat_classes)) and
                                 args.repeat_iterations > 0,
        "run_flags": {
            "lock_used": _flag_or_none(args.lock_used),
            "simulator_prep": _flag_or_none(args.simulator_prep),
        },
        "expected": {
            "unit_classes": args.unit_classes,
            "unit_batches": args.unit_batches,
            "ui_classes": args.ui_classes,
            "repeat_classes": _split_classes(args.repeat_classes),
            "repeat_iterations": args.repeat_iterations,
        },
    }
    # The second project-owned device, only when the run fanned out. Omitted
    # entirely for a one-worker run so a reader cannot mistake the primary
    # device for a second one.
    if (args.simulator2 or "").strip():
        doc["simulator2"] = {
            "name": args.simulator2,
            "runtime": args.simulator2_runtime or "",
            "udid": args.simulator2_udid or "",
        }
    write_json(args.out, doc)
    return 0



def cmd_phase(args) -> int:
    checks = []
    for raw in args.check or []:
        # name:status:duration_s[:note] - note may contain colons, so it is
        # re-joined rather than split again.
        parts = raw.split(":", 3)
        if len(parts) < 3:
            fail("--check must be name:status:seconds[:note], got {0!r}".format(raw))
            return 2
        checks.append({
            "name": parts[0],
            "status": parts[1],
            "duration_s": _int_or_zero(parts[2]),
            "note": parts[3] if len(parts) > 3 else "",
        })
    details = {}
    for raw in args.detail or []:
        if "=" not in raw:
            fail("--detail must be KEY=VALUE, got {0!r}".format(raw))
            return 2
        key, value = raw.split("=", 1)
        details[key] = value
    doc = {
        "schema_version": SCHEMA_VERSION,
        "phase": args.phase,
        "status": args.status,
        "duration_s": args.duration,
        "exit_code": args.exit_code if args.exit_code is not None else 0,
        "note": args.note or "",
        "details": details,
        "checks": checks,
    }
    write_json(args.out, doc)
    return 0


def _int_or_zero(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _flag_or_none(value):
    """Tri-state for an operating flag: True/False when the shell said so,
    None when it did not (so a caveat is never asserted on a guess)."""
    if value in ("1", "true", "True"):
        return True
    if value in ("0", "false", "False"):
        return False
    return None


def cmd_simulator(args) -> int:
    """Report the device xcodebuild will actually target: the newest iOS
    runtime that carries a device with the pinned name (matching
    ci-lib.sh's resolution order), so the gate's result names a real
    simulator/runtime instead of the requested string."""
    doc = load_json(args.devices)
    devices = None
    if isinstance(doc, dict):
        devices = doc.get("devices")
    out = {"name": args.name, "runtime": "", "udid": args.udid or ""}
    if isinstance(devices, dict):
        best = None
        for runtime_key, entries in devices.items():
            if "SimRuntime.iOS" not in str(runtime_key):
                continue
            version = _runtime_version(str(runtime_key))
            if version is None:
                continue
            for entry in entries or []:
                if not isinstance(entry, dict) or entry.get("name") != args.name:
                    continue
                if best is None or version > best[0]:
                    best = (version, entry.get("udid") or "", version)
        if best is not None:
            out["runtime"] = "iOS {0}".format(
                ".".join(str(p) for p in best[2]))
            if not out["udid"]:
                out["udid"] = best[1]
    write_json(args.out, out)
    return 0


def _runtime_version(runtime_key: str):
    """'com.apple.CoreSimulator.SimRuntime.iOS-26-0' -> (26, 0). Numeric
    tuples so iOS-26-10 outranks iOS-26-9 (a string compare would not)."""
    marker = ".iOS-"
    idx = runtime_key.find(marker)
    if idx < 0:
        return None
    tail = runtime_key[idx + len(marker):]
    if not tail:
        return None
    parts = tail.split("-")
    try:
        return tuple(int(p) for p in parts)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# summarize
# ---------------------------------------------------------------------------

def _phase_status(container, name):
    """Read one phase status document. Returns (status, doc); a missing or
    unreadable phase document is 'missing', never 'pass'."""
    if not container:
        return "missing", {}
    doc = load_json(os.path.join(container, name, "phase.json"))
    if not isinstance(doc, dict) or not doc.get("status"):
        return "missing", {}
    return str(doc["status"]), doc


def _work_items(attempts, batches, lane_classes=None):
    """Fold the runner's attempt chain into WORK ITEMS (the unit of retry).

    A unit lane retries a BATCH and a UI lane retries a CLASS, so a work item
    is identified by the batch number or the class name - NOT by the mode
    string, because attempt 2 arrives under a `-retry` mode. Grouping this
    way is what lets the gate see "this item failed an assertion and later
    passed" and "this item hit the environment and later passed".

    Returns (order, items): `order` preserves first-seen order, `items` maps
    the work-item key to {name, batch, statuses[]}.
    """
    batch_classes = {}
    for batch in batches if isinstance(batches, list) else []:
        if isinstance(batch, dict):
            batch_classes[str(batch.get("batch"))] = list(batch.get("classes") or [])

    order = []
    items = {}

    def touch(key, name=None, batch=None, part_keys=(), from_declared=False):
        if key not in items:
            items[key] = {"name": name or "", "batch": batch, "statuses": [],
                          "part_keys": list(part_keys),
                          "name_from_declared": bool(from_declared)}
            order.append(key)
        entry = items[key]
        if name and not entry["name"]:
            entry["name"] = name
        if from_declared:
            entry["name_from_declared"] = True
        if batch is not None and entry["batch"] is None:
            entry["batch"] = batch
        for part_key in part_keys:
            if part_key not in entry["part_keys"]:
                entry["part_keys"].append(part_key)
        return entry

    for item in attempts if isinstance(attempts, list) else []:
        if not isinstance(item, dict):
            continue
        mode = str(item.get("mode") or "")
        n = _int_or_zero(item.get("n"))
        cls = str(item.get("class") or "all")
        status = str(item.get("status") or "")
        if mode.startswith("batch"):
            key = ("batch", str(n))
            # A UI lane runs per-class invocations and writes NO `batches`
            # array, so its shard-level item is named by the lane's own
            # declared classes: the synthetic "batch-<n>" fallback names no
            # work any recovery could observe. An item named this way is
            # tagged, because its classes ran as their OWN invocations - the
            # healing evidence rule covers it per class rather than as one
            # interrupted batch (see `_round_reran`).
            declared = _csv(lane_classes or [])
            from_declared = not batch_classes.get(str(n)) and bool(declared)
            name = _csv(batch_classes.get(str(n)) or []) \
                or declared \
                or "batch-{0}".format(n)
            # "batch-<n>" is the unit naming; a UI shard has one batch-level
            # invocation whose part is named without the index. A UI shard's
            # targeted retry arrives as batch-retry with n=2 even though the
            # shard has a single batch, so a retry whose own key does not exist
            # reuses the only batch item there is - otherwise the "failed an
            # assertion, then passed" pair would never be seen as one item.
            keys = ["batch-{0}".format(n), "batch"]
            if mode.endswith("-retry") and ("batch", str(n)) not in items:
                existing = [k for k in items if k[0] == "batch"]
                if len(existing) == 1:
                    key = existing[0]
                    keys = ["batch-{0}".format(key[1]), "batch"]
            touch(key, name=name, batch=n, part_keys=keys,
                  from_declared=from_declared)["statuses"].append(status)
        elif mode.startswith("class") or mode == "skipped":
            # The runner writes UI diagnosis parts as detail-<Cls>-a<k>.json:
            # the class name carries no "class-" infix (see ci-test-lane.sh's
            # run_class_diagnosis), so both spellings are candidates.
            touch(("class", cls), name=cls,
                  part_keys=["class-{0}".format(cls), cls])["statuses"].append(status)
        else:
            touch((mode, str(n)), name=cls)["statuses"].append(status)

    # Batch chains carry the per-attempt failing-test counts, which the
    # attempt list does not; they also cover a batch whose bookkeeping line
    # survived without an attempt record. Both are the runner's own output,
    # so they are merged rather than preferred one over the other.
    for batch in batches if isinstance(batches, list) else []:
        if not isinstance(batch, dict):
            continue
        n = _int_or_zero(batch.get("batch"))
        key = ("batch", str(n))
        declared = _csv(lane_classes or [])
        name = _csv(batch_classes.get(str(n)) or batch.get("classes") or []) \
            or declared or "batch-{0}".format(n)
        from_declared = (not batch_classes.get(str(n))
                         and not (batch.get("classes") or [])
                         and bool(declared))
        chain = [a for a in (batch.get("attempts") or []) if isinstance(a, dict)]
        for attempt in chain:
            entry = touch(key, name=name, batch=n,
                          part_keys=["batch-{0}".format(n), "batch"],
                          from_declared=from_declared)
            status = str(attempt.get("status") or "")
            if status and status not in entry["statuses"]:
                entry["statuses"].append(status)
    return order, items


def _read_parts(lane_dir: str):
    """Per-invocation extraction parts, keyed as the lane runner names them:
    `detail-batch-<n>-a<k>.json` for a unit batch, `detail-<Cls>-a<k>.json` for
    a UI class, `detail-batch-a<k>.json` for a UI shard. Only the failure
    lists are used, and only to attribute a failure to the invocation that
    produced it (the merged detail document cannot).
    """
    parts = {}
    parts_dir = os.path.join(lane_dir, "parts")
    try:
        names = sorted(os.listdir(parts_dir))
    except OSError:
        return parts
    for name in names:
        match = PART_NAME.match(name)
        if not match:
            continue
        doc = load_json(os.path.join(parts_dir, name))
        if not isinstance(doc, dict):
            continue
        real, synthetic = split_failures(doc.get("failures"))
        entry = parts.setdefault(match.group("key"), {"real": 0, "synthetic": 0})
        entry["real"] += len(real)
        entry["synthetic"] += len(synthetic)
    return parts


# The verified signature of the infrastructure class the bounded recovery is
# allowed for. It is the simulator refusing to install/launch the host app, as
# observed on this machine:
#
#   Simulator device failed to launch com.milim.relay.
#   Application failed preflight checks ... reason: Busy
#
# Anything else - a crash with no synthetic entry, a watchdog timeout, a build
# error - is NOT this class and must never be recovered.
LAUNCH_SIGNATURES = (
    "Application failed preflight checks",
    "Simulator device failed to launch",
    "Failed to launch app with identifier",
    "BSErrorCodeDescription=Busy",
    "reason: Busy",
)


def scan_launch_signatures(lane_dir: str):
    """Best-effort scan of a lane's own logs for the verified launch-refusal
    signature. Returns (hit_count, sample) so the decision is auditable from
    the result document rather than being a bare boolean."""
    hits = 0
    sample = ""
    logs_dir = os.path.join(lane_dir, "logs")
    try:
        names = sorted(os.listdir(logs_dir))
    except OSError:
        return 0, ""
    for name in names:
        if not name.endswith(".log"):
            continue
        try:
            with open(os.path.join(logs_dir, name), encoding="utf-8",
                      errors="replace") as fh:
                for line in fh:
                    for signature in LAUNCH_SIGNATURES:
                        if signature in line:
                            hits += 1
                            if not sample:
                                sample = "{0}: {1}".format(name, line.strip()[:160])
                            break
        except OSError:
            continue
    return hits, sample


def _classify_attempts(attempts, batches, parts=None, lane_has_real_failures=True,
                       lane_classes=None):
    """Split lane evidence into assertion failures, infrastructure events,
    timeouts and never-executed work, using the runner's own status tokens.

    Each infrastructure/timeout event is tagged `recovered` when a later
    attempt on the same work item passed: that distinction is what keeps a
    recovered wedge from being confused with a persistent one, and
    `assertion_retried_until_green` marks the invariant the gate refuses to
    accept in any mode - the same work item recorded `test-failures` and then
    `passed`, i.e. a genuine assertion was re-run until it agreed (a flake),
    which is not validation.

    `parts` is the per-invocation failure attribution from _read_parts;
    `lane_has_real_failures` is the lane-level fallback for when the parts
    could not be read; `lane_classes` is the lane's DECLARED class list
    (lane-result `classes`), which names a batch-level work item when the lane
    carries no `batches` array of its own - production UI lanes run per-class
    invocations and write exactly that shape.
    """
    parts = parts or {}
    order, items = _work_items(attempts, batches, lane_classes)
    assertion = []
    infrastructure = []
    timeouts = []
    not_executed = []
    retried_until_green = []

    # A `test-failures` status means the invocation EXITED with failing
    # entries - but XCTest also reports the RUN under "System Failures" when
    # the test host never launched. Only the per-invocation extraction parts
    # can tell those apart, so the classification of a `test-failures` item
    # is decided by the parts when they are available and falls back to the
    # lane-level split when they are not (never to "assume assertion").
    def part_counts(entry):
        real = synthetic = 0
        seen = False
        for part_key in entry.get("part_keys") or []:
            if part_key in parts:
                seen = True
                real += parts[part_key]["real"]
                synthetic += parts[part_key]["synthetic"]
        return real, synthetic, seen

    for key in order:
        entry = items[key]
        statuses = entry["statuses"]
        if not statuses:
            continue
        final = statuses[-1]
        common = {"name": entry["name"], "key": list(key)}
        if entry.get("name_from_declared"):
            # The item is a UI shard-level invocation named by the lane's
            # DECLARED classes: each of those classes ran (or was re-run) as
            # its own invocation, so healing evidence for this item is a
            # per-class question (`_round_reran`).
            common["name_from_declared"] = True
        if entry["batch"] is not None:
            common["batch"] = entry["batch"]
        saw_assertion = any(s in ASSERTION_FAILURE_STATUSES for s in statuses)
        saw_infra = any(s in INFRASTRUCTURE_STATUSES for s in statuses)
        saw_timeout = any(s in TIMEOUT_STATUSES for s in statuses)
        recovered = final == "passed"

        if saw_assertion:
            real, synthetic, seen = part_counts(entry)
            if seen and real == 0 and synthetic > 0:
                # The invocation's only "failures" were XCTest reporting the
                # run: a test-runner/host failure, i.e. infrastructure.
                infrastructure.append(dict(
                    common, kind="infrastructure", status="test-runner-failure",
                    synthetic_failures=synthetic, recovered=recovered,
                    statuses=statuses))
            elif not seen and not lane_has_real_failures:
                infrastructure.append(dict(
                    common, kind="infrastructure", status="test-runner-failure",
                    synthetic_failures=0, recovered=recovered,
                    statuses=statuses))
            else:
                assertion.append(dict(common, kind="assertion",
                                      status="test-failures", real_failures=real,
                                      synthetic_failures=synthetic,
                                      recovered=recovered, statuses=statuses))
                if recovered:
                    retried_until_green.append(dict(common, statuses=statuses))
        if saw_infra:
            infrastructure.append(dict(common, kind="infrastructure",
                                       status=final if final in INFRASTRUCTURE_STATUSES
                                       else INFRASTRUCTURE_STATUSES[0],
                                       recovered=recovered, statuses=statuses))
        if saw_timeout:
            timeouts.append(dict(common, kind="timeout",
                                 status=final if final in TIMEOUT_STATUSES else "timeout",
                                 recovered=recovered, statuses=statuses))
        if final in NOT_EXECUTED_STATUSES:
            not_executed.append(dict(common, kind="not_executed", status=final,
                                     recovered=False, statuses=statuses))

    retries = []
    for item in attempts if isinstance(attempts, list) else []:
        if isinstance(item, dict) and str(item.get("mode")) in RETRY_MODES:
            retries.append({"mode": str(item.get("mode")),
                            "name": str(item.get("class") or "all"),
                            "status": str(item.get("status"))})

    return {
        "assertion_failures": assertion,
        "infrastructure_failures": infrastructure,
        "timeouts": timeouts,
        "not_executed": not_executed,
        "retries": retries,
        "assertion_retried_until_green": retried_until_green,
    }


def _read_lane(lane_dir: str) -> dict:
    """Read one lane's artifacts. `status` is taken from lane-result.json
    (the lane runner's own verdict); every count comes from the extraction
    artifacts, and their absence is reported, never guessed."""
    try:
        entries = sorted(os.listdir(lane_dir))
    except OSError:
        entries = []
    lane_result = load_json(os.path.join(lane_dir, "lane-result.json"))
    observations = load_json(os.path.join(lane_dir, "observations.json"))
    detail = load_json(os.path.join(lane_dir, "detail.json"))

    out = {
        "dir": lane_dir,
        "present": isinstance(lane_result, dict),
        "lane_result_present": isinstance(lane_result, dict),
        "observations_present": isinstance(observations, dict),
        "detail_present": isinstance(detail, dict),
        "status": "missing",
        "classes_observed": [],
        "executions": None,
        "failures": [],
        "flaky": [],
        "attempts": [],
        "batches": [],
        "retried_classes": [],
        "infra_recovered_classes": [],
        "persistent_infra_classes": [],
        "hung_class": None,
        "hung_batch": None,
        "simulator_reset": False,
        "simulator_erase": False,
        "actual_s": None,
        "predicted_s": None,
        "timeout_s": None,
        "xcresults": [e for e in entries if e.endswith(".xcresult")],
    }
    if isinstance(lane_result, dict):
        out.update({
            "status": str(lane_result.get("status") or "unknown"),
            "retried_classes": list(lane_result.get("retried_classes") or []),
            "infra_recovered_classes": list(
                lane_result.get("infra_recovered_classes") or []),
            "persistent_infra_classes": list(
                lane_result.get("persistent_infra_classes") or []),
            "hung_class": lane_result.get("hung_class"),
            "hung_batch": lane_result.get("hung_batch"),
            "simulator_reset": bool(lane_result.get("simulator_reset")),
            "simulator_erase": bool(lane_result.get("simulator_erase")),
            "actual_s": lane_result.get("actual_s"),
            "predicted_s": lane_result.get("predicted_s"),
            "timeout_s": lane_result.get("timeout_s"),
            "attempts": lane_result.get("attempts") or [],
            "batches": lane_result.get("batches") or [],
            # The lane's own declared class list. It is the only identity a
            # batch-level work item has on a UI lane (per-class invocations,
            # no `batches` array), and healing evidence is matched by name.
            "classes_declared": [str(c) for c in
                                 (lane_result.get("classes") or [])],
        })
        if not out["failures"]:
            out["failures"] = list(lane_result.get("failures") or [])
        out["flaky"] = list(lane_result.get("flaky") or [])
    if isinstance(observations, dict):
        classes = observations.get("classes")
        if isinstance(classes, dict):
            # XCTest's synthetic pseudo-class is not a planned class: it must
            # not be reported as an unexpected one when the run reports itself.
            out["classes_observed"] = sorted(
                c for c in classes.keys() if c not in SYNTHETIC_FAILURE_CLASSES)
        counts = observations.get("counts")
        if isinstance(counts, dict):
            out["executions"] = _int_or_zero(counts.get("cases"))
    if isinstance(detail, dict):
        if not out["failures"]:
            out["failures"] = list(detail.get("failures") or [])
        if not out["flaky"]:
            out["flaky"] = list(detail.get("retried") or [])
        if not out["classes_observed"]:
            attempts = detail.get("attempts") or []
            if isinstance(attempts, list):
                out["classes_observed"] = sorted({
                    str(a.get("class")) for a in attempts
                    if isinstance(a, dict) and a.get("class")
                    and str(a.get("class")) not in SYNTHETIC_FAILURE_CLASSES})
    # Split the extracted failures: entries XCTest files under its synthetic
    # "System Failures" class report the RUN (the test host never launched),
    # not a test asserting anything. Only the real ones are assertion
    # failures, and only they justify calling this a product failure.
    synthetic = [f for f in out["failures"] if is_synthetic_failure(f)]
    out["synthetic_failures"] = synthetic
    out["real_failures"] = [f for f in out["failures"] if not is_synthetic_failure(f)]
    out["failures"] = out["real_failures"]
    out["parts"] = _read_parts(lane_dir)
    signature_hits, signature_sample = scan_launch_signatures(lane_dir)
    out["launch_signature_hits"] = signature_hits
    out["launch_signature_sample"] = signature_sample
    # The verified infrastructure class the bounded recovery is allowed for:
    # the host/test-runner launch refusal. It is confirmed either by XCTest's
    # synthetic "it was the run, not a test" entry, or by the signature in the
    # lane's own log - never by a timeout or an unreadable bundle.
    out["is_launch_wedge"] = bool(
        (synthetic and not out["real_failures"]) or
        (signature_hits > 0 and not out["real_failures"]))
    # Per-class execution shares, so several passes over the same lane can be
    # merged per class instead of summed (a class re-run in a later pass must
    # not be counted twice). extract-test-timings.py splits a part's case
    # count across the classes that part contributed; with one class per
    # invocation (repeats, recovery) the share is exact.
    observed_classes = dict(observations.get("classes") or {}) \
        if isinstance(observations, dict) else {}
    cases = _int_or_zero((observations.get("counts") or {}).get("cases")) \
        if isinstance(observations, dict) else 0
    if observed_classes:
        share = float(cases) / float(len(observed_classes))
        out["class_shares"] = {c: share for c in observed_classes}
    else:
        out["class_shares"] = {}
    out.update(_classify_attempts(out["attempts"], out["batches"], out["parts"],
                                  bool(out["real_failures"]),
                                  out.get("classes_declared") or []))
    return out


def _is_recovery_pass(name) -> bool:
    """True when a pass IS a recovery pass, by directory basename.

    Matching `"recovery" in <full path>` would fire for any run directory
    whose path happens to contain the word (a --run-dir under ~/gate-recovery,
    a volume named "Recovery"), and would then suppress problems for a run
    that never recovered anything.
    """
    base = os.path.basename(str(name or ""))
    return base.startswith("unit-recovery") or base.startswith("ui-recovery")


def _recovery_observations(unit_summary, ui_summary):
    """Per-suite recovery evidence from the gate's OWN recovery passes.

    Returns {suite: {"ran": bool, "complete": bool, "observed": set}}. The
    round is per suite, so evidence is kept per suite and never merged: one
    suite's pass must never heal the other suite's records, and a suite whose
    own round left it incomplete heals nothing (its events stay persistent).
    """
    evidence = {}
    for suite, summary in (("unit", unit_summary), ("ui", ui_summary)):
        summary = summary or {}
        recovery_passes = [p for p in (summary.get("passes") or [])
                           if _is_recovery_pass(p.get("name"))]
        observed = set()
        for lane_pass in recovery_passes:
            observed.update(lane_pass.get("observed_names") or [])
        # Classes SOME earlier pass reported. A shard-level item named by the
        # lane's declared classes is covered per class, so what the round had
        # to re-run for it is exactly the classes left without results - this
        # is the evidence the coverage check unions with the round's own.
        primary_observed = set()
        for lane_pass in summary.get("passes") or []:
            if not _is_recovery_pass(lane_pass.get("name")):
                primary_observed.update(lane_pass.get("observed_names") or [])
        evidence[suite] = {
            "ran": bool(recovery_passes),
            "complete": not (summary.get("classes_missing") or []),
            "observed": observed,
            "primary_observed": primary_observed,
        }
    return evidence


def _round_reran(entry, evidence) -> bool:
    """True when the round's own passes re-ran the work `entry` names.

    Shared by infrastructure events and hangs so the two healing paths cannot
    drift: the entry's lane must be exactly unit or ui (a repeat lane is never
    healed - its own bounded retry decides it), a recovery pass for THAT suite
    must have run and left THAT suite complete, and its observations must
    cover every class the entry names (a batch CSV counts only when all of its
    classes have results). Work a suite's round never observed is not re-run
    work, and calling it healed is what lets a must-FAIL run pass.
    """
    suite = str(entry.get("lane") or "")
    if suite not in ("unit", "ui"):
        return False
    record = evidence.get(suite) or {}
    if not record.get("ran") or not record.get("complete"):
        return False
    name = str(entry.get("name") or "")
    if entry.get("name_from_declared"):
        # A UI shard-level item names the lane's DECLARED classes, and each of
        # them ran (or was re-run) as its OWN invocation. The item is covered
        # when every class it names has a result from some pass; the round had
        # only to re-run the ones the earlier passes left without results.
        covered = (record.get("observed") or set()) | \
                  (record.get("primary_observed") or set())
        return _classes_have_results(covered, name)
    return _classes_have_results(record.get("observed") or set(), name)


def _lane_pass_dirs(lanes_root, primary, extra, recovery_prefix):
    """The primary lane dir, an optional follow-up dir (the unit lane's
    continuation), and every recovery-pass dir - in execution order.

    UNIT and UI recovery are collected the same way on purpose: a recovery
    pass is evidence about the suite it recovers, whichever suite it is, and
    a UI recovery that the summarizer ignored would leave recovered work
    reported as never executed.
    """
    dirs = []
    primary_dir = os.path.join(lanes_root, primary)
    if os.path.isdir(primary_dir):
        dirs.append(primary_dir)
    if extra:
        extra_dir = os.path.join(lanes_root, extra)
        if os.path.isdir(extra_dir):
            dirs.append(extra_dir)
    try:
        names = sorted(os.listdir(lanes_root))
    except OSError:
        names = []
    for name in names:
        if name.startswith(recovery_prefix):
            candidate = os.path.join(lanes_root, name)
            if os.path.isdir(candidate):
                dirs.append(candidate)
    return dirs


def _summarize_lane_group(lane_dirs, expected_classes, expected_batches=None):
    """Read, summarize and merge a suite's passes (primary [+ continuation]
    [+ recovery]). Coverage is judged on the merged aggregate; only the
    primary pass carries the plan's expected class list and batch count,
    because a follow-up pass runs a subset of it on purpose."""
    if not lane_dirs:
        return None
    summaries = []
    for index, lane_dir in enumerate(lane_dirs):
        lane = _read_lane(lane_dir)
        summaries.append(_summarize_lane(
            lane,
            expected_classes if index == 0 else None,
            expected_batches if index == 0 else None))
    if len(summaries) == 1:
        return summaries[0]
    return _merge_lane_summaries(summaries, expected_classes)


def _summarize_lane(lane: dict, expected_classes, expected_batches=None) -> dict:
    problems = []
    # The lane runner's own verdict is a problem in its own right. Every path
    # that produces a non-pass status also emits a classifiable event today,
    # but the gate must not depend on that staying true: a runner that says
    # "fail" (or "error") can never be reported as PASS because the event
    # vocabulary happened to come up empty.
    if str(lane.get("status")) not in ("pass", "skipped"):
        problems.append("lane runner verdict is {0!r}, not 'pass'".format(
            lane.get("status")))
    if not lane["lane_result_present"]:
        problems.append("lane-result.json missing")
    if lane["executions"] is None:
        problems.append("observations.json missing or without counts (execution "
                        "count could not be read from the result bundle)")
    # expected_classes is None when the planned list is unknown: the caller
    # reports that separately, and asserting coverage against an empty set
    # would turn every executed class into a bogus "unexpected class".
    observed = set(lane["classes_observed"])
    expected = set(expected_classes or [])
    if expected_classes is not None:
        missing = sorted(expected - observed)
        extra = sorted(observed - expected)
        if missing:
            problems.append("classes never executed: {0}".format(_csv(missing)))
        if extra:
            problems.append("unexpected classes executed: {0}".format(_csv(extra)))
    else:
        missing, extra = [], sorted(observed)
    if expected_batches is not None:
        if len(lane["batches"] or []) != expected_batches:
            problems.append("expected {0} planned batches, lane result carries "
                            "{1}".format(expected_batches, len(lane["batches"] or [])))
    if lane["not_executed"]:
        problems.append("work recorded as not executed: {0}".format(
            _csv(sorted({e["name"] for e in lane["not_executed"]}))))
    if lane["assertion_retried_until_green"]:
        problems.append(
            "genuine assertions were retried and then passed (not validation): "
            + _csv(sorted({e["name"] for e in lane["assertion_retried_until_green"]})))

    observed_sorted = sorted(observed)
    return {
        "dir": lane["dir"],
        "status": lane["status"],
        # A single pass is reported in the same shape as a merged group, so a
        # consumer never has to special-case "there was no recovery".
        "passes": [{
            "name": lane["dir"],
            "status": lane["status"],
            "classes_observed": len(observed_sorted),
            "observed_names": observed_sorted,
            "executions": lane.get("executions"),
            "failures": len(lane["real_failures"] or []),
            "synthetic_failures": len(lane.get("synthetic_failures") or []),
            "launch_signature_hits": lane.get("launch_signature_hits") or 0,
            "is_launch_wedge": bool(lane.get("is_launch_wedge")),
        }],
        "executions": lane["executions"],
        "failures": len(lane["failures"]),
        "failure_detail": lane["failures"],
        # XCTest's own "the run failed" entries (test host never launched).
        # Counted as infrastructure, reported separately, and never as an
        # assertion failure.
        "synthetic_failures": len(lane.get("synthetic_failures") or []),
        "flaky": lane["flaky"],
        "classes_expected": len(expected),
        "classes_observed": len(observed),
        "classes_missing": missing,
        "observed_names": sorted(observed),
        # Per-class execution shares, used by the multi-pass merge so a class
        # is counted once across passes instead of once per pass.
        "class_shares": lane.get("class_shares") or {},
        "launch_signature_hits": lane.get("launch_signature_hits") or 0,
        "launch_signature_sample": lane.get("launch_signature_sample") or "",
        "is_launch_wedge": bool(lane.get("is_launch_wedge")),
        "batch_count": len(lane["batches"] or []) or None,
        "batches_expected": expected_batches,
        "assertion_failures": lane["assertion_failures"],
        "infrastructure_failures": lane["infrastructure_failures"],
        "timeouts": lane["timeouts"],
        "not_executed": lane["not_executed"],
        "retries": lane["retries"],
        "assertion_retried_until_green": lane["assertion_retried_until_green"],
        "retried_classes": lane["retried_classes"],
        "infra_recovered_classes": lane["infra_recovered_classes"],
        "persistent_infra_classes": lane["persistent_infra_classes"],
        "hung_class": lane["hung_class"],
        "hung_batch": lane["hung_batch"],
        "simulator_reset": lane["simulator_reset"],
        "simulator_erase": lane["simulator_erase"],
        "duration_s": lane["actual_s"],
        "predicted_s": lane["predicted_s"],
        "timeout_s": lane["timeout_s"],
        "problems": problems,
    }


# Fields concatenated when a lane is continued (the gate's unit lane plus the
# batches it never reached). Everything the summary exposes as a list of
# events is concatenated; counters are summed; coverage is unioned.
_MERGE_LIST_FIELDS = ("failure_detail", "assertion_failures",
                      "infrastructure_failures", "timeouts",
                      # not_executed is recomputed against the aggregate, not
                      # concatenated: see _merge_lane_summaries.
                      "retries", "assertion_retried_until_green",
                      "retried_classes", "infra_recovered_classes",
                      "persistent_infra_classes", "flaky")


def _merge_lane_summaries(passes, expected_classes) -> dict:
    """Fold a lane's follow-up passes (continuation, recovery) into its result.

    Two invariants earn their keep here:

    * a class is counted ONCE, from the LAST pass that produced a result for
      it. Passes only ever run work no earlier pass completed, so this is a
      no-op on a well-behaved run - and on a run where a class WAS re-run, the
      aggregate count stays truthful instead of double counting it, with the
      class recorded in `reread_classes` so the re-run is visible.
    * the follow-up passes' own coverage checks are not applied: what must hold
      is the AGGREGATE one (every class the plan promised was executed by some
      pass), computed against `expected_classes`.
    """
    passes = [p for p in passes if p]
    if not passes:
        return {}
    primary = passes[0]
    merged = dict(primary)
    merged["status"] = "fail" if any(str(p.get("status")) == "fail" for p in passes) \
        else primary["status"]

    for field in ("failures", "synthetic_failures"):
        merged[field] = _int_or_zero(primary.get(field)) + \
            sum(_int_or_zero(p.get(field)) for p in passes[1:])

    # Per-class execution shares: last pass wins for a class more than one
    # pass reported, which is exactly what the runner's own part merge does.
    shares = {}
    share_pass = {}
    for index, summary in enumerate(passes):
        for name, value in (summary.get("class_shares") or {}).items():
            shares[name] = value
            share_pass[name] = index
    merged["executions"] = int(round(sum(shares.values()))) if shares else None
    observed = set(shares)
    seen_in = {}
    for name in observed:
        seen_in[name] = sum(
            1 for summary in passes
            if name in (summary.get("observed_names") or []))
    reread = sorted(name for name in observed if seen_in[name] > 1)
    merged["classes_expected"] = len(list(expected_classes or []))
    merged["classes_observed"] = len(observed)
    missing = sorted(set(expected_classes or []) - observed)
    merged["classes_missing"] = missing

    for field in ("batch_count", "duration_s", "predicted_s", "timeout_s"):
        values = [p.get(field) for p in passes if p.get(field) is not None]
        merged[field] = sum(values) if values else None
    merged["simulator_reset"] = any(p.get("simulator_reset") for p in passes)
    merged["simulator_erase"] = any(p.get("simulator_erase") for p in passes)
    for field in _MERGE_LIST_FIELDS:
        merged[field] = [entry for summary in passes
                         for entry in (summary.get(field) or [])]
    # "Work recorded as not executed" is a stopped lane's evidence that a later
    # pass may have since executed: entries whose class now has a result are
    # dropped, which keeps a red report from claiming a class never ran when it
    # did.
    not_exec = [entry for summary in passes
                for entry in (summary.get("not_executed") or [])]
    merged["not_executed"] = [entry for entry in not_exec
                              if not _classes_have_results(
                                  observed, str(entry.get("name") or ""))]

    merged["reread_classes"] = reread
    merged["passes"] = [{
        "name": p.get("dir"),
        "status": p.get("status"),
        "classes_observed": p.get("classes_observed"),
        "observed_names": p.get("observed_names") or [],
        "executions": p.get("executions"),
        "failures": p.get("failures"),
        "synthetic_failures": p.get("synthetic_failures"),
        "launch_signature_hits": p.get("launch_signature_hits"),
        "is_launch_wedge": p.get("is_launch_wedge"),
    } for p in passes]

    # A pass that stopped on the launch wedge and whose work the gate's bounded
    # recovery round then completed is not a problem in itself: its failure is
    # exactly what the round exists for, and the round is recorded as
    # infrastructure.retries. Any other lane verdict stands as a problem.
    recovery_present = [str(p.get("dir") or "") for p in passes
                        if _is_recovery_pass(p.get("dir"))]

    problems = []
    for summary in passes:
        problems.extend(p for p in (summary.get("problems") or [])
                        if not p.startswith("classes never executed")
                        and not p.startswith("work recorded as not executed"))
    # Coverage and "not executed" are AGGREGATE facts after the merge: every
    # pass's own version of them is stale the moment a later pass runs, so the
    # merged list is recomputed against the aggregate.
    if missing:
        problems.append("classes never executed: {0}".format(_csv(missing)))
    if merged["not_executed"]:
        problems.append("work recorded as not executed: {0}".format(
            _csv(sorted({e["name"] for e in merged["not_executed"]}))))
    # A pass that stopped on the launch wedge and whose work the gate's bounded
    # recovery round then completed is not a problem in itself: its failure is
    # exactly what the round exists for, and the round is recorded as
    # infrastructure.retries. Any other lane verdict stands.
    if recovery_present and not missing:
        problems = [p for p in problems
                    if not p.startswith("lane runner verdict is")]
    merged["problems"] = _dedupe(problems)
    return merged


def _read_repeats(repeats_dir: str, expected, iterations: int):
    """Read every repeat class's per-iteration lane artifacts.

    An iteration may have a second attempt directory (`iter-<n>-retry`): the
    gate's bounded retry for a repetition that the launch wedge ate. Both
    attempts are read, because an iteration is satisfied when a later attempt
    is clean and NO attempt contains a genuine failure - a genuine failing
    test is final and is never retried.
    """
    classes = []
    for name in expected:
        class_dir = os.path.join(repeats_dir, name)
        per_iteration = {}
        try:
            entries = sorted(os.listdir(class_dir))
        except OSError:
            entries = []
        for entry in entries:
            if not entry.startswith("iter-"):
                continue
            number = _int_or_zero(entry.split("-")[1])
            retry = entry.endswith("-retry")
            lane = _read_lane(os.path.join(class_dir, entry))
            per_iteration.setdefault(number, []).append({
                "attempt": 2 if retry else 1,
                "dir": lane["dir"],
                "status": lane["status"],
                "executions": lane["executions"],
                "failures": len(lane["failures"]),
                "assertion_failures": lane["assertion_failures"],
                "infrastructure_failures": lane["infrastructure_failures"],
                "timeouts": lane["timeouts"],
                "not_executed": lane["not_executed"],
                "retries": lane["retries"],
                "assertion_retried_until_green": lane["assertion_retried_until_green"],
                "duration_s": lane["actual_s"],
                "xcresults": lane["xcresults"],
                "observations_present": lane["observations_present"],
                "lane_result_present": lane["lane_result_present"],
            })
        iterations_out = []
        for number in sorted(per_iteration):
            attempts = sorted(per_iteration[number], key=lambda a: a["attempt"])
            clean = [a for a in attempts
                     if a["status"] == "pass" and not a["failures"]
                     and not a["infrastructure_failures"] and not a["timeouts"]
                     and not a["not_executed"]
                     and not a["assertion_failures"]]
            genuine = [a for a in attempts if a["failures"] or a["assertion_failures"]]
            best = clean[-1] if clean else attempts[-1]
            merged = dict(best)
            merged["iteration"] = number
            merged["attempts"] = attempts
            merged["attempts_count"] = len(attempts)
            merged["satisfied"] = bool(clean) and not genuine
            merged["genuine_failure"] = bool(genuine)
            merged["executions"] = max(
                [a["executions"] or 0 for a in attempts] or [0]) or None
            iterations_out.append(merged)
        classes.append({
            "class": name,
            "iterations_expected": iterations,
            "iterations_observed": len(iterations_out),
            "iterations": iterations_out,
        })
    return classes


def _repeat_problems(entry, iterations: int):
    problems = []
    if entry["iterations_observed"] != iterations:
        problems.append(
            "{0}: expected {1} repeat iterations, found {2}".format(
                entry["class"], iterations, entry["iterations_observed"]))
    seen = [i["iteration"] for i in entry["iterations"]]
    expected_numbers = list(range(1, iterations + 1))
    if seen != expected_numbers:
        problems.append("{0}: repeat iterations {1} (expected {2})".format(
            entry["class"], seen, expected_numbers))
    for iteration in entry["iterations"]:
        label = "{0} iteration {1}".format(entry["class"], iteration["iteration"])
        # The repeat policy judges TEST reliability: its job is to catch a
        # test that fails intermittently. A repetition lost to the launcher
        # says nothing about the tests, and is governed instead by the
        # infrastructure rules (which require those events to be recovered,
        # else the gate fails as infrastructure) - reporting both would
        # dress an environment loss up as a test problem.
        if iteration.get("genuine_failure"):
            # A genuine failing test is FINAL: never retried, and a
            # repetition failed even if a later attempt passed.
            problems.append(
                "{0}: genuine test failure(s) ({1})".format(
                    label, iteration["failures"]))
        for attempt in iteration.get("attempts") or []:
            if not attempt.get("lane_result_present"):
                problems.append("{0} attempt {1}: lane-result.json missing".format(
                    label, attempt.get("attempt")))
        if not iteration.get("attempts"):
            problems.append("{0}: never executed".format(label))
        if (str(iteration.get("status")) not in ("pass", "skipped")
                and not iteration.get("genuine_failure")
                and not iteration.get("infrastructure_failures")
                and not iteration.get("timeouts")
                and not iteration.get("not_executed")
                and not iteration.get("assertion_failures")):
            problems.append(
                "{0}: lane verdict is {1!r} with no classifiable event".format(
                    label, iteration.get("status")))
        if iteration.get("assertion_retried_until_green"):
            problems.append(
                "{0}: genuine assertions were retried and then passed".format(label))
    return problems


def _invocation_count(lane_dir: str) -> int:
    """xcodebuild invocations a lane actually paid for.

    The lane runner writes one log per invocation (`batch-<n>-a<m>.log` for
    unit batches, `class-<name>-a<m>.log` for UI and diagnosis invocations);
    counting them is the honest measure of how many times Xcode/CoreSimulator
    startup was paid, which is what the wall-clock work is about."""
    logs = os.path.join(lane_dir, "logs")
    if not os.path.isdir(logs):
        return 0
    count = 0
    for name in os.listdir(logs):
        if name.endswith(".log") and (name.startswith("batch-")
                                      or name.startswith("class-")):
            count += 1
    return count


def _lane_timings(dirs) -> dict:
    out = {}
    for lane_dir in dirs:
        doc = load_json(os.path.join(lane_dir, "lane-result.json"))
        if not isinstance(doc, dict):
            continue
        out[os.path.basename(lane_dir)] = {
            "status": doc.get("status"),
            "wall_s": doc.get("actual_s"),
            "predicted_s": doc.get("predicted_s"),
            "classes": len(doc.get("classes") or []),
            "xcodebuild_invocations": _invocation_count(lane_dir),
            "simulator": doc.get("simulator"),
        }
    return out


# workers.tsv columns, in order: name, device name, device UDID, exit code,
# wall seconds, completed, sim-prep failed, log path (relative to the run dir).
WORKER_FIELDS = 8


def _read_workers(run_dir: str, meta: dict, build_passed: bool):
    """Read the run's worker evidence: (records, problems).

    A fanned-out gate run executes the unit work and the UI work as separate
    processes on separate devices. The result document has to prove, on its
    own, that every worker ran to completion on the device the run assigned
    it - a worker that died, or silently ran on the other device, must fail
    the gate rather than leave a shorter run looking complete."""
    records = []
    problems = []
    workers_declared = _int_or_zero(meta.get("workers")) or 1
    path = os.path.join(run_dir, "workers.tsv")
    if not os.path.exists(path):
        if build_passed:
            problems.append(
                "the run declared {0} worker(s) but wrote no worker evidence "
                "(workers.tsv)".format(workers_declared))
        return records, problems
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            fields = raw.rstrip("\n").split("\t")
            if len(fields) < WORKER_FIELDS or not fields[0]:
                continue
            (name, device_name, device_udid, exit_code, wall_s, completed,
             sim_prep_failed, log_path) = fields[:WORKER_FIELDS]
            records.append({
                "name": name,
                "device": {"name": device_name, "udid": device_udid},
                "exit_code": exit_code,
                "wall_s": _num_or_zero(wall_s),
                "completed": completed == "1",
                "sim_prep_failed": sim_prep_failed == "1",
                "log": log_path,
            })
    if not records:
        problems.append("the run's worker evidence (workers.tsv) lists no worker")
        return records, problems

    # The unit worker always exists; the UI worker exists whenever the plan
    # carries UI classes (with one worker it is the same device, run after the
    # unit work).
    expected_names = ["unit"]
    if _int_or_zero((meta.get("expected") or {}).get("ui_classes")) > 0:
        expected_names.append("ui")
    seen = {rec["name"]: rec for rec in records}
    for name in expected_names:
        rec = seen.get(name)
        if rec is None:
            problems.append(
                "worker '{0}' has no record: the run cannot prove what it ran "
                "or where".format(name))
            continue
        if not rec["completed"]:
            problems.append(
                "worker '{0}' did not run to completion (exit {1}); its work is "
                "not certified".format(name, rec["exit_code"]))
        log_path = os.path.join(run_dir, rec["log"])
        if not os.path.exists(log_path):
            problems.append(
                "worker '{0}' recorded its log at {1}, which is missing from "
                "the run directory".format(name, rec["log"]))
    # Device identity: unit work on the primary device, UI work on the second
    # device when the run fanned out (otherwise both are the primary).
    primary = (meta.get("simulator") or {}).get("udid") or ""
    second = (meta.get("simulator2") or {}).get("udid") or ""
    if workers_declared > 1 and second and second == primary:
        problems.append("the run's two workers were assigned the SAME device "
                        "({0}); a fanned-out run must use two".format(primary))
    expect_device = {"unit": primary}
    expect_device["ui"] = second if workers_declared > 1 else primary
    for name, rec in seen.items():
        want = expect_device.get(name)
        if want and rec["device"].get("udid") != want:
            problems.append(
                "worker '{0}' ran on device {1} but the run assigned it {2}".format(
                    name, rec["device"].get("udid") or "?", want))
    return records, problems


def _lane_device_problems(passes, expect_device, require_named=False) -> list:
    """Every lane's OWN artifact must name the device of its worker.

    `require_named` is what makes this a PROOF rather than a formality: a
    fanned-out run has two devices in play, so a lane that does not say which
    one it used cannot be attributed to a worker at all. A one-worker run has
    a single device (every invocation was pinned to it), so a lane record
    without the field is merely tolerated there - and a lane that names a
    DIFFERENT device still fails in either case.
    """
    problems = []
    for lane_dir in passes:
        doc = load_json(os.path.join(lane_dir, "lane-result.json"))
        if not isinstance(doc, dict):
            continue
        name = os.path.basename(lane_dir)
        kind = "ui" if name.startswith("ui") else "unit"
        want = expect_device.get(kind) or ""
        if not want:
            continue
        record = doc.get("simulator")
        if not isinstance(record, dict) or not record.get("udid"):
            if require_named:
                problems.append(
                    "{0}: the lane result does not name the device it ran on, so "
                    "the run cannot prove which worker ran it".format(name))
            continue
        if record.get("udid") != want:
            problems.append(
                "{0}: the lane ran on device {1} but its worker owns {2}".format(
                    name, record.get("udid"), want))
    return problems


def cmd_summarize(args) -> int:
    run_dir = os.path.abspath(args.run_dir)
    meta = load_json(os.path.join(run_dir, "meta.json"))
    if not isinstance(meta, dict):
        fail("meta.json not readable under {0}".format(run_dir))
        return 3

    # Which certification this run is. A meta.json written before modes existed
    # describes a release run (the only kind there was), which is also the
    # strictest reading of it.
    mode = str(meta.get("mode") or "release")
    if mode not in ("merge", "release"):
        mode = "release"

    expected = meta.get("expected") or {}
    iterations = _int_or_zero(expected.get("repeat_iterations")) or 0
    declared_repeats = expected.get("repeat_classes")
    # Corrupt meta must fail closed with a problem, not raise: the shape is
    # only ever written by this tool, but "readable enough to parse" is not
    # the same as "well formed".
    repeat_classes = [str(c) for c in declared_repeats] \
        if isinstance(declared_repeats, list) else []
    allow_recovered = bool(meta.get("allowed_recovered_infrastructure"))
    run_flags = meta.get("run_flags") if isinstance(meta.get("run_flags"), dict) else {}

    phases = {}
    gate_problems = []

    # --- tested SHA -------------------------------------------------------
    tested_sha = str(meta.get("tested_sha") or "")
    if not HEX40.match(tested_sha):
        gate_problems.append(
            "tested SHA is not a full 40-character git commit id: {0!r}".format(tested_sha))

    # --- non-lane phases --------------------------------------------------
    for name in ("static", "build"):
        status, doc = _phase_status(run_dir, name)
        phases[name] = doc if doc else {"phase": name, "status": status,
                                       "duration_s": 0, "checks": []}
        if status != "pass":
            if name == "static" and not meta.get("static_checks_enabled"):
                phases[name]["status"] = "skipped"
                continue
            gate_problems.append("{0} phase: {1}".format(name, status))
        for check in (phases[name].get("checks") or []):
            if str(check.get("status")) != "pass":
                gate_problems.append("{0} check {1}: {2}".format(
                    name, check.get("name"), check.get("status")))

    # Simulator preparation is not a verdict: it is environment preparation
    # whose failure becomes a caveat on the result (see `caveats` below).
    sim_prep_status, sim_prep_doc = _phase_status(run_dir, "sim-prep")
    phases["sim-prep"] = sim_prep_doc if sim_prep_doc else {
        "phase": "sim-prep", "status": sim_prep_status, "duration_s": 0,
        "checks": []}
    # The bounded recovery round. Its outcome is evidence, not a verdict: what
    # decides the gate is whether the classes it retried now have results, and
    # whether the same infrastructure class came back.
    recovery_status, recovery_doc = _phase_status(run_dir, "recovery")
    phases["recovery"] = recovery_doc if recovery_doc else {
        "phase": "recovery", "status": recovery_status, "duration_s": 0,
        "checks": []}
    # (the number of recovery rounds that actually ran is counted from the
    # passes themselves - see infrastructure.retries below)

    # --- lanes ------------------------------------------------------------
    # UNIT and UI use the same collection: the primary lane, the unit lane's
    # continuation, and every recovery pass. Coverage is judged on the
    # aggregate, so work recovered in a later pass counts as executed and is
    # never reported unexecuted.
    lanes_root = os.path.join(run_dir, "lanes")
    unit_passes = _lane_pass_dirs(lanes_root, "unit", "unit-continuation",
                                  "unit-recovery")
    if not any(os.path.basename(d) == "unit" for d in unit_passes):
        # Mirror the UI check: without the primary lane, a recovery pass
        # would be promoted to index 0 and judged against the whole plan -
        # a mis-copied run directory could then certify a suite whose primary
        # lane never ran.
        gate_problems.append("unit lane results are missing")
    unit_expected, unit_expect_problems = _expected_classes(run_dir, "unit", expected)
    gate_problems.extend(unit_expect_problems)
    unit_summary = _summarize_lane_group(
        unit_passes, unit_expected,
        _int_or_zero(expected.get("unit_batches")) or None)
    if unit_summary is None:
        unit_summary = {"status": "missing", "executions": None, "failures": 0,
                        "synthetic_failures": 0, "classes_expected": 0,
                        "classes_observed": 0, "classes_missing": [],
                        "observed_names": [], "problems": [], "passes": []}
    gate_problems.extend("unit: " + p for p in unit_summary.get("problems") or [])
    # The recovery round is allowed once. If the pass it produced shows the
    # same infrastructure class again, the run fails as infrastructure and no
    # third attempt is made - the gate does not loop until green.
    for entry in unit_summary.get("passes") or []:
        if entry.get("is_launch_wedge") and _is_recovery_pass(entry.get("name")):
            gate_problems.append(
                "the recovery round hit the same simulator launch-refusal class "
                "again; no further recovery is attempted")

    ui_expected, ui_expect_problems = _expected_classes(run_dir, "ui", expected)
    ui_passes = []
    if ui_expected:
        gate_problems.extend(ui_expect_problems)
        ui_passes = _lane_pass_dirs(lanes_root, "ui", None, "ui-recovery")
        if not any("ui" == os.path.basename(d) for d in ui_passes):
            gate_problems.append("UI lane results are missing")
        ui_summary = _summarize_lane_group(ui_passes, ui_expected)
        if ui_summary is None:
            ui_summary = {"status": "missing", "executions": None, "failures": 0,
                          "synthetic_failures": 0, "classes_expected": 0,
                          "classes_observed": 0, "classes_missing": [],
                          "observed_names": [], "problems": [], "passes": []}
        gate_problems.extend("ui: " + p for p in ui_summary.get("problems") or [])
        # Same recurrence rule as unit: one recovery round, then FAIL.
        for entry in ui_summary.get("passes") or []:
            if entry.get("is_launch_wedge") and _is_recovery_pass(entry.get("name")):
                gate_problems.append(
                    "the UI recovery round hit the same simulator launch-refusal "
                    "class again; no further recovery is attempted")
    else:
        # No UI lane in the plan is legitimate (a repo with no UI classes), but
        # uiclasses recorded in meta.json with no lane means the run skipped
        # work it planned - that is a gate defect, not a clean pass.
        if _int_or_zero(expected.get("ui_classes")) > 0:
            gate_problems.append(
                "the run expected {0} UI classes but planned no UI lane".format(
                    expected.get("ui_classes")))
        ui_summary = {"status": "skipped", "executions": 0, "failures": 0,
                      "classes_expected": 0, "classes_observed": 0,
                      "problems": []}

    # --- workers ----------------------------------------------------------
    # Who ran what, on which device. A worker that did not complete, that is
    # missing from the record, or whose lanes name another device means the run
    # cannot certify its own coverage.
    build_passed = str(phases.get("build", {}).get("status")) == "pass"
    worker_records, worker_problems = _read_workers(run_dir, meta, build_passed)
    gate_problems.extend(worker_problems)
    workers_declared = _int_or_zero(meta.get("workers")) or 1
    primary_udid = (meta.get("simulator") or {}).get("udid") or ""
    second_udid = (meta.get("simulator2") or {}).get("udid") or ""
    expect_device = {
        "unit": primary_udid,
        "ui": second_udid if workers_declared > 1 else primary_udid,
    }
    if worker_records:
        gate_problems.extend(
            _lane_device_problems(
                list(unit_passes) + list(ui_passes), expect_device,
                require_named=workers_declared > 1))

    # --- repeats ----------------------------------------------------------
    repeats_dir = os.path.join(run_dir, "repeats")
    repeat_entries = _read_repeats(repeats_dir, repeat_classes, iterations) \
        if repeat_classes and iterations else []
    for entry in repeat_entries:
        gate_problems.extend(
            "repeat " + p for p in _repeat_problems(entry, iterations))
    repeat_executions = sum(
        i["executions"] or 0
        for entry in repeat_entries for i in entry["iterations"])
    repeat_failures = sum(
        i["failures"] for entry in repeat_entries for i in entry["iterations"])

    # --- classification roll-up ------------------------------------------
    events = {
        "assertion_failures": [],
        "infrastructure_failures": [],
        "infrastructure_recovered": [],
        "infrastructure_recovered_classes": [],
        "timeouts": [],
        "not_executed": [],
        "retries": [],
        "assertion_retried_until_green": [],
    }
    # The gate's OWN bounded recovery round, per suite. `round_healed` (a
    # round ran and NOTHING is missing anywhere) still gates the runner-
    # failure problem text and the round caveat; whether an INDIVIDUAL event
    # was healed is decided per entry by `_round_reran` below - that suite ran
    # a round, that round left the suite complete, and its observations cover
    # the event's work.
    # Basename match, never the full path: a --run-dir under ~/gate-recovery
    # would otherwise claim a round ran, let round_healed mark every test-
    # runner failure as recovered, and turn a must-fail run into a PASS with
    # an erase+retry that never happened.
    recovery_ran = any(
        _is_recovery_pass(entry.get("name"))
        for entry in (unit_summary.get("passes") or []) +
                    (ui_summary.get("passes") or []))
    incomplete_after_round = (unit_summary.get("classes_missing") or
                              ui_summary.get("classes_missing") or [])
    round_healed = bool(recovery_ran and not incomplete_after_round)
    for label, summary in (("unit", unit_summary), ("ui", ui_summary)):
        for key in ("assertion_failures", "infrastructure_failures", "timeouts",
                    "not_executed", "retries",
                    "assertion_retried_until_green"):
            for entry in summary.get(key) or []:
                item = dict(entry)
                item["lane"] = label
                events[key].append(item)
        for name in summary.get("infra_recovered_classes") or []:
            events["infrastructure_recovered_classes"].append(
                {"lane": label, "name": name})
    for entry in repeat_entries:
        for iteration in entry["iterations"]:
            label = "repeat:{0}#{1}".format(entry["class"], iteration["iteration"])
            for key in ("assertion_failures", "infrastructure_failures",
                        "timeouts", "not_executed", "retries",
                        "assertion_retried_until_green"):
                for item in iteration.get(key) or []:
                    tagged = dict(item)
                    tagged["lane"] = label
                    events[key].append(tagged)

    # Classification verdict. The gate never claims success on a run whose
    # environment misbehaved: a persistent infrastructure failure is fatal
    # always, and a *recovered* one means the run is not usable as release
    # evidence either (the operator reruns it) unless the caller explicitly
    # downgraded it. Assertions that were re-run until they passed are not
    # validation in any mode.
    #
    # The gate's bounded recovery round heals the infrastructure evidence
    # (`test-runner-failure`, `incomplete`, `unclassified`) when it actually
    # left the run complete - and it heals a hang too, but ONLY a hang whose
    # work it re-ran itself. A batch watchdog that fired while some of its
    # classes already had results leaves those classes' remaining cases
    # unexecuted; healing that hang would flip a must-FAIL run into PASS on
    # coverage the round never produced.
    # Both healing paths share ONE evidence rule (`_round_reran`): the round
    # heals an event only when the entry's SUITE ran a recovery pass, that
    # round left that SUITE complete, and the pass's own observations cover
    # every class the entry names. A unit round never heals UI evidence and
    # vice versa; an event whose work item the suite's round never observed
    # stays PERSISTENT and fails the run; a repeat lane is never healed (its
    # own bounded retry decides). An entry the LANE's retry already recovered
    # keeps ITS healer: docs/CI.md splits recovered infrastructure by healer,
    # and lane-runner-retry recovery stays fatal (only
    # --allow-recovered-infrastructure downgrades it) - the round must not
    # steal that provenance. A wedge INSIDE the round is still a FAIL - that
    # decision comes from the passes' `is_launch_wedge` check, not from these
    # counts.
    recovery_evidence = _recovery_observations(unit_summary, ui_summary)
    for entry in events["infrastructure_failures"]:
        if entry.get("recovered"):
            continue
        if not _round_reran(entry, recovery_evidence):
            continue
        entry["recovered"] = True
        entry["recovered_by"] = "gate recovery round"
    for entry in events["timeouts"]:
        if entry.get("recovered"):
            # Already recovered by the lane's own retry: same provenance
            # rule as infrastructure - it keeps its real healer.
            continue
        if not _round_reran(entry, recovery_evidence):
            continue
        entry["recovered"] = True
        entry["recovered_by"] = "gate recovery round"
    persistent_infra = [e for e in events["infrastructure_failures"]
                        if not e.get("recovered")]
    recovered_infra = [e for e in events["infrastructure_failures"]
                       if e.get("recovered")]
    persistent_timeouts = [e for e in events["timeouts"] if not e.get("recovered")]
    recovered_timeouts = [e for e in events["timeouts"] if e.get("recovered")]
    events["infrastructure_persistent"] = persistent_infra
    events["infrastructure_recovered"] = recovered_infra + recovered_timeouts
    # Only wedges healed by the lane runner's own retry (or an unaccounted
    # recovered label) keep the default failure: wedges the gate's bounded
    # recovery round healed are the intended, recorded outcome.
    healed_by_round = [e for e in recovered_infra
                       if e.get("recovered_by") == "gate recovery round"]
    # Recovered evidence split by HEALER (docs/CI.md): what the gate's round
    # healed is the recorded, intended outcome; what the LANE's own retry
    # healed is never trustworthy evidence - the operator reruns, and only
    # --allow-recovered-infrastructure downgrades it. Hangs follow the same
    # split.
    recovered_by_lane_retry = [e for e in recovered_infra
                               if e.get("recovered_by") != "gate recovery round"]
    lane_retry_timeouts = [
        e for e in recovered_timeouts
        if e.get("recovered_by") != "gate recovery round"]
    events["infrastructure_recovered_by_round"] = healed_by_round
    events["timeouts_recovered_by_round"] = [
        e for e in recovered_timeouts
        if e.get("recovered_by") == "gate recovery round"]
    if events["assertion_failures"] or repeat_failures or unit_summary.get("failures") \
            or ui_summary.get("failures"):
        gate_problems.append("genuine XCTest assertion failures present ({0})".format(
            len(events["assertion_failures"]) or
            unit_summary.get("failures") or ui_summary.get("failures")))
    runner_failures = int(unit_summary.get("synthetic_failures") or 0) + \
        int(ui_summary.get("synthetic_failures") or 0)
    if runner_failures and not round_healed:
        gate_problems.append(
            "the test runner never started the app under test ({0} XCTest "
            "'System Failures' entr{1}); the affected invocation is an "
            "infrastructure failure, not an assertion".format(
                runner_failures, "y" if runner_failures == 1 else "ies"))
    if persistent_infra or persistent_timeouts:
        gate_problems.append(
            "persistent infrastructure failure(s)/hang(s) present "
            "({0} infra, {1} timeout)".format(len(persistent_infra),
                                              len(persistent_timeouts)))
    # Both healers count (not just infrastructure): a hang the LANE's own
    # retry passed is recovered evidence too - without it the run would pass
    # silently with nothing recorded. Round-healed hangs are excluded by the
    # lists above: they are the recorded, intended outcome.
    if (recovered_by_lane_retry or lane_retry_timeouts) \
            and not allow_recovered:
        gate_problems.append(
            "infrastructure failures were recovered by a bounded retry"
            " ({0} infra, {1} timeout: {2}); the run is not trustworthy "
            "evidence - rerun the gate".format(
                len(recovered_by_lane_retry), len(lane_retry_timeouts),
                _csv(sorted({e["name"] for e in
                             recovered_by_lane_retry +
                             lane_retry_timeouts}))))
    # The lane runner also labels recovered classes directly. That label is
    # the same recovery seen through a second lens, so it is never ADDED to
    # the count - but a label the attempt chain cannot account for means the
    # evidence is incomplete, and that must not slip through as a clean run.
    recovered_names = sorted({e["name"] for e in
                             recovered_infra + recovered_timeouts})
    unaccounted = [entry for entry in events["infrastructure_recovered_classes"]
                   if not _covers_names(recovered_names, entry["name"])]
    if unaccounted and not allow_recovered:
        gate_problems.append(
            "lane result reports recovered infrastructure the attempt chain "
            "does not account for: {0}".format(
                _csv(sorted({e["name"] for e in unaccounted}))))
    if events["assertion_retried_until_green"]:
        gate_problems.append(
            "genuine assertions were retried until they passed ({0}: {1})".format(
                len(events["assertion_retried_until_green"]),
                _csv(sorted({e["name"] for e in
                             events["assertion_retried_until_green"]}))))

    deduped = _dedupe(gate_problems)
    verdict = "PASS" if not deduped else "FAIL"

    partial_reasons = []
    if not meta.get("static_checks_enabled"):
        partial_reasons.append("static checks skipped (--skip-static)")
    # Repeat coverage is part of the RELEASE mode's documented coverage, so its
    # absence only narrows a release run. A merge run is complete for what it
    # claims to be (see `mode`/`coverage` below) - marking it partial would
    # misdescribe a deliberate, documented certification as a degraded one.
    if not meta.get("repeat_policy_enabled") and mode == "release":
        partial_reasons.append(
            "repeat policy disabled (no repeat classes or zero iterations)")
    # Operating flags that weaken a run must be visible in the artifact the
    # result is cited from, not only in meta.json: a PASS whose environment
    # was degraded is not the same evidence as a clean one.
    caveats = []
    # Only claim a downgrade the flag actually PERFORMED: evidence the
    # recovery round healed left the verdict PASS without the flag, so the
    # caveat would describe a downgrade that never happened. The flag flips
    # exactly two problems - the lane-retry one above and an unaccounted
    # runner label - so those are the conditions.
    if allow_recovered and (recovered_by_lane_retry or lane_retry_timeouts
                            or unaccounted):
        caveats.append("--allow-recovered-infrastructure downgraded recovered "
                       "infrastructure from FAIL to this verdict")
    sim_record = meta.get("simulator") or {}
    if (not meta.get("xcode_version") or not sim_record.get("runtime")
            or not sim_record.get("udid")):
        caveats.append("environment identity incomplete: the Xcode version or "
                       "the simulator runtime/UDID could not be read for this run")
    if run_flags.get("lock_used") is False:
        caveats.append("--no-lock: another gate could have been running "
                       "concurrently on this Mac")
    if run_flags.get("simulator_prep") is False:
        caveats.append("--no-simulator-prep: the Simulator was not prepared "
                       "before the lanes")
    if str(phases.get("sim-prep", {}).get("status")) == "missing":
        caveats.append("sim-prep phase record missing; preparation status unknown")
    if str(phases.get("recovery", {}).get("status")) == "missing":
        caveats.append("recovery phase record missing; recovery status unknown")
    for entry in phases.get("sim-prep", {}).get("checks") or []:
        if str(entry.get("status")) != "pass":
            caveats.append("Simulator preparation failed before {0}".format(
                entry.get("name")))
    if round_healed:
        healed_infra_n = len(healed_by_round)
        healed_hangs_n = sum(
            1 for e in recovered_timeouts
            if e.get("recovered_by") == "gate recovery round")
        healed_desc = " and ".join(
            part for part in (
                "{0} infrastructure failure(s)".format(healed_infra_n)
                if healed_infra_n else "",
                "{0} hang(s)".format(healed_hangs_n)
                if healed_hangs_n else "") if part) or "0 evidence entries"
        caveats.append(
            "the bounded recovery round healed {0} after erasing the gate "
            "simulator; this run is not an entirely clean one".format(
                healed_desc))
    healed_repeats = [
        "{0}#{1}".format(entry["class"], iteration["iteration"])
        for entry in (repeat_entries or [])
        for iteration in entry.get("iterations") or []
        if iteration.get("satisfied") and
        _int_or_zero(iteration.get("attempts_count")) > 1]
    if healed_repeats:
        caveats.append(
            "the repeat policy used its one retry on {0} repetition(s) lost to "
            "the simulator launch wedge ({1})".format(
                len(healed_repeats), _csv(healed_repeats)))
    if unit_summary.get("reread_classes") or ui_summary.get("reread_classes"):
        reread = sorted(set(unit_summary.get("reread_classes") or []) |
                        set(ui_summary.get("reread_classes") or []))
        caveats.append(
            "classes produced results in more than one pass ({0}); counted once "
            "in the aggregate, but no pass should have re-run them".format(
                _csv(reread)))

    # Per-lane / per-repeat wall clock and invocation counts: the run's own
    # account of where its wall clock went (a green summary that needed 20
    # xcodebuild invocations to run 3 minutes of tests is visible here).
    lane_timings = _lane_timings(list(unit_passes) + list(ui_passes))
    repeat_timings = _lane_timings(sorted(
        os.path.join(repeats_dir, cls, it)
        for cls in (os.listdir(repeats_dir) if os.path.isdir(repeats_dir) else [])
        for it in (os.listdir(os.path.join(repeats_dir, cls))
                   if os.path.isdir(os.path.join(repeats_dir, cls)) else [])
        if os.path.isdir(os.path.join(repeats_dir, cls, it))))

    result = {
        "schema_version": SCHEMA_VERSION,
        "gate": "conduit-local-ci-gate",
        "verdict": verdict,
        # WHICH certification this is. Both modes cover the complete unit and
        # UI suites; they differ only in whether the repeat/stress policy is
        # part of the run. A release head requires mode=release on its exact
        # SHA (docs/CI.md) - this field is what makes that checkable from the
        # artifact rather than from the command line someone remembers.
        "mode": mode,
        "coverage": {
            "unit_suite": "complete",
            "ui_suite": "complete",
            "static_checks": bool(meta.get("static_checks_enabled")),
            "bounded_recovery": True,
            "repeat_policy": bool(meta.get("repeat_policy_enabled")),
            "workers": workers_declared,
        },
        "requested_ref": meta.get("requested_ref"),
        "tested_sha": tested_sha,
        "tooling_sha": meta.get("tooling_sha") or "",
        "tested_sha_short": tested_sha[:12],
        "xcode_version": meta.get("xcode_version"),
        "simulator": meta.get("simulator"),
        # The second project-owned device when the run fanned out; null for a
        # one-worker run.
        "simulator2": meta.get("simulator2") or None,
        "workers": worker_records,
        "timing": {
            "started_at": meta.get("started_at"),
            "finished_at": meta.get("finished_at"),
            "wall_s": meta.get("wall_s"),
            "phases": {name: doc.get("duration_s")
                       for name, doc in sorted(phases.items())},
            "lanes": lane_timings,
            "repeats": repeat_timings,
            "xcodebuild_invocations": (sum(
                entry.get("xcodebuild_invocations") or 0
                for entry in list(lane_timings.values()) +
                list(repeat_timings.values()))),
        },
        "static_checks": phases.get("static", {}).get("checks", []),
        "build": {
            "status": phases.get("build", {}).get("status", "missing"),
            "duration_s": phases.get("build", {}).get("duration_s"),
            "xctestrun": (phases.get("build", {}).get("details") or {}).get("xctestrun", ""),
            "note": phases.get("build", {}).get("note", ""),
        },
        # A PARTIAL run is one the operator deliberately narrowed: it can
        # never be cited as the exhaustive gate result for a release head, so
        # the reasons are recorded explicitly rather than inferred from the
        # absence of artifacts.
        "partial": bool(partial_reasons),
        "partial_reasons": partial_reasons,
        "caveats": caveats,
        "run_flags": run_flags,
        "unit": unit_summary,
        "ui": ui_summary,
        "focused_repeats": {
            "enabled": bool(repeat_classes and iterations),
            "iterations_per_class": iterations,
            "classes": repeat_entries,
            "executions": repeat_executions,
            "failures": repeat_failures,
        },
        "infrastructure": {
            "failures": len(events["infrastructure_failures"]),
            "persistent": len(persistent_infra) + len(persistent_timeouts),
            "recovered": len(events["infrastructure_recovered"]),
            # The gate's one bounded recovery round: whether it was used, and
            # what it recovered. A recurrence after it is persistent.
            "retries": sum(1 for entry in
                   (unit_summary.get("passes") or []) +
                   (ui_summary.get("passes") or [])
                   if _is_recovery_pass(entry.get("name"))),
            "retry_detail": phases["recovery"].get("checks") or [],
            "timeouts": len(events["timeouts"]),
            "not_executed": len(events["not_executed"]),
            "simulator_resets": int(bool(unit_summary.get("simulator_reset"))) +
                                int(bool(ui_summary.get("simulator_reset"))),
            "simulator_erases": int(bool(unit_summary.get("simulator_erase"))) +
                               int(bool(ui_summary.get("simulator_erase"))),
            "events": events,
        },
        "assertion_rerun_until_green": len(events["assertion_retried_until_green"]),
        "problems": deduped,
        "artifacts": {
            "run_dir": run_dir,
            "gate_result": os.path.join(run_dir, "gate-result.json"),
            "summary_md": os.path.join(run_dir, "summary.md"),
            "build_log": os.path.join(run_dir, "build", "build.log"),
            "unit_dir": os.path.join(run_dir, "lanes", "unit"),
            "unit_continuation_dir": (os.path.join(run_dir, "lanes",
                                                   "unit-continuation")
                                      if os.path.isdir(os.path.join(run_dir, "lanes",
                                                                    "unit-continuation"))
                                      else None),
            "ui_dir": os.path.join(run_dir, "lanes", "ui") if ui_expected else None,
            "repeats_dir": repeats_dir if repeat_entries else None,
        },
    }
    write_json(args.out, result)
    if args.markdown:
        _write_markdown(args.markdown, result)
    _print_human(result)

    if verdict == "PASS":
        print("local gate: PASS")
        return 0
    print("local gate: FAIL ({0} problem(s) - see {1})".format(
        len(deduped), os.path.abspath(args.out)))
    return 1


def _expected_classes(run_dir: str, kind: str, expected: dict):
    """Return (planned_classes_or_None, problems).

    The planned class list comes from the projection the shell wrote. When it
    is unreadable the gate cannot know WHICH classes were planned - meta.json
    carries counts, not names - so the completeness check has nothing to
    compare against: that is reported, never silently treated as "everything
    ran". The recorded count is cross-checked as well, so a stale or
    truncated projection can never certify a shorter run than was planned.
    """
    count_key = "unit_classes" if kind == "unit" else "ui_classes"
    declared = expected.get(count_key)
    doc = load_json(os.path.join(run_dir, "lanes.json"))
    classes = None
    if isinstance(doc, dict):
        entry = doc.get(kind)
        if isinstance(entry, dict) and entry.get("classes"):
            classes = list(entry["classes"])
    if classes is None:
        if isinstance(declared, int) and declared > 0:
            return None, ["{0}: the planned class list is missing from the run "
                          "directory although {1} {0} classes were expected - "
                          "completeness cannot be checked".format(kind, declared)]
        return None, []
    if isinstance(declared, int) and declared != len(classes):
        return classes, ["{0}: the plan projection lists {1} classes but the run "
                         "recorded {2}".format(kind, len(classes), declared)]
    return classes, []


def _dedupe(items):
    seen = set()
    out = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


def _covers_names(names, candidate: str) -> bool:
    """True when `candidate` names one of the classes in `names`.

    Attempt entries name a batch by its class list ("AlphaTests,BetaTests")
    while the lane runner labels a recovered CLASS by its own name, so the
    match has to be by CSV member, not by string equality.
    """
    for name in names:
        if candidate in [part for part in str(name).split(",") if part]:
            return True
    return False


def _classes_have_results(observed, name: str) -> bool:
    """True when every class named by `name` has a result.

    The counterpart of _covers_names: a "not executed" entry names work as a
    batch ("AlphaTests,BetaTests"), so it is only stale when ALL of its
    classes produced a result in some pass.
    """
    parts = [part for part in str(name or "").split(",") if part]
    return bool(parts) and all(part in observed for part in parts)


def _write_markdown(path: str, result: dict) -> None:
    unit = result["unit"]
    ui = result["ui"]
    repeats = result["focused_repeats"]
    infra = result["infrastructure"]
    lines = []
    lines.append("# Conduit local gate: {0}".format(result["verdict"]))
    lines.append("")
    lines.append("Tested commit: `{0}` (requested `{1}`)".format(
        result["tested_sha"], result["requested_ref"]))
    lines.append("")
    coverage = result.get("coverage") or {}
    lines.append(
        "- Mode: **{0}** ({1})".format(
            result.get("mode") or "release",
            "complete unit + UI coverage, static checks, bounded recovery, and "
            "the repeat/stress policy" if (result.get("mode") or "release") == "release"
            else "complete unit + UI coverage, static checks, bounded recovery - "
                 "NO repeat/stress policy, so this is not on its own a release "
                 "certificate"))
    workers = result.get("workers") or []
    if workers:
        lines.append("- Workers: {0}".format(", ".join(
            "{0} on {1} ({2})".format(
                w.get("name"), (w.get("device") or {}).get("name") or "?",
                (w.get("device") or {}).get("udid") or "?")
            for w in workers)))
    sim2 = result.get("simulator2") or {}
    if sim2:
        lines.append("- Second device: {0} / {1} ({2})".format(
            sim2.get("name") or "?", sim2.get("runtime") or "?",
            sim2.get("udid") or "?"))
    lines.append("- Xcode: {0}".format(
        (result.get("xcode_version") or "").strip() or "unknown"))
    sim = result.get("simulator") or {}
    lines.append("- Simulator: {0} / {1} ({2})".format(
        sim.get("name") or "?", sim.get("runtime") or "?", sim.get("udid") or "?"))
    lines.append("- Wall clock: {0}s".format(result["timing"]["wall_s"]))
    if result.get("partial"):
        lines.append("- **PARTIAL RUN — not an exhaustive-gate result:** {0}".format(
            "; ".join(result.get("partial_reasons") or ["unspecified"])))
    for caveat in result.get("caveats") or []:
        lines.append("- **CAVEAT:** {0}".format(caveat))
    lines.append("")
    lines.append("| Phase | Status | Executions | Failures | Duration |")
    lines.append("|---|---|---|---|---|")
    lines.append("| build (once) | {0} | - | - | {1}s |".format(
        result["build"]["status"], result["build"]["duration_s"]))
    lines.append("| unit (ConduitTests) | {0} | {1} | {2} | {3}s |".format(
        unit.get("status"), unit.get("executions"), unit.get("failures"),
        unit.get("duration_s")))
    lines.append("| UI (ConduitUITests) | {0} | {1} | {2} | {3}s |".format(
        ui.get("status"), ui.get("executions"), ui.get("failures"),
        ui.get("duration_s")))
    if repeats.get("enabled"):
        lines.append("| repeats ({0} x {1} classes) | {2} | {3} | {4} | - |".format(
            repeats["iterations_per_class"], len(repeats["classes"]),
            "pass" if not repeats["failures"] else "fail",
            repeats["executions"], repeats["failures"]))
    lines.append("")
    lines.append("Classes: {0}/{1} unit, {2}/{3} UI executed.".format(
        unit.get("classes_observed"), unit.get("classes_expected"),
        ui.get("classes_observed"), ui.get("classes_expected")))
    lines.append("")
    lines.append("Infrastructure: {0} failure(s), {1} recovered, {2} timeout(s), "
                 "{3} persistent, {4} retry attempt(s), {5} simulator "
                 "reset(s)/{6} erase(s).".format(
                     infra["failures"], infra["recovered"], infra["timeouts"],
                     infra["persistent"], infra["retries"],
                     infra["simulator_resets"], infra["simulator_erases"]))
    if repeats.get("enabled"):
        lines.append("")
        lines.append("Repeat policy (unconditional repetitions, no retry):")
        for entry in repeats["classes"]:
            statuses = ", ".join(
                "iter {0}: {1} ({2} exec, {3} fail)".format(
                    i["iteration"], i["status"], i["executions"], i["failures"])
                for i in entry["iterations"])
            lines.append("- `{0}`: {1}".format(entry["class"], statuses))
    if result["problems"]:
        lines.append("")
        lines.append("## Problems")
        lines.append("")
        for problem in result["problems"]:
            lines.append("- {0}".format(problem))
    lines.append("")
    lines.append("Artifacts: `{0}`".format(result["artifacts"]["run_dir"]))
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines) + "\n")


def _print_human(result: dict) -> None:
    unit = result["unit"]
    ui = result["ui"]
    repeats = result["focused_repeats"]
    print("")
    print("=== Conduit local gate ===")
    print("tested SHA : {0}  (requested {1})".format(
        result["tested_sha"], result["requested_ref"]))
    print("mode       : {0}{1}".format(
        result.get("mode") or "release",
        "" if (result.get("mode") or "release") == "release"
        else "  (complete coverage, no repeat/stress policy)"))
    for worker in result.get("workers") or []:
        print("worker     : {0} on {1} ({2}) - exit {3}, {4}s, completed={5}".format(
            worker.get("name"), (worker.get("device") or {}).get("name"),
            (worker.get("device") or {}).get("udid"), worker.get("exit_code"),
            worker.get("wall_s"), worker.get("completed")))
    print("xcode      : {0}".format(
        (result.get("xcode_version") or "").strip() or "unknown"))
    sim = result.get("simulator") or {}
    print("simulator  : {0} / {1}".format(sim.get("name"), sim.get("runtime")))
    print("wall clock : {0}s".format(result["timing"]["wall_s"]))
    print("build      : {0} ({1}s)".format(
        result["build"]["status"], result["build"]["duration_s"]))
    print("unit       : {0} - {1} executions, {2} failures, "
          "{3}/{4} classes ({5}s)".format(
              unit.get("status"), unit.get("executions"), unit.get("failures"),
              unit.get("classes_observed"), unit.get("classes_expected"),
              unit.get("duration_s")))
    print("ui         : {0} - {1} executions, {2} failures, "
          "{3}/{4} classes ({5}s)".format(
              ui.get("status"), ui.get("executions"), ui.get("failures"),
              ui.get("classes_observed"), ui.get("classes_expected"),
              ui.get("duration_s")))
    if repeats.get("enabled"):
        print("repeats    : {0} class(es) x {1} iterations - {2} executions, "
              "{3} failures".format(len(repeats["classes"]),
                                    repeats["iterations_per_class"],
                                    repeats["executions"], repeats["failures"]))
    infra = result["infrastructure"]
    print("infra      : {0} failure(s), {1} recovered, {2} timeout(s), "
          "{3} persistent, {4} retry attempt(s), {5} simulator "
          "reset(s)/{6} erase(s)".format(
              infra["failures"], infra["recovered"], infra["timeouts"],
              infra["persistent"], infra["retries"],
              infra["simulator_resets"], infra["simulator_erases"]))
    if result.get("partial"):
        print("PARTIAL    : {0}".format("; ".join(result.get("partial_reasons") or [])))
    for caveat in result.get("caveats") or []:
        print("CAVEAT     : {0}".format(caveat))
    if result["problems"]:
        print("problems:")
        for problem in result["problems"]:
            print("  - {0}".format(problem))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("lanes")
    p.add_argument("--plan", required=True)
    p.add_argument("--out", required=True, help="shell-sourceable env file")
    p.add_argument("--json-out", default="",
                   help="plan-projection audit copy (read back by summarize)")
    p.set_defaults(func=cmd_lanes)

    p = sub.add_parser("repeat-spec")
    p.add_argument("--plan", required=True)
    p.add_argument("--classes", required=True, help="comma-separated class names")
    p.add_argument("--iterations", type=int, default=3)
    p.add_argument("--timeout-cap", type=int, default=REPEAT_BATCH_TIMEOUT_CAP_DEFAULT)
    p.add_argument("--out", required=True)
    p.add_argument("--tsv-out", default="",
                   help="TSV of per-class repeat tasks (read by the gate shell)")
    p.set_defaults(func=cmd_repeat_spec)

    p = sub.add_parser("not-run-batches")
    p.add_argument("--plan", required=True)
    p.add_argument("--lane-result", required=True)
    p.add_argument("--out", required=True, help="shell-sourceable env file")
    p.set_defaults(func=cmd_not_run_batches)

    p = sub.add_parser("meta")
    p.add_argument("--out", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--tooling-sha", default="")
    p.add_argument("--xcode", default="")
    p.add_argument("--simulator", default="")
    p.add_argument("--runtime", default="")
    p.add_argument("--simulator-udid", default="")
    p.add_argument("--simulator2", default="")
    p.add_argument("--simulator2-runtime", default="")
    p.add_argument("--simulator2-udid", default="")
    p.add_argument("--mode", default="release")
    p.add_argument("--workers", type=int, default=1)
    p.add_argument("--unit-batch-max-classes", type=int, default=0)
    p.add_argument("--started-at", default="")
    p.add_argument("--finished-at", default="")
    p.add_argument("--wall-s", type=int, default=0)
    p.add_argument("--unit-classes", type=int, default=0)
    p.add_argument("--unit-batches", type=int, default=0)
    p.add_argument("--ui-classes", type=int, default=0)
    p.add_argument("--repeat-classes", default="")
    p.add_argument("--repeat-iterations", type=int, default=0)
    p.add_argument("--allow-recovered-infrastructure", action="store_true")
    p.add_argument("--skip-static", action="store_true")
    p.add_argument("--lock-used", default="")
    p.add_argument("--simulator-prep", default="")
    p.set_defaults(func=cmd_meta)

    p = sub.add_parser("simulator")
    p.add_argument("--devices", required=True,
                   help="JSON from `xcrun simctl list devices available -j`")
    p.add_argument("--name", required=True)
    p.add_argument("--udid", default="")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_simulator)

    p = sub.add_parser("phase")
    p.add_argument("--out", required=True)
    p.add_argument("--phase", required=True)
    p.add_argument("--status", required=True)
    p.add_argument("--duration", type=int, default=0)
    p.add_argument("--exit-code", type=int, default=None)
    p.add_argument("--note", default="")
    p.add_argument("--check", action="append", default=[],
                   help="name:status:seconds[:note] (repeatable)")
    p.add_argument("--detail", action="append", default=[],
                   help="KEY=VALUE phase detail (repeatable)")
    p.set_defaults(func=cmd_phase)

    p = sub.add_parser("recovery-spec")
    p.add_argument("--plan", required=True)
    p.add_argument("--kind", default="unit", choices=["unit", "ui"])
    p.add_argument("--lane", required=True,
                   help="comma-separated lane result directories so far")
    p.add_argument("--timeout-cap", type=int, default=REPEAT_BATCH_TIMEOUT_CAP_DEFAULT)
    p.add_argument("--out", required=True, help="shell-sourceable env file")
    p.add_argument("--tsv-out", default="",
                   help="TSV of per-class retry tasks (read by the gate shell)")
    p.set_defaults(func=cmd_recovery_spec)

    p = sub.add_parser("is-infra-only")
    p.add_argument("--lane-dir", required=True)
    p.set_defaults(func=cmd_is_infra_only)

    p = sub.add_parser("summarize")
    p.add_argument("--run-dir", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--markdown", default="")
    p.set_defaults(func=cmd_summarize)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
