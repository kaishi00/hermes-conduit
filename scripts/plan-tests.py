#!/usr/bin/env python3
"""CI v2 test planner for Hermes Conduit.

Replaces the static unit-a..unit-d shard system:

  * discovers every XCTestCase class under ConduitTests/ and ConduitUITests/
    directly from the Swift sources (no Xcode runtime discovery needed);
  * validates complete, duplicate-free inventory (a new test class cannot
    silently miss CI);
  * assigns unit classes to a dynamic number of lanes with longest-
    processing-time-first balancing over historical duration estimates,
    consolidating lanes whose split would not buy more than a wall-clock
    tolerance once the fixed per-invocation Xcode/simulator startup cost is
    modeled (predicted lane cost = invocation overhead + predicted execution);
  * partitions every unit lane's classes, in stored order, into sequential
    execution BATCHES of at most 7 classes - each batch runs as its own
    fresh xcodebuild invocation with its own planned watchdog on the same
    runner and Simulator session (see MAX_UNIT_CLASSES_PER_XCODEBUILD_BATCH);
  * balances UI classes into their own parallel lanes the same way, and
    derives a PER-CLASS watchdog for every UI class (the lane runs its
    classes as one batched invocation priced at the sum of those budgets,
    and the diagnosis fallback enforces them per class);
  * derives measured per-lane watchdog budgets from those predictions;
  * emits GitHub Actions matrix JSON for the dynamic unit AND UI lanes.

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

SCHEMA_VERSION = 2  # 2: unit lanes carry sequential execution batches
#                   (batches/batch_count; timeout_s = sum of batch budgets)

# Planning configuration (overridable via flags for tests).
DEFAULT_ESTIMATE_S = 20.0          # unseen/new classes: conservative, not sticky
MIN_LANES = 1
MAX_LANES = 8
# Unit lanes execute internally as SEQUENTIAL SMALL xcodebuild invocations
# ("batches"): a lane's class list is chunked mechanically in stored order,
# and each batch runs as its own fresh xcodebuild test-without-building
# process on the same runner and the same Simulator session (no erase between
# successful batches). Diagnostic evidence (PRs #178-#183): large single unit
# invocations repeatedly watchdog-stalled on hosted macos-26 while the same
# classes split into <=7-class invocations completed - including two 7-class
# invocations run back-to-back inside ONE job (fresh xcodebuild/testhost
# boundary only). 7 is an empirically conservative starting point, not a
# proven universal threshold; it caps the invocation size, NOT the lane: the
# GitHub lane count and the timing-aware balancing above are unchanged.
MAX_UNIT_CLASSES_PER_XCODEBUILD_BATCH = 7
# Watchdog for ONE unit batch. One batch is one xcodebuild invocation, so its
# budget is priced like a mini lane: (modeled invocation overhead + predicted
# execution) with headroom, floored like a lane. Including the overhead is
# deliberate: under hosted-runner degradation it is the startup/finalize
# phase (not just test execution) that slows, and the diagnostic 7-class
# batches measured 211-488s wall INCLUDING startup.
UNIT_BATCH_TIMEOUT_MIN_S = 600
UNIT_BATCH_TIMEOUT_MULTIPLIER = 2.5
# Parallelism policy: a unit lane may not chain more than this many
# sequential xcodebuild batches inside one GitHub job. #184's first live run
# was reliable but slow (2 jobs x 9-10 batches = 29-48 min wall), so the
# planner treats this as a lower bound on the unit lane count: batches run
# CONCURRENTLY across hosted Macs instead of serially on one. The cap is on
# BATCHES per job, not on an arbitrary "safe class count"; with the 7-class
# batch cap this bounds a normal lane at roughly 28 classes. Watchdog
# budgets are deliberately untouched - one variable per change.
MAX_UNIT_BATCHES_PER_JOB = 4
# Modeled fixed cost of ONE xcodebuild invocation on a lane: process startup,
# simulator boot, app/test-host install, and xcresult finalization. Measured
# on macos-26 hosted runners as lane actual minus predicted execution
# (~208-295s across the four unit lanes of run 34349843495; the UI per-class
# floor below independently measured ~3.5 min for the same fixed cost, run
# #500). A lane must buy more than lane_wall_tolerance_s of wall-clock
# improvement to be worth spawning: more parallel jobs are not inherently
# faster when every job pays this cost up front.
INVOCATION_OVERHEAD_S = 240.0
LANE_WALL_TOLERANCE_S = 120.0
# UI sharding. UI classes are balanced into parallel lanes (same overhead-
# aware consolidation as units) and every lane runs its classes as ONE
# batched xcodebuild invocation. The clamp bounds hosted-runner usage
# (3 lanes for today's ~22 min of cumulative UI work, more only if the suite
# grows); the per-class watchdog table still travels with the lane for the
# batched budget and the diagnosis fallback.
UI_MIN_LANES = 3
UI_MAX_LANES = 4
# Per-class UI watchdog = max(floor, estimate x multiplier). The floor covers
# the fixed xcodebuild/automation-session/simulator overhead a hosted
# invocation pays around even a tiny class (~2.5 min before the first test +
# ~1 min finalizing the xcresult, measured on macos-26; run #500), with
# headroom for the targeted one-shot retry of a legitimately slow class; the
# multiplier gives slow-but-healthy classes room on slower runners without
# letting any single class hold a lane hostage for the old 48-minute
# suite-level watchdog.
UI_CLASS_TIMEOUT_MIN_S = 420
UI_CLASS_TIMEOUT_MULTIPLIER = 3.0
# Bounded cost of one failing class's erase/reboot recovery (shutdown 60 +
# erase 180 + boot 60 + bootstatus 200 + diagnostics ~45, rounded up) - the
# job ceiling must cover one per failing class, not a flat allowance.
UI_RESET_OVERHEAD_S = 600
# Bounded recovery cost of ONE unit batch that needed its retry: the
# infrastructure path pays shutdown+erase+boot+bootstatus+diagnostics
# (~545s); the watchdog path only shutdown+diagnostics. Priced at the
# infrastructure bound per batch, the job ceiling must cover one per batch.
UNIT_BATCH_RECOVERY_OVERHEAD_S = 600
# xcresulttool subprocess timeout in extract-test-timings.py. Extraction
# runs outside the per-class budgets (after the invocation returns), up to
# twice per class, so the ceiling reserves a bound for it as well.
UI_EXTRACT_BOUND_S = 300
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
        # math.isfinite: nan survives the <= 0 check and would poison every
        # downstream ceil()/comparison in the planner.
        if (isinstance(secs, bool) or not isinstance(secs, (int, float))
                or not math.isfinite(secs) or secs <= 0):
            warns.append(f"{purpose}: ignoring non-positive timing for {name!r}")
            continue
        estimates[name] = float(secs)
    return estimates, warns


# ---------------------------------------------------------------------------
# planning
# ---------------------------------------------------------------------------

def lane_count_for(items: list, cfg: dict) -> int:
    """Smallest lane count whose MODELED WALL CLOCK is within
    lane_wall_tolerance_s of the best achievable wall clock within bounds.

    Model: predicted lane cost = invocation_overhead_s (fixed: xcodebuild
    startup + simulator boot + result finalization, paid by every lane) + the
    lane's predicted test execution; lanes run in parallel, so the modeled
    wall for n lanes is overhead + the heaviest LPT lane load. Another shard
    only ever rebalances execution, but multiplies the paid fixed cost, so a
    lane must buy at least lane_wall_tolerance_s of wall improvement to be
    worth spawning. Splitting 200s of tests into two lanes is a net loss when
    the invocation overhead is several minutes.

    items: [(name, seconds)]; returns a count in
    [min(min_lanes, n_classes), max_lanes], 0 when there are no classes."""
    n_classes = len(items)
    if n_classes == 0:
        return 0
    lo = min(cfg["min_lanes"], n_classes)
    hi = min(cfg["max_lanes"], n_classes)
    seconds_for = dict(items)
    walls = {}
    for n in range(lo, hi + 1):
        lanes = longest_processing_time_first(items, n)
        walls[n] = cfg["invocation_overhead_s"] + max(
            sum(seconds_for[name] for name in lane) for lane in lanes
        )
    best = min(walls.values())
    for n in sorted(walls):
        if walls[n] <= best + cfg["lane_wall_tolerance_s"]:
            return n
    return lo  # unreachable: the best wall itself satisfies the tolerance


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


def unit_batch_timeout_for(predicted: float, cfg: dict) -> int:
    """Watchdog for ONE unit batch (<= unit_batch_max_classes classes in one
    xcodebuild invocation). Priced like a mini lane: the modeled fixed
    invocation overhead plus the batch's predicted execution, with the same
    lane headroom multiplier, floored like a lane. Every batch of the lane
    carries its own budget; the runner enforces them per invocation."""
    total = cfg["invocation_overhead_s"] + predicted
    return max(int(cfg["unit_batch_timeout_min_s"]),
               int(math.ceil(total * cfg["unit_batch_timeout_multiplier"])))


def unit_batches_for(classes: list, estimates: dict, cfg: dict) -> list:
    """Partition one unit lane's classes into deterministic execution batches.

    Purely mechanical: the lane's EXISTING class order (the LPT balance) is
    chunked at unit_batch_max_classes - no regrouping by subsystem, no
    special-casing. Invariants (pinned by tests and validate_plan):
    every class appears exactly once, batches concatenate back to the exact
    input order, and every batch holds 1..unit_batch_max_classes classes."""
    size = cfg["unit_batch_max_classes"]
    batches = []
    for start in range(0, len(classes), size):
        chunk = list(classes[start:start + size])
        predicted = sum(estimates[c] for c in chunk)
        batches.append({
            "classes": chunk,
            "predicted_s": round(predicted, 1),
            "timeout_s": unit_batch_timeout_for(predicted, cfg),
        })
    return batches


def ui_class_timeout_for(estimate: float, floor_s: float, multiplier: float) -> int:
    """Watchdog for ONE UI test class. It prices the class's share of the
    batched shard invocation (the runner sums these budgets for the batch
    watchdog) and the per-class diagnosis fallback invocation. The floor
    carries the fixed per-invocation simulator/Xcode overhead that dominates
    small classes; the multiplier gives big classes proportional headroom.
    With today's estimates this bounds worst-case hang detection at 7-17
    minutes per class instead of the old 48-minute suite-level watchdog."""
    return max(int(floor_s), int(math.ceil(estimate * multiplier)))


def ui_job_timeout_min(lane_timeout_s: int, n_classes: int, cfg: dict) -> int:
    """Outer emergency ceiling for a UI lane. Two reachable worst paths:
    (a) the batched shard attempt (the lane budget = sum of per-class
    budgets) times out and per-class diagnosis follows (one attempt + one
    targeted retry per class = 2x more) = 3x; (b) the batch completes with
    failures in every class, the targeted retry (a budget covering all of
    them) times out, and diagnosis of the retried classes follows = up to
    4x. (b) dominates and prices the ceiling. Each failing class then pays
    one bounded erase/reboot recovery; per-attempt timing extraction can
    wedge to the xcresulttool subprocess bound (up to twice per diagnosis
    class plus the batch's own classification extraction, outside the
    budgets) - plus setup/download slack. Per-class watchdogs inside the
    runner are the real enforcement; the ceiling only guarantees GitHub can
    never preempt legitimate in-script recovery (which is what would erase
    the hung-class attribution this lane exists to provide)."""
    total = (4 * lane_timeout_s
             + (n_classes + 1) * cfg.get("ui_reset_overhead_s", UI_RESET_OVERHEAD_S)
             + (2 * n_classes + 1) * cfg.get("ui_extract_bound_s", UI_EXTRACT_BOUND_S)
             + cfg["job_timeout_margin_s"])
    return int(math.ceil(total / 60.0))


def unit_job_timeout_min(batches: list, cfg: dict) -> int:
    """Outer job ceiling for a batched unit lane. Worst in-script path: EVERY
    batch burns its budget twice (attempt 1 plus its single batch-level
    retry), each retry may pay one bounded simulator recovery (erase-path
    bound), and every attempt's timing extraction can wedge to the
    xcresulttool subprocess bound (up to two per batch plus the lane's own
    final fold) - plus setup/download slack. The per-batch watchdogs inside
    the runner are the real enforcement; this only guarantees the ceiling
    can never preempt legitimate in-script recovery (GitHub's own 6-hour
    hosted-runner cap aside, which no ceiling can outrun)."""
    n = len(batches)
    budgets = sum(b["timeout_s"] for b in batches)
    total = (2 * budgets
             + n * cfg.get("unit_batch_recovery_overhead_s",
                           UNIT_BATCH_RECOVERY_OVERHEAD_S)
             + (2 * n + 1) * cfg.get("ui_extract_bound_s", UI_EXTRACT_BOUND_S)
             + cfg["job_timeout_margin_s"])
    return int(math.ceil(total / 60.0))


def enforce_batches_per_job(items: list, n_lanes: int, cfg: dict) -> tuple:
    """Raise the unit lane count (never lower it) until the ACTUAL LPT
    assignment gives every lane at most unit_max_batches_per_job batches
    (ceil(lane class count / unit_batch_max_classes)). Returns the final
    (lane count, lanes). Deterministic: the check is exact and the
    assignment at each count is the same LPT the rest of the planner uses.

    A pure ceil(N / (batch_cap x batches)) floor is only a starting point:
    LPT balances timing load, so a lane can legitimately receive far more
    than the average class count when estimates are skewed. The only
    guarantee that counts is verification of the produced assignment."""
    n_classes = len(items)
    if n_classes == 0:
        return 0, []
    size = cfg.get("unit_batch_max_classes", MAX_UNIT_CLASSES_PER_XCODEBUILD_BATCH)
    max_batches = cfg.get("unit_max_batches_per_job", MAX_UNIT_BATCHES_PER_JOB)
    if size < 1 or max_batches < 1:
        # Structured fail-closed, never a crash: skip the floor (the
        # division is meaningless) and let validate_plan report the
        # invalid policy, exactly like unit_batch_max_classes < 1.
        return n_lanes, longest_processing_time_first(items, n_lanes)
    lo = max(n_lanes, -(-n_classes // (size * max_batches)))
    hi = min(cfg["max_lanes"], n_classes)
    n = max(lo, 1)
    candidate = None
    while n <= hi:
        candidate = longest_processing_time_first(items, n)
        if all(-(-len(lane) // size) <= max_batches for lane in candidate):
            return n, candidate
        n += 1
    # Bounds exhausted without a policy-satisfying assignment: return the
    # best (largest) attempt and let validate_plan fail the run closed -
    # planning must never silently ship a plan that violates the policy.
    # (The floor may exceed hi outright; hi >= 1 whenever there are classes,
    # so the returned assignment is still well-defined.)
    if candidate is None:
        candidate = longest_processing_time_first(items, hi)
    return hi, candidate


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
    n_lanes = lane_count_for(items, cfg)
    # Parallelism floor: timing-aware selection may CONSOLIDATE below what
    # the per-job batch policy allows, and LPT balances LOAD, not class
    # counts - so even a lane count >= ceil(N / (cap x batches)) can leave
    # one lane with too many classes. Verify the ACTUAL assignment and
    # increment the lane count (never lower it) until every lane fits the
    # per-job batch policy; validate_plan fails the run closed if the
    # configured bounds make the policy unsatisfiable.
    n_lanes, lanes = enforce_batches_per_job(items, n_lanes, cfg)
    if unit_names and n_lanes >= cfg["max_lanes"]:
        warn(
            "unit lane count is at max_lanes ({0}); the {1}-batch per-job "
            "policy bounds the suite at {2} classes - further growth will "
            "fail planning closed until max_lanes or the batch policy is "
            "raised".format(
                cfg["max_lanes"], cfg["unit_max_batches_per_job"],
                cfg["max_lanes"] * cfg["unit_max_batches_per_job"]
                * cfg["unit_batch_max_classes"]))

    unit_lanes = []
    for i, classes in enumerate(lanes, start=1):
        predicted = sum(unit_est[c] for c in classes)
        modeled_wall = cfg["invocation_overhead_s"] + predicted
        # Sequential execution batches inside the lane: each is one fresh
        # xcodebuild invocation with its own watchdog; the lane watchdog is
        # the SUM of the batch budgets (the total the lane may consume across
        # invocations), and the job ceiling prices every batch twice.
        batches = unit_batches_for(classes, unit_est, cfg)
        timeout = sum(b["timeout_s"] for b in batches)
        unit_lanes.append({
            "lane": f"unit-{i}",
            "target": UNIT_TARGET,
            "classes": classes,
            "batches": batches,
            "batch_count": len(batches),
            "predicted_s": round(predicted, 1),
            "modeled_wall_s": round(modeled_wall, 1),
            "timeout_s": timeout,
            "job_timeout_min": unit_job_timeout_min(batches, cfg),
        })

    ui_lanes = []
    if ui_names:
        ui_items = sorted(ui_est.items(), key=lambda kv: (-kv[1], kv[0]))
        # Same overhead-aware selection as units, under the UI bounds.
        ui_cfg = dict(cfg, min_lanes=cfg["ui_min_lanes"], max_lanes=cfg["ui_max_lanes"])
        n_ui_lanes = lane_count_for(ui_items, ui_cfg)
        for i, classes in enumerate(longest_processing_time_first(ui_items, n_ui_lanes), start=1):
            predicted = sum(ui_est[c] for c in classes)
            # Watchdog budget per class, from the same timing data that
            # balanced the lane: it prices the batched invocation (the sum)
            # and every per-class diagnosis fallback invocation.
            class_timeouts = {
                c: ui_class_timeout_for(
                    ui_est[c], cfg["ui_class_timeout_min_s"],
                    cfg["ui_class_timeout_multiplier"])
                for c in classes
            }
            lane_timeout = sum(class_timeouts.values())
            ui_lanes.append({
                "lane": f"ui-{i}",
                "target": UI_TARGET,
                "classes": classes,
                "class_estimates": ",".join(
                    "{0}={1:.1f}".format(c, ui_est[c]) for c in classes),
                "class_timeouts": ",".join(
                    "{0}={1}".format(c, class_timeouts[c]) for c in classes),
                "predicted_s": round(predicted, 1),
                "timeout_s": lane_timeout,
                "job_timeout_min": ui_job_timeout_min(
                    lane_timeout, len(classes), cfg),
            })

    plan = {
        "schema_version": SCHEMA_VERSION,
        "config": {k: cfg[k] for k in (
            "default_estimate_s", "min_lanes", "max_lanes",
            "invocation_overhead_s", "lane_wall_tolerance_s",
            "unit_batch_max_classes", "unit_batch_timeout_min_s",
            "unit_batch_timeout_multiplier", "unit_batch_recovery_overhead_s",
            "unit_max_batches_per_job",
            "ui_min_lanes", "ui_max_lanes", "ui_class_timeout_min_s",
            "ui_class_timeout_multiplier", "job_timeout_margin_s")},
        "inventory": {"unit": unit_names, "ui": ui_names},
        "estimates": {n: round(v, 3) for n, v in sorted(
            list(unit_est.items()) + list(ui_est.items()))},
        "unit_lanes": unit_lanes,
        "ui_lanes": ui_lanes,
        "imbalance_predicted_pct": round(
            imbalance_pct([l["predicted_s"] for l in unit_lanes]), 1),
        "ui_imbalance_predicted_pct": round(
            imbalance_pct([l["predicted_s"] for l in ui_lanes]), 1),
        "total_predicted_s": round(total, 1),
        "ui_predicted_s": round(sum(ui_est.values()), 1),
        "lane_count": n_lanes,
        "ui_lane_count": len(ui_lanes),
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

    if plan["config"].get("unit_batch_max_classes", 0) < 1:
        errors.append("unit_batch_max_classes must be >= 1")

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

    ui_assigned = []
    for lane in plan["ui_lanes"]:
        if not lane["classes"]:
            errors.append(f"empty UI lane generated: {lane['lane']}")
        ui_assigned.extend(lane["classes"])
    if sorted(ui_assigned) != sorted(ui_names):
        missing = sorted(set(ui_names) - set(ui_assigned))
        extra = sorted(set(ui_assigned) - set(ui_names))
        if missing:
            errors.append(f"UI classes missing from plan: {missing}")
        if extra:
            errors.append(f"unknown classes in UI lanes: {extra}")
    if len(ui_assigned) != len(set(ui_assigned)):
        errors.append("a UI class is assigned to more than one lane")
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

    # Batch invariants: the execution batches inside every unit lane must
    # exactly reproduce the lane's class order, stay within the batch cap,
    # and carry positive numeric watchdogs. A planner regression here would
    # silently desync the runner's -only-testing filters from the plan, so
    # it fails planning instead.
    for lane in plan["unit_lanes"]:
        lane_batches = lane.get("batches")
        if not isinstance(lane_batches, list) or not lane_batches:
            errors.append(f"unit lane {lane['lane']} has no execution batches")
            continue
        batched = []
        for batch in lane_batches:
            classes_b = batch.get("classes")
            if not isinstance(classes_b, list) or not classes_b:
                errors.append(f"unit lane {lane['lane']} has an empty batch")
                continue
            batched.extend(classes_b)
            if len(classes_b) > plan["config"]["unit_batch_max_classes"]:
                errors.append(
                    f"unit lane {lane['lane']} batch exceeds the "
                    f"{plan['config']['unit_batch_max_classes']}-class cap "
                    f"({len(classes_b)} classes)")
            budget = batch.get("timeout_s")
            if (isinstance(budget, bool) or not isinstance(budget, int)
                    or budget <= 0):
                errors.append(
                    f"unit lane {lane['lane']} batch has a non-positive "
                    f"integer watchdog: {budget!r}")
        if batched != lane["classes"]:
            errors.append(
                f"unit lane {lane['lane']} batches do not reproduce the "
                "lane's class order exactly (duplication, omission, or "
                "reordering)")
        if lane.get("batch_count") != len(lane_batches):
            errors.append(f"unit lane {lane['lane']} batch_count mismatch")
        max_batches = plan["config"].get("unit_max_batches_per_job")
        if max_batches is not None and max_batches < 1:
            errors.append("unit_max_batches_per_job must be >= 1")
            max_batches = None
        if max_batches is not None and len(lane_batches) > max_batches:
            errors.append(
                f"unit lane {lane['lane']} plans {len(lane_batches)} "
                f"sequential batches, exceeding the {max_batches}-batch "
                "per-job policy")
    n_ui = len(ui_names)
    ui_lo = min(plan["config"]["ui_min_lanes"], n_ui)
    if plan["ui_lanes"]:
        if plan["ui_lane_count"] < ui_lo or plan["ui_lane_count"] > plan["config"]["ui_max_lanes"]:
            errors.append(
                f"UI lane count {plan['ui_lane_count']} outside configured "
                f"bounds [{ui_lo}, {plan['config']['ui_max_lanes']}]"
            )
        for lane in plan["ui_lanes"]:
            timeout_names = set()
            for pair in lane["class_timeouts"].split(","):
                if "=" in pair:
                    name, value = pair.split("=", 1)
                    timeout_names.add(name)
                    if not value.isdigit():
                        errors.append(
                            f"UI lane {lane['lane']} has a non-numeric watchdog "
                            f"for {name}: {value!r}")
            for c in lane["classes"]:
                if c not in timeout_names:
                    errors.append(f"UI lane {lane['lane']} has no watchdog for {c}")
    elif ui_names:
        errors.append("UI classes discovered but no UI lanes planned")
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
    lines.append(
        f"- Modeled per-lane cost: **{plan['config']['invocation_overhead_s']:.0f}s** "
        "fixed invocation overhead + predicted execution (another lane is only "
        f"added when it buys more than "
        f"**{plan['config']['lane_wall_tolerance_s']:.0f}s** of wall clock)"
    )
    lines.append("")
    lines.append("| Lane | Predicted | Modeled wall | Watchdog | Job ceiling | Batches | Classes |")
    lines.append("|---|---|---|---|---|---|---|")
    for lane in plan["unit_lanes"]:
        sizes = ", ".join(str(len(b["classes"])) for b in lane["batches"])
        lines.append(
            f"| {lane['lane']} | {lane['predicted_s']:.0f}s | {lane['modeled_wall_s']:.0f}s "
            f"| {lane['timeout_s']}s "
            f"| {lane['job_timeout_min']}m | {lane['batch_count']} ({sizes}) | {len(lane['classes'])} |")
    for lane in plan["ui_lanes"]:
        timeouts = [int(p.split("=", 1)[1]) for p in lane["class_timeouts"].split(",") if "=" in p]
        lines.append(
            f"| {lane['lane']} (UI) | {lane['predicted_s']:.0f}s | - "
            f"| {max(timeouts)}s per class "
            f"| {lane['job_timeout_min']}m | - | {len(lane['classes'])} |")
    lines.append("")
    lines.append(
        "- Unit lanes execute as sequential fresh-xcodebuild batches of at most "
        f"**{plan['config']['unit_batch_max_classes']}** classes on one runner "
        "(same Simulator session; no erase between successful batches), with at "
        f"most **{plan['config']['unit_max_batches_per_job']}** batches per job "
        "(more unit jobs run the batches concurrently). "
        "The lane watchdog is the sum of the per-batch budgets.")
    lines.append("")
    lines.append(f"- Predicted imbalance: **{plan['imbalance_predicted_pct']}%** "
                 f"(unit) / **{plan['ui_imbalance_predicted_pct']}%** (UI)")
    lines.append("")
    lines.append("<details><summary>Lane membership</summary>")
    lines.append("")
    for lane in plan["unit_lanes"]:
        lines.append(f"- **{lane['lane']}** ({lane['batch_count']} batches): "
                     + " | ".join(", ".join(b["classes"]) for b in lane["batches"]))
    for lane in plan["ui_lanes"]:
        timeouts = dict(p.split("=", 1) for p in lane["class_timeouts"].split(",") if p)
        members = ", ".join(
            f"{c} (watchdog {timeouts.get(c, '?')}s)" for c in lane["classes"])
        lines.append(f"- **{lane['lane']}** (one batched invocation; per-class "
                     f"diagnosis budgets): {members}")
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
        # `batches` travels as a compact JSON STRING: GitHub matrix values are
        # scalars, and the runner receives it verbatim through an environment
        # variable (never bash template interpolation).
        include.append({
            "lane": lane["lane"],
            "target": lane["target"],
            "classes": ",".join(lane["classes"]),
            "class_estimates": estimates,
            "batches": json.dumps(lane["batches"], separators=(",", ":")),
            "batch_count": lane["batch_count"],
            "predicted_s": lane["predicted_s"],
            "timeout_s": lane["timeout_s"],
            "job_timeout_min": lane["job_timeout_min"],
        })
    return json.dumps({"include": include}, sort_keys=False)


def ui_matrix_json(plan: dict) -> str:
    include = []
    for lane in plan["ui_lanes"]:
        include.append({
            "lane": lane["lane"],
            "target": lane["target"],
            "classes": ",".join(lane["classes"]),
            "class_estimates": lane["class_estimates"],
            "class_timeouts": lane["class_timeouts"],
            "predicted_s": lane["predicted_s"],
            "timeout_s": lane["timeout_s"],
            "job_timeout_min": lane["job_timeout_min"],
        })
    return json.dumps({"include": include}, sort_keys=False)


# ---------------------------------------------------------------------------
# xctestrun portability audit
# ---------------------------------------------------------------------------

# Runner-image-stable locations. Deliberately NOT "/private/var/": a
# per-runner temp path under /private/var/folders/... exists only on the
# machine that built the artifact and must fail the portability audit.
SYSTEM_PATH_PREFIXES = (
    "/Applications/",   # Xcode toolchain
    "/System/",
    "/usr/",
    "/Library/",        # Xcode support components
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
                path = unquote(m.group(1))
                if not path.startswith("/"):
                    # file://host/path form: strip the netloc
                    path = "/" + path.split("/", 1)[-1] if "/" in path else "/"
                candidates.add(path)
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
        "invocation_overhead_s": a.invocation_overhead_s,
        "lane_wall_tolerance_s": a.lane_wall_tolerance_s,
        "unit_batch_max_classes": a.unit_batch_max_classes,
        "unit_batch_timeout_min_s": a.unit_batch_timeout_min_s,
        "unit_batch_timeout_multiplier": a.unit_batch_timeout_multiplier,
        "unit_batch_recovery_overhead_s": a.unit_batch_recovery_overhead_s,
        "unit_max_batches_per_job": a.unit_max_batches_per_job,
        "ui_min_lanes": a.ui_min_lanes,
        "ui_max_lanes": a.ui_max_lanes,
        "ui_class_timeout_min_s": a.ui_class_timeout_min_s,
        "ui_class_timeout_multiplier": a.ui_class_timeout_multiplier,
        "ui_reset_overhead_s": a.ui_reset_overhead_s,
        "ui_extract_bound_s": a.ui_extract_bound_s,
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
            "  {0}: predicted {1}s, modeled wall {2}s, watchdog {3}s ({4} batches: {5}), job ceiling {6}m, {7} classes".format(
                lane["lane"], lane["predicted_s"], lane["modeled_wall_s"],
                lane["timeout_s"], lane["batch_count"],
                "/".join(str(len(b["classes"])) for b in lane["batches"]),
                lane["job_timeout_min"], len(lane["classes"])))
    for lane in plan["ui_lanes"]:
        out.append(
            "  {0} (UI): predicted {1}s, batched invocation, per-class watchdogs [{2}], job ceiling {3}m".format(
                lane["lane"], lane["predicted_s"], lane["class_timeouts"],
                lane["job_timeout_min"]))
    out.append(f"predicted imbalance: {plan['imbalance_predicted_pct']}% unit / "
               f"{plan['ui_imbalance_predicted_pct']}% UI")
    return "\n".join(out)


_CLASS_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def load_smoke_suite(path: str) -> tuple:
    """Read the curated smoke selection. Returns (unit_names, ui_names).

    Fails closed on anything that is not a well-formed suite: the file must be
    a JSON object declaring non-empty `unit` and `ui` lists of plain Swift class
    names. Defaulting an absent key to an empty list would turn a malformed
    edit into a silently empty hosted selection.
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("smoke suite must be a JSON object")
    for key in ("unit", "ui"):
        if key not in data:
            raise ValueError("smoke suite must declare a {0!r} list".format(key))
        names = data[key]
        if not isinstance(names, list) or not names:
            raise ValueError(
                "smoke suite {0!r} must be a non-empty list".format(key))
        for name in names:
            if not isinstance(name, str) or not _CLASS_NAME_RE.match(name):
                raise ValueError(
                    "smoke suite {0!r} names an invalid class: {1!r}".format(
                        key, name))
    return list(data["unit"]), list(data["ui"])


def cmd_smoke(args) -> int:
    """Validate the curated smoke selection against the discovered inventory.

    GitHub-hosted CI runs only these classes (docs/CI.md): the exhaustive and
    timing-sensitive families belong to the Mac local gate. This subcommand is
    what keeps that selection honest - a class that is renamed, deleted or moved
    between targets fails the plan job instead of silently shrinking hosted
    coverage, and the delegated counts are printed so the split is visible on
    every run.
    """
    discovery = discover_test_classes(args.repo_root)
    for w in discovery["warnings"]:
        warn(w)
    if discovery["errors"]:
        for e in discovery["errors"]:
            print(f"::error::{e}")
        return 1

    unit_inventory = {entry["name"] for entry in discovery["unit"]}
    ui_inventory = {entry["name"] for entry in discovery["ui"]}
    try:
        unit, ui = load_smoke_suite(args.suite)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"::error::smoke suite unreadable: {exc}")
        return 1

    problems = []
    # Validated per TARGET, never against the union of both: a class moved
    # between ConduitTests/ and ConduitUITests/ would otherwise still validate
    # while the smoke job filters it against the wrong bundle - which runs zero
    # tests for it and silently shrinks hosted coverage.
    for target, names, inventory in (("unit", unit, unit_inventory),
                                     ("ui", ui, ui_inventory)):
        seen = set()
        for name in names:
            if name in seen:
                problems.append(f"smoke suite lists {name!r} twice in {target}")
            seen.add(name)
            if name not in inventory:
                problems.append(
                    f"smoke suite lists {name!r} in {target}, but it is not a "
                    f"{target} test class")
    for name in sorted(set(unit) & set(ui)):
        problems.append(f"smoke suite lists {name!r} in both unit and ui")
    # Report failures before the split: the delegated counts are only
    # meaningful once every curated name has been validated.
    for e in problems:
        print(f"::error::{e}")
    if problems:
        print("smoke selection FAILED")
        return 1

    delegated_unit = len(discovery["unit"]) - len(unit)
    delegated_ui = len(discovery["ui"]) - len(ui)
    print(f"smoke selection: {len(unit)} unit + {len(ui)} UI classes")
    print(f"not in the UI smoke set: {delegated_unit} unit + "
          f"{delegated_ui} UI classes (unit classes run in the hosted shards; the "
          f"full UI suite and timing families run nightly)")

    if args.out:
        payload = {
            "schema_version": 1,
            "unit": unit,
            "ui": ui,
            "unit_csv": ",".join(unit),
            "ui_csv": ",".join(ui),
            "inventory_unit": len(discovery["unit"]),
            "inventory_ui": len(discovery["ui"]),
            "delegated_unit": delegated_unit,
            "delegated_ui": delegated_ui,
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(f"smoke selection written: {args.out}")
    print("smoke selection OK")
    return 0


def load_hosted_suite(path: str) -> dict:
    """Read the hosted CI shape (scripts/hosted-suite.json).

    Fails closed: shard counts must be positive integers and the nightly-only
    list must name plain Swift classes.
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("hosted suite must be a JSON object")
    for key in ("unit_shards", "nightly_ui_shards"):
        value = data.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise ValueError("hosted suite {0!r} must be a positive integer".format(key))
    names = data.get("nightly_only_unit")
    if not isinstance(names, list):
        raise ValueError("hosted suite must declare a 'nightly_only_unit' list")
    for name in names:
        if not isinstance(name, str) or not _CLASS_NAME_RE.match(name):
            raise ValueError(
                "hosted suite 'nightly_only_unit' names an invalid class: {0!r}".format(name))
    return data


def split_lpt(names: list, estimates: dict, shards: int) -> list:
    """Longest-processing-time split of `names` into `shards` lists.

    Each shard keeps its classes in assignment order (longest first), and ties
    break by name, so the same inventory always produces the same shards.
    """
    buckets = [[] for _ in range(shards)]
    totals = [0.0] * shards
    ordered = sorted(names, key=lambda n: (-estimates.get(n, DEFAULT_ESTIMATE_S), n))
    for name in ordered:
        i = min(range(shards), key=lambda k: (totals[k], k))
        buckets[i].append(name)
        totals[i] += estimates.get(name, DEFAULT_ESTIMATE_S)
    return [b for b in buckets if b]


def cmd_hosted(args) -> int:
    """Split the discovered inventory for the hosted CI v4 jobs.

    PR runs: every unit class except the nightly-only timing families, split
    into `unit_shards` balanced shards. Nightly runs: those families, plus the
    whole UI suite split into `nightly_ui_shards` shards. Every discovered class
    lands in exactly one PR or nightly list, so nothing is silently unrun.
    """
    discovery = discover_test_classes(args.repo_root)
    for w in discovery["warnings"]:
        warn(w)
    if discovery["errors"]:
        for e in discovery["errors"]:
            print(f"::error::{e}")
        return 1
    try:
        suite = load_hosted_suite(args.suite)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"::error::hosted suite unreadable: {exc}")
        return 1

    unit_names = [entry["name"] for entry in discovery["unit"]]
    ui_names = [entry["name"] for entry in discovery["ui"]]
    nightly = list(suite["nightly_only_unit"])
    problems = []
    seen = set()
    for name in nightly:
        if name in seen:
            problems.append(f"hosted suite lists {name!r} twice in nightly_only_unit")
        seen.add(name)
        if name not in unit_names:
            problems.append(
                f"hosted suite lists {name!r} in nightly_only_unit, but it is not a unit test class")
    for e in problems:
        print(f"::error::{e}")
    if problems:
        print("hosted selection FAILED")
        return 1

    baseline = args.baseline
    if baseline and not os.path.isabs(baseline):
        baseline = os.path.join(args.repo_root, baseline)
    estimates, ewarns = load_estimates(baseline, "baseline") if baseline else ({}, [])
    for w in ewarns:
        warn(w)

    pr_unit = [n for n in unit_names if n not in seen]
    unit_shards = split_lpt(pr_unit, estimates, suite["unit_shards"])
    ui_shards = split_lpt(ui_names, estimates, suite["nightly_ui_shards"])
    if not unit_shards:
        print("::error::hosted selection has no unit classes for PR runs")
        return 1

    print("hosted selection: {0} unit classes in {1} PR shards ({2}), "
          "{3} nightly-only unit classes, {4} UI classes in {5} nightly shards".format(
              len(pr_unit), len(unit_shards), "/".join(str(len(s)) for s in unit_shards),
              len(nightly), len(ui_names), len(ui_shards)))
    if args.out:
        payload = {
            "schema_version": 1,
            "unit_shards": [",".join(s) for s in unit_shards],
            "nightly_unit_csv": ",".join(nightly),
            "ui_shards": [",".join(s) for s in ui_shards],
            "inventory_unit": len(unit_names),
            "inventory_ui": len(ui_names),
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(f"hosted selection written: {args.out}")
    print("hosted selection OK")
    return 0


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
        p.add_argument("--invocation-overhead-s", type=float, default=INVOCATION_OVERHEAD_S)
        p.add_argument("--lane-wall-tolerance-s", type=float, default=LANE_WALL_TOLERANCE_S)
        p.add_argument("--unit-batch-max-classes", type=int,
                       default=MAX_UNIT_CLASSES_PER_XCODEBUILD_BATCH)
        p.add_argument("--unit-batch-timeout-min-s", type=int, default=UNIT_BATCH_TIMEOUT_MIN_S)
        p.add_argument("--unit-batch-timeout-multiplier", type=float,
                       default=UNIT_BATCH_TIMEOUT_MULTIPLIER)
        p.add_argument("--unit-batch-recovery-overhead-s", type=int,
                       default=UNIT_BATCH_RECOVERY_OVERHEAD_S)
        p.add_argument("--unit-max-batches-per-job", type=int,
                       default=MAX_UNIT_BATCHES_PER_JOB)
        p.add_argument("--ui-min-lanes", type=int, default=UI_MIN_LANES)
        p.add_argument("--ui-max-lanes", type=int, default=UI_MAX_LANES)
        p.add_argument("--ui-class-timeout-min-s", type=int, default=UI_CLASS_TIMEOUT_MIN_S)
        p.add_argument("--ui-class-timeout-multiplier", type=float,
                       default=UI_CLASS_TIMEOUT_MULTIPLIER)
        p.add_argument("--ui-reset-overhead-s", type=int, default=UI_RESET_OVERHEAD_S)
        p.add_argument("--ui-extract-bound-s", type=int, default=UI_EXTRACT_BOUND_S)
        p.add_argument("--job-timeout-margin-s", type=int, default=JOB_TIMEOUT_MARGIN_S)
        if cmd == "plan":
            p.add_argument("--out", default="plan.json")
            p.add_argument("--matrix-out", default="")
            p.add_argument("--ui-matrix-out", default="")
            p.add_argument("--summary-out", default="")

    p = sub.add_parser("audit-xctestrun")
    p.add_argument("--xctestrun", required=True)
    p.add_argument("--workspace-root", required=True)

    p = sub.add_parser("smoke")
    p.add_argument("--repo-root", default=".")
    p.add_argument("--suite", default=os.path.join("scripts", "smoke-suite.json"))
    p.add_argument("--out", default="")

    p = sub.add_parser("hosted")
    p.add_argument("--repo-root", default=".")
    p.add_argument("--suite", default=os.path.join("scripts", "hosted-suite.json"))
    p.add_argument("--baseline", default=os.path.join("scripts", "test-timings.json"))
    p.add_argument("--out", default="")

    a = parser.parse_args(argv)

    if a.cmd == "smoke":
        return cmd_smoke(a)
    if a.cmd == "hosted":
        return cmd_hosted(a)

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
    if a.ui_matrix_out:
        with open(a.ui_matrix_out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(ui_matrix_json(plan))
        print(f"UI matrix written: {a.ui_matrix_out}")
    if a.summary_out:
        with open(a.summary_out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(plan_summary_md(plan, discovery, source))
        print(f"summary written: {a.summary_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
