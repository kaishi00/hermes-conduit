#!/usr/bin/env bash
#
# CI v2 build job: build the complete test products EXACTLY ONCE into a
# workspace-anchored DerivedData directory, so the generated .xctestrun and
# every referenced product path is identical on every runner of this repo
# (/Users/runner/work/<repo>/<repo>/...). The Build/ tree is uploaded as an
# artifact and downstream lanes run test-without-building from it.
#
# No retry: build failures are deterministic; a simulator reset cannot fix
# them. Budget: BUILD_TIMEOUT_SECS.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ci-lib.sh"

PROJECT="Conduit.xcodeproj"
SCHEME="Conduit"
# Workspace-anchored by default: GITHUB_WORKSPACE is byte-identical across
# GitHub-hosted runners for the same repository, which is what makes the
# absolute paths inside the .xctestrun portable without rewriting anything.
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/ci-derived-data}"
BUILD_TIMEOUT_SECS="${BUILD_TIMEOUT_SECS:-1200}"
LOG_DIR="ci-lane/build"
mkdir -p "$LOG_DIR"

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
# newest main build's DerivedData, so only what changed since recompiles.
# Xcode reuses a result only when its inputs' file info matches exactly, and a
# fresh runner gives every file a new inode and the checkout time. So the
# sources get content-derived timestamps (ci-normalize-mtimes.py), and XCBuild
# is told to ignore device and inode changes, the setting Apple suggests for
# CI caches. A failed incremental build with no error in a source file is
# retried once from scratch, in case the cache itself is the problem.
# Hosted runners only: on a developer Mac both would touch the checkout and
# the user's Xcode settings.
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  python3 "$SCRIPT_DIR/ci-normalize-mtimes.py" --repo-root . --generated "$PROJECT"
  defaults write com.apple.dt.XCBuild IgnoreFileSystemDeviceInodeChanges -bool YES
  export IgnoreFileSystemDeviceInodeChanges=1
fi
build_kind="clean"
if [ -d "$DERIVED_DATA_PATH/Build/Intermediates.noindex" ]; then
  build_kind="incremental"
fi
echo "build-for-testing: $build_kind build"

run_build() {
  run_with_deadline "$BUILD_TIMEOUT_SECS" "$LOG_DIR/build.log" \
  build-for-testing \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
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

started_at=$(now_iso)
start=$(date +%s)
status=0
run_build || status=$?
if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$build_kind" = "incremental" ] \
  && ! grep -qE "^$PWD/[^:]+:[0-9]+:[0-9]+: error:" "$LOG_DIR/build.log"; then
  echo "::warning::the incremental build failed (exit $status) with no error in a source file; retrying from scratch"
  mv "$LOG_DIR/build.log" "$LOG_DIR/build-incremental.log"
  rm -rf "$DERIVED_DATA_PATH"
  build_kind="clean retry"
  status=0
  run_build || status=$?
fi
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
  echo "::notice title=Build ${duration}s ($build_kind build; DerivedData ${dd_size:-?}) - slowest phases::$(printf '%s\n' "$timing" | sed 's/%/%25/g' | awk '{printf "%s%s", (NR > 1 ? "%0A" : ""), $0}')"
else
  echo "::warning::no Build Timing Summary in $LOG_DIR/build.log"
fi
echo "xctestrun=$xctestrun"
exit 0
