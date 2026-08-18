#!/usr/bin/env bash
#
# Full-suite test runner with a per-attempt wall-clock budget.
#
# WHY THIS EXISTS: a single hung async test (or a wedged simulator) makes
# xcodebuild emit no output and never exit. Without a per-attempt deadline the
# retry loop below can never advance — the 45-minute job timeout kills the job
# instead, attempt 2 never runs, and no diagnostics survive (CI run #328).
#
# Contract:
#   - Runs the full suite up to 2 times. Exit 0 = some attempt passed.
#     Exit 1 = every attempt failed or timed out.
#   - Each attempt gets ATTEMPT_TIMEOUT_SECS (default 960 = 16 min; healthy
#     runs finish in 7-13 min). Sized so the worst case — setup + a killed
#     attempt 1 + simulator reboots (bootstatus is bounded at 180s each) + a
#     full attempt 2 — stays under the 45-minute job timeout. A timed-out
#     attempt is killed by process group and its status flows through the
#     retry loop exactly like a test failure.
#   - The simulator is explicitly booted (shutdown → boot → bootstatus) before
#     EVERY attempt, including the first.
#   - Raw xcodebuild logs land in ci-logs/ and stream into the step log; any
#     partial .xcresult bundles are left on disk for the artifact upload.
#
# Required env:
#   SIMULATOR            UDID of the iOS simulator to test against.
# Optional env:
#   ATTEMPT_TIMEOUT_SECS per-attempt budget in seconds (default 960).
#   ATTEMPTS             max attempts (default 2).
#
# Bash 3.2 compatible (GitHub macOS runners default to /bin/bash).

set -uo pipefail

SIMULATOR="${SIMULATOR:-}"
ATTEMPT_TIMEOUT_SECS="${ATTEMPT_TIMEOUT_SECS:-960}"
ATTEMPTS="${ATTEMPTS:-2}"

if [ -z "$SIMULATOR" ]; then
  echo "::error::SIMULATOR (UDID) must be set"
  exit 1
fi

LOG_DIR="ci-logs"
mkdir -p "$LOG_DIR"

# Boot the simulator to a known-clean state. All failures are tolerated: on a
# fresh runner the device may already be shut down (or booted), and a wedged
# device is exactly what this reset is here to clear. bootstatus is bounded
# by -t; shutdown/boot themselves can in principle stall on a wedged
# CoreSimulatorService — the job-level timeout is the backstop for that.
reset_and_boot_simulator() {
  xcrun simctl shutdown "$SIMULATOR" >/dev/null 2>&1 || true
  sleep 3
  xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
  # Wait for a complete boot before handing the device to xcodebuild; a
  # half-booted simulator wedges tests.
  xcrun simctl bootstatus "$SIMULATOR" -b -t 180 || true
}

# Stream log lines not yet printed. $1 = log path, $2 = NAME of the caller's
# variable holding the last printed line count (written back via printf -v).
# NOTE: no local may share that variable's name — a local would shadow the
# caller's binding under bash dynamic scoping and the counter would never
# advance, re-printing the whole log every poll.
stream_new_lines() {
  local logfile="$1"
  local printed_var="$2"
  local total=0
  if [ -f "$logfile" ]; then
    total=$(wc -l < "$logfile" | tr -d ' ')
  fi
  if [ "$total" -gt "${!printed_var}" ]; then
    tail -n +"$(( ${!printed_var} + 1 ))" "$logfile"
    printf -v "$printed_var" '%s' "$total"
  fi
}

# Run one xcodebuild attempt with a wall-clock deadline. Echoes the attempt's
# exit status: xcodebuild's own status, or 124 when the deadline killed it.
run_attempt() {
  local attempt="$1"
  local bundle="$2"
  local log="$LOG_DIR/attempt-${attempt}.log"

  rm -rf "$bundle"

  # Job control (set -m) puts this one background job into its own process
  # group so a deadline kill takes down xcodebuild AND its children (xctest,
  # simulator agents) without signalling this script itself.
  set -m
  xcodebuild test \
    -project Conduit.xcodeproj \
    -scheme Conduit \
    -destination "platform=iOS Simulator,id=$SIMULATOR" \
    -configuration Debug \
    -resultBundlePath "$bundle" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    >"$log" 2>&1 &
  local runner=$!
  set +m

  # Poll liveness, stream new output, and enforce the deadline. Sleeps never
  # cross the deadline, so the kill lands within one poll of the budget.
  local deadline=$(( $(date +%s) + ATTEMPT_TIMEOUT_SECS ))
  local poll=15
  local printed=0
  local heartbeat=0
  local timed_out=0
  while kill -0 "$runner" 2>/dev/null; do
    local now=$(date +%s)
    local remaining=$(( deadline - now ))
    if [ "$remaining" -le 0 ]; then
      timed_out=1
      break
    fi
    stream_new_lines "$log" printed
    heartbeat=$(( heartbeat + 1 ))
    if [ "$(( heartbeat % 4 ))" -eq 0 ]; then
      echo "… attempt ${attempt} still running ($(( ATTEMPT_TIMEOUT_SECS - remaining ))s elapsed, ${remaining}s of budget left)"
    fi
    [ "$remaining" -lt "$poll" ] && poll="$remaining"
    sleep "$poll"
    poll=15
  done
  stream_new_lines "$log" printed

  if [ "$timed_out" -eq 1 ]; then
    echo "::error::Attempt ${attempt} exceeded its ${ATTEMPT_TIMEOUT_SECS}s budget — killing the xcodebuild process group (pid $runner)"
    # xcodebuild spawns children (xctest, simulator agents); TERM the whole
    # group so nothing is orphaned, give it a grace window, then KILL.
    kill -TERM -- "-$runner" 2>/dev/null || kill -TERM "$runner" 2>/dev/null || true
    local grace=10
    while [ "$grace" -gt 0 ] && kill -0 "$runner" 2>/dev/null; do
      sleep 1
      grace=$(( grace - 1 ))
    done
    kill -KILL -- "-$runner" 2>/dev/null || kill -KILL "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null
    # Diagnostics: whatever the (progressively written) result bundle holds
    # stays on disk for the upload step; capture the device state and the
    # wedge point in the log tail.
    xcrun simctl list devices >"$LOG_DIR/simctl-devices-after-timeout-attempt-${attempt}.txt" 2>&1 || true
    ls -l "$log" || true
    echo "---- last 200 log lines of the timed-out attempt ----"
    tail -n 200 "$log" || true
    echo "------------------------------------------------------"
    return 124
  fi

  wait "$runner"
}

for attempt in $(seq 1 "$ATTEMPTS"); do
  if [ "$attempt" -eq 1 ]; then
    bundle="TestResults.xcresult"
  else
    bundle="TestResults-retry.xcresult"
  fi

  # A wedged or half-booted simulator is the one failure mode in-test retries
  # cannot clear; reset it before every attempt, including the first.
  echo "Booting simulator $SIMULATOR for attempt $attempt"
  reset_and_boot_simulator

  echo "::group::Test attempt $attempt (budget ${ATTEMPT_TIMEOUT_SECS}s)"
  status=0
  run_attempt "$attempt" "$bundle" || status=$?
  echo "::endgroup::"

  if [ "$status" -eq 0 ]; then
    echo "tests passed on attempt $attempt"
    exit 0
  fi
  echo "tests failed on attempt $attempt (exit status $status)"
done

echo "all $ATTEMPTS test attempts failed"
exit 1
