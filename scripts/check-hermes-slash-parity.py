#!/usr/bin/env python3
"""Does Conduit still handle Hermes' slash commands the way Hermes expects?

Hermes' `slash.exec` refuses about half its commands for a chat like
Conduit's (`unsupported_command`); its clients run those themselves or
leave them out. Hermes publishes which ones in its gateway command parity
table (website/docs/developer-guide/gateway-command-parity.md, generated
from its registry). Conduit keeps two lists against it in AppState.swift:
the commands it runs itself (`executeSlashCommand`'s cases) and the ones it
hides (`slashCommandsWithoutConduitRoute`). This script compares them, plus
the argument words Conduit sends for /fast, /reasoning and /approvals, with
a Hermes checkout:

    python3 scripts/check-hermes-slash-parity.py --hermes-root ../hermes-agent

Exit 0 when they agree; exit 1 with a Markdown list of what drifted (the
weekly workflow, .github/workflows/hermes-parity.yml, files it as an
issue); exit 2 when a file can't be read or parsed.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PARITY_DOC = "website/docs/developer-guide/gateway-command-parity.md"
COMMANDS_PY = "hermes_cli/commands.py"
APP_STATE = "Conduit/Services/AppState.swift"
MODEL_PICKER = "Conduit/Views/ModelPickerView.swift"
SETTINGS_VIEWS = "Conduit/Views/AuxiliaryViews.swift"

# Hermes argument words Conduit leaves out on purpose. A new Hermes word
# that isn't here is reported, so Conduit decides about it once.
ACKNOWLEDGED_WORDS = {
    # auto/cold are Hermes' adaptive tiers, ultra an alias of ultrafast.
    "fast": {"auto", "cold", "ultra", "status", "on", "off", "--global"},
    # Display toggles for terminals, not effort levels.
    "reasoning": {"show", "hide", "on", "off", "full", "clamp", "--global"},
    "approvals": set(),
}


class ParseError(Exception):
    pass


def parse_parity_table(text: str) -> dict[str, tuple[set[str], str]]:
    """Canonical command -> (its name and aliases, the slash.exec column)."""
    rows: dict[str, tuple[set[str], str]] = {}
    pattern = re.compile(r"^\| `/([^`]+)`(?: \(([^)]*)\))? \| ([^|]+) \|", re.MULTILINE)
    for match in pattern.finditer(text):
        name = match.group(1).strip().lower()
        aliases = {a.strip().lstrip("/").lower() for a in (match.group(2) or "").split(",") if a.strip()}
        rows[name] = ({name} | aliases, match.group(3).strip())
    if not rows:
        raise ParseError(f"no command rows in {PARITY_DOC}")
    return rows


def parse_registry_subcommands(text: str) -> dict[str, list[str]]:
    """Command name -> its `subcommands=(...)` words in Hermes' registry."""
    subs: dict[str, list[str]] = {}
    for chunk in text.split("CommandDef(")[1:]:
        name = re.match(r'\s*"([^"]+)"', chunk)
        words = re.search(r"(?<![\w])subcommands=\(([^)]*)\)", chunk)
        if name and words:
            subs[name.group(1)] = re.findall(r'"([^"]*)"', words.group(1))
    if not subs:
        raise ParseError(f"no subcommands in {COMMANDS_PY}")
    return subs


def parse_swift_string_set(text: str, name: str) -> set[str]:
    match = re.search(rf"static let {re.escape(name)}: Set<String> = \[(.*?)\]", text, re.DOTALL)
    if not match:
        raise ParseError(f"{name} not found in {APP_STATE}")
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def parse_native_routes(text: str) -> set[str]:
    """The command names `executeSlashCommand` handles before slash.exec."""
    start = text.find("// Client-side special cases")
    end = text.find("\n        default:", start)
    if start < 0 or end < 0:
        raise ParseError(f"executeSlashCommand's local cases not found in {APP_STATE}")
    names: set[str] = set()
    for case in re.findall(r"^\s+case ((?:\"[^\"]+\",?\s*)+):", text[start:end], re.MULTILINE):
        names.update(re.findall(r'"([^"]+)"', case))
    return names


def parse_swift_enum_raw_values(text: str, enum: str) -> set[str]:
    match = re.search(rf"enum {re.escape(enum)}: String[^{{]*\{{(.*?)\n\n", text, re.DOTALL)
    if not match:
        raise ParseError(f"enum {enum} not found")
    values: set[str] = set()
    for line in match.group(1).splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for item in line[len("case "):].split(","):
            item = item.strip()
            raw = re.search(r'=\s*"([^"]*)"', item)
            values.add(raw.group(1) if raw else item)
    return values


def parse_approval_modes(text: str) -> set[str]:
    match = re.search(r'"approvals\.mode": \[(.*?)\]', text)
    if not match:
        raise ParseError(f"approvals.mode titles not found in {SETTINGS_VIEWS}")
    return set(re.findall(r'"([\w-]+)":', match.group(1)))


def find_drift(
    parity: dict[str, tuple[set[str], str]],
    registry_subs: dict[str, list[str]],
    hidden: set[str],
    native: set[str],
    conduit_words: dict[str, set[str]],
) -> list[str]:
    problems: list[str] = []
    verdict_of = {name: verdict for names, verdict in parity.values() for name in names}

    for canonical, (names, verdict) in sorted(parity.items()):
        if verdict != "refused" or names & native:
            continue
        missing = sorted(names - hidden)
        if missing:
            problems.append(
                f"Hermes refuses `/{canonical}` for Conduit chats, and Conduit neither runs nor hides "
                f"{', '.join('`/' + n + '`' for n in missing)}: add them to "
                "`slashCommandsWithoutConduitRoute` or give the command a route."
            )
    for name in sorted(hidden):
        verdict = verdict_of.get(name)
        if verdict is None:
            problems.append(f"`/{name}` is no longer a Hermes command: drop it from `slashCommandsWithoutConduitRoute`.")
        elif verdict != "refused":
            problems.append(
                f"Hermes now runs `/{name}` through slash.exec ({verdict}): take it out of "
                "`slashCommandsWithoutConduitRoute`."
            )
    for name in sorted(hidden & native):
        problems.append(f"`/{name}` is both hidden and run by Conduit: keep one.")

    for command, words in sorted(conduit_words.items()):
        hermes = set(registry_subs.get(command, []))
        if not hermes:
            problems.append(f"Hermes' `/{command}` lists no subcommands any more; Conduit sends {sorted(words)}.")
            continue
        for word in sorted(words - hermes):
            problems.append(f"Conduit sends `/{command} {word}`, which Hermes no longer offers.")
        for word in sorted(hermes - words - ACKNOWLEDGED_WORDS.get(command, set())):
            problems.append(
                f"Hermes offers `/{command} {word}`, which Conduit doesn't: offer it, or list it in "
                "ACKNOWLEDGED_WORDS in scripts/check-hermes-slash-parity.py."
            )
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--hermes-root", required=True, type=Path)
    parser.add_argument("--repo-root", default=Path(__file__).resolve().parent.parent, type=Path)
    parser.add_argument("--report", type=Path, help="write the Markdown report here too")
    args = parser.parse_args(argv)

    try:
        parity = parse_parity_table((args.hermes_root / PARITY_DOC).read_text())
        registry_subs = parse_registry_subcommands((args.hermes_root / COMMANDS_PY).read_text())
        app_state = (args.repo_root / APP_STATE).read_text()
        picker = (args.repo_root / MODEL_PICKER).read_text()
        hidden = parse_swift_string_set(app_state, "slashCommandsWithoutConduitRoute")
        native = parse_native_routes(app_state)
        conduit_words = {
            "fast": parse_swift_enum_raw_values(picker, "ModelSpeed"),
            "reasoning": parse_swift_enum_raw_values(picker, "ReasoningEffortLevel"),
            "approvals": parse_approval_modes((args.repo_root / SETTINGS_VIEWS).read_text()),
        }
    except (OSError, ParseError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 2

    problems = find_drift(parity, registry_subs, hidden, native, conduit_words)
    if not problems:
        print(f"OK: {len(parity)} Hermes commands, {len(native)} run by Conduit, {len(hidden)} hidden; words match.")
        return 0
    report = "\n".join(
        ["Conduit's slash-command handling has drifted from Hermes main:", ""]
        + [f"- {p}" for p in problems]
        + ["", f"Source: Hermes `{PARITY_DOC}` and `{COMMANDS_PY}`."]
    )
    print(report)
    if args.report:
        try:
            args.report.write_text(report + "\n")
        except OSError as error:
            print(f"::error::{error}", file=sys.stderr)
            return 2
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # an unexpected failure is not drift (exit 1)
        import traceback
        traceback.print_exc()
        sys.exit(2)
