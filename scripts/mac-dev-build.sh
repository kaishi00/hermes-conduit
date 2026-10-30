#!/usr/bin/env bash
# Builds Conduit Dev from this checkout and installs it on this Mac, with no
# TestFlight round trip. It runs as a "Designed for iPad" app beside the
# TestFlight Conduit (its own bundle id, com.milim.relay.dev), so a branch can
# be tried, profiled or sampled on the Mac right away.
#
# Why an .ipa: an app xcodebuild launches directly on a Mac is refused by
# Gatekeeper ("damaged"). A development .ipa opened with macOS's iOS App
# Installer installs to /Applications and launches normally.
#
# Usage: scripts/mac-dev-build.sh [--no-install]
#   --no-install  build the .ipa only (build/mac-dev/Conduit Dev.ipa)
#
# Conduit Dev keeps its own sign-in, settings and keychain: sign in to Hermes
# once in it. It has no widgets, share extension, notification service,
# CarPlay voice or location push (scripts/mac-dev/project.yml).
set -euo pipefail

install=1
for arg in "$@"; do
  case "$arg" in
    --no-install) install=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/mac-dev"
archive="$out/ConduitDev.xcarchive"
cd "$root"

command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)" >&2; exit 1; }

rm -rf "$archive" "$out/export"
mkdir -p "$out"

xcodegen generate --quiet --spec scripts/mac-dev/project.yml --project-root . --project .

echo "Archiving Conduit Dev (log: $out/archive.log)..."
if ! xcodebuild archive \
    -project ConduitDev.xcodeproj \
    -scheme Conduit \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    >"$out/archive.log" 2>&1; then
  grep -E 'error:|BUILD FAILED|ARCHIVE FAILED' "$out/archive.log" | tail -20 >&2
  echo "Archive failed; see $out/archive.log" >&2
  exit 1
fi

echo "Exporting the development .ipa (log: $out/export.log)..."
if ! xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist scripts/mac-dev/ExportOptions.plist \
    -exportPath "$out/export" \
    -allowProvisioningUpdates \
    >"$out/export.log" 2>&1; then
  grep -E 'error:|EXPORT FAILED' "$out/export.log" | tail -20 >&2
  echo "Export failed; see $out/export.log" >&2
  exit 1
fi

ipa="$(find "$out/export" -name '*.ipa' -maxdepth 1 | head -1)"
[ -n "$ipa" ] || { echo "No .ipa in $out/export" >&2; exit 1; }
echo "Built $ipa"

if [ "$install" = 1 ]; then
  # iOS App Installer replaces an installed Conduit Dev; quit it first so the
  # new build is what opens next.
  osascript -e 'tell application id "com.milim.relay.dev" to quit' >/dev/null 2>&1 || true
  open "$ipa"
  echo "iOS App Installer is installing Conduit Dev to /Applications."
fi
