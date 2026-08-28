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
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/.ci-derived-data}"
BUILD_TIMEOUT_SECS="${BUILD_TIMEOUT_SECS:-900}"
LOG_DIR=".ci-lane/build"
mkdir -p "$LOG_DIR"

SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
build_destination

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

# build-result.json feeds the report job's summary. Values are script-controlled
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
echo "xctestrun=$xctestrun"
exit 0
