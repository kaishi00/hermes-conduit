#!/usr/bin/env bash
# The warm-simulator cache keys (ci-prepare-smoke.sh's SIM_SEED_DIR): seeds
# per runner image, Xcode build and pinned simulator, whatever the job builds.
# Each save is a generation (the run's id) and a restore takes the newest, so
# a seed a job couldn't use is replaced by the one it made instead.
set -euo pipefail
xcode=$(xcodebuild -version | awk 'NR==1 {v=$2} /Build version/ {b=$3} END {print v "-" b}')
base="sim-v2-$xcode-${ImageVersion:-image}-$(printf '%s' "${SIMULATOR_NAME:?}" | tr -c 'A-Za-z0-9.' '-')"
echo "warm simulator: $base"
{
  echo "prefix=$base-gen-"
  echo "key=$base-gen-${GITHUB_RUN_ID:-0}"
} >> "${GITHUB_OUTPUT:-/dev/null}"
