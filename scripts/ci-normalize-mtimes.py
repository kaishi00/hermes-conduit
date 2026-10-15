#!/usr/bin/env python3
"""Stamp every source file with a modification time derived from its content.

CI restores the previous main build's DerivedData so a job recompiles only
what changed (ci.yml, "Restore the build cache"). Xcode decides what changed
from file timestamps, and a fresh checkout gives every file the clone time, so
without this step every file looks edited and everything rebuilds anyway.

Each tracked file gets a time computed from its git blob id, and each file of
the generated Xcode project a time computed from its bytes: an unchanged file
carries exactly the time it had when the cached build was made, and a changed
file a different one. Directories all get one fixed time. Every stamp lies
between 2001 and 2021, so none is in the future.

Usage: ci-normalize-mtimes.py [--repo-root DIR] [--generated PATH ...]
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys

BASE_NS = 978_307_200 * 10**9  # 2001-01-01T00:00:00Z
SPAN_NS = 20 * 365 * 86_400 * 10**9
DIR_NS = BASE_NS


def stamp_for(hex_digest: str) -> int:
    """The modification time, in nanoseconds, for content with this digest."""
    return BASE_NS + int(hex_digest[:16], 16) % SPAN_NS


def tracked_files(repo_root: str):
    """Yield (path, blob id) for each regular tracked file."""
    out = subprocess.run(
        ["git", "-C", repo_root, "ls-files", "-s", "-z"],
        check=True, capture_output=True).stdout
    for entry in out.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        mode, blob, _stage = meta.split(b" ")
        # Symlinks (120000) and submodules (160000) carry no content of their own.
        if mode not in (b"100644", b"100755"):
            continue
        yield os.fsdecode(path), blob.decode()


def generated_files(root: str):
    """Yield (path, sha1 of bytes) for every file under a generated tree."""
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            digest = hashlib.sha1()
            with open(path, "rb") as fh:
                for block in iter(lambda: fh.read(1 << 20), b""):
                    digest.update(block)
            yield path, digest.hexdigest()


def normalize(repo_root: str, generated=()) -> int:
    """Stamp files and their directories; returns the number of files."""
    count = 0
    dirs = set()
    sources = [(os.path.join(repo_root, path), blob)
               for path, blob in tracked_files(repo_root)]
    for gen in generated:
        sources.extend(generated_files(os.path.join(repo_root, gen)))
    root = os.path.abspath(repo_root)
    for path, digest in sources:
        if not os.path.lexists(path) or os.path.islink(path):
            # Deleted in the working tree, or replaced by a link.
            continue
        stamp = stamp_for(digest)
        os.utime(path, ns=(stamp, stamp))
        count += 1
        parent = os.path.dirname(os.path.abspath(path))
        while parent.startswith(root + os.sep) and parent not in dirs:
            dirs.add(parent)
            parent = os.path.dirname(parent)
    for directory in dirs:
        os.utime(directory, ns=(DIR_NS, DIR_NS))
    return count


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--generated", action="append", default=[],
                        help="an untracked generated tree to stamp by content")
    args = parser.parse_args(argv)
    count = normalize(args.repo_root, args.generated)
    print(f"ci-normalize-mtimes: stamped {count} files by content")
    return 0


if __name__ == "__main__":
    sys.exit(main())
