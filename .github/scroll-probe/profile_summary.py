#!/usr/bin/env python3
"""Temporary scroll-probe helper: summarises an `xctrace export` of a Time
Profiler table, keeping only main-thread samples taken inside the probe's
`probeFrameWork` (one display frame's work), and prints where that time went.

Usage: profile_summary.py export.xml [process-name]
"""
import collections
import re
import sys
import xml.etree.ElementTree as ET

PATH = sys.argv[1]
PROCESS = sys.argv[2] if len(sys.argv) > 2 else "Conduit"
PROBE = re.compile(r"probeFrameWork")

memo = {}


def resolve(elem):
    ref = elem.get("ref")
    if ref is not None:
        return memo.get(ref)
    tag = elem.tag
    if tag == "frame":
        binary = "?"
        for child in elem:
            if child.tag == "binary":
                binary = resolve(child) or "?"
        value = (elem.get("name") or elem.get("addr") or "?", binary)
    elif tag == "binary":
        value = elem.get("name") or "?"
    elif tag.endswith("backtrace"):
        frames = []
        for child in elem:
            if child.tag == "frame":
                frames.append(resolve(child))
            elif child.tag.endswith("backtrace"):
                frames.extend(resolve(child) or ())
        value = tuple(f for f in frames if f)
    else:
        # thread, process, weight, sample-time and friends: register any
        # nested definitions so later rows can refer to them.
        for child in list(elem):
            resolve(child)
        if tag in ("thread", "process", "core", "thread-state"):
            value = elem.get("fmt") or (elem.text or "")
        else:
            text = (elem.text or "").strip()
            value = int(text) if text.isdigit() else (elem.get("fmt") or text)
    ident = elem.get("id")
    if ident is not None:
        memo[ident] = value
    return value


rows = 0
kept = 0
main_rows = 0
total_ns = 0
threads = collections.Counter()
step = collections.Counter()
leaf_binary = collections.Counter()
leaf_symbol = collections.Counter()
inclusive = collections.Counter()
inclusive_conduit = collections.Counter()
tree = {}


def short(name, limit=118):
    name = re.sub(r"\s+", " ", name)
    return name if len(name) <= limit else name[: limit - 1] + "…"


def add_path(path, weight):
    node = tree
    for key in path:
        entry = node.get(key)
        if entry is None:
            entry = node[key] = [0, {}]
        entry[0] += weight
        node = entry[1]


for _, elem in ET.iterparse(PATH, events=("end",)):
    if elem.tag != "row":
        continue
    rows += 1
    fields = {}
    for child in elem:
        fields[child.tag] = resolve(child)
    elem.clear()
    thread = str(fields.get("thread") or "")
    threads[thread[:80]] += 1
    if "Main Thread" not in thread or PROCESS not in thread:
        continue
    main_rows += 1
    backtrace = fields.get("backtrace") or fields.get("tagged-backtrace") or ()
    index = next((i for i, f in enumerate(backtrace) if PROBE.search(f[0])), None)
    if index is None:
        continue
    weight = fields.get("weight")
    weight = weight if isinstance(weight, int) else 1_000_000
    callees = backtrace[:index]  # leaf first
    if any("mountedRowEstimate" in f[0] or "ProbeCounters" in f[0] for f in callees):
        continue
    kept += 1
    total_ns += weight
    step[short(callees[-1][0]) if callees else "(probeFrameWork itself)"] += weight
    if callees:
        leaf_binary[callees[0][1]] += weight
        leaf_symbol[short(callees[0][0]) + "  [" + callees[0][1] + "]"] += weight
    seen = set()
    for name, binary in callees:
        key = short(name) + "  [" + binary + "]"
        if key in seen:
            continue
        seen.add(key)
        inclusive[key] += weight
        if binary.startswith("Conduit"):
            inclusive_conduit[key] += weight
    add_path([short(n, 96) + " [" + b + "]" for n, b in reversed(callees)], weight)


def ms(ns):
    return ns / 1_000_000


print(f"PROFILE rows={rows} mainThreadRows={main_rows} probeSamples={kept} probeTime={ms(total_ns):.0f}ms")
if kept == 0:
    print("PROFILE no probe samples; busiest threads:")
    for name, count in threads.most_common(8):
        print(f"PROFILE thread {count} {name}")
    sys.exit(0)


def table(title, counter, limit):
    print(f"PROFILE == {title}")
    for key, value in counter.most_common(limit):
        print(f"PROFILE {ms(value):7.1f}ms {100 * value / total_ns:5.1f}%  {key}")


table("frame step (callee of probeFrameWork)", step, 8)
table("self time by library", leaf_binary, 14)
table("self time by function", leaf_symbol, 40)
table("inclusive, our code", inclusive_conduit, 30)
table("inclusive, all", inclusive, 90)

# The call tree from the frame's work down: nodes under 1.5% are cut, and a
# child carrying nearly all of its parent's time continues on the same line.
print("PROFILE == call tree (ms, % of probe time)")
cutoff = total_ns * 0.015
lines = 0


def walk(node, depth):
    global lines
    for key, (weight, children) in sorted(node.items(), key=lambda kv: -kv[1][0]):
        if weight < cutoff or lines > 420:
            continue
        chain = [key]
        current = children
        while len(current) >= 1:
            heaviest = max(current.items(), key=lambda kv: kv[1][0])
            if heaviest[1][0] >= weight * 0.92 and len(chain) < 6:
                chain.append(heaviest[0])
                current = heaviest[1][1]
            else:
                break
        lines += 1
        print(f"PROFILE {'. ' * depth}{ms(weight):.0f}ms {100 * weight / total_ns:.0f}% " + " > ".join(chain))
        walk(current, depth + 1)


walk(tree, 0)
