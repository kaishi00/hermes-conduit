#!/usr/bin/env python3
"""Temporary: -only-testing ids for every test method in the given files."""
import re, sys
ids = []
for path in sys.argv[1:]:
    scope = None
    depth = 0
    for line in open(path):
        if depth == 0:
            m = re.match(r"\s*(?:@MainActor\s+)?(?:final\s+)?(?:class|extension)\s+(\w+)", line)
            if m:
                scope = m.group(1)
        m = re.match(r"\s*(?:@MainActor\s+)?func (test\w*)\(", line)
        if m and depth == 1 and scope:
            ids.append(f"ConduitTests/{scope}/{m.group(1)}")
        depth += line.count("{") - line.count("}")
print(",".join(ids))
