#!/usr/bin/env python3
"""Fail when Conduit's copy of the rich card schema differs from the plugin's.

Rich cards (maps and places) are defined once, in hermes-conduit-notifier's
cards/card-schema.json; its card-vectors.json holds the examples both test
suites run. Conduit ships byte-identical copies (Conduit/Cards/card-schema.json
for the app, ConduitTests/Fixtures/card-vectors.json for RichCardSchemaTests),
so the live models' show_on_screen and the chat's cards check exactly what
the plugin checks. This compares them with hermes-conduit-notifier main and
fails until they match: change the plugin first, merge it, then copy both
files here.

A file missing on main fails too. If GitHub can't be reached at all the check
warns and passes, so an outage doesn't block every PR.
"""

import argparse
import http.client
import os
import sys
import time
import urllib.error
import urllib.request

PLUGIN_RAW = "https://raw.githubusercontent.com/kaishi00/hermes-conduit-notifier/main/"
# Conduit's copy -> the plugin's file.
COPIES = {
    os.path.join("Conduit", "Cards", "card-schema.json"): "cards/card-schema.json",
    os.path.join("ConduitTests", "Fixtures", "card-vectors.json"): "cards/card-vectors.json",
}
UNREACHABLE = (OSError, http.client.HTTPException)


class Missing(Exception):
    """The file isn't on the plugin's main."""


def fetch(url, attempts=3):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                raise Missing(url) from error
            if attempt == attempts - 1:
                raise
        except UNREACHABLE as error:
            if attempt == attempts - 1:
                raise
            print(f"fetch failed ({error}), retrying", file=sys.stderr)
        time.sleep(2 ** attempt)


def compare(local, plugin, name):
    """None when they match, else the problem to report."""
    if local == plugin:
        return None
    return (f"{name} differs from hermes-conduit-notifier main ({COPIES[name]}). Copy the plugin's file "
            "byte for byte; change the schema in the plugin first.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--plugin-root", help="read the plugin's files from this checkout instead of GitHub")
    args = parser.parse_args(argv)

    failed = False
    for name, plugin_path in COPIES.items():
        with open(os.path.join(args.repo_root, name), "rb") as fh:
            local = fh.read()
        try:
            if args.plugin_root:
                with open(os.path.join(args.plugin_root, plugin_path), "rb") as fh:
                    plugin = fh.read()
            else:
                plugin = fetch(PLUGIN_RAW + plugin_path)
        except (Missing, FileNotFoundError):
            print(f"::error file={name}::{plugin_path} isn't on hermes-conduit-notifier main yet; "
                  "merge the plugin's change first.")
            failed = True
            continue
        except UNREACHABLE as error:
            print(f"::warning::Couldn't read {plugin_path} from GitHub ({error}); {name} not checked.")
            continue
        problem = compare(local, plugin, name)
        if problem:
            print(f"::error file={name}::{problem}")
            failed = True
        else:
            print(f"{name} matches the plugin on main.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
