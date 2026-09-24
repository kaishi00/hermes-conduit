#!/usr/bin/env bash
#
# CI v2 lane runner: execute ONE dynamically planned test lane from the shared
# build products (test-without-building; never rebuilds).
#
# Unit lanes execute their planner-assigned classes as SEQUENTIAL SMALL
# xcodebuild batches (at most 7 classes per invocation; each batch is a fresh
# xcodebuild/XCTest/testhost process on the SAME runner and the SAME Simulator
# session - no erase or reset between successful batches). UI lanes
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
#   1. Ordinary test failures never rerun healthy work. Unit batches run
#      with Xcode-native flake retry (-retry-tests-on-failure
#      -test-iterations N), which re-executes only the failing tests. If
#      failures survive those iterations the LANE FAILS on that batch - no
#      batch-level retry masquerades as recovery, and earlier batches keep
#      their recorded passes. UI batches get one TARGETED retry of just the
#      failed tests (methods when identifiable, else classes); passing
#      classes are never re-executed.
#   2. An invocation whose XCTest result CANNOT be classified (timing/result
#      extraction failed) is a FAILURE. Timing extraction is best-effort and
#      must never decide test correctness, so an unclassifiable failure is
#      never retried into a green lane - the batch fails its lane.
#   3. An invocation that exits nonzero with a KNOWN zero failing-test count
#      is confidently an infrastructure failure (simulator crash, runner
#      exit, ...). Units retry THAT BATCH ONCE after a bounded simulator
#      erase (the historical recovery, scoped to the batch instead of the
#      whole lane); a second infrastructure failure fails the lane with the
#      batch named. A UI batch cannot attribute a wedge to a class, so it
#      erases the simulator and re-runs the affected classes through
#      per-class diagnosis. If the simulator recovery itself cannot be
#      trusted (erase failed, UDID unresolvable, boot never completed),
#      later results would be misleading: the lane stops there.
#   4. A watchdog timeout is positive identification of a hang. Units retry
#      THAT BATCH ONCE with a fresh xcodebuild process on the same runner
#      and Simulator (bounded shutdown only - NO erase; the fresh-process
#      boundary IS the recovery, per the sequential-invocation diagnostic
#      that showed stalled workloads completing when re-entered through a
#      new xcodebuild). A second stall fails the lane with the batch as the
#      identified culprit. A UI batch timeout cannot name the hung class, so
#      it erases and enters the same per-class diagnosis, where a class that
#      hangs twice names the culprit, fails the lane, and stops it (its
#      simulator state is contaminated) while earlier results are kept and
#      later classes are recorded as not_diagnosed so a contaminated
#      simulator cannot produce misleading secondary failures.
#
# Batch layouts and per-batch watchdog budgets for unit lanes are owned by
# plan-tests.py alone (--batches-json is the single source of that policy;
# the runner refuses to start unless the batches exactly reproduce the
# lane's planned class order). UI watchdog budgets are likewise owned by
# plan-tests.py: every UI lane receives an explicit per-class budget table
# (--class-timeouts) and the runner refuses to start unless it covers every
# assigned class - there is no fallback formula here to drift from the
# planner.
#
# Every simctl operation is deadline-bounded (ci-lib.sh). Bash 3.2 compatible.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/ci-lib.sh"

KIND=""; LANE=""; TARGET=""; CLASSES=""; CLASS_ESTIMATES=""
BATCHES_JSON=""; CLASS_TIMEOUTS=""; PREDICTED_S=""; TIMEOUT_S=""; ITERATIONS="3"; XCRUN_FILE=""; RESULT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind) KIND="$2"; shift 2 ;;
    --lane) LANE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --classes) CLASSES="$2"; shift 2 ;;
    --class-estimates) CLASS_ESTIMATES="$2"; shift 2 ;;
    --batches-json) BATCHES_JSON="$2"; shift 2 ;;
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
# Unit lanes enforce the planned batch layout; a missing table would silently
# downgrade them to one unbounded invocation, so it is a hard argument there.
if [ "$KIND" = "unit" ] && [ -z "$BATCHES_JSON" ]; then
  echo "::error::--batches-json is required for --kind unit (planned batch layout + per-batch watchdogs from plan-tests.py)"
  exit 2
fi
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

SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"

LOG_DIR="$RESULT_DIR/logs"
mkdir -p "$LOG_DIR" "$RESULT_DIR/parts"

# --- planned batch layout (unit lanes) ---------------------------------------
# plan-tests.py owns the batch partition and every batch's watchdog budget;
# this is a pure parse + fail-closed verification that the batches exactly
# reproduce the lane's planned class order (no duplication, omission, or
# reordering) BEFORE any simulator side effect happens. Layout: one
# "<classes-csv>\t<timeout-s>" line per batch.
BATCH_CLASSES_ARR=(); BATCH_TIMEOUT_ARR=()
UNIT_BATCH_LINES="$RESULT_DIR/batch-plan.txt"
if [ "$KIND" = "unit" ]; then
if ! python3 -c '
import json, sys
raw, expected_csv, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    batches = json.loads(raw)
except json.JSONDecodeError as exc:
    sys.exit("batches JSON is not valid JSON: {0}".format(exc))
if not isinstance(batches, list) or not batches:
    sys.exit("batches JSON must be a non-empty list of batch objects")
expected_names = [c for c in expected_csv.split(",") if c]
joined = []
for b in batches:
    if not isinstance(b, dict):
        sys.exit("every batch must be a JSON object")
    classes = b.get("classes")
    timeout = b.get("timeout_s")
    if (not isinstance(classes, list) or not classes
            or any(not isinstance(c, str) or not c for c in classes)):
        sys.exit("every batch needs a non-empty list of class names")
    for c in classes:
        if "," in c or "\t" in c or "\n" in c:
            sys.exit("class name {0!r} contains a separator character".format(c))
    if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout <= 0:
        sys.exit("every batch needs a positive integer timeout_s, got {0!r}".format(timeout))
    joined.extend(classes)
if joined != expected_names:
    sys.exit("batches do not reproduce the lane class list exactly "
             "(planned {0} classes in order, batches carry {1})".format(
                 len(expected_names), len(joined)))
with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
    for b in batches:
        fh.write("{0}\t{1}\n".format(",".join(b["classes"]), b["timeout_s"]))
' "$BATCHES_JSON" "$CLASSES" "$UNIT_BATCH_LINES"; then
  echo "::error::lane $LANE: --batches-json failed validation - refusing to run (see the reason above)"
  exit 2
fi
while IFS=$'\t' read -r bcls btimeout; do
  [ -z "$bcls" ] && continue
  # Tolerate CRLF residue: the plan file crosses toolchains (the parser may
  # run under a Python whose text mode translates newlines).
  bcls="${bcls%$'\r'}"
  btimeout="${btimeout%$'\r'}"
  BATCH_CLASSES_ARR+=("$bcls")
  BATCH_TIMEOUT_ARR+=("$btimeout")
done < "$UNIT_BATCH_LINES"
if [ "${#BATCH_CLASSES_ARR[@]}" -eq 0 ]; then
  echo "::error::lane $LANE: the planned batch layout is empty"
  exit 2
fi
fi

# --- lane membership ----------------------------------------------------------
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

build_destination
disable_pasteboard_sync

echo "lane $LANE ($KIND): target $TARGET, predicted "${PREDICTED_S}"s, watchdog "${TIMEOUT_S}"s"
echo "destination: $DESTINATION"
echo "xctestrun: $XCRUN_FILE"
echo "lane $LANE: "${#CLASSES_ARR[@]}" classes in "${#BATCH_CLASSES_ARR[@]}" sequential xcodebuild batches"
# The per-class estimates remain informational: they document the timing
# data behind the plan in the lane log (watchdogs come from the planned
# tables above, never from a runner-side formula).
echo "lane $LANE class estimates: ${CLASS_ESTIMATES:-<none supplied>}"

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
# the unexecuted classes force diagnosis (UI) or fail the lane (unit) instead.
# $1 = detail.json, $2 = CSV of the classes the invocation was expected to run.
unexecuted_classes() {
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
" "$1" "$2" 2>/dev/null || true
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
HUNG_BATCH=0

# UI mode records the per-class attempt chain (mode|n|class|status lines) and
# serializes it to JSON at lane finish; unit mode passes JSON directly and
# creates none of these bookkeeping files.
ATTEMPT_LINES="$RESULT_DIR/attempts-lines.txt"
# Unit mode records one "n|attempt|status|seconds|failures" line per batch
# attempt in BATCH_RESULT_LINES; the planned layout lives in batch-plan.txt.
# Together they are the single source for the lane-result batches document.
BATCH_RESULT_LINES="$RESULT_DIR/batch-results.txt"
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
else
  : > "$ATTEMPT_LINES"
  : > "$BATCH_RESULT_LINES"
fi

record_attempt() { # $1=mode $2=n $3=class $4=status
  echo "$1|$2|$3|$4" >> "$ATTEMPT_LINES"
}

record_batch_attempt() { # $1=batch $2=attempt $3=status $4=seconds $5=failures
  echo "$1|$2|$3|$4|$5" >> "$BATCH_RESULT_LINES"
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

finish_lane() { # $1=status $2=attempts_json $3=batches_json $4=exit_code
  ACTUAL_S=$(( $(date +%s) - lane_start ))
  # Both modes fold the per-attempt extraction parts into the lane-level
  # observations/detail documents (last attempt per class wins - on a green
  # lane that is always the passing attempt; for units the last attempt of a
  # batch is a FULL-class rerun, so it owns the class timing sample).
  python3 "$SCRIPT_DIR/extract-test-timings.py" merge-parts \
    --parts-dir "$RESULT_DIR/parts" \
    --observations-out "$RESULT_DIR/observations.json" \
    --detail-out "$RESULT_DIR/detail.json" \
    >>"$LOG_DIR/merge-parts.log" 2>&1 || \
    echo "::warning::timing part merge failed safely for lane $LANE; timing history keeps previous values"
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
    --batches-json "$3" \
    --retried-classes "$(retried_classes_csv)" \
    --infra-recovered-classes "$(infra_recovered_csv)" \
    --persistent-infra-classes "$(persistent_infra_csv)" \
    --hung-class "$HUNG_CLASS" \
    --hung-batch "$HUNG_BATCH" \
    $reset_flag $erase_flag \
    --observations "$RESULT_DIR/observations.json" \
    --detail "$RESULT_DIR/detail.json" \
    --out "$RESULT_DIR/lane-result.json" || true
  # Bundles are created inside RESULT_DIR, so failed lanes upload them as
  # failure artifacts automatically. Successful lanes have already had their
  # timings extracted - delete the bundles to keep the artifact small, EXCEPT
  # for attempts that needed their retry (test-flake OR stall/wedge recovery:
  # both attempt bundles are kept, since the attempt-1 bundle is the only
  # evidence of what needed the retry).
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
      # Green unit lane: keep both bundles only for batches that ran twice
      # (their attempt-2 record exists); everything else is pruned.
      local keep b base bn
      keep=$(awk -F'|' '$2 == 2 {print $1}' "$BATCH_RESULT_LINES" 2>/dev/null || true)
      for b in "$RESULT_DIR"/batch-*.xcresult; do
        [ -e "$b" ] || break
        base=$(basename "$b" .xcresult)
        bn=${base#batch-}; bn=${bn%%-*}
        case " $keep " in *" $bn "*) ;; *) rm -rf "$b" ;; esac
      done
    fi
  fi
  exit "$4"
}

# Serialize the unit lane's batch document for lane-result.json: planned
# layout (batch-plan.txt) + recorded attempt chain (batch-results.txt).
# Best-effort like every lane-result side input: a lost bookkeeping file
# degrades to [] (the report shows no batch detail) but can never crash the
# lane verdict - the fail-closed completeness check happens in
# finish_unit_lane BEFORE a green verdict is reachable.
serialize_unit_batches() {
  python3 -c "
import json, sys
try:
    planned = []
    with open(sys.argv[1], encoding='utf-8') as fh:
        for line in fh:
            line = line.rstrip(chr(10))
            if not line:
                continue
            classes, timeout = line.split(chr(9))
            planned.append({'classes': classes.split(','),
                            'timeout_s': int(timeout)})
    attempts = {}
    with open(sys.argv[2], encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            fields = line.split('|')
            if len(fields) != 5:
                continue
            n, attempt, status, secs, failures = fields
            try:
                entry = {'attempt': int(attempt), 'status': status,
                         'seconds': float(secs), 'failures': int(failures)}
            except ValueError:
                continue
            attempts.setdefault(int(n), []).append(entry)
    out = []
    for i, b in enumerate(planned, start=1):
        chain = attempts.get(i, [])
        if not chain:
            status = 'not_run'
        elif any(a['status'] == 'passed' for a in chain):
            status = 'pass'
        else:
            status = chain[-1]['status']
        out.append({'batch': i, 'classes': b['classes'],
                    'timeout_s': b['timeout_s'], 'status': status,
                    'attempts': chain})
    print(json.dumps(out))
except Exception:
    print('[]')
" "$UNIT_BATCH_LINES" "$BATCH_RESULT_LINES" 2>/dev/null
}

# Remaining batches after the lane stopped are recorded as not_run so the
# report shows exactly what never executed - unexecuted tests may never
# masquerade as passed or as ordinary failures.
mark_later_batches_not_run() { # $1 = batch index the lane stopped on
  local total="${#BATCH_CLASSES_ARR[@]}" n="$1"
  while [ "$n" -lt "$total" ]; do
    n=$(( n + 1 ))
    record_batch_attempt "$n" 0 "not_run" 0 0
  done
}

# Unit finish: fail-closed completeness check first - a green verdict is only
# reachable when EVERY planned batch index (1..N) owns a passing record.
# Compared per batch index so a corrupted or truncated bookkeeping file can
# never satisfy the count. Then the shared finish_lane writes the lane result
# with the batch document attached.
finish_unit_lane() { # $1=status $2=exit_code
  if [ "$1" = "pass" ]; then
    local expected i
    expected=$(awk 'END {print NR}' "$UNIT_BATCH_LINES" 2>/dev/null || echo 0)
    i=1
    while [ "$i" -le "$expected" ]; do
      if ! grep -q "^$i|[0-9]*|passed|" "$BATCH_RESULT_LINES" 2>/dev/null; then
        echo "::error::unit lane $LANE cannot finish green: batch $i has no passing record in the lane bookkeeping - failing closed"
        finish_lane "error" "$(serialize_attempts)" "$(serialize_unit_batches)" 1
      fi
      i=$(( i + 1 ))
    done
  fi
  finish_lane "$1" "$(serialize_attempts)" "$(serialize_unit_batches)" "$2"
}

# --- unit lane: sequential fresh-xcodebuild batches ---------------------------
#
# Evidence (PRs #178-#183): large single unit invocations repeatedly
# watchdog-stalled on hosted macos-26 regardless of membership - audio was
# exonerated, a 30-class cap did not help, the reproducing set narrowed to
# 14 classes, and those same 14 completed as two 7-class invocations run
# back-to-back in ONE job on ONE runner with ONE Simulator session (only the
# xcodebuild/XCTest/testhost process was fresh between them). So the lane's
# planned classes execute batch by batch:
#
#   * pass      -> next batch; the Simulator is never reset/erased between
#                  successful batches (the fresh process is the boundary);
#   * real test failures surviving the native in-invocation retry, or an
#     unclassifiable result -> the lane FAILS on that batch;
#   * watchdog stall OR infrastructure wedge (nonzero exit, KNOWN zero
#     failures) -> THIS batch retries ONCE: fresh xcodebuild, same runner,
#     same Simulator. The watchdog path adds only a bounded simulator
#     shutdown (NO erase); the infra path keeps the historical
#     erase-before-retry. A second stall fails the lane with the batch
#     named - exactly one batch-level retry ever, never a lane rerun.
run_unit_batches() {
if ! shutdown_own_simulator; then  # bounded + UDID-scoped, and refused outright when the run's own UDID cannot be established
  echo "::error::unit $LANE: cannot establish this run's own simulator - refusing to run against an ambiguous device"
  mark_later_batches_not_run 1
  finish_unit_lane "error" 1
fi

local batch_idx=1 batch_total="${#BATCH_CLASSES_ARR[@]}"
local batch_classes budget cls t0 secs status missing fail_count a1_status
while [ "$batch_idx" -le "$batch_total" ]; do
  batch_classes="${BATCH_CLASSES_ARR[$(( batch_idx - 1 ))]}"
  budget="${BATCH_TIMEOUT_ARR[$(( batch_idx - 1 ))]}"
  BATCH_ONLY=()
  IFS=',' read -r -a BATCH_ONLY <<< "$batch_classes"
  ONLY_TESTING=()
  for cls in "${BATCH_ONLY[@]}"; do
    ONLY_TESTING+=("-only-testing:$TARGET/$cls")
  done

  t0=$(date +%s)
  status=0
  echo "::group::unit $LANE batch $batch_idx/$batch_total attempt 1 (${#BATCH_ONLY[@]} classes, budget "${budget}"s, native flake retry x"${ITERATIONS}")"
  xcodebuild_test "$budget" "$LOG_DIR/batch-$batch_idx-a1.log" \
    "$RESULT_DIR/batch-$batch_idx-a1.xcresult" "$ITERATIONS" "${ONLY_TESTING[@]}" || status=$?
  echo "::endgroup::"
  secs=$(( $(date +%s) - t0 ))

  extract_bundle "$RESULT_DIR/batch-$batch_idx-a1.xcresult" \
    "$RESULT_DIR/parts/observations-batch-$batch_idx-a1.json" \
    "$RESULT_DIR/parts/detail-batch-$batch_idx-a1.json" \
    "$LOG_DIR/extract-batch-$batch_idx-a1.log"

  if [ "$status" -eq 0 ]; then
    # Defense in depth (same rule as the UI batch path): exit 0 should imply
    # every -only-testing filter executed; if a parseable detail proves an
    # assigned class left no record, do not trust the exit code. An
    # unreadable detail degrades to the pass (the gate reports nothing).
    missing=$(unexecuted_classes "$RESULT_DIR/parts/detail-batch-$batch_idx-a1.json" "$batch_classes")
    if [ -z "$missing" ]; then
      record_batch_attempt "$batch_idx" 1 "passed" "$secs" 0
      record_attempt "batch" "$batch_idx" "all" "passed"
      echo "unit $LANE: batch $batch_idx/$batch_total passed"
      batch_idx=$(( batch_idx + 1 ))
      continue
    fi
    echo "::error::unit $LANE batch $batch_idx/$batch_total exited 0 but the xcresult has no record of $(printf '%s ' $missing)- failing the lane"
    record_batch_attempt "$batch_idx" 1 "incomplete" "$secs" 0
    record_attempt "batch" "$batch_idx" "all" "incomplete"
    mark_later_batches_not_run "$batch_idx"
    finish_unit_lane "fail" 1
  fi

  fail_count=$(count_failures "$RESULT_DIR/parts/detail-batch-$batch_idx-a1.json")
  # Real failures win over the stall classification: a batch whose xcresult
  # records surviving test failures is a TEST failure no matter how the
  # process exited - the native in-invocation retry already re-ran them, and
  # a real failure is never eligible for the batch-level retry.
  if [ "$fail_count" -gt 0 ]; then
    a1_status="test-failures"
  elif [ "$status" -eq 124 ]; then
    a1_status="timeout"
  elif [ "$fail_count" -eq -1 ]; then
    a1_status="unclassified"
  else
    a1_status="infra-error"
  fi
  record_batch_attempt "$batch_idx" 1 "$a1_status" "$secs" "$fail_count"
  record_attempt "batch" "$batch_idx" "all" "$a1_status"

  # Terminal, never retried: real failures (native retry already re-ran only
  # the failing tests inside the invocation) and unclassifiable results.
  if [ "$a1_status" = "test-failures" ]; then
    echo "::error::unit $LANE: batch $batch_idx/$batch_total has "${fail_count}" test(s) failing after native retry - real failures, not infrastructure; failing the lane"
    mark_later_batches_not_run "$batch_idx"
    finish_unit_lane "fail" 1
  fi
  if [ "$a1_status" = "unclassified" ]; then
    echo "::error::unit $LANE: batch $batch_idx/$batch_total failed (exit $status) and its XCTest result could not be classified - failing the lane instead of retrying"
    mark_later_batches_not_run "$batch_idx"
    finish_unit_lane "fail" 1
  fi

  # The only two retry-eligible failures. Exactly ONE retry of THIS batch:
  # a fresh xcodebuild on the same runner, same Simulator.
  if [ "$a1_status" = "timeout" ]; then
    echo "::warning::unit $LANE batch $batch_idx/$batch_total exceeded its "${budget}"s watchdog - shutting down the simulator (NO erase) and retrying THIS batch once with a fresh xcodebuild"
    bounded_run 45 xcrun simctl list devices >"$LOG_DIR/simctl-devices-after-batch-$batch_idx-timeout.txt" 2>&1 || true
    if ! shutdown_own_simulator; then
      echo "::error::unit $LANE batch $batch_idx/$batch_total: cannot establish this run's own simulator for the retry - the environment cannot be trusted; stopping the lane"
      mark_later_batches_not_run "$batch_idx"
      finish_unit_lane "error" 1
    fi
    RESET_USED=1
  else
    echo "::warning::unit $LANE batch $batch_idx/$batch_total failed with zero failing tests (exit $status) - infrastructure failure; erasing the simulator and retrying THIS batch once"
    RESET_USED=1
    ERASE_USED=1
    if ! reset_and_boot_simulator 1; then
      echo "::error::simulator recovery for unit batch $batch_idx/$batch_total failed - the environment cannot be trusted; stopping the lane"
      mark_later_batches_not_run "$batch_idx"
      finish_unit_lane "error" 1
    fi
  fi

  t0=$(date +%s)
  status=0
  echo "::group::unit $LANE batch $batch_idx/$batch_total attempt 2 (batch retry, budget "${budget}"s)"
  xcodebuild_test "$budget" "$LOG_DIR/batch-$batch_idx-a2.log" \
    "$RESULT_DIR/batch-$batch_idx-a2.xcresult" "$ITERATIONS" "${ONLY_TESTING[@]}" || status=$?
  echo "::endgroup::"
  secs=$(( $(date +%s) - t0 ))

  extract_bundle "$RESULT_DIR/batch-$batch_idx-a2.xcresult" \
    "$RESULT_DIR/parts/observations-batch-$batch_idx-a2.json" \
    "$RESULT_DIR/parts/detail-batch-$batch_idx-a2.json" \
    "$LOG_DIR/extract-batch-$batch_idx-a2.log"

  if [ "$status" -eq 0 ]; then
    missing=$(unexecuted_classes "$RESULT_DIR/parts/detail-batch-$batch_idx-a2.json" "$batch_classes")
    if [ -z "$missing" ]; then
      record_batch_attempt "$batch_idx" 2 "passed" "$secs" 0
      record_attempt "batch-retry" "$batch_idx" "all" "passed"
      if [ "$a1_status" = "timeout" ]; then
        echo "::warning::unit $LANE batch $batch_idx/$batch_total PASSED on its watchdog retry - the stall was recovered by the fresh xcodebuild boundary (not a test flake)"
      else
        echo "::warning::unit $LANE batch $batch_idx/$batch_total passed after its infrastructure retry - environment wedge recovered (not a test flake)"
      fi
      batch_idx=$(( batch_idx + 1 ))
      continue
    fi
    echo "::error::unit $LANE batch $batch_idx/$batch_total retry exited 0 but the xcresult has no record of $(printf '%s ' $missing)- failing the lane"
    record_batch_attempt "$batch_idx" 2 "incomplete" "$secs" 0
    record_attempt "batch-retry" "$batch_idx" "all" "incomplete"
    mark_later_batches_not_run "$batch_idx"
    finish_unit_lane "fail" 1
  fi

  # The one allowed retry is spent: every non-passing outcome fails the
  # lane, naming the batch.
  fail_count=$(count_failures "$RESULT_DIR/parts/detail-batch-$batch_idx-a2.json")
  local a2_status
  if [ "$fail_count" -gt 0 ]; then
    a2_status="test-failures"
  elif [ "$status" -eq 124 ]; then
    a2_status="timeout"
  elif [ "$fail_count" -eq -1 ]; then
    a2_status="unclassified"
  else
    a2_status="infra-error"
  fi
  record_batch_attempt "$batch_idx" 2 "$a2_status" "$secs" "$fail_count"
  record_attempt "batch-retry" "$batch_idx" "all" "$a2_status"

  if [ "$a2_status" = "timeout" ]; then
    echo "::error::unit $LANE batch $batch_idx/$batch_total failed after its one allowed batch retry (attempt 1: $a1_status, attempt 2: timeout) - persistent stall; failing the lane with this batch as the identified culprit"
    HUNG_BATCH="$batch_idx"
    mark_later_batches_not_run "$batch_idx"
    finish_unit_lane "timeout" 1
  fi
  if [ "$a2_status" = "test-failures" ]; then
    echo "::error::unit $LANE batch $batch_idx/$batch_total has "${fail_count}" test(s) failing after its retry - real failures; failing the lane"
    mark_later_batches_not_run "$batch_idx"
    finish_unit_lane "fail" 1
  fi
  if [ "$a2_status" = "unclassified" ]; then
    echo "::error::unit $LANE batch $batch_idx/$batch_total failed on retry (exit $status) and its XCTest result could not be classified - failing the lane"
    mark_later_batches_not_run "$batch_idx"
    finish_unit_lane "fail" 1
  fi
  echo "::error::unit $LANE batch $batch_idx/$batch_total failed after its one allowed batch retry (attempt 1: $a1_status, attempt 2: infrastructure failure, zero failing tests) - persistent environment failure; failing the lane"
  mark_later_batches_not_run "$batch_idx"
  finish_unit_lane "error" 1
done

finish_unit_lane "pass" 0
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
  if ! shutdown_own_simulator; then
    echo "::error::ui $LANE: cannot establish this run's own simulator - refusing to run against an ambiguous device"
    finish_lane "error" "$(serialize_attempts)" "" 1
  fi
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
    MISSING_CLASSES=$(unexecuted_classes "$RESULT_DIR/parts/detail-batch-a1.json" "$CLASSES")
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
  MISSING_CLASSES=$(unexecuted_classes "$RESULT_DIR/parts/detail-batch-a1.json" "$CLASSES")
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
  run_unit_batches
fi
