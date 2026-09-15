#!/usr/bin/env bash
#
# CI v2 lane runner: execute ONE dynamically planned test lane from the shared
# build products (test-without-building; never rebuilds).
#
# Unit lanes run all assigned classes in one xcodebuild invocation. UI lanes
# batch every class of the shard into ONE invocation on the healthy path
# (multiple -only-testing filters), so a successful shard pays Xcode/
# CoreSimulator/test-session startup once instead of once per class. Any
# batch-level failure falls back to per-class diagnosis (each class its own
# invocation under its own planned watchdog), so one hung class can never
# hold the rest of the suite hostage and failure is still attributed - and
# retried - at class granularity; ordinary test failures never even get
# there: they retry ONLY the failed test methods (exact method when the
# xcresult identifies them, the class otherwise) in a single follow-up
# invocation, and healthy classes are never re-executed.
#
# Failure-domain policy (docs/CI.md):
#   1. Ordinary test failures never rerun healthy work. Unit attempt 1 runs
#      with Xcode-native flake retry (-retry-tests-on-failure -test-iterations N),
#      which re-executes only the failing tests. If failures survive those
#      iterations the lane fails with the failing tests identified - the
#      healthy classes are never rerun. UI batches get one TARGETED retry of
#      just the failed tests (methods when identifiable, else classes);
#      passing classes are never re-executed.
#   2. An invocation whose XCTest result CANNOT be classified (timing/result
#      extraction failed) is a FAILURE. Timing extraction is best-effort and
#      must never decide test correctness, so an unclassifiable failure is
#      never retried into a green lane.
#   3. An invocation that exits nonzero with a KNOWN zero failing-test count
#      is confidently an infrastructure failure (simulator crash, runner
#      exit, ...): reset the simulator once and retry. Units retry the whole
#      lane (it is one invocation); a UI batch cannot attribute a wedge to a
#      class, so it erases the simulator and re-runs the affected classes
#      through per-class diagnosis. If a class fails AGAIN as an
#      infrastructure failure there, it is recorded as a persistent
#      infrastructure failure and the lane FAILS - but after a clean
#      simulator reset the remaining classes still run, so one wedged class
#      cannot suppress independent UI coverage. If the simulator recovery
#      itself cannot be trusted (erase failed, UDID unresolvable, boot never
#      completed), later results would be misleading: the lane stops there.
#   4. A watchdog timeout is positive identification of a hang. Units erase
#      and enter lane-level class-granular isolation (heaviest estimate
#      first, bounded by the isolation budget, stopping at the first
#      confirmed class-level hang). A UI batch timeout cannot name the hung
#      class, so it erases and enters the same per-class diagnosis, where a
#      class that hangs twice names the culprit, fails the lane, and stops
#      it (its simulator state is contaminated) while earlier results are
#      kept and later classes are recorded as not_diagnosed so a
#      contaminated simulator cannot produce misleading secondary failures.
#   5. CoreAudio host wedge (any unit lane): a broken hosted audio host is
#      a RUNNER failure, not a property of any test class - it floods the
#      invocation log with AURemoteIO -10851 errors and HAL "skipping
#      cycle due to overload" lines, then starves timing-sensitive
#      assertions or hangs the invocation outright. The host-health
#      classifier (scripts/classify-coreaudio-wedge.py) fires on the
#      strong log signature alone; on the failure path the retry scope is
#      the identified failed classes, on the timeout path it is the whole
#      lane. The simulator is erased and the scope re-runs ONCE on the
#      clean host: a retry pass is an infrastructure recovery, a retry
#      that fails without the signature is a real product failure, and a
#      retry carrying the signature again is a persistent CoreAudio runner
#      failure. There is no second recovery - the wedge path never loops.
#
# UI watchdog budgets are owned by plan-tests.py alone: every UI lane
# receives an explicit per-class budget table (--class-timeouts) and the
# runner refuses to start unless it covers every assigned class - there is
# no fallback formula here to drift from the planner.
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
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"

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

# Watchdog for one UI class. The PLANNER is the single authority for UI
# watchdog policy: the table arrives via --class-timeouts (validated for full
# coverage below), so this is a pure lookup - no fallback formula exists here
# to drift from the planner.
ui_budget_for() {
  local planned
  planned="$(class_timeout_entry "$1" || true)"
  if [ -z "$planned" ]; then
    # Unreachable when the startup coverage check ran; a fatal guard anyway.
    echo "::error::no planned watchdog for UI class $1 - --class-timeouts must cover every assigned class"
    exit 2
  fi
  printf '%s\n' "$planned"
}

# UI lanes may not start unless every assigned class has an explicit planned
# watchdog. A silently missing budget would mean an unenforced invocation.
if [ "$KIND" = "ui" ]; then
  for cls in "${CLASSES_ARR[@]}"; do
    if ! class_timeout_entry "$cls" >/dev/null; then
      echo "::error::UI class $cls has no watchdog in --class-timeouts - refusing to run: plan-tests.py must supply a budget for every assigned class"
      exit 2
    fi
  done
fi

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

# Method-precise retry filters from an extraction detail file: one
# ConduitUITests/Class/testMethod line per non-passing test when the
# xcresult identifies it, ConduitUITests/Class when only the class is known
# (a class-level line subsumes any method-level lines of the same class).
# Anything whose FINAL result is not Passed is retried - Failed, but also
# Crashed/Skipped entries left by an aborted run, so a partial batch can
# never be retried into a false green. Empty output means nothing was
# reliably identifiable.
retry_filter_lines() { # $1 = detail.json
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)
target = sys.argv[2]
class_only = set()
lines = []
for a in d.get('attempts', []):
    if str(a.get('final', '')).lower() == 'passed':
        continue
    cls = a.get('class')
    if not cls:
        continue
    test = a.get('test')
    if test:
        lines.append(target + '/' + cls + '/' + test)
    else:
        class_only.add(cls)
out = []
seen = set()
for line in lines:
    cls = line.split('/')[1]
    if cls in class_only:
        continue
    if line not in seen:
        seen.add(line)
        out.append(line)
for cls in sorted(class_only):
    out.append(target + '/' + cls)
for line in out:
    print(line)
" "$1" "$TARGET" 2>/dev/null || true
}

# Classes with NO attempt records in an extraction detail file: a batch that
# aborted before a class ever started must not be retried into a green lane -
# the unexecuted classes force per-class diagnosis instead.
unexecuted_classes() { # $1 = detail.json
  python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)
seen = set()
for a in d.get('attempts', []):
    cls = a.get('class')
    if cls:
        seen.add(cls)
for cls in sys.argv[2].split(','):
    if cls and cls not in seen:
        print(cls)
" "$1" "$CLASSES" 2>/dev/null || true
}

# Sum of the planned per-class watchdog budgets for the named classes. Used
# as the watchdog of a batched invocation (sum of its members' budgets is a
# safe upper bound: every member budget already covers a full invocation's
# fixed overhead on its own).
sum_of_class_budgets() {
  local total=0 cls budget
  for cls in "$@"; do
    budget=$(ui_budget_for "$cls")
    total=$(( total + budget ))
  done
  echo "$total"
}

# --- lane bookkeeping --------------------------------------------------------
STARTED_AT=$(now_iso)
lane_start=$(date +%s)
RESET_USED=0
ERASE_USED=0
HUNG_CLASS=""
# Set to 1 when a CoreAudio wedge recovery ran: a green lane then keeps both
# attempt bundles (the attempt-1 bundle is the only evidence of the wedge)
# and the wedge metadata travels in lane-result.json.
COREAUDIO_RECOVERY=0
# The attempt-1 classification is the canonical incident record embedded in
# lane-result.json; the retry classification (coreaudio-wedge-retry.json)
# stays a log/artifact-level detail of the persistent-wedge verdict.
COREAUDIO_WEDGE_JSON="$RESULT_DIR/coreaudio-wedge.json"

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
# Classes whose BOTH attempts were infrastructure failures (exit nonzero,
# zero failing tests, no hang): reported as persistent infra failures; the
# lane keeps running the remaining classes.
PERSISTENT_INFRA_LINES="$RESULT_DIR/persistent-infra-classes.txt"
if [ "$KIND" = "ui" ]; then
  : > "$ATTEMPT_LINES"
  : > "$RETRIED_LINES"
  : > "$INFRA_RECOVERED_LINES"
  : > "$PERSISTENT_INFRA_LINES"
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
  [ -f "$RETRIED_LINES" ] || { printf ''; return 0; }
  sed '/^$/d' "$RETRIED_LINES" 2>/dev/null | paste -sd ',' - 2>/dev/null || printf ''
}

infra_recovered_csv() {
  [ -f "$INFRA_RECOVERED_LINES" ] || { printf ''; return 0; }
  sed '/^$/d' "$INFRA_RECOVERED_LINES" 2>/dev/null | paste -sd ',' - 2>/dev/null || printf ''
}

persistent_infra_csv() {
  [ -f "$PERSISTENT_INFRA_LINES" ] || { printf ''; return 0; }
  sed '/^$/d' "$PERSISTENT_INFRA_LINES" 2>/dev/null | paste -sd ',' - 2>/dev/null || printf ''
}

# Every class after $1 (the class the diagnosis stopped on) in the diagnosis
# list ($2 onwards) that never ran must be visible as not_diagnosed -
# unexecuted tests may never masquerade as passed or as ordinary failures.
mark_remaining_not_diagnosed() { # $1 = class the diagnosis stopped on
  local stopped="$1"
  shift
  local seen=0 cls
  for cls in "$@"; do
    if [ "$seen" -eq 1 ]; then
      record_attempt "skipped" 0 "$cls" "not_diagnosed"
      echo "::error::class $cls was NOT executed (lane stopped at $stopped) - recorded as not_diagnosed"
    fi
    [ "$cls" = "$stopped" ] && seen=1
  done
}

# Batch-level failures that abort before ANY per-class result exists: every
# named class is recorded as not_diagnosed. Called with ALL assigned classes
# when nothing attributable ran, or with just the retried classes when a
# retry's simulator recovery failed (healthy batch-passing classes keep
# their recorded results).
mark_all_not_diagnosed() {
  local cls
  for cls in "$@"; do
    record_attempt "skipped" 0 "$cls" "not_diagnosed"
    echo "::error::class $cls was NOT executed - recorded as not_diagnosed"
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
  # Optional flags land in an array (bash 3.2-safe) so the wedge metadata
  # path survives spaces; empty arrays expand to nothing under set -u.
  local extra_args=()
  if [ -f "$COREAUDIO_WEDGE_JSON" ]; then
    extra_args+=(--coreaudio-wedge-json "$COREAUDIO_WEDGE_JSON")
  fi
  # Intentional unquoted expansion of the optional scalar flags below; the
  # array form is quoted.
  python3 "$SCRIPT_DIR/extract-test-timings.py" lane-result \
    --lane "$LANE" --kind "$KIND" --target "$TARGET" --classes "$CLASSES" \
    --status "$1" \
    --predicted-s "$PREDICTED_S" --timeout-s "$TIMEOUT_S" --actual-s "$ACTUAL_S" \
    --started-at "$STARTED_AT" \
    --attempts-json "$2" \
    --isolation-json "$3" \
    --retried-classes "$(retried_classes_csv)" \
    --infra-recovered-classes "$(infra_recovered_csv)" \
    --persistent-infra-classes "$(persistent_infra_csv)" \
    --hung-class "$HUNG_CLASS" \
    $reset_flag $erase_flag "${extra_args[@]:+${extra_args[@]}}" \
    --observations "$RESULT_DIR/observations.json" \
    --detail "$RESULT_DIR/detail.json" \
    --out "$RESULT_DIR/lane-result.json" || true
  # Bundles are created inside RESULT_DIR, so failed lanes upload them as
  # failure artifacts automatically. Successful lanes have already had their
  # timings extracted - delete the bundles to keep the artifact small, EXCEPT
  # for attempts that needed their targeted retry (test-flake OR infra-wedge
  # recovery: both attempt bundles are kept, since the attempt-1 bundle is
  # the only evidence of what needed the retry).
  if [ "$1" = "pass" ]; then
    if [ "$KIND" = "ui" ]; then
      # Batched shard: a clean first-attempt batch leaves no bundle behind;
      # a batch that needed its targeted retry keeps BOTH bundles.
      if [ ! -s "$RETRIED_LINES" ] && [ ! -s "$INFRA_RECOVERED_LINES" ]; then
        rm -rf "$RESULT_DIR"/batch-a*.xcresult 2>/dev/null || true
      fi
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
      # A green unit lane deletes its attempt bundles - EXCEPT when a
      # CoreAudio wedge recovery ran: the attempt-1 bundle is the only
      # evidence of the wedge, and the attempt-2 bundle documents the
      # recovery.
      if [ "$COREAUDIO_RECOVERY" -eq 0 ]; then
        rm -rf "$RESULT_DIR"/attempt-*.xcresult "$RESULT_DIR"/iso-*.xcresult 2>/dev/null || true
      fi
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

# --- CoreAudio host wedge recovery on the FAILURE path (unit lanes) -----------
# A failed unit invocation whose log carries the strong CoreAudio HOST
# signature ran on the known broken hosted-audio-host, no matter which
# classes failed - the wedge poisons timing-sensitive assertions anywhere.
# Recovery: erase the simulator, re-run EVERY identified failed class ONCE
# on the clean host, and finish the lane here:
#   retry passes                      -> lane passes, recovery recorded
#   retry fails without the signature -> real product failure, lane fails
#   retry carries the signature again -> persistent CoreAudio runner failure
#   retry is zero-failure infra / timeout / unclassifiable
#                                     -> lane fails with that classification
# There is no second recovery attempt: a human re-running the lane is the
# escalation path for a persistent fleet wedge. Returns 0 only when the lane
# was fully handled here.
# Fold attempt parts into the lane-level observations/detail. Called before
# EVERY wedge verdict: a red wedge lane must still carry its failures and
# class timings (attempt-1 data when the retry never ran, merged retry data
# otherwise). No-op safe when no parts were staged.
merge_wedge_parts() {
  [ -d "$RESULT_DIR/parts" ] || return 0
  python3 "$SCRIPT_DIR/extract-test-timings.py" merge-parts \
    --parts-dir "$RESULT_DIR/parts" \
    --observations-out "$RESULT_DIR/observations.json" \
    --detail-out "$RESULT_DIR/detail.json" \
    >>"$LOG_DIR/merge-parts.log" 2>&1 || \
    echo "::warning::timing part merge failed safely for lane $LANE; timing history keeps previous values"
}

# --- CoreAudio host recovery on the TIMEOUT path (unit lanes) ----------------
# CoreAudio starvation can hang an invocation instead of failing it. Before
# paying for generic class-granular isolation, consult the same host-health
# classifier on the timed-out invocation's log: a strong signature means the
# environment is already diagnosed, so erase the simulator and retry the
# WHOLE lane once (a timeout yields no reliable per-test attribution - the
# recovery is recorded at lane level, never per class). Any other outcome
# fails the lane without a loop. Returns 1 when the host looks healthy so
# the caller proceeds with the unchanged isolation semantics.
attempt_coreaudio_host_recovery_after_timeout() { # $1 = attempt-1 log
  local a1_log="$1"
  local classifier="$SCRIPT_DIR/classify-coreaudio-wedge.py"
  local verdict=0 statusR=0 SIG_AURIOC=0 SIG_HALC=0 WEDGE_FIELDS="" RETRY_SIG=""
  [ -f "$classifier" ] || return 1
  python3 "$classifier" classify \
    --invocation-log "$a1_log" \
    --min-auremoteio "${COREAUDIO_WEDGE_MIN_AURIOC:-150}" \
    --min-halc-overload "${COREAUDIO_WEDGE_MIN_HALC:-10}" \
    --out "$COREAUDIO_WEDGE_JSON" >"$LOG_DIR/coreaudio-wedge-timeout.log" 2>&1 || verdict=$?
  if [ "$verdict" -eq 2 ]; then
    # The classifier cannot read the timed-out invocation's log: whether the
    # host is poisoned is UNKNOWN, and a timeout yields no test results to
    # attribute - fail closed as unclassified instead of burning isolation.
    echo "::error::lane $LANE CoreAudio host wedge classifier could not run on the timed-out invocation - failing closed as unclassified"
    finish_lane "error" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "unclassified"}]' "" 1
  fi
  [ "$verdict" -eq 0 ] || return 1

  WEDGE_FIELDS=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    doc = json.load(fh)
print('aurioc=' + str(doc.get('signals', {}).get('auremoteio_10851', 0)))
print('halc=' + str(doc.get('signals', {}).get('halc_overload', 0)))
" "$COREAUDIO_WEDGE_JSON" 2>/dev/null || true)
  while IFS= read -r wedge_line; do
    case "$wedge_line" in
      aurioc=*) SIG_AURIOC="${wedge_line#aurioc=}" ;;
      halc=*) SIG_HALC="${wedge_line#halc=}" ;;
    esac
  done <<WEDGE_EOF
$WEDGE_FIELDS
WEDGE_EOF
  COREAUDIO_RECOVERY=1
  echo "::warning::CoreAudio host wedge detected behind the watchdog in lane $LANE: AURemoteIO -10851 occurrences: ${SIG_AURIOC}, HALC overload skips: ${SIG_HALC}"
  echo "action: resetting simulator and retrying the whole lane once (a timeout carries no reliable per-test attribution, so no per-class recovery is claimed)"
  mkdir -p "$RESULT_DIR/parts"
  [ -f "$RESULT_DIR/observations.json" ] && \
    mv "$RESULT_DIR/observations.json" "$RESULT_DIR/parts/observations-lane-a1.json"
  [ -f "$RESULT_DIR/detail.json" ] && \
    mv "$RESULT_DIR/detail.json" "$RESULT_DIR/parts/detail-lane-a1.json"

  RESET_USED=1
  ERASE_USED=1
  if ! reset_and_boot_simulator 1; then
    echo "::error::simulator recovery after the CoreAudio host wedge failed - the environment cannot be trusted; stopping the lane"
    finish_lane "error" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "untrusted-recovery"}]' "" 1
  fi

  statusR=0
  echo "::group::CoreAudio host wedge recovery for lane $LANE (whole lane, budget "${TIMEOUT_S}"s)"
  xcodebuild_test "$TIMEOUT_S" "$LOG_DIR/attempt-2-host-retry.log" \
    "$RESULT_DIR/attempt-2-host-retry.xcresult" 1 "${ONLY_TESTING[@]}" || statusR=$?
  echo "::endgroup::"

  if [ "$statusR" -eq 0 ]; then
    extract_bundle "$RESULT_DIR/attempt-2-host-retry.xcresult" \
      "$RESULT_DIR/parts/observations-lane-a2.json" \
      "$RESULT_DIR/parts/detail-lane-a2.json" \
      "$LOG_DIR/extract-host-retry.log"
    python3 "$SCRIPT_DIR/extract-test-timings.py" merge-parts \
      --parts-dir "$RESULT_DIR/parts" \
      --observations-out "$RESULT_DIR/observations.json" \
      --detail-out "$RESULT_DIR/detail.json" \
      >>"$LOG_DIR/merge-parts.log" 2>&1 || \
      echo "::warning::timing part merge failed safely for lane $LANE; timing history keeps previous values"
    echo "::warning::lane $LANE passed after the CoreAudio host wedge recovery on a clean simulator - infrastructure recovery; no per-test recovery is claimed (the timed-out attempt had no failure attribution)"
    finish_lane "pass" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "passed"}]' "" 0
  fi

  if [ "$statusR" -eq 124 ]; then
    echo "::error::CoreAudio host wedge recovery for lane $LANE exceeded its "${TIMEOUT_S}"s watchdog - failing the lane; rerun the lane when the hosted fleet has recovered"
    merge_wedge_parts
    finish_lane "timeout" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "timeout"}]' "" 1
  fi

  extract_bundle "$RESULT_DIR/attempt-2-host-retry.xcresult" \
    "$RESULT_DIR/parts/observations-lane-a2.json" \
    "$RESULT_DIR/parts/detail-lane-a2.json" \
    "$LOG_DIR/extract-host-retry.log"
  FAIL_COUNT_R=$(count_failures "$RESULT_DIR/parts/detail-lane-a2.json")

  if [ "$FAIL_COUNT_R" -gt 0 ]; then
    verdictR=0
    python3 "$classifier" classify \
      --invocation-log "$LOG_DIR/attempt-2-host-retry.log" \
      --min-auremoteio "${COREAUDIO_WEDGE_MIN_AURIOC:-150}" \
      --min-halc-overload "${COREAUDIO_WEDGE_MIN_HALC:-10}" \
      --out "$RESULT_DIR/coreaudio-wedge-retry.json" \
      >"$LOG_DIR/coreaudio-wedge-attempt2.log" 2>&1 || verdictR=$?
    if [ "$verdictR" -eq 0 ]; then
      RETRY_SIG=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    doc = json.load(fh)
sig = doc.get('signals', {})
print('AURemoteIO -10851 occurrences: {0}, HALC overload skips: {1}'.format(
    sig.get('auremoteio_10851', 0), sig.get('halc_overload', 0)))
" "$RESULT_DIR/coreaudio-wedge-retry.json" 2>/dev/null || echo 'signal counts unavailable')
      echo "::error::persistent CoreAudio runner failure in lane $LANE: the recovery retry carries the same wedge signature ($RETRY_SIG) - the hosted fleet is broken; this is NOT a product test failure"
      finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "persistent-coreaudio-wedge"}]' "" 1
    fi
    if [ "$verdictR" -eq 2 ]; then
      echo "::error::lane $LANE CoreAudio host wedge retry classifier could not run - failing closed as unclassified instead of claiming product failures"
      merge_wedge_parts
      finish_lane "error" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "unclassified"}]' "" 1
    fi
    echo "lane $LANE: tests FAILED on the clean-host retry without the wedge signature - real product failures"
    merge_wedge_parts
    finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "test-failures"}]' "" 1
  fi

  if [ "$FAIL_COUNT_R" -eq -1 ]; then
    echo "::error::lane $LANE CoreAudio host wedge recovery failed (exit $statusR) and its XCTest result could not be classified - failing the lane instead of retrying"
    merge_wedge_parts
    finish_lane "error" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "unclassified"}]' "" 1
  fi

  merge_wedge_parts
  echo "::error::lane $LANE CoreAudio host wedge recovery exited nonzero with zero failing tests (exit $statusR) - persistent infrastructure failure after the clean-host reset"
  finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "host-wedge-timeout"}, {"n": 2, "mode": "host-retry", "status": "infra-error"}]' "" 1
}

attempt_coreaudio_wedge_recovery() { # $1=attempt1 log $2=attempt1 detail
  local a1_log="$1" a1_detail="$2"
  local classifier="$SCRIPT_DIR/classify-coreaudio-wedge.py"
  local verdict=0 verdictR=0 statusR=0 FAIL_COUNT_R="" WEDGE_FIELDS="" \
    AFFECTED_CLASSES="" SIG_AURIOC=0 SIG_HALC=0 RETRY_SIG=""
  [ -f "$classifier" ] || return 1
  python3 "$classifier" classify \
    --invocation-log "$a1_log" \
    --min-auremoteio "${COREAUDIO_WEDGE_MIN_AURIOC:-150}" \
    --min-halc-overload "${COREAUDIO_WEDGE_MIN_HALC:-10}" \
    --out "$COREAUDIO_WEDGE_JSON" >"$LOG_DIR/coreaudio-wedge-attempt1.log" 2>&1 || verdict=$?
  if [ "$verdict" -eq 2 ]; then
    echo "::warning::CoreAudio wedge classifier could not run - treating the failure as a product failure (fail closed)"
    return 1
  fi
  if [ "$verdict" -ne 0 ]; then
    # Host healthy: ordinary product failure. The classification document is
    # still kept so signal counts are visible for recalibration.
    echo "lane $LANE: failure not classified as a CoreAudio host wedge - see $COREAUDIO_WEDGE_JSON for signal counts"
    return 1
  fi

  # One parse of the classification document; the classifier owns the schema
  # and prints shell-assignable key=value lines (values are classifier-owned
  # tokens, never user input).
  SIG_AURIOC=0
  SIG_HALC=0
  WEDGE_FIELDS=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    doc = json.load(fh)
print('aurioc=' + str(doc.get('signals', {}).get('auremoteio_10851', 0)))
print('halc=' + str(doc.get('signals', {}).get('halc_overload', 0)))
" "$COREAUDIO_WEDGE_JSON" 2>/dev/null || true)
  while IFS= read -r wedge_line; do
    case "$wedge_line" in
      aurioc=*) SIG_AURIOC="${wedge_line#aurioc=}" ;;
      halc=*) SIG_HALC="${wedge_line#halc=}" ;;
    esac
  done <<WEDGE_EOF
$WEDGE_FIELDS
WEDGE_EOF

  # Retry scope: EVERY identified failed class - the wedge poisons any
  # timing-sensitive assertion, so the inventory of the failure is the
  # extraction, not a class list. A failure record without a usable class
  # cannot be scoped, so it fails closed as unclassified instead of
  # authorizing a subset retry.
  AFFECTED_CLASSES=$(python3 "$classifier" scope --detail "$a1_detail" 2>/dev/null) || {
    # An unattributable failure record cannot be scoped for the retry, and
    # it must not be silently omitted: fail closed as unclassified (the
    # lane-level extraction is still in place here - nothing was moved).
    echo "::error::lane $LANE CoreAudio host wedge retry scope could not be derived (unattributable failure record) - failing closed as unclassified"
    finish_lane "error" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "unclassified"}]' "" 1
  }
  if [ -z "$AFFECTED_CLASSES" ]; then
    return 1
  fi
  COREAUDIO_RECOVERY=1
  echo "::warning::CoreAudio host wedge detected in lane $LANE: AURemoteIO -10851 occurrences: ${SIG_AURIOC}, HALC overload skips: ${SIG_HALC}"
  echo "::warning::affected tests: $(printf '%s ' $AFFECTED_CLASSES)"
  echo "action: resetting simulator and retrying affected tests"
  # Stamp the retry scope into the incident record: a red wedge-retry lane
  # must still name what the recovery attempted.
  python3 -c "
import json, sys
path, scope = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as fh:
    doc = json.load(fh)
doc['affected_classes'] = scope.split()
with open(path, 'w', encoding='utf-8', newline='
') as fh:
    fh.write(json.dumps(doc, indent=2, sort_keys=True) + '
')
" "$COREAUDIO_WEDGE_JSON" "$AFFECTED_CLASSES" 2>/dev/null || true

  # The attempt-1 extraction already sits in observations.json/detail.json;
  # move it into parts/ so the post-retry merge-parts fold keeps attempt-1
  # results for the healthy classes and lets attempt-2 own the affected ones.
  mkdir -p "$RESULT_DIR/parts"
  [ -f "$RESULT_DIR/observations.json" ] &&     mv "$RESULT_DIR/observations.json" "$RESULT_DIR/parts/observations-lane-a1.json"
  [ -f "$RESULT_DIR/detail.json" ] &&     mv "$RESULT_DIR/detail.json" "$RESULT_DIR/parts/detail-lane-a1.json"

  RESET_USED=1
  ERASE_USED=1
  if ! reset_and_boot_simulator 1; then
    echo "::error::simulator recovery after the CoreAudio wedge failed - the environment cannot be trusted; stopping the lane"
    merge_wedge_parts
    finish_lane "error" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "untrusted-recovery"}]' "" 1
  fi

  RETRY_FILTERS=()
  for cls in $AFFECTED_CLASSES; do
    # Class identifiers are alphanumeric/underscore; anything else in the
    # scope would inject arguments into the retry invocation - fail closed
    # instead.
    case "$cls" in ''|*[!A-Za-z0-9_]*)
      echo "::error::lane $LANE wedge retry scope contains an invalid class token ('$cls') - failing closed as unclassified"
      merge_wedge_parts
      finish_lane "error" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "unclassified"}]' "" 1
      ;;
    esac
    RETRY_FILTERS+=("-only-testing:$TARGET/$cls")
  done

  statusR=0
  echo "::group::CoreAudio wedge recovery for lane $LANE (only the affected classes, budget "${TIMEOUT_S}"s)"
  xcodebuild_test "$TIMEOUT_S" "$LOG_DIR/attempt-2-audio-retry.log" \
    "$RESULT_DIR/attempt-2-audio-retry.xcresult" 1 "${RETRY_FILTERS[@]}" || statusR=$?
  echo "::endgroup::"

  if [ "$statusR" -eq 0 ]; then
    extract_bundle "$RESULT_DIR/attempt-2-audio-retry.xcresult" \
      "$RESULT_DIR/parts/observations-lane-a2.json" \
      "$RESULT_DIR/parts/detail-lane-a2.json" \
      "$LOG_DIR/extract-audio-retry.log"
    merge_wedge_parts
    # Bookkeeping lives HERE, not at classification time: only a retry that
    # actually passed was "recovered"; every red path below must leave
    # infra_recovered_classes empty so a failed lane never claims recovery.
    for wedge_cls in $AFFECTED_CLASSES; do
      echo "$wedge_cls" >> "$INFRA_RECOVERED_LINES"
    done
    echo "::warning::lane $LANE passed after the CoreAudio wedge recovery on a clean simulator - infrastructure recovery, not a test flake; affected classes: $(printf '%s' "$AFFECTED_CLASSES" | tr ' ' ',')"
    finish_lane "pass" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "passed"}]' "" 0
  fi

  if [ "$statusR" -eq 124 ]; then
    # The recovery itself hung: no second recovery, no isolation loop - the
    # affected classes were already running alone on a fresh simulator.
    echo "::error::CoreAudio wedge recovery for lane $LANE exceeded its "${TIMEOUT_S}"s watchdog - failing the lane; rerun the lane when the hosted fleet has recovered"
    merge_wedge_parts
    finish_lane "timeout" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "timeout"}]' "" 1
  fi

  extract_bundle "$RESULT_DIR/attempt-2-audio-retry.xcresult" \
    "$RESULT_DIR/parts/observations-lane-a2.json" \
    "$RESULT_DIR/parts/detail-lane-a2.json" \
    "$LOG_DIR/extract-audio-retry.log"
  FAIL_COUNT_R=$(count_failures "$RESULT_DIR/parts/detail-lane-a2.json")
  merge_wedge_parts

  if [ "$FAIL_COUNT_R" -gt 0 ]; then
    verdictR=0
    python3 "$classifier" classify \
      --invocation-log "$LOG_DIR/attempt-2-audio-retry.log" \
      --min-auremoteio "${COREAUDIO_WEDGE_MIN_AURIOC:-150}" \
      --min-halc-overload "${COREAUDIO_WEDGE_MIN_HALC:-10}" \
      --out "$RESULT_DIR/coreaudio-wedge-retry.json" \
      >"$LOG_DIR/coreaudio-wedge-attempt2.log" 2>&1 || verdictR=$?
    if [ "$verdictR" -eq 0 ]; then
      RETRY_SIG=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    doc = json.load(fh)
sig = doc.get('signals', {})
print('AURemoteIO -10851 occurrences: {0}, HALC overload skips: {1}'.format(
    sig.get('auremoteio_10851', 0), sig.get('halc_overload', 0)))
" "$RESULT_DIR/coreaudio-wedge-retry.json" 2>/dev/null || echo 'signal counts unavailable')
      echo "::error::persistent CoreAudio runner failure in lane $LANE: the recovery retry carries the same wedge signature ($RETRY_SIG) - the hosted fleet is broken; this is NOT a product test failure"
      finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "persistent-coreaudio-wedge"}]' "" 1
    fi
    if [ "$verdictR" -eq 2 ]; then
      # The classifier could not read the retry inputs: whether the clean
      # host still carries the wedge signature is UNKNOWN, so the failures
      # must not be labelled product failures (fail closed).
      echo "::error::lane $LANE CoreAudio wedge retry classifier could not run - failing closed as unclassified instead of claiming product failures"
      finish_lane "error" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "unclassified"}]' "" 1
    fi
    echo "lane $LANE: affected classes FAILED on the clean-host retry without the wedge signature - real product failures"
    finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "test-failures"}]' "" 1
  fi

  if [ "$FAIL_COUNT_R" -eq -1 ]; then
    echo "::error::lane $LANE CoreAudio wedge recovery failed (exit $statusR) and its XCTest result could not be classified - failing the lane instead of retrying"
    finish_lane "error" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "unclassified"}]' "" 1
  fi

  echo "::error::lane $LANE CoreAudio wedge recovery exited nonzero with zero failing tests (exit $statusR) - persistent infrastructure failure after the clean-host reset"
  finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "audio-wedge"}, {"n": 2, "mode": "audio-retry", "status": "infra-error"}]' "" 1
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
# re-ran only the failing tests; survivors are real failures - UNLESS the
# host-health classifier detects the CoreAudio host wedge (strong log
# signature alone - the wedge is the runner's failure, whatever classes
# happened to break), in which case attempt_coreaudio_wedge_recovery
# finishes the lane itself.
if [ "$status1" -ne 124 ] && [ "$FAIL_COUNT" -gt 0 ]; then
  echo "lane $LANE: "${FAIL_COUNT}" test(s) failed after native retry"
  # The recovery path finishes the lane in every branch it enters; a
  # spurious return still falls through to the real-failure verdict below,
  # so the wedge path can never end in a green lane by accident.
  attempt_coreaudio_wedge_recovery "$LOG_DIR/attempt-1.log" "$RESULT_DIR/detail.json" || true
  finish_lane "fail" '[{"n": 1, "mode": "lane", "status": "test-failures"}]' "" 1
fi

# --- TIMEOUT: diagnose immediately, no second full-lane attempt ---------------
# A watchdog kill is positive identification of a hang (or an environment too
# slow for the lane to finish): erase/reset and go straight to class-granular
# isolation instead of consuming another whole-lane watchdog.
if [ "$status1" -eq 124 ]; then
  echo "::warning::lane $LANE attempt 1 exceeded its "${TIMEOUT_S}"s watchdog"
  diag="$LOG_DIR/simctl-devices-after-timeout-attempt-1.txt"
  bounded_run 45 xcrun simctl list devices >"$diag" 2>&1 || true
  # Host first: when the timed-out invocation's log already proves the
  # audio host is poisoned, erase and retry the lane once instead of
  # burning the budget on a generic isolation pass. The recovery finishes
  # the lane in every branch it enters; a decline falls through to the
  # unchanged isolation below.
  attempt_coreaudio_host_recovery_after_timeout "$LOG_DIR/attempt-1.log" || true
  echo "::warning::lane $LANE watchdog was not a CoreAudio host wedge - erasing simulator and entering class-granular isolation"
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

# --- UI lane: one batched invocation per shard on the healthy path ------------
# Every class of the shard runs in ONE xcodebuild invocation (multiple
# -only-testing filters), so a healthy shard pays the Xcode/CoreSimulator/
# test-session startup and result finalization once instead of once per
# class. Recovery never re-executes healthy work:
#   * ordinary test failures  -> one targeted retry invocation of ONLY the
#     non-passing tests (final results other than Passed - exact methods
#     when the xcresult identifies them, else their classes); a passing
#     retry stays a reported flake;
#   * watchdog timeout or infrastructure wedge -> erase the simulator and
#     re-run the affected classes through run_class_diagnosis, which keeps
#     the original per-class failure-domain properties (per-class watchdogs,
#     one retry, hang attribution).
run_ui_lane() {
  bounded_run 60 xcrun simctl shutdown all || true
  reset_and_boot_simulator 0

  batch_budget=$(sum_of_class_budgets "${CLASSES_ARR[@]}")
  status1=0
  echo "::group::UI shard $LANE batch attempt 1 ("${#CLASSES_ARR[@]}" classes in one invocation, budget "${batch_budget}"s)"
  xcodebuild_test "$batch_budget" "$LOG_DIR/batch-a1.log" \
    "$RESULT_DIR/batch-a1.xcresult" 1 "${ONLY_TESTING[@]}" || status1=$?
  echo "::endgroup::"

  if [ "$status1" -ne 0 ] && [ "$status1" -ne 124 ]; then
    # Classify the failure before deciding the retry's recovery actions.
    extract_bundle "$RESULT_DIR/batch-a1.xcresult" \
      "$RESULT_DIR/parts/observations-batch-a1.json" \
      "$RESULT_DIR/parts/detail-batch-a1.json" \
      "$LOG_DIR/extract-batch-a1.log"
    FAIL_COUNT1=$(count_failures "$RESULT_DIR/parts/detail-batch-a1.json")
    if [ "$FAIL_COUNT1" -eq -1 ]; then
      echo "::error::UI shard $LANE batch failed (exit $status1) and its XCTest result could not be classified - failing the lane instead of retrying"
      record_attempt "batch" 1 "all" "unclassified"
      mark_all_not_diagnosed "${CLASSES_ARR[@]}"
      finish_lane "fail" "$(serialize_attempts)" "" 1
    fi
  else
    FAIL_COUNT1=""   # timeout: classified without extraction; pass: not needed
  fi

  if [ "$status1" -eq 0 ]; then
    extract_bundle "$RESULT_DIR/batch-a1.xcresult" \
      "$RESULT_DIR/parts/observations-batch-a1.json" \
      "$RESULT_DIR/parts/detail-batch-a1.json" \
      "$LOG_DIR/extract-batch-a1.log"
    # Defense in depth: exit 0 should imply every -only-testing filter
    # executed; if a parseable detail proves an assigned class left no
    # record, do not trust the exit code - diagnose like any other batch
    # that cannot account for its classes. An unreadable detail degrades to
    # the pass (the gate reports nothing).
    MISSING_CLASSES=$(unexecuted_classes "$RESULT_DIR/parts/detail-batch-a1.json")
    if [ -z "$MISSING_CLASSES" ]; then
      record_attempt "batch" 1 "all" "passed"
      echo "UI shard $LANE: batch of "${#CLASSES_ARR[@]}" classes passed in one invocation"
      finish_lane "pass" "$(serialize_attempts)" "" 0
    fi
    record_attempt "batch" 1 "all" "incomplete"
    DIAGNOSIS_REASON="batch exit 0 without any record of $(printf '%s ' $MISSING_CLASSES)"
    echo "::warning::UI shard $LANE batch exited 0 but the xcresult has no record of $(printf '%s ' $MISSING_CLASSES)- erasing simulator and entering per-class diagnosis"
    RESET_USED=1
    ERASE_USED=1
    if ! reset_and_boot_simulator 1; then
      echo "::error::simulator recovery after the incomplete batch failed - the environment cannot be trusted; stopping the lane"
      mark_all_not_diagnosed "${CLASSES_ARR[@]}"
      finish_lane "error" "$(serialize_attempts)" "" 1
    fi
    run_class_diagnosis "${CLASSES_ARR[@]}"
  fi

  # --- batch timed out: no per-class attribution, diagnose class-by-class ----
  if [ "$status1" -eq 124 ]; then
    record_attempt "batch" 1 "all" "timeout"
    DIAGNOSIS_REASON="batch watchdog timeout"
    echo "::warning::UI shard $LANE batch exceeded its "${batch_budget}"s watchdog - erasing simulator and entering per-class diagnosis"
    bounded_run 45 xcrun simctl list devices >"$LOG_DIR/simctl-devices-after-timeout-batch-a1.txt" 2>&1 || true
    RESET_USED=1
    ERASE_USED=1
    if ! reset_and_boot_simulator 1; then
      echo "::error::simulator recovery after the batch timeout failed - the environment cannot be trusted; stopping the lane"
      mark_all_not_diagnosed "${CLASSES_ARR[@]}"
      finish_lane "error" "$(serialize_attempts)" "" 1
    fi
    run_class_diagnosis "${CLASSES_ARR[@]}"
  fi

  # --- batch infra wedge: zero identified failures, nonzero exit -----------
  # A batch cannot attribute a wedge to a class: erase the simulator and
  # re-run the whole shard through per-class diagnosis, which keeps the
  # per-class watchdog, retry, and hang-attribution properties.
  if [ "$status1" -ne 0 ] && [ "$FAIL_COUNT1" -eq 0 ]; then
    record_attempt "batch" 1 "all" "infra-error"
    DIAGNOSIS_REASON="batch infrastructure failure (exit $status1, zero failing tests)"
    echo "::warning::UI shard $LANE batch failed with zero failing tests (exit $status1) - infrastructure failure; erasing simulator and entering per-class diagnosis"
    RESET_USED=1
    ERASE_USED=1
    if ! reset_and_boot_simulator 1; then
      echo "::error::simulator recovery after the batch infrastructure failure failed - the environment cannot be trusted; stopping the lane"
      mark_all_not_diagnosed "${CLASSES_ARR[@]}"
      finish_lane "error" "$(serialize_attempts)" "" 1
    fi
    run_class_diagnosis "${CLASSES_ARR[@]}"
  fi

  # --- ordinary test failures: retry ONLY the failed tests --------------------
  # Method-level when the xcresult identifies the test (the extraction's
  # failure records carry class + test), class-level otherwise. Healthy
  # classes are never re-executed, so a single failure can never grow into a
  # shard-wide rerun.
  RETRY_LINES=$(retry_filter_lines "$RESULT_DIR/parts/detail-batch-a1.json")
  if [ -z "$RETRY_LINES" ]; then
    echo "::error::UI shard $LANE had "${FAIL_COUNT1}" failing test(s) but none could be identified from the xcresult - failing the lane"
    record_attempt "batch" 1 "all" "unclassified"
    finish_lane "fail" "$(serialize_attempts)" "" 1
  fi

  # A batch that aborted before a class ever started must not be retried
  # into a green lane: any assigned class without an attempt record forces
  # a full per-class diagnosis pass instead of the targeted retry.
  MISSING_CLASSES=$(unexecuted_classes "$RESULT_DIR/parts/detail-batch-a1.json")
  if [ -n "$MISSING_CLASSES" ]; then
    record_attempt "batch" 1 "all" "incomplete"
    DIAGNOSIS_REASON="batch aborted before executing $(printf '%s ' $MISSING_CLASSES)"
    echo "::warning::UI shard $LANE batch aborted before executing $(printf '%s ' $MISSING_CLASSES)- erasing simulator and entering per-class diagnosis"
    RESET_USED=1
    ERASE_USED=1
    if ! reset_and_boot_simulator 1; then
      echo "::error::simulator recovery after the incomplete batch failed - the environment cannot be trusted; stopping the lane"
      mark_all_not_diagnosed "${CLASSES_ARR[@]}"
      finish_lane "error" "$(serialize_attempts)" "" 1
    fi
    run_class_diagnosis "${CLASSES_ARR[@]}"
  fi

  RETRY_FILTERS=()
  while IFS= read -r filter; do
    [ -n "$filter" ] && RETRY_FILTERS+=("-only-testing:$filter")
  done <<EOF
$RETRY_LINES
EOF
  if [ "${#RETRY_FILTERS[@]}" -eq 0 ]; then
    # Unreachable via retry_filter_lines (it only prints non-empty lines),
    # but an empty array expansion would crash bash 3.2 under set -u.
    echo "::error::UI shard $LANE could not build retry filters for "${FAIL_COUNT1}" identified failure(s) - failing the lane"
    record_attempt "batch" 1 "all" "unclassified"
    finish_lane "fail" "$(serialize_attempts)" "" 1
  fi
  RETRY_CLASSES=$(printf '%s\n' "$RETRY_LINES" | awk -F/ '{print $2}' | sort -u)
  retry_budget=$(sum_of_class_budgets $RETRY_CLASSES)
  record_attempt "batch" 1 "all" "test-failures"
  echo "UI shard $LANE: "${FAIL_COUNT1}" test(s) failed - targeted retry of only the failed tests ("$(printf '%s ' $RETRY_FILTERS)")"

  status2=0
  echo "::group::UI shard $LANE targeted retry (budget "${retry_budget}"s)"
  xcodebuild_test "$retry_budget" "$LOG_DIR/batch-a2.log" \
    "$RESULT_DIR/batch-a2.xcresult" 1 "${RETRY_FILTERS[@]}" || status2=$?
  echo "::endgroup::"

  if [ "$status2" -eq 0 ]; then
    extract_bundle "$RESULT_DIR/batch-a2.xcresult" \
      "$RESULT_DIR/parts/observations-batch-a2.json" \
      "$RESULT_DIR/parts/detail-batch-a2.json" \
      "$LOG_DIR/extract-batch-a2.log"
    # The retry reran only the failed METHODS, so its observations carry
    # method-only durations per class - the batch attempt owns class timing,
    # so the retry's observations must not fold into the timing history.
    rm -f "$RESULT_DIR/parts/observations-batch-a2.json"
    record_attempt "batch-retry" 2 "all" "passed"
    for cls in $RETRY_CLASSES; do
      echo "$cls" >> "$RETRIED_LINES"
    done
    # A test failure that a retry rescued is a runner-level flake: it stays
    # visible instead of blending into a clean pass, and both attempt
    # bundles are kept for diagnosis.
    echo "::warning::UI shard $LANE passed on its targeted retry - runner-level flake. Retried tests: $(printf '%s' "$RETRY_LINES" | tr '\n' ' ')- only the non-passing tests were re-run; reported, not hidden"
    finish_lane "pass" "$(serialize_attempts)" "" 0
  fi

  if [ "$status2" -eq 124 ]; then
    record_attempt "batch-retry" 2 "all" "timeout"
    DIAGNOSIS_REASON="targeted retry watchdog timeout"
    echo "::warning::UI shard $LANE targeted retry exceeded its "${retry_budget}"s watchdog - erasing simulator and entering per-class diagnosis of the retried classes"
    RESET_USED=1
    ERASE_USED=1
    if ! reset_and_boot_simulator 1; then
      echo "::error::simulator recovery after the retry timeout failed - the environment cannot be trusted; stopping the lane"
      mark_all_not_diagnosed $RETRY_CLASSES
      finish_lane "error" "$(serialize_attempts)" "" 1
    fi
    run_class_diagnosis $RETRY_CLASSES
  fi

  extract_bundle "$RESULT_DIR/batch-a2.xcresult" \
    "$RESULT_DIR/parts/observations-batch-a2.json" \
    "$RESULT_DIR/parts/detail-batch-a2.json" \
    "$LOG_DIR/extract-batch-a2.log"
  rm -f "$RESULT_DIR/parts/observations-batch-a2.json"
  FAIL_COUNT2=$(count_failures "$RESULT_DIR/parts/detail-batch-a2.json")
  if [ "$FAIL_COUNT2" -gt 0 ]; then
    echo "::error::UI shard $LANE tests FAILED again on the targeted retry ("${FAIL_COUNT2}" test(s) - real failures, not flakes) - failing the lane"
    record_attempt "batch-retry" 2 "all" "test-failures"
    finish_lane "fail" "$(serialize_attempts)" "" 1
  fi
  if [ "$FAIL_COUNT2" -eq -1 ]; then
    echo "::error::UI shard $LANE targeted retry failed (exit $status2) and its XCTest result could not be classified - failing the lane"
    record_attempt "batch-retry" 2 "all" "unclassified"
    finish_lane "fail" "$(serialize_attempts)" "" 1
  fi

  # Nonzero exit with a known zero failing-test count and no timeout: the
  # retry itself wedged on the environment. A batch cannot attribute a wedge
  # to a class, so erase and diagnose the retried classes one by one.
  record_attempt "batch-retry" 2 "all" "infra-error"
  DIAGNOSIS_REASON="targeted retry infrastructure failure (exit $status2, zero failing tests)"
  echo "::warning::UI shard $LANE targeted retry hit an infrastructure failure (exit $status2, zero failing tests) - erasing simulator and entering per-class diagnosis of the retried classes"
  RESET_USED=1
  ERASE_USED=1
  if ! reset_and_boot_simulator 1; then
    echo "::error::simulator recovery after the retry infrastructure failure failed - the environment cannot be trusted; stopping the lane"
    mark_all_not_diagnosed $RETRY_CLASSES
    finish_lane "error" "$(serialize_attempts)" "" 1
  fi
  run_class_diagnosis $RETRY_CLASSES
}

# --- UI per-class diagnosis loop ----------------------------------------------
# Each named class runs alone, under its own planned watchdog, and gets at
# most one targeted retry. A pass moves on immediately; a retry pass is
# reported as a runner-level flake (never an indistinguishable clean pass); a
# class that fails both attempts fails the lane while the remaining classes
# still run; a class that hangs twice names the culprit and stops the lane
# (its simulator state is contaminated). Entered only after the simulator is
# in a trusted, freshly-booted state. Always terminates the lane.
run_class_diagnosis() {
  DIAG_CLASSES_ARR=("$@")
  LANE_FAILED=0
  for cls in "${DIAG_CLASSES_ARR[@]}"; do
    budget=$(ui_budget_for "$cls")
    obs1="$RESULT_DIR/parts/observations-$cls-a1.json"
    det1="$RESULT_DIR/parts/detail-$cls-a1.json"

    status1=0
    echo "::group::UI diagnosis class $cls attempt 1 (budget "${budget}"s)"
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
        mark_remaining_not_diagnosed "$cls" "${DIAG_CLASSES_ARR[@]}"
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
    # the simulator (a hang may have left it contaminated; a wedge may have
    # left it unusable) - but only if the clean recovery itself can be
    # trusted; an ordinary test failure retries as-is. The class is
    # re-executed, nothing else.
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
      if ! reset_and_boot_simulator 1; then
        echo "::error::simulator recovery for UI class $cls failed - the environment cannot be trusted; stopping the lane"
        mark_remaining_not_diagnosed "$cls" "${DIAG_CLASSES_ARR[@]}"
        finish_lane "error" "$(serialize_attempts)" "" 1
      fi
    elif [ "$FAIL_COUNT1" -eq 0 ]; then
      echo "::warning::UI class $cls failed with zero failing tests (exit $status1) - infrastructure failure; erasing simulator and retrying this class once"
      RESET_USED=1
      ERASE_USED=1
      if ! reset_and_boot_simulator 1; then
        echo "::error::simulator recovery for UI class $cls failed - the environment cannot be trusted; stopping the lane"
        mark_remaining_not_diagnosed "$cls" "${DIAG_CLASSES_ARR[@]}"
        finish_lane "error" "$(serialize_attempts)" "" 1
      fi
    else
      # Diagnosis mode retries at the same precision as the batch path: the
      # failed methods when the extraction identifies them, the class
      # otherwise.
      DIAG_RETRY_LINES=$(retry_filter_lines "$det1")
      echo "UI class $cls failed ("${FAIL_COUNT1}" test(s) surviving) - targeted retry"
    fi

    DIAG_RETRY_FILTERS=()
    DIAG_RETRY_METHOD_FILTERED=0
    if [ -n "${DIAG_RETRY_LINES:-}" ]; then
      while IFS= read -r filter; do
        [ -n "$filter" ] && DIAG_RETRY_FILTERS+=("-only-testing:$filter")
      done <<EOF
$DIAG_RETRY_LINES
EOF
      DIAG_RETRY_METHOD_FILTERED=1
    else
      DIAG_RETRY_FILTERS+=("-only-testing:$TARGET/$cls")
    fi
    DIAG_RETRY_LINES=""

    status2=0
    echo "::group::UI class $cls attempt 2 (targeted retry)"
    xcodebuild_test "$budget" "$LOG_DIR/class-$cls-a2.log" \
      "$RESULT_DIR/class-$cls-a2.xcresult" 1 "${DIAG_RETRY_FILTERS[@]}" || status2=$?
    echo "::endgroup::"

    if [ "$status2" -eq 0 ]; then
      extract_bundle "$RESULT_DIR/class-$cls-a2.xcresult" \
        "$RESULT_DIR/parts/observations-$cls-a2.json" \
        "$RESULT_DIR/parts/detail-$cls-a2.json" \
        "$LOG_DIR/extract-$cls-a2.log"
      # A method-filtered retry reran only the failed METHODS, so its
      # observations carry method-only durations per class - the attempt-1
      # full-class invocation owns class timing, so the retry's observations
      # must not fold into the timing history (same rule as the batch path).
      # The detail part stays: it carries the retry/flake evidence.
      if [ "$DIAG_RETRY_METHOD_FILTERED" -eq 1 ]; then
        rm -f "$RESULT_DIR/parts/observations-$cls-a2.json"
      fi
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
      mark_remaining_not_diagnosed "$cls" "${DIAG_CLASSES_ARR[@]}"
      finish_lane "timeout" "$(serialize_attempts)" "" 1
    fi

    extract_bundle "$RESULT_DIR/class-$cls-a2.xcresult" \
      "$RESULT_DIR/parts/observations-$cls-a2.json" \
      "$RESULT_DIR/parts/detail-$cls-a2.json" \
      "$LOG_DIR/extract-$cls-a2.log"
    # Same timing-history rule on the failing path: a method-filtered retry
    # never becomes the class's duration sample.
    if [ "$DIAG_RETRY_METHOD_FILTERED" -eq 1 ]; then
      rm -f "$RESULT_DIR/parts/observations-$cls-a2.json"
    fi
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
      mark_remaining_not_diagnosed "$cls" "${DIAG_CLASSES_ARR[@]}"
      finish_lane "fail" "$(serialize_attempts)" "" 1
    fi

    # Persistent infrastructure failure: the class exited nonzero twice with
    # a KNOWN zero failing-test count and never hung. The culprit is fully
    # identified and the environment is classifiable, so unlike a hang this
    # must not suppress the remaining independent classes: record the
    # persistent failure, fail the lane, clean the simulator, and continue.
    if [ "$a1_status" = "infra-error" ]; then
      echo "$cls" >> "$PERSISTENT_INFRA_LINES"
      echo "::error::UI class $cls has a PERSISTENT infrastructure failure (exit $status1, then $status2, zero failing tests both times) - failing the lane; remaining classes still run after a simulator reset"
    else
      echo "::error::UI class $cls failed again with an infrastructure failure on its retry (exit $status1, then $status2) - failing the lane; remaining classes still run after a simulator reset"
    fi
    record_attempt "class-retry" 2 "$cls" "infra-error"
    LANE_FAILED=1
    RESET_USED=1
    ERASE_USED=1
    if ! reset_and_boot_simulator 1; then
      echo "::error::simulator cleanup after the persistent infrastructure failure in UI class $cls failed - the environment cannot be trusted; stopping the lane"
      mark_remaining_not_diagnosed "$cls" "${DIAG_CLASSES_ARR[@]}"
      finish_lane "error" "$(serialize_attempts)" "" 1
    fi
  done

  if [ "$LANE_FAILED" -eq 1 ]; then
    finish_lane "fail" "$(serialize_attempts)" "" 1
  fi
  if [ -n "${DIAGNOSIS_REASON:-}" ]; then
    # A green lane reached through per-class diagnosis re-ran classes after
    # a batch-level event; keep that visible instead of blending into a
    # clean pass (the attempt chain in lane-result.json carries the record).
    echo "::warning::UI shard $LANE passed after per-class diagnosis ($DIAGNOSIS_REASON) - the affected classes re-ran individually and passed"
    DIAGNOSIS_REASON=""
  fi
  finish_lane "pass" "$(serialize_attempts)" "" 0
}

if [ "$KIND" = "ui" ]; then
  run_ui_lane
else
  run_unit_lane
fi
