#!/usr/bin/env bash
# Select the newest released Xcode on a hosted runner image (run with sudo).
#
# The xcode-27 image's default Xcode.app can lag the newest release it ships:
# on 2026-11-12 it was 27.1 while the image carried Xcode 27.2 and the iOS
# 27.2 simulator runtime, and the smoke job's device lookup (newest runtime
# wins, scripts/ci-lib.sh) put the iPhone 18 Pro on iOS 27.2, a runtime 27.1
# doesn't build for. The newest release also matches what TestFlight builds
# are made with. Only plain version names count (Xcode_27.2.app), never a
# beta or release candidate (Xcode_27.3_beta.app); with none, the image's
# default Xcode.app stays.
#
# APPLICATIONS_DIR is for the regression test only.
set -euo pipefail

apps="${APPLICATIONS_DIR:-/Applications}"
newest=$(find "$apps" -maxdepth 1 -name 'Xcode_*.app' 2>/dev/null \
  | sed 's#.*/##' \
  | grep -E '^Xcode_[0-9]+(\.[0-9]+)*\.app$' \
  | sed -E 's/^Xcode_(.*)\.app$/\1/' \
  | sort -t. -k1,1n -k2,2n -k3,3n \
  | tail -n 1 || true)

if [ -n "$newest" ]; then
  target="$apps/Xcode_$newest.app"
else
  target="$apps/Xcode.app"
  echo "::warning::no released Xcode_<version>.app under $apps; keeping the default Xcode.app"
fi

echo "selecting $target"
if [ -z "${APPLICATIONS_DIR:-}" ]; then
  xcode-select -s "$target"
  xcodebuild -version
fi
