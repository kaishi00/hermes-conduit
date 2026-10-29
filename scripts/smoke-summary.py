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
    replaced = list(selection.get("replaced_unit") or [])
    pinned_run = [t for t in (selection.get("curated_unit") or unit) if t not in replaced]
    lines = [
        "### Hosted CI selection",
        "",
        "PR and push runs build once and run the pinned smoke tests below",
        "(`scripts/smoke-suite.json`, capped at "
        f"{_count(selection.get('max_unit_tests'))} unit and "
        f"{_count(selection.get('max_ui_tests'))} UI tests). Every unit class (in balanced shards,",
        "`scripts/hosted-suite.json`), the timing families and the complete UI",
        "suite run in the nightly workflow.",
        "",
        f"- pinned unit tests run: **{len(pinned_run)}**"
        + (f" ({len(replaced)} more run in their whole changed class)" if replaced else "")
        + "; unit classes"
        f" this run reaches, whole or in part: {len({t.split('/')[0] for t in unit})}"
        f" of {_count(selection.get('inventory_unit'))}",
        f"- pinned UI tests: **{len(ui)}**, from {len({t.split('/')[0] for t in ui})} of "
        f"{_count(selection.get('inventory_ui'))} UI classes",
        f"- classes left to the nightly run: {_count(selection.get('delegated_unit'))} unit"
        f" + {_count(selection.get('delegated_ui'))} UI",
        "",
        "Unit: " + ", ".join(pinned_run),
        "",
        "Source contracts: " + ", ".join(selection.get("source_contracts") or []),
        "",
    ]
    if selection.get("changed_unit"):
        lines += ["Added for this change: " + ", ".join(selection["changed_unit"]), ""]
    if selection.get("changed_skipped"):
        lines += ["Related to this change but over the smoke budget (nightly only): "
                  + ", ".join(selection["changed_skipped"]), ""]
    lines += [
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
