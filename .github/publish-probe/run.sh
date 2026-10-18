#!/usr/bin/env bash
# PROBE ONLY (removed before merge). `run.sh tests` runs the suites this
# change touches; `run.sh probe` measures publishes under a covered list.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
probe=TranscriptPerformanceFixtureTests/testPublishProbeReportsCoveredListCost

run_probe() {
  local name=$1
  shift
  env "$@" xcodebuild test-without-building \
    -xctestrun "$XCRUN_FILE" \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:"ConduitTests/$probe" \
    > "probe-$name.log" 2>&1 || echo "probe $name exited $?"
}

case "${1:-probe}" in
tests)
  xcodebuild test-without-building \
    -xctestrun "$XCRUN_FILE" \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:ConduitTests/SettledMessageIsolationTests \
    -only-testing:ConduitTests/ChatScrollHostedTests \
    -only-testing:ConduitTests/ClarifyHistoryRecordTests \
    -only-testing:ConduitTests/ChatTypographyTests \
    -only-testing:ConduitTests/ComposerDraftStoreTests \
    -only-testing:ConduitTests/ComposerFullEditorTests \
    -only-testing:ConduitTests/ComposerReturnKeyTests \
    > tests.log 2>&1 || echo "tests exited $?"
  { grep -E "^Test Suite .*(passed|failed)|Executed [0-9]+ test" tests.log | tail -n 12
    grep -E ": error: |^Test Case .* failed" tests.log | sed -e "s|$PWD/||g" | head -n 80
  } > tests-summary.txt
  cat tests-summary.txt
  python3 "$HERE/annotate.py" tests-summary.txt tests
  ;;
probe)
  # Interleaved: the first process in a job runs slower.
  run_probe warm TEST_RUNNER_PROBE_CONFIG=nolist
  run_probe nolist-1 TEST_RUNNER_PROBE_CONFIG=nolist
  run_probe nocomposer-1 TEST_RUNNER_PROBE_CONFIG=nocomposer
  run_probe nolist-2 TEST_RUNNER_PROBE_CONFIG=nolist
  run_probe nocomposer-2 TEST_RUNNER_PROBE_CONFIG=nocomposer
  for name in nolist-1 nocomposer-1 nolist-2 nocomposer-2; do
    echo "===== $name"
    grep -E "PUBLISH_PROBE|SCROLL_PROBE stacks|^Test Case .*(passed|failed)" "probe-$name.log" || tail -n 30 "probe-$name.log"
    awk '/: error: /{p=1} p{print; n++} n>=30{exit}' "probe-$name.log"
  done > probe-summary.txt
  cat probe-summary.txt
  python3 "$HERE/annotate.py" probe-summary.txt probe
  ;;
esac
