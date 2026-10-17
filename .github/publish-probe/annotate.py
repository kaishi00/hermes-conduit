#!/usr/bin/env python3
"""Temporary scroll-probe helper: prints a text file as GitHub annotations
(10 notices then 10 warnings per step, each under the 4,096 characters an
annotation keeps), since cloud threads read annotations, not the log.

Usage: annotate.py file title [skip-chunks]
"""
import sys

path, title = sys.argv[1], sys.argv[2]
skip = int(sys.argv[3]) if len(sys.argv) > 3 else 0
lines = open(path, errors="replace").read().splitlines()
chunks, current = [], ""


def encode(text):
    return text.replace("%", "%25").replace("\r", "").replace("\n", "%0A")


for line in lines:
    line = encode(line[:600] + "\n")
    if current and len(current) + len(line) > 3900:
        chunks.append(current)
        current = ""
    current += line
if current:
    chunks.append(current)
shown = chunks[skip:skip + 20]
for index, chunk in enumerate(shown):
    kind = "notice" if index < 10 else "warning"
    print(f"::{kind} title={title} {skip + index + 1}/{len(chunks)}::{chunk}")
