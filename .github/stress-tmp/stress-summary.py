#!/usr/bin/env python3
"""Temporary: summarize an xcodebuild -test-iterations log into one annotation."""
import collections, re, sys
log_path, title = sys.argv[1], sys.argv[2]
passed, failed, errors, crashes = collections.Counter(), collections.Counter(), {}, []
last_started = None
with open(log_path, errors="replace") as f:
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
        if "Restarting after unexpected exit" in line or "crashed" in line.lower() and "Test Case" not in line:
            crashes.append(f"{last_started}: {line.strip()[:200]}")
total = sum(passed.values()) + sum(failed.values())
lines = [f"{total} test runs, {sum(failed.values())} failed, {len(failed)} distinct tests failed, {len(crashes)} crash lines"]
for key, n in failed.most_common(40):
    lines.append(f"{n}/{n + passed[key]} {key} | {errors.get(key, '')}")
for c in crashes[:8]:
    lines.append(f"CRASH {c}")
text = "\n".join(lines)
print(text)
enc = text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
level = "error" if failed or crashes else "notice"
print(f"::{level} title={title}::{enc}")
