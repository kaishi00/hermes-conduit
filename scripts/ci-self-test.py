#!/usr/bin/env python3
"""Partition full unittest discovery into three fixed hosted Linux groups."""
import argparse
import collections
import os
import sys
import unittest

GROUPS = ("fast", "lane", "local-gate")
SLOW_MODULES = {"test_lane_runner": "lane", "test_local_ci_gate": "local-gate"}


def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item


def partition_tests(suite):
    groups = {group: [] for group in GROUPS}
    counts = collections.Counter()
    for test in flatten(suite):
        counts[test.id()] += 1
        module = type(test).__module__.rsplit(".", 1)[-1]
        groups[SLOW_MODULES.get(module, "fast")].append(test)
    duplicates = [test_id for test_id, count in counts.items() if count != 1]
    if duplicates:
        raise ValueError("duplicate discovery IDs: " + ", ".join(duplicates))
    return groups


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", required=True, choices=GROUPS)
    parser.add_argument("--tests-dir", default=os.path.join(os.path.dirname(__file__), "tests"))
    args = parser.parse_args()
    # The plan job's skip flag must never suppress a hosted self-test group.
    os.environ.pop("CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS", None)
    loader = unittest.TestLoader()
    suite = loader.discover(os.path.abspath(args.tests_dir), pattern="test_*.py")
    if loader.errors:
        for error in loader.errors:
            print(error, file=sys.stderr)
        return 1
    try:
        groups = partition_tests(suite)
        selected = groups[args.group]
        if not selected:
            raise ValueError("self-test group is empty: " + args.group)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("Discovery groups: " + ", ".join(f"{group}={len(tests)}" for group, tests in groups.items()), flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(selected))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
