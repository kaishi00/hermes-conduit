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

# Stub that decides per class AND per attempt: classes listed in
# $FAKE_UI_FAIL_ONCE fail attempt 1 (exit 65, Failed canned doc) and pass
# their retry; $FAKE_UI_FAIL_ALWAYS classes always fail; $FAKE_UI_HANG
# classes sleep past any budget; $FAKE_UI_INFRA_ONCE classes fail attempt 1
# with an infrastructure-looking exit 70 and zero failing tests. Every
# invocation rewrites the canned xcresult document to match its own verdict,
# so the runner's classification sees the right detail.
write_ui_stub_xcodebuild() {
  cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
cls=$(printf '%s\n' "$@" | grep 'only-testing:' | head -1 | sed 's|.*/||')
attempt=a1
printf '%s\n' "$@" | grep -q '\-a2\.xcresult' && attempt=a2
echo "ui:$cls:$attempt" >> "$INVOCATION_LOG"
# Real xcodebuild creates the result bundle directory; create it so cleanup
# and bundle-preservation assertions exercise the real paths.
for a in "$@"; do
  case "$a" in
    *.xcresult) mkdir -p "$a" ;;
  esac
done
write_doc() { # $1=TestClass $2=Passed|Failed
  [ -n "${FAKE_UI_NO_DOC:-}" ] && return 0
  cat > "$FAKE_CANNED" <<DOC
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "UI test bundle", "name": "ConduitUITests", "result": "Passed",
    "children": [{"nodeType": "Test Suite", "name": "$1", "result": "Passed",
      "children": [{"nodeType": "Test Case", "name": "testC()", "result": "$2",
        "durationInSeconds": 0.1}]}]}]}]}
DOC
}
case " $FAKE_UI_FAIL_ONCE " in *" $cls "*)
  if [ "$attempt" = a1 ]; then write_doc "$cls" Failed; echo "Test Case failed (stub)"; exit 65; fi
  write_doc "$cls" Passed; exit 0 ;;
esac
case " $FAKE_UI_FAIL_ALWAYS " in *" $cls "*) write_doc "$cls" Failed; echo "Test Case failed (stub)"; exit 65 ;; esac
case " $FAKE_UI_INFRA_ONCE " in *" $cls "*)
  if [ "$attempt" = a1 ]; then write_doc "$cls" Passed; echo "simulator crashed (stub)"; exit 70; fi
  write_doc "$cls" Passed; exit 0 ;;
esac
case " $FAKE_UI_HANG " in *" $cls "*) sleep 300; exit 0 ;; esac
write_doc "$cls" Passed
exit 0
EOF
  chmod +x "$STUBS/xcodebuild"
}

ui_invocations() { # $1=class -> how many times that class was invoked
  grep -c "^ui:$1:" "$INVOCATION_LOG" 2>/dev/null || true
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
# UI lane mode: per-class invocations, per-class watchdogs, targeted retry.
# Runs even if unit cases failed so every case reports in one pass; the
# single summary at the bottom decides the exit code.
# ===========================================================================

write_stub_xcrun
write_ui_stub_xcodebuild
touch "$WORK/fake.xctestrun"
export FAKE_CANNED="$WORK/canned-ui.json"

# --- UI case 1: every class passes once - one invocation per class ------------
begin_case "ui all pass" "$WORK/u1"
export INVOCATION_LOG="$WORK/u1-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="" FAKE_UI_HANG=""
run_ui_lane "AlphaUITests,BetaUITests" 300 "AlphaUITests=200,BetaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'passed']"
assert_eq "Alpha invoked once" "$(ui_invocations AlphaUITests)" "1"
assert_eq "Beta invoked once" "$(ui_invocations BetaUITests)" "1"
if grep -q -- "-retry-tests-on-failure" "$WORKCASE/stdout.log"; then
  bad "UI classes must not run under native multi-iteration retry"
else
  ok "UI class invocations run without native retry flags"
fi
if [ -f "$WORKCASE/lane-result.json" ] && grep -q '"class": "AlphaUITests"' "$WORKCASE/lane-result.json"; then
  ok "attempt chain records the owning class"
else
  bad "attempt chain must record the owning class"
fi

# --- UI case 2: flaky class passes on the targeted retry ----------------------
begin_case "ui flaky class recovered" "$WORK/u2"
export INVOCATION_LOG="$WORK/u2-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_FAIL_ONCE="BetaUITests"
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 300 "AlphaUITests=200,BetaUITests=200,GammaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'test-failures', 'passed', 'passed']"
assert_eq "retried classes" "$(retried_classes)" "['BetaUITests']"
assert_eq "Alpha never rerun" "$(ui_invocations AlphaUITests)" "1"
assert_eq "Beta retried exactly once" "$(ui_invocations BetaUITests)" "2"
assert_eq "Gamma still ran" "$(ui_invocations GammaUITests)" "1"
if grep -q "PASSED on its targeted retry" "$WORKCASE/stdout.log"; then
  ok "recovered flake reported loudly"
else
  bad "a retry pass must be reported as a flake, not hidden"
fi
if [ -d "$WORKCASE" ] && ls "$WORKCASE"/class-BetaUITests-a*.xcresult >/dev/null 2>&1; then
  ok "both flake attempt bundles kept on a green lane"
else
  bad "flake attempt bundles must be preserved on a green lane"
fi
if ls "$WORKCASE"/class-AlphaUITests-a*.xcresult >/dev/null 2>&1; then
  bad "clean class bundles should be pruned from a green lane artifact"
else
  ok "clean class bundles pruned from a green lane artifact"
fi

# --- UI case 3: class failing both attempts fails the lane, others still run --
begin_case "ui class fails twice" "$WORK/u3"
export INVOCATION_LOG="$WORK/u3-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="BetaUITests" FAKE_UI_INFRA_ONCE="" FAKE_UI_HANG=""
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 300 "AlphaUITests=200,BetaUITests=200,GammaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'test-failures', 'test-failures', 'passed']"
assert_eq "Beta retried once, not looped" "$(ui_invocations BetaUITests)" "2"
assert_eq "Gamma ran after the failure" "$(ui_invocations GammaUITests)" "1"
assert_eq "no false flake" "$(retried_classes)" "[]"

# --- UI case 4: hung class identified after its one retry; lane stops ---------
begin_case "ui hang identified and lane stops" "$WORK/u4"
export INVOCATION_LOG="$WORK/u4-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="" FAKE_UI_HANG="BetaUITests"
run_ui_lane "AlphaUITests,BetaUITests,GammaUITests" 300 "AlphaUITests=200,BetaUITests=3,GammaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung class" "$(lane_field "['hung_class']")" "BetaUITests"
assert_eq "attempts" "$(attempts_statuses)" "['passed', 'timeout', 'timeout', 'not_diagnosed']"
assert_eq "Beta hung twice, then stopped" "$(ui_invocations BetaUITests)" "2"
assert_eq "Gamma never ran on the contaminated simulator" "$(ui_invocations GammaUITests)" "0"

# --- UI case 5: infra failure recovers via the single class retry -------------
begin_case "ui infra failure recovers" "$WORK/u5"
export INVOCATION_LOG="$WORK/u5-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="AlphaUITests" FAKE_UI_HANG=""
run_ui_lane "AlphaUITests" 300 "AlphaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "0"
assert_eq "verdict" "$(lane_field "['status']")" "pass"
assert_eq "attempts" "$(attempts_statuses)" "['infra-error', 'passed']"
assert_eq "Alpha invoked twice" "$(ui_invocations AlphaUITests)" "2"
assert_eq "infra recovery is not a test flake" "$(retried_classes)" "[]"

# --- UI case 6: unclassified failure fails the lane without retry -------------
begin_case "ui unclassified failure" "$WORK/u6"
export INVOCATION_LOG="$WORK/u6-invocations.log"; : > "$INVOCATION_LOG"
# Extraction must fail: the canned doc path never exists (and the stub never
# writes it), so the xcrun stub returns an invalid document.
export FAKE_CANNED="$WORK/does-not-exist-u6.json"
export FAKE_UI_NO_DOC=1
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="AlphaUITests" FAKE_UI_INFRA_ONCE="" FAKE_UI_HANG=""
run_ui_lane "AlphaUITests,BetaUITests" 300 "AlphaUITests=200,BetaUITests=200"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "fail"
assert_eq "attempts" "$(attempts_statuses)" "['unclassified', 'not_diagnosed']"
assert_eq "Alpha not retried into green" "$(ui_invocations AlphaUITests)" "1"
assert_eq "Beta never ran" "$(ui_invocations BetaUITests)" "0"

# --- UI case 7: per-class watchdogs come from the planner table ---------------
begin_case "ui per-class budgets honored" "$WORK/u7"
export INVOCATION_LOG="$WORK/u7-invocations.log"; : > "$INVOCATION_LOG"
export FAKE_CANNED="$WORK/canned-u7.json"
export FAKE_UI_NO_DOC=""
export FAKE_UI_FAIL_ONCE="" FAKE_UI_FAIL_ALWAYS="" FAKE_UI_INFRA_ONCE="" FAKE_UI_HANG="SlowUITests"
# SlowUITests gets a 2s budget; it must be killed while FastUITests' 300s
# budget is untouched (a lane-wide budget would kill both or neither).
run_ui_lane "FastUITests,SlowUITests" 600 "FastUITests=300,SlowUITests=2"
assert_eq "exit code" "$(cat "$WORKCASE/exit-code")" "1"
assert_eq "verdict" "$(lane_field "['status']")" "timeout"
assert_eq "hung class" "$(lane_field "['hung_class']")" "SlowUITests"
assert_eq "Fast passed under its own larger budget" "$(attempts_statuses)" "['passed', 'timeout', 'timeout']"
assert_eq "lane watchdog sum recorded" "$(lane_field "['timeout_s']")" "600"

echo ""
echo "lane-runner state machine: $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ] || exit 1
echo "ALL CASES PASSED"
exit 0
