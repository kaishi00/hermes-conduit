#!/usr/bin/env bash
# Temporary scroll-probe runner. `run.sh frames` runs the frame test without
# a profiler; `run.sh profile` runs it again under the Time Profiler and
# summarises the samples taken inside each probe frame.
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
  run_probe drawn-1 "$frames"
  run_probe textviews-1 "$frames" TEST_RUNNER_PROBE_TEXT_VIEWS=1
  run_probe drawn-2 "$frames"
  run_probe textviews-2 "$frames" TEST_RUNNER_PROBE_TEXT_VIEWS=1
  for name in drawn-1 textviews-1 drawn-2 textviews-2; do summarise "$name"; done > probe-summary.txt
  cat probe-summary.txt
  python3 "$HERE/annotate.py" probe-summary.txt probe
  ;;
profile)
  xcrun xctrace version || true
  # The test host runs from the simulator's own copy of the app; hosts
  # left from the runs before, and helpers naming the build's copy, are
  # not it.
  app="CoreSimulator/Devices/$SIMULATOR_UDID/data/Containers/Bundle/Application/.*/Conduit\.app/Conduit( |$)"
  any='Conduit\.app/Conduit( |$)'
  stale=" $(pgrep -f "$any" | tr '\n' ' ') "
  echo "stale:$stale" | tee profile-log.txt
  # The test waits PROBE_WAIT seconds before scrolling, for the recorder.
  ( run_probe profiled "$frames" TEST_RUNNER_PROBE_WAIT=60 ) &
  probe_pid=$!
  pid=""
  for attempt in $(seq 1 240); do
    pattern=$app
    [ "$attempt" -gt 90 ] && pattern=$any
    for candidate in $(pgrep -f "$pattern"); do
      case "$stale" in *" $candidate "*) ;; *) pid=$candidate ;; esac
    done
    [ -n "$pid" ] && break
    sleep 1
  done
  sleep 3
  {
    echo "test host pid=${pid:-none}"
    ps -axo pid,etime,command | grep -E 'Conduit\.app/Conduit' | grep -v grep | cut -c1-260
  } | tee -a profile-log.txt
  recorder_pid=""
  record() {
    rm -rf probe.trace
    xcrun xctrace record --template 'Time Profiler' "$@" --output probe.trace \
      --time-limit 300s --no-prompt > xctrace.log 2>&1 &
    local recorder=$!
    for _ in $(seq 1 30); do
      if ! kill -0 "$recorder" 2>/dev/null; then
        wait "$recorder"
        echo "recorder ($*) exited $?: $(grep -v '^\s*$' xctrace.log | head -n 2 | tr '\n' ' ')" | tee -a profile-log.txt
        return 1
      fi
      grep -qiE "starting recording|ctrl-c" xctrace.log && break
      sleep 1
    done
    sleep 2
    kill -0 "$recorder" 2>/dev/null || { echo "recorder ($*) stopped: $(head -n 2 xctrace.log | tr '\n' ' ')" | tee -a profile-log.txt; return 1; }
    echo "recording ($*): $(head -n 3 xctrace.log | tr '\n' ' ')" | tee -a profile-log.txt
    recorder_pid=$recorder
    return 0
  }
  if [ -n "$pid" ]; then
    record --device "$SIMULATOR_UDID" --attach "$pid" \
      || record --device "$SIMULATOR_UDID" --attach Conduit \
      || record --attach "$pid" \
      || record --device "$SIMULATOR_UDID" --all-processes \
      || echo "::warning::no recorder attached"
  fi
  wait "$probe_pid"
  if [ -n "$recorder_pid" ]; then
    # It stops when the test host exits; the limit is the backstop.
    for _ in $(seq 1 120); do kill -0 "$recorder_pid" 2>/dev/null || break; sleep 1; done
    kill -INT "$recorder_pid" 2>/dev/null || true
    wait "$recorder_pid" || true
    tail -n 20 xctrace.log
  fi
  summarise profiled > probe-summary.txt
  if [ -d probe.trace ]; then
    sudo chown -R "$(id -u)" probe.trace 2>/dev/null || true
    xcrun xctrace export --input probe.trace --toc > probe-toc.xml 2> export.log || cat export.log
    grep -oE 'schema="[^"]+"' probe-toc.xml | sort | uniq -c | head -n 40
    xcrun xctrace export --input probe.trace \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
      > probe-profile.xml 2>> export.log || cat export.log
    ls -la probe-profile.xml || true
    python3 "$HERE/profile_summary.py" probe-profile.xml Conduit > profile-summary.txt 2>&1 \
      || { echo "summary failed"; tail -n 20 profile-summary.txt; }
  else
    echo "PROFILE no trace recorded" > profile-summary.txt
    cat xctrace.log >> profile-summary.txt 2>/dev/null || true
  fi
  cat probe-summary.txt profile-summary.txt
  grep -v "^PROFILE \. \|^PROFILE [0-9]*ms [0-9]*% " profile-summary.txt > profile-tables.txt || true
  grep "^PROFILE \. \|^PROFILE [0-9]*ms [0-9]*% \|call tree" profile-summary.txt > profile-tree.txt || true
  { cat profile-log.txt; cat probe-summary.txt | grep -E "frames=|totals|sum=" ; cat profile-tables.txt; } > profile-annotations.txt
  python3 "$HERE/annotate.py" profile-annotations.txt profile
  ;;
tree)
  python3 "$HERE/annotate.py" profile-tree.txt tree
  ;;
esac
