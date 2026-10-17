#!/usr/bin/env python3
"""Temporary scroll-probe helper: summarises a macOS `sample` report,
keeping only main-thread samples taken inside the probe's `probeFrameWork`
(one display frame's work), and prints where that time went. One sample is
one millisecond at the default interval.

Usage: sample_summary.py sample.txt
"""
import collections
import re
import sys

PATH = sys.argv[1]
PROBE = "probeFrameWork"

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


main_thread = None
stack = []
for line in lines[start + 1:end]:
    match = NODE.match(line)
    if not match:
        continue
    prefix, count, rest = match.groups()
    depth = (len(prefix) - 4) // 2
    count = int(count)
    if depth <= 0:
        # A thread: only the main one is kept.
        stack = []
        if "com.apple.main-thread" in rest and main_thread is None:
            main_thread = Node("main thread", "", count)
            stack = [main_thread]
        continue
    if not stack:
        continue
    name, binary = parse_frame(rest)
    node = Node(name, binary, count)
    while len(stack) > depth:
        stack.pop()
    if len(stack) < depth:
        # A gap in the indentation; attach to the deepest node.
        pass
    stack[-1].children.append(node)
    stack.append(node)

if main_thread is None:
    print("PROFILE no main thread in the sample report")
    sys.exit(0)

# Every probeFrameWork node's subtree, merged by call path.
merged = {}
total = 0


def merge(node, into):
    key = (node.name, node.binary)
    entry = into.get(key)
    if entry is None:
        entry = into[key] = [0, {}]
    entry[0] += node.count
    for child in node.children:
        merge(child, entry[1])


def find(node):
    global total
    if PROBE in node.name:
        total += node.count
        for child in node.children:
            merge(child, merged)
        return
    for child in node.children:
        find(child)


find(main_thread)
print(f"PROFILE mainThreadSamples={main_thread.count} probeSamples={total} (1 sample = 1 ms)")
if total == 0:
    sys.exit(0)


def short(name, limit=118):
    name = re.sub(r"\s+", " ", name)
    return name if len(name) <= limit else name[: limit - 1] + "…"


step = collections.Counter()
self_binary = collections.Counter()
self_symbol = collections.Counter()
inclusive = collections.Counter()
inclusive_ours = collections.Counter()


def walk(tree, ancestors):
    for (name, binary), (count, children) in tree.items():
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
        walk(children, ancestors | {key})


for (name, binary), (count, _) in merged.items():
    step[short(name)] += count
walk(merged, frozenset())


def table(title, counter, limit):
    print(f"PROFILE == {title}")
    for key, value in counter.most_common(limit):
        print(f"PROFILE {value:7d}ms {100 * value / total:5.1f}%  {key}")


table("frame step (callee of probeFrameWork)", step, 8)
table("self time by library", self_binary, 14)
table("self time by function", self_symbol, 40)
table("inclusive, our code", inclusive_ours, 30)
table("inclusive, all", inclusive, 90)

# The call tree from the frame's work down: nodes under 1.5% are cut, and a
# child carrying nearly all of its parent's time continues on the same line.
print("PROFILE == call tree (ms, % of probe time)")
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
