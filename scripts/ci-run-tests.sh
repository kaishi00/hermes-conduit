#!/usr/bin/env bash
#
# Sharded CI test runner: build once, then run ONE test lane with a
# per-attempt wall-clock budget and retry-without-rebuilding.
#
# WHY THIS EXISTS: CI used to run the entire XCTest universe as one
# monolithic `xcodebuild test`. As the suite grew, a single hung async test or
# wedged simulator hit the attempt budget and forced a FULL-SUITE rerun on a
# reset simulator — the dominant CI cost. This runner instead executes a
# single lane (see scripts/test-shards.txt), and the workflow runs the lanes
# as parallel jobs, so:
#   - a timeout or flaky run retries only the current lane;
#   - the other lanes' results are never thrown away (fail-fast: false);
#   - retries re-use the already-built test products: the lane runs
#     `build-for-testing` exactly once and every attempt (including retries)
#     is `test-without-building`. A runtime retry NEVER rebuilds.
#
# Usage:
#   scripts/ci-run-tests.sh <lane>       lane: unit-a|unit-b|unit-c|unit-d|ui
#
# Phases:
#   1. build-for-testing     — exactly once; NO retry (build failures are
#                              deterministic; retrying cannot help and a
#                              simulator reset would not fix them).
#                              Budget: BUILD_TIMEOUT_SECS.
#   2. test-without-building — up to ATTEMPTS attempts, each with budget
#                              ATTEMPT_TIMEOUT_SECS. Before a RETRY attempt the
#                              simulator is reset; after a TIMED-OUT attempt
#                              that reset escalates to an erase (the deadline
#                              kill removes xcodebuild's process group, but
#                              services inside the simulator — e.g. the
#                              pasteboard daemon — can stay wedged in ways a
#                              plain reboot does not clear).
#
# Simulator handling:
#   xcodebuild always uses the known SIMULATOR_DESTINATION directly — the
#   happy path never pays for `simctl list` enumeration. A concrete UDID is
#   resolved (one JSON query) only on the RETRY path, because the targeted
#   erase/boot needs one device and simctl cannot disambiguate a device name
#   that exists on several runtimes.
#
# Optional env:
#   SIMULATOR_NAME        simulator device name (default: iPhone 17 Pro).
#                         Composed into the xcodebuild destination; override
#                         when a runner-image refresh renames devices.
#   SIMULATOR_OS          optional OS pin appended to the destination.
#   ATTEMPT_TIMEOUT_SECS  per-test-attempt budget; default 600 s (10 min) for
#                         unit shards, 1200 s (20 min) for the ui lane.
#   BUILD_TIMEOUT_SECS    build-for-testing budget; default 900 s.
#   ATTEMPTS              max test attempts; default 2.
#
# Raw xcodebuild logs land in ci-logs/ and stream into the step log; partial
# .xcresult bundles are left on disk for the failure-only artifact upload.
#
# Bash 3.2 compatible (GitHub macOS runners default to /bin/bash).

set -uo pipefail

LANE="${1:-}"
case "$LANE" in
  ui)        TEST_TARGET="ConduitUITests" ;;
  unit-*)    TEST_TARGET="ConduitTests" ;;
  *)
    echo "::error::usage: $0 <lane> (unit-a|unit-b|unit-c|unit-d|ui); got '$LANE'"
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARD_FILE="$SCRIPT_DIR/test-shards.txt"
if [ ! -f "$SHARD_FILE" ]; then
  echo "::error::shard membership file not found: $SHARD_FILE"
  exit 1
fi

# Lane membership comes from the readable shard file; each class becomes one
# -only-testing:<target>/<class> argument.
CLASSES=()
while read -r lane cls _; do
  case "$lane" in ''|'#'*) continue ;; esac
  # A lane with no class would generate a bogus -only-testing:<target>/ arg.
  if [ -z "$cls" ]; then
    echo "::error::malformed line in $SHARD_FILE: expected '<lane> <ClassName>'"
    exit 1
  fi
  if [ "$lane" = "$LANE" ]; then
    CLASSES+=("$cls")
  fi
done < <(tr -d '\r' < "$SHARD_FILE")

if [ "${#CLASSES[@]}" -eq 0 ]; then
  echo "::error::lane '$LANE' has no classes in $SHARD_FILE"
  exit 1
fi

ONLY_TESTING=()
for cls in "${CLASSES[@]}"; do
  ONLY_TESTING+=("-only-testing:$TEST_TARGET/$cls")
done
echo "lane $LANE: ${#CLASSES[@]} classes from $TEST_TARGET"

SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME"
if [ -n "${SIMULATOR_OS:-}" ]; then
  DESTINATION="$DESTINATION,OS=$SIMULATOR_OS"
fi
echo "destination: $DESTINATION"

case "$LANE" in
  ui) DEFAULT_ATTEMPT_TIMEOUT=1200 ;;
  *)  DEFAULT_ATTEMPT_TIMEOUT=600 ;;
esac
ATTEMPT_TIMEOUT_SECS="${ATTEMPT_TIMEOUT_SECS:-$DEFAULT_ATTEMPT_TIMEOUT}"
BUILD_TIMEOUT_SECS="${BUILD_TIMEOUT_SECS:-900}"
ATTEMPTS="${ATTEMPTS:-2}"

PROJECT="Conduit.xcodeproj"
SCHEME="Conduit"
LOG_DIR="ci-logs"
mkdir -p "$LOG_DIR"

# Headless CI has no clipboard UI. App-level UIPasteboard access participates
# in the Mac<->simulator automatic clipboard sync, a recurring hang source on
# fresh runners (observed as a unit-test suite stalling forever inside its
# first pasteboard touch). The pasteboard-mutating unit tests only need the
# device-local pasteboard, so keep Simulator.app out of the path entirely.
# Must happen before the device's pasteboard daemon first starts.
defaults write com.apple.iphonesimulator PasteboardAutomaticSync -bool false

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

# Run `xcodebuild "$@"` with a wall-clock deadline. Streams the log into the
# step log; returns xcodebuild's exit status, or 124 when the deadline killed
# it. The caller owns the retry policy — this function never retries.
run_with_deadline() {
  local budget="$1"
  local log="$2"
  shift 2
  local started deadline poll printed heartbeat timed_out now remaining runner grace

  started=$(date +%s)
  deadline=$(( started + budget ))
  rm -f "$log"

  # Job control (set -m) puts this one background job into its own process
  # group so a deadline kill takes down xcodebuild AND its children (xctest,
  # simulator agents) without signalling this script itself.
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
      echo "… xcodebuild still running ($(( now - started ))s elapsed, ${remaining}s of budget left)"
    fi
    [ "$remaining" -lt "$poll" ] && poll="$remaining"
    sleep "$poll"
    poll=15
  done
  stream_new_lines "$log" printed

  if [ "$timed_out" -eq 1 ]; then
    echo "::error::xcodebuild exceeded its ${budget}s budget — killing the process group (pid $runner)"
    # xcodebuild spawns children (xctest, simulator agents); TERM the whole
    # group so nothing is orphaned, give it a grace window, then KILL.
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

# Bound a short-lived command with a wall-clock deadline. The reset path's
# simctl calls can hang on a wedged CoreSimulatorService — precisely the state
# the erase escalation targets — so they must not silently consume the job
# cap. stdout+stderr are captured into $BOUNDED_OUTPUT; the return value is
# the command's status, or 124 when the deadline killed it.
# NOTE: BOUNDED_OUTPUT is set in the CALLER's shell — readable after a plain
# call, but NOT across a $( ) subshell boundary (simulator_udid consumes it
# inside its own). Keep that constraint in mind when adding call sites.
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
      echo "::warning::bounded command exceeded its ${budget}s budget: $*"
      kill -TERM -- "-$runner" 2>/dev/null || kill -TERM "$runner" 2>/dev/null || true
      grace=3
      while [ "$grace" -gt 0 ] && kill -0 "$runner" 2>/dev/null; do
        sleep 1
        grace=$(( grace - 1 ))
      done
      kill -KILL -- "-$runner" 2>/dev/null || kill -KILL "$runner" 2>/dev/null || true
      wait "$runner" 2>/dev/null
      # Best-effort: keep whatever the killed command already wrote so
      # callers (e.g. timeout diagnostics) can preserve partial output.
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

# Resolve the UDID of the device the destination names. Only used on the RETRY
# path (erase/boot need one concrete device; simctl cannot take a name that
# exists on multiple runtimes). Picks the newest iOS runtime that has a device
# named $SIMULATOR_NAME — matching how xcodebuild resolves a name-only
# destination. Runtime keys embed the version (…SimRuntime.iOS-26-5); the
# newest pick compares MAJOR.MINOR NUMERICALLY (a plain lexical sort would
# rank iOS-26-10 older than iOS-26-9 once minors go double-digit).
simulator_udid() {
  local json runtime udid
  if ! command -v jq >/dev/null 2>&1; then
    echo "::warning::jq not found on runner — cannot resolve simulator UDID for the targeted erase/boot; degrading to xcodebuild-managed boot"
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

# Reset the simulator to a known-clean state before a RETRY attempt.
# $1 = 1 erases the device before booting (used after a timed-out attempt).
# Failures are tolerated and degrade gracefully: on a wedged CoreSimulator
# service the retry still happens — xcodebuild boots the destination itself.
reset_and_boot_simulator() {
  local erase="${1:-0}"
  local udid
  # Every simctl call below is deadline-bounded: a wedged
  # CoreSimulatorService must cost a bounded warning, not the whole job cap.
  # On any bound/degrade the retry still happens — xcodebuild boots the
  # destination itself.
  bounded_run 60 xcrun simctl shutdown all || true
  if [ "$erase" -eq 1 ]; then
    echo "::warning::previous attempt timed out — erasing simulator before retry"
    if udid=$(simulator_udid); then
      bounded_run 180 xcrun simctl erase "$udid" || true
    else
      echo "::warning::could not resolve simulator UDID for erase — retrying without erase"
    fi
  fi
  sleep 3
  if udid=$(simulator_udid); then
    bounded_run 60 xcrun simctl boot "$udid" || true
    # Wait for a complete boot before handing the device to xcodebuild; a
    # half-booted simulator wedges tests. bootstatus bounds itself with
    # -t 180; the outer bound catches bootstatus itself hanging.
    bounded_run 200 xcrun simctl bootstatus "$udid" -b -t 180 || true
  else
    echo "::warning::could not resolve simulator UDID — letting xcodebuild boot the destination itself"
  fi
}

# ---------------------------------------------------------------------------
# Phase 1: build the test products exactly once. No retry: build failures are
# deterministic, and a simulator reset cannot fix them.
# ---------------------------------------------------------------------------
echo "::group::build-for-testing (budget ${BUILD_TIMEOUT_SECS}s)"
build_status=0
run_with_deadline "$BUILD_TIMEOUT_SECS" "$LOG_DIR/build.log" \
  build-for-testing \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" || build_status=$?
echo "::endgroup::"

if [ "$build_status" -ne 0 ]; then
  echo "::error::build-for-testing failed (exit $build_status) — lane $LANE aborted; full log: $LOG_DIR/build.log"
  exit 1
fi
echo "build-for-testing ok; test retries will reuse these products"

# ---------------------------------------------------------------------------
# Phase 2: run the lane with test-without-building. Every attempt — including
# retries — uses the artifacts built above; a runtime retry never rebuilds.
# ---------------------------------------------------------------------------
erase_before_retry=0
for attempt in $(seq 1 "$ATTEMPTS"); do
  if [ "$attempt" -eq 1 ]; then
    bundle="TestResults.xcresult"
    # Fresh runner VMs start with devices shut down and clean; a blanket
    # shutdown is cheap and guarantees xcodebuild cold-boots the destination.
    # No simctl enumeration on the happy path.
    bounded_run 60 xcrun simctl shutdown all || true # bounded: a wedged CoreSimulatorService must not stall the lane before attempt 1
  else
    bundle="TestResults-retry.xcresult"
    # A wedged or half-booted simulator is the one failure mode an in-test
    # retry cannot clear; reset (and after a timeout, erase) before retrying.
    echo "Resetting simulator before retry attempt $attempt"
    reset_and_boot_simulator "$erase_before_retry"
  fi

  rm -rf "$bundle"

  echo "::group::Test attempt $attempt for lane $LANE (budget ${ATTEMPT_TIMEOUT_SECS}s)"
  status=0
  run_with_deadline "$ATTEMPT_TIMEOUT_SECS" "$LOG_DIR/attempt-${attempt}.log" \
    test-without-building \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -resultBundlePath "$bundle" \
    "${ONLY_TESTING[@]}" || status=$?
  echo "::endgroup::"

  if [ "$status" -eq 0 ]; then
    echo "lane $LANE passed on attempt $attempt"
    exit 0
  fi
  echo "lane $LANE failed on attempt $attempt (exit status $status)"
  # Only a deadline kill (124) escalates the next reset to an erase; ordinary
  # test failures keep the fast shutdown→boot path. Failure-only diagnostics:
  # capture device state and leave the partial result bundle for upload.
  if [ "$status" -eq 124 ]; then
    erase_before_retry=1
    # Best-effort failure-only diagnostics: this runs right after a
    # simulator/test timeout — exactly when CoreSimulatorService is most
    # likely unhealthy — so it is deadline-bounded and must never delay the
    # shard-local retry. Partial output from a killed dump is preserved.
    diag="$LOG_DIR/simctl-devices-after-timeout-attempt-${attempt}.txt"
    diag_status=0
    bounded_run 45 xcrun simctl list devices || diag_status=$?
    # Always materialize the artifact (even an empty capture) so the failure
    # bundle is consistent.
    printf '%s\n' "${BOUNDED_OUTPUT:-<no output captured before failure/deadline>}" > "$diag"
    if [ "$diag_status" -ne 0 ]; then
      if [ "$diag_status" -eq 124 ]; then
        echo "::warning::timeout diagnostic 'simctl list devices' did not complete within 45s — partial output in $diag; continuing to retry"
      else
        echo "::warning::timeout diagnostic 'simctl list devices' failed (exit $diag_status) — output in $diag; continuing to retry"
      fi
    fi
  fi
done

echo "::error::all $ATTEMPTS attempts failed for lane $LANE"
exit 1
