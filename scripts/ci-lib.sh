#!/usr/bin/env bash
#
# Shared CI runner primitives for Hermes Conduit CI v2.
#
# Sourced by ci-build-for-testing.sh and ci-test-lane.sh. Bash 3.2 compatible
# (GitHub macOS runners default to /bin/bash).
#
# Helpers:
#   run_with_deadline          - xcodebuild under a wall-clock watchdog; kills
#                                the whole process group (xcodebuild + xctest +
#                                simulator agents) on expiry. Returns 124.
#   bounded_run                - any short command under a deadline so a wedged
#                                CoreSimulatorService costs a bounded warning,
#                                not the job. Output lands in BOUNDED_OUTPUT.
#   simulator_udid             - resolve the destination device UDID.
#   reset_and_boot_simulator   - bounded shutdown/erase/boot recovery.
#   now_iso                    - UTC timestamp for lane result documents.

# Stream log lines not yet printed. $1 = log path, $2 = NAME of the caller's
# variable holding the last printed line count (written back via printf -v).
# NOTE: no local may share that variable's name - a local would shadow the
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

# Run the command given after the first two args under a wall-clock deadline
# (arg 1 = budget seconds, arg 2 = log path). Streams the log into the step
# log; returns the command's exit status, or 124 when the deadline killed it.
# The caller owns retry policy - this function never retries.
run_with_deadline() {
  local budget="$1"
  local log="$2"
  shift 2
  local started deadline poll printed heartbeat timed_out now remaining runner grace

  started=$(date +%s)
  deadline=$(( started + budget ))
  rm -f "$log"

  # Job control (set -m) puts this one background job into its own process
  # group so a deadline kill takes down the command AND its children without
  # signalling this script itself.
  set -m
  xcodebuild "$@" >"$log" 2>&1 &
  runner=$!
  set +m

  # Poll liveness, stream new output, and enforce the deadline. Sleeps never
  # cross the deadline, so the kill lands within one poll of the budget.
  poll=15
  printed=0
  heartbeat=0
  timed_out=0
  while kill -0 "$runner" 2>/dev/null; do
    now=$(date +%s)
    remaining=$(( deadline - now ))
    if [ "$remaining" -le 0 ]; then
      timed_out=1
      break
    fi
    stream_new_lines "$log" printed
    heartbeat=$(( heartbeat + 1 ))
    if [ "$(( heartbeat % 4 ))" -eq 0 ]; then
      echo "... xcodebuild still running ($(( now - started ))s elapsed, "${remaining}"s of budget left)"
    fi
    [ "$remaining" -lt "$poll" ] && poll="$remaining"
    sleep "$poll"
    poll=15
  done
  stream_new_lines "$log" printed

  if [ "$timed_out" -eq 1 ]; then
    echo "::error::xcodebuild exceeded its "${budget}"s budget - killing the process group (pid $runner)"
    # TERM the whole group so nothing is orphaned, grace window, then KILL.
    kill -TERM -- "-$runner" 2>/dev/null || kill -TERM "$runner" 2>/dev/null || true
    grace=10
    while [ "$grace" -gt 0 ] && kill -0 "$runner" 2>/dev/null; do
      sleep 1
      grace=$(( grace - 1 ))
    done
    kill -KILL -- "-$runner" 2>/dev/null || kill -KILL "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null
    ls -l "$log" || true
    echo "---- last 200 log lines of the timed-out invocation ----"
    tail -n 200 "$log" || true
    echo "--------------------------------------------------------"
    return 124
  fi

  wait "$runner"
}

# Bound a short-lived command with a wall-clock deadline. stdout+stderr are
# captured into BOUNDED_OUTPUT (caller's shell); the return value is the
# command's status, or 124 when the deadline killed it. BOUNDED_OUTPUT is NOT
# visible across a subshell boundary.
BOUNDED_OUTPUT=""
bounded_run() {
  local budget="$1"
  shift
  local outfile="$LOG_DIR/bounded-$$.log"
  local runner status grace
  BOUNDED_OUTPUT=""
  set -m
  "$@" >"$outfile" 2>&1 &
  runner=$!
  set +m
  local deadline=$(( $(date +%s) + budget ))
  while kill -0 "$runner" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "::warning::bounded command exceeded its "${budget}"s budget: $*"
      kill -TERM -- "-$runner" 2>/dev/null || kill -TERM "$runner" 2>/dev/null || true
      grace=3
      while [ "$grace" -gt 0 ] && kill -0 "$runner" 2>/dev/null; do
        sleep 1
        grace=$(( grace - 1 ))
      done
      kill -KILL -- "-$runner" 2>/dev/null || kill -KILL "$runner" 2>/dev/null || true
      wait "$runner" 2>/dev/null
      # Keep whatever the killed command already wrote (partial diagnostics).
      BOUNDED_OUTPUT="$(cat "$outfile" 2>/dev/null)"
      rm -f "$outfile"
      return 124
    fi
    sleep 2
  done
  status=0
  wait "$runner" || status=$?
  BOUNDED_OUTPUT="$(cat "$outfile" 2>/dev/null)"
  rm -f "$outfile"
  return "$status"
}

# Resolve the UDID of the device the destination names (newest iOS runtime
# wins). Numeric MAJOR.MINOR comparison so iOS-26-10 ranks above iOS-26-9.
simulator_udid() {
  local json runtime udid
  if ! command -v jq >/dev/null 2>&1; then
    echo "::warning::jq not found on runner - cannot resolve simulator UDID for the targeted erase/boot; degrading to xcodebuild-managed boot"
    return 1
  fi
  if ! bounded_run 60 xcrun simctl list devices available -j; then
    return 1
  fi
  json="$BOUNDED_OUTPUT"
  for runtime in $(printf '%s\n' "$json" | jq -r '.devices | keys[]' | grep 'SimRuntime\.iOS' | awk -F'iOS-' '{split($2, a, "-"); printf "%04d.%03d %s\n", a[1] + 0, a[2] + 0, $0}' | sort -rn | awk '{print $2}'); do
    udid=$(printf '%s\n' "$json" | jq -r --arg rt "$runtime" --arg n "$SIMULATOR_NAME" \
      '.devices[$rt][]? | select(.name == $n) | .udid' | head -n 1)
    if [ -n "$udid" ]; then
      printf '%s\n' "$udid"
      return 0
    fi
  done
  return 1
}

# Reset the simulator to a known-clean state. $1 = 1 erases the device before
# booting (used after a timed-out attempt). Every simctl call is deadline-
# bounded; failures degrade gracefully - xcodebuild boots the destination
# itself, so the retry still happens.
reset_and_boot_simulator() {
  local erase="${1:-0}"
  local udid
  bounded_run 60 xcrun simctl shutdown all || true
  if [ "$erase" -eq 1 ]; then
    echo "::warning::previous attempt timed out - erasing simulator before retry"
    if udid=$(simulator_udid); then
      bounded_run 180 xcrun simctl erase "$udid" || true
    else
      echo "::warning::could not resolve simulator UDID for erase - retrying without erase"
    fi
  fi
  sleep 3
  if udid=$(simulator_udid); then
    bounded_run 60 xcrun simctl boot "$udid" || true
    # Wait for a complete boot before handing the device to xcodebuild; a
    # half-booted simulator wedges tests.
    bounded_run 200 xcrun simctl bootstatus "$udid" -b -t 180 || true
  else
    echo "::warning::could not resolve simulator UDID - letting xcodebuild boot the destination itself"
  fi
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Headless CI has no clipboard UI. App-level UIPasteboard access participates
# in the Mac<->simulator automatic clipboard sync, a recurring hang source on
# fresh runners. Must happen before the device's pasteboard daemon first starts.
disable_pasteboard_sync() {
  defaults write com.apple.iphonesimulator PasteboardAutomaticSync -bool false
}

# Deterministic destination string shared by build and lane jobs. Sets the
# global DESTINATION from SIMULATOR_NAME (and optional SIMULATOR_OS).
build_destination() {
  DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME"
  if [ -n "${SIMULATOR_OS:-}" ]; then
    DESTINATION="$DESTINATION,OS=$SIMULATOR_OS"
  fi
}
