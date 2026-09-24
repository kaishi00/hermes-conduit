#!/usr/bin/env bash
#
# State-machine tests for scripts/ci-test-lane.sh.
#
# The lane runner is exercised end-to-end against stub xcodebuild/xcrun
# binaries (no simulator, no real Xcode). Each case asserts the lane verdict,
# the attempt chain, and that an unclassifiable failure can never be retried
# into a green lane.
#
# Usage: bash scripts/tests/test_lane_runner.sh   (exit 0 = all cases pass)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
WORK="${LR_DEBUG_WORK:-$(mktemp -d)}"
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
if [ -z "${LR_DEBUG_WORK:-}" ]; then trap 'rm -rf "$WORK"' EXIT; fi

pass_count=0
fail_count=0

ok()   { pass_count=$((pass_count + 1)); echo "  ok: $1"; }
bad()  { fail_count=$((fail_count + 1)); echo "  FAIL: $1"; }

assert_eq() { # $1=desc $2=actual $3=expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}

seq_line() { # $1=exact line → first line number in SEQ_LOG, empty if absent
  grep -nFx -m1 "$1" "$SEQ_LOG" 2>/dev/null | cut -d: -f1
}

seq_between() { # $1=earlier line no, $2=later line no, $3=exact line between them → yes/no
  if [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] \
     && [ "$1" -lt "$2" ] && [ "$3" -gt "$1" ] && [ "$3" -lt "$2" ]; then
    echo yes
  else
    echo no
  fi
}

write_stub_xcrun() {
  cat > "$STUBS/xcrun" <<'EOF'
#!/bin/bash
if [ "$1" = "xcresulttool" ]; then
  if [ -n "$FAKE_CANNED" ] && [ -f "$FAKE_CANNED" ]; then
    cat "$FAKE_CANNED"
    exit 0
  fi
  echo "not json - schema change (stub)"
  exit 0
fi
if [ "$1" = "simctl" ]; then
  # Every simctl subcommand lands in SEQ_LOG so cases can assert the exact
  # device-lifecycle ORDER (settle before xcodebuild), not just outcomes.
  echo "simctl $2" >> "${SEQ_LOG:-/dev/null}"
  # The erase-gated simulator recovery must be able to SUCCEED in tests, so
  # simctl list -j serves one pinned device (matching the default
  # SIMULATOR_NAME) for ci-lib's jq-based UDID resolution. FAKE_SIMCTL_DUPLICATE
  # serves the same name on TWO runtimes: the lane must refuse to guess which
  # device it owns unless the caller pinned a run-owned UDID.
  if [ "$2 $3 $4 $5" = "list devices available -j" ]; then
    if [ -n "${FAKE_SIMCTL_DUPLICATE:-}" ]; then
      cat <<'DEV'
{"devices" : {"com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
  { "udid" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "name" : "iPhone 17 Pro", "state" : "Shutdown" },
  { "udid" : "6D08B063-B890-4D18-893B-D1E89E119919",
    "name" : "iPhone 17 Pro", "state" : "Shutdown" }]}}
DEV
      exit 0
    fi
    cat <<'DEV'
{"devices" : {"com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
  { "udid" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "name" : "iPhone 17 Pro", "state" : "Shutdown" }]}}
DEV
    exit 0
  fi
  # Simulate an erase/reboot recovery that never completes: the lane must
  # treat the environment as untrustworthy.
  if [ "$FAKE_UI_RECOVERY_FAILS" = "1" ] && [ "$2" = "bootstatus" ]; then
    echo "bootstatus failed (stub)"
    exit 1
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$STUBS/xcrun"
}

# Compact batches JSON for a lane whose classes each run in their OWN batch
# (the runner behavior under test is per-batch, not the chunking itself -
# the chunking invariants are pinned in Python by test_plan_tests.py).
batches_json_for() { # $1=classes csv $2=timeout seconds
  python3 -c "
import json, sys
classes = [c for c in sys.argv[1].split(',') if c]
print(json.dumps([{'classes': [c], 'timeout_s': int(sys.argv[2])} for c in classes], separators=(',', ':')))
" "$1" "$2"
}

# Unit batch stub: decides per INVOCATION, keyed by the result-bundle stem
# batch-<n>-a<k> through FAKE_UNIT_B<n>_A<k> (unset = pass). Every invocation
# writes the canned xcresult document matching its own verdict for every
# class it was asked to run. Invocation facts land in $INVOCATION_LOG as
# "batch-<n>-a<k>" lines.
write_unit_batch_stub_xcodebuild() {
  cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
# Echo the invocation arguments so the streamed xcodebuild log carries the
# retry flags (asserted below: unit batches must run under native retry).
echo "stub args: $*"
bundle=""
for a in "$@"; do
  case "$a" in *.xcresult) bundle="$a"; mkdir -p "$a" ;; esac
done
stem=$(basename "$bundle" .xcresult)
n="${stem#batch-}"; n="${n%%-*}"
attempt="${stem##*-a}"
echo "batch-$n-a$attempt" >> "$INVOCATION_LOG"
echo "xcodebuild batch-$n-a$attempt" >> "${SEQ_LOG:-/dev/null}"
classes=""
for a in "$@"; do
  case "$a" in
    -only-testing:*) cls="${a#-only-testing:}"; classes="$classes ${cls#*/}" ;;
  esac
done
mode_var="FAKE_UNIT_B${n}_A${attempt}"
mode=$(eval "echo \${$mode_var:-pass}")
write_doc() {
  [ -n "${FAKE_UNIT_NO_DOC:-}" ] && return 0
  result="$1"
  nodes=""
  sep=""
  for c in $classes; do
    # Classes listed in $FAKE_UNIT_OMIT get no Test Suite node at all: the
    # canned document then models an invocation that exited 0 without ever
    # running one of its assigned classes.
    case " $FAKE_UNIT_OMIT " in *" $c "*) continue ;; esac
    nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"$c\", \"result\": \"$result\",
      \"children\": [{\"nodeType\": \"Test Case\", \"name\": \"testC()\", \"result\": \"$result\",
      \"durationInSeconds\": 0.1}]}"
    sep=","
  done
  cat > "$FAKE_CANNED" <<DOC
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Unit test bundle", "name": "ConduitTests", "result": "Passed",
    "children": [$nodes]}]}]}
DOC
}
case "$mode" in
  hang) write_doc Passed; sleep 300; exit 0 ;;
  hangfail) write_doc Failed; sleep 300; exit 0 ;;
  infra70) write_doc Passed; echo "simulator crashed (stub)"; exit 70 ;;
  fail65) write_doc Failed; echo "Test Case failed (stub)"; exit 65 ;;
  *) write_doc Passed; exit 0 ;;
esac
EOF
  chmod +x "$STUBS/xcodebuild"
}

reset_unit_stub_vars() {
  unset FAKE_UNIT_B1_A1 FAKE_UNIT_B1_A2 FAKE_UNIT_B2_A1 FAKE_UNIT_B2_A2 \
        FAKE_UNIT_B3_A1 FAKE_UNIT_B3_A2 FAKE_UNIT_NO_DOC FAKE_UNIT_OMIT \
        2>/dev/null || true
}

write_canned() { # $1=file $2=class $3=result
  cat > "$1" <<EOF
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Unit test bundle", "name": "ConduitTests", "result": "Passed",
    "children": [{"nodeType": "Test Suite", "name": "$2", "result": "Passed",
      "children": [{"nodeType": "Test Case", "name": "testC()", "result": "$3",
        "durationInSeconds": 0.1}]}]}]}]}
EOF
  export FAKE_CANNED="$1"
}

export PATH="$STUBS:$PATH"
write_unit_batch_stub_xcodebuild
write_stub_xcrun
touch "$WORK/fake.xctestrun"
# The stub xcodebuild invocations exit instantly; a full 15s poll interval
# per invocation would dominate the suite's wall clock (and blow the plan
# job's budget), so shrink the cadence. Behavior under test is unaffected:
# the deadline math and kill semantics are identical at any cadence.
export XCODEBUILD_POLL_INTERVAL_S=1
# The lane's settle (reset_and_boot_simulator) sleeps between shutdown and
# boot. Deadlines are wall-clock (date), never sleep-derived - the same
# rationale as the gate's stubbed integration suite - so scale the settling
# sleeps out to keep this suite's wall clock as it was before the settle.
export GATE_SLEEP_SCALE=0
# Ordered device-lifecycle trace (simctl subcommands + xcodebuild
# invocations) for the settle-before-launch assertions. Truncated per case
# in begin_case.
export SEQ_LOG="$WORK/seq.log"

begin_case() { # $1=name $2=workdir
  current="$1"
  WORKCASE="$2"
  mkdir -p "$2"
  : > "$SEQ_LOG"
  CASE_START=$(date +%s)
  echo "START $current"
}

end_case() { # closes the current case's timing line (suite-progress telemetry)
  [ -n "${current:-}" ] || return 0
  echo "END $current $(( $(date +%s) - CASE_START ))s"
  current=""
}

run_lane() { # $1=classes $2=timeout $3=iterations (one batch per class)
  _classes="$1"; _timeout="$2"; _iters="$3"; shift 3
  bash "$SCRIPTS/ci-test-lane.sh" \
    --kind unit --lane unit-t --target ConduitTests \
    --classes "$_classes" \
    --batches-json "$(batches_json_for "$_classes" "$_timeout")" \
    --predicted 42 --timeout "$_timeout" \
    --iterations "$_iters" \
    --xctestrun "$WORK/fake.xctestrun" \
    --result-dir "$WORKCASE" >"$WORKCASE/stdout.log" 2>&1
  echo $? > "$WORKCASE/exit-code"
}

run_lane_raw() { # $1=classes $2=RAW batches json (for malformed-layout cases)
  _classes="$1"; _raw="$2"
  bash "$SCRIPTS/ci-test-lane.sh" \
    --kind unit --lane unit-t --target ConduitTests \
    --classes "$_classes" \
    --batches-json "$_raw" \
    --predicted 42 --timeout 300 \
    --iterations 3 \
    --xctestrun "$WORK/fake.xctestrun" \
    --result-dir "$WORKCASE" >"$WORKCASE/stdout.log" 2>&1
  echo $? > "$WORKCASE/exit-code"
}

run_lane_missing_batches() { # $1=classes: no --batches-json at all
  bash "$SCRIPTS/ci-test-lane.sh" \
    --kind unit --lane unit-t --target ConduitTests \
    --classes "$1" \
    --predicted 42 --timeout 300 \
    --iterations 3 \
    --xctestrun "$WORK/fake.xctestrun" \
    --result-dir "$WORKCASE" >"$WORKCASE/stdout.log" 2>&1
  echo $? > "$WORKCASE/exit-code"
}

lane_field() { # $1=python expression applied to the lane-result document
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print(eval('d' + sys.argv[2]))
" "$WORKCASE/lane-result.json" "$1" 2>/dev/null || echo NONE
}

attempts_statuses() {
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print([a['status'] for a in d.get('attempts', [])])
" "$WORKCASE/lane-result.json" 2>/dev/null || echo NONE
}

batch_statuses() {
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print([b['status'] for b in d.get('batches', [])])
" "$WORKCASE/lane-result.json" 2>/dev/null || echo NONE
}

batch_attempt_chain() { # $1 = batch index
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
b = d.get('batches', [])[int(sys.argv[2]) - 1]
print([a['status'] for a in b.get('attempts', [])])
" "$WORKCASE/lane-result.json" "$1" 2>/dev/null || echo NONE
}

batch_invocations() { # $1=batch $2=attempt -> exact invocation count
  grep -cx "batch-$1-a$2" "$INVOCATION_LOG" 2>/dev/null || true
}

retried_classes() {
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print(d.get('retried_classes'))
" "$WORKCASE/lane-result.json" 2>/dev/null || echo NONE
}

run_ui_lane() { # $1=classes $2=lane-timeout(bookkeeping) $3=class-timeouts
  _classes="$1"; _timeout="$2"; _cto="$3"
  bash "$SCRIPTS/ci-test-lane.sh"     --kind ui --lane ui-t --target ConduitUITests     --classes "$_classes"     --class-timeouts "$_cto"     --predicted 42 --timeout "$_timeout"     --xctestrun "$WORK/fake.xctestrun"     --result-dir "$WORKCASE" >"$WORKCASE/stdout.log" 2>&1
  echo $? > "$WORKCASE/exit-code"
}

# Stub that decides per invocation SHAPE: the batched shard invocation
# (result bundle stem batch-a1/batch-a2) is driven by $FAKE_BATCH_A1 /
# $FAKE_BATCH_RETRY; per-class diagnosis invocations (bundle stem
# class-<cls>-a1/a2) are driven by the $FAKE_UI_* class tables. Every
# invocation rewrites the canned xcresult document to match its own verdict
# for EVERY class it was asked to run, so the runner's classification sees
# the right detail. Invocation facts land in $INVOCATION_LOG as
# "batch-a1", "batch-a2 (filters: ...)" and "class:<cls>:<kind>" lines.
write_ui_stub_xcodebuild() {
  cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
bundle=""
for a in "$@"; do
  case "$a" in
    *.xcresult) bundle="$a"; mkdir -p "$a" ;;
  esac
done
kind=a1
case "$bundle" in
  *-a2.xcresult) kind=a2 ;;
esac
mode=class
case "$bundle" in
  *batch-*) mode=batch ;;
esac
classes=""
methods=""
for a in "$@"; do
  case "$a" in
    -only-testing:*)
      spec="${a#-only-testing:}"
      rest="${spec#*/}"
      cls="${rest%%/*}"
      case "$rest" in
        */*) methods="$methods $rest" ;;
      esac
      case " $classes " in *" $cls "*) ;; *) classes="$classes $cls" ;; esac
      ;;
  esac
done

# Write the canned extraction document: one Test Suite node per Class:Result.
# Classes listed in $FAKE_BATCH_SKIP_CLASSES get an extra Skipped test (final
# != Passed, so the runner's retry filters must include it).
write_doc_multi() {
  docfile="$1"; shift
  nodes=""
  sep=""
  for pair in "$@"; do
    c="${pair%%:*}"; r="${pair#*:}"
    extra=""
    case " $FAKE_BATCH_SKIP_CLASSES " in *" $c "*)
      extra=",{\"nodeType\": \"Test Case\", \"name\": \"testD()\", \"result\": \"Skipped\",
        \"durationInSeconds\": 0.1}" ;;
    esac
    nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"$c\", \"result\": \"$r\",
      \"children\": [{\"nodeType\": \"Test Case\", \"name\": \"testC()\", \"result\": \"$r\",
      \"durationInSeconds\": 0.1}$extra]}"
    sep=","
  done
  cat > "$FAKE_CANNED" <<DOC
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "UI test bundle", "name": "ConduitUITests", "result": "Passed",
    "children": [$nodes]}]}]}
DOC
}

write_all_passed() {
  # $@ = class names
  pairs=""
  for c in "$@"; do pairs="$pairs $c:Passed"; done
  write_doc_multi "$FAKE_CANNED" $pairs
}

# The canned document must reflect an ABORTED batch: classes listed in
# $FAKE_BATCH_OMIT_CLASSES never ran and get no Test Suite node at all.
doc_classes=""
for c in $classes; do
  case " $FAKE_BATCH_OMIT_CLASSES " in *" $c "*) ;; *) doc_classes="$doc_classes $c" ;; esac
done

if [ "$mode" = "batch" ]; then
  case "$kind" in
    a1)
      echo "batch-a1" >> "$INVOCATION_LOG"
      [ -n "${FAKE_UI_NO_DOC:-}" ] || write_all_passed $doc_classes
      case "$FAKE_BATCH_A1" in
        hang)
          sleep 300
          exit 0
          ;;
        infra)
          echo "simulator crashed (stub)"
          exit 70
          ;;
        fail-test)
          pairs=""
          for c in $doc_classes; do
            case " $FAKE_BATCH_FAIL_CLASSES " in *" $c "*) pairs="$pairs $c:Failed" ;; *) pairs="$pairs $c:Passed" ;; esac
          done
          # NO_DOC keeps the canned document stale so extraction fails.
          [ -n "${FAKE_UI_NO_DOC:-}" ] || write_doc_multi "$FAKE_CANNED" $pairs
          echo "Test Case failed (stub)"
          exit 65
          ;;
        *)
          exit 0
          ;;
      esac
      ;;
    a2)
      echo "batch-a2 (filters:$methods)" >> "$INVOCATION_LOG"
      [ -n "${FAKE_UI_NO_DOC:-}" ] || write_all_passed $doc_classes
      case "$FAKE_BATCH_RETRY" in
        hang)
          sleep 300
          exit 0
          ;;
        infra)
          echo "simulator crashed (stub)"
          exit 70
          ;;
        fail)
          pairs=""
          for c in $doc_classes; do pairs="$pairs $c:Failed"; done
          [ -n "${FAKE_UI_NO_DOC:-}" ] || write_doc_multi "$FAKE_CANNED" $pairs
          echo "Test Case failed (stub)"
          exit 65
          ;;
        *)
          exit 0
          ;;
      esac
      ;;
  esac
  exit 0
fi

# Class mode: exactly one class per invocation.
cls=$(printf '%s\n' $classes | head -1)
echo "class:$cls:$kind" >> "$INVOCATION_LOG"
# A hanging class hangs on BOTH attempts: the second hang is what names the
# culprit and stops the lane.
case " $FAKE_UI_HANG " in *" $cls "*) sleep 300; exit 0 ;; esac
case "$kind" in
  a1) case " $FAKE_UI_FAIL_ONCE " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Failed"; echo "Test Case failed (stub)"; exit 65 ;; esac
      case " $FAKE_UI_FAIL_ALWAYS " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Failed"; echo "Test Case failed (stub)"; exit 65 ;; esac
      case " $FAKE_UI_INFRA_ONCE " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Passed"; echo "simulator crashed (stub)"; exit 70 ;; esac
      case " $FAKE_UI_INFRA_ALWAYS " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Passed"; echo "simulator crashed (stub)"; exit 70 ;; esac
      ;;
  a2) case " $FAKE_UI_FAIL_ALWAYS " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Failed"; echo "Test Case failed (stub)"; exit 65 ;; esac
      case " $FAKE_UI_INFRA_ALWAYS " in *" $cls "*) write_doc_multi "$FAKE_CANNED" "$cls:Passed"; echo "simulator crashed (stub)"; exit 70 ;; esac
      ;;
esac
write_doc_multi "$FAKE_CANNED" "$cls:Passed"
exit 0
EOF
  chmod +x "$STUBS/xcodebuild"
}

batch_invocations() { # $1 = exact batch line -> count
  grep -cx "$1" "$INVOCATION_LOG" 2>/dev/null || true
}
class_invocations() { # $1=class -> how many diagnosis invocations it got
  grep -c "^class:$1:" "$INVOCATION_LOG" 2>/dev/null || true
}



# ===========================================================================
# UNIT lane mode: sequential fresh-xcodebuild batches (one class per batch in
# these cases; the chunking itself is pinned in Python). Each case asserts
# the lane verdict, the batch attempt chains, exact invocation counts, and
# that a real failure can never be retried into a green lane.
# ===========================================================================

export INVOCATION_LOG="$WORK/invocations.log"
# The batch stub (re)writes this document per invocation to match its own
# verdict; b3 overrides it with a path that never exists.
export FAKE_CANNED="$WORK/canned-unit.json"

# --- unit case 1: every batch passes once -------------------------------------
end_case
begin_case "unit batches all pass" "$WORK/b1"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
run_lane "AlphaTests,BetaTests,GammaTests" 300 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
# The lane must settle the device (shutdown -> boot -> bootstatus) BEFORE the
# first xcodebuild: a Shutdown destination makes xcodebuild cold-boot it, and
# that launch is the one refused with the FBS/preflight/Busy wedge. Removing
# reset_and_boot_simulator from run_unit_batches deletes the boot/bootstatus
# lines and fails these.
_x1="$(seq_line "xcodebuild batch-1-a1")"
_sd="$(seq_line "simctl shutdown")"
_bt="$(seq_line "simctl boot")"
_bs="$(seq_line "simctl bootstatus")"
assert_eq "first xcodebuild recorded" "$([ -n "$_x1" ] && echo yes || echo no)" "yes"
assert_eq "lane start shuts the device down" "$([ -n "$_sd" ] && [ "$_sd" -lt "${_x1:-0}" ] && echo yes || echo no)" "yes"
assert_eq "settle boots the device before first xcodebuild" \
  "$(seq_between "$_sd" "$_x1" "$_bt")" "yes"
assert_eq "settle waits for bootstatus before first xcodebuild" \
  "$(seq_between "$_bt" "$_x1" "$_bs")" "yes"
# The settle is PREPARATION, never a retry: reset_and_boot_simulator 0 must
# never erase. Changing either new call site to erase=1 makes these fail.
assert_eq "lane start settle never erases" \
  "$(grep -cFx "simctl erase" "$SEQ_LOG" 2>/dev/null || true)" "0"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'passed', 'passed']"
assert_eq "batch statuses" "$(batch_statuses)" "['pass', 'pass', 'pass']"
assert_eq "batch 1 invoked once" "$(batch_invocations "batch-1-a1")" "1"
assert_eq "batch 2 invoked once" "$(batch_invocations "batch-2-a1")" "1"
assert_eq "batch 3 invoked once" "$(batch_invocations "batch-3-a1")" "1"
assert_eq "no batch retries" "$(batch_invocations "batch-1-a2")$(batch_invocations "batch-2-a2")$(batch_invocations "batch-3-a2")" "000"
assert_eq "no hung batch" "$(lane_field "['hung_batch']")" "None"
if grep -q -- "-retry-tests-on-failure" "$WORKCASE/stdout.log"; then
  ok "unit batches run under native flake retry"
else
  bad "unit batches must keep the native retry flags"
fi
assert_eq "merged per-class timings reach lane-result" \
  "$(lane_field "['class_seconds']")" \
  "{'AlphaTests': 0.1, 'BetaTests': 0.1, 'GammaTests': 0.1}"
if ls "$WORKCASE"/batch-*.xcresult >/dev/null 2>&1; then
  bad "clean batch bundles should be pruned from a green lane artifact"
else
  ok "clean batch bundles pruned from a green lane artifact"
fi

# --- unit case 1b: a degraded settle is best-effort preparation, never a failure ---
end_case
begin_case "unit lane start settle degrades best-effort" "$WORK/b1s"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
# FAKE_UI_RECOVERY_FAILS makes every stubbed bootstatus exit 1, so the new
# lane-start settle's bootstatus fails: with erase=0 that must WARN and
# continue (best-effort preparation), never fail or stall the lane.
export FAKE_UI_RECOVERY_FAILS="1"
run_lane "AlphaTests" 300 1
export FAKE_UI_RECOVERY_FAILS=""
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "batch invoked once" "$(batch_invocations "batch-1-a1")" "1"
if grep -q "bootstatus did not confirm" "$WORKCASE/stdout.log"; then
  ok "degraded settle warns instead of failing"
else
  bad "a settle whose bootstatus fails must warn, not fail the lane"
fi

# --- unit case 2: real test failure -> lane fails, NO batch retry --------------
end_case
begin_case "unit batch real failure" "$WORK/b2"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
FAKE_UNIT_B2_A1="fail65" run_lane "AlphaTests,BetaTests,GammaTests" 300 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'test-failures']"
assert_eq "batch statuses" "$(batch_statuses)" "['pass', 'test-failures', 'not_run']"
assert_eq "failing batch invoked exactly once" "$(batch_invocations "batch-2-a1")" "1"
assert_eq "no batch-level retry for a real failure" "$(batch_invocations "batch-2-a2")" "0"
assert_eq "later batches never ran" "$(batch_invocations "batch-3-a1")" "0"
assert_eq "failure attributed" "$(lane_field "['failures'][0]['class']")" "BetaTests"

# --- unit case 3: unclassified failure -> fail, never retried ------------------
end_case
begin_case "unit batch unclassified failure" "$WORK/b3"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
# Extraction must fail: the canned doc path never exists (and the stub is
# told not to write one), so the xcrun stub returns an invalid document.
FAKE_UNIT_NO_DOC="1" FAKE_UNIT_B2_A1="fail65" FAKE_CANNED="$WORK/does-not-exist-b3.json" \
  run_lane "AlphaTests,BetaTests" 300 3
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'unclassified']"
assert_eq "no retry after an unclassifiable batch" "$(batch_invocations "batch-2-a2")" "0"
assert_eq "batch statuses" "$(batch_statuses)" "['pass', 'unclassified']"

# --- unit case 4: watchdog stall -> same-batch retry once -> lane continues ----
end_case
begin_case "unit watchdog stall recovered by batch retry" "$WORK/b4"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
FAKE_UNIT_B2_A1="hang" FAKE_UNIT_B2_A2="pass" run_lane "AlphaTests,BetaTests,GammaTests" 3 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'timeout', 'passed', 'passed']"
assert_eq "batch attempt chain" "$(batch_attempt_chain 2)" "['timeout', 'passed']"
assert_eq "stalled batch invoked exactly twice" "$(batch_invocations "batch-2-a1")$(batch_invocations "batch-2-a2")" "11"
# The watchdog retry's fresh xcodebuild must also find a Booted device:
# between the timed-out attempt and its retry the runner must shut down,
# boot, and wait (bootstatus) again. Removing the settle from the timeout
# branch deletes boot/bootstatus between the two xcodebuild lines and fails.
_a1="$(seq_line "xcodebuild batch-2-a1")"
_a2="$(seq_line "xcodebuild batch-2-a2")"
_sd2="$(awk -v lo="${_a1:-0}" '$0=="simctl shutdown" && NR>lo {print NR; exit}' "$SEQ_LOG" 2>/dev/null)"
_bt2="$(awk -v lo="${_a1:-0}" '$0=="simctl boot" && NR>lo {print NR; exit}' "$SEQ_LOG" 2>/dev/null)"
_bs2="$(awk -v lo="${_a1:-0}" '$0=="simctl bootstatus" && NR>lo {print NR; exit}' "$SEQ_LOG" 2>/dev/null)"
assert_eq "retry path shuts the device down again" \
  "$([ -n "$_sd2" ] && [ -n "$_a2" ] && [ "$_sd2" -gt "$_a1" ] && [ "$_sd2" -lt "$_a2" ] && echo yes || echo no)" "yes"
assert_eq "retry path settles (boot+bootstatus) before attempt 2" \
  "$(seq_between "$_sd2" "$_a2" "$_bt2")$(seq_between "$_bt2" "$_a2" "$_bs2")" "yesyes"
# The timeout branch is shutdown + settle ONLY: its settle must never erase
# (that is the infra branch's contract, one line below). erase=1 here fails.
assert_eq "watchdog-retry settle never erases" \
  "$(grep -cFx "simctl erase" "$SEQ_LOG" 2>/dev/null || true)" "0"
assert_eq "lane continued after the recovered batch" "$(batch_invocations "batch-3-a1")" "1"
assert_eq "no hung batch on a recovered lane" "$(lane_field "['hung_batch']")" "None"
assert_eq "watchdog retry shutdown recorded (no erase)" \
  "$(lane_field "['simulator_reset']")$(lane_field "['simulator_erase']")" "TrueFalse"
if ls "$WORKCASE"/batch-1-*.xcresult >/dev/null 2>&1 || ls "$WORKCASE"/batch-3-*.xcresult >/dev/null 2>&1; then
  bad "clean batches' bundles must be pruned even when a sibling batch needed its retry"
else
  ok "only the recovered batch keeps its bundles"
fi
if ls "$WORKCASE"/batch-2-a1.xcresult >/dev/null 2>&1 && ls "$WORKCASE"/batch-2-a2.xcresult >/dev/null 2>&1; then
  ok "both stall-retry bundles kept on the green lane"
else
  bad "stall-retry bundles must be preserved (attempt 1 is the wedge evidence)"
fi

# --- unit case 5: second stall -> lane fails, batch named, exactly one retry ---
end_case
begin_case "unit batch stalls twice" "$WORK/b5"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
FAKE_UNIT_B2_A1="hang" FAKE_UNIT_B2_A2="hang" run_lane "AlphaTests,BetaTests,GammaTests" 3 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung batch named" "$(lane_field "['hung_batch']")" "2"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'timeout', 'timeout']"
assert_eq "batch statuses" "$(batch_statuses)" "['pass', 'timeout', 'not_run']"
assert_eq "exactly one retry, never a third invocation" "$(batch_invocations "batch-2-a1")$(batch_invocations "batch-2-a2")" "11"
assert_eq "later batches never ran on the stalled lane" "$(batch_invocations "batch-3-a1")" "0"

# --- unit case 6: infra wedge -> erase + same-batch retry -> green -------------
end_case
begin_case "unit infra wedge recovered by batch retry" "$WORK/b6"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
FAKE_UNIT_B2_A1="infra70" FAKE_UNIT_B2_A2="pass" run_lane "AlphaTests,BetaTests" 300 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "batch attempt chain" "$(batch_attempt_chain 2)" "['infra-error', 'passed']"
assert_eq "wedge batch invoked exactly twice" "$(batch_invocations "batch-2-a1")$(batch_invocations "batch-2-a2")" "11"
assert_eq "infra retry erases the simulator" "$(lane_field "['simulator_erase']")" "True"
assert_eq "batch statuses" "$(batch_statuses)" "['pass', 'pass']"

# --- unit case 7: persistent infra failure -> lane fails after its one retry ---
end_case
begin_case "unit persistent infra failure" "$WORK/b7"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
FAKE_UNIT_B2_A1="infra70" FAKE_UNIT_B2_A2="infra70" run_lane "AlphaTests,BetaTests,GammaTests" 300 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "error"
assert_eq "batch statuses" "$(batch_statuses)" "['pass', 'infra-error', 'not_run']"
assert_eq "wedge batch invoked exactly twice" "$(batch_invocations "batch-2-a1")$(batch_invocations "batch-2-a2")" "11"
assert_eq "later batches never ran" "$(batch_invocations "batch-3-a1")" "0"

# --- unit case 8: malformed batch layout refuses to start (fail closed) --------
end_case
begin_case "unit malformed batches json rejected" "$WORK/b8"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
# The batches carry fewer classes than the lane: a silent desync would run
# BetaTests with no plan record, so the runner must refuse BEFORE anything.
run_lane_raw "AlphaTests,BetaTests" '[{"classes":["AlphaTests"],"timeout_s":300}]'
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "2"
assert_eq "no xcodebuild invocation" "$(wc -l < "$INVOCATION_LOG" | tr -d ' ')" "0"
if [ -f "$WORKCASE/lane-result.json" ]; then
  bad "a rejected layout must not produce a lane result"
else
  ok "lane never started with a desynced batch layout"
fi
if grep -q "batches do not reproduce the lane class list" "$WORKCASE/stdout.log"; then
  ok "layout desync named as the reason"
else
  bad "layout desync must be named loudly"
fi
# Not even valid JSON is accepted.
run_lane_raw "AlphaTests" 'not json at all'
assert_eq "invalid json rejected" "$(cat "$WORKCASE/exit-code")" "2"
# A non-positive integer watchdog is rejected.
run_lane_raw "AlphaTests" '[{"classes":["AlphaTests"],"timeout_s":0}]'
assert_eq "non-positive batch watchdog rejected" "$(cat "$WORKCASE/exit-code")" "2"

# --- unit case 9: missing --batches-json refuses to start ----------------------
end_case
begin_case "unit missing batches json rejected" "$WORK/b9"
: > "$INVOCATION_LOG"
run_lane_missing_batches "AlphaTests"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "2"
assert_eq "no xcodebuild invocation" "$(wc -l < "$INVOCATION_LOG" | tr -d ' ')" "0"
if grep -q -- "--batches-json is required" "$WORKCASE/stdout.log"; then
  ok "missing batch table rejected loudly"
else
  bad "missing --batches-json must be rejected loudly"
fi

# --- unit case 12: stall WITH known failures is a test failure, no retry ------
# The batch retry is only for watchdog stalls with ZERO known failures: a
# batch whose killed xcresult still records surviving test failures must fail
# the lane exactly like an ordinary failure (real failures never convert into
# infrastructure recovery).
end_case
begin_case "unit stall with known failures never retried" "$WORK/b12"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
FAKE_UNIT_B2_A1="hangfail" run_lane "AlphaTests,BetaTests,GammaTests" 3 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'test-failures']"
assert_eq "batch statuses" "$(batch_statuses)" "['pass', 'test-failures', 'not_run']"
assert_eq "no batch retry for a failure-carrying stall" "$(batch_invocations "batch-2-a2")" "0"
assert_eq "later batches never ran" "$(batch_invocations "batch-3-a1")" "0"
assert_eq "failures attributed, not hidden" "$(lane_field "['failures'][0]['class']")" "BetaTests"

# --- unit case 13: exit-0 batch without a class record fails the lane ---------
# Defense in depth: an exit-0 batch whose parseable xcresult has no record of
# an assigned class must not finish as a clean pass (an -only-testing filter
# silently matching nothing), and there is no per-class diagnosis for units -
# the lane fails closed. Beta and Gamma share batch 2 so the omit leaves a
# VALID document that is merely missing one assigned class.
end_case
begin_case "unit pass with unrecorded class fails closed" "$WORK/b13"
: > "$INVOCATION_LOG"
reset_unit_stub_vars
FAKE_UNIT_OMIT="BetaTests" \
  run_lane_raw "AlphaTests,BetaTests,GammaTests" \
  '[{"classes":["AlphaTests"],"timeout_s":300},{"classes":["BetaTests","GammaTests"],"timeout_s":300}]'
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'incomplete']"
assert_eq "batch statuses" "$(batch_statuses)" "['pass', 'incomplete']"
assert_eq "no retry for an unaccountable batch" "$(batch_invocations "batch-2-a2")" "0"
assert_eq "later batches never ran" "$(batch_invocations "batch-3-a1")" "0"
if grep -q "exited 0 but the xcresult has no record" "$WORKCASE/stdout.log"; then
  ok "exit-0 pass with a missing class record announced"
else
  bad "an exit-0 batch with an unrecorded class must not pass silently"
fi

# --- unit case 10: finished session survives its budget via finalize grace -----
# Run #500 regression: xcodebuild printed its terminal result and was only
# finalizing the xcresult when the watchdog expired. The deadline must be
# extended ONCE (bounded grace) so the finished session can exit with its
# real status; success still comes from the exit status, never the marker.
end_case
begin_case "finalize grace lets a finished batch pass" "$WORK/b10"
: > "$INVOCATION_LOG"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
prev=""
for a in "$@"; do
  case "$prev" in -resultBundlePath) echo "$(basename "$a" .xcresult)" >> "$INVOCATION_LOG" ;; esac
  prev="$a"
done
echo "running tests (stub)"
sleep 4
echo "** TEST EXECUTE SUCCEEDED **"
echo "finalizing xcresult (stub)"
sleep 4
exit 0
EOF
chmod +x "$STUBS/xcodebuild"
export XCODEBUILD_FINALIZE_GRACE_S=30
write_canned "$WORK/canned-grace.json" "AlphaTests" "Passed"
run_lane "AlphaTests" 5 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed']"
if grep -q "finalize grace" "$WORKCASE/stdout.log"; then
  ok "finalize grace reported"
else
  bad "finalize grace must be reported when it fires"
fi

# --- unit case 11: grace is bounded - a wedged finalize is still a timeout -----
end_case
begin_case "finalize grace expiry kills, retry stalls, lane fails" "$WORK/b11"
: > "$INVOCATION_LOG"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
prev=""
for a in "$@"; do
  case "$prev" in -resultBundlePath) echo "$(basename "$a" .xcresult)" >> "$INVOCATION_LOG" ;; esac
  prev="$a"
done
echo "** TEST EXECUTE SUCCEEDED **"
echo "wedged finalization (stub)"
sleep 300
exit 0
EOF
chmod +x "$STUBS/xcodebuild"
export XCODEBUILD_FINALIZE_GRACE_S=3
run_lane "AlphaTests" 3 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "attempt chain" "$(attempts_statuses)" "['timeout', 'timeout']"
assert_eq "batch invoked exactly twice" "$(batch_invocations "batch-1-a1")$(batch_invocations "batch-1-a2")" "11"
if grep -q "finalize grace" "$WORKCASE/stdout.log"; then
  ok "grace was granted before the kill"
else
  bad "grace must be attempted before killing a finalized session"
fi

echo ""
end_case
echo "unit batch state machine: $pass_count passed, $fail_count failed so far"

# ===========================================================================
# UI lane mode: one batched shard invocation on the healthy path, per-class
# diagnosis + method-precise retry on failure paths.
# Runs even if unit cases failed so every case reports in one pass; the
# single summary at the bottom decides the exit code.
# ===========================================================================

write_stub_xcrun
write_ui_stub_xcodebuild
touch "$WORK/fake.xctestrun"
export FAKE_CANNED="$WORK/canned-ui.json"
UI_DEFAULTS='FAKE_BATCH_A1=pass FAKE_BATCH_RETRY=pass FAKE_BATCH_FAIL_CLASSES= FAKE_UI_NO_DOC='

# --- UI case 1: every class passes once - ONE batched invocation --------------
end_case
begin_case "ui batch all pass" "$WORK/u1"
export INVOCATION_LOG="$WORK/u1-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_BATCH_A1="pass" FAKE_BATCH_RETRY="pass" FAKE_BATCH_FAIL_CLASSES="" FAKE_UI_NO_DOC=""
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="" FAKE_UI_INFRA_ALWAYS="" FAKE_UI_HANG="" FAKE_UI_RECOVERY_FAILS=""
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 300 "AlphaUITests=200,BetaUITests=200,GammaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed']"
assert_eq "exactly one batch invocation" "$(batch_invocations 'batch-a1')" "1"
assert_eq "no per-class invocations on the happy path" "$(class_invocations AlphaUITests)$(class_invocations BetaUITests)$(class_invocations GammaUITests)" "000"
if grep -q -- "-retry-tests-on-failure" "$WORKCASE/stdout.log"; then
  bad "UI batches must not run under native multi-iteration retry"
else
  ok "UI batch invocation runs without native retry flags"
fi
assert_eq "merged per-class timings reach lane-result" \
  "$(lane_field "['class_seconds']")" \
  "{'AlphaUITests': 0.1, 'BetaUITests': 0.1, 'GammaUITests': 0.1}"
assert_eq "merged case counts" "$(python3 -c "
import json
print(json.load(open('$WORKCASE/observations.json'))['counts']['cases'])
" 2>/dev/null || echo NONE)" "3"
if ls "$WORKCASE"/batch-a*.xcresult >/dev/null 2>&1; then
  bad "clean batch bundles should be pruned from a green lane artifact"
else
  ok "clean batch bundles pruned from a green lane artifact"
fi

# --- UI case 2: flaky test recovered by a METHOD-precise retry ----------------
end_case
begin_case "ui flaky test recovered via method retry" "$WORK/u2"
export INVOCATION_LOG="$WORK/u2-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_BATCH_A1="fail-test" FAKE_BATCH_FAIL_CLASSES="BetaUITests" FAKE_BATCH_RETRY="pass"
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 300 "AlphaUITests=200,BetaUITests=200,GammaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['test-failures', 'passed']"
assert_eq "retried classes" "$(retried_classes)" "['BetaUITests']"
assert_eq "one batch attempt + one retry invocation" \
  "$(batch_invocations 'batch-a1')$(batch_invocations 'batch-a2 (filters: BetaUITests/testC())')" "11"
assert_eq "healthy classes never re-invoked" \
  "$(class_invocations AlphaUITests)$(class_invocations GammaUITests)" "00"
if grep -q "passed on its targeted retry" "$WORKCASE/stdout.log" \
   && grep -q "Retried tests:" "$WORKCASE/stdout.log"; then
  ok "recovered flake reported loudly with the retried tests"
else
  bad "a retry pass must be reported as a flake, not hidden"
fi
if ls "$WORKCASE"/batch-a1.xcresult >/dev/null 2>&1 && ls "$WORKCASE"/batch-a2.xcresult >/dev/null 2>&1; then
  ok "both flake attempt bundles kept on a green lane"
else
  bad "flake attempt bundles must be preserved on a green lane"
fi

# --- UI case 3: failure survives the retry -> lane fails, no false flake ------
end_case
begin_case "ui failure survives retry" "$WORK/u3"
export INVOCATION_LOG="$WORK/u3-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_BATCH_A1="fail-test" FAKE_BATCH_FAIL_CLASSES="BetaUITests" FAKE_BATCH_RETRY="fail"
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 300 "AlphaUITests=200,BetaUITests=200,GammaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['test-failures', 'test-failures']"
assert_eq "no false flake" "$(retried_classes)" "[]"
assert_eq "retry ran exactly once" "$(batch_invocations 'batch-a1')$(batch_invocations 'batch-a2 (filters: BetaUITests/testC())')" "11"

# --- UI case 4: batch timeout -> per-class diagnosis, hang attributed ---------
end_case
begin_case "ui batch timeout enters per-class diagnosis" "$WORK/u4"
export INVOCATION_LOG="$WORK/u4-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_BATCH_A1="hang" FAKE_BATCH_RETRY="pass" FAKE_BATCH_FAIL_CLASSES=""
export FAKE_UI_HANG="BetaUITests"
# Tiny per-class budgets keep the killed batch and the two hung diagnosis
# invocations fast; Beta's own budget applies in diagnosis mode.
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 3 "AlphaUITests=2,BetaUITests=2,GammaUITests=2"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung class" "$(lane_field "['hung_class']")" "BetaUITests"
assert_eq "attempts" "$(attempts_statuses)" \
  "['timeout', 'passed', 'timeout', 'timeout', 'not_diagnosed']"
assert_eq "Alpha diagnosed once" "$(class_invocations AlphaUITests)" "1"
assert_eq "Beta hung twice in diagnosis" "$(class_invocations BetaUITests)" "2"
assert_eq "Gamma never ran on the contaminated simulator" "$(class_invocations GammaUITests)" "0"
if grep -q "per-class diagnosis" "$WORKCASE/stdout.log"; then
  ok "batch timeout announced the diagnosis fallback"
else
  bad "batch timeout must enter per-class diagnosis"
fi

# --- UI case 5: batch infra wedge -> diagnosis; class infra recovers ----------
end_case
begin_case "ui batch infra enters diagnosis and recovers" "$WORK/u5"
export INVOCATION_LOG="$WORK/u5-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_BATCH_A1="infra" FAKE_UI_HANG=""
export FAKE_UI_INFRA_ONCE="AlphaUITests" FAKE_UI_INFRA_ALWAYS=""
run_ui_lane "AlphaUITests,BetaUITests" 300 "AlphaUITests=200,BetaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" \
  "['infra-error', 'infra-error', 'passed', 'passed']"
assert_eq "infra recovery is not a test flake" "$(retried_classes)" "[]"
assert_eq "infra recovery reported separately" \
  "$(lane_field "['infra_recovered_classes']")" "['AlphaUITests']"
assert_eq "Alpha diagnosed with its one retry" "$(class_invocations AlphaUITests)" "2"

# --- UI case 6: unclassified batch failure fails the lane without retry -------
end_case
begin_case "ui unclassified batch failure" "$WORK/u6"
export INVOCATION_LOG="$WORK/u6-invocations.log"; : > "$INVOCATION_LOG"
# Extraction must fail: the canned doc path never exists (and the stub never
# writes it), so the xcrun stub returns an invalid document.
export FAKE_CANNED="$WORK/does-not-exist-u6.json"
export FAKE_UI_NO_DOC=1
export FAKE_BATCH_A1="fail-test" FAKE_BATCH_RETRY="pass" FAKE_BATCH_FAIL_CLASSES="AlphaUITests"
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="" FAKE_UI_INFRA_ALWAYS="" FAKE_UI_HANG="" FAKE_UI_RECOVERY_FAILS=""
run_ui_lane "AlphaUITests,BetaUITests" 300 "AlphaUITests=200,BetaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['unclassified', 'not_diagnosed', 'not_diagnosed']"
assert_eq "no retry after an unclassifiable batch" "$(batch_invocations 'batch-a2 (filters: BetaUITests/testC())')" "0"
export FAKE_CANNED="$WORK/canned-ui.json"
export FAKE_UI_NO_DOC=""

# --- UI case 7: persistent infra failure in diagnosis fails the lane ----------
end_case
begin_case "ui persistent infra in diagnosis continues lane" "$WORK/u7"
export INVOCATION_LOG="$WORK/u7-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_NO_DOC=""
export FAKE_BATCH_A1="infra" FAKE_UI_HANG=""
export FAKE_UI_INFRA_ONCE="" FAKE_UI_INFRA_ALWAYS="AlphaUITests" FAKE_UI_RECOVERY_FAILS=""
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 300 "AlphaUITests=200,BetaUITests=200,GammaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" \
  "['infra-error', 'infra-error', 'infra-error', 'passed', 'passed']"
assert_eq "persistent infra class named" \
  "$(lane_field "['persistent_infra_classes']")" "['AlphaUITests']"
assert_eq "persistent infra is not a flake" "$(retried_classes)" "[]"
assert_eq "Alpha retried once, not looped" "$(class_invocations AlphaUITests)" "2"
assert_eq "Beta executed after the persistent failure" "$(class_invocations BetaUITests)" "1"
assert_eq "Gamma executed after the persistent failure" "$(class_invocations GammaUITests)" "1"
if grep -q "not_diagnosed" "$WORKCASE/lane-result.json"; then
  bad "persistent infra failure must not mark healthy classes not_diagnosed"
else
  ok "no not_diagnosed entries after a persistent infra failure"
fi

# --- UI case 8: untrusted simulator recovery stops the lane -------------------
end_case
begin_case "ui recovery failure stops lane" "$WORK/u8"
export INVOCATION_LOG="$WORK/u8-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_NO_DOC=""
export FAKE_BATCH_A1="infra" FAKE_UI_HANG=""
export FAKE_UI_INFRA_ONCE="AlphaUITests" FAKE_UI_INFRA_ALWAYS="" FAKE_UI_RECOVERY_FAILS="1"
run_ui_lane "AlphaUITests,BetaUITests" 300 "AlphaUITests=200,BetaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "error"
assert_eq "attempts" "$(attempts_statuses)" "['infra-error', 'not_diagnosed', 'not_diagnosed']"
assert_eq "Beta never ran on an untrusted simulator" "$(class_invocations BetaUITests)" "0"

# --- UI case 9: retry-timeout falls back to diagnosis of the retried class ----
end_case
begin_case "ui retry timeout diagnoses the retried class" "$WORK/u9"
export INVOCATION_LOG="$WORK/u9-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_NO_DOC=""
export FAKE_BATCH_A1="fail-test" FAKE_BATCH_FAIL_CLASSES="BetaUITests" FAKE_BATCH_RETRY="hang"
export FAKE_UI_HANG="BetaUITests" FAKE_UI_INFRA_ONCE="" FAKE_UI_INFRA_ALWAYS="" FAKE_UI_RECOVERY_FAILS=""
run_ui_lane "AlphaUITests,BetaUITests" 3 "AlphaUITests=2,BetaUITests=2"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung class" "$(lane_field "['hung_class']")" "BetaUITests"
assert_eq "attempts" "$(attempts_statuses)" \
  "['test-failures', 'timeout', 'timeout', 'timeout']"
assert_eq "Alpha never re-ran after its batch pass" "$(class_invocations AlphaUITests)" "0"

# --- UI case 12: batch aborted before a class ran -> diagnosis, no retry -----
# A batch whose xcresult has no record of an assigned class can never be
# retried into a green lane: the unexecuted class forces per-class diagnosis.
end_case
begin_case "ui incomplete batch diagnoses instead of retrying" "$WORK/u12"
export INVOCATION_LOG="$WORK/u12-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_NO_DOC="" FAKE_UI_HANG=""
export FAKE_BATCH_A1="fail-test" FAKE_BATCH_FAIL_CLASSES="BetaUITests" FAKE_BATCH_RETRY="pass"
export FAKE_BATCH_SKIP_CLASSES="" FAKE_BATCH_OMIT_CLASSES="GammaUITests"
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="" FAKE_UI_INFRA_ALWAYS="" FAKE_UI_RECOVERY_FAILS=""
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 300 "AlphaUITests=200,BetaUITests=200,GammaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" \
  "['incomplete', 'passed', 'passed', 'passed']"
assert_eq "no targeted retry for an incomplete batch" "$(batch_invocations 'batch-a1')$(batch_invocations 'batch-a2 (filters: BetaUITests/testC())')" "10"
assert_eq "every class diagnosed exactly once" \
  "$(class_invocations AlphaUITests)$(class_invocations BetaUITests)$(class_invocations GammaUITests)" "111"
if grep -q "batch aborted before executing" "$WORKCASE/stdout.log"; then
  ok "incomplete batch announced the missing class"
else
  bad "an incomplete batch must name the unexecuted class"
fi
export FAKE_BATCH_OMIT_CLASSES=""

# --- UI case 13: a Skipped final is non-passing and joins the retry ----------
end_case
begin_case "ui skipped final joins the retry filters" "$WORK/u13"
export INVOCATION_LOG="$WORK/u13-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_NO_DOC="" FAKE_UI_HANG="" FAKE_BATCH_OMIT_CLASSES=""
export FAKE_BATCH_A1="fail-test" FAKE_BATCH_FAIL_CLASSES="BetaUITests" FAKE_BATCH_RETRY="pass"
export FAKE_BATCH_SKIP_CLASSES="BetaUITests"
run_ui_lane "AlphaUITests,BetaUITests" 300 "AlphaUITests=200,BetaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "failed and skipped tests both retried" \
  "$(batch_invocations 'batch-a2 (filters: BetaUITests/testC() BetaUITests/testD())')" "1"
assert_eq "attempts" "$(attempts_statuses)" "['test-failures', 'passed']"

# --- UI case 14: exit-0 batch missing a class -> diagnosis, never green ------
# Defense in depth: an exit-0 batch whose parseable xcresult has no record of
# an assigned class (an -only-testing filter silently matching nothing) must
# not finish as a clean pass.
end_case
begin_case "ui pass with unrecorded class diagnoses" "$WORK/u14"
export INVOCATION_LOG="$WORK/u14-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_NO_DOC="" FAKE_UI_HANG=""
export FAKE_BATCH_A1="pass" FAKE_BATCH_RETRY="pass" FAKE_BATCH_FAIL_CLASSES=""
export FAKE_BATCH_SKIP_CLASSES="" FAKE_BATCH_OMIT_CLASSES="BetaUITests"
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="" FAKE_UI_INFRA_ALWAYS="" FAKE_UI_RECOVERY_FAILS=""
run_ui_lane "AlphaUITests,BetaUITests" 300 "AlphaUITests=200,BetaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" \
  "['incomplete', 'passed', 'passed']"
assert_eq "no targeted retry for an unrecorded class" \
  "$(batch_invocations 'batch-a1')$(batch_invocations 'batch-a2 (filters: testC())')" "10"
assert_eq "missing class diagnosed" "$(class_invocations BetaUITests)" "1"
if grep -q "exited 0 but the xcresult has no record" "$WORKCASE/stdout.log"; then
  ok "exit-0 pass with a missing class announced the diagnosis"
else
  bad "an exit-0 batch with an unrecorded class must not pass silently"
fi
export FAKE_BATCH_OMIT_CLASSES=""

# --- UI case 15: diagnosis METHOD-only retry never becomes class timing ------
# A diagnosis retry filtered down to the failed methods must not leave an
# observations part behind: only the attempt-1 full-class invocation owns the
# class's timing-history sample (the batch path obeys the same rule).
begin_case "ui diagnosis method retry keeps class timing" "$WORK/u15"
export INVOCATION_LOG="$WORK/u15-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_NO_DOC="" FAKE_BATCH_OMIT_CLASSES="" FAKE_BATCH_SKIP_CLASSES=""
export FAKE_BATCH_A1="hang" FAKE_BATCH_RETRY="pass" FAKE_BATCH_FAIL_CLASSES=""
export FAKE_UI_FAIL_ONCE="AlphaUITests" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="" FAKE_UI_INFRA_ALWAYS="" FAKE_UI_HANG="" FAKE_UI_RECOVERY_FAILS=""
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 3 "AlphaUITests=2,BetaUITests=2,GammaUITests=2"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" \
  "['timeout', 'test-failures', 'passed', 'passed', 'passed']"
assert_eq "retried classes" "$(retried_classes)" "['AlphaUITests']"
if [ -f "$WORKCASE/parts/observations-AlphaUITests-a2.json" ]; then
  bad "method-only retry observations must not fold into timing history"
else
  ok "method-only retry observations removed"
fi
if [ -f "$WORKCASE/parts/detail-AlphaUITests-a2.json" ]; then
  ok "method-only retry detail kept as flake evidence"
else
  bad "method-only retry detail (flake evidence) must be kept"
fi

# --- UI case 16: same rule when the diagnosis method retry FAILS -------------
begin_case "ui failing diagnosis method retry keeps rule" "$WORK/u16"
export INVOCATION_LOG="$WORK/u16-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_NO_DOC="" FAKE_UI_HANG=""
export FAKE_BATCH_A1="hang" FAKE_BATCH_RETRY="pass" FAKE_BATCH_FAIL_CLASSES=""
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="AlphaUITests" FAKE_UI_RECOVERY_FAILS=""
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 3 "AlphaUITests=2,BetaUITests=2,GammaUITests=2"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "no false flake" "$(retried_classes)" "[]"
if [ -f "$WORKCASE/parts/observations-AlphaUITests-a2.json" ]; then
  bad "failing method-only retry observations must not fold either"
else
  ok "failing method-only retry observations removed"
fi

# --- UI case 10: a class without a planned watchdog refuses to start ----------
end_case
begin_case "ui missing watchdog entry rejected" "$WORK/u10"
export INVOCATION_LOG="$WORK/u10-invocations.log"; : > "$INVOCATION_LOG"
run_ui_lane "AlphaUITests,BetaUITests" 300 "AlphaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "2"
if grep -q "BetaUITests has no watchdog in --class-timeouts" "$WORKCASE/stdout.log"; then
  ok "missing watchdog entry named the uncovered class"
else
  bad "missing watchdog entry must be rejected naming the class"
fi
if [ -f "$WORKCASE/lane-result.json" ]; then
  bad "no class may run when the watchdog table is incomplete"
else
  ok "lane never started with an incomplete watchdog table"
fi

# --- UI case 11: malformed watchdog entries are rejected ----------------------
end_case
begin_case "ui malformed watchdog entry rejected" "$WORK/u11"
run_ui_lane "AlphaUITests" 300 "AlphaUITests=abc"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "2"
if grep -q "must be a positive integer" "$WORKCASE/stdout.log"; then
  ok "malformed watchdog value rejected"
else
  bad "malformed watchdog value must fail immediately"
fi

# --- unit case 12: ambiguous device name fails the lane closed ----------------
end_case
begin_case "ambiguous simulator name refused" "$WORK/u12"
# The UI cases above REPLACE $STUBS/xcodebuild with their own stub; these are
# unit cases again, so reinstall the unit-batch stub and reset its knobs.
write_unit_batch_stub_xcodebuild
reset_unit_stub_vars
export FAKE_SIMCTL_DUPLICATE=1
run_lane "AlphaTests" 300 1
unset FAKE_SIMCTL_DUPLICATE
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
if grep -q "is ambiguous" "$WORKCASE/stdout.log"; then
  ok "ambiguity refused by name"
else
  bad "ambiguous name must be refused"
fi
if grep -q "refusing to shut down" "$WORKCASE/stdout.log"; then
  ok "nothing was shut down"
else
  bad "ambiguous name must not touch any simulator"
fi

# --- unit case 13: a run-owned UDID pin is authoritative ------------------------
# Same duplicate inventory, but the caller pinned this run's UDID: the pin
# is unique and never recycled, so the lane proceeds without guessing.
end_case
begin_case "run-owned UDID pin bypasses ambiguity" "$WORK/u13"
write_unit_batch_stub_xcodebuild
reset_unit_stub_vars
export FAKE_SIMCTL_DUPLICATE=1
export SIMULATOR_UDID="6D08B063-B890-4D18-893B-D1E89E119919"
run_lane "AlphaTests" 300 1
unset FAKE_SIMCTL_DUPLICATE
unset SIMULATOR_UDID
cp "$WORKCASE/stdout.log" /c/Users/Micro/.dsh/tmp/u13-stdout.log 2>/dev/null || cp "$WORKCASE/stdout.log" /tmp/u13-stdout.log
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
if grep -q "is ambiguous" "$WORKCASE/stdout.log"; then
  bad "a pinned UDID must not consult the ambiguous name"
else
  ok "pin was authoritative"
fi

echo ""
end_case
echo "lane-runner state machine: $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ] || exit 1
echo "ALL CASES PASSED"
exit 0
