#!/usr/bin/env python3
"""Fail when Conduit's recommended plugin version is ahead of the plugin.

Conduit offers the one-tap plugin update whenever the host is below the
plugin on hermes-conduit-notifier's main branch, which it reads from GitHub
(NotifierPluginLatestVersion.swift). NotifierPluginStatus.recommendedVersion
is only the floor a build offers when GitHub can't be reached, so it may lag
main (the check notes it). Ahead of main fails: an update can't reach the
version Conduit asks for, so the notice would never go away. Merge the plugin
first, then raise the constant in Conduit when a build needs it.

If GitHub can't be reached the check warns and passes, so an outage doesn't
block every PR.
"""

import argparse
import http.client
import os
import re
import sys
import time
import urllib.request

PLUGIN_YAML_URL = (
    "https://raw.githubusercontent.com/kaishi00/hermes-conduit-notifier/main/plugin.yaml")
SWIFT_FILE = os.path.join("Conduit", "Services", "NotifierPluginStatus.swift")
# A failed or truncated download, as opposed to a plugin.yaml that says the wrong thing.
FETCH_ERRORS = (OSError, http.client.HTTPException, UnicodeDecodeError)

RECOMMENDED_RE = re.compile(r'static\s+let\s+recommendedVersion\s*=\s*"([^"]+)"')
YAML_VERSION_RE = re.compile(r'^version:\s*["\']?([^"\'\s#]+)', re.MULTILINE)


def recommended_version(swift_source):
    match = RECOMMENDED_RE.search(swift_source)
    return match.group(1) if match else None


def plugin_version(plugin_yaml):
    match = YAML_VERSION_RE.search(plugin_yaml)
    return match.group(1) if match else None


def parts(version):
    """Dotted numeric parts, or None when a part isn't a number."""
    core = version.split("-", 1)[0]
    try:
        return tuple(int(part) for part in core.split("."))
    except ValueError:
        return None


def compare(recommended, latest):
    """Returns None when they match, else the problem to report. Missing
    trailing parts count as zero ("0.41" matches "0.41.0"), as in Swift's
    NotifierPluginStatus.isOlder."""
    left, right = parts(recommended), parts(latest)
    if left is None or right is None:
        return f"Can't compare versions {recommended!r} and {latest!r}: not dotted numbers."
    width = max(len(left), len(right))
    left += (0,) * (width - len(left))
    right += (0,) * (width - len(right))
    if left == right:
        return None
    where = "behind" if left < right else "ahead of"
    return (
        f"NotifierPluginStatus.recommendedVersion is {recommended}, {where} the "
        f"plugin on hermes-conduit-notifier main ({latest}). Set it to "
        f'"{latest}" in {SWIFT_FILE} so hosts below it are offered the update.')


def fetch(url, attempts=3):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=15) as response:
                return response.read().decode("utf-8")
        except FETCH_ERRORS as error:
            if attempt == attempts - 1:
                raise
            print(f"fetch failed ({error}), retrying", file=sys.stderr)
            time.sleep(2 ** attempt)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--plugin-yaml",
                        help="read the plugin's plugin.yaml from this file instead of GitHub")
    args = parser.parse_args(argv)

    with open(os.path.join(args.repo_root, SWIFT_FILE), encoding="utf-8") as fh:
        recommended = recommended_version(fh.read())
    if not recommended:
        print(f"::error file={SWIFT_FILE}::No recommendedVersion found in {SWIFT_FILE}.")
        return 1

    if args.plugin_yaml:
        with open(args.plugin_yaml, encoding="utf-8") as fh:
            yaml_text = fh.read()
    else:
        try:
            yaml_text = fetch(PLUGIN_YAML_URL)
        except FETCH_ERRORS as error:
            print(f"::warning::Couldn't read the plugin version from GitHub ({error}); "
                  "recommendedVersion not checked.")
            return 0

    latest = plugin_version(yaml_text)
    if not latest:
        print("::error::No version: line in hermes-conduit-notifier's plugin.yaml.")
        return 1

    problem = compare(recommended, latest)
    if problem and parts(recommended) is not None and parts(latest) is not None:
        behind = parts(recommended) + (0,) * 8 < parts(latest) + (0,) * 8
    else:
        behind = False
    if problem and behind:
        # Conduit offers main's version itself; the floor may lag.
        print(f"::notice file={SWIFT_FILE}::{problem}")
        return 0
    if problem:
        print(f"::error file={SWIFT_FILE}::{problem}")
        return 1
    print(f"recommendedVersion {recommended} matches the plugin on main.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
