#!/bin/bash
# Temporary: runs a suite's tests repeatedly under CPU load and posts one
# annotation per xcodebuild invocation with every failing test and count.
# Usage: run-stress.sh <voice-live|shard1-rest> <iterations> <label>
set -uo pipefail
suite="$1" iterations="$2" label="$3"

voice=$(python3 .github/stress-tmp/list-tests.py ConduitTests/GeminiLiveVoiceTests.swift ConduitTests/GrokLiveVoiceTests.swift ConduitTests/GPTLiveVoiceTests.swift)
skips=()
if [ "$suite" = voice-live ]; then
  batches=("$voice")
else
  # Shard 1's classes in two halves, minus the voice-live tests.
  python3 scripts/plan-tests.py hosted --repo-root . --suite scripts/hosted-suite.json --out "$RUNNER_TEMP/hosted.json" >/dev/null
  IFS=',' read -r -a classes <<< "$(jq -r '.unit_shards[0]' "$RUNNER_TEMP/hosted.json")"
  half=$(( (${#classes[@]} + 1) / 2 ))
  first=$(printf 'ConduitTests/%s,' "${classes[@]:0:$half}")
  second=$(printf 'ConduitTests/%s,' "${classes[@]:$half}")
  batches=("${first%,}" "${second%,}")
  IFS=',' read -r -a voice_ids <<< "$voice"
  for id in "${voice_ids[@]}"; do skips+=("-skip-testing:$id"); done
fi

ncpu=$(sysctl -n hw.ncpu)
n=0
for batch in "${batches[@]}"; do
  n=$((n + 1))
  args=()
  IFS=',' read -r -a ids <<< "$batch"
  for id in "${ids[@]}"; do args+=("-only-testing:$id"); done
  log="$RUNNER_TEMP/stress-$n.log"
  : > "$log"
  # The hogs start once tests are running: under full load from the start,
  # xcodebuild gave up resolving the simulator (exit 70) before any test.
  (
    for _ in $(seq 1 900); do
      grep -q "Test Suite '.*' started" "$log" 2>/dev/null && break
      sleep 1
    done
    echo "CPU hogs: $ncpu"
    for _ in $(seq 1 "$ncpu"); do yes > /dev/null & done
    wait
  ) &
  hogs=$!
  echo "::group::$label batch $n (${#ids[@]} selections x $iterations)"
  start=$(date +%s)
  xcodebuild test-without-building \
    -xctestrun "$XCRUN_FILE" \
    -destination "$DESTINATION" \
    -parallel-testing-enabled NO \
    -collect-test-diagnostics never \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 180 \
    -test-iterations "$iterations" \
    "${args[@]}" ${skips[@]+"${skips[@]}"} > "$log" 2>&1
  rc=$?
  pkill yes || true
  kill "$hogs" 2>/dev/null || true
  echo "xcodebuild exit $rc after $(( $(date +%s) - start ))s"
  grep -E "error: -\[|' failed \(|Restarting after|Executed [0-9]+ tests" "$log" | tail -n 60
  if [ "$rc" -ne 0 ]; then
    echo "--- last lines of the xcodebuild log ---"
    tail -n 80 "$log"
  fi
  echo "::endgroup::"
  python3 .github/stress-tmp/stress-summary.py "$log" "$label batch $n (x$iterations, exit $rc)"
done
exit 0
