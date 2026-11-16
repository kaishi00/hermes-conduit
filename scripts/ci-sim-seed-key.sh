#!/usr/bin/env bash
# The warm-simulator cache key (ci-prepare-smoke.sh's SIM_SEED_DIR): one seed
# per runner image, Xcode build and pinned simulator, whatever the job builds.
set -euo pipefail
xcode=$(xcodebuild -version | awk 'NR==1 {v=$2} /Build version/ {b=$3} END {print v "-" b}')
key="sim-v1-$xcode-${ImageVersion:-image}-$(printf '%s' "${SIMULATOR_NAME:?}" | tr -c 'A-Za-z0-9.' '-')"
echo "warm simulator: $key"
echo "key=$key" >> "${GITHUB_OUTPUT:-/dev/null}"
