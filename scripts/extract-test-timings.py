#!/usr/bin/env python3
"""CI v2 timing extraction and report aggregation for Hermes Conduit.

Subcommands
-----------
extract      Read an .xcresult bundle via `xcrun xcresulttool` and normalize
             per-XCTest-class durations plus per-test retry attempts into JSON.
lane-result  Merge bash-computed lane facts with extraction output into the
             canonical lane-result.json consumed by the report job.
aggregate    Build the human-readable CI Test Report (GitHub Step Summary)
             from plan.json + lane-result.json files + build-result.json.

Design rules (see docs/CI.md):
  * Timing extraction is NEVER allowed to fail a CI lane. Any structural
    surprise in the xcresult schema exits with code 3 and the caller falls
    back to previously known timing history.
  * Aggregate output is best-effort reporting; it never changes job status.
  * Only Python 3 stdlib is used (runs on ubuntu and macOS runners).
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys

SCHEMA_VERSION = 1

# Exit codes with contractual meaning for callers.
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_SCHEMA = 3  # xcresult structure not understood -> caller keeps old history


def warn(msg: str) -> None:
    print(f"::warning::extract-test-timings: {msg}", file=sys.stderr)


def info(msg: str) -> None:
    print(msg)


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# extract
# ---------------------------------------------------------------------------

def _duration_seconds(node: dict) -> float:
    """Best-effort duration of a node in seconds. Missing durations are 0."""
    raw = node.get("durationInSeconds")
    if isinstance(raw, (int, float)) and raw >= 0:
        return float(raw)
    text = node.get("duration")
    if isinstance(text, str):
        m = re.fullmatch(r"\s*([0-9]+(?:\.[0-9]+)?)s?\s*", text)
        if m:
            return float(m.group(1))
    return 0.0


def _norm_result(node: dict) -> str:
    r = node.get("result")
    return r if isinstance(r, str) else "Unknown"


def _walk_bundle(bundle: dict, stats: dict, problems: list) -> None:
    """Walk one test-bundle node, accumulating class-level durations and
    per-test attempts. Class = nearest enclosing Test Suite node."""
    suite_stack: list = []

    def visit(node: dict) -> None:
        ntype = str(node.get("nodeType", ""))
        ntype_l = ntype.lower()
        name = str(node.get("name", "?"))
        if "test case" in ntype_l:
            if not suite_stack:
                problems.append(f"test case {name!r} with no enclosing suite")
                return
            cls = suite_stack[-1]
            seconds = _duration_seconds(node)
            stats["class_seconds"].setdefault(cls, 0.0)
            stats["class_seconds"][cls] += seconds
            key = f"{cls}/{name}"
            stats["attempts"].setdefault(key, {"class": cls, "test": name, "attempts": []})
            stats["attempts"][key]["attempts"].append(
                {"result": _norm_result(node), "seconds": seconds}
            )
            return
        if "test suite" in ntype_l:
            suite_stack.append(name)
            for child in node.get("children", []) or []:
                visit(child)
            suite_stack.pop()
            return
        # Unknown intermediate node (e.g. future grouping types): descend so
        # partial schema changes degrade to warnings instead of hard failure.
        if node.get("children"):
            problems.append(f"unrecognized node type {ntype!r} (descended anyway)")
            for child in node.get("children", []) or []:
                visit(child)

    for child in bundle.get("children", []) or []:
        visit(child)


def extract(xcresult: str) -> dict:
    """Run xcresulttool on an .xcresult bundle and normalize the document."""
    cmd = ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", xcresult]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except FileNotFoundError:
        raise RuntimeError("xcrun not found; timing extraction requires macOS/Xcode")
    except subprocess.TimeoutExpired:
        raise RuntimeError("xcresulttool timed out after 300s")
    if proc.returncode != 0:
        raise RuntimeError(
            "xcresulttool exited {0}: {1}".format(
                proc.returncode, proc.stderr.strip()[:500])
        )
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"xcresulttool produced invalid JSON: {exc}")
    return extract_from_doc(data, xcresult)


def extract_from_doc(data: dict, xcresult_label: str) -> dict:
    """Normalize an already-parsed xcresulttool document. Pure function so the
    regression tests can exercise schema handling without macOS."""
    if not isinstance(data, dict) or "testNodes" not in data:
        raise RuntimeError("xcresult JSON missing 'testNodes'; schema changed?")

    problems: list = []
    stats = {"class_seconds": {}, "attempts": {}}
    bundles_seen = []

    for top in data.get("testNodes", []) or []:
        for bundle in top.get("children", []) or []:
            btype = str(bundle.get("nodeType", "")).lower()
            if "test bundle" not in btype:
                continue
            bundle_name = str(bundle.get("name", "?"))
            bundles_seen.append(bundle_name)
            _walk_bundle(bundle, stats, problems)

    attempts = list(stats["attempts"].values())
    for att in attempts:
        att["final"] = att["attempts"][-1]["result"] if att["attempts"] else "Unknown"
        att["attempts_count"] = len(att["attempts"])
    failures = [
        {"class": a["class"], "test": a["test"], "attempts": a["attempts"]}
        for a in attempts
        if a["final"].lower() == "failed"
    ]
    flaky = [
        {"class": a["class"], "test": a["test"], "attempts": a["attempts"],
         "final": a["final"]}
        for a in attempts
        if a["attempts_count"] > 1
    ]
    total_cases = sum(len(a["attempts"]) for a in attempts)

    if not bundles_seen:
        raise RuntimeError("no test bundle nodes found in xcresult")
    if not stats["class_seconds"] and not attempts:
        # A run can legitimately contain zero tests, but never in our CI.
        raise RuntimeError("xcresult contained no test cases")

    for p in problems:
        warn(p)

    doc = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": now_iso(),
        "xcresult": os.path.basename(str(xcresult_label).rstrip("/")),
        "bundles": bundles_seen,
        "classes": {k: round(v, 3) for k, v in sorted(stats["class_seconds"].items())},
        "attempts": sorted(attempts, key=lambda a: (a["class"], a["test"])),
        "failures": failures,
        "retried": flaky,
        "counts": {"classes": len(stats["class_seconds"]), "cases": total_cases},
    }
    return doc


# ---------------------------------------------------------------------------
# lane-result
# ---------------------------------------------------------------------------

def lane_result(args) -> int:
    result = {
        "schema_version": SCHEMA_VERSION,
        "lane": args.lane,
        "kind": args.kind,
        "target": args.target,
        "classes": [c for c in args.classes.split(",") if c],
        "status": args.status,
        "predicted_s": args.predicted_s,
        "timeout_s": args.timeout_s,
        "actual_s": round(args.actual_s, 1) if args.actual_s is not None else None,
        "started_at": args.started_at,
        "finished_at": now_iso(),
        "attempts": json.loads(args.attempts_json) if args.attempts_json else [],
        "simulator_reset": bool(args.simulator_reset),
        "simulator_erase": bool(args.simulator_erase),
        "hung_class": args.hung_class or None,
        "isolation": json.loads(args.isolation_json) if args.isolation_json else None,
    }
    # Merge extraction outputs when available (flaky/failures/class timings).
    if args.observations and os.path.exists(args.observations):
        with open(args.observations, encoding="utf-8") as fh:
            obs = json.load(fh)
        result["class_seconds"] = obs.get("classes", {})
    if args.detail and os.path.exists(args.detail):
        with open(args.detail, encoding="utf-8") as fh:
            detail = json.load(fh)
        result["failures"] = detail.get("failures", [])
        result["flaky"] = detail.get("retried", [])

    text = json.dumps(result, indent=2, sort_keys=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text + "\n")
    info(f"lane result written: {args.out} (status={args.status})")
    return EXIT_OK


# ---------------------------------------------------------------------------
# aggregate
# ---------------------------------------------------------------------------

def _fmt_secs(s):
    if s is None:
        return "-"
    m, sec = divmod(int(round(s)), 60)
    return f"{m}m {sec:02d}s" if m else f"{sec}s"


def _load_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def aggregate(args) -> int:
    lines: list = []
    plan = _load_json(args.plan)

    lanes = plan.get("unit_lanes", [])
    ui = plan.get("ui_lane") or {}

    results = {}  # lane name -> lane-result dict
    for root, _dirs, files in os.walk(args.lanes_dir):
        for fname in files:
            if fname == "lane-result.json":
                path = os.path.join(root, fname)
                try:
                    doc = _load_json(path)
                    results[doc.get("lane", path)] = doc
                except (OSError, json.JSONDecodeError) as exc:
                    warn(f"unreadable lane result {path}: {exc}")

    build = None
    if args.build_result and os.path.exists(args.build_result):
        try:
            build = _load_json(args.build_result)
        except (OSError, json.JSONDecodeError) as exc:
            warn(f"unreadable build result: {exc}")

    lines.append("# CI Test Report")
    lines.append("")

    # --- Build -------------------------------------------------------------
    lines.append("## Build")
    if build:
        lines.append(
            f"- Status: **{build.get('status', '?')}**"
            f"  -  Duration: {_fmt_secs(build.get('duration_s'))}"
        )
        if build.get("shared_artifact") is not None:
            lines.append(
                f"- Shared build artifact: **{'yes' if build['shared_artifact'] else 'no'}**"
                " (downstream lanes run test-without-building from downloaded products)"
            )
    else:
        lines.append("- No build result artifact found (build job may have failed early).")
    lines.append("")

    # --- Unit lanes ----------------------------------------------------------
    lines.append("## Unit lanes")
    lines.append("")
    lines.append("| Lane | Predicted | Actual | Status | Classes |")
    lines.append("|---|---|---|---|---|")
    any_actual = True
    for lane in lanes:
        name = lane.get("lane")
        res = results.get(name, {})
        actual = res.get("actual_s")
        if actual is None:
            any_actual = False
        lines.append(
            f"| {name} | {_fmt_secs(lane.get('predicted_s'))} | {_fmt_secs(actual)} "
            f"| {res.get('status', 'no result')} | {len(lane.get('classes', []))} |"
        )
    if not lanes:
        lines.append("| (no unit lanes planned) | | | | |")
    lines.append("")

    # --- UI ------------------------------------------------------------------
    lines.append("## UI")
    if ui:
        name = ui.get("lane", "ui")
        res = results.get(name, {})
        lines.append(
            f"- {name} ({', '.join(ui.get('classes', []))}): "
            f"predicted {_fmt_secs(ui.get('predicted_s'))}, "
            f"actual {_fmt_secs(res.get('actual_s'))}, status **{res.get('status', 'no result')}**"
        )
    else:
        lines.append("- No UI tests planned.")
    lines.append("")

    # --- Retries / flaky -----------------------------------------------------
    flaky_rows = [
        (name, res) for name, res in sorted(results.items())
        if res.get("flaky")
    ]
    lines.append("## Retries & flaky tests")
    if not flaky_rows:
        lines.append("- None: every test passed on its first attempt.")
    else:
        for name, res in flaky_rows:
            for fl in res["flaky"]:
                chain = " -> ".join(
                    "{0} ({1})".format(a["result"], _fmt_secs(a["seconds"]))
                    for a in fl.get("attempts", [])
                )
                lines.append(f"- `{fl['class']}/{fl['test']}` [{name}]: {chain}")
            lines.append(
                f"  - **FLAKE WARNING**: {name} passed only after retry - investigate."
            )
    lines.append("")

    # --- Failures / hangs ------------------------------------------------------
    failed_rows = [
        (name, res) for name, res in sorted(results.items())
        if res.get("status") not in (None, "pass")
    ]
    if failed_rows:
        lines.append("## Failures & diagnostics")
        for name, res in failed_rows:
            lines.append(f"### {name} - status **{res.get('status')}**")
            lines.append(
                f"- predicted {_fmt_secs(res.get('predicted_s'))} vs actual "
                f"{_fmt_secs(res.get('actual_s'))}; watchdog budget "
                f"{_fmt_secs(res.get('timeout_s'))}"
            )
            if res.get("simulator_reset") or res.get("simulator_erase"):
                kind = "erase" if res.get("simulator_erase") else "reset"
                lines.append(f"- simulator {kind} performed during recovery")
            attempts = res.get("attempts", [])
            if attempts:
                chain = " -> ".join(str(a.get("status", "?")) for a in attempts)
                lines.append(f"- attempts: {chain}")
            if res.get("hung_class"):
                lines.append(
                    f"- **HANG identified by isolation mode: `{res['hung_class']}`** "
                    "(lane timed out; class-granular rerun pinned this class)"
                )
            if res.get("isolation"):
                lines.append("- isolation per-class results:")
                for cls in res["isolation"].get("classes", []):
                    lines.append(
                        f"  - `{cls.get('class')}`: {cls.get('status')} "
                        f"({_fmt_secs(cls.get('seconds'))})"
                    )
            for failure in res.get("failures", [])[:20]:
                lines.append(f"- failing test: `{failure.get('test')}`")
            lines.append("")

    # --- Slowest classes -------------------------------------------------------
    merged: dict = {}
    for res in results.values():
        for cls, secs in (res.get("class_seconds") or {}).items():
            merged[cls] = max(secs, merged.get(cls, 0.0))
    if merged:
        lines.append("## Slowest test classes (this run)")
        lines.append("")
        lines.append("| Class | Seconds |")
        lines.append("|---|---|")
        for cls, secs in sorted(merged.items(), key=lambda kv: -kv[1])[:10]:
            lines.append(f"| {cls} | {secs:.1f} |")
        lines.append("")

    # --- Imbalance & wall clock -------------------------------------------------
    if lanes:
        preds = [l.get("predicted_s") or 0.0 for l in lanes]
        avg_p = sum(preds) / len(preds)
        imb_p = (max(preds) - min(preds)) / avg_p * 100 if avg_p else 0.0
        lines.append(f"- Predicted lane imbalance: **{imb_p:.1f}%** (from the timing plan)")
        if any_actual:
            actuals = [
                results[l["lane"]]["actual_s"] for l in lanes if l["lane"] in results
            ]
            if len(actuals) == len(lanes) and actuals:
                avg_a = sum(actuals) / len(actuals)
                imb_a = (max(actuals) - min(actuals)) / avg_a * 100 if avg_a else 0.0
                lines.append(f"- Actual lane imbalance: **{imb_a:.1f}%**")

    starts, ends = [], []
    for res in results.values():
        if res.get("started_at"):
            starts.append(res["started_at"])
        if res.get("finished_at"):
            ends.append(res["finished_at"])
    if build and build.get("started_at"):
        starts.append(build["started_at"])
    if build and build.get("finished_at"):
        ends.append(build["finished_at"])
    if starts and ends:
        def parse(ts):
            return datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
        span = max(parse(t) for t in ends) - min(parse(t) for t in starts)
        total = int(span.total_seconds())
        lines.append(
            f"- Overall wall clock (build start -> last lane finish): "
            f"**{_fmt_secs(total)}**"
        )
    lines.append("")

    text = "\n".join(lines)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print(text)
    return EXIT_OK


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("extract", help="extract timings from an .xcresult")
    p.add_argument("--xcresult", required=True)
    p.add_argument("--observations", help="write class-duration JSON here")
    p.add_argument("--detail", help="write attempts/failures JSON here")
    p.set_defaults(func=lambda a: _cmd_extract(a))

    p = sub.add_parser("lane-result", help="assemble lane-result.json")
    p.add_argument("--lane", required=True)
    p.add_argument("--kind", required=True, choices=["unit", "ui"])
    p.add_argument("--target", required=True)
    p.add_argument("--classes", default="")
    p.add_argument("--status", required=True)
    p.add_argument("--predicted-s", type=float, default=None)
    p.add_argument("--timeout-s", type=float, default=None)
    p.add_argument("--actual-s", type=float, default=None)
    p.add_argument("--started-at", default=None)
    p.add_argument("--attempts-json", default="")
    p.add_argument("--isolation-json", default="")
    p.add_argument("--simulator-reset", action="store_true")
    p.add_argument("--simulator-erase", action="store_true")
    p.add_argument("--hung-class", default="")
    p.add_argument("--observations", default="")
    p.add_argument("--detail", default="")
    p.add_argument("--out", required=True)
    p.set_defaults(func=lambda a: lane_result(a))

    p = sub.add_parser("aggregate", help="build the CI Test Report summary")
    p.add_argument("--plan", required=True)
    p.add_argument("--lanes-dir", required=True)
    p.add_argument("--build-result", default="")
    p.add_argument("--out", required=True)
    p.set_defaults(func=lambda a: aggregate(a))

    args = parser.parse_args(argv)
    return args.func(args)


def _cmd_extract(a) -> int:
    try:
        doc = extract(a.xcresult)
    except RuntimeError as exc:
        warn(f"timing extraction failed safely: {exc}")
        return EXIT_SCHEMA
    if a.observations:
        slim = {
            "schema_version": SCHEMA_VERSION,
            "generated_at": doc["generated_at"],
            "xcresult": doc["xcresult"],
            "bundles": doc["bundles"],
            "classes": doc["classes"],
            "counts": doc["counts"],
        }
        with open(a.observations, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(slim, indent=2, sort_keys=True) + "\n")
    if a.detail:
        slim = {
            "schema_version": SCHEMA_VERSION,
            "generated_at": doc["generated_at"],
            "xcresult": doc["xcresult"],
            "attempts": doc["attempts"],
            "failures": doc["failures"],
            "retried": doc["retried"],
        }
        with open(a.detail, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(slim, indent=2, sort_keys=True) + "\n")
    info(
        f"extracted timings: {doc['counts']['classes']} classes, "
        f"{doc['counts']['cases']} case attempts, "
        f"{len(doc['failures'])} failures, {len(doc['retried'])} retried tests"
    )
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
