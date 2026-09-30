#!/usr/bin/env bash
# CI v4: build the test products on THIS runner while the pinned simulator
# boots in the background, so device boot (~2.5 min on hosted macos-26) is
# hidden behind the ~3 min build instead of adding to it. Exports XCRUN_FILE,
# DESTINATION and SIMULATOR_UDID for the later steps through $GITHUB_ENV.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p ci-lane
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$PWD/ci-derived-data}"
export DERIVED_DATA_PATH

bash "$SCRIPT_DIR/ci-prepare-smoke.sh" > ci-lane/prepare.log 2>&1 &
prepare_pid=$!

build_rc=0
bash "$SCRIPT_DIR/ci-build-for-testing.sh" || build_rc=$?

prepare_rc=0
wait "$prepare_pid" || prepare_rc=$?
echo "::group::simulator preparation (ran during the build)"
cat ci-lane/prepare.log || true
echo "::endgroup::"

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
