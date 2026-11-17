#!/usr/bin/env python3
"""Refresh scripts/test-timings.json from xcodebuild test logs.

Smoke charges each changed unit class its baseline time against
`changed_budget_s` (scripts/smoke-suite.json), and a class with no baseline
is charged 3 s. The baseline was seeded in August 2026 and drifted: by
2026-11-16 half the unit classes had no entry and others had grown tenfold,
so app-code PRs ran 1,300-2,200 tests (5-9 minutes) against a 120 s budget.

Usage, with the logs of a green nightly's unit shards (GitHub's job logs or
xcodebuild's own output):

    python3 scripts/refresh-test-timings.py --baseline scripts/test-timings.json \
        shard1.log shard2.log

Each `Test Suite 'Name' passed|failed` line and the `Executed N tests ... (S)
seconds` line after it give a class its wall time; a class seen more than once
keeps its longest time. Classes the logs measure replace their entries; every
other entry (the UI classes, the nightly-only timing families) is kept.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys

SUITE = re.compile(r"Test Suite '([A-Za-z_][A-Za-z0-9_]*)' (?:passed|failed) at ")
EXECUTED = re.compile(r"Executed \d+ tests?, with .* \(([0-9]+(?:\.[0-9]+)?)\) seconds")
# Aggregate suites, not classes.
NOT_CLASSES = {"All", "Selected"}


def measure(lines) -> dict:
    """Class name -> longest wall time in seconds, from one log's lines."""
    found = {}
    previous = None
    for line in lines:
        if previous is not None:
            m = EXECUTED.search(line)
            if m:
                seconds = float(m.group(1))
                found[previous] = max(found.get(previous, 0.0), seconds)
            previous = None
        m = SUITE.search(line)
        if m and m.group(1) not in NOT_CLASSES:
            previous = m.group(1)
    return found


def refresh(baseline: dict, measured: dict, now: str) -> dict:
    classes = dict(baseline.get("classes") or {})
    for name, seconds in measured.items():
        classes[name] = round(seconds, 3)
    out = dict(baseline)
    out["classes"] = dict(sorted(classes.items()))
    out["updated_at"] = now
    return out


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--baseline", required=True)
    p.add_argument("logs", nargs="+")
    args = p.parse_args(argv)
    measured = {}
    for path in args.logs:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for name, seconds in measure(fh).items():
                measured[name] = max(measured.get(name, 0.0), seconds)
    if not measured:
        print("no class timings in the logs; baseline unchanged", file=sys.stderr)
        return 1
    with open(args.baseline, encoding="utf-8") as fh:
        baseline = json.load(fh)
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    updated = refresh(baseline, measured, now)
    with open(args.baseline, "w", encoding="utf-8") as fh:
        json.dump(updated, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"{len(measured)} classes measured; {len(updated['classes'])} in the baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
