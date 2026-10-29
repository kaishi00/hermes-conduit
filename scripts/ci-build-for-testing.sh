#!/usr/bin/env bash
#
# CI v2 build job: build the complete test products EXACTLY ONCE into a
# workspace-anchored DerivedData directory, so the generated .xctestrun and
# every referenced product path is identical on every runner of this repo
# (/Users/runner/work/<repo>/<repo>/...). The Build/ tree is uploaded as an
# artifact and downstream lanes run test-without-building from it.
#
# One retry only: an incremental build (from a restored cache) that fails with
# no error in a source file is retried once from scratch, since the cache
# itself could be the cause. Any other failure is deterministic. Budget:
# BUILD_TIMEOUT_SECS per attempt, so a retried build can take twice that.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ci-lib.sh"

PROJECT="Conduit.xcodeproj"
SCHEME="Conduit"
# Workspace-anchored by default: GITHUB_WORKSPACE is byte-identical across
# GitHub-hosted runners for the same repository, which is what makes the
# absolute paths inside the .xctestrun portable without rewriting anything.
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/ci-derived-data}"
# Read as base 10 with a 1200 fallback: the value goes straight into
# run_with_deadline's $(( )), where a non-numeric or leading-zero override
# would abort the build job.
BUILD_TIMEOUT_SECS=$(decimal_seconds "${BUILD_TIMEOUT_SECS:-}" 1200)
LOG_DIR="ci-lane/build"
mkdir -p "$LOG_DIR"

prep_start=$(date +%s)
if [ -n "${BUILD_DESTINATION:-}" ]; then
  # Hosted jobs (ci-hosted-build.sh) build for a generic simulator: the
  # products and .xctestrun are the same, but neither this script nor
  # xcodebuild has to reach CoreSimulator while the job's simulator boots.
  # With the device as destination, the lookup here took 4-64 s and
  # xcodebuild sat silent until 30-75 s after the boot ended (2026-10-15).
  DESTINATION="$BUILD_DESTINATION"
  echo "build-for-testing: destination $DESTINATION"
else
  SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
  build_destination

  # Destination readiness gate: absorb the fresh-runner CoreSimulator
  # settlement race before spending the build budget on a guaranteed
  # destination-resolution failure (observed as an empty available-destinations
  # list and "Unable to find a device matching the provided destination
  # specifier", which skips every downstream lane).
  if ! wait_for_destination_device; then
    build_status_token="failed"
    printf '{"schema_version": 1, "status": "%s", "duration_s": %d, "started_at": "%s", "finished_at": "%s", "xctestrun": "%s", "shared_artifact": true}\n' \
      "$build_status_token" 0 "$(now_iso)" "$(now_iso)" "" > "$LOG_DIR/build-result.json"
    echo "::error::destination device '$SIMULATOR_NAME' never became available; build-for-testing skipped"
    exit 1
  fi
fi
destination_s=$(( $(date +%s) - prep_start ))

# Build-time trims (2026-10-13: builds of 800-900 s were common and a third of
# a day's runs hit the budget). None of these change what the tests exercise:
# - COMPILER_INDEX_STORE_ENABLE=NO: no IDE index is written alongside every
#   compile (it was on: `-index-store-path` on each swift-frontend call).
# - -enableCodeCoverage NO: the scheme gathers coverage, which instruments
#   every Conduit file (`-profile-generate`); nothing in CI reads coverage.
# - ARCHS = the destination's arch (SIMULATOR_ARCH, arm64 by default, as in
#   build_destination): the embedded Watch app is a dependency on another
#   platform, so ONLY_ACTIVE_ARCH did not apply and it compiled for x86_64
#   too.
# Not whole-module: tried 2026-10-15 (#629), it made the 3-core hosted builds
# slower (full app 20.5 min against 11-16), since the app is one large module
# and whole-module type-checks it on one core.
# -showBuildTimingSummary prints where the time went; the slowest phases are
# echoed after the build and posted as a notice on the job.
#
# Incremental builds from a restored cache (2026-10-15): ci.yml restores the
# DerivedData of the newest build it can reach (main's, or its own branch's),
# so only what changed since recompiles.
# Xcode reuses a result only when its inputs' file info matches exactly, and a
# fresh runner gives every file a new inode and the checkout time. So the
# sources get content-derived timestamps (ci-normalize-mtimes.py), and XCBuild
# is told to ignore device and inode changes, the setting Apple suggests for
# CI caches. A failed incremental build with no error in a source file is
# retried once from scratch, in case the cache itself is the problem.
# Hosted runners only: on a developer Mac both would touch the checkout and
# the user's Xcode settings.
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  python3 "$SCRIPT_DIR/ci-normalize-mtimes.py" --repo-root . --generated "$PROJECT" \
    || echo "::warning::could not stamp the sources by content; this build will recompile everything"
  defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES
  export IgnoreFileSystemDeviceInodeChanges=1
fi
build_kind="clean"
if [ -d "$DERIVED_DATA_PATH/Build/Intermediates.noindex" ]; then
  build_kind="incremental"
fi
echo "build-for-testing: $build_kind build"

# With the WebRTC checkout in the restored DerivedData, -skipPackageUpdates
# resolves from it instead of the network. A new pinned version the checkout
# lacks fails the build, and the clean retry below resolves it from scratch.
# Whether this xcodebuild knows the flag is asked once: an xcodebuild launch
# took up to 30 s while the job's simulator booted (2026-10-15).
skip_flag_supported=no
case "$(xcodebuild -help 2>&1 || true)" in
  *-skipPackageUpdates*) skip_flag_supported=yes ;;
esac
skip_package_updates() {
  [ -d "$DERIVED_DATA_PATH/SourcePackages/checkouts" ] || return 0
  if [ "$skip_flag_supported" = "yes" ]; then echo "-skipPackageUpdates"; fi
}

# Resolve packages on their own first, timed, so a stall there shows apart
# from the build. The build's own resolution then finds everything in place.
resolve_packages() {
  local package_flag started
  package_flag=$(skip_package_updates)
  started=$(date +%s)
  echo "::group::resolve packages${package_flag:+ ($package_flag)}"
  run_with_deadline 600 "$LOG_DIR/resolve.log" \
    -resolvePackageDependencies \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ${package_flag:+"$package_flag"} \
    || echo "::warning::resolving packages on their own failed; the build resolves them itself"
  echo "::endgroup::"
  resolve_s=$(( $(date +%s) - started ))
  echo "build-for-testing: packages resolved in ${resolve_s}s"
}

run_build() {
  local package_flag
  package_flag=$(skip_package_updates)
  run_with_deadline "$BUILD_TIMEOUT_SECS" "$LOG_DIR/build.log" \
  build-for-testing \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ${package_flag:+"$package_flag"} \
  -enableCodeCoverage NO \
  -showBuildTimingSummary \
  COMPILER_INDEX_STORE_ENABLE=NO \
  ARCHS="${SIMULATOR_ARCH:-arm64}" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER=""
}

# ci-hosted-build.sh boots the job's simulator alongside this script and names
# the file its preparation writes when it ends (BUILD_AFTER). Package
# resolution and the build wait for it (2026-10-15, #629, 3-core 7 GB hosted
# runners): a build beside the first boot slowed the boot badly (2 of 3 missed
# their 200 s readiness budget, and the tests then waited 4-7 minutes for the
# device), and even a package resolution with no device involved sat at
# "Resolve Package Graph" until 43-73 s after the boot ended (2 of 3 jobs; 21 s
# in the third). No build started after the preparation had ended was held up.
boot_wait_s=""
if [ -n "${BUILD_AFTER:-}" ]; then
  boot_wait_budget="${BUILD_AFTER_TIMEOUT_S:-600}"
  case "$boot_wait_budget" in ''|*[!0-9]*) boot_wait_budget=600 ;; esac
  wait_start=$(date +%s)
  while [ ! -e "$BUILD_AFTER" ] && [ $(( $(date +%s) - wait_start )) -lt "$boot_wait_budget" ]; do
    sleep 2
  done
  boot_wait_s=$(( $(date +%s) - wait_start ))
  if [ -e "$BUILD_AFTER" ]; then
    echo "build-for-testing: waited ${boot_wait_s}s for the simulator to boot"
  else
    echo "::warning::the simulator was still being prepared after ${boot_wait_s}s; building alongside it"
  fi
fi

# Hosted jobs only: one xcodebuild call more on a developer Mac buys nothing.
resolve_s=""
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  XCODEBUILD_POLL_INTERVAL_S=2 resolve_packages
fi

# Where xcodebuild sits quietly (package resolution, build graph, waiting on
# the simulator service) never shows in the timing summary, which counts only
# tasks. A sampler records the log's length every 2 s; the longest stretches
# without a new line are posted with the line they followed. A clean retry
# starts a fresh timeline, so the notice describes the attempt whose build.log
# it quotes.
timeline="$LOG_DIR/build-timeline.txt"
sampler=""
start_sampler() {
  : > "$timeline"
  (
    t0=$(date +%s)
    while :; do
      lines=$( { wc -l < "$LOG_DIR/build.log"; } 2>/dev/null || echo 0)
      echo "$(( $(date +%s) - t0 )) ${lines// /}" >> "$timeline"
      sleep 2
    done
  ) &
  sampler=$!
}
stop_sampler() {
  if [ -n "$sampler" ]; then kill "$sampler" 2>/dev/null || true; fi
  sampler=""
}
trap stop_sampler EXIT
start_sampler

started_at=$(now_iso)
start=$(date +%s)
status=0
# Poll every 2 s instead of 15: an incremental build can be done in seconds.
XCODEBUILD_POLL_INTERVAL_S=2 run_build || status=$?
# The second grep reads all its input (no -q): stopping early could kill the
# first with SIGPIPE, which pipefail would read as "no source error".
if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$build_kind" = "incremental" ] \
  && ! grep -E ':[0-9]+:[0-9]+: error:' "$LOG_DIR/build.log" | grep -F "$PWD/" >/dev/null; then
  echo "::warning::the incremental build failed (exit $status) with no error in a source file; retrying from scratch"
  stop_sampler
  mv "$LOG_DIR/build.log" "$LOG_DIR/build-incremental.log"
  rm -rf "$DERIVED_DATA_PATH"
  build_kind="clean retry"
  status=0
  start_sampler
  XCODEBUILD_POLL_INTERVAL_S=2 run_build || status=$?
fi
stop_sampler
finished_at=$(now_iso)
duration=$(( $(date +%s) - start ))

xctestrun=""
if [ "$status" -eq 0 ]; then
  xctestrun="$(ls -t "$DERIVED_DATA_PATH"/Build/Products/*.xctestrun 2>/dev/null | head -n 1 || true)"
  if [ -z "$xctestrun" ]; then
    echo "::error::build-for-testing produced no .xctestrun under $DERIVED_DATA_PATH/Build/Products"
    status=1
  fi
fi

# build-result.json records this job's own build outcome (diagnostics only:
# the report job that consumed it was removed in CI v3). Values are script-controlled
# (status token, integer seconds, ISO stamps, one path) - safe to printf.
build_status_token="failed"
[ "$status" -eq 0 ] && build_status_token="ok"
printf '{"schema_version": 1, "status": "%s", "duration_s": %d, "started_at": "%s", "finished_at": "%s", "xctestrun": "%s", "shared_artifact": true}\n' \
  "$build_status_token" "$duration" "$started_at" "$finished_at" "$xctestrun" \
  > "$LOG_DIR/build-result.json"

if [ "$status" -ne 0 ]; then
  echo "::error::build-for-testing failed (exit $status); full log: $LOG_DIR/build.log"
  tail -n 100 "$LOG_DIR/build.log" || true
  exit 1
fi

echo "build-for-testing ok in ${duration}s ($build_kind)"
du -sh "$DERIVED_DATA_PATH"/* "$DERIVED_DATA_PATH"/Build/* 2>/dev/null || true
# The notice is readable from the job's annotations, where a long test log
# would bury the build step's output.
timing=$(sed -n '/Build Timing Summary/,$p' "$LOG_DIR/build.log" | grep -E '\| *[0-9.]+ seconds' \
  | sort -t'|' -k2 -rn | head -n 12 || true)
if [ -n "$timing" ]; then
  echo "::group::build timing summary"
  echo "$timing"
  echo "::endgroup::"
  dd_size=$(du -sh "$DERIVED_DATA_PATH" 2>/dev/null | cut -f1 || true)
  prep_note="before the build: destination ${destination_s}s"
  if [ -n "$boot_wait_s" ]; then prep_note="$prep_note, ${boot_wait_s}s waiting for the simulator"; fi
  if [ -n "$resolve_s" ]; then prep_note="$prep_note, then packages ${resolve_s}s"; fi
  echo "::notice title=Build ${duration}s ($build_kind build; DerivedData ${dd_size:-?}) - slowest phases::$(printf 'cache: %s\n%s\n%s\n' "${BUILD_CACHE:-not used}" "$prep_note" "$timing" | sed 's/%/%25/g' | awk '{printf "%s%s", (NR > 1 ? "%0A" : ""), $0}')"
else
  echo "::warning::no Build Timing Summary in $LOG_DIR/build.log"
fi
quiet=$(python3 "$SCRIPT_DIR/ci-build-quiet-stretches.py" "$timeline" "$LOG_DIR/build.log" 2>/dev/null || true)
if [ -n "$quiet" ]; then
  echo "::group::longest quiet stretches of the build"
  echo "$quiet"
  echo "::endgroup::"
  echo "::notice title=Build ${duration}s - longest stretches with no new output::$(printf '%s\n' "$quiet" | sed 's/%/%25/g' | awk '{printf "%s%s", (NR > 1 ? "%0A" : ""), $0}')"
fi
echo "xctestrun=$xctestrun"
exit 0
