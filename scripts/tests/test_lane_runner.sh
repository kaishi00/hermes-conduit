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
echo ""
echo "lane-runner state machine: $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ] || exit 1
echo "ALL CASES PASSED"
exit 0
