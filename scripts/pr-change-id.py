#!/usr/bin/env python3
"""Prints an id for a PR's change: its diff from where it meets its base.

Reads `git diff` text (GitHub's compare diff) on stdin. Hunk headers and blob
ids are left out, so merging the base into the PR doesn't change the id; a
binary file keeps its blob id, its only trace of its content. A Markdown file
counts by the words the PR adds and removes, so a resolved conflict in the
feature map, where the base changed the same Checked line, keeps the id when
the PR's own words didn't change. Empty input prints nothing: it never
matches.

CI's plan job skips the smoke job when a PR's change has this id at a commit
whose smoke job already passed (.github/workflows/ci.yml).
"""

from __future__ import annotations

import collections
import hashlib
import sys


def change_id(diff: str) -> str:
    if not diff.strip():
        return ""
    out, md, index = [], False, ""
    added, removed = collections.Counter(), collections.Counter()

    def words():
        if md:
            out.append(repr(sorted((added - removed).items()))
                       + repr(sorted((removed - added).items())))

    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            words()
            added.clear()
            removed.clear()
            md = line.endswith(".md")
            out.append(line)
        elif line.startswith("index "):
            index = line
        elif line.startswith("@@"):
            continue
        elif line.startswith(("Binary files ", "GIT binary patch")):
            out.extend([index, line])
        elif md and line.startswith(("+++ ", "--- ")):
            out.append(line)
        elif md and line.startswith("+"):
            added.update(line[1:].split())
        elif md and line.startswith("-"):
            removed.update(line[1:].split())
        elif not md:
            out.append(line)
    words()
    return hashlib.sha256("\n".join(out).encode("utf-8", "surrogateescape")).hexdigest()


if __name__ == "__main__":
    # Bytes that aren't UTF-8 (a Latin-1 file) pass through unchanged.
    print(change_id(sys.stdin.buffer.read().decode("utf-8", "surrogateescape")))
