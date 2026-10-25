#!/usr/bin/env python3
"""Run full unittest discovery of the CI tooling suites for the hosted Linux self-test."""
import argparse
import os
import sys
import unittest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests-dir", default=os.path.join(os.path.dirname(__file__), "tests"))
    args = parser.parse_args()
    # The plan job's skip flag must never suppress a hosted self-test.
    os.environ.pop("CONDUIT_CI_SKIP_BASH_WRAPPER_TESTS", None)
    loader = unittest.TestLoader()
    suite = loader.discover(os.path.abspath(args.tests_dir), pattern="test_*.py")
    if loader.errors:
        for error in loader.errors:
            print(error, file=sys.stderr)
        return 1
    if not suite.countTestCases():
        print("self-test discovered no tests", file=sys.stderr)
        return 1
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
