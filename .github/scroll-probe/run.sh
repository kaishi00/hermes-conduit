#!/usr/bin/env bash
# Temporary scroll-probe runner. `run.sh tests` runs the suites the drawn
# text touches; `run.sh frames` runs the frame test, drawn text against text
# views; `run.sh stacks` runs it again with a stack sampler and prints where
# the slowest frames' main-thread time went.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
frames=TranscriptPerformanceFixtureTests/testScrollProbeReportsWorkPerFrame

run_probe() {
  local name=$1 filter=$2
  shift 2
  env "$@" xcodebuild test-without-building \
    -xctestrun "$XCRUN_FILE" \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:"ConduitTests/$filter" \
    > "probe-$name.log" 2>&1 || echo "probe $name exited $?"
}

summarise() {
  local name=$1
  echo "===== $name"
  grep -E "SCROLL_PROBE|^Test Case .*(passed|failed)" "probe-$name.log" \
    | grep -v "SCROLL_PROBE stack" \
    | awk '/ slow frame=/{if (++seen[$2] > 3) next} {print}' \
    || tail -n 40 "probe-$name.log"
  awk '/: error: /{p=1} p{print; n++} /^Test Case .* failed/{if (p) exit} n>=60{exit}' "probe-$name.log"
}

case "${1:-frames}" in
tests)
  # The suites the drawn text touches, failures as annotations.
  xcodebuild test-without-building \
    -xctestrun "$XCRUN_FILE" \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -only-testing:ConduitTests/ChatTypographyTests \
    -only-testing:ConduitTests/SelectableTextViewPresentationCacheTests \
    -only-testing:ConduitTests/MarkdownSelectionCoordinatorTests \
    -only-testing:ConduitTests/ChatTextSelectionTests \
    -only-testing:ConduitTests/ChatQuoteTests \
    -only-testing:ConduitTests/ChatScrollHostedTests \
    > tests.log 2>&1 || echo "tests exited $?"
  { grep -E "^Test Suite .*(passed|failed)|Executed [0-9]+ test" tests.log | tail -n 12
    grep -E ": error: |^Test Case .* failed" tests.log | sed -e "s|$PWD/||g" | head -n 80
  } > tests-summary.txt
  cat tests-summary.txt
  python3 "$HERE/annotate.py" tests-summary.txt tests
  ;;
frames)
  # Drawn text (the default) against text views everywhere, interleaved:
  # the first process in a job runs slower, so each kind gets two runs.
  # The last run leaves the drifting backdrop out, to show its share.
  run_probe drawn-1 "$frames"
  run_probe textviews-1 "$frames" TEST_RUNNER_PROBE_TEXT_VIEWS=1
  run_probe drawn-2 "$frames"
  run_probe textviews-2 "$frames" TEST_RUNNER_PROBE_TEXT_VIEWS=1
  run_probe drawn-still "$frames" TEST_RUNNER_PROBE_NO_BACKDROP=1
  for name in drawn-1 textviews-1 drawn-2 textviews-2 drawn-still; do summarise "$name"; done > probe-summary.txt
  cat probe-summary.txt
  python3 "$HERE/annotate.py" probe-summary.txt probe
  ;;
stacks)
  # Drawn text again with the in-process sampler: where the slowest
  # frames' main-thread time went, as call trees.
  run_probe drawn-stacks "$frames" TEST_RUNNER_PROBE_STACKS=1
  { grep -E "SCROLL_PROBE (up-new-rows|down-seen-rows) frames=|SCROLL_PROBE stacks" probe-drawn-stacks.log \
      || tail -n 40 probe-drawn-stacks.log
    awk '/: error: /{p=1} p{print; n++} n>=40{exit}' probe-drawn-stacks.log
  } > stacks-summary.txt
  python3 "$HERE/annotate.py" stacks-summary.txt stacks
  ;;
esac
