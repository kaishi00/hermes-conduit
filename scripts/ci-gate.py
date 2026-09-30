#!/usr/bin/env python3
"""CI Gate: the single stable branch-protection verdict for Hermes Conduit.

GitHub-hosted CI is the merge gate (docs/CI.md, CI v4). Its jobs must never
be required individually, so this job aggregates them into one stable status
context ("CI Gate").

Policy:
  plan        must be success
  unit        must be success (the aggregate of every unit shard)
  ui-smoke    must be success
  self-test   must be success (the CI-tooling regression suites)

No hosted job is ever legitimately skipped: the plan job fails closed on an
empty selection and every test job refuses to run unfiltered, so `skipped`
here always means an upstream failure cascade - which fails the gate anyway.

Anything else - failure, cancelled, skipped upstream of a failure - fails the
gate. The nightly workflow (nightly.yml) reports the timing families and the
complete UI suite separately; it never gates a merge.
"""

from __future__ import annotations

import argparse
import sys

REQUIRED_SUCCESS = ("plan", "unit", "ui-smoke", "self-test")


def verdict(plan: str, unit: str, ui_smoke: str, self_test: str) -> tuple:
    """Return (passed, reason). Reason lists every violated expectation."""
    results = {"plan": plan, "unit": unit, "ui-smoke": ui_smoke,
               "self-test": self_test}
    failures = []
    for name in REQUIRED_SUCCESS:
        if results[name] != "success":
            failures.append(f"{name} must be 'success', got {results[name]!r}")
    return (not failures), "; ".join(failures)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--ui-smoke", required=True, dest="ui_smoke")
    parser.add_argument("--self-test", required=True)
    args = parser.parse_args(argv)

    passed, reason = verdict(args.plan, args.unit, args.ui_smoke,
                             args.self_test)
    if passed:
        print("CI Gate: PASS (plan/unit/ui-smoke/self-test all succeeded)")
        return 0
    print(f"CI Gate: FAIL - {reason}")
    print("::error::CI Gate failed: " + reason)
    return 1


if __name__ == "__main__":
    sys.exit(main())
