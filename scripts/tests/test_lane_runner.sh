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
WORK="$(mktemp -d)"
STUBS="$WORK/stubs"
mkdir -p "$STUBS"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0

ok()   { pass_count=$((pass_count + 1)); echo "  ok: $1"; }
bad()  { fail_count=$((fail_count + 1)); echo "  FAIL: $1"; }

assert_eq() { # $1=desc $2=actual $3=expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}

write_stub_xcodebuild() {
  cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
COUNT_FILE="$COUNT_FILE"
if [ "$FAKE_MODE" = "infra-once" ]; then
  n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$COUNT_FILE"
  if [ "$n" -eq 1 ]; then
    echo "simulator crashed (stub)"
    exit 70
  fi
  exit 0
fi
case "$FAKE_MODE" in
  pass) exit 0 ;;
  fail65) echo "Test Case failed (stub)"; exit 65 ;;
  infra70) echo "Simulator boot failed (stub)"; exit 70 ;;
  hang) sleep 300; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$STUBS/xcodebuild"
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
  # The erase-gated simulator recovery must be able to SUCCEED in tests, so
  # simctl list -j serves one pinned device (matching the default
  # SIMULATOR_NAME) for ci-lib's jq-based UDID resolution.
  if [ "$2 $3 $4 $5" = "list devices available -j" ]; then
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
write_stub_xcodebuild
write_stub_xcrun
touch "$WORK/fake.xctestrun"
# The stub xcodebuild invocations exit instantly; a full 15s poll interval
# per invocation would dominate the suite's wall clock (and blow the plan
# job's budget), so shrink the cadence. Behavior under test is unaffected:
# the deadline math and kill semantics are identical at any cadence.
export XCODEBUILD_POLL_INTERVAL_S=1

begin_case() { # $1=name $2=workdir
  current="$1"
  WORKCASE="$2"
  mkdir -p "$2"
}

run_lane() { # $1=classes $2=timeout $3=mode $4=iterations
  _classes="$1"; _timeout="$2"; _mode="$3"; _iters="$4"; shift 4
  FAKE_MODE="$_mode" CLASS_TIMEOUT_MIN_S="1" CLASS_TIMEOUT_MULTIPLIER="0.1"     bash "$SCRIPTS/ci-test-lane.sh"     --kind unit --lane unit-t --target ConduitTests     --classes "$_classes"     --predicted 42 --timeout "$_timeout"     --iterations "$_iters"     --xctestrun "$WORK/fake.xctestrun"     --result-dir "$WORKCASE" >"$WORKCASE/stdout.log" 2>&1
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

isolation_statuses() {
  python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
print([c['status'] for c in (d.get('isolation') or {}).get('classes', [])])
" "$WORKCASE/lane-result.json" 2>/dev/null || echo NONE
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
  CLASS_TIMEOUT_MIN_S="1" CLASS_TIMEOUT_MULTIPLIER="0.1"     bash "$SCRIPTS/ci-test-lane.sh"     --kind ui --lane ui-t --target ConduitUITests     --classes "$_classes"     --class-timeouts "$_cto"     --predicted 42 --timeout "$_timeout"     --xctestrun "$WORK/fake.xctestrun"     --result-dir "$WORKCASE" >"$WORKCASE/stdout.log" 2>&1
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
write_doc_multi() {
  docfile="$1"; shift
  nodes=""
  sep=""
  for pair in "$@"; do
    c="${pair%%:*}"; r="${pair#*:}"
    nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"$c\", \"result\": \"$r\",
      \"children\": [{\"nodeType\": \"Test Case\", \"name\": \"testC()\", \"result\": \"$r\",
      \"durationInSeconds\": 0.1}]}"
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

if [ "$mode" = "batch" ]; then
  case "$kind" in
    a1)
      echo "batch-a1" >> "$INVOCATION_LOG"
      [ -n "${FAKE_UI_NO_DOC:-}" ] || write_all_passed $classes
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
          for c in $classes; do
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
      [ -n "${FAKE_UI_NO_DOC:-}" ] || write_all_passed $classes
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
          for c in $classes; do pairs="$pairs $c:Failed"; done
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



# --- case 1: pass -------------------------------------------------------------
begin_case "pass path" "$WORK/c1"
write_canned "$WORK/canned-pass.json" "AlphaTests" "Passed"
run_lane "AlphaTests" 300 pass 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed']"

# --- case 2: ordinary failure -> fail, no lane retry --------------------------
begin_case "ordinary failure" "$WORK/c2"
write_canned "$WORK/canned-fail.json" "AlphaTests" "Failed"
run_lane "AlphaTests" 300 fail65 3
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['test-failures']"
if grep -q "attempt 2" "$WORKCASE/stdout.log"; then
  bad "ordinary failure must not trigger a full-lane retry"
else
  ok "no full-lane retry after ordinary failure"
fi

# --- case 3: unclassified failure -> fail, never retried ----------------------
begin_case "unclassified failure" "$WORK/c3"
# Extraction must fail: xcrun returns an invalid document (no canned file).
export FAKE_CANNED="$WORK/does-not-exist.json"
run_lane "AlphaTests" 300 fail65 3
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['unclassified']"
if grep -q "attempt 2" "$WORKCASE/stdout.log"; then
  bad "unclassified failure must not be retried into a second lane run"
else
  ok "unclassified failure not retried"
fi

# --- case 4: infra failure -> exactly one full-lane retry, then error ---------
begin_case "infra failure retry" "$WORK/c4"
write_canned "$WORK/canned-pass2.json" "AlphaTests" "Passed"
run_lane "AlphaTests" 300 infra70 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "error"
assert_eq "attempts" "$(attempts_statuses)" "['infra-error', 'infra-error']"


# --- case 5: timeout -> isolation directly, hang identified -------------------
begin_case "timeout isolation" "$WORK/c5"
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests" 3 hang 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung class" "$(lane_field "['hung_class']")" "AlphaTests"
assert_eq "first attempt" "$(attempts_statuses | grep -o 'timeout' | head -1)" "timeout"
if grep -q "lane-retry" "$WORKCASE/lane-result.json"; then
  bad "timeout must not do a second full-lane attempt"
else
  ok "no full-lane retry after timeout"
fi
assert_eq "isolation ran" "$(isolation_statuses)" "['timeout', 'not_diagnosed']"

# --- case 6: incomplete isolation fails the lane ------------------------------
begin_case "incomplete isolation" "$WORK/c6"
export ISOLATION_BUDGET_S=2 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests" 3 hang 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "isolation statuses" "$(isolation_statuses)" "['not_diagnosed', 'not_diagnosed']"
if grep -q "undiagnosed classes" "$WORKCASE/stdout.log"; then
  ok "undiagnosed classes reported"
else
  bad "undiagnosed classes must be reported loudly"
fi

if grep -q "undiagnosed classes" "$WORKCASE/stdout.log"; then
  ok "undiagnosed classes reported"
else
  bad "undiagnosed classes must be reported loudly"
fi


# --- case 7: isolation stops after the first confirmed hang ------
# Spec scenario: AlphaTests PASSES, BetaTests TIMES OUT, GammaTests
# would pass if called - but must NEVER run on the contaminated
# simulator. Tracks exact xcodebuild invocation counts via the stub.
begin_case "stop after hang" "$WORK/c7"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
n=$(printf '%s\n' "$@" | grep -c -- '-only-testing:' || true)
if [ "$n" -gt 1 ]; then
  echo "full" >> "$INVOCATION_LOG"
  sleep 300
  exit 0
fi
cls=$(printf '%s\n' "$@" | grep 'only-testing:' | head -1 | sed 's|.*/||')
echo "iso:$cls" >> "$INVOCATION_LOG"
case "$cls" in
  BetaTests) sleep 300; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUBS/xcodebuild"
INVOCATION_LOG="$WORK/c7-invocations.log"
: > "$INVOCATION_LOG"
export INVOCATION_LOG
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests,GammaTests" 3 hang-second 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung class" "$(lane_field "['hung_class']")" "BetaTests"
assert_eq "full lane run once" "$(grep -c '^full$' "$INVOCATION_LOG")" "1"
assert_eq "isolation statuses" "$(isolation_statuses)" "['pass', 'timeout', 'not_diagnosed']"
assert_eq "AlphaTests invoked once" "$(grep -c '^iso:AlphaTests$' "$INVOCATION_LOG")" "1"
assert_eq "BetaTests invoked once" "$(grep -c '^iso:BetaTests$' "$INVOCATION_LOG")" "1"
assert_eq "GammaTests never invoked" "$(grep -c '^iso:GammaTests$' "$INVOCATION_LOG")" "0"

# --- case 8: finished session survives its budget via finalize grace ----------
# Run #500 regression: xcodebuild printed its terminal result and was only
# finalizing the xcresult when the watchdog expired. The deadline must be
# extended ONCE (bounded grace) so the finished session can exit with its
# real status; success still comes from the exit status, never the marker.
begin_case "finalize grace lets a finished invocation pass" "$WORK/c8"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
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
run_lane "AlphaTests" 5 pass 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed']"
if grep -q "finalize grace" "$WORKCASE/stdout.log"; then
  ok "finalize grace reported"
else
  bad "finalize grace must be reported when it fires"
fi

# --- case 9: grace is bounded - a wedged finalize is still a timeout ----------
begin_case "finalize grace expiry kills and isolates" "$WORK/c9"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
echo "** TEST EXECUTE SUCCEEDED **"
echo "wedged finalization (stub)"
sleep 300
exit 0
EOF
chmod +x "$STUBS/xcodebuild"
export XCODEBUILD_FINALIZE_GRACE_S=3
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests" 3 pass 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "first attempt" "$(attempts_statuses | grep -o 'timeout' | head -1)" "timeout"
if grep -q "finalize grace" "$WORKCASE/stdout.log"; then
  ok "grace was granted before the kill"
else
  bad "grace must be attempted before killing a finalized session"
fi

# --- case 10: infra failure recovers on the single post-reset retry -----------
begin_case "infra retry recovers to green" "$WORK/c10"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$COUNT_FILE"
if [ "$n" -eq 1 ]; then
  echo "simulator crashed once (stub)"
  exit 70
fi
exit 0
EOF
chmod +x "$STUBS/xcodebuild"
export COUNT_FILE="$WORK/c10-count"
: > "$COUNT_FILE"
write_canned "$WORK/canned-c10.json" "AlphaTests" "Passed"
run_lane "AlphaTests" 300 infra-once 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['infra-recovered', 'passed']"

# --- case 11: class failure during isolation fails the lane --------------------
begin_case "class failure during isolation" "$WORK/c11"
cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
n=$(printf '%s\n' "$@" | grep -c -- '-only-testing:' || true)
if [ "$n" -gt 1 ]; then
  sleep 300
  exit 0
fi
exit 65
EOF
chmod +x "$STUBS/xcodebuild"
export ISOLATION_BUDGET_S=200 CLASS_TIMEOUT_MIN_S=1 CLASS_TIMEOUT_MULTIPLIER=0.1
run_lane "AlphaTests,BetaTests" 3 fail65 1
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "isolation statuses" "$(isolation_statuses)" "['fail', 'fail']"

echo ""
echo "unit+isolation state machine: $pass_count passed, $fail_count failed so far"

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
if grep -q "PASSED on its targeted retry" "$WORKCASE/stdout.log"; then
  ok "recovered flake reported loudly"
else
  bad "a retry pass must be reported as a flake, not hidden"
fi
if ls "$WORKCASE"/batch-a1.xcresult >/dev/null 2>&1 && ls "$WORKCASE"/batch-a2.xcresult >/dev/null 2>&1; then
  ok "both flake attempt bundles kept on a green lane"
else
  bad "flake attempt bundles must be preserved on a green lane"
fi

# --- UI case 3: failure survives the retry -> lane fails, no false flake ------
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

# --- UI case 10: a class without a planned watchdog refuses to start ----------
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
begin_case "ui malformed watchdog entry rejected" "$WORK/u11"
run_ui_lane "AlphaUITests" 300 "AlphaUITests=abc"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "2"
if grep -q "must be a positive integer" "$WORKCASE/stdout.log"; then
  ok "malformed watchdog value rejected"
else
  bad "malformed watchdog value must fail immediately"
fi

echo ""
echo "lane-runner state machine: $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ] || exit 1
echo "ALL CASES PASSED"
exit 0
