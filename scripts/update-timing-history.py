#!/usr/bin/env python3
"""Merge fresh per-class XCTest timings into the timing-history cache.

CI v2 timing model:
  * checked-in scripts/test-timings.json  = deterministic baseline fallback;
  * timing-history.json (Actions cache)   = living estimates, updated only by
    successful main-branch runs; PR runs consume it read-only;
  * this script performs the update with an exponentially weighted moving
    average so one anomalous runner cannot reshape the plan:

        updated = previous * 0.75 + observed * 0.25

  * observations are clamped to (previous / outlier-ratio .. previous * ratio)
    before averaging (extreme-outlier guard);
  * first observations are taken verbatim;
  * classes missing from the current planner inventory are pruned so the
    metadata cannot grow forever;
  * corrupt/missing inputs degrade to "no update" — never crash the CI job.

Stdlib only; deterministic for identical inputs (modulo the updated_at stamp).
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys

SCHEMA_VERSION = 1


def warn(msg: str) -> None:
    print(f"::warning::update-timing-history: {msg}", file=sys.stderr)


def load_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def try_load_history(path) -> tuple:
    if not path:
        return {}, []
    if not os.path.exists(path):
        return {}, [f"history file not found ({path}); starting from empty history"]
    try:
        doc = load_json(path)
        classes = doc.get("classes", {})
        if not isinstance(classes, dict):
            raise ValueError("'classes' is not an object")
        clean = {}
        for name, secs in classes.items():
            if isinstance(secs, (int, float)) and not isinstance(secs, bool) and secs > 0:
                clean[name] = float(secs)
        return clean, []
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {}, [f"history file corrupt ({exc}); starting from empty history"]


def os_path_exists(path: str) -> bool:
    import os
    return os.path.exists(path)


def update(history: dict, observations_docs: list, inventory: set,
           decay_prev: float, decay_new: float, outlier_ratio: float) -> tuple:
    updated = dict(history)
    changed = {}
    pruned = 0
    for doc in observations_docs:
        for name in sorted(doc.get("classes", {})):
            observed = doc["classes"][name]
            if not isinstance(observed, (int, float)) or observed <= 0:
                warn(f"ignoring non-positive observation for {name!r}")
                continue
            if inventory and name not in inventory:
                warn(f"observation for {name!r} is not in the planner inventory; ignored")
                continue
            observed = float(observed)
            prev = updated.get(name)
            if prev is None:
                new = observed
            else:
                clamped = min(max(observed, prev / outlier_ratio), prev * outlier_ratio)
                new = prev * decay_prev + clamped * decay_new
            updated[name] = round(new, 3)
            changed[name] = (prev, updated[name])
    if inventory:
        before = len(updated)
        updated = {k: v for k, v in updated.items() if k in inventory}
        pruned = before - len(updated)
    return updated, changed, pruned


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--observations", nargs="+", required=True,
                        help="observation JSON files from extract-test-timings.py")
    parser.add_argument("--inventory", required=True,
                        help="plan.json whose inventory defines the class universe")
    parser.add_argument("--history", default="",
                        help="previous timing-history.json (optional)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--decay-prev", type=float, default=0.75)
    parser.add_argument("--decay-new", type=float, default=0.25)
    parser.add_argument("--outlier-ratio", type=float, default=5.0)
    parser.add_argument("--max-seconds", type=float, default=3600.0,
                        help="absolute sanity cap for any single estimate")
    args = parser.parse_args(argv)

    if abs(args.decay_prev + args.decay_new - 1.0) > 1e-9:
        parser.error("--decay-prev + --decay-new must equal 1.0")

    history, hwarns = try_load_history(args.history)
    for w in hwarns:
        warn(w)

    try:
        plan = load_json(args.inventory)
        inventory = set(plan.get("inventory", {}).get("unit", [])) | set(
            plan.get("inventory", {}).get("ui", []))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        warn(f"inventory unreadable ({exc}); nothing to merge")
        return 1

    docs = []
    for path in args.observations:
        try:
            docs.append(load_json(path))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            warn(f"observations file unreadable, skipping ({path}: {exc})")
    if not docs:
        warn("no usable observations; history left unchanged")

    merged, changed, pruned = update(
        history, docs, inventory,
        args.decay_prev, args.decay_new, args.outlier_ratio)
    # Absolute sanity cap protects against pathological observations entirely.
    merged = {k: min(v, args.max_seconds) for k, v in merged.items()}

    doc = {
        "schema_version": SCHEMA_VERSION,
        "updated_at": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"),
        "decay": {"prev": args.decay_prev, "new": args.decay_new,
                  "outlier_ratio": args.outlier_ratio},
        "classes": dict(sorted(merged.items())),
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")

    print(
        f"timing history updated: {len(merged)} classes "
        f"({len(changed)} changed, {pruned} pruned) -> {args.out}"
    )
    if changed:
        top = sorted(changed.items(), key=lambda kv: -(kv[1][1] - (kv[1][0] or 0)))[:5]
        for name, (prev, new) in top:
            print(f"  {name}: {prev if prev is not None else 'new'} -> {new}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
