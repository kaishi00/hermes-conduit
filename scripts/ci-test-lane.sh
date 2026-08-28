#!/usr/bin/env bash
#
# CI v2 lane runner: execute ONE dynamically planned test lane from the shared
# build products (test-without-building; never rebuilds).
#
# Failure-domain policy (docs/CI.md):
#   1. Ordinary test failures never rerun the lane. Attempt 1 runs with
#      Xcode-native flake retry (-retry-tests-on-failure -test-iterations N),
#      which re-executes only the failing tests. If failures survive those
#      iterations the lane fails with the failing tests identified - the
#      healthy classes are never rerun.
#   2. One bounded infrastructure recovery: if an invocation dies without any
#      reported test failure (simulator crash, runner exit, ...), the lane
#      resets the simulator once and retries the whole lane.
#   3. Hangs/timeouts are a different failure mode. After killing the hung
#      process group and resetting (with erase) the simulator, the lane enters
#      ISOLATION: classes are re-run one at a time, heaviest-estimate first,
#      each under its own bounded watchdog, until the isolation budget is
#      spent. The lane result names the class that hung instead of silently
#      consuming another full lane budget.
#
# Every simctl operation is deadline-bounded (ci-lib.sh). Bash 3.2 compatible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ci-lib.sh"

KIND=""; LANE=""; TARGET=""; CLASSES=""; CLASS_ESTIMATES=""
PREDICTED_S=""; TIMEOUT_S=""; ITERATIONS="3"; XCRUN_FILE=""; RESULT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND="$2"; shift 2 ;;
    --lane) LANE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --classes) CLASSES="$2"; shift 2 ;;
    --class-estimates) CLASS_ESTIMATES="$2"; shift 2 ;;
    --predicted) PREDICTED_S="$2"; shift 2 ;;
    --timeout) TIMEOUT_S="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --xctestrun) XCRUN_FILE="$2"; shift 2 ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    *) echo "::error::unknown argument: $1"; exit 2 ;;
  esac
done

missing=""
[ -z "$KIND" ] && missing="$missing --kind"
[ -z "$LANE" ] && missing="$missing --lane"
[ -z "$TARGET" ] && missing="$missing --target"
[ -z "$CLASSES" ] && missing="$missing --classes"
[ -z "$PREDICTED_S" ] && missing="$missing --predicted"
[ -z "$TIMEOUT_S" ] && missing="$missing --timeout"
[ -z "$XCRUN_FILE" ] && missing="$missing --xctestrun"
[ -z "$RESULT_DIR" ] && missing="$missing --result-dir"
if [ -n "$missing" ]; then
  echo "::error::ci-test-lane.sh missing required arguments:$missing"
  exit 2
fi
if [ ! -f "$XCRUN_FILE" ]; then
  echo "::error::xctestrun file not found: $XCRUN_FILE - the shared build artifact is missing or was restored to the wrong path"
  exit 1
fi
case "$KIND" in unit|ui) ;; *) echo "::error::--kind must be unit or ui"; exit 2 ;; esac
for pair in "$TIMEOUT_S:--timeout" "$ITERATIONS:--iterations"; do
  value="${pair%%:*}"
  flag="${pair#*:}"
  case "$value" in
    ''|*[!0-9]*) echo "::error::$flag must be a positive integer, got '$value'"; exit 2 ;;
  esac
done
case "$PREDICTED_S" in
  ''|*[!0-9.]*) echo "::error::--predicted must be a positive number, got '$PREDICTED_S'"; exit 2 ;;
esac

CLASS_TIMEOUT_MIN_S="${CLASS_TIMEOUT_MIN_S:-180}"
CLASS_TIMEOUT_MULTIPLIER="${CLASS_TIMEOUT_MULTIPLIER:-4.0}"
DEFAULT_ESTIMATE_S="${DEFAULT_ESTIMATE_S:-20.0}"
ISOLATION_BUDGET_S="${ISOLATION_BUDGET_S:-$TIMEOUT_S}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"

LOG_DIR="$RESULT_DIR/logs"
mkdir -p "$LOG_DIR"
build_destination
disable_pasteboard_sync

echo "lane $LANE ($KIND): target $TARGET, predicted "${PREDICTED_S}"s, watchdog "${TIMEOUT_S}"s"
echo "destination: $DESTINATION"
echo "xctestrun: $XCRUN_FILE"

# --- lane membership + per-class estimates ----------------------------------
CLASSES_ARR=()
IFS=',' read -r -a CLASSES_ARR <<< "$CLASSES"
if [ "${#CLASSES_ARR[@]}" -eq 0 ]; then
  echo "::error::lane $LANE has no classes"
  exit 2
fi
ONLY_TESTING=()
for cls in "${CLASSES_ARR[@]}"; do
  ONLY_TESTING+=("-only-testing:$TARGET/$cls")
done
echo "lane $LANE: "${#CLASSES_ARR[@]}" classes"

EST_NAMES=(); EST_VALS=()
if [ -n "$CLASS_ESTIMATES" ]; then
  PAIRS=()
  IFS=',' read -r -a PAIRS <<< "$CLASS_ESTIMATES"
  for pair in "${PAIRS[@]}"; do
    name="${pair%%=*}"
    val="${pair#*=}"
    EST_NAMES+=("$name")
    EST_VALS+=("$val")
  done
fi

estimate_for() {
  local i=0
  if [ "${#EST_NAMES[@]}" -eq 0 ]; then
    return 1
  fi
  while [ "$i" -lt "${#EST_NAMES[@]}" ]; do
    if [ "${EST_NAMES[$i]}" = "$1" ]; then
      echo "${EST_VALS[$i]}"
      return 0
    fi
    i=$(( i + 1 ))
  done
  return 1
}

# Shared invocation: test-without-building from the downloaded products.
# Extra args (after the 4 named ones) are additional -only-testing filters.
# Native retry flags are only valid with more than one iteration ("Must
# specify -test-iterations with more than 1 iteration"), so isolation runs
# (iters=1) omit them.
xcodebuild_test() {
  local budget="$1" log="$2" bundle="$3" iters="$4"
  shift 4
  # A string (not an array) so an empty retry set stays bash-3.2-safe under
  # "set -u"; the contents are script-controlled flags without spaces.
  local retry_args=""
  if [ "$iters" -gt 1 ]; then
    retry_args="-retry-tests-on-failure -test-iterations $iters"
  fi
  run_with_deadline "$budget" "$log" \
    test-without-building \
    -xctestrun "$XCRUN_FILE" \
    -destination "$DESTINATION" \
    -resultBundlePath "$bundle" \
    $retry_args \
    -parallel-testing-enabled NO \
    "$@"
}

# Timing extraction is best-effort and must never decide lane correctness.
extract_bundle() { # $1 = xcresult bundle
  python3 "$SCRIPT_DIR/extract-test-timings.py" extract \
    --xcresult "$1" \
    --observations "$RESULT_DIR/observations.json" \
    --detail "$RESULT_DIR/detail.json" \
    >"$LOG_DIR/extract.log" 2>&1
  local st=$?
  if [ "$st" -ne 0 ]; then
    echo "::warning::timing extraction failed safely (exit $st) for lane $LANE; CI continues with previous timing history"
  fi
}

# Number of failed tests in the extraction detail; -1 = unknown.
count_failures() {
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    print(len(d.get('failures', [])))
except Exception:
    print(-1)
" "$RESULT_DIR/detail.json" 2>/dev/null || echo -1
}

# --- lane bookkeeping --------------------------------------------------------
STARTED_AT=$(now_iso)
lane_start=$(date +%s)
RESET_USED=0
ERASE_USED=0
HUNG_CLASS=""

finish_lane() { # $1=status $2=attempts_json $3=isolation_json $4=exit_code
  ACTUAL_S=$(( $(date +%s) - lane_start ))
  local reset_flag="" erase_flag=""
  [ "$RESET_USED" -eq 1 ] && reset_flag="--simulator-reset"
  [ "$ERASE_USED" -eq 1 ] && erase_flag="--simulator-erase"
  # Intentional unquoted expansion of the optional flag variables below.
  python3 "$SCRIPT_DIR/extract-test-timings.py" lane-result \
    --lane "$LANE" --kind "$KIND" --target "$TARGET" --classes "$CLASSES" \
    --status "$1" \
    --predicted-s "$PREDICTED_S" --timeout-s "$TIMEOUT_S" --actual-s "$ACTUAL_S" \
    --started-at "$STARTED_AT" \
    --attempts-json "$2" \
    --isolation-json "$3" \
    --hung-class "$HUNG_CLASS" \
    $reset_flag $erase_flag \
    --observations "$RESULT_DIR/observations.json" \
    --detail "$RESULT_DIR/detail.json" \
    --out "$RESULT_DIR/lane-result.json" || true
  # Bundles are created inside RESULT_DIR, so failed lanes upload them as
  # failure artifacts automatically. Successful lanes have already had their
  # timings extracted - delete the bundles to keep the artifact small.
  if [ "$1" = "pass" ]; then
    rm -rf "$RESULT_DIR"/attempt-*.xcresult "$RESULT_DIR"/iso-*.xcresult 2>/dev/null || true
  fi
  exit "$4"
}

# Class-granular isolation. $1 = attempts JSON prefix, open-ended (no closing
# bracket), e.g. '[{"n": 1, "mode": "lane", "status": "timeout"'. Erase/reset
# must already have been performed by the caller.
run_isolation() {
  echo "::warning::lane $LANE entering class-granular isolation (budget "${ISOLATION_BUDGET_S}"s)"

  # Heaviest estimates first: a hanging class is usually also a slow one, and
  # unknown/new classes go first so unmeasured code is diagnosed before
  # well-understood fast classes. Bounded by ISOLATION_BUDGET_S overall.
  ISOLATION_ORDER=$(CLASSES="$CLASSES" CLASS_ESTIMATES="$CLASS_ESTIMATES" python3 -c "
import os
classes = [c for c in os.environ.get('CLASSES', '').split(',') if c]
est = {}
for pair in os.environ.get('CLASS_ESTIMATES', '').split(','):
    if '=' in pair:
        name, value = pair.split('=', 1)
        try:
            est[name] = float(value)
        except ValueError:
            pass
classes.sort(key=lambda c: (-est.get(c, 1e9), c))
print(chr(10).join(classes))
")

  ISOLATION_LINES="$RESULT_DIR/isolation-classes.txt"
  : > "$ISOLATION_LINES"
  iso_start=$(date +%s)
  for cls in $ISOLATION_ORDER; do
    remaining=$(( ISOLATION_BUDGET_S - ($(date +%s) - iso_start) ))
    if [ "$remaining" -lt 60 ]; then
      echo "$cls|not_diagnosed|0" >> "$ISOLATION_LINES"
      echo "isolation: budget exhausted before $cls"
      continue
    fi
    est="$(estimate_for "$cls" || true)"
    [ -z "$est" ] && est="$DEFAULT_ESTIMATE_S"
    cls_timeout=$(awk -v m="$CLASS_TIMEOUT_MIN_S" -v k="$CLASS_TIMEOUT_MULTIPLIER" -v e="$est" -v r="$remaining" 'BEGIN { t = m; if (e * k > t) t = e * k; if (t > r) t = r; printf "%d", t }')
    cls_start=$(date +%s)
    cstatus=0
    echo "::group::isolation: $cls (budget "${cls_timeout}"s)"
    xcodebuild_test "$cls_timeout" "$LOG_DIR/iso-$cls.log" "$RESULT_DIR/iso-$cls.xcresult" 1 \
      "-only-testing:$TARGET/$cls" || cstatus=$?
    echo "::endgroup::"
    cls_secs=$(( $(date +%s) - cls_start ))
    if [ "$cstatus" -eq 0 ]; then
      echo "$cls|pass|$cls_secs" >> "$ISOLATION_LINES"
    elif [ "$cstatus" -eq 124 ]; then
      echo "$cls|timeout|$cls_secs" >> "$ISOLATION_LINES"
      if [ -z "$HUNG_CLASS" ]; then HUNG_CLASS="$cls"; fi
      echo "::error::isolation: $cls HUNG (exceeded its "${cls_timeout}"s class budget)"
    else
      echo "$cls|fail|$cls_secs" >> "$ISOLATION_LINES"
      echo "::error::isolation: $cls FAILED (exit $cstatus)"
    fi
  done

  ISOLATION_JSON=$(ISOLATION_LINES="$ISOLATION_LINES" ISOLATION_BUDGET_S="$ISOLATION_BUDGET_S" python3 -c "
import json, os
classes = []
with open(os.environ['ISOLATION_LINES']) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        name, status, secs = line.split('|')
        classes.append({'class': name, 'status': status, 'seconds': float(secs)})
print(json.dumps({'budget_s': int(os.environ['ISOLATION_BUDGET_S']), 'classes': classes}))
")

  # Verdict: a class that hung or failed is the lane's identified culprit; if
  # every isolated class passed after the erase, the original event was a
  # transient simulator/environment wedge - recovered, but prominently
  # reported. Any undiagnosed class fails the lane (coverage guarantee).
  if [ -n "$HUNG_CLASS" ]; then
    finish_lane "timeout" "$1"'}, {"mode": "isolation", "status": "hung"}]' "$ISOLATION_JSON" 1
  fi
  if grep -q '|fail|' "$ISOLATION_LINES"; then
    finish_lane "fail" "$1"'}, {"mode": "isolation", "status": "class-failed"}]' "$ISOLATION_JSON" 1
  fi
  if grep -q '|not_diagnosed|' "$ISOLATION_LINES"; then
    echo "::error::lane $LANE isolation ended with undiagnosed classes - failing the lane so the unexecuted tests are visible"
    finish_lane "timeout" "$1"'}, {"mode": "isolation", "status": "incomplete"}]' "$ISOLATION_JSON" 1
  fi
  echo "::warning::lane $LANE: every isolated class passed after erase/reset - original event classified as a recovered transient simulator/environment wedge"
  finish_lane "pass" "$1"'}, {"mode": "isolation", "status": "all-classes-passed"}]' "$ISOLATION_JSON" 0
}

# --- attempt 1 ----------------------------------------------------------------
bounded_run 60 xcrun simctl shutdown all || true  # bounded: a wedged CoreSimulatorService must not stall attempt 1

bundle1="$RESULT_DIR/attempt-1.xcresult"
status1=0
echo "::group::attempt 1 for lane $LANE (budget "${TIMEOUT_S}"s, native flake retry x"${ITERATIONS}")"
xcodebuild_test "$TIMEOUT_S" "$LOG_DIR/attempt-1.log" "$bundle1" "$ITERATIONS" "${ONLY_TESTING[@]}" || status1=$?
echo "::endgroup::"

if [ "$status1" -eq 0 ]; then
  extract_bundle "$bundle1"
  finish_lane "pass" '[{"n": 1, "mode": "lane", "status": "passed"}]' "" 0
fi

extract_bundle "$bundle1"
FAIL_COUNT=$(count_failures)

# Ordinary test failures: never rerun the healthy lane. Native retry already
# re-ran only the failing tests; survivors are real failures.
if [ "$status1" -ne 124 ] && [ "$FAIL_COUNT" -gt 0 ]; then
  echo "lane $LANE: "${FAIL_COUNT}" test(s) failed after native retry"
  finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "test-failures"}]' "" 1
fi

# --- TIMEOUT: diagnose immediately, no second full-lane attempt ---------------
# A watchdog kill is positive identification of a hang (or an environment too
# slow for the lane to finish): erase/reset and go straight to class-granular
# isolation instead of consuming another whole-lane watchdog.
if [ "$status1" -eq 124 ]; then
  echo "::warning::lane $LANE attempt 1 exceeded its "${TIMEOUT_S}"s watchdog - erasing simulator and entering class-granular isolation"
  diag="$LOG_DIR/simctl-devices-after-timeout-attempt-1.txt"
  bounded_run 45 xcrun simctl list devices >"$diag" 2>&1 || true
  RESET_USED=1
  ERASE_USED=1
  reset_and_boot_simulator 1
  run_isolation '[{"n": 1, "mode": "lane", "status": "timeout"'
fi

# --- classify the non-timeout failure ----------------------------------------
# count_failures: >0 ordinary test failures; 0 exited nonzero with every test
# passing (confidently infrastructure); -1 the XCTest result could not be
# classified. Timing/result extraction is best-effort and must never decide
# test correctness, so an unclassifiable failure is NEVER retried into a
# green lane - it fails here.
if [ "$FAIL_COUNT" -eq -1 ]; then
  echo "::error::lane $LANE failed (exit $status1) and its XCTest result could not be classified - failing the lane instead of retrying"
  finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "unclassified"}]' "" 1
fi

bundle2="$RESULT_DIR/attempt-2.xcresult"
status2=0
echo "::group::attempt 2 (post-reset) for lane $LANE"
xcodebuild_test "$TIMEOUT_S" "$LOG_DIR/attempt-2.log" "$bundle2" "$ITERATIONS" "${ONLY_TESTING[@]}" || status2=$?
echo "::endgroup::"

if [ "$status2" -eq 0 ]; then
  extract_bundle "$bundle2"
  finish_lane "pass" '[{"n": 1, "mode": "lane", "status": "infra-recovered"}, {"n": 2, "mode": "lane-retry", "status": "passed"}]' "" 0
fi

extract_bundle "$bundle2"
FAIL_COUNT2=$(count_failures)
if [ "$status2" -eq 124 ]; then
  echo "::warning::lane $LANE retry attempt exceeded its "${TIMEOUT_S}"s watchdog - erasing simulator and entering class-granular isolation"
  diag2="$LOG_DIR/simctl-devices-after-timeout-attempt-2.txt"
  bounded_run 45 xcrun simctl list devices >"$diag2" 2>&1 || true
  RESET_USED=1
  ERASE_USED=1
  reset_and_boot_simulator 1
  run_isolation '[{"n": 1, "mode": "lane", "status": "infra-error"}, {"n": 2, "mode": "lane-retry", "status": "timeout"'
fi

if [ "$FAIL_COUNT2" -gt 0 ]; then
  echo "lane $LANE: "${FAIL_COUNT2}" test(s) failed after reset retry"
  finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "infra-error"}, {"n": 2, "mode": "lane-retry", "status": "test-failures"}]' "" 1
fi

if [ "$FAIL_COUNT2" -eq -1 ]; then
  echo "::error::lane $LANE failed again (exit $status2) and its XCTest result could not be classified - failing the lane without further retry"
  finish_lane "error" '[{"n": 1, "mode": "lane", "status": "infra-error"}, {"n": 2, "mode": "lane-retry", "status": "unclassified"}]' "" 1
fi

echo "::error::lane $LANE failed twice with zero failing tests (exit $status1, then $status2) - runner/simulator environment failure"
finish_lane "error" '[{"n": 1, "mode": "lane", "status": "infra-error"}, {"n": 2, "mode": "lane-retry", "status": "infra-error"}]' "" 1