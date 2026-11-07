#!/usr/bin/env python3
"""Fail when a transcript row would miss a value of the chat's environment.

Each row of the chat transcript draws in a hosting controller of its own
(TranscriptView, #1533), the root of its own SwiftUI hierarchy, so it
inherits nothing from ChatView: a value a row reads comes through
TranscriptCellEnvironment, which copies it from the transcript's environment
and applies it to every row. A key added to Conduit would otherwise read its
default in the rows, with nothing to say so.

So every key Conduit declares (a `var` in an `extension EnvironmentValues`)
is copied there, set in its init (`key = values.key`, or the chat's own
value, as for the disclosure) and applied to the rows
(`.environment(\\.key, values.key)`), or listed in its `setInsideRows`, for
a key the rows set themselves, where they read it. A listed key must be one
Conduit declares, and one something in Conduit sets
(`.environment(\\.key, ...)`), or its default would reach the rows with
nothing to say so. Being text-level, the check can't tell whether that
setter is inside a row or above the transcript, so a key set above the
transcript is copied, never listed. A key set or applied from another key's
value (`key = values.other`) fails too. SwiftUI's own keys are left to the
struct: the traits carry most of them, and it copies the rest.

Text-level, like check-sheet-environment.py, whose Swift reader it uses.

Usage: check-transcript-environment.py [--repo-root DIR]
"""

import argparse
import importlib.util
import os
import re
import sys

SOURCE_DIRS = ("Conduit",)
CELL_ENVIRONMENT = "Conduit/Views/TranscriptCellEnvironment.swift"
ENVIRONMENT_EXTENSION = re.compile(r"\bextension\s+EnvironmentValues\b[^{]*\{")
DECLARED_VAR = re.compile(r"\bvar\s+(\w+)\s*:")
COPYING_INIT = re.compile(r"\binit\s*\(\s*_\s+values\s*:\s*EnvironmentValues\b[^{]*\{")
SET_IN_INIT = re.compile(r"^\s*(\w+)\s*=(?!=)", re.MULTILINE)
SET_FROM_VALUES = re.compile(r"^\s*(\w+)\s*=\s*values\.(\w+)\b", re.MULTILINE)
APPLIED = re.compile(r"\.environment\(\s*\\\.(\w+)\s*,")
APPLIED_FROM_VALUES = re.compile(r"\.environment\(\s*\\\.(\w+)\s*,\s*values\.(\w+)\b")
SET_INSIDE = re.compile(r"\bstatic\s+let\s+setInsideRows\s*=\s*\[([^\]]*)\]")


def _load_swift_reader():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-sheet-environment.py")
    spec = importlib.util.spec_from_file_location("check_sheet_environment", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


swift = _load_swift_reader()


def declared_keys(sources):
    """{key: path} for each `var` at the top level of an EnvironmentValues extension."""
    keys = {}
    for path, raw in sorted(sources.items()):
        text = swift.strip_comments(raw)
        for match in ENVIRONMENT_EXTENSION.finditer(text):
            block = text[match.end() - 1:swift.block_end(text, match.end() - 1)]
            depth, depths = 0, []
            for ch in block:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                depths.append(depth)
            for var in DECLARED_VAR.finditer(block):
                line = block[block.rfind("\n", 0, var.start()) + 1:var.start()]
                if depths[var.start()] == 1 and "static" not in line:
                    keys.setdefault(var.group(1), path)
    return keys


def find_problems(sources):
    """sources: {path: text}. Returns a line for each key a row would miss."""
    if CELL_ENVIRONMENT not in sources:
        return [f"{CELL_ENVIRONMENT}: not found; the transcript rows' environment is copied there"]
    raw = sources[CELL_ENVIRONMENT]
    text = swift.strip_comments(raw)
    init = COPYING_INIT.search(text)
    if not init:
        return [f"{CELL_ENVIRONMENT}: no init(_ values: EnvironmentValues, ...) copying the chat's values"]
    init_text = text[init.end():swift.block_end(text, init.end() - 1)]
    copied = set(SET_IN_INIT.findall(init_text))
    applied = set(APPLIED.findall(text))
    # The list holds strings, which the reader blanks: found in the read
    # text, so no copy in a comment stands for it, and read as written.
    listed = SET_INSIDE.search(text)
    set_inside = set(re.findall(r'"(\w+)"', raw[listed.start(1):listed.end(1)])) if listed else set()

    keys = declared_keys(sources)
    set_elsewhere = set()
    for path, source in sources.items():
        if path != CELL_ENVIRONMENT:
            set_elsewhere |= set(APPLIED.findall(swift.strip_comments(source)))
    problems = []
    for key, path in sorted(keys.items()):
        if key in set_inside or (key in copied and key in applied):
            continue
        if key in copied:
            problems.append(f"{CELL_ENVIRONMENT}: \\.{key} is set in the init but never applied to the rows")
        elif key in applied:
            problems.append(f"{CELL_ENVIRONMENT}: \\.{key} is applied to the rows but never set in the init")
        else:
            problems.append(
                f"{path}: \\.{key} reaches no transcript row; copy it in TranscriptCellEnvironment "
                f"(set in its init, applied in its modifiers) or list it in setInsideRows")
    for key, source in SET_FROM_VALUES.findall(init_text):
        if key != source:
            problems.append(f"{CELL_ENVIRONMENT}: \\.{key} is set in the init from values.{source}")
    for key, source in APPLIED_FROM_VALUES.findall(text):
        if key != source:
            problems.append(f"{CELL_ENVIRONMENT}: \\.{key} is applied to the rows from values.{source}")
    for key in sorted(set_inside - set(keys)):
        problems.append(f"{CELL_ENVIRONMENT}: setInsideRows lists {key}, which Conduit doesn't declare")
    for key in sorted((set_inside & set(keys)) - set_elsewhere):
        problems.append(f"{CELL_ENVIRONMENT}: setInsideRows lists {key}, which nothing in Conduit sets")
    return problems


def load_sources(repo_root):
    sources = {}
    for top in SOURCE_DIRS:
        for dirpath, _, files in os.walk(os.path.join(repo_root, top)):
            for name in files:
                if name.endswith(".swift"):
                    full = os.path.join(dirpath, name)
                    with open(full, encoding="utf-8") as f:
                        sources[os.path.relpath(full, repo_root).replace(os.sep, "/")] = f.read()
    return sources


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = parser.parse_args(argv)
    sources = load_sources(args.repo_root)
    problems = find_problems(sources)
    for problem in problems:
        print(problem)
    if problems:
        print(f"FAIL: {len(problems)} environment key(s) the transcript rows would miss.")
        return 1
    print(f"OK: every Conduit environment key reaches the transcript rows or is set inside them "
          f"({len(declared_keys(sources))} keys).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
