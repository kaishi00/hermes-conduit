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
#   --no-install  build the .ipa only (build/mac-dev/export/Conduit Dev.ipa)
#
# Conduit Dev keeps its own sign-in, settings and keychain: sign in to Hermes
# once in it. It has no widgets, share extension, notification service,
# push notifications, CarPlay voice or location push, and conduit:// links
# keep opening the TestFlight Conduit (scripts/mac-dev/project.yml).
set -euo pipefail

install=1
for arg in "$@"; do
  case "$arg" in
    --no-install) install=0 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
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

# iOS App Installer skips an .ipa whose build number is already installed,
# so each build numbers itself by the minute it was made.
build_number="$(date +%Y%m%d%H%M)"

echo "Archiving Conduit Dev $build_number (log: $out/archive.log)..."
if ! xcodebuild archive \
    -project ConduitDev.xcodeproj \
    -scheme Conduit \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    CURRENT_PROJECT_VERSION="$build_number" \
    >"$out/archive.log" 2>&1; then
  grep -E 'error:|BUILD FAILED|ARCHIVE FAILED' "$out/archive.log" | tail -20 >&2 || true
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
  grep -E 'error:|EXPORT FAILED' "$out/export.log" | tail -20 >&2 || true
  echo "Export failed; see $out/export.log" >&2
  exit 1
fi

ipa="$(find "$out/export" -maxdepth 1 -name '*.ipa' | head -1)"
[ -n "$ipa" ] || { echo "No .ipa in $out/export" >&2; exit 1; }
echo "Built $ipa"

if [ "$install" = 1 ]; then
  if pgrep -f "Wrapper/Conduit Dev.app/Conduit Dev" >/dev/null; then
    osascript -e 'tell application id "com.milim.relay.dev" to quit' >/dev/null 2>&1 \
      || echo "warning: couldn't quit Conduit Dev; quit it before opening the new build" >&2
  fi
  # iOS App Installer never replaces an installed copy: it adds
  # "Conduit Dev 2.app" beside it. The installed app is owned by root, so
  # Finder moves the old copies to the Trash (it asks for an admin password).
  old=()
  for app in /Applications/*.app; do
    id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app"/Wrapper/*.app/Info.plist 2>/dev/null || true)"
    if [ "$id" = com.milim.relay.dev ]; then old+=("$app"); fi
  done
  if [ "${#old[@]}" -gt 0 ]; then
    echo "Moving the installed Conduit Dev to the Trash (Finder may ask for your password)..."
    for app in "${old[@]}"; do
      if ! osascript -e "tell application \"Finder\" to delete (POSIX file \"$app\" as alias)" >/dev/null 2>&1; then
        echo "Couldn't move $app to the Trash (password prompt cancelled?)." >&2
        echo "Remove it yourself, then open: $ipa" >&2
        exit 1
      fi
    done
  fi
  open "$ipa"
  echo "iOS App Installer is installing Conduit Dev to /Applications."
fi
