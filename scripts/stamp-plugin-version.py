#!/usr/bin/env python3
"""Record the plugin version on notifier main in an archived Conduit.app.

Conduit asks the host to update the Conduit plugin only up to a stable
version by default, not every version on main (NotifierPluginNoticeChannel).
The archive is that stable version: whatever was on main when the build was
cut is what it was tested against on TestFlight. This writes it to the built
Info.plist as ConduitArchivedPluginVersion, so each build moves the
floor forward with nobody bumping it. `stable:` in the notifier's
channels.yaml can still raise it between builds (for an urgent plugin fix).

Only an archive (ACTION=install) is stamped; a Run or a CI build keeps the
fallback, NotifierPluginStatus.recommendedVersion. If GitHub can't be
reached the archive still succeeds, with an Xcode warning.

Usage (Xcode build phase, before code signing):
  stamp-plugin-version.py --info-plist "$TARGET_BUILD_DIR/$INFOPLIST_PATH"
"""

from __future__ import annotations

import argparse
import http.client
import os
import plistlib
import re
import subprocess
import sys
import urllib.request

PLUGIN_YAML_URL = (
    "https://raw.githubusercontent.com/kaishi00/hermes-conduit-notifier/main/plugin.yaml")
KEY = "ConduitArchivedPluginVersion"
# Leading spaces allowed, as NotifierPluginLatestVersion's parser does.
YAML_VERSION_RE = re.compile(r'^[ \t]*version:\s*["\']?([0-9]+(?:\.[0-9]+)*)["\']?\s*(?:#.*)?$', re.MULTILINE)
FETCH_ERRORS = (OSError, http.client.HTTPException, UnicodeDecodeError)


def plugin_version(plugin_yaml: str) -> str | None:
    match = YAML_VERSION_RE.search(plugin_yaml)
    return match.group(1) if match else None


def fetch_plugin_yaml(timeout: float = 15.0) -> str:
    # curl uses the Mac's own certificates; a python3 without them (a
    # python.org install) fails TLS through urllib.
    try:
        return subprocess.run(
            ["curl", "-fsSL", "--max-time", str(int(timeout)), PLUGIN_YAML_URL],
            check=True, capture_output=True, timeout=timeout + 5).stdout.decode("utf-8")
    except (OSError, subprocess.SubprocessError):
        pass
    with urllib.request.urlopen(PLUGIN_YAML_URL, timeout=timeout) as response:
        return response.read().decode("utf-8")


def stamp(info_plist_path: str, version: str) -> None:
    with open(info_plist_path, "rb") as handle:
        data = handle.read()
    info = plistlib.loads(data)
    info[KEY] = version
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist") else plistlib.FMT_XML
    with open(info_plist_path, "wb") as handle:
        plistlib.dump(info, handle, fmt=fmt)


def main(argv=None, environ=None, fetch=fetch_plugin_yaml) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--info-plist", required=True)
    args = parser.parse_args(argv)
    environ = os.environ if environ is None else environ
    if environ.get("ACTION") != "install":
        return 0
    try:
        version = plugin_version(fetch())
    except FETCH_ERRORS as exc:
        print(f"warning: Couldn't read the plugin version on notifier main ({exc}); "
              "this archive's App Store plugin notice falls back to recommendedVersion.")
        return 0
    if version is None:
        print("warning: notifier main's plugin.yaml has no readable version; "
              "this archive's App Store plugin notice falls back to recommendedVersion.")
        return 0
    stamp(args.info_plist, version)
    print(f"Stamped {KEY} = {version}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
