#!/usr/bin/env bash
#
# Integration tests for scripts/local-ci-gate.sh.
#
# The gate orchestrates real Xcode project generation, a build-for-testing,
# the lane runner and the summarizer, so its contract with those pieces
# (argument shapes, paths, exit codes, the run directory layout) has no unit
# test: this suite builds a throwaway Conduit-shaped repository and drives the
# REAL gate against stub xcodegen/xcodebuild/xcrun binaries. No simulator, no
# Xcode, no macOS required - it runs on the Linux CI job as well.
#
# What it pins (each of these was a real defect or a real risk):
#   * a clean run exits 0 and reports the EXACT commit it tested;
#   * the repeat policy actually executes its iterations (a path mismatch
#     between the gate and its helper once made the loop run zero times while
#     the lane still reported "pass");
#   * the caller's working tree, index and stashes are untouched;
#   * a genuine assertion failure fails the gate and is reported as an
#     assertion; a test-runner/launch failure fails it and is reported as
#     infrastructure;
#   * a reused --run-dir is refused (a previous run's artifacts must never be
#     read back as evidence).
#
# Usage: bash scripts/tests/test_local_ci_gate.sh   (exit 0 = all cases pass)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
STUBS="$WORK/stubs"
# The gate's wedge-mitigation sleeps and bounded-poll cadence are wall-clock
# behaviour for a REAL run; the stubs exit instantly, so scaling them to 0
# keeps ~20 stubbed gate runs inside the hosted self-test job's ceiling.
# Deadlines still come from `date`, so watchdog cases are unaffected - the
# synthetic hang is Python time.sleep inside a fake script, not shell sleep.
export GATE_SLEEP_SCALE=0
mkdir -p "$STUBS"
# CONDUIT_GATE_TEST_KEEP=1 leaves the throwaway fixture and its run directories
# in place for inspection instead of deleting them on exit.
if [ -n "${CONDUIT_GATE_TEST_KEEP:-}" ]; then
  echo "keeping the test workspace at $WORK"
  trap 'echo "kept: $WORK"' EXIT
else
  trap 'rm -rf "$WORK"' EXIT
fi

pass_count=0
fail_count=0
skip_count=0

ok()  { pass_count=$((pass_count + 1)); echo "  ok: $1"; }
bad() { fail_count=$((fail_count + 1)); echo "  FAIL: $1"; }

skip() { # $1 = what would have been asserted
  skip_count=$((skip_count + 1))
  echo "  skip: $1 (xcrun is not executable from Python on this platform)"
}

# Run the body only where the result bundle can actually be read.
needs_extraction() { [ "$EXTRACTION_SUPPORTED" -eq 1 ]; }

assert_eq() { # $1=desc $2=actual $3=expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}

assert_contains() { # $1=desc $2=haystack $3=needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (missing '$3' in: $(printf '%s' "$2" | head -c 400))" ;;
  esac
}

json_get() { # $1=file $2=python expression on `doc`
  python3 -c "
import json, sys
doc = json.load(open(sys.argv[1], encoding='utf-8'))
print(eval(sys.argv[2]))
" "$1" "$2" 2>/dev/null || printf ''
}

# --- stubs -------------------------------------------------------------------
write_stubs() {
  cat > "$STUBS/xcodegen" <<'EOF'
#!/bin/bash
# The gate only requires that project generation succeeds and that the
# generated project is never committed; nothing here reads it.
echo "xcodegen stub: $*"
exit 0
EOF

  cat > "$STUBS/xcodebuild" <<'EOF'
#!/bin/bash
# -version is asked for the result document.
if [ "${1:-}" = "-version" ]; then
  echo "Xcode 27.0"
  echo "Build version 27A0stub"
  exit 0
fi
echo "xcodebuild stub: $*"
bundle=""
target="ConduitTests"
classes=""
for a in "$@"; do
  case "$a" in
    -resultBundlePath) ;;
    *.xcresult) bundle="$a"; mkdir -p "$a" ;;
    -only-testing:*) spec="${a#-only-testing:}"; target="${spec%%/*}"; classes="$classes ${spec#*/}" ;;
  esac
done
prev=""
for a in "$@"; do
  [ "$prev" = "-resultBundlePath" ] && { bundle="$a"; mkdir -p "$a"; }
  prev="$a"
done
if [ -z "$classes" ]; then
  classes=" $(cat "$FAKE_CLASSES_FALLBACK" 2>/dev/null)"
fi
# One unit batch per class in this fixture, so the batch index is recoverable
# from the result-bundle stem; the FAKE_* knobs decide that batch's verdict.
# A knob keyed on a batch number would ALSO hit the continuation pass, which
# renumbers its own batches from 1 - so the continuation is clean unless a knob
# explicitly targets it, and the cases below test the primary lane's stop.
stem="$(basename "$bundle" .xcresult)"
mode="pass"
case "$bundle" in
  *ui-recovery*)       mode="${FAKE_UI_RECOVERY:-pass}" ;;
  */repeats/*/iter-[0-9]*/*) mode="${FAKE_REPEAT_ITER:-pass}" ;;
  *unit-recovery*)     mode="${FAKE_RECOVERY_MODE:-pass}" ;;
  *unit-continuation*) mode="${FAKE_CONTINUATION_MODE:-pass}" ;;
  */lanes/ui/*)        mode="${FAKE_UI_BATCH:-pass}" ;;
  *)
    case "$stem" in
      batch-*) idx="${stem#batch-}"; idx="${idx%%-*}"; attempt="${stem##*-a}"
               eval "mode=\${FAKE_UNIT_B${idx}_A${attempt}:-pass}" ;;
      class-*) cls="${stem#class-}"; cls="${cls%-a*}"
               eval "mode=\${FAKE_CLASS_${cls}:-pass}" ;;
    esac
    ;;
esac
result="Passed"
extra_node=""
case "$mode" in
  fail) result="Failed" ;;
  crash)
    # The shape XCTest produces when the host never launched: a synthetic
    # "System Failures" entry, and NO real test case node.
    result="Failed"
    classes=""
    extra_node='{"nodeType": "Test Case", "name": "Conduit encountered an error", "result": "Failed", "durationInSeconds": 0.0}'
    ;;
esac
nodes=""
sep=""
for c in $classes; do
  nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"$c\", \"result\": \"$result\",
    \"children\": [{\"nodeType\": \"Test Case\", \"name\": \"testSomething\", \"result\": \"$result\",
    \"durationInSeconds\": 0.1}]}"
  sep=","
done
[ -n "$extra_node" ] && { nodes="$nodes$sep{\"nodeType\": \"Test Suite\", \"name\": \"System Failures\", \"result\": \"Failed\",
  \"children\": [$extra_node]}"; }
# Per-BUNDLE (so concurrent workers cannot cross-contaminate) plus the legacy
# shared path for cases that assert on it.
if [ -n "$bundle" ]; then
  cat > "$bundle.canned.json" <<DOC
{"testNodes": [{"nodeType": "Test Plan", "name": "Conduit", "result": "Passed",
  "children": [{"nodeType": "Test bundle", "name": "$target", "result": "$result",
    "children": [$nodes]}]}]}
DOC
  if [ -n "${FAKE_CANNED:-}" ]; then
    cp "$bundle.canned.json" "$FAKE_CANNED" 2>/dev/null
  fi
fi
case "$mode" in
  crash) echo "Simulator device failed to launch com.milim.relay (stub)"; exit 65 ;;
  fail) echo "Test Case 'testSomething' failed (stub)"; exit 65 ;;
  infra) echo "test host quit unexpectedly (stub)"; exit 70 ;;
  *) exit 0 ;;
esac
EOF

  cat > "$STUBS/xcrun" <<'EOF'
#!/bin/bash
if [ "$1" = "xcresulttool" ]; then
  # `xcresulttool get test-results tests --path <bundle>`: serve what the
  # xcodebuild stub wrote for THAT invocation. The per-bundle file is what
  # makes the fixture safe for concurrent workers: a single shared canned
  # document would let one worker's extraction read the other worker's
  # verdict. FAKE_CANNED stays as the fallback for cases that pre-seed it.
  canned_path=""
  prev=""
  for a in "$@"; do
    [ "$prev" = "--path" ] && canned_path="$a"
    prev="$a"
  done
  if [ -n "$canned_path" ] && [ -f "$canned_path.canned.json" ]; then
    cat "$canned_path.canned.json"
    exit 0
  fi
  cat "$FAKE_CANNED" 2>/dev/null || exit 0
  exit 0
fi
  if [ "$1" = "simctl" ]; then
    if [ "$2" = "create" ]; then
      # Model `simctl create`: it prints a runtime notice BEFORE the UDID, so
      # the gate has to match the UUID rather than take the whole output. A
      # test can remove the gate devices from the listing below to exercise
      # this path. The UDID is derived from the requested NAME, so two workers
      # creating their own devices get two DISTINCT devices - a fixture that
      # handed both workers the same UDID would hide exactly the defect the
      # gate's "two workers, two devices" refusal exists for.
      echo "No runtime specified, using 'iOS 26.5 (26.5 - 23F77) - com.apple.CoreSimulator.SimRuntime.iOS-26-5'"
      case "${3:-}" in
        "Conduit CI Gate 2") echo "7E7E7E7E-1111-2222-3333-444444444444" ;;
        *) echo "6D08B063-B890-4D18-893B-D1E89E119919" ;;
      esac
      exit 0
    fi
    if [ "$2 $3 $4" = "list devices available" ]; then
      if [ -n "${FAKE_SIMCTL_DUPLICATE:-}" ]; then
        # Two devices sharing the pinned name across runtimes: the gate must
        # REFUSE to shut either down rather than pick one.
        cat <<'DEV'
{"devices" : {"com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
  { "udid" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "name" : "iPhone 17 Pro", "state" : "Booted" },
  { "udid" : "6D08B063-B890-4D18-893B-D1E89E119919",
    "name" : "Conduit CI Gate", "state" : "Shutdown" }],
 "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
  { "udid" : "99999999-8888-7777-6666-555555555555",
    "name" : "Conduit CI Gate", "state" : "Shutdown" }]}}
DEV
        exit 0
      fi
      if [ -n "${FAKE_NO_GATE_DEVICE:-}" ]; then
        cat <<'DEV'
{"devices" : {"com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
  { "udid" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "name" : "iPhone 17 Pro", "state" : "Booted" }]}}
DEV
      else
        cat <<'DEV'
{"devices" : {"com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
  { "udid" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "name" : "iPhone 17 Pro", "state" : "Booted" },
  { "udid" : "6D08B063-B890-4D18-893B-D1E89E119919",
    "name" : "Conduit CI Gate", "state" : "Shutdown" },
  { "udid" : "7E7E7E7E-1111-2222-3333-444444444444",
    "name" : "Conduit CI Gate 2", "state" : "Shutdown" }]}}
DEV
      fi
      exit 0
    fi
  exit 0
fi
exit 0
EOF

  cat > "$STUBS/ios-ci-host" <<'EOF'
#!/bin/bash
# Models the host coordinator for fixtures. Default mode: always-granting
# and always-quiet - `doctor` self-checks clean, `acquire --hold` grants
# instantly and holds exactly as long as its stdin stays open (the real
# FIFO contract the gate relies on). IOS_CI_HOST_MODE selects the failure
# shapes the gate must fail closed on:
#   doctor-fail - the coordinator's self-check fails (gate must exit 2)
#   busy        - another project holds the resource (gate must exit 3)
#   foreign     - the monitor signals the controller mid-run (invalid run)
#   dead        - the helper dies without any verdict (gate must exit 2)
# IOS_CI_HOST_PIDFILE, when set, receives the holder's pid so suite
# assertions never have to pattern-match the shared host's process table.
if [ "${IOS_CI_HOST_MODE:-grant}" = "doctor-fail" ] && [ "${1:-}" = "doctor" ]; then
  echo "stub doctor failure" >&2
  exit 1
fi
case "${1:-}" in
  doctor|status|audit) exit 0 ;;
esac
if [ "${1:-}" = "acquire" ]; then
  if [ "${IOS_CI_HOST_MODE:-grant}" = "busy" ]; then
    echo "{\"status\": \"busy\", \"resource\": \"simulator-test\", \"owner\": {\"project\": \"VitalRoute\", \"workflow\": \"background-tests\", \"owner_pid\": 4242, \"acquired_at\": \"stub\"}, \"hint\": \"stubbed busy\"}"
    exit 0
  fi
  if [ "${IOS_CI_HOST_MODE:-grant}" = "dead" ]; then
    exit 1
  fi
  if [ "${IOS_CI_HOST_MODE:-grant}" = "foreign" ]; then
    # Model the monitor's release-policy action: shortly after granting,
    # signal the controller (the gate) that uncoordinated activity was seen.
    (
      sleep 1
      if [ -n "${IOS_CI_HOST_CONTROLLER_PID:-}" ]; then
        kill -TERM "$IOS_CI_HOST_CONTROLLER_PID" 2>/dev/null || true
      fi
    ) &
  fi
  [ -n "${IOS_CI_HOST_PIDFILE:-}" ] && echo $$ > "$IOS_CI_HOST_PIDFILE"
  echo "{\"status\": \"acquired\", \"lease_id\": \"L-stub00000000\", \"resource\": \"simulator-test\", \"project\": \"stub\", \"simulator_udid\": null, \"acquired_at\": \"stub\", \"owner_pid\": $$, \"waited_seconds\": 0.0, \"tool_version\": \"stub\"}"
  cat > /dev/null
  exit 0
fi
exit 0
EOF

  chmod +x "$STUBS/xcodegen" "$STUBS/xcodebuild" "$STUBS/xcrun" "$STUBS/ios-ci-host"

  # Windows (MSYS/Cygwin) cannot exec an extension-less script: Python's
  # subprocess (the timing extractor shells out to `xcrun xcresulttool`) needs
  # a PATHEXT-visible name. CI runs this suite on Linux/macOS, where the plain
  # scripts are found; these shims exist so the suite is also runnable from a
  # Windows checkout instead of silently degrading to "extraction failed".
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      for name in xcodegen xcodebuild xcrun ios-ci-host; do
        printf '@bash "%%~dp0%s" %%*\r\n' "$name" > "$STUBS/$name.cmd"
      done
      ;;
  esac
}

# --- fixture repository ------------------------------------------------------
# A Conduit-shaped tree: the real CI tooling under test, and stand-ins for the
# two pieces the gate only needs to SUCCEED at (project generation is stubbed
# through PATH; the build script is a fixture file, since its real
# implementation is CI v2's build job and is exercised on macOS).
make_fixture() { # $1 = path
  local repo="$1"
  mkdir -p "$repo/ConduitTests" "$repo/ConduitUITests" "$repo/Conduit" "$repo/scripts/tests"
  printf 'name: Conduit\n' > "$repo/project.yml"
  printf 'import Foundation\n' > "$repo/Conduit/App.swift"
  # 15 unit classes: enough for the planner to split them into THREE batches
  # (7/7/1 by the default 7-class batch cap), which is what makes the
  # continuation path reachable - a lane that stops on batch 2 still has a
  # batch it never reached.
  for name in Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa Lambda \
              Mu Nu Xi Omicron; do
    cat > "$repo/ConduitTests/${name}Tests.swift" <<SWIFT
import XCTest

final class ${name}Tests: XCTestCase {
    func testSomething() {}
}
SWIFT
  done
  cat > "$repo/ConduitUITests/LaunchUITests.swift" <<'SWIFT'
import XCTest

final class LaunchUITests: XCTestCase {
    func testSomething() {}
}
SWIFT
  for script in local-ci-gate.sh local-gate.py ci-gate-lock.sh plan-tests.py ci-test-lane.sh \
                ci-lib.sh extract-test-timings.py test-timings.json; do
    cp "$SCRIPTS/$script" "$repo/scripts/$script"
  done
  # The localization checker is CI infrastructure, not the gate's subject; a
  # passing stand-in keeps the static phase's contract (exit code) under test.
  # FAKE_STATIC_SLEEP makes it hang, so an interrupt can be tested against a
  # gate that is mid-run rather than against a finished one.
  cat > "$repo/scripts/check-l10n-coverage.py" <<'PY'
#!/usr/bin/env python3
import os
import sys
import time

delay = int(os.environ.get("FAKE_STATIC_SLEEP") or 0)
if delay:
    time.sleep(delay)
sys.exit(0)
PY
  cat > "$repo/scripts/tests/test_fixture_ok.py" <<'PY'
import unittest


class FixtureSanityTests(unittest.TestCase):
    def test_ok(self):
        self.assertTrue(True)


if __name__ == "__main__":
    unittest.main()
PY
  cat > "$repo/scripts/ci-build-for-testing.sh" <<'SH'
#!/usr/bin/env bash
# Fixture stand-in for CI v2's build job: produce a .xctestrun where the gate
# expects one and record the build metadata the gate moves into its run dir.
set -u
# FAKE_BUILD_FAIL models a build that fails before producing a .xctestrun:
# the gate must still finish and write its three artifacts, reporting FAIL.
if [ -n "${FAKE_BUILD_FAIL:-}" ]; then
  mkdir -p ci-lane/build
  echo "fixture build-for-testing failed (stub)" > ci-lane/build/build.log
  exit 1
fi
mkdir -p "$DERIVED_DATA_PATH/Build/Products"
: > "$DERIVED_DATA_PATH/Build/Products/Conduit_stub.xctestrun"
mkdir -p ci-lane/build
echo "fixture build-for-testing ok" > ci-lane/build/build.log
printf '{"schema_version": 1, "status": "ok", "duration_s": 1, "xctestrun": "%s"}\n' \
  "$DERIVED_DATA_PATH/Build/Products/Conduit_stub.xctestrun" \
  > ci-lane/build/build-result.json
exit 0
SH
  ( cd "$repo" && git init -q . && git add -A \
      && git -c user.email=t@example.com -c user.name=t commit -q -m fixture )
}

# --- gate invocation --------------------------------------------------------
GATE="$WORK/repo/scripts/local-ci-gate.sh"
RUN_LOG=""

run_gate() { # extra args...
  local n=0
  for arg in "$@"; do
    n=$((n + 1))
    case "$arg" in
      --run-dir-*) [ "$n" -eq 1 ] && run_dir_hint="${arg#--run-dir-}" ;;
    esac
  done
  RUN_LOG="$WORK/gate-$RANDOM.log"
  # XCODEBUILD_POLL_INTERVAL_S keeps the watchdog polling cheap: the stub
  # xcodebuild exits instantly, and CI's own suite shrinks the cadence for
  # the same reason.
  #
  # --unit-batch-max-classes 7 is pinned HERE (not left to the gate's default)
  # on purpose: this fixture's 15 classes are sized so that a 7-class cap makes
  # THREE batches, which is what keeps the continuation path reachable (a lane
  # that stops on batch 2 still has a batch it never reached). A case that
  # wants the gate's own default passes --unit-batch-max-classes explicitly.
  PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 \
    bash "$GATE" --allow-another-run --unit-batch-max-classes 7 "$@" >"$RUN_LOG" 2>&1
}

new_run_dir() { printf '%s\n' "$WORK/run-$RANDOM-$RANDOM"; }

assert_three_artifacts() { # $1 = run dir, $2 = label
  assert_eq "$2: meta.json was written"     "$([ -f "$1/meta.json" ] && echo yes || echo no)" "yes"
  assert_eq "$2: gate-result.json was written"     "$([ -f "$1/gate-result.json" ] && echo yes || echo no)" "yes"
  assert_eq "$2: summary.md was written"     "$([ -f "$1/summary.md" ] && echo yes || echo no)" "yes"
}


echo "=== local-ci-gate integration suite ==="
write_stubs
make_fixture "$WORK/repo"

# The timing extractor shells out to `xcrun xcresulttool` with an argv list, so
# it needs an executable `xcrun` on PATH - which is why this probe runs AFTER
# the stubs exist (an earlier probe placed before write_stubs reported
# "unsupported" everywhere and silently skipped the assertions on Linux CI).
# On Windows (MSYS/Cygwin) an extension-less script is not executable from
# Python at all, so the extraction - and with it every count, classification
# and verdict the gate derives from the result bundle - cannot be exercised
# there: those assertions are SKIPPED loudly rather than quietly passed, while
# the structural ones (refs, exit codes, the caller's tree, the lock, cleanup)
# still run everywhere.
EXTRACTION_SUPPORTED=1
if ! python3 - "$STUBS" <<'PY'
import os, subprocess, sys
os.environ["PATH"] = sys.argv[1] + os.pathsep + os.environ.get("PATH", "")
try:
    proc = subprocess.run(["xcrun", "xcresulttool"], capture_output=True,
                          timeout=60)
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if proc.returncode == 0 else 1)
PY
then
  EXTRACTION_SUPPORTED=0
fi
echo "result-bundle extraction exercised here: $([ "$EXTRACTION_SUPPORTED" -eq 1 ] && echo yes || echo no)"

FIXTURE_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"
export FAKE_CANNED="$WORK/canned.json"
# The stub holder records its pid here. Exported BEFORE the first gate run so
# the holder-exit assertions below test the holder that actually served that
# run - and asserted non-empty, so a stub regression that stops writing the
# pidfile cannot silently turn the check into a vacuous pass.
export IOS_CI_HOST_PIDFILE="$WORK/holder.pid"
rm -f "$IOS_CI_HOST_PIDFILE"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: clean run (on the DEFAULT gate root) ---"
# Deliberately NO --gate-root: the default (repo parent +/conduit-local-gate
# = $WORK/conduit-local-gate, inside this sandbox) must work - a lease block
# placed before the GATE_ROOT default would die at mkfifo /host-lease/... .
# This run doubles as the default-gate-root regression.
RUN1="$(new_run_dir)"
CLEAN_EXIT=0
run_gate --ref HEAD --run-dir "$RUN1" \
    --repeat-classes AlphaTests --repeat-iterations 2 || CLEAN_EXIT=$?
if needs_extraction; then
  if [ "$CLEAN_EXIT" -eq 0 ]; then
    ok "clean run exits 0"
  else
    bad "clean run exited $CLEAN_EXIT (see $RUN_LOG)"
    tail -n 30 "$RUN_LOG"
  fi
elif [ "$CLEAN_EXIT" -ne 0 ]; then
  # Nothing can be certified without a readable result bundle, so on this host
  # the correct behavior is to refuse to pass rather than report an empty
  # success - which is itself worth pinning.
  ok "a run whose result bundle cannot be read does not pass"
else
  bad "the gate passed a run whose result bundle could not be read"
fi
GATE_JSON="$RUN1/gate-result.json"
if needs_extraction; then
assert_eq "verdict is PASS" "$(json_get "$GATE_JSON" 'doc["verdict"]')" "PASS"
assert_eq "tested SHA is the tested commit" \
  "$(json_get "$GATE_JSON" 'doc["tested_sha"]')" "$FIXTURE_HEAD"
assert_eq "unit executions counted" \
  "$(json_get "$GATE_JSON" 'doc["unit"]["executions"]')" "15"
assert_eq "unit classes complete" \
  "$(json_get "$GATE_JSON" 'doc["unit"]["classes_observed"]')" "15"
assert_eq "no continuation was needed" \
  "$(json_get "$GATE_JSON" '"continuation" in doc["unit"]')" "False"
assert_eq "UI executions counted" \
  "$(json_get "$GATE_JSON" 'doc["ui"]["executions"]')" "1"
assert_eq "repeat policy executed every iteration" \
  "$(json_get "$GATE_JSON" 'len(doc["focused_repeats"]["classes"][0]["iterations"])')" "2"
assert_eq "repeat executions counted" \
  "$(json_get "$GATE_JSON" 'doc["focused_repeats"]["executions"]')" "2"
assert_eq "no infrastructure events" \
  "$(json_get "$GATE_JSON" 'doc["infrastructure"]["failures"]')" "0"
assert_eq "run is not partial" "$(json_get "$GATE_JSON" 'doc["partial"]')" "False"
else
  skip "clean-run verdict, execution counts and repeat evidence"
fi
assert_eq "the plan's three batches all ran" \
  "$(json_get "$GATE_JSON" 'doc["unit"]["batch_count"]')" "3"
assert_eq "xcode version recorded" \
  "$(json_get "$GATE_JSON" 'doc["xcode_version"].strip()')" "Xcode 27.0 Build version 27A0stub"
assert_eq "simulator runtime recorded" \
  "$(json_get "$GATE_JSON" 'doc["simulator"]["runtime"]')" "iOS 26.0"
assert_eq "the gate ran on its OWN simulator device, not the default" \
  "$(json_get "$GATE_JSON" 'doc["simulator"]["name"]')" "Conduit CI Gate"
assert_eq "the gate tooling's own commit is recorded"   "$(json_get "$GATE_JSON" 'doc["tooling_sha"]')"   "$(git -C "$WORK/repo" rev-parse HEAD)"
assert_eq "static checks ran" \
  "$(json_get "$GATE_JSON" 'len(doc["static_checks"])')" "3"
assert_contains "human summary names the tested commit" \
  "$(cat "$RUN1/summary.md")" "$FIXTURE_HEAD"
assert_eq "build metadata moved into the run dir" \
  "$([ -f "$RUN1/build/build.log" ] && echo yes || echo no)" "yes"
# The clean run uses the DEFAULT gate root, so its worktree-leak check must
# inspect that root (later explicit-root runs keep their own checks).
if [ -d "$WORK/conduit-local-gate/worktrees" ] && [ -n "$(ls -A "$WORK/conduit-local-gate/worktrees" 2>/dev/null)" ]; then
  bad "throwaway worktree was left behind (default root)"
else
  ok "throwaway worktree removed (default root)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the host lease is acquired, held, and released ---"
# IOS_CI_HOST_PIDFILE was exported before the run that produced $RUN1, so
# this is the holder that actually served that run.
assert_eq "acquisition evidence lands in the run dir" \
  "$([ -f "$RUN1/host-lease.json" ] && echo yes || echo no)" "yes"
assert_contains "lease id recorded" "$(cat "$RUN1/host-lease.json")" "L-stub00000000"
HOLDER_PID="$(cat "$IOS_CI_HOST_PIDFILE" 2>/dev/null || true)"
assert_eq "the holder recorded its pid (non-vacuous regression)" \
  "$([ -n "$HOLDER_PID" ] && echo yes || echo no)" "yes"
if [ -n "$HOLDER_PID" ] && kill -0 "$HOLDER_PID" 2>/dev/null; then
  bad "a lease-holder helper survived the gate's exit (pid $HOLDER_PID)"
else
  ok "lease-holder helper exited with the gate"
fi

echo ""
echo "--- case: HOST BUSY refuses before any work (exit 3) ---"
BUSY_DIR="$(new_run_dir)"
BUSY_LOG="$WORK/gate-busy-$RANDOM.log"
IOS_CI_HOST_MODE=busy PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 \
  bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-busy" \
    --run-dir "$BUSY_DIR" >"$BUSY_LOG" 2>&1
BUSY_EXIT=$?
assert_eq "busy coordinator refuses with exit 3" "$BUSY_EXIT" "3"
assert_contains "refusal names the owning project" "$(cat "$BUSY_LOG")" "VitalRoute"
assert_eq "no gate-result.json for a refused run" \
  "$([ -f "$BUSY_DIR/gate-result.json" ] && echo yes || echo no)" "no"
assert_eq "refusal evidence retained under the gate root" \
  "$([ -s "$WORK/gate-busy/host-lease/attempt.json" ] && echo yes || echo no)" "yes"

echo ""
echo "--- case: a broken coordinator self-check fails closed (exit 2) ---"
DOCTOR_LOG="$WORK/gate-doctor-$RANDOM.log"
IOS_CI_HOST_MODE=doctor-fail PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 \
  bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-doctor" \
    --run-dir "$(new_run_dir)" >"$DOCTOR_LOG" 2>&1
DOCTOR_EXIT=$?
assert_eq "failed coordinator self-check refuses with exit 2" "$DOCTOR_EXIT" "2"
assert_contains "the self-check failure is reported" "$(cat "$DOCTOR_LOG")" "self-check"

echo ""
echo "--- case: a helper that dies without a verdict fails closed (exit 2) ---"
DEAD_LOG="$WORK/gate-dead-$RANDOM.log"
IOS_CI_HOST_MODE=dead PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 \
  bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-dead" \
    --run-dir "$(new_run_dir)" >"$DEAD_LOG" 2>&1
DEAD_EXIT=$?
assert_eq "a verdict-less helper refuses with exit 2" "$DEAD_EXIT" "2"
assert_contains "the refusal explains the coordinator failure" "$(cat "$DEAD_LOG")" "coordinator failed to grant"

echo ""
echo "--- case: an ambiguous simulator name fails closed ---"
DUP_LOG="$WORK/gate-dup-$RANDOM.log"
FAKE_SIMCTL_DUPLICATE=1 PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 \
  bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-dup" \
    --run-dir "$(new_run_dir)" >"$DUP_LOG" 2>&1
DUP_EXIT=$?
assert_eq "ambiguous device name fails closed with exit 2" "$DUP_EXIT" "2"
assert_contains "the refusal names the ambiguity" "$(cat "$DUP_LOG")" "is ambiguous"
assert_contains "nothing was run against the ambiguous device" "$(cat "$DUP_LOG")" "refusing to run"

echo ""
echo "--- case: the monitor's invalid-run teardown is not a verdict ---"
FOREIGN_DIR="$(new_run_dir)"
FOREIGN_LOG="$WORK/gate-foreign-$RANDOM.log"
IOS_CI_HOST_MODE=foreign PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 \
  bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-foreign" \
    --run-dir "$FOREIGN_DIR" >"$FOREIGN_LOG" 2>&1
FOREIGN_EXIT=$?
assert_eq "a monitor teardown exits 143 (SIGTERM)" "$FOREIGN_EXIT" "143"
assert_eq "a torn-down run produces no gate verdict" \
  "$([ -f "$FOREIGN_DIR/gate-result.json" ] && echo yes || echo no)" "no"
assert_eq "the torn-down run had acquired the lease" \
  "$([ -s "$FOREIGN_DIR/host-lease.json" ] && echo yes || echo no)" "yes"

echo ""
echo "--- case: SIGKILL of the gate releases the lease via kernel EOF ---"
KILL_DIR="$(new_run_dir)"
KILL_LOG="$WORK/gate-kill-$RANDOM.log"
# A fresh pidfile proves the holder recorded by the assertions below served
# THIS run, not an earlier one.
rm -f "$IOS_CI_HOST_PIDFILE"
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 \
  bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-kill" \
    --run-dir "$KILL_DIR" >"$KILL_LOG" 2>&1 &
KILL_GATE_PID=$!
KILL_ACQUIRED=1
for i in $(seq 1 120); do
  if [ -s "$KILL_DIR/host-lease.json" ] && [ -s "$IOS_CI_HOST_PIDFILE" ]; then
    KILL_ACQUIRED=0
    break
  fi
  if ! kill -0 "$KILL_GATE_PID" 2>/dev/null; then break; fi
  sleep 0.5
done
assert_eq "the run acquired the lease before the kill" "$KILL_ACQUIRED" "0"
kill -9 "$KILL_GATE_PID" 2>/dev/null || true
wait "$KILL_GATE_PID" 2>/dev/null || true
KILL_HOLDER_PID="$(cat "$IOS_CI_HOST_PIDFILE" 2>/dev/null || true)"
assert_eq "the killed run's holder recorded its pid" \
  "$([ -n "$KILL_HOLDER_PID" ] && echo yes || echo no)" "yes"
KILL_RELEASED=1
for i in $(seq 1 40); do
  if [ -z "$KILL_HOLDER_PID" ] || ! kill -0 "$KILL_HOLDER_PID" 2>/dev/null; then
    KILL_RELEASED=0
    break
  fi
  sleep 0.5
done
assert_eq "kernel EOF released the lease holder without any trap" "$KILL_RELEASED" "0"

# The default gate root is already proven by the CLEAN RUN (it ran without
# --gate-root, on $WORK/conduit-local-gate); this only re-asserts the lease
# evidence landed there - a separate full gate run would spend the hosted
# self-test job's time ceiling for no extra coverage.
assert_eq "the default root run acquired the host lease" \
  "$([ -s "$WORK/conduit-local-gate/host-lease/attempt.json" ] && echo yes || echo no)" "yes"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the caller's tree, index and stashes are untouched ---"
# Model a developer mid-work: an uncommitted change, an untracked file, and a
# stash. The gate must test the COMMIT and leave all three alone.
( cd "$WORK/repo" && printf 'wip\n' >> Conduit/App.swift \
    && git -c user.email=t@example.com -c user.name=t stash push -q -m gate-wip )
( cd "$WORK/repo" && printf 'untracked\n' > uncommitted.txt \
    && printf 'dirty\n' >> Conduit/App.swift )
STATUS_BEFORE="$(git -C "$WORK/repo" status --porcelain)"
STASHES_BEFORE="$(git -C "$WORK/repo" stash list)"
STASH_REF_BEFORE="$(git -C "$WORK/repo" rev-parse refs/stash)"
HEAD_BEFORE="$(git -C "$WORK/repo" rev-parse HEAD)"
HEAD_REF_BEFORE="$(git -C "$WORK/repo" symbolic-ref HEAD)"
RUN2="$(new_run_dir)"
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN2" \
    --repeat-classes AlphaTests --repeat-iterations 1 >/dev/null 2>&1
assert_eq "working tree unchanged" "$(git -C "$WORK/repo" status --porcelain)" "$STATUS_BEFORE"
assert_eq "stash list unchanged" "$(git -C "$WORK/repo" stash list)" "$STASHES_BEFORE"
assert_eq "stash commit untouched" "$(git -C "$WORK/repo" rev-parse refs/stash)" "$STASH_REF_BEFORE"
assert_eq "HEAD unchanged" "$(git -C "$WORK/repo" rev-parse HEAD)" "$HEAD_BEFORE"
assert_eq "HEAD ref unchanged" "$(git -C "$WORK/repo" symbolic-ref HEAD)" "$HEAD_REF_BEFORE"
assert_contains "the stash created before the run is still listed" "$STASHES_BEFORE" "gate-wip"
assert_eq "the dirty working tree was not what got tested" \
  "$(json_get "$RUN2/gate-result.json" 'doc["tested_sha"]')" "$HEAD_BEFORE"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: a genuine assertion failure stops the lane, and the lane is continued ---"
export FAKE_UNIT_B1_A1=fail
RUN3="$(new_run_dir)"
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN3" \
    --repeat-classes "" >/dev/null 2>&1; then
  bad "a genuine assertion failure did not fail the gate"
else
  ok "a genuine assertion failure fails the gate"
fi
GATE3="$RUN3/gate-result.json"
if needs_extraction; then
assert_eq "verdict is FAIL" "$(json_get "$GATE3" 'doc["verdict"]')" "FAIL"
assert_eq "reported as an assertion failure" \
  "$(json_get "$GATE3" 'doc["unit"]["failures"] > 0')" "True"
assert_eq "not reported as infrastructure" \
  "$(json_get "$GATE3" 'doc["unit"]["synthetic_failures"]')" "0"
assert_eq "no infrastructure events" \
  "$(json_get "$GATE3" 'doc["infrastructure"]["failures"]')" "0"
assert_contains "the failure names the assertion" \
  "$(cat "$RUN3/summary.md")" "genuine XCTest assertion failures"
assert_contains "the failing test is identified" \
  "$(cat "$RUN3/gate-result.json")" "testSomething"
# Batches 2 and 3 never ran; the gate runs them as a continuation so one
# failing batch cannot hide the rest of the suite.
assert_eq "the never-reached batches were continued" \
  "$(json_get "$GATE3" 'len(doc["unit"]["passes"]) > 1')" "True"
assert_eq "the continuation ran every class the lane never reached" \
  "$(json_get "$GATE3" 'doc["unit"]["passes"][1]["executions"]')" "8"
assert_eq "every planned class still has a result" \
  "$(json_get "$GATE3" 'doc["unit"]["classes_missing"]')" "[]"
else
  skip "assertion-failure classification and the continuation pass"
fi
unset FAKE_UNIT_B1_A1

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the test runner never launched the app (wedge -> one recovery round) ---"
# XCTest reports this under its synthetic "System Failures" class; the gate
# must call it infrastructure, not an assertion (this is exactly what the
# gate's first real runs on main produced, and it was mislabeled then). With
# the bounded recovery round, the class it leaves incomplete is retried once
# after an erase of the gate simulator - and that is the one case a run may
# still PASS: the retry is recorded, never hidden.
export FAKE_UNIT_B2_A1=crash
RUN4="$(new_run_dir)"
CLEAN4_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN4" \
    --repeat-classes "" >/dev/null 2>&1 || CLEAN4_EXIT=$?
if needs_extraction; then
  if [ "$CLEAN4_EXIT" -eq 0 ]; then
    ok "a wedged run recovered by the bounded round passes the gate"
  else
    bad "the wedged run was not recovered (see $RUN4/summary.md)"
    tail -n 20 "$RUN4/summary.md" 2>/dev/null
  fi
GATE4="$RUN4/gate-result.json"
assert_eq "no assertion failure claimed" \
  "$(json_get "$GATE4" 'doc["unit"]["failures"]')" "0"
assert_eq "the synthetic failure is counted separately" \
  "$(json_get "$GATE4" 'doc["unit"]["synthetic_failures"] > 0')" "True"
assert_eq "the recovery round was used exactly once" \
  "$(json_get "$GATE4" 'doc["infrastructure"]["retries"]')" "1"
assert_eq "the healed wedge is recorded as recovered" \
  "$(json_get "$GATE4" 'doc["infrastructure"]["recovered"] > 0')" "True"
assert_eq "nothing stayed persistent" \
  "$(json_get "$GATE4" 'doc["infrastructure"]["persistent"]')" "0"
assert_eq "every planned class still has a result" \
  "$(json_get "$GATE4" 'doc["unit"]["classes_missing"]')" "[]"
assert_contains "the recovered launch failure is visible in the summary" \
  "$(cat "$RUN4/summary.md")" "recovery"
else
  skip "test-runner-crash classification and the recovery round"
fi
unset FAKE_UNIT_B2_A1

# ---------------------------------------------------------------------------
echo ""
echo "--- case: refusals that must not run anything ---"
RUN5="$(new_run_dir)"
if run_gate --ref definitely-not-a-ref --gate-root "$WORK/gate" --run-dir "$RUN5" \
    >/dev/null 2>&1; then
  bad "an unresolvable ref was accepted"
else
  ok "an unresolvable ref is refused"
fi
assert_eq "no result document for a refused run" \
  "$([ -f "$RUN5/gate-result.json" ] && echo yes || echo no)" "no"

if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN3" \
    >/dev/null 2>&1; then
  bad "a non-empty --run-dir was reused"
else
  ok "a non-empty --run-dir is refused"
fi

# A run directory inside the repository would put gate output in the very
# working tree the gate promises never to touch.
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$WORK/repo/ci-local" \
    >/dev/null 2>&1; then
  bad "--run-dir inside the repository was accepted"
else
  ok "--run-dir inside the repository is refused"
fi
assert_eq "nothing was written into the repository by that refusal" \
  "$([ -e "$WORK/repo/ci-local" ] && echo yes || echo no)" "no"

# Non-numeric flags fail as usage errors rather than mid-run arithmetic.
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$(new_run_dir)" \
    --repeat-iterations abc >/dev/null 2>&1; then
  bad "a non-numeric --repeat-iterations was accepted"
else
  ok "a non-numeric --repeat-iterations is refused"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: a genuine assertion never enters the recovery round ---"
export FAKE_UNIT_B1_A1=fail
RUN7="$(new_run_dir)"
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN7" \
    --repeat-classes "" >/dev/null 2>&1; then
  bad "a genuine assertion failure did not fail the gate"
else
  ok "a genuine assertion failure fails the gate"
fi
GATE7="$RUN7/gate-result.json"
assert_eq "no recovery pass was created" \
  "$(ls -d "$RUN7"/lanes/unit-recovery-* 2>/dev/null | wc -l | tr -d ' ')" "0"
if needs_extraction; then
assert_eq "no recovery retry was recorded" \
  "$(json_get "$GATE7" 'doc["infrastructure"]["retries"]')" "0"
assert_contains "the failure is named as an assertion" \
  "$(cat "$RUN7/summary.md")" "genuine XCTest assertion failures"
else
  skip "assertion failure blocks the recovery round"
fi
unset FAKE_UNIT_B1_A1

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the launch-refusal wedge gets exactly one recovery round ---"
# Both the primary lane and its continuation pass are refused (the
# continuation renumbers its batches, so each is keyed independently), which
# is what leaves work incomplete - and that is the only shape the recovery
# round is allowed for.
export FAKE_UNIT_B1_A1=crash FAKE_CONTINUATION_MODE=crash
RUN8="$(new_run_dir)"
CLEAN8_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN8" \
    --repeat-classes "" >/dev/null 2>&1 || CLEAN8_EXIT=$?
if needs_extraction; then
  if [ "$CLEAN8_EXIT" -eq 0 ]; then
    ok "a recovered run passes the gate"
  else
    bad "the recovered run still failed (see $RUN8/summary.md)"
    tail -n 20 "$RUN8/summary.md" 2>/dev/null
  fi
else
  skip "the recovered run's verdict"
fi
GATE8="$RUN8/gate-result.json"
if needs_extraction; then
assert_eq "one recovery retry was recorded" \
  "$(json_get "$GATE8" 'doc["infrastructure"]["retries"]')" "1"
assert_eq "the recovered work is recorded as recovered" \
  "$(json_get "$GATE8" 'doc["infrastructure"]["recovered"] > 0')" "True"
assert_eq "nothing stayed persistent" \
  "$(json_get "$GATE8" 'doc["infrastructure"]["persistent"]')" "0"
assert_eq "no class is left without a result" \
  "$(json_get "$GATE8" 'doc["unit"]["classes_missing"]')" "[]"
else
  skip "wedge recovery outcome (verdict and classification)"
fi
assert_eq "the recovery pass exists (one retry set, one launch)" \
  "$(ls -d "$RUN8"/lanes/unit-recovery-* 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "the gate ran on its own simulator device" \
  "$(json_get "$GATE8" 'doc["simulator"]["name"]')" "Conduit CI Gate"
assert_contains "the recovery is recorded, not hidden" \
  "$(cat "$RUN8/summary.md")" "recovery"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: a recurrence after the recovery round fails as infrastructure ---"
export FAKE_UNIT_B1_A1=crash FAKE_CONTINUATION_MODE=crash FAKE_RECOVERY_MODE=crash
RUN9="$(new_run_dir)"
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN9" \
    --repeat-classes "" >/dev/null 2>&1; then
  bad "a recurring wedge did not fail the gate"
else
  ok "a recurring wedge fails the gate"
fi
GATE9="$RUN9/gate-result.json"
if needs_extraction; then
assert_eq "only one retry was attempted" \
  "$(json_get "$GATE9" 'doc["infrastructure"]["retries"]')" "1"
assert_eq "the recurrence is persistent infrastructure" \
  "$(json_get "$GATE9" 'doc["infrastructure"]["persistent"] > 0')" "True"
assert_contains "the report names the recurrence" \
  "$(cat "$RUN9/summary.md")" "launch-refusal class"
else
  skip "recurrence verdict and classification"
fi
unset FAKE_UNIT_B1_A1 FAKE_CONTINUATION_MODE FAKE_RECOVERY_MODE

# ---------------------------------------------------------------------------
echo ""
echo "--- case: an interrupt releases the lock and the worktree ---"
# Interrupt the gate mid-run (during the static phase, which the fixture can
# make hang) and require the same cleanup the end of a run performs.
export FAKE_STATIC_SLEEP=30
RUN10="$(new_run_dir)"
STATUS_BEFORE_INTERRUPT="$(git -C "$WORK/repo" status --porcelain)"
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 \
  bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN10" \
    --repeat-classes "" >"$WORK/interrupt.log" 2>&1 &
INTERRUPTED_PID=$!
sleep 3
kill -TERM "$INTERRUPTED_PID" 2>/dev/null
INTERRUPT_EXIT=0
wait "$INTERRUPTED_PID" || INTERRUPT_EXIT=$?
unset FAKE_STATIC_SLEEP
# SIGTERM is the signal sent, so the gate reports 143 (128 + SIGTERM); an
# INT would report 130.
assert_eq "the interrupted run exits 143 (SIGTERM)" "$INTERRUPT_EXIT" "143"
assert_eq "the lock was released" \
  "$([ -d "$WORK/gate/gate.lock" ] && echo yes || echo no)" "no"
assert_eq "no worktree was left behind" \
  "$(ls -A "$WORK/gate/worktrees" 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "the caller's repository is unchanged by the interrupted run" \
  "$(git -C "$WORK/repo" status --porcelain)" "$STATUS_BEFORE_INTERRUPT"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the gate simulator is created when it does not exist ---"
export FAKE_NO_GATE_DEVICE=1
RUN11="$(new_run_dir)"
CLEAN11_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN11" \
    --repeat-classes "" >/dev/null 2>&1 || CLEAN11_EXIT=$?
if needs_extraction; then
  if [ "$CLEAN11_EXIT" -eq 0 ]; then
    ok "a run without the gate device still runs (it creates it)"
  else
    bad "a missing gate simulator stopped the run (see $RUN11/summary.md)"
  fi
else
  skip "the missing-device run's verdict"
fi
assert_contains "the creation is visible in the log" "$(cat "$RUN_LOG")" \
  "gate simulator 'Conduit CI Gate' created"
assert_eq "the created device is recorded" \
  "$(json_get "$RUN11/gate-result.json" 'doc["simulator"]["udid"]')" \
  "6D08B063-B890-4D18-893B-D1E89E119919"
unset FAKE_NO_GATE_DEVICE

# ---------------------------------------------------------------------------
echo ""
# ---------------------------------------------------------------------------
echo ""
echo "--- case: a failed build still writes all three artifacts ---"
# Regression for the Bash 3.2 empty-array fatal: `set -u` with an empty array
# expansion used to abort /bin/bash 3.2 during argument expansion, BEFORE the
# gate could write its result. Whatever fails, meta.json + gate-result.json +
# summary.md must exist and the verdict must be FAIL.
export FAKE_BUILD_FAIL=1
RUN15="$(new_run_dir)"
BUILD_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN15"     --repeat-classes "" >/dev/null 2>&1 || BUILD_EXIT=$?
if [ "$BUILD_EXIT" -eq 0 ]; then
  bad "a failed build passed the gate"
else
  ok "a failed build fails the gate (exit $BUILD_EXIT)"
fi
assert_three_artifacts "$RUN15" "a failed build"
assert_eq "the failed build's verdict is FAIL"   "$(json_get "$RUN15/gate-result.json" 'doc["verdict"]')" "FAIL"
unset FAKE_BUILD_FAIL

echo ""
echo "--- case: --no-simulator-prep still writes all three artifacts ---"
# The SIM_PREP_CHECKS array is EMPTY on this path, which is exactly the
# expansion that used to be fatal under Bash 3.2. Combined with a genuine
# assertion failure so the verdict is FAIL on every platform (without one, a
# host that can read result bundles would legitimately pass).
export FAKE_UNIT_B1_A1=fail
RUN16="$(new_run_dir)"
NOPREP_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN16"     --repeat-classes "" --no-simulator-prep >/dev/null 2>&1 || NOPREP_EXIT=$?
if [ "$NOPREP_EXIT" -eq 0 ]; then
  bad "the run with --no-simulator-prep passed despite a genuine failure"
else
  ok "the run with --no-simulator-prep fails (exit $NOPREP_EXIT)"
fi
assert_three_artifacts "$RUN16" "--no-simulator-prep"
assert_eq "its verdict is FAIL"   "$(json_get "$RUN16/gate-result.json" 'doc["verdict"]')" "FAIL"
assert_eq "the run records that preparation was off" \
  "$(json_get "$RUN16/gate-result.json" 'doc["run_flags"]["simulator_prep"] is False')" "True"
unset FAKE_UNIT_B1_A1

echo ""
echo ""
echo ""
echo "--- case: a UI-only recovery round is recorded end to end ---"
# The hole the reviewer found: the shell writes a UI retry to lanes/ui-recovery
# (no trailing suffix), which the phase accounting's globs could not see - so a
# UI-only recovery recorded retries: 0 while the verdict said PASS. This case
# drives the REAL shell lines: clean unit lane, wedged UI shard, healed UI
# recovery, and then asks the result document whether the round ran.
export FAKE_UI_BATCH=crash
RUN17="$(new_run_dir)"
UIREC_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN17"     --repeat-classes "" >/dev/null 2>&1 || UIREC_EXIT=$?
if needs_extraction; then
  if [ "$UIREC_EXIT" -eq 0 ]; then
    ok "a UI-only recovery round lets the run pass"
  else
    bad "the UI-only recovery run failed (see $RUN17/summary.md)"
    tail -n 20 "$RUN17/summary.md" 2>/dev/null
  fi
  GATE17="$RUN17/gate-result.json"
  assert_eq "the round is recorded as having run"     "$(json_get "$GATE17" 'doc["infrastructure"]["retries"]')" "1"
  assert_eq "the UI classes recovered count as executed"     "$(json_get "$GATE17" 'len(doc["ui"]["classes_missing"])')" "0"
  assert_eq "both UI passes are in the record"     "$(json_get "$GATE17" 'len(doc["ui"]["passes"])')" "2"
  assert_eq "and the unit suite needed no recovery"     "$(json_get "$GATE17" 'len(doc["unit"]["passes"])')" "1"
  assert_contains "the healed round is a caveat, not silence"     "$(cat "$RUN17/summary.md")" "recovery"
else
  skip "UI-only recovery round (needs a readable result bundle)"
fi
unset FAKE_UI_BATCH

echo ""
echo "--- case: the repeat policy runs even when the unit lane failed ---"
# docs/CI.md: "Runs even when the unit or UI lane failed, so one red lane
# cannot hide the rest." A regression that nested the repeat block inside the
# lane-success branch would pass every other case while silently dropping the
# policy on exactly the runs that matter.
# The repetition itself must carry the genuine failure too: with a passing
# repetition the no-retry assertion below would be decided by an EMPTY lane
# (vacuously true), not by is-infra-only refusing a REAL failing test.
export FAKE_UNIT_B1_A1=fail FAKE_REPEAT_ITER=fail
RUN18="$(new_run_dir)"
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN18"     --repeat-classes AlphaTests --repeat-iterations 1 >/dev/null 2>&1 || true
GATE18="$RUN18/gate-result.json"
if needs_extraction; then
  assert_eq "the repetition still executed despite the failed lane"     "$(json_get "$GATE18" 'len(doc["focused_repeats"]["classes"][0]["iterations"])')" "1"
  # The genuine/infra split is only readable from an extracted bundle, so
  # this half is asserted exactly where that is possible.
  assert_eq "and a genuine assertion IN the repetition gets NO retry (it is final)"     "$(find "$RUN18/repeats" -name "iter-*-retry" 2>/dev/null | wc -l | tr -d ' ')" "0"
else
  skip "repeat-after-failed-lane (needs a readable result bundle)"
fi
assert_eq "the repeat artifacts exist regardless of the lane result"   "$([ -d "$RUN18/repeats" ] && echo yes || echo no)" "yes"
unset FAKE_UNIT_B1_A1 FAKE_REPEAT_ITER

echo ""
echo "--- case: a repetition lost to the launcher gets exactly one retry ---"
# The other half of the same decision: is-infra-only must let the verified
# launch wedge through, so the shell creates exactly one retry directory.
export FAKE_REPEAT_ITER=crash
RUN20="$(new_run_dir)"
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN20"     --repeat-classes AlphaTests --repeat-iterations 1 >/dev/null 2>&1 || true
assert_eq "the wedged repetition was retried exactly once"   "$(find "$RUN20/repeats" -name "iter-*-retry" 2>/dev/null | wc -l | tr -d ' ')" "1"
unset FAKE_REPEAT_ITER

echo ""
echo "--- case: the repeat policy is skipped when the build fails ---"
# docs/CI.md: "skipped when the build failed (no test products)". No plan and
# no products means there is nothing to repeat against.
export FAKE_BUILD_FAIL=1
RUN19="$(new_run_dir)"
run_gate --ref HEAD --gate-root "$WORK/gate-artifacts" --run-dir "$RUN19"     --repeat-classes AlphaTests --repeat-iterations 1 >/dev/null 2>&1 || true
assert_eq "no repeat artifacts when there are no test products"   "$([ -d "$RUN19/repeats" ] && echo yes || echo no)" "no"
assert_eq "the run still produced its three artifacts"   "$([ -f "$RUN19/gate-result.json" ] && echo yes || echo no)" "yes"
unset FAKE_BUILD_FAIL

echo "--- case: one authoritative full-gate invocation per requested SHA ---"
# The gate is single-shot: after a verdict, another COMPLETE run for the same
# SHA must be an explicit caller request. Nothing may restart it into "until
# green" - and the tooling refuses rather than trusting whatever drives it.
# (exit 2 is the policy refusal; 0/1 is a run that actually started, so these
# assertions are structural and hold on every platform.)
RUN12="$(new_run_dir)"
FIRST_EXIT=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-policy" --run-dir "$RUN12" --repeat-classes "" >"$WORK/policy-first.log" 2>&1 || FIRST_EXIT=$?
if [ "$FIRST_EXIT" -eq 2 ]; then
  bad "the first full gate run for this SHA was refused"
else
  ok "the first full gate run for this SHA is allowed to start"
fi
RUN13="$(new_run_dir)"
SECOND_EXIT=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 bash "$GATE" --ref HEAD --gate-root "$WORK/gate-policy" --run-dir "$RUN13" --repeat-classes "" >"$WORK/policy-second.log" 2>&1 || SECOND_EXIT=$?
assert_eq "a second full gate run is refused (exit 2)" "$SECOND_EXIT" "2"
assert_contains "the refusal states the policy" "$(cat "$WORK/policy-second.log")"   "one authoritative full-gate invocation per requested SHA"
assert_contains "the refusal names the explicit escape" "$(cat "$WORK/policy-second.log")"   "--allow-another-run"
assert_eq "the refused run started no work at all"   "$([ -d "$RUN13/lanes" ] && echo yes || echo no)" "no"
RUN14="$(new_run_dir)"
EXPLICIT_EXIT=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 bash "$GATE" --allow-another-run --ref HEAD --gate-root "$WORK/gate-policy" --run-dir "$RUN14" --repeat-classes "" >"$WORK/policy-third.log" 2>&1 || EXPLICIT_EXIT=$?
if [ "$EXPLICIT_EXIT" -eq 2 ]; then
  bad "--allow-another-run did not allow the explicitly requested run"
else
  ok "an explicitly requested second run is allowed to start"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: only one gate at a time ---"
mkdir -p "$WORK/gate/gate.lock"
echo "$$" > "$WORK/gate/gate.lock/pid"
RUN6="$(new_run_dir)"
if run_gate --ref HEAD --gate-root "$WORK/gate" --run-dir "$RUN6" >/dev/null 2>&1; then
  bad "a second concurrent gate was allowed to start"
else
  ok "a second concurrent gate is refused"
fi
assert_contains "the refusal explains why" "$(cat "$RUN_LOG")" "another gate is running"
rm -rf "$WORK/gate/gate.lock"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: merge mode is complete coverage WITHOUT the repeat layer ---"
# The mode decides the repeat DEFAULT, never the unit/UI coverage: a merge run
# still executes the complete suites, and its artifact says so. It is NOT
# partial - narrowing is not what happened; the mode's coverage is what it is.
RUN21="$(new_run_dir)"
MERGE_EXIT=0
run_gate --mode merge --ref HEAD --gate-root "$WORK/gate-mode" \
    --run-dir "$RUN21" >/dev/null 2>&1 || MERGE_EXIT=$?
GATE21="$RUN21/gate-result.json"
if needs_extraction; then
  assert_eq "a merge run passes its own coverage" "$MERGE_EXIT" "0"
  assert_eq "the result states the mode" \
    "$(json_get "$GATE21" 'doc["mode"]')" "merge"
  assert_eq "the complete unit suite ran" \
    "$(json_get "$GATE21" 'doc["unit"]["classes_observed"]')" "15"
  assert_eq "the complete UI suite ran" \
    "$(json_get "$GATE21" 'doc["ui"]["classes_observed"]')" "1"
  assert_eq "static checks ran" \
    "$(json_get "$GATE21" 'len(doc["static_checks"])')" "3"
  assert_eq "the coverage block says the repeat layer is absent" \
    "$(json_get "$GATE21" 'doc["coverage"]["repeat_policy"]')" "False"
  assert_eq "the repeat policy is recorded as not enabled" \
    "$(json_get "$GATE21" 'doc["focused_repeats"]["enabled"]')" "False"
  assert_eq "no repetition ran" \
    "$(json_get "$GATE21" 'doc["focused_repeats"]["executions"]')" "0"
  # A merge run is complete for what it claims; marking it partial would
  # misdescribe it AND hide the real reason a release head still needs a
  # release run on this SHA.
  assert_eq "a merge run is not a partial run" \
    "$(json_get "$GATE21" 'doc["partial"]')" "False"
  assert_contains "the summary names the mode and its limits" \
    "$(cat "$RUN21/summary.md")" "NO repeat/stress policy"
else
  skip "merge mode's verdict and coverage"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: release mode keeps the repeat policy (the mode only sets the default) ---"
RUN22="$(new_run_dir)"
RELEASE_EXIT=0
run_gate --mode release --ref HEAD --gate-root "$WORK/gate-mode" \
    --run-dir "$RUN22" --repeat-classes AlphaTests --repeat-iterations 1 \
    >/dev/null 2>&1 || RELEASE_EXIT=$?
GATE22="$RUN22/gate-result.json"
if needs_extraction; then
  assert_eq "the release run passes" "$RELEASE_EXIT" "0"
  assert_eq "the result states the mode" \
    "$(json_get "$GATE22" 'doc["mode"]')" "release"
  assert_eq "the repeat layer ran" \
    "$(json_get "$GATE22" 'doc["focused_repeats"]["executions"]')" "1"
else
  skip "release mode's repeat coverage"
fi
# An explicit repeat request wins over the merge default: the mode is a
# default, not a prohibition.
RUN23="$(new_run_dir)"
MERGE_REPEAT_EXIT=0
run_gate --mode merge --ref HEAD --gate-root "$WORK/gate-mode" \
    --run-dir "$RUN23" --repeat-classes AlphaTests --repeat-iterations 1 \
    >/dev/null 2>&1 || MERGE_REPEAT_EXIT=$?
if needs_extraction; then
  assert_eq "an explicit repeat request is honored in merge mode" \
    "$(json_get "$RUN23/gate-result.json" 'doc["focused_repeats"]["executions"]')" "1"
else
  skip "merge mode with an explicit repeat request"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: the SHA registry is per MODE, not per SHA ---"
# merge then release for one SHA is the normal flow and must stay possible;
# each mode on its own is still single-shot.
RUN24="$(new_run_dir)"
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 \
  bash "$GATE" --mode merge --allow-another-run --ref HEAD \
    --gate-root "$WORK/gate-mode-registry" --run-dir "$RUN24" \
    --repeat-classes "" >/dev/null 2>&1 || true
RUN25="$(new_run_dir)"
MERGE_AGAIN=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 \
  bash "$GATE" --mode merge --ref HEAD --gate-root "$WORK/gate-mode-registry" \
    --run-dir "$RUN25" --repeat-classes "" >/dev/null 2>&1 || MERGE_AGAIN=$?
assert_eq "a second merge run for the same SHA is refused" "$MERGE_AGAIN" "2"
RUN26="$(new_run_dir)"
RELEASE_AFTER_MERGE=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 \
  bash "$GATE" --mode release --ref HEAD --gate-root "$WORK/gate-mode-registry" \
    --run-dir "$RUN26" --repeat-classes "" >/dev/null 2>&1 || RELEASE_AFTER_MERGE=$?
if [ "$RELEASE_AFTER_MERGE" -eq 2 ]; then
  bad "a release run was refused because a MERGE result already existed"
else
  ok "a release run is allowed after a merge result exists (the merge is weaker)"
fi
RUN27="$(new_run_dir)"
RELEASE_AGAIN=0
PATH="$STUBS:$PATH" XCODEBUILD_POLL_INTERVAL_S=1 CONDUIT_PERF_TRACE=1 \
  bash "$GATE" --mode merge --ref HEAD --gate-root "$WORK/gate-mode-registry" \
    --run-dir "$RUN27" --repeat-classes "" >/dev/null 2>&1 || RELEASE_AGAIN=$?
assert_eq "and a merge run is refused once a release result exists" "$RELEASE_AGAIN" "2"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: two workers, two devices, one run ---"
# The gate fans the unit work and the UI work out over two project-owned
# devices. The evidence has to prove: every worker ran to completion, each on
# the device the run assigned it, with each lane's OWN artifact naming it too.
RUN28="$(new_run_dir)"
TWO_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate-workers" --run-dir "$RUN28" \
    --repeat-classes "" >/dev/null 2>&1 || TWO_EXIT=$?
GATE28="$RUN28/gate-result.json"
assert_eq "both workers were recorded" \
  "$(wc -l < "$RUN28/workers.tsv" | tr -d ' ')" "2"
assert_eq "the unit worker holds the first device" \
  "$(awk -F'\t' '$1=="unit" {print $3}' "$RUN28/workers.tsv")" \
  "6D08B063-B890-4D18-893B-D1E89E119919"
assert_eq "the ui worker holds the second device" \
  "$(awk -F'\t' '$1=="ui" {print $3}' "$RUN28/workers.tsv")" \
  "7E7E7E7E-1111-2222-3333-444444444444"
assert_eq "each worker ran to completion" \
  "$(awk -F'\t' '$6!="1" {print $1}' "$RUN28/workers.tsv" | wc -l | tr -d ' ')" "0"
assert_eq "both workers' logs were kept" \
  "$([ -s "$RUN28/workers/unit/worker.log" ] && [ -s "$RUN28/workers/ui/worker.log" ] && echo yes || echo no)" "yes"
if needs_extraction; then
  assert_eq "the fanned-out run passes" "$TWO_EXIT" "0"
  assert_eq "the result records both workers" \
    "$(json_get "$GATE28" 'len(doc["workers"])')" "2"
  assert_eq "the second device is recorded" \
    "$(json_get "$GATE28" 'doc["simulator2"]["udid"]')" \
    "7E7E7E7E-1111-2222-3333-444444444444"
  assert_eq "each lane's own artifact names its worker's device" \
    "$(json_get "$GATE28" 'doc["timing"]["lanes"]["ui"]["simulator"]["udid"]')" \
    "7E7E7E7E-1111-2222-3333-444444444444"
  assert_eq "the unit lane names the unit device" \
    "$(json_get "$GATE28" 'doc["timing"]["lanes"]["unit"]["simulator"]["udid"]')" \
    "6D08B063-B890-4D18-893B-D1E89E119919"
else
  skip "the fanned-out run's verdict"
fi

# ---------------------------------------------------------------------------
echo ""
echo "--- case: two workers may not be given one device ---"
RUN29="$(new_run_dir)"
SAME_DEVICE_EXIT=0
run_gate --ref HEAD --gate-root "$WORK/gate-workers" --run-dir "$RUN29" \
    --repeat-classes "" --second-simulator "Conduit CI Gate" \
    >/dev/null 2>&1 || SAME_DEVICE_EXIT=$?
assert_eq "one device for two workers is refused (exit 2)" "$SAME_DEVICE_EXIT" "2"
assert_contains "the refusal explains the two-device requirement" \
  "$(cat "$RUN_LOG")" "--second-simulator must differ from --simulator"

# ---------------------------------------------------------------------------
echo ""
echo "--- case: one worker runs both suites on the primary device ---"
RUN30="$(new_run_dir)"
ONE_EXIT=0
run_gate --workers 1 --ref HEAD --gate-root "$WORK/gate-workers" \
    --run-dir "$RUN30" --repeat-classes "" >/dev/null 2>&1 || ONE_EXIT=$?
if needs_extraction; then
  assert_eq "the one-worker run passes" "$ONE_EXIT" "0"
  assert_eq "it still ran the complete unit suite" \
    "$(json_get "$RUN30/gate-result.json" 'doc["unit"]["classes_observed"]')" "15"
  assert_eq "both workers ran on the PRIMARY device" \
    "$(json_get "$RUN30/gate-result.json" 'len({w["device"]["udid"] for w in doc["workers"]})')" "1"
  assert_eq "no second device is recorded" \
    "$(json_get "$RUN30/gate-result.json" 'doc["simulator2"]')" "None"
else
  skip "the one-worker run's verdict"
fi

echo ""
echo "=== $pass_count passed, $fail_count failed, $skip_count skipped ==="
[ "$fail_count" -eq 0 ]
