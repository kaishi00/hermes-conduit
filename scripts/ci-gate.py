#!/usr/bin/env python3
"""CI Gate: the single stable branch-protection verdict for Hermes Conduit.

The unit-test matrix is dynamically sized (4-8 lanes), so individual lane
jobs must never be required directly. This job aggregates the upstream
results into one stable status context ("CI Gate").

Policy:
  plan  must be success
  build must be success
  unit  must be success
  ui    must be success OR skipped (skipped is legitimate when the repo
        contains no UI test classes)

Anything else - failure, cancelled, skipped upstream of a failure - fails
the gate.
"""

from __future__ import annotations

import argparse
import sys

REQUIRED_SUCCESS = ("plan", "build", "unit")
UI_ALLOWED = ("success", "skipped")


def verdict(plan: str, build: str, unit: str, ui: str) -> tuple:
    """Return (passed, reason). Reason lists every violated expectation."""
    results = {"plan": plan, "build": build, "unit": unit, "ui": ui}
    failures = []
    for name in REQUIRED_SUCCESS:
        if results[name] != "success":
            failures.append(f"{name} must be 'success', got {results[name]!r}")
    if results["ui"] not in UI_ALLOWED:
        failures.append(
            f"ui must be 'success' or 'skipped', got {results['ui']!r}")
    return (not failures), "; ".join(failures)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--unit", required=True)
    parser.add_argument("--ui", required=True)
    args = parser.parse_args(argv)

    passed, reason = verdict(args.plan, args.build, args.unit, args.ui)
    if passed:
        print("CI Gate: PASS (plan/build/unit succeeded; ui "
              f"{args.ui!r})")
        return 0
    print(f"CI Gate: FAIL - {reason}")
    print("::error::CI Gate failed: " + reason)
    return 1


if __name__ == "__main__":
    sys.exit(main())
