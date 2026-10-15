#!/usr/bin/env python3
"""The longest stretches of a build with no new log output.

ci-build-for-testing.sh samples the build log's line count every 2 seconds
into TIMELINE ("<elapsed seconds> <line count>" per line). A stretch where the
count does not move is time xcodebuild spent without finishing anything:
resolving packages, computing the build graph, waiting on the simulator
service, or one long task. Each stretch is printed with the log line it
followed, longest first.

Usage: ci-build-quiet-stretches.py TIMELINE LOG [--top N] [--min-seconds S]
"""

from __future__ import annotations

import argparse
import sys


def read_samples(path):
    samples = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            parts = raw.split()
            if len(parts) != 2 or not all(p.isdigit() for p in parts):
                continue
            samples.append((int(parts[0]), int(parts[1])))
    return samples


def quiet_stretches(samples):
    """(seconds, started_at, line_count) for each run of equal line counts."""
    stretches = []
    i = 0
    while i < len(samples):
        start, count = samples[i]
        j = i
        while j + 1 < len(samples) and samples[j + 1][1] == count:
            j += 1
        end = samples[j + 1][0] if j + 1 < len(samples) else samples[j][0]
        stretches.append((end - start, start, count))
        i = j + 1
    return stretches


def describe(stretches, log_lines, top=6, min_seconds=10):
    rows = []
    for seconds, start, count in sorted(stretches, key=lambda s: -s[0])[:top]:
        if seconds < min_seconds:
            break
        if count == 0 or count > len(log_lines):
            after = "(no output yet)"
        else:
            after = log_lines[count - 1].strip()[:140] or "(blank line)"
        rows.append(f"{seconds}s from {start}s, after: {after}")
    return rows


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("timeline")
    parser.add_argument("log")
    parser.add_argument("--top", type=int, default=6)
    parser.add_argument("--min-seconds", type=int, default=10)
    args = parser.parse_args(argv)
    with open(args.log, encoding="utf-8", errors="replace") as fh:
        log_lines = fh.read().splitlines()
    for row in describe(quiet_stretches(read_samples(args.timeline)), log_lines,
                        args.top, args.min_seconds):
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
