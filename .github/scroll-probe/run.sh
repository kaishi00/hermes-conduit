#!/usr/bin/env bash
# Temporary scroll-probe runner. `run.sh tests` runs the suites the drawn
# text touches; `run.sh frames` runs the frame test, drawn text against text
# views; `run.sh sample` runs it again under macOS `sample`, and `summary` /
# `tree` print where the frames' main-thread time went.
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
sample)
  # Runs the frame test under macOS's `sample` (xctrace attaches to the
  # simulator's test host but never saves its trace). Every wait is bounded
  # and what happened goes to profile-log.txt, printed as annotations.
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
  app="CoreSimulator/Devices/$SIMULATOR_UDID/data/Containers/Bundle/Application/.*/Conduit\.app/Conduit( |$)"
  # The test says when the chat is ready (.ready), scrolls once the
  # sampler runs (.go), then holds until released.
  marker="$PWD/probe-marker"
  rm -f "$marker" "$marker".*
  ( run_probe profiled "$frames" TEST_RUNNER_PROBE_MARKER="$marker" ) &
  probe_pid=$!
  for waited in $(seq 1 240); do
    [ -e "$marker.ready" ] && break
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 1
  done
  pid=$(pgrep -f "$app" | tail -n 1)
  log "ready after ${waited}s: $([ -e "$marker.ready" ] && echo yes || echo no), test host pid=${pid:-none}"
  sampler=""
  if [ -n "$pid" ]; then
    # Symbols are read after sampling (no -mayDie): read first, they took
    # longer than the whole scroll. Through a pty (script -F) its first
    # line lands at once, so the scroll starts once sampling has.
    script -q -F sample.log sudo sample "$pid" 60 1 -file "$PWD/sample.txt" > /dev/null 2>&1 &
    sampler=$!
    for waited in $(seq 1 20); do
      grep -q "Sampling process" sample.log 2>/dev/null && break
      kill -0 "$sampler" 2>/dev/null || break
      sleep 1
    done
    sleep 1
    log "sampling after ${waited}s: $(head -c 200 sample.log | tr '\r\n' '  ')"
  fi
  touch "$marker.go"
  for waited in $(seq 1 180); do
    [ -e "$marker" ] && break
    kill -0 "$probe_pid" 2>/dev/null || break
    sleep 1
  done
  log "scrolled after ${waited}s: $([ -e "$marker" ] && echo yes || echo no)"
  if [ -n "$sampler" ]; then
    if wait_for "$sampler" 150; then
      log "sampler finished"
    else
      log "sampler still running, interrupting"
      sudo kill -INT "$sampler" 2>/dev/null || true
      wait_for "$sampler" 60 || { log "sampler hung, killed"; sudo kill -9 "$sampler" 2>/dev/null || true; }
    fi
    log "sampler: $(tail -c 300 sample.log | tr '\r\n' '  ')"
  fi
  touch "$marker.release"
  if wait_for "$probe_pid" 300; then log "probe finished"; else log "probe still running after 300s, stopping it"; pkill -f "test-without-building" || true; fi
  sudo chown "$(id -u)" sample.txt 2>/dev/null || true
  log "sample.txt: $(wc -c < sample.txt 2>/dev/null || echo missing) bytes"
  summarise profiled > probe-summary.txt
  { cat profile-log.txt; grep -E "frames=|totals|sum=" probe-summary.txt; } > record-annotations.txt
  python3 "$HERE/annotate.py" record-annotations.txt record
  ;;
summary)
  bounded() { local limit=$1; shift; perl -e 'alarm shift; exec @ARGV' "$limit" "$@"; }
  if [ -s sample.txt ]; then
    bounded 240 python3 "$HERE/sample_summary.py" sample.txt > profile-summary.txt 2>&1 \
      || echo "summary exited $?" >> profile-summary.txt
  else
    echo "PROFILE no sample report" > profile-summary.txt
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
