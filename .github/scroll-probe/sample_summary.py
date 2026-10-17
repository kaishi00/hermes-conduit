#!/usr/bin/env python3
"""Temporary scroll-probe helper: summarises a macOS `sample` report of the
frame probe. It keeps the main thread's samples taken inside the probe's
frame loop (ProbeFrameClock.run) that were not waiting for the next event:
the work the scrolled frames did. One sample is one millisecond at the
default interval.

Usage: sample_summary.py sample.txt
"""
import collections
import re
import sys

PATH = sys.argv[1]
LOOP = re.compile(r"ProbeFrameClock.*\brun\(")
# Where an idle run loop sleeps until its next event.
WAITS = ("__CFRunLoopServiceMachPort",)

lines = open(PATH, errors="replace").read().splitlines()
try:
    start = next(i for i, line in enumerate(lines) if line.startswith("Call graph:"))
except StopIteration:
    print("PROFILE no call graph in the sample report")
    for line in lines[:12]:
        print("PROFILE  " + line[:200])
    sys.exit(0)
end = next(
    (i for i in range(start + 1, len(lines))
     if lines[i].startswith("Total number in stack") or lines[i].startswith("Binary Images:")),
    len(lines),
)

NODE = re.compile(r"^([ +!:|]*?)(\d+) (.*)$")
THREAD = re.compile(r"^\s*\d+ Thread_")


class Node:
    __slots__ = ("name", "binary", "count", "children")

    def __init__(self, name, binary, count):
        self.name = name
        self.binary = binary
        self.count = count
        self.children = []


def parse_frame(text):
    match = re.match(r"(.*?)  \(in ([^)]+)\)", text)
    if match:
        return match.group(1).strip(), match.group(2).strip()
    return text.strip(), "?"


# Every thread's tree: a thread's line has no tree marks, its frames sit two
# columns deeper per level.
threads = []
stack = []
base = 0
for line in lines[start + 1:end]:
    if THREAD.match(line):
        match = NODE.match(line)
        root = Node(match.group(3), "", int(match.group(2)))
        threads.append(root)
        base = len(match.group(1))
        stack = [root]
        continue
    match = NODE.match(line)
    if not match or not stack:
        continue
    prefix, count, rest = match.groups()
    depth = max(1, (len(prefix) - base) // 2)
    name, binary = parse_frame(rest)
    node = Node(name, binary, int(count))
    while len(stack) > depth:
        stack.pop()
    stack[-1].children.append(node)
    stack.append(node)

print(f"PROFILE threads={len(threads)}: " + "; ".join(f"{t.count} {t.name[:60]}" for t in threads[:6]))
if not threads:
    for line in lines[start:start + 25]:
        print("PROFILE  | " + line[:160])
    sys.exit(0)
main_threads = [t for t in threads if "com.apple.main-thread" in t.name] or threads[:1]

# The frame loop's nodes on the main thread; the whole main thread when the
# loop isn't found.
roots = []


def find(node):
    if LOOP.search(node.name):
        roots.append(node)
        return
    for child in node.children:
        find(child)


for thread in main_threads:
    find(thread)
loop_samples = sum(root.count for root in roots)
if not roots:
    print("PROFILE no frame loop found: the whole main thread, waits left out")
    roots = main_threads

# The loop's subtrees merged by call path, each node's count without the
# samples spent waiting under it.
merged = {}


def merge(node, into):
    if any(wait in node.name for wait in WAITS):
        return 0
    key = (node.name, node.binary)
    entry = into.get(key)
    if entry is None:
        entry = into[key] = [0, {}]
    kept = max(0, node.count - sum(child.count for child in node.children))
    for child in node.children:
        kept += merge(child, entry[1])
    entry[0] += kept
    return kept


total = 0
for root in roots:
    for child in root.children:
        total += merge(child, merged)
print(
    f"PROFILE mainThreadSamples={sum(t.count for t in main_threads)} frameLoopSamples={loop_samples} "
    f"busy={total} (1 sample = 1 ms)"
)
if total == 0:
    for line in lines[start:start + 25]:
        print("PROFILE  | " + line[:160])
    sys.exit(0)


def short(name, limit=118):
    name = re.sub(r"\s+", " ", name)
    return name if len(name) <= limit else name[: limit - 1] + "…"


callouts = collections.Counter()
self_binary = collections.Counter()
self_symbol = collections.Counter()
inclusive = collections.Counter()
inclusive_ours = collections.Counter()


def walk(tree, ancestors, parent):
    for (name, binary), (count, children) in tree.items():
        if count == 0:
            continue
        key = short(name) + "  [" + binary + "]"
        child_total = sum(c[0] for c in children.values())
        own = count - child_total
        if own > 0:
            self_binary[binary] += own
            self_symbol[key] += own
        if key not in ancestors:
            inclusive[key] += count
            if binary.startswith("Conduit"):
                inclusive_ours[key] += count
        # What each run-loop callout ran: an observer (SwiftUI's update,
        # the Core Animation commit), a source (the display link, touches),
        # a timer or the main queue.
        if parent.startswith("__CFRUNLOOP_IS_CALLING_OUT_TO_"):
            callouts[short(parent.replace("__CFRUNLOOP_IS_CALLING_OUT_TO_", ""), 40) + " > " + key] += count
        walk(children, ancestors | {key}, name)


walk(merged, frozenset(), "")


def table(title, counter, limit):
    print(f"PROFILE == {title}")
    for key, value in counter.most_common(limit):
        print(f"PROFILE {value:7d}ms {100 * value / total:5.1f}%  {key}")


table("run-loop callouts", callouts, 16)
table("self time by library", self_binary, 14)
table("self time by function", self_symbol, 40)
table("inclusive, our code", inclusive_ours, 30)
table("inclusive, all", inclusive, 90)

# The call tree of the frames' work: nodes under 1.5% are cut, and a child
# carrying nearly all of its parent's time continues on the same line.
print("PROFILE == call tree (ms, % of busy time)")
cutoff = total * 0.015
printed = 0


def tree_walk(tree, depth):
    global printed
    for (name, binary), (count, children) in sorted(tree.items(), key=lambda kv: -kv[1][0]):
        if count < cutoff or printed > 420:
            continue
        chain = [short(name, 96) + " [" + binary + "]"]
        current = children
        while current:
            heaviest = max(current.items(), key=lambda kv: kv[1][0])
            if heaviest[1][0] >= count * 0.92 and len(chain) < 6:
                chain.append(short(heaviest[0][0], 96) + " [" + heaviest[0][1] + "]")
                current = heaviest[1][1]
            else:
                break
        printed += 1
        print(f"PROFILE {'. ' * depth}{count}ms {100 * count / total:.0f}% " + " > ".join(chain))
        tree_walk(current, depth + 1)


tree_walk(merged, 0)
