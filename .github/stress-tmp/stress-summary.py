#!/usr/bin/env python3
"""Temporary: summarize xcodebuild stress logs into annotations.

Usage: stress-summary.py <title> <log>...
One annotation lists every failing test with its failure count and first
message; a second lists how many yields and milliseconds each traced
condition wait took (STRESS-SETTLE lines from the trace patch).
"""
import collections, re, statistics, sys

title, paths = sys.argv[1], sys.argv[2:]
passed, failed, errors, crashes = collections.Counter(), collections.Counter(), {}, []
settles = collections.defaultdict(list)
for path in paths:
    last_started = None
    with open(path, errors="replace") as f:
        for line in f:
            m = re.search(r"Test Case '-\[ConduitTests\.(\w+) (\w+)\]' (started|passed|failed)", line)
            if m:
                key = f"{m.group(1)}.{m.group(2)}"
                if m.group(3) == "started":
                    last_started = key
                elif m.group(3) == "passed":
                    passed[key] += 1
                else:
                    failed[key] += 1
                continue
            m = re.search(r"(\w+\.swift:\d+): error: -\[ConduitTests\.(\w+) (\w+)\] : (.*)", line)
            if m:
                key = f"{m.group(2)}.{m.group(3)}"
                errors.setdefault(key, f"{m.group(1)}: {m.group(4).strip()}"[:260])
                continue
            m = re.search(r"STRESS-SETTLE (\S+) yields=(\d+) ms=(-?\d+)", line)
            if m:
                settles[m.group(1)].append((int(m.group(2)), int(m.group(3))))
                continue
            if "Restarting after unexpected exit" in line or ("crashed" in line.lower() and "Test Case" not in line):
                crashes.append(f"{last_started}: {line.strip()[:200]}")


def annotate(level, heading, lines):
    text = "\n".join(lines)
    print(f"== {heading}\n{text}")
    enc = text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    safe = heading.replace("%", "%25").replace(":", "%3A").replace(",", "%2C")
    print(f"::{level} title={safe}::{enc}")


total = sum(passed.values()) + sum(failed.values())
lines = [f"{len(paths)} invocation(s), {total} test runs, {sum(failed.values())} failed, "
         f"{len(failed)} distinct tests failed, {len(crashes)} crash lines"]
for key, n in failed.most_common(40):
    lines.append(f"{n}/{n + passed[key]} {key} | {errors.get(key, '')}")
for c in crashes[:8]:
    lines.append(f"CRASH {c}")
annotate("error" if failed or crashes else "notice", f"{title} - results", lines)

if settles:
    rows = []
    for key, samples in settles.items():
        ys = sorted(y for y, _ in samples)
        ms = sorted(t for _, t in samples)
        p = lambda xs, q: xs[min(len(xs) - 1, int(q * len(xs)))]
        rows.append((ys[-1], f"{key}: n={len(samples)} yields median={statistics.median(ys):g} "
                             f"p99={p(ys, 0.99)} max={ys[-1]} | ms median={statistics.median(ms):g} max={ms[-1]}"))
    rows.sort(reverse=True)
    annotate("notice", f"{title} - condition waits", [r for _, r in rows[:60]])
