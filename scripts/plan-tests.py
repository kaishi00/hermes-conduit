#!/usr/bin/env python3
"""CI v2 test planner for Hermes Conduit.

Replaces the static unit-a..unit-d shard system:

  * discovers every XCTestCase class under ConduitTests/ and ConduitUITests/
    directly from the Swift sources (no Xcode runtime discovery needed);
  * validates complete, duplicate-free inventory (a new test class cannot
    silently miss CI);
  * assigns unit classes to a dynamic number of lanes with longest-
    processing-time-first balancing over historical duration estimates;
  * derives measured per-lane watchdog budgets from those predictions;
  * emits a GitHub Actions matrix JSON for dynamic unit lanes.

Subcommands
-----------
plan             Validate + write plan.json / unit-matrix.json / summary md.
validate         Same validation, human report, no files written (cheap Linux guard).
audit-xctestrun  Fail unless all absolute paths inside a built .xctestrun live
                 under the workspace root (build-once artifact portability gate).

Determinism: identical inputs produce byte-identical outputs (no timestamps).
Timing input precedence: --history (Actions-cache timing history) > --baseline
(checked-in fallback) > DEFAULT_ESTIMATE_S for unseen classes. Corrupt or
missing timing files never fail planning.
"""

from __future__ import annotations

import argparse
import heapq
import json
import math
import os
import plistlib
import re
import sys

SCHEMA_VERSION = 1

# Planning configuration (overridable via flags for tests).
DEFAULT_ESTIMATE_S = 20.0          # unseen/new classes: conservative, not sticky
MIN_LANES = 4
MAX_LANES = 8
TARGET_LANE_BUDGET_S = 240.0       # scale-out threshold per lane
LANE_TIMEOUT_MIN_S = 300           # healthy lanes never get less than 5 min
LANE_TIMEOUT_MULTIPLIER = 2.5      # headroom over prediction
UI_TIMEOUT_MIN_S = 420             # UI lane floor (simulator interaction overhead)
JOB_TIMEOUT_MARGIN_S = 1200        # reset/erase overhead + setup/download slack
UNIT_TARGET = "ConduitTests"
UI_TARGET = "ConduitUITests"

# A class declaration line: attributes, optional access level, optional final,
# then "class Name: InheritanceClause". Single-line inheritance is the repo
# convention; the colon anchor keeps mere XCTestCase mentions from matching.
DECL_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:open|public|internal|private|fileprivate)\s+)?"
    r"(?:final\s+)?class\s+([A-Za-z_]\w*)\s*:\s*([^{=;]+)"
)
FIRST_IDENT_RE = re.compile(r"\s*([A-Za-z_]\w*)")


def warn(msg: str) -> None:
    # GitHub Actions parses workflow commands from STDOUT only; stderr would
    # never render as an annotation.
    print(f"::warning::plan-tests: {msg}")


# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------

def _swift_files(root: str) -> list:
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for f in sorted(files):
            if f.endswith(".swift"):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def _parse_decl(line: str):
    m = DECL_RE.match(line)
    if not m:
        return None
    name = m.group(1)
    clause = m.group(2).strip()
    # Direct superclass = first comma-separated element, minus generics.
    first = clause.split(",")[0]
    im = FIRST_IDENT_RE.match(first)
    superclass = im.group(1) if im else ""
    return name, superclass


def discover_test_classes(repo_root: str) -> dict:
    """Discover XCTest classes per target directory. Directory membership (not
    class-name suffix) decides ConduitTests vs ConduitUITests."""
    result = {
        "unit": [], "ui": [],            # [{"name","file","line"}]
        "helpers": [],                   # [{"name","file","line"}]
        "errors": [], "warnings": [],
    }
    # Targets are separate Swift modules: superclass resolution is per target
    # so one target's base class can never redirect the other's ancestry.
    all_classes = {UNIT_TARGET: {}, UI_TARGET: {}}
    direct = {UNIT_TARGET: set(), UI_TARGET: set()}
    file_hits = {UNIT_TARGET: [], UI_TARGET: []}

    for target in (UNIT_TARGET, UI_TARGET):
        root = os.path.join(repo_root, target)
        if not os.path.isdir(root):
            result["errors"].append(f"target directory missing: {target}/")
            continue
        for path in _swift_files(root):
            with open(path, encoding="utf-8", errors="replace") as fh:
                content = fh.read()
            has_test_func = "func test" in content
            for lineno, line in enumerate(content.splitlines(), start=1):
                decl = _parse_decl(line)
                if decl is None:
                    continue
                name, superclass = decl
                rel = os.path.relpath(path, repo_root).replace(os.sep, "/")
                all_classes[target].setdefault(name, superclass)
                if superclass == "XCTestCase":
                    direct[target].add(name)
                file_hits[target].append(
                    {"name": name, "file": rel, "line": lineno,
                     "has_test_func": has_test_func}
                )

    def is_xctestcase(target: str, name: str) -> bool:
        classes = all_classes[target]
        seen = set()
        cur = name
        while cur and cur not in seen:
            seen.add(cur)
            if cur == "XCTestCase":
                return True
            cur = classes.get(cur, "")
        return False

    # Plannable = runs tests in the XCTest runtime:
    #   * *Tests-named classes that resolve to XCTestCase (direct or
    #     transitive) - the repo convention for real suites, or
    #   * direct XCTestCase subclasses with visible test methods and an
    #     unconventional name (kept planned, with a warning).
    # Everything else that merely resolves to XCTestCase (mocks, fakes, test
    # helpers such as MockGateway/FakeSocket, with or without a direct
    # XCTestCase inheritance but no Tests suffix and no visible test methods)
    # enumerates zero tests and is excluded from lanes exactly as the static
    # shard system excluded it.
    for target, bucket in ((UNIT_TARGET, "unit"), (UI_TARGET, "ui")):
        seen_names = {}
        for entry in file_hits[target]:
            name = entry["name"]
            resolves = is_xctestcase(target, name)
            if not resolves and name.endswith("Tests"):
                result["errors"].append(
                    "malformed test declaration: {0} in {1}:{2} looks like a test "
                    "class but does not inherit XCTestCase (directly or "
                    "transitively); it will never execute".format(
                        name, entry["file"], entry["line"])
                )
                continue
            if not resolves:
                continue  # unrelated helper class
            is_suite = name.endswith("Tests") or entry["has_test_func"]
            if not is_suite:
                # Zero visible test methods + unconventional name: a mock or
                # support type. -only-testing would match zero tests for it.
                result["helpers"].append(
                    {"name": name, "file": entry["file"], "line": entry["line"]}
                )
                continue
            if name in seen_names:
                result["errors"].append(
                    f"duplicate test class {name!r} in {target}/: "
                    f"{seen_names[name]} and {entry['file']}:{entry['line']}"
                )
            else:
                seen_names[name] = f"{entry['file']}:{entry['line']}"
                result[bucket].append(
                    {"name": name, "file": entry["file"], "line": entry["line"]}
                )
                if not name.endswith("Tests"):
                    result["warnings"].append(
                        "{0}:{1}: planned XCTestCase subclass {2!r} lacks the "
                        "conventional 'Tests' suffix".format(
                            entry["file"], entry["line"], name)
                    )
                if name.endswith("Tests") and not entry["has_test_func"]:
                    result["warnings"].append(
                        f"{entry['file']}: planned class {name} file contains "
                        "no 'func test' declaration"
                    )

    result["unit"].sort(key=lambda e: e["name"])
    result["ui"].sort(key=lambda e: e["name"])
    result["helpers"].sort(key=lambda e: (e["file"], e["line"]))
    return result


# ---------------------------------------------------------------------------
# timing estimates
# ---------------------------------------------------------------------------

def load_estimates(path, purpose: str) -> tuple:
    """Load a timing file ({'classes': {name: seconds}}). Returns
    (estimates, warnings). Never raises: corrupt/missing -> empty + warning."""
    if not path:
        return {}, []
    if not os.path.exists(path):
        return {}, [f"{purpose} timing file not found: {path} (falling back)"]
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return {}, [f"{purpose} timing file unreadable/corrupt ({exc}); falling back"]
    if not isinstance(doc, dict) or not isinstance(doc.get("classes", {}), dict):
        return {}, [f"{purpose} timing file has unexpected schema; falling back"]
    estimates, warns = {}, []
    for name, secs in doc["classes"].items():
        if isinstance(secs, bool) or not isinstance(secs, (int, float)) or secs <= 0:
            warns.append(f"{purpose}: ignoring non-positive timing for {name!r}")
            continue
        estimates[name] = float(secs)
    return estimates, warns


# ---------------------------------------------------------------------------
# planning
# ---------------------------------------------------------------------------

def lane_count_for(total_predicted: float, n_classes: int, cfg: dict) -> int:
    if n_classes == 0:
        return 0
    n = math.ceil(total_predicted / cfg["target_budget_s"]) if total_predicted > 0 else 1
    n = max(cfg["min_lanes"], n)
    n = min(cfg["max_lanes"], n)
    return min(n, n_classes)


def longest_processing_time_first(items: list, n_lanes: int) -> list:
    """items: [(name, seconds)] sorted deterministically. Returns n_lanes lists
    of names. Classic LPT with a min-heap; tie-breaks by name then lane index
    make the result fully deterministic."""
    lanes = [[] for _ in range(n_lanes)]
    loads = [0.0] * n_lanes
    heap = [(0.0, i) for i in range(n_lanes)]
    heapq.heapify(heap)
    for name, seconds in items:
        load, idx = heapq.heappop(heap)
        lanes[idx].append(name)
        new_load = load + seconds
        loads[idx] = new_load
        heapq.heappush(heap, (new_load, idx))
    return lanes


def timeout_for(predicted: float, floor_s: float, multiplier: float) -> int:
    return max(int(floor_s), int(math.ceil(predicted * multiplier)))


def job_timeout_min(lane_timeout_s: int, cfg: dict) -> int:
    """Outer job ceiling: worst in-script path is attempt 1 + attempt 2 + a
    full isolation pass (each bounded by lane_timeout_s) plus two bounded
    simulator resets and setup/download slack. Watchdogs inside the runner
    script are the real enforcement; this only guarantees the ceiling can
    never preempt legitimate in-script recovery."""
    total = 3 * lane_timeout_s + cfg["job_timeout_margin_s"]
    return int(math.ceil(total / 60.0))


def imbalance_pct(values: list) -> float:
    if not values:
        return 0.0
    avg = sum(values) / len(values)
    if avg <= 0:
        return 0.0
    return (max(values) - min(values)) / avg * 100.0


def build_plan(discovery: dict, cfg: dict, estimates: dict) -> dict:
    unit_names = [e["name"] for e in discovery["unit"]]
    ui_names = [e["name"] for e in discovery["ui"]]

    unit_est = {n: estimates.get(n, cfg["default_estimate_s"]) for n in unit_names}
    ui_est = {n: estimates.get(n, cfg["default_estimate_s"]) for n in ui_names}

    items = sorted(unit_est.items(), key=lambda kv: (-kv[1], kv[0]))
    total = sum(s for _n, s in items)
    n_lanes = lane_count_for(total, len(items), cfg)
    lanes = longest_processing_time_first(items, n_lanes)

    unit_lanes = []
    for i, classes in enumerate(lanes, start=1):
        predicted = sum(unit_est[c] for c in classes)
        timeout = timeout_for(predicted, cfg["lane_timeout_min_s"], cfg["timeout_multiplier"])
        unit_lanes.append({
            "lane": f"unit-{i}",
            "target": UNIT_TARGET,
            "classes": classes,
            "predicted_s": round(predicted, 1),
            "timeout_s": timeout,
            "job_timeout_min": job_timeout_min(timeout, cfg),
        })

    ui_lane = None
    if ui_names:
        predicted = sum(ui_est.values())
        timeout = timeout_for(predicted, cfg["ui_timeout_min_s"], cfg["timeout_multiplier"])
        ui_lane = {
            "lane": "ui",
            "target": UI_TARGET,
            "classes": ui_names,
            "class_estimates": ",".join(
                "{0}={1:.1f}".format(c, ui_est[c]) for c in ui_names),
            "predicted_s": round(predicted, 1),
            "timeout_s": timeout,
            "job_timeout_min": job_timeout_min(timeout, cfg),
        }

    plan = {
        "schema_version": SCHEMA_VERSION,
        "config": {k: cfg[k] for k in (
            "default_estimate_s", "min_lanes", "max_lanes", "target_budget_s",
            "lane_timeout_min_s", "timeout_multiplier", "ui_timeout_min_s",
            "job_timeout_margin_s")},
        "inventory": {"unit": unit_names, "ui": ui_names},
        "estimates": {n: round(v, 3) for n, v in sorted(
            list(unit_est.items()) + list(ui_est.items()))},
        "unit_lanes": unit_lanes,
        "ui_lane": ui_lane,
        "imbalance_predicted_pct": round(
            imbalance_pct([l["predicted_s"] for l in unit_lanes]), 1),
        "total_predicted_s": round(total, 1),
        "lane_count": n_lanes,
    }
    return plan


# ---------------------------------------------------------------------------
# validation
# ---------------------------------------------------------------------------

def validate_plan(plan: dict, discovery: dict) -> list:
    """Structural invariants beyond discovery errors. Returns error strings."""
    errors = list(discovery["errors"])
    unit_names = [e["name"] for e in discovery["unit"]]
    ui_names = [e["name"] for e in discovery["ui"]]

    assigned = []
    for lane in plan["unit_lanes"]:
        if not lane["classes"]:
            errors.append(f"empty lane generated: {lane['lane']}")
        assigned.extend(lane["classes"])
    if sorted(assigned) != sorted(unit_names):
        missing = sorted(set(unit_names) - set(assigned))
        extra = sorted(set(assigned) - set(unit_names))
        if missing:
            errors.append(f"unit classes missing from plan: {missing}")
        if extra:
            errors.append(f"unknown classes in unit lanes: {extra}")
    if len(assigned) != len(set(assigned)):
        errors.append("a unit class is assigned to more than one lane")

    ui_assigned = list(plan["ui_lane"]["classes"]) if plan["ui_lane"] else []
    if sorted(ui_assigned) != sorted(ui_names):
        errors.append(
            f"UI plan mismatch: planned {ui_assigned} vs discovered {ui_names}"
        )
    if set(ui_assigned) & set(assigned):
        errors.append("UI classes leaked into unit lanes")

    # Fewer classes than min_lanes legitimately yields fewer lanes; the count
    # must merely stay within [min(min_lanes, n_classes), max_lanes].
    n_unit = len(unit_names)
    lo = min(plan["config"]["min_lanes"], n_unit)
    hi = plan["config"]["max_lanes"]
    if plan["lane_count"] < lo or plan["lane_count"] > hi:
        errors.append(
            f"lane count {plan['lane_count']} outside configured bounds "
            f"[{lo}, {hi}]"
        )
    return errors


# ---------------------------------------------------------------------------
# outputs
# ---------------------------------------------------------------------------

def plan_summary_md(plan: dict, discovery: dict, source: str) -> str:
    lines = ["## Test plan", ""]
    lines.append(
        f"- Discovered: **{len(plan['inventory']['unit'])}** unit classes, "
        f"**{len(plan['inventory']['ui'])}** UI classes "
        f"({len(discovery['warnings'])} warnings)"
    )
    lines.append(
        f"- Timing source: **{source}** · total predicted unit runtime "
        f"**{plan['total_predicted_s']:.0f}s** · lanes **{plan['lane_count']}** "
        f"(bounds {plan['config']['min_lanes']}-{plan['config']['max_lanes']})"
    )
    lines.append("")
    lines.append("| Lane | Predicted | Watchdog | Job ceiling | Classes |")
    lines.append("|---|---|---|---|---|")
    for lane in plan["unit_lanes"]:
        lines.append(
            f"| {lane['lane']} | {lane['predicted_s']:.0f}s | {lane['timeout_s']}s "
            f"| {lane['job_timeout_min']}m | {len(lane['classes'])} |"
        )
    if plan["ui_lane"]:
        ui = plan["ui_lane"]
        lines.append(
            f"| {ui['lane']} | {ui['predicted_s']:.0f}s | {ui['timeout_s']}s "
            f"| {ui['job_timeout_min']}m | {len(ui['classes'])} |"
        )
    lines.append("")
    lines.append(f"- Predicted imbalance: **{plan['imbalance_predicted_pct']}%**")
    lines.append("")
    lines.append("<details><summary>Lane membership</summary>")
    lines.append("")
    for lane in plan["unit_lanes"]:
        lines.append(f"- **{lane['lane']}**: {', '.join(lane['classes'])}")
    if plan["ui_lane"]:
        lines.append(
            f"- **{plan['ui_lane']['lane']}**: {', '.join(plan['ui_lane']['classes'])}"
        )
    lines.append("")
    lines.append("</details>")
    lines.append("")
    return "\n".join(lines)


def matrix_json(plan: dict) -> str:
    include = []
    for lane in plan["unit_lanes"]:
        estimates = ",".join(
            "{0}={1:.1f}".format(c, plan["estimates"][c]) for c in lane["classes"]
        )
        include.append({
            "lane": lane["lane"],
            "target": lane["target"],
            "classes": ",".join(lane["classes"]),
            "class_estimates": estimates,
            "predicted_s": lane["predicted_s"],
            "timeout_s": lane["timeout_s"],
            "job_timeout_min": lane["job_timeout_min"],
        })
    return json.dumps({"include": include}, sort_keys=False)


# ---------------------------------------------------------------------------
# xctestrun portability audit
# ---------------------------------------------------------------------------

SYSTEM_PATH_PREFIXES = (
    "/Applications/",   # Xcode toolchain
    "/System/",
    "/usr/",
    "/Library/",        # Xcode support components
    "/private/var/",    # runner temp
    "/opt/",
)


def _walk_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _walk_strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk_strings(v)


EMBEDDED_ABS_PATH_RE = re.compile(r'(?<![\w])/(?:Users|Volumes)/[^\s\x22\x27]+')
FILE_URL_RE = re.compile(r'file://([^\s\x22\x27]+)')


def audit_xctestrun(xctestrun_path: str, workspace_root: str) -> tuple:
    """Return (violations, paths_checked). A violation is an absolute path in
    the .xctestrun that points outside the workspace root (and outside known
    system locations) — such a path cannot resolve on a different runner."""
    try:
        with open(xctestrun_path, "rb") as fh:
            plist = plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise ValueError(f"unreadable .xctestrun ({exc})")
    # Paths inside .xctestrun are POSIX (macOS); compare textually so the
    # audit itself stays portable (tests run on ubuntu/Windows too).
    import posixpath
    ws = posixpath.normpath(workspace_root).rstrip("/") or "/"
    prefix = ws + "/"

    def violation(path: str) -> bool:
        path = path.rstrip("/")
        if path == ws or path.startswith(prefix):
            return False
        return not any(path.startswith(p) for p in SYSTEM_PATH_PREFIXES)

    violations = set()
    checked = 0
    for s in _walk_strings(plist):
        candidates = set()
        if s.startswith("file://"):
            m = FILE_URL_RE.match(s)
            if m:
                from urllib.parse import unquote
                candidates.add(unquote(m.group(1)))
        if s.startswith("/"):
            candidates.add(s)
        # Mid-string absolute paths (e.g. embedded in a command-line value)
        # can pin the run to one runner; scan the risky home/volume roots.
        for m in EMBEDDED_ABS_PATH_RE.finditer(s):
            candidates.add(m.group(0))
        for path in candidates:
            checked += 1
            if violation(path):
                violations.add(path)
    return sorted(violations), checked


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _cfg_from_args(a) -> dict:
    return {
        "default_estimate_s": a.default_estimate_s,
        "min_lanes": a.min_lanes,
        "max_lanes": a.max_lanes,
        "target_budget_s": a.target_budget_s,
        "lane_timeout_min_s": a.lane_timeout_min_s,
        "timeout_multiplier": a.timeout_multiplier,
        "ui_timeout_min_s": a.ui_timeout_min_s,
        "job_timeout_margin_s": a.job_timeout_margin_s,
    }


def _load_history_or_baseline(a, discovery) -> tuple:
    warns = []
    def resolve(path):
        # A relative --baseline/--history is resolved against --repo-root, so
        # the tool behaves the same no matter which directory it runs from.
        if path and not os.path.isabs(path):
            joined = os.path.join(a.repo_root, path)
            if os.path.exists(joined):
                return joined
        return path
    if a.history:
        estimates, w = load_estimates(resolve(a.history), "history")
        warns.extend(w)
        if estimates:
            return estimates, warns, "timing history"
        if not w:
            warns.append("history file contained no usable entries; using baseline")
    estimates, w = load_estimates(resolve(a.baseline), "baseline")
    warns.extend(w)
    if estimates:
        return estimates, warns, "checked-in baseline"
    return {}, warns, "default estimates"


def _human_report(plan: dict, discovery: dict, source: str) -> str:
    out = []
    out.append(
        "discovered {0} unit + {1} UI test classes ({2} warnings)".format(
            len(plan["inventory"]["unit"]), len(plan["inventory"]["ui"]),
            len(discovery["warnings"]))
    )
    out.append(f"timing source: {source}")
    for lane in plan["unit_lanes"]:
        out.append(
            "  {0}: predicted {1}s, watchdog {2}s, job ceiling {3}m, {4} classes".format(
                lane["lane"], lane["predicted_s"], lane["timeout_s"],
                lane["job_timeout_min"], len(lane["classes"])))
    if plan["ui_lane"]:
        ui = plan["ui_lane"]
        out.append(
            "  {0}: predicted {1}s, watchdog {2}s, job ceiling {3}m".format(
                ui["lane"], ui["predicted_s"], ui["timeout_s"],
                ui["job_timeout_min"]))
    out.append(f"predicted imbalance: {plan['imbalance_predicted_pct']}%")
    return "\n".join(out)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    for cmd in ("plan", "validate"):
        p = sub.add_parser(cmd)
        p.add_argument("--repo-root", default=".")
        p.add_argument("--baseline", default=os.path.join("scripts", "test-timings.json"))
        p.add_argument("--history", default="")
        p.add_argument("--default-estimate-s", type=float, default=DEFAULT_ESTIMATE_S)
        p.add_argument("--min-lanes", type=int, default=MIN_LANES)
        p.add_argument("--max-lanes", type=int, default=MAX_LANES)
        p.add_argument("--target-budget-s", type=float, default=TARGET_LANE_BUDGET_S)
        p.add_argument("--lane-timeout-min-s", type=int, default=LANE_TIMEOUT_MIN_S)
        p.add_argument("--timeout-multiplier", type=float, default=LANE_TIMEOUT_MULTIPLIER)
        p.add_argument("--ui-timeout-min-s", type=int, default=UI_TIMEOUT_MIN_S)
        p.add_argument("--job-timeout-margin-s", type=int, default=JOB_TIMEOUT_MARGIN_S)
        if cmd == "plan":
            p.add_argument("--out", default="plan.json")
            p.add_argument("--matrix-out", default="")
            p.add_argument("--summary-out", default="")

    p = sub.add_parser("audit-xctestrun")
    p.add_argument("--xctestrun", required=True)
    p.add_argument("--workspace-root", required=True)

    a = parser.parse_args(argv)

    if a.cmd == "audit-xctestrun":
        violations, checked = audit_xctestrun(a.xctestrun, a.workspace_root)
        print(f"xctestrun audit: {checked} absolute-path entries checked")
        if violations:
            for v in violations:
                print(f"::error::non-portable absolute path in .xctestrun: {v}")
            print(
                "These paths point outside the workspace root; the shared build "
                "artifact would not resolve on a different runner."
            )
            return 1
        print("xctestrun audit OK: all absolute paths are workspace- or system-relative")
        return 0

    if not os.path.isdir(a.repo_root):
        print(f"::error::repo root not found: {a.repo_root}")
        return 2

    discovery = discover_test_classes(a.repo_root)
    for w in discovery["warnings"]:
        warn(w)
    cfg = _cfg_from_args(a)
    estimates, ewarns, source = _load_history_or_baseline(a, discovery)
    for w in ewarns:
        warn(w)
    # Unknown timing entries are ignored: build_plan only looks up discovered
    # class names, and the history update script prunes stale entries.
    plan = build_plan(discovery, cfg, estimates)
    errors = validate_plan(plan, discovery)

    report = _human_report(plan, discovery, source)
    print(report)
    for e in errors:
        print(f"::error::{e}")

    if a.cmd == "validate":
        if errors:
            print("plan validation FAILED")
            return 1
        print("plan validation OK")
        return 0

    if errors:
        return 1
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    print(f"plan written: {a.out}")
    if a.matrix_out:
        with open(a.matrix_out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(matrix_json(plan))
        print(f"matrix written: {a.matrix_out}")
    if a.summary_out:
        with open(a.summary_out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(plan_summary_md(plan, discovery, source))
        print(f"summary written: {a.summary_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
