#!/usr/bin/env bash
#
# CI v2 lane runner: execute ONE dynamically planned test lane from the shared
# build products (test-without-building; never rebuilds).
#
# Unit lanes run all assigned classes in one xcodebuild invocation. UI lanes
# are DIFFERENT: each UI class is its own xcodebuild invocation under its own
# per-class watchdog (budgets planned by plan-tests.py), so one hung class can
# never hold the rest of the suite hostage and failure is attributed - and
# retried - at class granularity.
#
# Failure-domain policy (docs/CI.md):
#   1. Ordinary test failures never rerun healthy work. Unit attempt 1 runs
#      with Xcode-native flake retry (-retry-tests-on-failure -test-iterations N),
#      which re-executes only the failing tests. If failures survive those
#      iterations the lane fails with the failing tests identified - the
#      healthy classes are never rerun. UI classes get one TARGETED retry of
#      just the failed class; passing classes are never re-executed.
#   2. An invocation whose XCTest result CANNOT be classified (timing/result
#      extraction failed) is a FAILURE. Timing extraction is best-effort and
#      must never decide test correctness, so an unclassifiable failure is
#      never retried into a green lane.
#   3. An invocation that exits nonzero with a KNOWN zero failing-test count
#      is confidently an infrastructure failure (simulator crash, runner
#      exit, ...): reset the simulator once and retry. Units retry the whole
#      lane (it is one invocation); a UI lane retries only the affected
#      class. If a retry times out, it falls through to hang handling (4).
#   4. A watchdog timeout is positive identification of a hang. Units erase
#      and enter lane-level class-granular isolation (heaviest estimate
#      first, bounded by the isolation budget, stopping at the first
#      confirmed class-level hang). UI classes are already isolated: the
#      simulator is erased and the SAME class retries once under its own
#      budget; a second timeout names the hung class, fails the lane, and
#      later classes are recorded as not_diagnosed so a contaminated
#      simulator cannot produce misleading secondary failures.
#
# Every simctl operation is deadline-bounded (ci-lib.sh). Bash 3.2 compatible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ci-lib.sh"

KIND=""; LANE=""; TARGET=""; CLASSES=""; CLASS_ESTIMATES=""
CLASS_TIMEOUTS=""; PREDICTED_S=""; TIMEOUT_S=""; ITERATIONS="3"; XCRUN_FILE=""; RESULT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND="$2"; shift 2 ;;
    --lane) LANE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --classes) CLASSES="$2"; shift 2 ;;
    --class-estimates) CLASS_ESTIMATES="$2"; shift 2 ;;
    --class-timeouts) CLASS_TIMEOUTS="$2"; shift 2 ;;
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
# UI lanes enforce per-class watchdogs; a missing budget table would silently
# downgrade them to no enforcement, so it is a hard argument there.
if [ "$KIND" = "ui" ] && [ -z "$CLASS_TIMEOUTS" ]; then
  echo "::error::--class-timeouts is required for --kind ui (planned per-class watchdog budgets)"
  exit 2
fi
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
# Per-class UI watchdog fallbacks (the planner normally supplies explicit
# budgets via --class-timeouts; these only cover a hand-run lane).
UI_CLASS_TIMEOUT_MIN_S="${UI_CLASS_TIMEOUT_MIN_S:-420}"
UI_CLASS_TIMEOUT_MULTIPLIER="${UI_CLASS_TIMEOUT_MULTIPLIER:-3.0}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"

case "$UI_CLASS_TIMEOUT_MIN_S" in
  ''|*[!0-9]*) echo "::error::UI_CLASS_TIMEOUT_MIN_S must be a positive integer, got '$UI_CLASS_TIMEOUT_MIN_S'"; exit 2 ;;
esac
case "$UI_CLASS_TIMEOUT_MULTIPLIER" in
  ''|*[!0-9.]*) echo "::error::UI_CLASS_TIMEOUT_MULTIPLIER must be a positive number, got '$UI_CLASS_TIMEOUT_MULTIPLIER'"; exit 2 ;;
esac

LOG_DIR="$RESULT_DIR/logs"
mkdir -p "$LOG_DIR" "$RESULT_DIR/parts"
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

# Planned per-class watchdog budgets (UI lanes). Same name=value CSV shape as
# the estimates; every value is validated numeric so a malformed table fails
# the lane at startup instead of mid-run.
TM_NAMES=(); TM_VALS=()
if [ -n "$CLASS_TIMEOUTS" ]; then
  PAIRS=()
  IFS=',' read -r -a PAIRS <<< "$CLASS_TIMEOUTS"
  for pair in "${PAIRS[@]}"; do
    name="${pair%%=*}"
    val="${pair#*=}"
    if [ "$name" = "$pair" ]; then
      echo "::error::--class-timeouts entry '$pair' is not name=seconds"
      exit 2
    fi
    case "$val" in
      ''|*[!0-9]*) echo "::error::--class-timeouts value for $name must be a positive integer (seconds), got '$val'"; exit 2 ;;
    esac
    TM_NAMES+=("$name")
    TM_VALS+=("$val")
  done
fi

class_timeout_entry() {
  local i=0
  if [ "${#TM_NAMES[@]}" -eq 0 ]; then
    return 1
  fi
  while [ "$i" -lt "${#TM_NAMES[@]}" ]; do
    if [ "${TM_NAMES[$i]}" = "$1" ]; then
      echo "${TM_VALS[$i]}"
      return 0
    fi
    i=$(( i + 1 ))
  done
  return 1
}

# Effective watchdog for one UI class: the planner's budget when supplied,
# otherwise the same formula over the estimate (floor + multiplier).
ui_budget_for() {
  local planned est
  planned="$(class_timeout_entry "$1" || true)"
  if [ -n "$planned" ]; then
    echo "$planned"
    return 0
  fi
  est="$(estimate_for "$1" || true)"
  [ -z "$est" ] && est="$DEFAULT_ESTIMATE_S"
  # Ceiling like the planner's math.ceil (truncation would shave budget).
  awk -v m="$UI_CLASS_TIMEOUT_MIN_S" -v k="$UI_CLASS_TIMEOUT_MULTIPLIER" -v e="$est" \
    'BEGIN { t = m; if (e * k > t) t = e * k; t = (t == int(t)) ? t : int(t) + 1; printf "%d", t }'
}

# Shared invocation: test-without-building from the downloaded products.
# Extra args (after the 4 named ones) are additional -only-testing filters.
# Native retry flags are only valid with more than one iteration ("Must
# specify -test-iterations with more than 1 iteration"), so isolation runs
# and every UI class invocation (iters=1) omit them - UI flake retry is the
# runner's single targeted class retry, not a native multi-iteration run.
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
# $1 = xcresult bundle, $2 = observations out, $3 = detail out, $4 = log out.
extract_bundle() {
  python3 "$SCRIPT_DIR/extract-test-timings.py" extract \
    --xcresult "$1" \
    --observations "$2" \
    --detail "$3" \
    >"$4" 2>&1
  local st=$?
  if [ "$st" -ne 0 ]; then
    echo "::warning::timing extraction failed safely (exit $st) for lane $LANE; CI continues with previous timing history"
  fi
}

# Number of failed tests in an extraction detail file; -1 = unknown/unclassified.
count_failures() {
  python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    print(len(d.get('failures', [])))
except Exception:
    print(-1)
" "$1" 2>/dev/null || echo -1
}

# --- lane bookkeeping --------------------------------------------------------
STARTED_AT=$(now_iso)
lane_start=$(date +%s)
RESET_USED=0
ERASE_USED=0
HUNG_CLASS=""

# UI mode records the per-class attempt chain (mode|n|class|status lines) and
# serializes it to JSON at lane finish; unit mode passes JSON directly and
# creates none of these bookkeeping files.
ATTEMPT_LINES="$RESULT_DIR/attempts-lines.txt"
# RETRIED = classes whose targeted retry rescued a TEST failure or timeout
# (runner-level flakes; reported + both attempt bundles kept on a green
# lane). INFRA_RECOVERED = the retry rescued an infrastructure wedge instead
# (reported, but not a test flake; both attempt bundles also kept - the a1
# bundle is the only evidence of the wedge).
RETRIED_LINES="$RESULT_DIR/retried-classes.txt"
INFRA_RECOVERED_LINES="$RESULT_DIR/infra-recovered-classes.txt"
if [ "$KIND" = "ui" ]; then
  : > "$ATTEMPT_LINES"
  : > "$RETRIED_LINES"
  : > "$INFRA_RECOVERED_LINES"
fi

record_attempt() { # $1=mode $2=n $3=class $4=status
  echo "$1|$2|$3|$4" >> "$ATTEMPT_LINES"
}

serialize_attempts() {
  python3 -c "
import json, sys
out = []
with open(sys.argv[1], encoding='utf-8') as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        fields = line.split('|')
        if len(fields) != 4:
            continue
        mode, n, cls, status = fields
        try:
            n = int(n)
        except ValueError:
            continue
        out.append({'mode': mode, 'n': n, 'class': cls, 'status': status})
print(json.dumps(out))
" "$ATTEMPT_LINES" 2>/dev/null || printf '[]'
}

retried_classes_csv() {
  sed '/^$/d' "$RETRIED_LINES" | paste -sd ',' - 2>/dev/null || printf ''
}

infra_recovered_csv() {
  sed '/^$/d' "$INFRA_RECOVERED_LINES" | paste -sd ',' - 2>/dev/null || printf ''
}

# Every class after $1 (the class being stopped on) that never ran must be
# visible as not_diagnosed - unexecuted tests may never masquerade as passed
# or as ordinary failures.
mark_remaining_not_diagnosed() { # $1 = class the lane stopped on
  local seen=0 cls
  for cls in "${CLASSES_ARR[@]}"; do
    if [ "$seen" -eq 1 ]; then
      record_attempt "skipped" 0 "$cls" "not_diagnosed"
      echo "::error::class $cls was NOT executed (lane stopped at $1) - recorded as not_diagnosed"
    fi
    [ "$cls" = "$1" ] && seen=1
  done
}

finish_lane() { # $1=status $2=attempts_json $3=isolation_json $4=exit_code
  ACTUAL_S=$(( $(date +%s) - lane_start ))
  # UI mode: fold the per-class/per-attempt extractions into the lane-level
  # observations/detail documents (last attempt per class wins - on a green
  # lane that is always the passing one). Unit mode wrote them directly.
  if [ "$KIND" = "ui" ]; then
    python3 "$SCRIPT_DIR/extract-test-timings.py" merge-parts \
      --parts-dir "$RESULT_DIR/parts" \
      --observations-out "$RESULT_DIR/observations.json" \
      --detail-out "$RESULT_DIR/detail.json" \
      >>"$LOG_DIR/merge-parts.log" 2>&1 || \
      echo "::warning::timing part merge failed safely for lane $LANE; timing history keeps previous values"
  fi
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
    --retried-classes "$(retried_classes_csv)" \
    --infra-recovered-classes "$(infra_recovered_csv)" \
    --hung-class "$HUNG_CLASS" \
    $reset_flag $erase_flag \
    --observations "$RESULT_DIR/observations.json" \
    --detail "$RESULT_DIR/detail.json" \
    --out "$RESULT_DIR/lane-result.json" || true
  # Bundles are created inside RESULT_DIR, so failed lanes upload them as
  # failure artifacts automatically. Successful lanes have already had their
  # timings extracted - delete the bundles to keep the artifact small, EXCEPT
  # for classes that needed their targeted retry (test-flake OR infra-wedge
  # recovery: both attempt bundles are kept, since the attempt-1 bundle is
  # the only evidence of what needed the retry).
  if [ "$1" = "pass" ]; then
    if [ "$KIND" = "ui" ]; then
      local b base cls
      for b in "$RESULT_DIR"/class-*.xcresult; do
        [ -e "$b" ] || break
        base=$(basename "$b" .xcresult)
        cls=${base#class-}
        cls=${cls%-a[12]}
        if ! grep -qx "$cls" "$RETRIED_LINES" 2>/dev/null \
           && ! grep -qx "$cls" "$INFRA_RECOVERED_LINES" 2>/dev/null; then
          rm -rf "$b"
        fi
      done
    else
      rm -rf "$RESULT_DIR"/attempt-*.xcresult "$RESULT_DIR"/iso-*.xcresult 2>/dev/null || true
    fi
  fi
  exit "$4"
}

# Class-granular isolation. $1 = attempts JSON prefix, open-ended (no closing
# bracket), e.g. '[{"n": 1, "mode": "lane", "status": "timeout"'. Erase/reset
# must already have been performed by the caller. Isolation STOPS at the
# first confirmed class-level hang: the culprit is identified and the
# simulator may be contaminated, so later classes are recorded as
# not_diagnosed instead of being executed on it.
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
      # The culprit is identified and the timed-out invocation may have
      # left the simulator contaminated: stop isolation immediately instead
      # of risking misleading secondary failures on later classes.
      break
    else
      echo "$cls|fail|$cls_secs" >> "$ISOLATION_LINES"
      echo "::error::isolation: $cls FAILED (exit $cstatus)"
    fi
  done

  # Classes never reached (isolation stopped at the confirmed hang, or the
  # budget was spent) are recorded as not_diagnosed so the report shows
  # exactly what was skipped - they must never appear as passed and must
  # never become fake failures.
  for cls in $ISOLATION_ORDER; do
    grep -q "^$cls|" "$ISOLATION_LINES" \
      || echo "$cls|not_diagnosed|0" >> "$ISOLATION_LINES"
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

# --- unit lane: one batched invocation for the whole lane ---------------------
run_unit_lane() {
bounded_run 60 xcrun simctl shutdown all || true  # bounded: a wedged CoreSimulatorService must not stall attempt 1

bundle1="$RESULT_DIR/attempt-1.xcresult"
status1=0
echo "::group::attempt 1 for lane $LANE (budget "${TIMEOUT_S}"s, native flake retry x"${ITERATIONS}")"
xcodebuild_test "$TIMEOUT_S" "$LOG_DIR/attempt-1.log" "$bundle1" "$ITERATIONS" "${ONLY_TESTING[@]}" || status1=$?
echo "::endgroup::"

if [ "$status1" -eq 0 ]; then
  extract_bundle "$bundle1" "$RESULT_DIR/observations.json" "$RESULT_DIR/detail.json" "$LOG_DIR/extract.log"
  finish_lane "pass" '[{"n": 1, "mode": "lane", "status": "passed"}]' "" 0
fi

extract_bundle "$bundle1" "$RESULT_DIR/observations.json" "$RESULT_DIR/detail.json" "$LOG_DIR/extract.log"
FAIL_COUNT=$(count_failures "$RESULT_DIR/detail.json")

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
  extract_bundle "$bundle2" "$RESULT_DIR/observations.json" "$RESULT_DIR/detail.json" "$LOG_DIR/extract.log"
  finish_lane "pass" '[{"n": 1, "mode": "lane", "status": "infra-recovered"}, {"n": 2, "mode": "lane-retry", "status": "passed"}]' "" 0
fi

extract_bundle "$bundle2" "$RESULT_DIR/observations.json" "$RESULT_DIR/detail.json" "$LOG_DIR/extract.log"
FAIL_COUNT2=$(count_failures "$RESULT_DIR/detail.json")
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
}

# --- UI lane: one independent invocation PER CLASS ----------------------------
# Each class runs alone, under its own planned watchdog, and gets at most one
# targeted retry. A pass moves on immediately; a retry pass is reported as a
# runner-level flake (never an indistinguishable clean pass); a class that
# fails both attempts fails the lane while the remaining classes still run;
# a class that hangs twice names the culprit and stops the lane (its
# simulator state is contaminated). The simulator is booted once up front so
# only the first class pays the cold-boot overhead.
run_ui_lane() {
  bounded_run 60 xcrun simctl shutdown all || true
  reset_and_boot_simulator 0

  LANE_FAILED=0
  for cls in "${CLASSES_ARR[@]}"; do
    budget=$(ui_budget_for "$cls")
    obs1="$RESULT_DIR/parts/observations-$cls-a1.json"
    det1="$RESULT_DIR/parts/detail-$cls-a1.json"

    status1=0
    echo "::group::UI class $cls attempt 1 (budget "${budget}"s)"
    xcodebuild_test "$budget" "$LOG_DIR/class-$cls-a1.log" \
      "$RESULT_DIR/class-$cls-a1.xcresult" 1 "-only-testing:$TARGET/$cls" || status1=$?
    echo "::endgroup::"

    if [ "$status1" -ne 0 ] && [ "$status1" -ne 124 ]; then
      # Classify the failure before deciding the retry's recovery actions.
      extract_bundle "$RESULT_DIR/class-$cls-a1.xcresult" "$obs1" "$det1" \
        "$LOG_DIR/extract-$cls-a1.log"
      FAIL_COUNT1=$(count_failures "$det1")
      if [ "$FAIL_COUNT1" -eq -1 ]; then
        echo "::error::UI class $cls failed (exit $status1) and its XCTest result could not be classified - failing the lane instead of retrying"
        record_attempt "class" 1 "$cls" "unclassified"
        mark_remaining_not_diagnosed "$cls"
        finish_lane "fail" "$(serialize_attempts)" "" 1
      fi
    else
      FAIL_COUNT1=""   # timeout: classified without extraction; pass: not needed
    fi

    if [ "$status1" -eq 0 ]; then
      extract_bundle "$RESULT_DIR/class-$cls-a1.xcresult" "$obs1" "$det1" \
        "$LOG_DIR/extract-$cls-a1.log"
      record_attempt "class" 1 "$cls" "passed"
      echo "UI class $cls passed on attempt 1"
      continue
    fi

    # Attempt 1 failed. Recovery: a hang or an infrastructure failure erases
    # the simulator (a hang may have left it contaminated); an ordinary test
    # failure retries as-is - the class is re-executed, nothing else.
    if [ "$status1" -eq 124 ]; then
      a1_status="timeout"
    elif [ "$FAIL_COUNT1" -gt 0 ]; then
      a1_status="test-failures"
    else
      a1_status="infra-error"
    fi
    record_attempt "class" 1 "$cls" "$a1_status"
    if [ "$status1" -eq 124 ]; then
      echo "::warning::UI class $cls exceeded its "${budget}"s watchdog - erasing simulator and retrying this class once"
      bounded_run 45 xcrun simctl list devices >"$LOG_DIR/simctl-devices-after-timeout-$cls-a1.txt" 2>&1 || true
      RESET_USED=1
      ERASE_USED=1
      reset_and_boot_simulator 1
    elif [ "$FAIL_COUNT1" -eq 0 ]; then
      echo "::warning::UI class $cls failed with zero failing tests (exit $status1) - infrastructure failure; erasing simulator and retrying this class once"
      RESET_USED=1
      ERASE_USED=1
      reset_and_boot_simulator 1
    else
      echo "UI class $cls failed ("${FAIL_COUNT1}" test(s) surviving) - targeted retry of this class once"
    fi

    status2=0
    echo "::group::UI class $cls attempt 2 (targeted retry)"
    xcodebuild_test "$budget" "$LOG_DIR/class-$cls-a2.log" \
      "$RESULT_DIR/class-$cls-a2.xcresult" 1 "-only-testing:$TARGET/$cls" || status2=$?
    echo "::endgroup::"

    if [ "$status2" -eq 0 ]; then
      extract_bundle "$RESULT_DIR/class-$cls-a2.xcresult" \
        "$RESULT_DIR/parts/observations-$cls-a2.json" \
        "$RESULT_DIR/parts/detail-$cls-a2.json" \
        "$LOG_DIR/extract-$cls-a2.log"
      record_attempt "class-retry" 2 "$cls" "passed"
      if [ "$a1_status" = "infra-error" ]; then
        echo "$cls" >> "$INFRA_RECOVERED_LINES"
        echo "::warning::UI class $cls passed after its infrastructure retry - environment wedge recovered (not a test flake)"
      else
        # A test failure or a watchdog timeout that a retry rescued is a
        # runner-level flake: it stays visible instead of blending into a
        # clean pass, and both attempt bundles are kept for diagnosis.
        echo "$cls" >> "$RETRIED_LINES"
        echo "::warning::UI class $cls PASSED on its targeted retry - runner-level flake, reported, not hidden"
      fi
      continue
    fi

    if [ "$status2" -eq 124 ]; then
      echo "::error::UI class $cls HUNG again (exceeded its "${budget}"s class budget twice) - it is the identified culprit; failing the lane"
      HUNG_CLASS="$cls"
      record_attempt "class-retry" 2 "$cls" "timeout"
      mark_remaining_not_diagnosed "$cls"
      finish_lane "timeout" "$(serialize_attempts)" "" 1
    fi

    extract_bundle "$RESULT_DIR/class-$cls-a2.xcresult" \
      "$RESULT_DIR/parts/observations-$cls-a2.json" \
      "$RESULT_DIR/parts/detail-$cls-a2.json" \
      "$LOG_DIR/extract-$cls-a2.log"
    FAIL_COUNT2=$(count_failures "$RESULT_DIR/parts/detail-$cls-a2.json")
    if [ "$FAIL_COUNT2" -gt 0 ]; then
      echo "::error::UI class $cls FAILED again ("${FAIL_COUNT2}" test(s)) - failing the lane; remaining classes still run"
      record_attempt "class-retry" 2 "$cls" "test-failures"
      LANE_FAILED=1
      continue
    fi
    if [ "$FAIL_COUNT2" -eq -1 ]; then
      echo "::error::UI class $cls failed again (exit $status2) and its XCTest result could not be classified - failing the lane"
      record_attempt "class-retry" 2 "$cls" "unclassified"
      mark_remaining_not_diagnosed "$cls"
      finish_lane "fail" "$(serialize_attempts)" "" 1
    fi
    echo "::error::UI class $cls failed twice with zero failing tests (exit $status1, then $status2) - runner/simulator environment failure"
    record_attempt "class-retry" 2 "$cls" "infra-error"
    mark_remaining_not_diagnosed "$cls"
    finish_lane "error" "$(serialize_attempts)" "" 1
  done

  if [ "$LANE_FAILED" -eq 1 ]; then
    finish_lane "fail" "$(serialize_attempts)" "" 1
  fi
  finish_lane "pass" "$(serialize_attempts)" "" 0
}

if [ "$KIND" = "ui" ]; then
  run_ui_lane
else
  run_unit_lane
fi
