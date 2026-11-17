#!/usr/bin/env python3
"""How many Swift files each target compiled, from an xcodebuild log.

Xcode logs one `SwiftCompile normal <arch> <file> (in target 'X' from
project 'Y')` line per file, so counting them per target shows what a slow
incremental build rebuilt (a hand-written `==` or an AppState member can
recompile most of the app, docs/CI.md). Prints e.g. `412 Conduit, 351
ConduitTests`, most first, or `none`.
"""

import re
import sys
from collections import Counter

LINE = re.compile(r"^SwiftCompile normal .*\(in target '([^']+)'")


def counts(lines):
    found = Counter(m.group(1) for m in map(LINE.match, lines) if m)
    return sorted(found.items(), key=lambda item: (-item[1], item[0]))


def describe(pairs):
    return ", ".join(f"{n} {target}" for target, n in pairs) or "none"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        with open(argv[0], encoding="utf-8", errors="replace") as log:
            print(describe(counts(log)))
    except OSError:
        print("none")
    return 0


if __name__ == "__main__":
    sys.exit(main())
