#!/usr/bin/env python3
"""Test inventory and selection for Hermes Conduit's hosted CI.

  * discovers every XCTestCase class under ConduitTests/ and ConduitUITests/
    directly from the Swift sources (no Xcode runtime discovery needed);
  * validates a complete, duplicate-free inventory (a new test class cannot
    silently miss CI);
  * selects what the Smoke job runs (`smoke`) and splits everything else into
    the nightly workflow's shards (`hosted`).

Subcommands
-----------
validate         Inventory check and report, no files written (cheap Linux guard).
smoke            Validate scripts/smoke-suite.json and select the Smoke classes.
hosted           Split the inventory into the nightly shards (scripts/hosted-suite.json).
audit-xctestrun  Fail unless all absolute paths inside a built .xctestrun live
                 under the workspace root.

The CI v2 lane planner (8 unit lanes of 4 batches of 7 classes, with their
watchdogs and job ceilings) was removed on 2026-11-25: no workflow had run its
lanes since CI v5 moved the unit suite to the nightly shards, and its batch
policy still capped the suite at 224 classes.

Determinism: identical inputs produce byte-identical outputs (no timestamps).
Corrupt or missing timing files never fail a command.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import plistlib
import re
import subprocess
import sys

DEFAULT_ESTIMATE_S = 20.0          # unseen/new classes: conservative, not sticky
UNIT_TARGET = "ConduitTests"
UI_TARGET = "ConduitUITests"

# A class declaration line: attributes, optional access level, optional final,
# then "class Name: InheritanceClause". Single-line inheritance is the repo
# convention; the colon anchor keeps mere XCTestCase mentions from matching.
DECL_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:open|public|internal|private|fileprivate)\s+)?"
    r"(?:final\s+)?class\s+([A-Za-z_]\w*)\s*:\s*([^{=;]+)"
)
FIRST_IDENT_RE = re.compile(r"\s*([A-Za-z_]\w*)")


def warn(msg: str) -> None:
    # GitHub Actions parses workflow commands from STDOUT only; stderr would
    # never render as an annotation.
    print(f"::warning::plan-tests: {msg}")


# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------

def _swift_files(root: str) -> list:
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for f in sorted(files):
            if f.endswith(".swift"):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def _parse_decl(line: str):
    m = DECL_RE.match(line)
    if not m:
        return None
    name = m.group(1)
    clause = m.group(2).strip()
    # Direct superclass = first comma-separated element, minus generics.
    first = clause.split(",")[0]
    im = FIRST_IDENT_RE.match(first)
    superclass = im.group(1) if im else ""
    return name, superclass


def discover_test_classes(repo_root: str) -> dict:
    """Discover XCTest classes per target directory. Directory membership (not
    class-name suffix) decides ConduitTests vs ConduitUITests."""
    result = {
        "unit": [], "ui": [],            # [{"name","file","line"}]
        "helpers": [],                   # [{"name","file","line"}]
        "errors": [], "warnings": [],
    }
    # Targets are separate Swift modules: superclass resolution is per target
    # so one target's base class can never redirect the other's ancestry.
    all_classes = {UNIT_TARGET: {}, UI_TARGET: {}}
    direct = {UNIT_TARGET: set(), UI_TARGET: set()}
    file_hits = {UNIT_TARGET: [], UI_TARGET: []}

    for target in (UNIT_TARGET, UI_TARGET):
        root = os.path.join(repo_root, target)
        if not os.path.isdir(root):
            result["errors"].append(f"target directory missing: {target}/")
            continue
        for path in _swift_files(root):
            with open(path, encoding="utf-8", errors="replace") as fh:
                content = fh.read()
            has_test_func = "func test" in content
            for lineno, line in enumerate(content.splitlines(), start=1):
                decl = _parse_decl(line)
                if decl is None:
                    continue
                name, superclass = decl
                rel = os.path.relpath(path, repo_root).replace(os.sep, "/")
                all_classes[target].setdefault(name, superclass)
                if superclass == "XCTestCase":
                    direct[target].add(name)
                file_hits[target].append(
                    {"name": name, "file": rel, "line": lineno,
                     "has_test_func": has_test_func}
                )

    def is_xctestcase(target: str, name: str) -> bool:
        classes = all_classes[target]
        seen = set()
        cur = name
        while cur and cur not in seen:
            seen.add(cur)
            if cur == "XCTestCase":
                return True
            cur = classes.get(cur, "")
        return False

    # Plannable = runs tests in the XCTest runtime:
    #   * *Tests-named classes that resolve to XCTestCase (direct or
    #     transitive) - the repo convention for real suites, or
    #   * direct XCTestCase subclasses with visible test methods and an
    #     unconventional name (kept planned, with a warning).
    # Everything else that merely resolves to XCTestCase (mocks, fakes, test
    # helpers such as MockGateway/FakeSocket, with or without a direct
    # XCTestCase inheritance but no Tests suffix and no visible test methods)
    # enumerates zero tests and is excluded from lanes exactly as the static
    # shard system excluded it.
    for target, bucket in ((UNIT_TARGET, "unit"), (UI_TARGET, "ui")):
        seen_names = {}
        for entry in file_hits[target]:
            name = entry["name"]
            resolves = is_xctestcase(target, name)
            if not resolves and name.endswith("Tests"):
                result["errors"].append(
                    "malformed test declaration: {0} in {1}:{2} looks like a test "
                    "class but does not inherit XCTestCase (directly or "
                    "transitively); it will never execute".format(
                        name, entry["file"], entry["line"])
                )
                continue
            if not resolves:
                continue  # unrelated helper class
            is_suite = name.endswith("Tests") or entry["has_test_func"]
            if not is_suite:
                # Zero visible test methods + unconventional name: a mock or
                # support type. -only-testing would match zero tests for it.
                result["helpers"].append(
                    {"name": name, "file": entry["file"], "line": entry["line"]}
                )
                continue
            if name in seen_names:
                result["errors"].append(
                    f"duplicate test class {name!r} in {target}/: "
                    f"{seen_names[name]} and {entry['file']}:{entry['line']}"
                )
            else:
                seen_names[name] = f"{entry['file']}:{entry['line']}"
                result[bucket].append(
                    {"name": name, "file": entry["file"], "line": entry["line"]}
                )
                if not name.endswith("Tests"):
                    result["warnings"].append(
                        "{0}:{1}: planned XCTestCase subclass {2!r} lacks the "
                        "conventional 'Tests' suffix".format(
                            entry["file"], entry["line"], name)
                    )
                if name.endswith("Tests") and not entry["has_test_func"]:
                    result["warnings"].append(
                        f"{entry['file']}: planned class {name} file contains "
                        "no 'func test' declaration"
                    )

    result["unit"].sort(key=lambda e: e["name"])
    result["ui"].sort(key=lambda e: e["name"])
    result["helpers"].sort(key=lambda e: (e["file"], e["line"]))
    return result


# ---------------------------------------------------------------------------
# timing estimates
# ---------------------------------------------------------------------------

def load_estimates(path, purpose: str) -> tuple:
    """Load a timing file ({'classes': {name: seconds}}). Returns
    (estimates, warnings). Never raises: corrupt/missing -> empty + warning."""
    if not path:
        return {}, []
    if not os.path.exists(path):
        return {}, [f"{purpose} timing file not found: {path} (falling back)"]
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        return {}, [f"{purpose} timing file unreadable/corrupt ({exc}); falling back"]
    if not isinstance(doc, dict) or not isinstance(doc.get("classes", {}), dict):
        return {}, [f"{purpose} timing file has unexpected schema; falling back"]
    estimates, warns = {}, []
    for name, secs in doc["classes"].items():
        # math.isfinite: nan survives the <= 0 check and would poison every
        # downstream sum and comparison (smoke's changed-class budget and
        # the hosted shards' split).
        if (isinstance(secs, bool) or not isinstance(secs, (int, float))
                or not math.isfinite(secs) or secs <= 0):
            warns.append(f"{purpose}: ignoring non-positive timing for {name!r}")
            continue
        estimates[name] = float(secs)
    return estimates, warns


# ---------------------------------------------------------------------------
# xctestrun portability audit
# ---------------------------------------------------------------------------

# Runner-image-stable locations. Deliberately NOT "/private/var/": a
# per-runner temp path under /private/var/folders/... exists only on the
# machine that built the artifact and must fail the portability audit.
SYSTEM_PATH_PREFIXES = (
    "/Applications/",   # Xcode toolchain
    "/System/",
    "/usr/",
    "/Library/",        # Xcode support components
    "/opt/",
)


def _walk_strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _walk_strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _walk_strings(v)


EMBEDDED_ABS_PATH_RE = re.compile(r'(?<![\w])/(?:Users|Volumes)/[^\s\x22\x27]+')
FILE_URL_RE = re.compile(r'file://([^\s\x22\x27]+)')


def audit_xctestrun(xctestrun_path: str, workspace_root: str) -> tuple:
    """Return (violations, paths_checked). A violation is an absolute path in
    the .xctestrun that points outside the workspace root (and outside known
    system locations) — such a path cannot resolve on a different runner."""
    try:
        with open(xctestrun_path, "rb") as fh:
            plist = plistlib.load(fh)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise ValueError(f"unreadable .xctestrun ({exc})")
    # Paths inside .xctestrun are POSIX (macOS); compare textually so the
    # audit itself stays portable (tests run on ubuntu/Windows too).
    import posixpath
    ws = posixpath.normpath(workspace_root).rstrip("/") or "/"
    prefix = ws + "/"

    def violation(path: str) -> bool:
        path = path.rstrip("/")
        if path == ws or path.startswith(prefix):
            return False
        return not any(path.startswith(p) for p in SYSTEM_PATH_PREFIXES)

    violations = set()
    checked = 0
    for s in _walk_strings(plist):
        candidates = set()
        if s.startswith("file://"):
            m = FILE_URL_RE.match(s)
            if m:
                from urllib.parse import unquote
                path = unquote(m.group(1))
                if not path.startswith("/"):
                    # file://host/path form: strip the netloc
                    path = "/" + path.split("/", 1)[-1] if "/" in path else "/"
                candidates.add(path)
        if s.startswith("/"):
            candidates.add(s)
        # Mid-string absolute paths (e.g. embedded in a command-line value)
        # can pin the run to one runner; scan the risky home/volume roots.
        for m in EMBEDDED_ABS_PATH_RE.finditer(s):
            candidates.add(m.group(0))
        for path in candidates:
            checked += 1
            if violation(path):
                violations.add(path)
    return sorted(violations), checked


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

_CLASS_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


_SMOKE_TEST_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)/(test[A-Za-z0-9_]*)$")


def load_smoke_suite(path: str) -> tuple:
    """Read the curated smoke selection. Returns (unit_tests, ui_tests,
    max_unit_tests, max_ui_tests).

    The curated lists name single tests, `Class/testMethod`, never whole
    classes: a class grows with every test added to it, and a list of classes
    let the PR gate grow with it (unit smoke 195 -> 240 s from 2026-10-18 to
    10-29 while the list stayed the same). `max_unit_tests` and
    `max_ui_tests` cap each list, so Smoke grows only when someone raises a
    cap on purpose.

    Fails closed on anything that is not a well-formed suite: the file must be
    a JSON object declaring non-empty `unit` and `ui` lists and both caps.
    Defaulting an absent key to an empty list would turn a malformed edit into
    a silently empty hosted selection.
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("smoke suite must be a JSON object")
    for key in ("unit", "ui"):
        if key not in data:
            raise ValueError("smoke suite must declare a {0!r} list".format(key))
        names = data[key]
        if not isinstance(names, list) or not names:
            raise ValueError(
                "smoke suite {0!r} must be a non-empty list".format(key))
        for name in names:
            if not isinstance(name, str) or not _SMOKE_TEST_RE.match(name):
                raise ValueError(
                    "smoke suite {0!r} entries name one test as Class/testMethod, "
                    "not {1!r}".format(key, name))
    caps = []
    for key in ("max_unit_tests", "max_ui_tests"):
        value = data.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            raise ValueError("smoke suite must declare {0!r} as a positive integer".format(key))
        caps.append(value)
    return list(data["unit"]), list(data["ui"]), caps[0], caps[1]


_TOP_DECL_RE = re.compile(
    r"^(?:(?:@\w+(?:\([^)]*\))?|public|internal|fileprivate|private|final|open)\s+)*"
    r"(?:class|extension)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
_TEST_FUNC_RE = re.compile(
    r"^(?:    |\t)(?:(?:@\w+(?:\([^)]*\))?|override|public|internal|open|nonisolated)\s+)*"
    r"func\s+(test[A-Za-z0-9_]*)\s*\(\s*\)")


def discover_test_methods(repo_root: str, target: str, classes: set) -> dict:
    """The test methods each of `classes` declares in `target`, in its body or
    in an extension of it, as {class: set(method)}. A declaration starts a
    body at column 0 and a `}` at column 0 ends it (the repo's formatting).
    Only parameterless `test...` methods at the body's own level count:
    XCTest runs only those, and a nested type's are not the class's."""
    found = {name: set() for name in classes}
    root = os.path.join(repo_root, target)
    for path in _swift_files(root) if os.path.isdir(root) else []:
        with open(path, encoding="utf-8", errors="replace") as fh:
            current = None
            for line in fh:
                m = _TOP_DECL_RE.match(line)
                if m:
                    current = m.group(1) if m.group(1) in found else None
                    continue
                if line.startswith("}"):
                    current = None
                    continue
                if current:
                    t = _TEST_FUNC_RE.match(line)
                    if t:
                        found[current].add(t.group(1))
    return found


def load_smoke_extras(path: str) -> tuple:
    """Read the smoke suite's optional additions to the unit invocation.
    Returns (source_contracts, changed_budget_s, changed_max_classes).

    `source_contracts` are the static source scans (an accessibility audit,
    log redaction, the privacy manifest): seconds to run, and the classes a
    PR outside their area breaks without touching them. `changed_budget_s`
    caps how much baseline test time the PR's own test classes may add, and
    `changed_max_classes` how many, so the one invocation stays within the
    nightly batch size.
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    contracts = data.get("source_contracts", [])
    if not isinstance(contracts, list):
        raise ValueError("smoke suite 'source_contracts' must be a list")
    for name in contracts:
        if not isinstance(name, str) or not _CLASS_NAME_RE.match(name):
            raise ValueError(
                "smoke suite 'source_contracts' names an invalid class: {0!r}".format(name))
    budget = data.get("changed_budget_s", 0)
    if isinstance(budget, bool) or not isinstance(budget, (int, float)) or budget < 0:
        raise ValueError("smoke suite 'changed_budget_s' must be a non-negative number")
    most = data.get("changed_max_classes", 0)
    if isinstance(most, bool) or not isinstance(most, int) or most < 0:
        raise ValueError("smoke suite 'changed_max_classes' must be a non-negative integer")
    return list(contracts), float(budget), most


# A class with no baseline (about half of them, usually sub-second, or one
# the PR adds) is charged this much of the changed-class budget.
_UNKNOWN_CLASS_COST_S = 3.0
_EXTENSION_RE = re.compile(
    r"^\s*(?:(?:@\w+(?:\([^)]*\))?|package|private|fileprivate|internal|public|open)\s+)*"
    r"extension\s+([A-Za-z_][A-Za-z0-9_]*)\b")


def changed_files_since(repo_root: str, ref: str) -> list:
    """Files that differ between `ref` and HEAD, repo-relative. A ref that is
    missing (a shallow clone, a first commit) yields no files, never an
    error: the extra classes are a bonus on top of the curated set."""
    try:
        proc = subprocess.run(
            ["git", "-C", repo_root, "diff", "--name-only", ref, "HEAD"],
            capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        warn(f"changed files unavailable ({exc}); smoke runs the curated set only")
        return []
    if proc.returncode != 0:
        warn(f"git diff {ref} HEAD failed; smoke runs the curated set only: "
             f"{proc.stderr.strip()}")
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def unit_classes_for_changes(repo_root: str, changed: list, unit_entries: list) -> tuple:
    """Unit classes a change touches, as (direct, related), each in a stable
    order. Direct: classes declared or extended in a changed ConduitTests
    file, and `<Stem>Tests` for a changed app source file `<Stem>.swift`.
    Related: the rest of that stem's family, `<Stem><Topic>Tests` (a change
    to AppState.swift reaches AppStateChatResumeTests). These classes
    otherwise run only at night, so a PR that adds or edits them, or changes
    the code they test, would first see them fail there."""
    by_name = {e["name"] for e in unit_entries}
    by_file = {}
    for e in unit_entries:
        by_file.setdefault(e["file"], []).append(e["name"])
    picked, stems = [], []

    def add(name):
        if name in by_name and name not in picked:
            picked.append(name)

    for rel in changed:
        if not rel.endswith(".swift"):
            continue
        if rel.startswith(UNIT_TARGET + "/"):
            for name in by_file.get(rel, []):
                add(name)
            path = os.path.join(repo_root, rel)
            if os.path.isfile(path):
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        m = _EXTENSION_RE.match(line)
                        if m:
                            add(m.group(1))
        elif not rel.startswith(UI_TARGET + "/"):
            stem = os.path.splitext(os.path.basename(rel))[0].split("+")[0]
            add(stem + "Tests")
            if stem and stem not in stems:
                stems.append(stem)
    related = []
    for stem in stems:
        # `<Stem>` followed by a new word: AppState reaches AppStateChatResume
        # but not AppStatement.
        for name in sorted(by_name):
            if not (name.startswith(stem) and name.endswith("Tests")):
                continue
            topic = name[len(stem):-len("Tests")]
            if topic[:1].isupper() and name not in picked and name not in related:
                related.append(name)
    return picked, related


def _resolve_in_repo(repo_root: str, path: str) -> str:
    """A relative path is read against --repo-root when it exists there, as
    validate's --baseline is, so smoke behaves the same from any working
    directory."""
    if path and not os.path.isabs(path):
        joined = os.path.join(repo_root, path)
        if os.path.exists(joined):
            return joined
    return path


def _baseline_seconds(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    classes = data.get("classes") if isinstance(data, dict) else None
    return classes if isinstance(classes, dict) else {}


def _nightly_only(path: str):
    """The nightly-only timing families, or None when the hosted suite
    cannot be read (the caller then adds no changed classes at all)."""
    try:
        with open(path, encoding="utf-8") as fh:
            names = json.load(fh).get("nightly_only_unit")
    except (OSError, ValueError, AttributeError):
        return None
    return set(names) if isinstance(names, list) else None


def cmd_smoke(args) -> int:
    """Validate the curated smoke selection against the discovered inventory.

    A PR or push run runs only these classes (docs/CI.md, CI v5): every other
    class runs in the nightly workflow (`cmd_hosted`). This subcommand is what
    keeps that selection honest - a class that is renamed, deleted or moved
    between targets fails the plan job instead of silently shrinking PR
    coverage, and the delegated counts are printed so the split is visible on
    every run.
    """
    discovery = discover_test_classes(args.repo_root)
    for w in discovery["warnings"]:
        warn(w)
    if discovery["errors"]:
        for e in discovery["errors"]:
            print(f"::error::{e}")
        return 1

    unit_inventory = {entry["name"] for entry in discovery["unit"]}
    ui_inventory = {entry["name"] for entry in discovery["ui"]}
    try:
        suite_path = _resolve_in_repo(args.repo_root, args.suite)
        unit, ui, max_unit, max_ui = load_smoke_suite(suite_path)
        contracts, changed_budget, changed_max = load_smoke_extras(suite_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"::error::smoke suite unreadable: {exc}")
        return 1

    problems = []
    # Validated per TARGET, never against the union of both: a class moved
    # between ConduitTests/ and ConduitUITests/ would otherwise still validate
    # while the smoke job filters it against the wrong bundle - which runs zero
    # tests for it and silently shrinks hosted coverage. A renamed or deleted
    # test fails the same way.
    for target, tests, inventory, cap, dirname in (
            ("unit", unit, unit_inventory, max_unit, UNIT_TARGET),
            ("ui", ui, ui_inventory, max_ui, UI_TARGET)):
        if len(tests) > cap:
            problems.append(
                f"smoke suite lists {len(tests)} {target} tests, over its cap of "
                f"{cap} (max_{target}_tests): the PR gate stays small on purpose, "
                f"so pin fewer tests or raise the cap in the same change")
        methods = discover_test_methods(
            args.repo_root, dirname,
            {t.split("/")[0] for t in tests} & inventory)
        seen = set()
        for test in tests:
            cls, method = test.split("/")
            if test in seen:
                problems.append(f"smoke suite lists {test!r} twice in {target}")
            seen.add(test)
            if cls not in inventory:
                problems.append(
                    f"smoke suite lists {test!r} in {target}, but {cls} is not a "
                    f"{target} test class")
            elif method not in methods.get(cls, set()):
                problems.append(
                    f"smoke suite lists {test!r} in {target}, but {cls} has no "
                    f"test method {method}()")
    # The timing families run with repeats at night; on every PR's shared
    # runner they flake (docs/CI.md).
    nightly_only_pinned = _nightly_only(_resolve_in_repo(args.repo_root, args.hosted_suite))
    if nightly_only_pinned is None:
        warn(f"hosted suite {args.hosted_suite} unreadable: the pinned tests "
             f"aren't checked against the nightly-only timing families")
    else:
        for test in unit:
            if test.split("/")[0] in nightly_only_pinned:
                problems.append(
                    f"smoke suite pins {test!r}, from a nightly-only timing family "
                    f"(hosted-suite.json nightly_only_unit)")
    for name in contracts:
        if name not in unit_inventory:
            problems.append(
                f"smoke suite lists {name!r} in source_contracts, but it is not "
                f"a unit test class")
        elif any(t.split("/")[0] == name for t in unit):
            problems.append(f"smoke suite lists {name!r} in both unit and source_contracts")
    # Report failures before the split: the delegated counts are only
    # meaningful once every curated name has been validated.
    for e in problems:
        print(f"::error::{e}")
    if problems:
        print("smoke selection FAILED")
        return 1

    curated_unit = list(unit)
    unit = curated_unit + list(contracts)

    # The change's own unit classes join the same invocation (no extra
    # fixed cost), cheapest first within the budget. Timing families stay
    # nightly-only whatever changed.
    changed_unit, changed_skipped, replaced = [], [], []
    changed = []
    if args.changed_files:
        try:
            with open(_resolve_in_repo(args.repo_root, args.changed_files),
                      encoding="utf-8") as fh:
                changed = [line.strip() for line in fh if line.strip()]
        except OSError as exc:
            warn(f"changed files unreadable ({exc}); smoke runs the curated set only")
    elif args.changed_from:
        changed = changed_files_since(args.repo_root, args.changed_from)
    nightly_only = None
    if changed:
        nightly_only = _nightly_only(_resolve_in_repo(args.repo_root, args.hosted_suite))
        if nightly_only is None:
            # Fail closed: without the list a touched timing family would
            # join every PR's run.
            warn(f"hosted suite {args.hosted_suite} unreadable; no changed "
                 f"classes added to smoke")
            changed = []
    if changed:
        baseline = _baseline_seconds(_resolve_in_repo(args.repo_root, args.baseline))
        direct, related = unit_classes_for_changes(
            args.repo_root, changed, discovery["unit"])
        direct = [c for c in direct if c not in contracts and c not in nightly_only]
        related = [c for c in related if c not in contracts and c not in nightly_only]

        def cost(name):
            # Same rules as load_estimates: only a finite positive number
            # is a timing.
            value = baseline.get(name)
            if (isinstance(value, bool) or not isinstance(value, (int, float))
                    or not math.isfinite(value) or value <= 0):
                return _UNKNOWN_CLASS_COST_S
            return float(value)

        # The change's own classes first, then its stems' families in what
        # budget is left, each cheapest first.
        spent = 0.0
        for tier in (direct, related):
            for name in sorted(tier, key=lambda n: (cost(n), n)):
                if (spent + cost(name) <= changed_budget
                        and len(changed_unit) < changed_max):
                    changed_unit.append(name)
                    spent += cost(name)
                else:
                    changed_skipped.append(name)
            # The change's only heavy class still runs once, ahead of any
            # family member (or the cheapest family member when the change
            # has no class of its own): a slow new suite is exactly what
            # would otherwise first fail at night.
            if ((tier is direct or not direct) and not changed_unit
                    and changed_skipped and changed_max > 0):
                cheapest = min(changed_skipped, key=lambda n: (cost(n), n))
                changed_skipped.remove(cheapest)
                changed_unit.append(cheapest)
                spent = cost(cheapest)
                print(f"::notice title=changed class over the smoke budget::"
                      f"{cheapest} (~{spent:.0f}s) runs anyway: nothing else of the "
                      f"change fit")
        changed_unit.sort()
        changed_skipped.sort()
        # A changed class runs whole, so its pinned tests would only repeat.
        replaced = [t for t in curated_unit if t.split("/")[0] in changed_unit]
        unit = [t for t in unit if t not in replaced] + changed_unit
        if changed_unit:
            print(f"changed unit classes added: {', '.join(changed_unit)} "
                  f"(~{spent:.0f}s of {changed_budget:.0f}s)")
        if changed_skipped:
            print(f"::notice title=classes related to this change left to nightly::"
                  f"{', '.join(changed_skipped)} exceed the smoke budget "
                  f"({changed_budget:.0f}s, {changed_max} classes)")

    # Classes Smoke runs nothing of; a class it runs a few tests of still runs
    # whole at night.
    unit_classes = {t.split("/")[0] for t in unit}
    ui_classes = {t.split("/")[0] for t in ui}
    delegated_unit = len(discovery["unit"]) - len(unit_classes)
    delegated_ui = len(discovery["ui"]) - len(ui_classes)
    print(f"smoke selection: {len(curated_unit) - len(replaced)} of {max_unit} pinned unit tests"
          f"{f' ({len(replaced)} more run in their whole changed class)' if replaced else ''}, "
          f"{len(contracts)} source contract classes, {len(changed_unit)} changed "
          f"classes; {len(ui)} of {max_ui} pinned UI tests")
    print(f"not in the smoke set: {delegated_unit} unit + "
          f"{delegated_ui} UI classes (they run only in the nightly workflow: "
          f"the unit shards, the timing families and the full UI suite)")

    if args.out:
        payload = {
            "schema_version": 1,
            "unit": unit,
            "curated_unit": curated_unit,
            "replaced_unit": replaced,
            "source_contracts": list(contracts),
            "max_unit_tests": max_unit,
            "max_ui_tests": max_ui,
            "changed_unit": changed_unit,
            "changed_skipped": changed_skipped,
            "ui": ui,
            "unit_csv": ",".join(unit),
            "ui_csv": ",".join(ui),
            "inventory_unit": len(discovery["unit"]),
            "inventory_ui": len(discovery["ui"]),
            "delegated_unit": delegated_unit,
            "delegated_ui": delegated_ui,
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(f"smoke selection written: {args.out}")
    print("smoke selection OK")
    return 0


def load_hosted_suite(path: str) -> dict:
    """Read the hosted CI shape (scripts/hosted-suite.json).

    Fails closed: the schema version must be 1, shard counts must be positive
    integers and the nightly-only list must name plain Swift classes.
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("hosted suite must be a JSON object")
    if data.get("schema_version") != 1:
        raise ValueError("hosted suite schema_version must be 1, got {0!r}".format(
            data.get("schema_version")))
    for key in ("unit_shards", "nightly_ui_shards"):
        value = data.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise ValueError("hosted suite {0!r} must be a positive integer".format(key))
    names = data.get("nightly_only_unit")
    if not isinstance(names, list):
        raise ValueError("hosted suite must declare a 'nightly_only_unit' list")
    for name in names:
        if not isinstance(name, str) or not _CLASS_NAME_RE.match(name):
            raise ValueError(
                "hosted suite 'nightly_only_unit' names an invalid class: {0!r}".format(name))
    return data


def split_lpt(names: list, estimates: dict, shards: int) -> list:
    """Longest-processing-time split of `names` into `shards` lists.

    Each shard keeps its classes in assignment order (longest first), and ties
    break by name, so the same inventory always produces the same shards.
    """
    buckets = [[] for _ in range(shards)]
    totals = [0.0] * shards
    ordered = sorted(names, key=lambda n: (-estimates.get(n, DEFAULT_ESTIMATE_S), n))
    for name in ordered:
        i = min(range(shards), key=lambda k: (totals[k], k))
        buckets[i].append(name)
        totals[i] += estimates.get(name, DEFAULT_ESTIMATE_S)
    return [b for b in buckets if b]


def cmd_hosted(args) -> int:
    """Split the discovered inventory for the nightly workflow (CI v5).

    Every unit class except the nightly-only timing families, split into
    `unit_shards` balanced shards; the timing families, run with repeats; and
    the whole UI suite split into `nightly_ui_shards` shards. Every discovered
    class lands in exactly one of those lists, so nothing is silently unrun
    (PR and push runs only run the smoke sample of `cmd_smoke`).
    """
    discovery = discover_test_classes(args.repo_root)
    for w in discovery["warnings"]:
        warn(w)
    if discovery["errors"]:
        for e in discovery["errors"]:
            print(f"::error::{e}")
        return 1
    try:
        suite = load_hosted_suite(args.suite)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"::error::hosted suite unreadable: {exc}")
        return 1

    unit_names = [entry["name"] for entry in discovery["unit"]]
    ui_names = [entry["name"] for entry in discovery["ui"]]
    nightly = list(suite["nightly_only_unit"])
    problems = []
    seen = set()
    for name in nightly:
        if name in seen:
            problems.append(f"hosted suite lists {name!r} twice in nightly_only_unit")
        seen.add(name)
        if name not in unit_names:
            problems.append(
                f"hosted suite lists {name!r} in nightly_only_unit, but it is not a unit test class")
    for e in problems:
        print(f"::error::{e}")
    if problems:
        print("hosted selection FAILED")
        return 1

    baseline = args.baseline
    if baseline and not os.path.isabs(baseline):
        baseline = os.path.join(args.repo_root, baseline)
    estimates, ewarns = load_estimates(baseline, "baseline") if baseline else ({}, [])
    for w in ewarns:
        warn(w)

    pr_unit = [n for n in unit_names if n not in seen]
    unit_shards = split_lpt(pr_unit, estimates, suite["unit_shards"])
    ui_shards = split_lpt(ui_names, estimates, suite["nightly_ui_shards"])
    if not unit_shards:
        print("::error::hosted selection has no unit classes for the nightly unit shards")
        return 1
    if not ui_shards:
        print("::error::hosted selection has no UI classes for the nightly run")
        return 1

    print("hosted selection: {0} unit classes in {1} nightly unit shards ({2}), "
          "{3} nightly-only unit classes, {4} UI classes in {5} nightly shards".format(
              len(pr_unit), len(unit_shards), "/".join(str(len(s)) for s in unit_shards),
              len(nightly), len(ui_names), len(ui_shards)))
    if args.out:
        payload = {
            "schema_version": 1,
            "unit_shards": [",".join(s) for s in unit_shards],
            "nightly_unit_csv": ",".join(nightly),
            "ui_shards": [",".join(s) for s in ui_shards],
            "inventory_unit": len(unit_names),
            "inventory_ui": len(ui_names),
        }
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        print(f"hosted selection written: {args.out}")
    print("hosted selection OK")
    return 0


def cmd_validate(args) -> int:
    """Inventory check: every XCTestCase class discovered, none duplicated or
    malformed; a missing or unreadable timing baseline only warns. No cap on
    the class count: the nightly shards (`hosted`) take any number of
    classes."""
    if not os.path.isdir(args.repo_root):
        print(f"::error::repo root not found: {args.repo_root}")
        return 2
    discovery = discover_test_classes(args.repo_root)
    for w in discovery["warnings"]:
        warn(w)
    baseline = args.baseline
    if baseline and not os.path.isabs(baseline):
        joined = os.path.join(args.repo_root, baseline)
        if os.path.exists(joined):
            baseline = joined
    estimates, ewarns = load_estimates(baseline, "baseline")
    for w in ewarns:
        warn(w)
    unit = [e["name"] for e in discovery["unit"]]
    ui = [e["name"] for e in discovery["ui"]]
    timed = sum(1 for name in unit + ui if name in estimates)
    print("discovered {0} unit + {1} UI test classes ({2} warnings); "
          "{3} of them in the timing baseline".format(
              len(unit), len(ui), len(discovery["warnings"]), timed))
    for e in discovery["errors"]:
        print(f"::error::{e}")
    if discovery["errors"]:
        print("inventory validation FAILED")
        return 1
    print("inventory validation OK")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("validate")
    p.add_argument("--repo-root", default=".")
    p.add_argument("--baseline", default=os.path.join("scripts", "test-timings.json"))

    p = sub.add_parser("audit-xctestrun")
    p.add_argument("--xctestrun", required=True)
    p.add_argument("--workspace-root", required=True)

    p = sub.add_parser("smoke")
    p.add_argument("--repo-root", default=".")
    p.add_argument("--suite", default=os.path.join("scripts", "smoke-suite.json"))
    p.add_argument("--out", default="")
    p.add_argument("--changed-from", default="",
                   help="git ref; unit classes the diff to HEAD touches join the smoke run")
    p.add_argument("--changed-files", default="",
                   help="file listing changed paths, one per line (instead of --changed-from)")
    p.add_argument("--hosted-suite", default=os.path.join("scripts", "hosted-suite.json"))
    p.add_argument("--baseline", default=os.path.join("scripts", "test-timings.json"))

    p = sub.add_parser("hosted")
    p.add_argument("--repo-root", default=".")
    p.add_argument("--suite", default=os.path.join("scripts", "hosted-suite.json"))
    p.add_argument("--baseline", default=os.path.join("scripts", "test-timings.json"))
    p.add_argument("--out", default="")

    a = parser.parse_args(argv)

    if a.cmd == "smoke":
        return cmd_smoke(a)
    if a.cmd == "hosted":
        return cmd_hosted(a)

    if a.cmd == "audit-xctestrun":
        violations, checked = audit_xctestrun(a.xctestrun, a.workspace_root)
        print(f"xctestrun audit: {checked} absolute-path entries checked")
        if violations:
            for v in violations:
                print(f"::error::non-portable absolute path in .xctestrun: {v}")
            print(
                "These paths point outside the workspace root; the shared build "
                "artifact would not resolve on a different runner."
            )
            return 1
        print("xctestrun audit OK: all absolute paths are workspace- or system-relative")
        return 0

    return cmd_validate(a)


if __name__ == "__main__":
    sys.exit(main())
