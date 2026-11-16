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
# Xcode 26 and later ship the Metal toolchain as a separate component, and an
# image can carry an Xcode without it: image 20261112.0361.1's Xcode 27.3
# (27C5020n) failed every build at CompileMetalFile ("missing Metal
# Toolchain", 2026-11-16). The app compiles a .metal file, so when the
# selected Xcode can't run metal the script downloads it. Apple's catalog
# doesn't always carry that build's toolchain ("Failed fetching catalog for
# assetType", the 2026-11-16 Nightly), so when the download fails the next
# newest release is tried, then the image's default Xcode.app, and the job
# fails only when none has a toolchain.
#
# An image that carries a newer Xcode usually carries its iOS runtime too, and
# the device lookup (scripts/ci-lib.sh) takes the newest runtime, which an
# older Xcode doesn't build for. So when the script falls back past the newest
# release it pins SIMULATOR_OS (and WATCH_SIMULATOR_OS, which the App Store
# screenshots' Watch job reads) to the selected Xcode's simulator SDK versions
# through GITHUB_ENV (the workflows keep that variable across sudo).
#
# APPLICATIONS_DIR is for the regression test only; it puts stub
# xcode-select, xcodebuild and xcrun first on PATH.
set -euo pipefail

apps="${APPLICATIONS_DIR:-/Applications}"
candidates=$(find "$apps" -maxdepth 1 -name 'Xcode_*.app' 2>/dev/null \
  | sed 's#.*/##' \
  | grep -E '^Xcode_[0-9]+(\.[0-9]+)*\.app$' \
  | sed -E 's/^Xcode_(.*)\.app$/\1/' \
  | sort -t. -k1,1nr -k2,2nr -k3,3nr \
  | sed -E "s#^(.*)\$#$apps/Xcode_\\1.app#" || true)

if [ -z "$candidates" ]; then
  echo "::warning::no released Xcode_<version>.app under $apps; keeping the default Xcode.app"
fi
newest=$(printf '%s\n' "$candidates" | head -n 1)
candidates=$(printf '%s\n%s\n' "$candidates" "$apps/Xcode.app" | sed '/^$/d')

has_metal() { xcrun -sdk iphonesimulator metal -v >/dev/null 2>&1; }

while IFS= read -r target; do
  echo "selecting $target"
  xcode-select -s "$target"
  xcodebuild -version
  if ! has_metal; then
    echo "the Metal toolchain is missing - downloading it"
    started=$(date +%s)
    if xcodebuild -downloadComponent MetalToolchain && has_metal; then
      echo "::notice title=Metal toolchain downloaded::$(xcodebuild -version | head -n 1) lacked it; fetching took $(( $(date +%s) - started ))s"
    else
      echo "::warning title=Metal toolchain unavailable::$target has no Metal toolchain and couldn't get one (the download failed or left metal missing); trying the next one"
      continue
    fi
  fi
  if [ -n "$newest" ] && [ "$target" != "$newest" ]; then
    sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
    watch_sdk=$(xcrun --sdk watchsimulator --show-sdk-version)
    echo "::notice title=Simulator runtime pinned::fell back to $target; simulators run iOS $sdk and watchOS $watch_sdk, the runtimes its SDKs build for"
    if [ -n "${GITHUB_ENV:-}" ]; then
      printf 'SIMULATOR_OS=%s\nWATCH_SIMULATOR_OS=%s\n' "$sdk" "$watch_sdk" >> "$GITHUB_ENV"
    fi
  fi
  exit 0
done <<< "$candidates"

echo "::error::no Xcode on this image has a Metal toolchain, and none could download one"
exit 1
