#!/usr/bin/env python3
"""Fresh-runner recovery classification and final unit verdict for CI v2.

The GitHub-hosted macOS fleet occasionally stalls a unit lane outright: the
whole-lane invocation hits its watchdog, the same-runner isolation re-runs
classes individually (they pass), but the isolation budget is exhausted and
the lane finishes red with ZERO identified test failures. PR #175
demonstrated the shape twice; re-running the lane on a fresh hosted runner
passes. Same-runner retries cannot fix it - every invocation inside one job
stays on the same broken Mac - so the recovery is a second, bounded GitHub
Actions job on a NEW macos-26 runner.

This module is the single source of truth for

  * classifying one lane-result.json into the recovery taxonomy
    (``classify_lane_result``) - embedded into every lane result at write
    time by extract-test-timings.py and re-derived at read time by the
    recovery planner and the CI Gate (mismatch fails closed);
  * scanning downloaded lane artifacts (``scan_lane_results`` /
    ``dedupe_lane_results``) - artifact names carry the run attempt, so a
    re-run of failed jobs produces one document per (lane, attempt) and the
    newest attempt wins deterministically;
  * the final per-lane unit verdict (``adjudicate_unit_lanes``): every
    planned lane gets exactly one disposition - pass, recovered (exactly one
    fresh-runner pass), or FAIL - and anything missing, duplicated,
    unplanned, malformed, or inconsistent with the plan fails closed.

The classifier is deliberately conservative. Recovery eligibility requires
ALL of:

  1. the lane is a unit lane;
  2. the PRIMARY (first full-lane) invocation hit its watchdog
     (status "timeout");
  3. zero failing test methods are known anywhere in the lane metadata -
     no failure records, no "test-failures" attempt status, no isolation
     class failure (a watchdog-killed extraction with no readable result
     counts as "nothing identified", which is exactly the demonstrated
     stall shape);
  4. the lane result is complete enough to reconstruct the lane
     (attempts/isolation chain readable, consistent with its own embedded
     classification).

Anything else - ordinary test failures, unclassifiable failures, infra
errors that already burned their same-runner retry, a retry-timeout whose
primary never watchdoged, or a fresh-runner retry that stalls AGAIN - is
final. A fresh-runner retry (``fresh_runner_recovery``) is never itself
eligible for another recovery: there is no third attempt.

Stdlib only (runs on ubuntu and macOS runners).
"""

from __future__ import annotations

import json
import os
import re
import sys

# Lane-result classifications (the machine-readable recovery taxonomy).
CLASS_PASS = "pass"
CLASS_TEST_FAILURE = "test-failure"
CLASS_RECOVERABLE_TIMEOUT_ZERO_FAILURES = "recoverable-timeout-zero-failures"
CLASS_NONRECOVERABLE_INFRASTRUCTURE = "nonrecoverable-infrastructure"
CLASS_UNCLASSIFIABLE = "unclassifiable"

RECOVERY_ELIGIBLE_CLASSES = frozenset({CLASS_RECOVERABLE_TIMEOUT_ZERO_FAILURES})

# Artifact naming (ci.yml): lane-<lane>-attempt-<n> for primary lanes,
# lane-recovery-<lane>-attempt-<n> for fresh-runner recovery lanes.
ARTIFACT_NAME_RE = re.compile(
    r"^lane-(?:(?P<recovery>recovery)-)?"
    r"(?P<lane>.+?)(?:-attempt-(?P<attempt>\d+))?$")

_LANE_RESULT_SCHEMA_VERSION = 1


def warn(msg: str) -> None:
    print(f"::warning::ci-lane-recovery: {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# classification
# ---------------------------------------------------------------------------

def _attempts(doc: dict) -> list:
    attempts = doc.get("attempts")
    return attempts if isinstance(attempts, list) else []


def _primary_attempt(attempts: list):
    """The first full-lane invocation record, or None."""
    for att in attempts:
        if isinstance(att, dict) and att.get("mode") == "lane":
            return att
    return None


def _isolation_classes(doc: dict) -> list:
    isolation = doc.get("isolation")
    if not isinstance(isolation, dict):
        return []
    classes = isolation.get("classes")
    return classes if isinstance(classes, list) else []


def _known_test_failures(doc) -> tuple:
    """(method_failures, signals): the failing test methods KNOWN to the
    lane metadata, plus coarser failure signals (attempt/isolation records
    used when the extraction itself was killed). Empty is not a claim that
    none occurred - a watchdog can kill the run before any result was
    written (exactly the demonstrated stall: extraction of the corrupted
    bundle failed safely and `failures` is absent)."""
    failures = doc.get("failures")
    method_failures = [f for f in failures if isinstance(f, dict)] \
        if isinstance(failures, list) else []
    signals = []
    for att in _attempts(doc):
        if isinstance(att, dict) and att.get("status") == "test-failures":
            signals.append({"attempt_status": "test-failures"})
    for cls in _isolation_classes(doc):
        if isinstance(cls, dict) and cls.get("status") == "fail":
            signals.append({"isolation_failure": cls.get("class")})
    return method_failures, signals


def _attempt_chain(attempts: list) -> str:
    return " -> ".join(
        str(att.get("status", "?")) for att in attempts if isinstance(att, dict))


def classify_lane_result(doc):
    """Classify one parsed lane-result.json document.

    Returns (classification, reason). classification is None for UI lanes
    (fresh-runner recovery is unit-only); every unit document maps to one
    of the CLASS_* values, failing closed on anything unreadable or self-
    inconsistent.
    """
    if not isinstance(doc, dict):
        return CLASS_UNCLASSIFIABLE, "lane result is not an object"
    kind = doc.get("kind")
    if kind == "ui":
        return None, "UI lanes are outside fresh-runner recovery scope"
    if kind != "unit":
        return CLASS_UNCLASSIFIABLE, f"unknown lane kind {kind!r}"

    status = doc.get("status")
    attempts = _attempts(doc)
    fresh = bool(doc.get("fresh_runner_recovery"))
    method_failures, failure_signals = _known_test_failures(doc)
    known = bool(method_failures or failure_signals)
    primary = _primary_attempt(attempts)
    primary_watchdog = bool(primary) and primary.get("status") == "timeout"
    chain = _attempt_chain(attempts)

    if not attempts:
        return (CLASS_UNCLASSIFIABLE,
                "lane result carries no attempt chain (fail closed)")

    if known:
        count = len(method_failures) or len(failure_signals)
        return (CLASS_TEST_FAILURE,
                f"{count} failing test method(s) identified "
                f"(attempt chain: {chain})")

    if status == "pass":
        # A pass must be internally consistent: no hung class and no
        # isolation record with a non-passing class.
        if doc.get("hung_class"):
            return (CLASS_UNCLASSIFIABLE,
                    "status is pass but a hung class is recorded (fail closed)")
        bad_isolation = [
            cls.get("class") for cls in _isolation_classes(doc)
            if isinstance(cls, dict) and cls.get("status") != "pass"]
        if bad_isolation:
            return (CLASS_UNCLASSIFIABLE,
                    "status is pass but isolation recorded non-passing "
                    f"classes: {', '.join(map(str, bad_isolation))} (fail closed)")
        return CLASS_PASS, f"lane passed (attempt chain: {chain})"

    if status == "timeout":
        if not primary_watchdog:
            # The retry of a zero-failure infra error stalled: the primary
            # never hit the watchdog, and that failure mode already had its
            # same-runner retry. Not the demonstrated host-stall shape.
            return (CLASS_NONRECOVERABLE_INFRASTRUCTURE,
                    "a retry invocation timed out but the primary invocation "
                    f"did not hit its watchdog (attempt chain: {chain})")
        if fresh:
            return (CLASS_NONRECOVERABLE_INFRASTRUCTURE,
                    "fresh-runner retry stalled again with zero identified "
                    "test failures - no further attempt is permitted "
                    f"(attempt chain: {chain})")
        return (CLASS_RECOVERABLE_TIMEOUT_ZERO_FAILURES,
                "primary invocation hit its watchdog with zero identified "
                f"test failures (attempt chain: {chain})")

    if status == "error":
        return (CLASS_NONRECOVERABLE_INFRASTRUCTURE,
                f"persistent infrastructure failure (attempt chain: {chain})")

    # status "fail" without any identified failure record, or any unknown
    # status value: the outcome cannot be trusted either way.
    return (CLASS_UNCLASSIFIABLE,
            f"lane status {status!r} without identified failures "
            f"(attempt chain: {chain})")


def embedded_classification(doc):
    """The classification embedded at write time, or None if absent."""
    recovery = doc.get("recovery") if isinstance(doc, dict) else None
    if not isinstance(recovery, dict):
        return None
    value = recovery.get("classification")
    return value if isinstance(value, str) else None


# ---------------------------------------------------------------------------
# artifact scanning + dedupe
# ---------------------------------------------------------------------------

class LaneResultRecord:
    """One lane-result.json found under downloaded artifact directories."""

    __slots__ = ("path", "artifact_name", "is_recovery_artifact",
                 "attempt", "artifact_lane", "doc", "error")

    def __init__(self, path, artifact_name, doc=None, error=None):
        self.path = path
        self.artifact_name = artifact_name
        self.doc = doc
        self.error = error
        match = ARTIFACT_NAME_RE.match(artifact_name or "")
        self.is_recovery_artifact = bool(match and match.group("recovery"))
        self.attempt = int(match.group("attempt")) if match and match.group("attempt") else None
        self.artifact_lane = match.group("lane") if match else None


def parse_artifact_name(name):
    """(lane, is_recovery, attempt) encoded in a lane artifact's name, or
    None when the name does not follow the lane-*-attempt-N convention."""
    match = ARTIFACT_NAME_RE.match(name or "")
    if not match:
        return None
    return (match.group("lane"), bool(match.group("recovery")),
            int(match.group("attempt")) if match.group("attempt") else None)


def scan_lane_results(root):
    """Find every lane-result.json under `root` (a directory of extracted
    artifacts: <root>/<artifact-name>/<lane-dir>/lane-result.json) and
    return LaneResultRecord list. Unreadable documents are returned as
    error records - consumers decide whether that fails closed."""
    records = []
    if not root or not os.path.isdir(root):
        return records
    for dirpath, _dirnames, filenames in os.walk(root):
        if "lane-result.json" not in filenames:
            continue
        path = os.path.join(dirpath, "lane-result.json")
        relative = os.path.relpath(dirpath, root)
        artifact_name = relative.split(os.sep)[0] if relative != "." else ""
        try:
            with open(path, encoding="utf-8") as fh:
                doc = json.load(fh)
            if not isinstance(doc, dict):
                raise ValueError("lane result is not a JSON object")
            records.append(LaneResultRecord(path, artifact_name, doc=doc))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            records.append(LaneResultRecord(path, artifact_name, error=str(exc)))
    return records


def _finished_at_key(record):
    doc = record.doc or {}
    stamp = doc.get("finished_at")
    if isinstance(stamp, str) and stamp:
        return stamp
    return ""  # undated documents lose against any dated one


def dedupe_lane_results(records):
    """Collapse per-lane attempt duplicates deterministically: the newest
    finished_at wins (a re-run of failed jobs re-uploads only the re-run
    lanes, and both attempts' artifacts remain downloadable).

    Returns (by_lane, conflicts): by_lane maps lane -> the winning record
    (only records that carry a parsed document); conflicts is a list of
    human-readable problems - undated or ambiguous documents the caller
    must treat as fatal (fail closed)."""
    by_lane = {}
    conflicts = []
    grouped = {}
    for record in records:
        if record.doc is None:
            conflicts.append(f"unreadable lane result {record.path}: {record.error}")
            continue
        lane = record.doc.get("lane")
        if not isinstance(lane, str) or not lane:
            conflicts.append(f"lane result {record.path} has no lane name (fail closed)")
            continue
        if not _finished_at_key(record):
            conflicts.append(
                f"lane result {record.path} has no finished_at stamp; cannot "
                "order re-run attempts (fail closed)")
            continue
        grouped.setdefault(lane, []).append(record)

    for lane, lane_records in grouped.items():
        lane_records.sort(key=lambda r: (r.artifact_name, r.path))
        newest = max(lane_records, key=_finished_at_key)
        # Another record with the SAME stamp but a different document would
        # make the winner ambiguous - refuse rather than guess.
        for other in lane_records:
            if other is newest:
                continue
            if _finished_at_key(other) == _finished_at_key(newest) \
                    and other.doc != newest.doc:
                conflicts.append(
                    f"ambiguous lane results for {lane}: {other.path} and "
                    f"{newest.path} share finished_at "
                    f"{_finished_at_key(newest)} but differ (fail closed)")
        by_lane[lane] = newest
    return by_lane, conflicts


# ---------------------------------------------------------------------------
# final unit verdict
# ---------------------------------------------------------------------------

FINAL_PASS = "pass"
FINAL_RECOVERED = "recovered-infrastructure-pass"
FINAL_FAIL = "fail"


class Adjudication:
    def __init__(self):
        self.passed = True
        self.failures = []
        self.dispositions = []

    def fail(self, message):
        self.passed = False
        self.failures.append(message)

    def lane_fail(self, lane, message):
        self.fail(f"{lane}: {message}")


def _classes_match(planned, documented) -> bool:
    if not isinstance(documented, list):
        return False
    return sorted(map(str, documented)) == sorted(map(str, planned))


def _numbers_match(a, b) -> bool:
    try:
        return a is not None and b is not None and abs(float(a) - float(b)) < 0.01
    except (TypeError, ValueError):
        return False


def plan_disagreements(lane_entry, doc, record=None, primary=True):
    """Every way a lane result document disagrees with its authoritative
    plan entry - the ONE fail-closed artifact/plan fence, shared by the
    recovery planner (ci-recovery-plan.py) and the gate adjudication, so
    both consumers accept or reject a document identically. With
    primary=False (a fresh-runner recovery document) the primary-only
    fences (fresh-runner flag, recovery artifact name) are skipped but the
    coverage fields are still enforced."""
    mismatches = []
    if not isinstance(doc, dict):
        return ["lane result is not an object"]
    if doc.get("kind") != "unit":
        mismatches.append(f"kind {doc.get('kind')!r} != 'unit'")
    if doc.get("lane") != lane_entry.get("lane"):
        mismatches.append(
            f"lane name {doc.get('lane')!r} != planned {lane_entry.get('lane')!r}")
    if record is not None:
        if record.artifact_lane is not None \
                and record.artifact_lane != lane_entry.get("lane"):
            mismatches.append(
                f"artifact name says lane {record.artifact_lane!r}")
        if primary and record.is_recovery_artifact:
            mismatches.append(
                "primary result uploaded under a recovery artifact name")
    if not _classes_match(lane_entry.get("classes", []), doc.get("classes")):
        mismatches.append("lane membership differs from the plan")
    if doc.get("target") != lane_entry.get("target"):
        mismatches.append(
            f"target {doc.get('target')!r} != planned {lane_entry.get('target')!r}")
    if not _numbers_match(doc.get("timeout_s"), lane_entry.get("timeout_s")):
        mismatches.append("watchdog budget differs from the plan")
    if doc.get("schema_version") != _LANE_RESULT_SCHEMA_VERSION:
        mismatches.append(
            f"schema_version {doc.get('schema_version')!r} != "
            f"{_LANE_RESULT_SCHEMA_VERSION}")
    if primary and doc.get("fresh_runner_recovery"):
        mismatches.append(
            "a primary lane result must not carry the fresh-runner flag")
    return mismatches


def adjudicate_unit_lanes(plan_doc, unit_docs, recovery_docs):
    """Adjudicate every planned unit lane to exactly one final disposition.

    plan_doc     parsed plan.json (unit_lanes is the lane-membership
                 authority);
    unit_docs    lane -> primary LaneResultRecord (already deduped);
    recovery_docs lane -> list of recovery LaneResultRecords.

    The returned Adjudication lists one disposition per planned lane plus
    every fence violation (missing/malformed/inconsistent metadata,
    unplanned or duplicate recovery results)."""
    adjudication = Adjudication()
    if not isinstance(plan_doc, dict) or not isinstance(
            plan_doc.get("unit_lanes"), list):
        adjudication.fail("plan artifact is missing or has no unit_lanes")
        return adjudication

    planned_lanes = []
    validated_entries = []
    for lane_entry in plan_doc["unit_lanes"]:
        lane = lane_entry.get("lane") if isinstance(lane_entry, dict) else None
        if not isinstance(lane, str) or not lane:
            adjudication.fail("plan contains a unit lane without a name")
            continue
        planned_lanes.append(lane)
        validated_entries.append(lane_entry)

    recovery_lanes = set(recovery_docs or {})

    for lane_entry in validated_entries:
        lane = lane_entry.get("lane")
        record = unit_docs.get(lane)
        disposition = {
            "lane": lane,
            "original": None,
            "original_reason": None,
            "recovery": None,
            "recovery_detail": None,
            "final": FINAL_FAIL,
        }

        if record is None:
            reason = "no lane-result artifact found (fail closed)"
            adjudication.lane_fail(lane, reason)
            disposition["original"] = "missing"
            disposition["original_reason"] = reason
            disposition["recovery_detail"] = "adjudicated"
            adjudication.dispositions.append(disposition)
            continue

        doc = record.doc
        # --- artifact/plan agreement (fail closed) --------------------------
        mismatches = plan_disagreements(lane_entry, doc, record, primary=True)
        if mismatches:
            reason = "lane result disagrees with the plan: " + "; ".join(mismatches)
            adjudication.lane_fail(lane, reason)
            disposition["original"] = "inconsistent"
            disposition["original_reason"] = reason
            adjudication.dispositions.append(disposition)
            continue

        # --- classification: re-derive AND cross-check the embedded one ----
        classification, reason = classify_lane_result(doc)
        embedded = embedded_classification(doc)
        if embedded is None:
            reason = ("lane result predates recovery metadata "
                      "(no embedded classification; fail closed)")
            adjudication.lane_fail(lane, reason)
            disposition["original"] = "unclassifiable"
            disposition["original_reason"] = reason
            adjudication.dispositions.append(disposition)
            continue
        if embedded != classification:
            reason = (f"embedded classification {embedded!r} != re-derived "
                      f"{classification!r} (fail closed)")
            adjudication.lane_fail(lane, reason)
            disposition["original"] = "inconsistent"
            disposition["original_reason"] = reason
            adjudication.dispositions.append(disposition)
            continue

        disposition["original"] = classification
        disposition["original_reason"] = reason

        if classification == CLASS_PASS:
            disposition["final"] = FINAL_PASS
            adjudication.dispositions.append(disposition)
            continue

        if classification != CLASS_RECOVERABLE_TIMEOUT_ZERO_FAILURES:
            adjudication.lane_fail(
                lane, f"final classification {classification}: {reason}")
            disposition["recovery_detail"] = "not requested"
            adjudication.dispositions.append(disposition)
            continue

        # --- recoverable: exactly one fresh-runner pass or FAIL -------------
        records = recovery_docs.get(lane) or []
        if not records:
            disposition["recovery"] = "missing"
            disposition["recovery_detail"] = "no fresh-runner result"
            adjudication.lane_fail(
                lane, "recoverable stall but no fresh-runner retry ran "
                "(recovery missing)")
            adjudication.dispositions.append(disposition)
            continue
        if len(records) > 1:
            disposition["recovery"] = "duplicate"
            disposition["recovery_detail"] = (
                f"{len(records)} fresh-runner results")
            adjudication.lane_fail(
                lane, f"{len(records)} fresh-runner results found; "
                "exactly one attempt is permitted")
            adjudication.dispositions.append(disposition)
            continue

        recovery_record = records[0]
        recovery_doc = recovery_record.doc
        bad_flags = []
        if not recovery_doc.get("fresh_runner_recovery"):
            bad_flags.append("result is not marked fresh_runner_recovery")
        if recovery_doc.get("lane") != lane:
            bad_flags.append(f"recovery lane name {recovery_doc.get('lane')!r}")
        if not recovery_record.is_recovery_artifact:
            bad_flags.append("uploaded outside a lane-recovery-* artifact")
        # The recovery must ALSO agree with the plan: same target, same
        # membership, same watchdog, same schema. A recovery that executed
        # anything else never satisfies the lane's coverage. (The
        # primary-only fences live in the primary branch above.)
        bad_flags.extend(
            plan_disagreements(lane_entry, recovery_doc, recovery_record,
                               primary=False))
        if bad_flags:
            reason = "recovery result invalid: " + "; ".join(bad_flags)
            adjudication.lane_fail(lane, reason)
            disposition["recovery"] = "invalid"
            disposition["recovery_detail"] = reason
            adjudication.dispositions.append(disposition)
            continue

        recovery_class, recovery_reason = classify_lane_result(recovery_doc)
        recovery_embedded = embedded_classification(recovery_doc)
        if recovery_embedded is None:
            reason = ("recovery result predates recovery metadata "
                      "(no embedded classification; fail closed)")
            adjudication.lane_fail(lane, reason)
            disposition["recovery"] = "invalid"
            disposition["recovery_detail"] = reason
            adjudication.dispositions.append(disposition)
            continue
        if recovery_embedded != recovery_class:
            reason = (f"recovery result embedded classification "
                      f"{recovery_embedded!r} != re-derived "
                      f"{recovery_class!r} (fail closed)")
            adjudication.lane_fail(lane, reason)
            disposition["recovery"] = "invalid"
            disposition["recovery_detail"] = reason
            adjudication.dispositions.append(disposition)
            continue

        disposition["recovery"] = recovery_class
        disposition["recovery_detail"] = recovery_reason
        if recovery_class == CLASS_PASS:
            disposition["final"] = FINAL_RECOVERED
        else:
            adjudication.lane_fail(
                lane, f"fresh-runner retry did not pass "
                f"({recovery_class}): {recovery_reason}")
        adjudication.dispositions.append(disposition)

    # --- unplanned recovery results -----------------------------------------
    planned = set(planned_lanes)
    for lane in sorted(recovery_lanes - planned):
        adjudication.fail(
            f"fresh-runner result for unplanned lane {lane!r} (fail closed)")
    for lane, records in sorted((recovery_docs or {}).items()):
        for record in records:
            if record.doc is None:
                adjudication.fail(
                    f"unreadable fresh-runner result {record.path}: "
                    f"{record.error}")
    # A recovery result attached to a lane that did not need one: harmless
    # corroboration when it is a clean pass (the lane's primary was re-run
    # and passed after a recovery run had already been planned), but a
    # non-pass recovery anywhere else is a fence violation.
    dispositions_by_lane = {d["lane"]: d for d in adjudication.dispositions}
    for lane in sorted(recovery_lanes & planned):
        disposition = dispositions_by_lane.get(lane)
        if disposition and disposition.get("original") == \
                CLASS_RECOVERABLE_TIMEOUT_ZERO_FAILURES:
            continue  # handled per-lane above
        for record in recovery_docs.get(lane) or []:
            if record.doc is None:
                continue  # already reported as unreadable
            recovery_class, _reason = classify_lane_result(record.doc)
            if recovery_class != CLASS_PASS:
                adjudication.fail(
                    f"{lane}: fresh-runner result for a lane that was not "
                    f"recovery-eligible ({recovery_class}) - fail closed")
                break
    return adjudication


def disposition_line(d: dict) -> str:
    """One human-readable line per disposition, in the report's voice."""
    lane = d.get("lane")
    original = d.get("original")
    recovery = d.get("recovery")
    final = d.get("final")
    if final == FINAL_RECOVERED:
        return (f"{lane}: original {original} (zero identified test "
                f"failures), fresh runner {recovery}, final: recovered "
                "infrastructure PASS")
    if final == FINAL_PASS:
        return f"{lane}: original pass, final: PASS"
    detail = d.get("recovery_detail") or d.get("original_reason") or ""
    return f"{lane}: original {original}, fresh runner {recovery}, final: FAIL ({detail})"


# ---------------------------------------------------------------------------
# CLI: the timing-history preflight
# ---------------------------------------------------------------------------

def _cmd_adjudicate(args) -> int:
    """Exit 0 iff every planned unit lane ends green (pass or exactly-one
    recovered pass). The timing-history job uses this as its preflight: a
    recovered main run must still evolve timing history, a genuinely red
    run must not - and the decision uses lane artifacts, never the raw
    matrix job result."""
    try:
        with open(args.plan_json, encoding="utf-8") as fh:
            plan_doc = json.load(fh)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"plan artifact unreadable ({exc}); refusing to update history")
        return 2

    all_records = scan_lane_results(args.unit_lanes_dir) + \
        scan_lane_results(args.recovery_lanes_dir)
    # Partition BEFORE dedupe: a lane's recovery document shares the lane
    # name with its primary document and must never collapse into it.
    unit_records = [r for r in all_records
                    if r.doc is None or not r.doc.get("fresh_runner_recovery")]
    recovery_records = [r for r in all_records
                        if r.doc is not None and r.doc.get("fresh_runner_recovery")]
    unit_docs, conflicts = dedupe_lane_results(unit_records)
    recovery_deduped, recovery_conflicts = dedupe_lane_results(recovery_records)
    recovery_groups = {lane: [record]
                       for lane, record in recovery_deduped.items()}
    for problem in conflicts + recovery_conflicts:
        warn(problem)
    if conflicts or recovery_conflicts:
        print("ambiguous lane artifacts; refusing to update history")
        return 2

    adjudication = adjudicate_unit_lanes(plan_doc, unit_docs, recovery_groups)
    for line in adjudication.dispositions:
        print(disposition_line(line))
    for failure in adjudication.failures:
        print(f"gate failure: {failure}")
    if not adjudication.passed:
        print("final unit verdict: FAIL - timing history must not be updated")
        return 1
    print("final unit verdict: green - timing history may be updated")
    return 0


def main(argv=None) -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser(
        "adjudicate",
        help="final unit verdict from lane artifacts (timing-history preflight)")
    p.add_argument("--plan-json", required=True)
    p.add_argument("--unit-lanes-dir", required=True)
    p.add_argument("--recovery-lanes-dir", required=True)
    p.set_defaults(func=_cmd_adjudicate)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
