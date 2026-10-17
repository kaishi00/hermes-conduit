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
record)
  # Runs the frame test under the Time Profiler. Every wait is bounded and
  # what happened goes to profile-log.txt, printed as annotations at the end.
  : > profile-log.txt
  log() { echo "$*" | tee -a profile-log.txt; }
  # Waits up to $2 seconds for pid $1 to exit.
  wait_for() {
    for _ in $(seq 1 "$2"); do
      kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null; return 0; }
      sleep 1
    done
    return 1
  }
  log "xctrace $(xcrun xctrace version 2>&1 | head -n 1)"
  # The test host runs from the simulator's own copy of the app; hosts
  # left from the runs before, and helpers naming the build's copy, are
  # not it.
  app="CoreSimulator/Devices/$SIMULATOR_UDID/data/Containers/Bundle/Application/.*/Conduit\.app/Conduit( |$)"
  any='Conduit\.app/Conduit( |$)'
  stale=" $(pgrep -f "$any" | tr '\n' ' ') "
  log "stale:$stale"
  # The test waits PROBE_WAIT seconds before scrolling, for the recorder.
  ( run_probe profiled "$frames" TEST_RUNNER_PROBE_WAIT=90 ) &
  probe_pid=$!
  pid=""
  for attempt in $(seq 1 150); do
    pattern=$app
    [ "$attempt" -gt 90 ] && pattern=$any
    for candidate in $(pgrep -f "$pattern"); do
      case "$stale" in *" $candidate "*) ;; *) pid=$candidate ;; esac
    done
    [ -n "$pid" ] && break
    sleep 1
  done
  sleep 3
  log "test host pid=${pid:-none} after ${attempt}s"
  ps -axo pid,etime,command | grep -E 'Conduit\.app/Conduit' | grep -v grep | cut -c1-240 | tee -a profile-log.txt
  recorder_pid=""
  attach() {
    rm -rf probe.trace
    xcrun xctrace record --template 'Time Profiler' "$@" --output probe.trace \
      --time-limit 200s --no-prompt > xctrace.log 2>&1 &
    local recorder=$!
    for _ in $(seq 1 20); do
      kill -0 "$recorder" 2>/dev/null || break
      grep -qiE "starting recording|ctrl-c" xctrace.log && break
      sleep 1
    done
    sleep 2
    if ! kill -0 "$recorder" 2>/dev/null; then
      wait "$recorder"
      log "attach ($*) exited $?: $(grep -v '^[[:space:]]*$' xctrace.log | head -n 3 | tr '\n' ' ' | cut -c1-300)"
      return 1
    fi
    log "attach ($*) running: $(grep -v '^[[:space:]]*$' xctrace.log | head -n 3 | tr '\n' ' ' | cut -c1-300)"
    recorder_pid=$recorder
  }
  if [ -n "$pid" ]; then
    attach --device "$SIMULATOR_UDID" --attach "$pid" \
      || attach --device "$SIMULATOR_UDID" --attach Conduit \
      || attach --attach "$pid" \
      || log "no recorder attached"
  fi
  if wait_for "$probe_pid" 300; then log "probe finished"; else log "probe still running after 300s, stopping it"; pkill -f "test-without-building" || true; fi
  if [ -n "$recorder_pid" ]; then
    # It stops when the test host exits; the limit is the backstop.
    if wait_for "$recorder_pid" 30; then
      log "recorder stopped by itself"
    else
      kill -INT "$recorder_pid" 2>/dev/null || true
      if wait_for "$recorder_pid" 150; then log "recorder stopped on SIGINT"; else log "recorder hung, killed"; kill -9 "$recorder_pid" 2>/dev/null || true; fi
    fi
    log "recorder tail: $(tail -n 4 xctrace.log | tr '\n' ' ' | cut -c1-400)"
  fi
  log "trace: $(du -sh probe.trace 2>/dev/null | cut -f1)"
  summarise profiled > probe-summary.txt
  { cat profile-log.txt; grep -E "frames=|totals|sum=" probe-summary.txt; } > record-annotations.txt
  python3 "$HERE/annotate.py" record-annotations.txt record
  ;;
export)
  # Bounded with perl's alarm: macOS has no timeout(1).
  bounded() { local limit=$1; shift; perl -e 'alarm shift; exec @ARGV' "$limit" "$@"; }
  : > export-log.txt
  if [ -d probe.trace ]; then
    sudo chown -R "$(id -u)" probe.trace 2>/dev/null || true
    bounded 240 xcrun xctrace export --input probe.trace --toc > probe-toc.xml 2> export.log
    echo "toc exit $? size $(wc -c < probe-toc.xml)" >> export-log.txt
    grep -oE 'schema="[^"]+"' probe-toc.xml | sort | uniq -c | head -n 30 >> export-log.txt
    bounded 360 xcrun xctrace export --input probe.trace \
      --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
      > probe-profile.xml 2>> export.log
    echo "time-profile exit $? size $(wc -c < probe-profile.xml)" >> export-log.txt
    head -c 1500 export.log >> export-log.txt
  else
    echo "no trace" >> export-log.txt
  fi
  cat export-log.txt
  python3 "$HERE/annotate.py" export-log.txt export
  ;;
summary)
  bounded() { local limit=$1; shift; perl -e 'alarm shift; exec @ARGV' "$limit" "$@"; }
  if [ -s probe-profile.xml ]; then
    bounded 420 python3 "$HERE/profile_summary.py" probe-profile.xml Conduit > profile-summary.txt 2>&1 \
      || echo "summary exited $?" >> profile-summary.txt
  else
    echo "PROFILE no time-profile table" > profile-summary.txt
  fi
  grep -v "^PROFILE \. \|^PROFILE [0-9]*ms [0-9]*% " profile-summary.txt > profile-tables.txt || true
  grep "^PROFILE \. \|^PROFILE [0-9]*ms [0-9]*% \|call tree" profile-summary.txt > profile-tree.txt || true
  cat profile-tables.txt
  python3 "$HERE/annotate.py" profile-tables.txt profile
  ;;
tree)
  python3 "$HERE/annotate.py" profile-tree.txt tree
  ;;
esac
