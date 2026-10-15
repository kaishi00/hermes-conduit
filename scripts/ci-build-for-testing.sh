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
# - SWIFT_COMPILATION_MODE=wholemodule (2026-10-15): Debug compiles each Swift
#   module in incremental batches, which re-parses and type-checks the shared
#   declarations once per batch. CI always builds from scratch, where
#   compiling each module as one unit does that work once.
# -showBuildTimingSummary prints where the time went, echoed after the build.
started_at=$(now_iso)
start=$(date +%s)
status=0
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
  SWIFT_COMPILATION_MODE=wholemodule \
  ARCHS="${SIMULATOR_ARCH:-arm64}" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" || status=$?
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

echo "build-for-testing ok in "${duration}"s"
echo "::group::build timing summary"
sed -n '/Build Timing Summary/,$p' "$LOG_DIR/build.log" | head -n 40 || true
echo "::endgroup::"
echo "xctestrun=$xctestrun"
exit 0