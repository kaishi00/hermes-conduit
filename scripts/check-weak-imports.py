#!/usr/bin/env python3
"""Keep Foundation's back-deployed Date comparisons out of shipped builds,
and the frameworks some supported OS lacks weak-linked.

The iOS and watchOS 27.2 SDKs mark Foundation's `Date.<=` and `Date.>=`
`@backDeployed(before: 27.2)`, so a build made with them weak-imports both and
calls Foundation's copy on 27.2 and later. Foundation in the early 27.2 betas
doesn't export them, and TestFlight builds 250 to 252 jumped to a null pointer
at launch there (2026-11-05). Shared/DateOrder/DateOrder.swift declares both in
each target, so a comparison of two Dates never reaches Foundation's.

Two checks:

  targets   (Linux) every application and app extension in project.yml
            compiles Shared/DateOrder, through `Shared` or the folder itself,
            and no `excludes:` of that source leaves it out.
  binaries  (macOS) no Mach-O under a products folder (the app, its .debug.dylib
            in a Debug build, every .appex and framework; not test bundles or
            UI test runners) weak-imports a symbol in BANNED. Reads `nm -m`: an undefined weak external whose name
            starts with a banned symbol (its thunks included) fails; a
            Debug build's own thunks for them (`...FZTwb`, defined in
            __TEXT) are the app's code, not imports, and pass.
            Also reads `otool -l`: a Mach-O that loads a framework in
            WEAK_FRAMEWORKS must load it weak (LC_LOAD_WEAK_DYLIB), or dyld
            stops the app at launch where the framework is missing.

Usage: check-weak-imports.py targets [--repo-root DIR]
       check-weak-imports.py binaries --products DIR
"""

import argparse
import fnmatch
import os
import re
import subprocess
import sys

DATE_ORDER = "Shared/DateOrder"
DATE_ORDER_FILE = DATE_ORDER + "/DateOrder.swift"
SHIPPED_TYPES = {"application", "app-extension"}

# Back-deployed API that an OS in the field may lack although it passes the
# availability check (an early beta of the version it was back-deployed to).
BANNED = {
    "_$s10Foundation4DateV2leoiySbAC_ACtFZ": "Date.<=, back-deployed before iOS/watchOS 27.2",
    "_$s10Foundation4DateV2geoiySbAC_ACtFZ": "Date.>=, back-deployed before iOS/watchOS 27.2",
}

# Frameworks a supported OS lacks, so a strong link stops Conduit at launch
# there; project.yml weak-links each (`sdk: ... weak: true`).
WEAK_FRAMEWORKS = {
    "ActivityKit": "macOS 14 has none for iPhone and iPad apps (issue 1877)",
    "ImagePlayground": "iOS 17 has none",
}

MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",  # 32-bit
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",  # 64-bit
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",  # universal
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",  # universal, 64-bit offsets
}


def shipped_targets(project_yml):
    """{target name: [(source path, [its excludes])]} for every application and
    app extension. Reads project.yml's shape (two-space indents), not YAML."""
    targets = {}
    in_targets = False
    name = None
    kinds = {}
    in_excludes = False
    for line in project_yml.splitlines():
        # A comment after a key (`excludes:  # why`) is no part of it.
        line = re.sub(r"(^|\s+)#.*$", "", line).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            in_targets = line == "targets:"
            name = None
            continue
        if not in_targets:
            continue
        if indent == 2 and line.endswith(":"):
            name = line.strip()[:-1]
            targets[name] = []
            continue
        if name is None:
            continue
        match = re.match(r"^\s{4}type:\s*(\S+)", line)
        if match:
            kinds[name] = match.group(1)
            continue
        match = re.match(r"^\s{6}- path:\s*(\S+)", line)
        if match:
            targets[name].append((match.group(1).strip("\"'").rstrip("/"), []))
            in_excludes = False
            continue
        if targets[name] and re.match(r"^\s{8}excludes:$", line):
            in_excludes = True
            continue
        match = re.match(r"^\s{10}-\s*(\S+)", line)
        if in_excludes and match:
            targets[name][-1][1].append(match.group(1).strip("\"'"))
            continue
        if indent <= 8:
            in_excludes = False
    return {n: sources for n, sources in targets.items() if kinds.get(n) in SHIPPED_TYPES}


def compiles_date_order(sources):
    """Whether a target's sources reach Shared/DateOrder/DateOrder.swift and
    no excludes pattern of that source drops it."""
    for path, excludes in sources:
        if path == DATE_ORDER_FILE:
            return True
        if DATE_ORDER_FILE.startswith(path + "/"):
            rest = DATE_ORDER_FILE[len(path) + 1:]
            # A pattern drops the file, or a folder it's in (`DateOrder`).
            if not any(fnmatch.fnmatch(rest, pattern) or rest.startswith(pattern.rstrip("/") + "/")
                       for pattern in excludes):
                return True
    return False


def target_problems(project_yml):
    targets = shipped_targets(project_yml)
    if not targets:
        return ["project.yml: no application or app extension targets found; the check can't read it"]
    problems = []
    for name, sources in sorted(targets.items()):
        if not compiles_date_order(sources):
            problems.append(
                f"project.yml: target {name} doesn't compile {DATE_ORDER_FILE}: "
                f"add `- path: {DATE_ORDER}` to its sources (or drop the excludes that leave it out)")
    return problems


def weak_import_problems(binary, nm_output):
    problems = []
    for line in nm_output.splitlines():
        # Only what dyld must find in another image: an undefined symbol.
        if "weak external" not in line or "(undefined)" not in line:
            continue
        for symbol, what in BANNED.items():
            if symbol in line:
                problems.append(f"{binary}: weak-imports {symbol} ({what})")
    return problems


def strong_link_problems(binary, otool_output):
    """Problems for each WEAK_FRAMEWORKS framework `otool -l` shows loaded by
    a plain LC_LOAD_DYLIB (or a re-export or upward load) instead of
    LC_LOAD_WEAK_DYLIB."""
    problems = []
    command = None
    for line in otool_output.splitlines():
        words = line.split()
        if len(words) >= 2 and words[0] == "cmd":
            command = words[1]
        elif len(words) >= 2 and words[0] == "name" and command and command.startswith("LC_") and "DYLIB" in command:
            framework = os.path.basename(words[1])
            if framework in WEAK_FRAMEWORKS and command != "LC_LOAD_WEAK_DYLIB":
                problems.append(f"{binary}: links {framework} strongly ({command}); "
                                f"{WEAK_FRAMEWORKS[framework]}, so it must be weak")
    return problems


def is_macho(path):
    try:
        with open(path, "rb") as handle:
            return handle.read(4) in MACHO_MAGICS
    except OSError:
        return False


def binaries_under(products):
    for root, dirs, files in os.walk(products):
        # Test bundles and UI test runners don't ship (a test bundle that
        # imports the app's internals uses Foundation's comparisons).
        dirs[:] = [d for d in dirs if not d.endswith(".xctest") and not d.endswith("-Runner.app")]
        for file in files:
            path = os.path.join(root, file)
            if not os.path.islink(path) and is_macho(path):
                yield path


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="mode", required=True)
    targets = sub.add_parser("targets")
    targets.add_argument("--repo-root", default=".")
    binaries = sub.add_parser("binaries")
    binaries.add_argument("--products", required=True)
    args = parser.parse_args()

    if args.mode == "targets":
        with open(os.path.join(args.repo_root, "project.yml"), encoding="utf-8") as handle:
            problems = target_problems(handle.read())
        checked = "shipped targets"
    else:
        problems = []
        count = 0
        for path in binaries_under(args.products):
            count += 1
            nm = subprocess.run(["xcrun", "nm", "-m", path], capture_output=True, text=True)
            if nm.returncode != 0:
                # A binary nm can't read is one the check didn't look at.
                problems.append(f"{os.path.relpath(path, args.products)}: nm failed "
                                f"(exit {nm.returncode}): {nm.stderr.strip()}")
                continue
            problems += weak_import_problems(os.path.relpath(path, args.products), nm.stdout)
            otool = subprocess.run(["xcrun", "otool", "-l", path], capture_output=True, text=True)
            if otool.returncode != 0:
                problems.append(f"{os.path.relpath(path, args.products)}: otool failed "
                                f"(exit {otool.returncode}): {otool.stderr.strip()}")
                continue
            problems += strong_link_problems(os.path.relpath(path, args.products), otool.stdout)
        if count == 0:
            print(f"::error::no Mach-O files under {args.products}")
            return 1
        checked = f"{count} Mach-O files"

    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        print("Foundation's back-deployed Date comparisons crash on early 27.2 betas "
              "(see Shared/DateOrder/DateOrder.swift), and a strongly linked framework "
              "an OS lacks stops Conduit at launch there (project.yml weak: true).")
        return 1
    print(f"check-weak-imports: {checked} OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
