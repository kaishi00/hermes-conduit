#!/bin/bash
# Temporary: runs tests repeatedly under CPU load and posts one annotation
# per mode with every failing test and count, plus how long the traced
# condition waits took.
# Usage: run-stress.sh voice-live <iterations> <label>
#        run-stress.sh ci-batch <batch-number> <repeats> <label>
set -uo pipefail
mode="$1"

voice=$(python3 .github/stress-tmp/list-tests.py ConduitTests/GeminiLiveVoiceTests.swift ConduitTests/GrokLiveVoiceTests.swift ConduitTests/GPTLiveVoiceTests.swift)
ncpu=$(sysctl -n hw.ncpu)

# One xcodebuild invocation; the hogs start once tests are running (under
# full load from the start, xcodebuild gave up resolving the simulator).
run_once() {
  local log="$1"; shift
  : > "$log"
  (
    for _ in $(seq 1 900); do
      grep -q "Test Suite '.*' started" "$log" 2>/dev/null && break
      sleep 1
    done
    for _ in $(seq 1 "$ncpu"); do yes > /dev/null & done
    wait
  ) &
  local hogs=$! start rc
  start=$(date +%s)
  xcodebuild test-without-building \
    -xctestrun "$XCRUN_FILE" \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    "$@" > "$log" 2>&1
  rc=$?
  pkill yes || true
  kill "$hogs" 2>/dev/null || true
  echo "xcodebuild exit $rc after $(( $(date +%s) - start ))s"
  grep -E "error: -\[|' failed \(|Restarting after|Executed [0-9]+ tests" "$log" | tail -n 40
  if [ "$rc" -ne 0 ]; then
    echo "--- last lines of the xcodebuild log ---"
    tail -n 60 "$log"
  fi
  return 0
}

logs=()
if [ "$mode" = voice-live ]; then
  iterations="$2" label="$3"
  args=()
  IFS=',' read -r -a ids <<< "$voice"
  for id in "${ids[@]}"; do args+=("-only-testing:$id"); done
  echo "::group::$label (${#ids[@]} tests x $iterations)"
  run_once "$RUNNER_TEMP/voice-live.log" -test-iterations "$iterations" "${args[@]}"
  echo "::endgroup::"
  logs+=("$RUNNER_TEMP/voice-live.log")
else
  batch="$2" repeats="$3" label="$4"
  # Shard 1's classes split into batches the way ci.yml splits them.
  python3 scripts/plan-tests.py hosted --repo-root . --suite scripts/hosted-suite.json --out "$RUNNER_TEMP/hosted.json" >/dev/null
  IFS=',' read -r -a classes <<< "$(jq -r '.unit_shards[0]' "$RUNNER_TEMP/hosted.json")"
  batches=$(( (${#classes[@]} + 44) / 45 ))
  per_batch=$(( (${#classes[@]} + batches - 1) / batches ))
  selected=("${classes[@]:$(( (batch - 1) * per_batch )):$per_batch}")
  args=()
  for cls in "${selected[@]}"; do args+=("-only-testing:ConduitTests/$cls"); done
  echo "batch $batch of $batches: ${selected[*]}"
  for r in $(seq 1 "$repeats"); do
    echo "::group::$label run $r of $repeats (${#selected[@]} classes)"
    run_once "$RUNNER_TEMP/batch-$batch-$r.log" "${args[@]}"
    echo "::endgroup::"
    logs+=("$RUNNER_TEMP/batch-$batch-$r.log")
  done
fi
python3 .github/stress-tmp/stress-summary.py "$label" "${logs[@]}"
exit 0
