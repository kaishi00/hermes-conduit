#!/usr/bin/env python3
"""Render the hosted smoke selection (scripts/plan-tests.py smoke output) as
Markdown for the GitHub step summary.

Kept as a script rather than inline YAML so the wording and the split between
PR coverage and nightly coverage are reviewable, and so the summary can be
asserted in the CI-tooling tests.
"""

from __future__ import annotations

import argparse
import json
import sys


def _count(value) -> str:
    """Render a count that a hand-built selection fixture may omit."""
    return "?" if value is None else str(value)


def render(selection: dict) -> str:
    unit = list(selection.get("unit") or [])
    ui = list(selection.get("ui") or [])
    lines = [
        "### Hosted CI selection",
        "",
        "Every unit class except the nightly-only timing families runs in the",
        "unit shard jobs (`scripts/hosted-suite.json`). UI tests run the curated",
        "smoke classes below; the complete UI suite and the timing families run",
        "in the nightly workflow.",
        "",
        f"- UI smoke classes: **{len(ui)}** of {_count(selection.get('inventory_ui'))}",
        f"- UI classes left to the nightly run: {_count(selection.get('delegated_ui'))}",
        "",
        "UI: " + ", ".join(ui),
        "",
    ]
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", required=True,
                        help="JSON written by `plan-tests.py smoke --out`")
    args = parser.parse_args(argv)

    with open(args.selection, encoding="utf-8") as fh:
        selection = json.load(fh)
    if not selection.get("unit") or not selection.get("ui"):
        print("::error::smoke selection is empty for at least one target - "
              "hosted CI would exercise nothing there")
        return 1
    sys.stdout.write(render(selection))
    return 0


if __name__ == "__main__":
    sys.exit(main())
