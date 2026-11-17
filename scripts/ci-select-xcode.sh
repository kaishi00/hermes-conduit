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
# older Xcode doesn't build for. So when the script falls back to an Xcode
# whose iOS simulator SDK is older than the first candidate with an SDK, it
# pins SIMULATOR_OS (and WATCH_SIMULATOR_OS, which the App Store
# screenshots' Watch job reads) to the selected Xcode's simulator SDK versions
# through GITHUB_ENV (the workflows keep that variable across sudo). A
# fallback to another copy of the same SDK pins nothing: an image carried
# both Xcode_27.3.app (no toolchain) and Xcode_27.3.0.app, and pinning iOS
# 27.3 there left Smoke without a device (#2627's first run).
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
candidates=$(printf '%s\n%s\n' "$candidates" "$apps/Xcode.app" | sed '/^$/d')

has_metal() { xcrun -sdk iphonesimulator metal -v >/dev/null 2>&1; }

sdk_is_older() {
  awk -v selected="$1" -v first="$2" 'BEGIN {
    n = split(selected, a, /[.]/); m = split(first, b, /[.]/)
    for (i = 1; i <= n || i <= m; i++) {
      if (a[i] + 0 < b[i] + 0) exit 0
      if (a[i] + 0 > b[i] + 0) exit 1
    }
    exit 1
  }'
}

while IFS= read -r target; do
  echo "selecting $target"
  xcode-select -s "$target"
  xcodebuild -version
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-version) || sdk=""
  if [ -z "$sdk" ]; then
    echo "::warning title=iOS simulator SDK unavailable::$target has no iphonesimulator SDK; trying the next one"
    continue
  fi
  newest_sdk="${newest_sdk:-$sdk}"
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
  if sdk_is_older "$sdk" "$newest_sdk"; then
    watch_sdk=$(xcrun --sdk watchsimulator --show-sdk-version) || watch_sdk=""
    if [ -z "$watch_sdk" ]; then
      echo "::warning title=Watch simulator SDK unavailable::$target has no watchsimulator SDK for the runtime pin; trying the next one"
      continue
    fi
    echo "::notice title=Simulator runtime pinned::fell back to $target; simulators run iOS $sdk and watchOS $watch_sdk, the runtimes its SDKs build for"
    if [ -n "${GITHUB_ENV:-}" ]; then
      printf 'SIMULATOR_OS=%s\nWATCH_SIMULATOR_OS=%s\n' "$sdk" "$watch_sdk" >> "$GITHUB_ENV"
    fi
  fi
  exit 0
done <<< "$candidates"

echo "::error::no usable Xcode on this image has the required simulator SDKs and a working Metal toolchain"
exit 1
