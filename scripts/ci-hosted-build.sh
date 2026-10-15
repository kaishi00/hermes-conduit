#!/usr/bin/env bash
# CI v4: boot the pinned simulator in the background and build the test
# products on THIS runner. The build script resolves packages and builds only
# once the preparation has ended (BUILD_AFTER): on the 3-core hosted runners a
# build beside the first boot slowed it, and xcodebuild stalled until after it
# (#629).
# Exports XCRUN_FILE, DESTINATION and SIMULATOR_UDID for the later steps
# through $GITHUB_ENV.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p ci-lane
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/ci-derived-data}"
export DERIVED_DATA_PATH

# The build targets a generic simulator and needs no device. With the pinned
# device as its destination, the lookups took 4-64 s and xcodebuild then sat
# silent until 30-75 s after the boot ended (#629). The tests still run on the
# booted device (DESTINATION, from the preparation).
export BUILD_DESTINATION="${BUILD_DESTINATION:-generic/platform=iOS Simulator}"
export BUILD_AFTER="$PWD/ci-lane/prepare.end"

step_start=$(date +%s)
rm -f ci-lane/prepare.end
( rc=0
  bash "$SCRIPT_DIR/ci-prepare-smoke.sh" || rc=$?
  date +%s > ci-lane/prepare.end
  exit "$rc" ) > ci-lane/prepare.log 2>&1 &
prepare_pid=$!

build_rc=0
bash "$SCRIPT_DIR/ci-build-for-testing.sh" || build_rc=$?
build_s=$(( $(date +%s) - step_start ))

prepare_rc=0
wait "$prepare_pid" || prepare_rc=$?
echo "::group::simulator preparation"
cat ci-lane/prepare.log || true
echo "::endgroup::"
# Both times count from the start of the step. A failed side says so here
# too, so the notice never reads as a healthy run.
if prepare_end=$(cat ci-lane/prepare.end 2>/dev/null) && [ -n "$prepare_end" ]; then
  outcome=""
  if [ "$build_rc" -ne 0 ]; then outcome="$outcome; the build failed (exit $build_rc)"; fi
  if [ "$prepare_rc" -ne 0 ]; then outcome="$outcome; simulator preparation failed (exit $prepare_rc)"; fi
  echo "::notice title=Simulator ready after $(( prepare_end - step_start ))s - build done after ${build_s}s::the step took $(( $(date +%s) - step_start ))s$outcome"
fi

if [ "$build_rc" -ne 0 ]; then
  echo "::error::build-for-testing failed (exit $build_rc)"
  exit "$build_rc"
fi
if [ "$prepare_rc" -ne 0 ]; then
  echo "::error::simulator preparation failed (exit $prepare_rc)"
  exit "$prepare_rc"
fi

xctestrun=$(ls -t "$DERIVED_DATA_PATH"/Build/Products/*.xctestrun 2>/dev/null | head -n 1 || true)
if [ -z "$xctestrun" ]; then
  echo "::error::no .xctestrun under $DERIVED_DATA_PATH/Build/Products"
  exit 1
fi
printf 'XCRUN_FILE=%s\n' "$xctestrun" >> "${GITHUB_ENV:-/dev/null}"
