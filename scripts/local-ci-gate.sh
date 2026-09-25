#!/usr/bin/env bash
#
# Conduit LOCAL exhaustive CI gate.
#
# This is the authoritative exhaustive test gate for a trusted commit: it is
# run on our own Mac over SSH (never inside GitHub's runner system), and it
# always tests an EXACT commit in a throwaway detached worktree - never the
# invoking checkout's working tree. See docs/CI.md ("Local exhaustive gate")
# for the contract and for the policy rules this script implements.
#
# What it does, in order:
#   1. resolve --ref to a full commit SHA (the ONLY revision it will test);
#   2. create a detached worktree for that SHA outside the developer's tree;
#   3. xcodegen generate (the generated .xcodeproj is never committed);
#   4. cheap static checks (planner inventory validation, CI-tooling
#      regression suites, localization coverage), run CONCURRENTLY with
#      everything below unless --static-serial asks for the old order;
#   5. build-for-testing ONCE into a gate-specific DerivedData directory;
#   6-7. the COMPLETE ConduitTests and ConduitUITests suites, as two WORKERS
#      on two project-owned devices (--workers 1 serializes them on the unit
#      device), each with its own bounded recovery round;
#   8. the explicit repeat policy for timing/performance-sensitive classes:
#      K unconditional repetitions, every one of which must pass - inside the
#      unit worker, and only in release mode;
#   9. a machine-readable gate-result.json + summary.md, and exit 0 only if
#      the whole gate passed.
#
# Failure semantics (docs/CI.md): a genuine XCTest assertion failure fails the
# gate; an infrastructure/simulator/AX failure ALSO fails the gate but is
# reported as infrastructure, never as an assertion failure. Genuine
# assertions are never re-run until they agree: the lane runner is invoked
# with --iterations 1 (no Xcode-native flake retry), and the summarizer fails
# the gate outright if it finds an item that failed and then passed.
#
# The orchestrator and the result assembler come from the checkout this
# script was invoked from; the planner, lane runner and timing extractor come
# from the TESTED commit's tree, so the policy under test is the policy of the
# revision being certified.
#
# Bash 3.2 compatible (/bin/bash on macOS).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# jq is not required: every JSON-aware step goes through local-gate.py.
# Homebrew tools (xcodegen) are not on the minimal non-interactive SSH PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
# Test knob: every wedge-mitigation sleep and bounded-poll cadence below is
# wall-clock BEHAVIOUR for a real run (scale 1); the stubbed integration
# suite scales it to 0 so ~20 stubbed gate runs fit the hosted self-test
# job's ceiling. Deadlines are computed from `date`, never from sleep counts,
# so watchdog budgets are unaffected by the scale.
export GATE_SLEEP_SCALE="${GATE_SLEEP_SCALE:-1}"

HELPER="$SCRIPT_DIR/local-gate.py"
# Explicit default repeat classes: the settled-Markdown/dormancy and
# transcript-performance families that have repeatedly failed on
# scheduling-dependent behavior (the family that also blocked the 0.1.11
# build 147 release). Repeated unconditionally, so a flake in the family is
# evidence rather than a coin flip.
DEFAULT_REPEAT_CLASSES="SettledMessageIsolationTests,TranscriptPerfLedgerContractTests,TranscriptPerformanceFixtureTests,MarkdownRichContentHostedTests"

usage() {
  cat <<'USAGE'
Usage: scripts/local-ci-gate.sh --ref <git-ref-or-sha> [options]

Required:
  --ref REF                  Exact git ref or commit SHA to test. The gate
                             reports the full SHA it actually tested; a result
                             is only valid for that SHA.

Options:
  --mode MODE                Which certification this run is: "merge"
                             (trusted-PR merge: complete unit + UI coverage,
                             static checks, bounded recovery) or "release"
                             (that, plus the repeat/stress policy). Both modes
                             are exact-SHA and host-coordinated; the mode is
                             recorded in gate-result.json. Default: release, so
                             an invocation that does not ask for anything
                             weaker gets the strongest policy.
  --fetch                    Fetch --remote before resolving --ref.
  --remote NAME              Remote for --fetch (default: origin).
  --gate-root DIR            Root for runs + worktrees.
                             Default: <parent of the repository>/conduit-local-gate
  --run-dir DIR              This run's artifact directory.
                             Default: <gate-root>/runs/<sha12>-<UTC stamp>
  --worktree-root DIR        Parent directory for the throwaway worktree.
                             Default: <gate-root>/worktrees
  --simulator NAME           Simulator device the gate's unit worker runs on
                             (default: $GATE_SIMULATOR_NAME or "Conduit CI
                             Gate" - the gate's OWN device, created if it does
                             not exist, which is what makes erasing it safe).
  --second-simulator NAME    Device the UI worker runs on when --workers 2
                             (default: "<--simulator> 2", created on demand).
                             Also the gate's own device: two project-owned
                             devices, one host lease, disjoint UDIDs.
  --workers N                1 = run the unit work and the UI work one after
                             the other on the unit device; 2 = run them
                             CONCURRENTLY, the unit worker on --simulator and
                             the UI worker on --second-simulator (default).
                             Each worker owns exactly one UDID and never
                             touches the other's device.
  --unit-batch-max-classes N Classes per unit xcodebuild invocation (default:
                             28 - measured: 5 invocations cost ~31s more than
                             one invocation of the whole suite and ~105s less
                             than the planner's hosted-derived cap of 7, while
                             keeping a per-invocation watchdog and a bounded
                             blast radius). 0 restores the planner's own cap.
                             The planner still owns the batch layout and every
                             watchdog; this only moves its chunk size.
  --static-serial            Run the static checks in the foreground before the
                             build, as older revisions did, instead of
                             overlapping them with the test lanes. Diagnostic
                             only: the checks are the same either way.
  --allow-another-run        Explicitly request ANOTHER full gate run for a
                             SHA that already has a result. Without this the
                             gate refuses: one authoritative invocation per
                             (SHA, mode), and the gate never restarts itself
                             after a verdict.
  --no-simulator-prep        Skip the bounded Simulator preparation (shutdown,
                             erase, boot, wait for boot) that runs before each
                             lane. Preparation only: it never re-runs
                             anything, but skipping it makes the "device
                             failed to launch the host app" wedge far more
                             likely.
  --no-simulator-erase       Prepare the device with shutdown+boot instead of
                             erasing it first. Cheaper (~40s per lane saved),
                             and it is the mode that reproduced the launch
                             refusals on our Mac: use it to observe the raw
                             behavior, not for a release run.
  --repeat-classes CSV       Classes for the repeat policy.
                             Default: settled-Markdown/dormancy + transcript
                             performance families.
  --repeat-iterations N      Unconditional repetitions per repeat class (default 3).
  --repeat-timeout-cap S     Ceiling for one repeat iteration's watchdog
                             (default 900); the planner's batch budget still
                             applies, capped by this. 0 disables the ceiling
                             and uses the planner's budget unchanged.
  --allow-recovered-infrastructure
                             Downgrade "an infrastructure failure was
                             recovered by the bounded retry" from FAIL to a
                             recorded warning. Off by default: the run is not
                             trustworthy evidence either way. Must be recorded
                             wherever the result is cited.
  --keep-worktree            Keep the throwaway worktree after the run.
  --skip-static              Skip the cheap static checks (developer loop
                             only; the result is marked partial).
  --no-lock                  Skip the single-gate-per-Mac lock (UNSAFE: two
                             concurrent xcodebuild chains corrupt each other's
                             Simulator).
  -h, --help                 This text.

Exit status: 0 = gate PASS, 1 = gate FAIL, 2 = usage/preflight error,
3 = HOST BUSY (the SIMULATOR_TEST host resource is held by another
project/workflow; the refusing owner is printed). A SIGTERM-driven exit
during the run means the host-lease monitor detected UNCOORDINATED host
activity and tore the run down as invalid - see host-watch.jsonl in the
run dir; the result is not a gate verdict.
USAGE
}

REF=""; REMOTE="origin"; DO_FETCH=0
GATE_ROOT=""; RUN_DIR=""; WORKTREE_ROOT=""
# The gate runs on its OWN simulator device, so that erasing it (part of both
# the preparation and the bounded recovery round) can never touch a device a
# developer is using. GATE_SIMULATOR_NAME picks the device name; --simulator
# still overrides it for an operator who wants a specific one. An inherited
# SIMULATOR_NAME is deliberately IGNORED: the hosted workflow exports one, and
# naming a device the gate is free to erase is exactly what must never happen
# to a developer's simulator.
SIMULATOR_NAME="${GATE_SIMULATOR_NAME:-Conduit CI Gate}"
SIMULATOR_NAME2="${GATE_SIMULATOR_NAME2:-}"
REPEAT_CLASSES="$DEFAULT_REPEAT_CLASSES"
REPEAT_ITERATIONS=3
REPEAT_TIMEOUT_CAP=900
ALLOW_RECOVERED_INFRA=0
KEEP_WORKTREE=0
SKIP_STATIC=0
USE_LOCK=1
# Which certification this is. `release` is the default so that a caller who
# asks for nothing in particular gets the strongest policy, never a silently
# narrowed one; `merge` is the explicit trusted-PR mode.
MODE="release"
WORKERS=2
# Classes per unit xcodebuild invocation. 0 = the planner's own cap (7, the
# hosted-derived stall-avoidance policy). The gate measured on our Mac (same
# frozen products, same Booted+settled device, 2026-09-24) 292s/20 invocations
# at 7 classes, 247s/10 at 14, 218s/5 at 28 and 187s/1 at the whole suite -
# with ZERO launch-refusal or stall signatures in all 36 invocations, i.e. the
# sweep is dominated by ~4s of xcodebuild/CoreSimulator startup per invocation
# (80s of it at 7 classes, 13s for the whole suite). The gate therefore pays
# for 5 invocations instead of 20: it keeps a per-invocation watchdog and a
# bounded blast radius (and a meaningful continuation pass) while removing
# three quarters of the startup overhead. See docs/CI.md for the measurement.
UNIT_BATCH_MAX_CLASSES=28
STATIC_OVERLAP=1
# Set to 1 only when the caller passed the flag, so `--mode merge` (repeats
# off) can still be overridden explicitly without guessing from the value.
REPEAT_ITERATIONS_SET=0
REPEAT_CLASSES_SET=0

# One authoritative full-gate invocation per requested SHA: another full run
# must be an EXPLICIT caller request, never an automatic restart. The gate is
# a single-shot program - it never re-executes itself after a verdict.
ALLOW_ANOTHER_RUN=0
SIM_PREP=1
# 1 = erase the destination before booting it (see simulator_prep: the A/B
# probe on this machine showed erase is what clears the launch-refusal wedge).
SIM_ERASE="${GATE_SIMULATOR_ERASE:-1}"
# SIM_PREP_CHECKS/SIM_PREP_FAILED are initialized where the phase document is
# assembled (after the workers), not here: the shell cannot carry them across a
# worker subshell, so a second initialization here would only invite a future
# edit to write into the copy nothing reads.

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --workers) WORKERS="$2"; shift 2 ;;
    --unit-batch-max-classes) UNIT_BATCH_MAX_CLASSES="$2"; shift 2 ;;
    --second-simulator) SIMULATOR_NAME2="$2"; shift 2 ;;
    --static-serial) STATIC_OVERLAP=0; shift ;;
    --fetch) DO_FETCH=1; shift ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --gate-root) GATE_ROOT="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --worktree-root) WORKTREE_ROOT="$2"; shift 2 ;;
    --simulator) SIMULATOR_NAME="$2"; shift 2 ;;
    --allow-another-run) ALLOW_ANOTHER_RUN=1; shift ;;
    --no-simulator-prep) SIM_PREP=0; shift ;;
    --no-simulator-erase) SIM_ERASE=0; shift ;;
    --repeat-classes) REPEAT_CLASSES="$2"; REPEAT_CLASSES_SET=1; shift 2 ;;
    --repeat-iterations) REPEAT_ITERATIONS="$2"; REPEAT_ITERATIONS_SET=1; shift 2 ;;
    --repeat-timeout-cap) REPEAT_TIMEOUT_CAP="$2"; shift 2 ;;
    --allow-recovered-infrastructure) ALLOW_RECOVERED_INFRA=1; shift ;;
    --keep-worktree) KEEP_WORKTREE=1; shift ;;
    --skip-static) SKIP_STATIC=1; shift ;;
    --no-lock) USE_LOCK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "local-ci-gate: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$MODE" in
  merge) ;;
  release) ;;
  *) echo "local-ci-gate: --mode must be 'merge' or 'release', got '$MODE'" >&2
     exit 2 ;;
esac

# The mode's coverage policy, in ONE place so the result document and the run
# cannot drift apart:
#   merge   - complete unit + UI coverage, static checks, bounded recovery. No
#             repeat/stress layer: GitHub already runs the broad smoke gate on
#             every PR, and the repeat families are stress evidence, not unique
#             functional coverage (the repeat classes are themselves part of
#             the unit suite, which merge mode runs in full).
#   release - merge coverage PLUS the repeat policy below.
# An explicit --repeat-classes/--repeat-iterations always wins: the mode only
# decides the DEFAULT. So merge mode turns the layer off only when the caller
# asked for nothing - naming repeat classes (or a repetition count) with
# --mode merge runs them, using the release defaults for whatever was left
# unsaid, rather than silently producing a run whose artifact says merge and
# which repeats nothing.
if [ "$MODE" = "merge" ]; then
  if [ "$REPEAT_CLASSES_SET" -eq 0 ] && [ "$REPEAT_ITERATIONS_SET" -eq 0 ]; then
    REPEAT_CLASSES=""
    REPEAT_ITERATIONS=0
  fi
fi

case "$WORKERS" in
  1|2) ;;
  *) echo "local-ci-gate: --workers must be 1 or 2, got '$WORKERS'" >&2
     exit 2 ;;
esac
if [ -z "$SIMULATOR_NAME2" ]; then
  SIMULATOR_NAME2="$SIMULATOR_NAME 2"
fi
if [ "$WORKERS" -eq 2 ] && [ "$SIMULATOR_NAME2" = "$SIMULATOR_NAME" ]; then
  echo "local-ci-gate: --second-simulator must differ from --simulator (two workers need two devices)" >&2
  exit 2
fi
case "$UNIT_BATCH_MAX_CLASSES" in
  ''|*[!0-9]*) echo "local-ci-gate: --unit-batch-max-classes must be a non-negative integer, got '$UNIT_BATCH_MAX_CLASSES'" >&2
               exit 2 ;;
esac

if [ -z "$REF" ]; then
  echo "local-ci-gate: --ref is required (the exact ref or SHA to certify)" >&2
  usage >&2
  exit 2
fi

# Numeric flags are validated up front: a stray value would otherwise surface
# far later as a bash integer-comparison error (or as an opaque "meta.json not
# readable") in the middle of a run that has already spent build minutes.
for pair in "$REPEAT_ITERATIONS:--repeat-iterations" \
            "$REPEAT_TIMEOUT_CAP:--repeat-timeout-cap"; do
  value="${pair%%:*}"
  flag="${pair#*:}"
  case "$value" in
    ''|*[!0-9]*) echo "local-ci-gate: $flag must be a non-negative integer, got '$value'" >&2
                 exit 2 ;;
  esac
done
if [ -z "$SIMULATOR_NAME" ]; then
  echo "local-ci-gate: --simulator must not be empty" >&2
  exit 2
fi

# --- preflight ---------------------------------------------------------------
for tool in git python3 xcodebuild xcodegen; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "local-ci-gate: required tool not found on PATH: $tool" >&2
    exit 2
  fi
done

# jq is not required, but without it ci-lib.sh cannot resolve the simulator
# UDID: the destination falls back to a name-based lookup and every
# erase-based recovery becomes fatal ("environment cannot be trusted"). Better
# to say so now than an hour into a run.
if ! command -v jq >/dev/null 2>&1; then
  echo "local-ci-gate: warning: jq is not on PATH - simulator UDID resolution and erase-based recovery will be degraded" >&2
fi

if [ ! -f "$HELPER" ]; then
  echo "local-ci-gate: helper missing: $HELPER" >&2
  exit 2
fi

REPO_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null)" || true
if [ -z "$REPO_ROOT" ]; then
  echo "local-ci-gate: $SCRIPT_DIR is not inside a git working tree" >&2
  exit 2
fi

# Fail closed on the wrong repository: the gate certifies Conduit commits, so
# the invoking checkout must BE a Conduit checkout. Without this, running the
# script from some unrelated repository would resolve --ref there and report a
# meaningless SHA as the tested commit.
for marker in project.yml ConduitTests ConduitUITests; do
  if [ ! -e "$REPO_ROOT/$marker" ]; then
    echo "local-ci-gate: $REPO_ROOT does not look like the Conduit repository (missing $marker)" >&2
    exit 2
  fi
done

# --- host-level SIMULATOR_TEST lease (ios-ci-host) ---------------------------
# (The lease itself is acquired AFTER the run directory exists - see the
# block following the run banner below - so it can record the resolved SHA
# and land its evidence inside the run dir. Everything above this point is
# cheap, non-simulator preflight.)

# The device is pinned by name and every phase must use the SAME one: the
# build, the lanes and the recovery round all resolve their destination
# through ci-lib.sh, which reads this variable. It is passed EXPLICITLY to
# those invocations (see run_lane / simulator_prep / the build call) and is
# deliberately NOT exported: the tested tree's own CI-tooling suites stub
# `simctl` with the default device name, and an exported override makes those
# suites fail against a device their fixtures do not know about.

# Everything the gate writes lives OUTSIDE the repository: the invoking
# checkout is never the run's workspace and never accumulates gate output.
if [ -z "$GATE_ROOT" ]; then
  GATE_ROOT="$(cd "$REPO_ROOT/.." && pwd)/conduit-local-gate"
fi
if [ -z "$WORKTREE_ROOT" ]; then
  WORKTREE_ROOT="$GATE_ROOT/worktrees"
fi

# ... and an explicit override must not be able to put them inside it either.
# Both sides are canonicalized (parent-anchored when the path does not exist
# yet) because a plain string prefix test is defeated by a path that is
# spelled differently - a relative override, or a different path style on
# Windows/MSYS - and then the guard would silently protect nothing.
canonical_path() { # $1 = path that may not exist yet
  local path="$1" parent base
  if [ -d "$path" ]; then
    ( cd "$path" && pwd -P ) 2>/dev/null || printf '%s' "$path"
    return 0
  fi
  parent="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$parent" ]; then
    printf '%s/%s' "$( cd "$parent" && pwd -P )" "$base"
  else
    printf '%s' "$path"
  fi
}
REPO_CANON="$(canonical_path "$REPO_ROOT")"
for pair in "$RUN_DIR:--run-dir" "$WORKTREE_ROOT:--worktree-root" \
            "$GATE_ROOT:--gate-root"; do
  candidate="${pair%%:*}"
  flag="${pair#*:}"
  [ -z "$candidate" ] && continue
  case "$(canonical_path "$candidate")" in
    "$REPO_CANON"|"$REPO_CANON"/*)
      echo "local-ci-gate: $flag must live outside the repository ($REPO_CANON)" >&2
      exit 2
      ;;
  esac
done

# --- single-gate-per-Mac lock ------------------------------------------------
# Two concurrent xcodebuild/test chains on one Mac corrupt each other's
# Simulator state; a gate result from such a run would be meaningless. The
# acquisition lives in ci-gate-lock.sh and is structural: a temporary lock
# directory carries the PID before it is renamed into the canonical location,
# and the acquisition is verified afterwards - so no contender can ever
# believe it owns the gate when it does not.
LOCK_DIR="$GATE_ROOT/gate.lock"
. "$SCRIPT_DIR/ci-gate-lock.sh"

# Reap anything of THIS RUN still alive in its own process group.
#
# The worker/static group passes in cleanup() reach the worker and the lane
# runner, but NOT the xcodebuild invocation: ci-lib.sh's run_with_deadline puts
# each invocation in a second process group of its own (the same `set -m`
# idiom, which is what lets the watchdog kill a whole invocation). That
# grandchild is the process actually holding a device, so it is selected here
# by its command line. The gate's own pid is excluded explicitly.
#
# SELECTION is a plain SUBSTRING test, deliberately - never a regex. The
# candidates are the processes whose argv embeds this run's directory
# (-xctestrun / -resultBundlePath / --result-dir) or one of this run's device
# UDIDs (every `xcrun simctl` call carries only the UDID), and the SHAPE fence
# (`xcodebuild` / lane runner / `xcrun` / `xcresulttool`) keeps a process that
# merely mentions a path - an editor, a tail, another shell - from ever being
# signalled. There is nothing to escape and therefore nothing that can silently
# fail to match: an earlier revision escaped the path for `pgrep -f`'s ERE, and
# a single misplaced backslash turned the pattern into one that matched
# nothing, which would have made this whole pass a silent no-op.
reap_run_chain() {
  if [ -z "${RUN_DIR:-}" ] || [ ! -d "$RUN_DIR" ]; then
    return 0
  fi
  if ! command -v ps >/dev/null 2>&1; then
    echo "local-ci-gate: the teardown sweep needs ps, which is unavailable; a surviving test chain may be left behind" >&2
    return 0
  fi
  local _mc_pid _mc_cmd _mc_targets=""
  while read -r _mc_pid _mc_cmd; do
    case "$_mc_pid" in ''|*[!0-9]*) continue ;; esac
    [ "$_mc_pid" = "$$" ] && continue
    [ -z "$_mc_cmd" ] && continue
    case "$_mc_cmd" in
      *"$RUN_DIR"*) ;;
      *) case "${SIMULATOR_UDID:-}${SIMULATOR2_UDID:-}" in
           '') continue ;;
           *) case "$_mc_cmd" in
                *"${SIMULATOR_UDID:-}"*) ;;
                *"${SIMULATOR2_UDID:-}"*) ;;
                *) continue ;;
              esac ;;
         esac ;;
    esac
    # The command shape is the fence: only a test chain is ever signalled.
    case "$_mc_cmd" in
      *xcodebuild*|*ci-test-lane.sh*|*xcrun*|*xcresulttool*) ;;
      *) continue ;;
    esac
    _mc_targets="$_mc_targets $_mc_pid"
  done <<EOF
$(ps -eo pid=,command= 2>/dev/null)
EOF
  [ -z "$_mc_targets" ] && return 0
  for _mc_pid in $_mc_targets; do
    printf 'local-ci-gate: terminating a surviving run process: pid %s, group leader of %s\n' \
      "$_mc_pid" "$(ps -o command= -p "$_mc_pid" 2>/dev/null | cut -c1-90)" >&2
    kill -TERM -- "-$_mc_pid" 2>/dev/null || kill -TERM "$_mc_pid" 2>/dev/null || true
  done
  # TERM, a bounded settle for the process to drain (xcodebuild writes its
  # xcresult and releases the simulator), then KILL for survivors: the lease
  # and the gate lock are released immediately after this, so nothing may be
  # left to chance. The settle is a wedge-mitigation sleep, so the stubbed
  # integration suite scales it to 0 and gets the KILL path immediately.
  sleep $(( ${GATE_TEARDOWN_GRACE_S:-10} * GATE_SLEEP_SCALE ))
  local _mc_member
  for _mc_pid in $_mc_targets; do
    if kill -0 "$_mc_pid" 2>/dev/null; then
      kill -KILL -- "-$_mc_pid" 2>/dev/null || kill -KILL "$_mc_pid" 2>/dev/null || true
      continue
    fi
    # The leader is gone, but a process group outlives its leader: a member
    # that ignored the TERM (a wedged simulator helper) keeps the device. The
    # group is escalated only while a member still looks like THIS run's chain,
    # so a pid that has since been reused cannot draw a signal.
    for _mc_member in $(pgrep -g "$_mc_pid" 2>/dev/null || true); do
      case "$(ps -o command= -p "$_mc_member" 2>/dev/null || true)" in
        *xcodebuild*|*ci-test-lane.sh*|*xcrun*|*xcresulttool*)
          kill -KILL -- "-$_mc_pid" 2>/dev/null || true
          break
          ;;
      esac
    done
  done
  return 0
}

cleanup() {
  local status=$?
  # Reap the lease-acquisition watchdog first: a TERM landing in the small
  # window between its spawn and the post-exec kill would otherwise leave a 60s
  # orphaned sleep behind. The variable is cleared once reaped so no later
  # signal can reach a reused PID.
  if [ -n "${HOST_LEASE_WATCHDOG:-}" ]; then
    if kill -0 "$HOST_LEASE_WATCHDOG" 2>/dev/null; then
      kill "$HOST_LEASE_WATCHDOG" 2>/dev/null || true
    fi
    wait "$HOST_LEASE_WATCHDOG" 2>/dev/null || true
    HOST_LEASE_WATCHDOG=""
  fi
  # Live workers hold xcodebuild/test chains against this run's devices. A
  # tear-down (INT/TERM from the host monitor, a closed SSH session) must take
  # them with it: an orphaned chain would keep driving a device - and keep
  # testing - after this script has released the host lease and the gate lock,
  # which is exactly the uncoordinated state the lease exists to prevent.
  #
  # TWO passes, because the chain spans two process-group levels:
  #   1. each worker was launched under `set -m`, so it leads its OWN group
  #      (never this script's, and never its caller's): `-$pid` reaches the
  #      worker and the lane runner below it;
  #   2. the xcodebuild invocation itself is put in a SECOND, separate group by
  #      ci-lib.sh's run_with_deadline (the same `set -m` idiom, which is what
  #      lets its watchdog kill a whole invocation) - so pass 1 does NOT reach
  #      it. Those processes are found by the run directory in their command
  #      line (-xctestrun / -resultBundlePath / --result-dir all point inside
  #      it), and only that shape is signalled: a process that merely mentions
  #      the path is never touched.
  # Both passes TERM first, then KILL, and every pid is reaped, so the lease
  # below is released only once the chain is actually gone.
  if [ -n "${WORKER_PIDS:-}" ]; then
    local _wp
    for _wp in $WORKER_PIDS; do
      kill -TERM -- "-$_wp" 2>/dev/null || kill -TERM "$_wp" 2>/dev/null || true
    done
    for _wp in $WORKER_PIDS; do
      wait "$_wp" 2>/dev/null || true
    done
    for _wp in $WORKER_PIDS; do
      kill -0 "$_wp" 2>/dev/null || continue
      kill -KILL -- "-$_wp" 2>/dev/null || kill -KILL "$_wp" 2>/dev/null || true
    done
    for _wp in $WORKER_PIDS; do
      wait "$_wp" 2>/dev/null || true
    done
    WORKER_PIDS=""
  fi
  # The overlapped static phase is launched the same way, and its check
  # processes (`unittest`, the l10n checker) are its group's members too.
  if [ -n "${STATIC_PID:-}" ]; then
    kill -TERM -- "-$STATIC_PID" 2>/dev/null || kill -TERM "$STATIC_PID" 2>/dev/null || true
    wait "$STATIC_PID" 2>/dev/null || true
    if kill -0 "$STATIC_PID" 2>/dev/null; then
      kill -KILL -- "-$STATIC_PID" 2>/dev/null || kill -KILL "$STATIC_PID" 2>/dev/null || true
      wait "$STATIC_PID" 2>/dev/null || true
    fi
    STATIC_PID=""
  fi
  # Pass 2: whatever of THIS RUN is still alive in its own process group - the
  # in-flight xcodebuild/simctl invocation, or a lane runner whose worker is
  # gone. Bounded: the sweep is one pgrep + two kill rounds, and it runs only on
  # a tear-down or at the end of an already-finished run.
  reap_run_chain
  # Release the host SIMULATOR_TEST lease FIRST: closing fd 3 EOFs the
  # holder helper's stdin, which releases the lease - and this works even
  # for exit paths that reach nothing else (no LONG-LIVED child keeps the
  # write end open; short-lived probes inherit it only transiently).
  # Escalation (TERM, then KILL) happens ONLY while the holder is
  # demonstrably alive, and the PID is cleared once reaped: a signal to a
  # reaped PID can reach an unrelated process on this shared host.
  if [ -n "${HOST_LEASE_HOLDER:-}" ]; then
    exec 3>&- || true
    local _w=0
    while kill -0 "$HOST_LEASE_HOLDER" 2>/dev/null && [ "$_w" -lt 10 ]; do
      sleep 1
      _w=$(( _w + 1 ))
    done
    if kill -0 "$HOST_LEASE_HOLDER" 2>/dev/null; then
      kill -TERM "$HOST_LEASE_HOLDER" 2>/dev/null || true
      sleep 1
      kill -0 "$HOST_LEASE_HOLDER" 2>/dev/null && kill -KILL "$HOST_LEASE_HOLDER" 2>/dev/null || true
    fi
    wait "$HOST_LEASE_HOLDER" 2>/dev/null || true
    HOST_LEASE_HOLDER=""
  fi
  if [ -n "${HOST_LEASE_DIR:-}" ] && [ -n "${RUN_DIR:-}" ] && [ -d "$RUN_DIR" ]; then
    if [ -s "$HOST_LEASE_JSON" ]; then
      cp "$HOST_LEASE_JSON" "$RUN_DIR/host-lease.json" 2>/dev/null || true
    fi
    if [ -f "$HOST_LEASE_DIR/watch.jsonl" ]; then
      cp "$HOST_LEASE_DIR/watch.jsonl" "$RUN_DIR/host-watch.jsonl" 2>/dev/null || true
    fi
  fi
  # Removes the canonical lock ONLY if its pid is still this process, and
  # clears an in-flight temporary lock (an interrupt mid-acquisition).
  gate_lock_release
  # An interrupt (Ctrl-C, closed SSH session) must not leave a registered
  # worktree behind: the next run for the same commit would then fail at
  # `git worktree add`, and the operator would have to clean up by hand.
  # remove_worktree is idempotent, so the normal exit path calling it too is
  # harmless. A SIGKILL is the one case nothing can cover; the gate prints
  # the manual recovery command for that.
  if [ -n "${WT:-}" ] && [ -d "$WT" ] && command -v remove_worktree >/dev/null 2>&1; then
    remove_worktree >/dev/null 2>&1 || true
  fi
  return "$status"
}
# EXIT runs cleanup and keeps the gate's own exit code. INT/TERM must also
# STOP: a handler that only returns (the same function on one trap) cleans up
# and then lets the run continue against a deleted worktree, with the lock
# released while the run is still going.
# These traps are installed BEFORE the acquisition sequence can run, so an
# interrupt during acquisition cannot leak the temporary lock directory.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
# An SSH drop SIGHUPs the session leader: without this the cleanup never
# runs, the lane runner is reparented and keeps the device busy, and the
# next invocation legally steals a lock whose owner is dead - two chains
# on one Mac.
trap 'cleanup; exit 129' HUP

if [ "$USE_LOCK" -eq 1 ]; then
  mkdir -p "$GATE_ROOT"
  LOCK_STATUS=0
  acquire_gate_lock "$LOCK_DIR" || LOCK_STATUS=$?
  case "$LOCK_STATUS" in
    0) ;;
    2)
      if [ -n "${GATE_LOCK_OWNER:-}" ]; then
        echo "local-ci-gate: another gate is running (pid $GATE_LOCK_OWNER): refusing to run two xcodebuild chains on one Mac" >&2
        echo "local-ci-gate: if that process is gone, remove $LOCK_DIR" >&2
      else
        echo "local-ci-gate: the gate lock at $LOCK_DIR exists with no readable owner, so it is BUSY - not provably stale" >&2
        echo "local-ci-gate: if you are certain no gate is running, remove $LOCK_DIR" >&2
      fi
      exit 2
      ;;
    *)
      echo "local-ci-gate: could not acquire the gate lock at $LOCK_DIR" >&2
      exit 2
      ;;
  esac
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Any command that talks to Xcode/CoreSimulator gets a wall-clock bound: a
# wedged CoreSimulatorService can hang `xcrun simctl list` indefinitely, and
# an operator watching an SSH session with no progress has no way to tell a
# hung tool from a long build. Bounded here rather than left to the lane
# runner's own deadlines, because these run before any lane exists.
run_bounded() { # $1=budget seconds $2=log path $3=working directory, rest=command
  local budget="$1" log="$2" cwd="$3"
  shift 3
  local pid status deadline grace
  mkdir -p "$(dirname "$log")"
  # Job control puts this one background job into its OWN process group - the
  # idiom ci-lib.sh's run_with_deadline uses for the same reason. The set -m /
  # set +m pair is deliberate and local to this one launch: it creates the
  # child's group for the kill below, then restores the parent shell's state. Without it a
  # non-interactive bash leaves the child in the SCRIPT's group, so
  # `kill -- -$pid` targets a group that does not exist, fails silently, and
  # only the direct child dies while a grandchild keeps the Simulator busy
  # after the budget expired.
  set -m
  ( cd "$cwd" && exec "$@" ) >"$log" 2>&1 3>&- &
  pid=$!
  set +m
  deadline=$(( $(date +%s) + budget ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # Kill the job's GROUP (set -m above made the child its leader) so
      # grandchildren spawned by the command go too: a TERM to $pid alone
      # would leave them holding the Simulator after the budget expired or
      # after an interrupt.
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
      grace=5
      while [ "$grace" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
        sleep $(( 1 * GATE_SLEEP_SCALE ))
        grace=$(( grace - 1 ))
      done
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null
      echo "local-ci-gate: '$*' exceeded its ${budget}s budget" >&2
      return 124
    fi
    sleep $(( 1 * GATE_SLEEP_SCALE ))
  done
  status=0
  wait "$pid" || status=$?
  return "$status"
}

# --- resolve the tested revision --------------------------------------------
if [ "$DO_FETCH" -eq 1 ]; then
  echo "== fetching $REMOTE =="
  if ! git -C "$REPO_ROOT" fetch "$REMOTE" --tags --prune; then
    echo "local-ci-gate: fetch from $REMOTE failed" >&2
    exit 2
  fi
fi

SHA="$(git -C "$REPO_ROOT" rev-parse --verify "${REF}^{commit}" 2>/dev/null)" || true
if [ -z "$SHA" ]; then
  echo "local-ci-gate: cannot resolve '$REF' to a commit in $REPO_ROOT" >&2
  exit 2
fi
case "$SHA" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    ;;
  *) echo "local-ci-gate: resolved revision is not a commit id: $SHA" >&2; exit 2 ;;
esac
SHA12="${SHA%${SHA#????????????}}"
GATE_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

if [ -z "$RUN_DIR" ]; then
  RUN_DIR="$GATE_ROOT/runs/${SHA12}-$GATE_STAMP"
fi
# Unique per run: a worktree left behind by an interrupted run (or two commits
# sharing a 12-character prefix) must never collide with this one.
WT="$WORKTREE_ROOT/${SHA12}-$GATE_STAMP"
mkdir -p "$WORKTREE_ROOT"

# A reused run directory would let a previous run's plan projection or lane
# artifacts be read back as this run's evidence. Refuse it instead of
# producing a result assembled from two different runs.
# One authoritative full-gate invocation per requested (SHA, mode). A second
# full run is a caller decision, never an automatic restart: the gate itself is
# single-shot and must not be looped into "until green" by whatever drives it.
# The record lives under the gate ROOT (not the run dir), so it holds however
# the run's artifacts were laid out (--run-dir included).
#
# A record covers the requested run when its mode is AT LEAST as strong:
# release covers release and merge (a release result is strictly stronger
# evidence for the same tree), merge covers merge only - so the normal
# merge-then-release flow for one SHA stays possible, while neither mode can be
# re-run on its own without --allow-another-run.
SHA_REGISTRY_DIR="$GATE_ROOT/sha-results"
SHA_REGISTRY="$SHA_REGISTRY_DIR/$SHA.log"
mode_strength() { # $1 = mode -> 1 (merge) / 2 (release); unknown = 2
  case "${1:-}" in
    merge) echo 1 ;;
    *) echo 2 ;;
  esac
}
registry_covers() { # $1 = requested mode -> 0 when an existing record covers it
  [ -s "$SHA_REGISTRY" ] || return 1
  local want line rec_mode
  want="$(mode_strength "$1")"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # 5th field is the mode; records written before the field existed were
    # all release runs, which is exactly what an empty field must mean.
    rec_mode="$(printf '%s\n' "$line" | awk -F'\t' '{print $5}')"
    [ -z "$rec_mode" ] && rec_mode="release"
    if [ "$(mode_strength "$rec_mode")" -ge "$want" ]; then
      # Recorded so the refusal can name WHICH mode already covers the SHA: a
      # release record blocking a merge request and a merge record blocking
      # another merge are different sentences.
      GATE_REGISTRY_COVERING_MODE="$rec_mode"
      return 0
    fi
  done < "$SHA_REGISTRY"
  return 1
}
GATE_REGISTRY_COVERING_MODE=""
# How many earlier records this SHA already has: a passing release run that
# follows a red merge run for the same SHA is the one bounded second attempt
# the mode rules allow, and where the result is cited from it has to be
# visible.
GATE_PRIOR_RUNS=0
if [ -s "$SHA_REGISTRY" ]; then
  # awk, not `grep -c ... || echo 0`: grep -c prints "0" AND exits 1 when
  # nothing matches, so the fallback would append a second line and the value
  # would reach argparse as "0\n0" - an error far from its cause.
  GATE_PRIOR_RUNS="$(awk 'END { print NR + 0 }' "$SHA_REGISTRY" 2>/dev/null || echo 0)"
  case "$GATE_PRIOR_RUNS" in ''|*[!0-9]*) GATE_PRIOR_RUNS=0 ;; esac
fi
if [ "$ALLOW_ANOTHER_RUN" -ne 1 ] && registry_covers "$MODE"; then
  echo "local-ci-gate: a full ${GATE_REGISTRY_COVERING_MODE:-$MODE} gate result already exists for $SHA:" >&2
  sed 's/^/  /' "$SHA_REGISTRY" >&2
  echo "local-ci-gate: one authoritative full-gate invocation per requested SHA" >&2
  if [ "$(mode_strength "${GATE_REGISTRY_COVERING_MODE:-}")" -gt "$(mode_strength "$MODE")" ]; then
    echo "local-ci-gate: a ${GATE_REGISTRY_COVERING_MODE} result already covers a $MODE request for the same SHA." >&2
  else
    echo "local-ci-gate: (and mode) - one authoritative run per (SHA, mode)." >&2
  fi
  echo "local-ci-gate: if you really want another full run, request it explicitly with --allow-another-run" >&2
  exit 2
fi
mkdir -p "$SHA_REGISTRY_DIR"

if [ -d "$RUN_DIR" ] && [ -n "$(ls -A "$RUN_DIR" 2>/dev/null)" ]; then
  echo "local-ci-gate: run directory $RUN_DIR already exists and is not empty; choose another --run-dir" >&2
  exit 2
fi
if ! mkdir -p "$RUN_DIR"; then
  echo "local-ci-gate: cannot create the run directory $RUN_DIR (a file in the way, or an unwritable parent?)" >&2
  exit 2
fi

GATE_STARTED_AT="$(now_iso)"
GATE_START_EPOCH=$(date +%s)

echo "== Conduit local gate =="
echo "repo root : $REPO_ROOT"
echo "tested ref: $REF -> $SHA"
echo "mode      : $MODE ($([ "$MODE" = release ] && echo 'complete coverage + repeat/stress policy' || echo 'complete coverage, no repeat/stress policy'))"
echo "run dir   : $RUN_DIR"
echo "worktree  : $WT"
echo "simulator : $SIMULATOR_NAME"
if [ "$WORKERS" -eq 2 ]; then
  echo "workers   : 2 (unit work on '$SIMULATOR_NAME', UI work on '$SIMULATOR_NAME2', one host lease)"
else
  echo "workers   : 1 (both suites on '$SIMULATOR_NAME', one after the other)"
fi

# --- host-level SIMULATOR_TEST lease (ios-ci-host) ---------------------------
# The per-checkout gate lock above only excludes other GATES on the same
# checkout; it cannot see VitalRoute, SeaBag, a future project, or an agent
# session's xcodebuild/simctl chain on this shared Mac - and two concurrent
# chains corrupt each other's Simulator state (the launch-wedge class of
# infrastructure failures this gate's recovery round exists to absorb). The
# host-level coordinator closes that hole: from here - before any Xcode or
# Simulator work - until the gate exits, this run exclusively holds the
# SIMULATOR_TEST resource, fail-closed.
#
# Mechanism: a background helper (`acquire --hold`) owns the lease and reads
# a FIFO as stdin. This script holds the FIFO's write end (fd 3) and closes
# that descriptor in every LONG-LIVED child it spawns (`3>&-` in run_bounded,
# run_static_check, the build subshell, run_lane, and simulator_prep), so
# the write end dies with THIS process: on every exit path - including a
# SIGKILL that runs no trap - the kernel closes the pipe, the helper sees
# EOF, and the lease is released; a surviving lane subtree can never hold
# the host hostage by inheritance. (Short-lived synchronous probes - git,
# date, the python3 JSON parses - transiently inherit fd 3 and release it
# on exit within milliseconds.) The helper also watches for uncoordinated
# simulator activity (host-lease/watch.jsonl) and, by release policy,
# SIGTERMs THIS script so the run is torn down as invalid instead of being
# certified against a busy host; the teardown completes when the currently
# running lane returns (bash defers traps until a foreground child exits).
IOS_CI_HOST_BIN="${IOS_CI_HOST:-$(command -v ios-ci-host 2>/dev/null || true)}"
if [ -z "$IOS_CI_HOST_BIN" ] && [ -x "$HOME/.local/bin/ios-ci-host" ]; then
  IOS_CI_HOST_BIN="$HOME/.local/bin/ios-ci-host"
fi
if [ -z "$IOS_CI_HOST_BIN" ] || [ ! -x "$IOS_CI_HOST_BIN" ]; then
  echo "local-ci-gate: the host coordinator ios-ci-host was not found (PATH, \$IOS_CI_HOST, or ~/.local/bin)" >&2
  echo "local-ci-gate: the exhaustive gate requires host-level SIMULATOR_TEST exclusivity on the shared build Mac;" >&2
  echo "local-ci-gate: install the coordinator (~/projects/ios-ci-host/install.sh on ios-mac); refusing to run uncoordinated" >&2
  exit 2
fi
if ! "$IOS_CI_HOST_BIN" doctor >/dev/null 2>&1; then
  echo "local-ci-gate: the host coordinator failed its self-check (run: ios-ci-host doctor)" >&2
  exit 2
fi
echo "== host coordinator: $IOS_CI_HOST_BIN =="
HOST_LEASE_DIR="$GATE_ROOT/host-lease"
mkdir -p "$HOST_LEASE_DIR"
# Reused per run (the gate lock above serializes same-root gates); the
# watch log APPENDS across runs on purpose - it is the host-busy evidence
# trail - rotating once past 10MB (each run's own copy in the run dir stays
# complete); attempt.json/holder.err are reset each run.
HOST_LEASE_FIFO="$HOST_LEASE_DIR/holder.fifo"
HOST_LEASE_JSON="$HOST_LEASE_DIR/attempt.json"
if [ -f "$HOST_LEASE_DIR/watch.jsonl" ] \
   && [ "$(wc -c < "$HOST_LEASE_DIR/watch.jsonl")" -gt 10485760 ]; then
  mv "$HOST_LEASE_DIR/watch.jsonl" "$HOST_LEASE_DIR/watch-$(date +%s).jsonl" || true
fi
rm -f "$HOST_LEASE_FIFO" "$HOST_LEASE_JSON" "$HOST_LEASE_DIR/holder.err"
# 0600: on a multi-account build Mac no other local user may be able to open
# the FIFO's read end and race the lease rendezvous.
if ! ( umask 077 && mkfifo "$HOST_LEASE_FIFO" ); then
  echo "local-ci-gate: cannot create the host-lease FIFO at $HOST_LEASE_FIFO" >&2
  exit 2
fi
IOS_CI_HOST_CONTROLLER_PID=$$ \
  "$IOS_CI_HOST_BIN" acquire simulator-test \
    --project Conduit \
    --repo "$REPO_ROOT" \
    --workflow local-exhaustive-gate \
    --sha "$SHA" \
    --simulator-name "$SIMULATOR_NAME" \
    --description "Conduit local exhaustive gate" \
    --fail-if-busy --hold \
    --monitor "$HOST_LEASE_DIR/watch.jsonl" --on-foreign terminate \
    < "$HOST_LEASE_FIFO" > "$HOST_LEASE_JSON" 2> "$HOST_LEASE_DIR/holder.err" &
HOST_LEASE_HOLDER=$!
# A helper that never opens the FIFO's read end (broken, or dead before its
# stdin open completes) would leave the exec below blocked forever inside
# open(2); this watchdog turns that into a clean refusal. It fires on the
# MISSING VERDICT alone - a dead helper fails `kill -0`, so conditioning on
# liveness would miss exactly the deadlock this exists to break.
(
  # The sleep must not inherit the gate's stdio: killing THIS subshell does
  # not kill the sleep child, and an orphaned sleep holding stdout/stderr
  # keeps an SSH channel open until it expires.
  sleep 60 </dev/null >/dev/null 2>&1
  if [ ! -s "$HOST_LEASE_JSON" ]; then
    echo "local-ci-gate: the host-lease helper never completed acquisition (is ios-ci-host functional?)" >&2
    kill -TERM "$HOST_LEASE_HOLDER" 2>/dev/null || true
    kill -TERM "$$" 2>/dev/null || true
  fi
) &
HOST_LEASE_WATCHDOG=$!
exec 3>"$HOST_LEASE_FIFO"
kill "$HOST_LEASE_WATCHDOG" 2>/dev/null || true
wait "$HOST_LEASE_WATCHDOG" 2>/dev/null || true
HOST_LEASE_WATCHDOG=""
# The helper prints exactly one flushed JSON line before holding; wait for
# it (or for the helper to die refusing).
HOST_LEASE_WAITED=0
while [ ! -s "$HOST_LEASE_JSON" ]; do
  if ! kill -0 "$HOST_LEASE_HOLDER" 2>/dev/null; then
    break
  fi
  sleep 1
  HOST_LEASE_WAITED=$(( HOST_LEASE_WAITED + 1 ))
  if [ "$HOST_LEASE_WAITED" -ge 60 ]; then
    echo "local-ci-gate: the host-lease helper produced no verdict within ${HOST_LEASE_WAITED}s" >&2
    break
  fi
done
HOST_LEASE_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("status",""))' "$HOST_LEASE_JSON" 2>/dev/null || true)"
if [ "$HOST_LEASE_STATUS" != "acquired" ]; then
  exec 3>&- || true
  kill -0 "$HOST_LEASE_HOLDER" 2>/dev/null && kill "$HOST_LEASE_HOLDER" 2>/dev/null || true
  wait "$HOST_LEASE_HOLDER" 2>/dev/null || true
  HOST_LEASE_HOLDER=""
  if [ "$HOST_LEASE_STATUS" = "busy" ]; then
    echo "local-ci-gate: HOST BUSY - the SIMULATOR_TEST host resource is not available to this gate:" >&2
    sed 's/^/  /' "$HOST_LEASE_JSON" >&2 2>/dev/null || true
    sed 's/^/  /' "$HOST_LEASE_DIR/holder.err" >&2 2>/dev/null || true
    echo "local-ci-gate: refusal evidence retained at $HOST_LEASE_DIR" >&2
    exit 3
  fi
  # No verdict at all (helper died, crashed, or produced nothing parseable)
  # is a coordinator failure - a preflight condition, not a busy host.
  echo "local-ci-gate: the host coordinator failed to grant the lease (status: '${HOST_LEASE_STATUS:-none}'):" >&2
  sed 's/^/  /' "$HOST_LEASE_JSON" >&2 2>/dev/null || true
  sed 's/^/  /' "$HOST_LEASE_DIR/holder.err" >&2 2>/dev/null || true
  echo "local-ci-gate: refusal evidence retained at $HOST_LEASE_DIR" >&2
  exit 2
fi
HOST_LEASE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("lease_id",""))' "$HOST_LEASE_JSON" 2>/dev/null || true)"
# "acquired" is only evidence while the holder is alive to keep holding it:
# helper death releases the lease BY DESIGN, so a holder that exited right
# after granting means this gate would run uncoordinated while believing
# otherwise. Refuse instead.
if ! kill -0 "$HOST_LEASE_HOLDER" 2>/dev/null; then
  echo "local-ci-gate: the lease holder exited immediately after granting - refusing to run uncoordinated" >&2
  exec 3>&- || true
  wait "$HOST_LEASE_HOLDER" 2>/dev/null || true
  HOST_LEASE_HOLDER=""
  exit 2
fi
echo "== host lease: SIMULATOR_TEST held (lease ${HOST_LEASE_ID:-unknown}) =="
cp "$HOST_LEASE_JSON" "$RUN_DIR/host-lease.json" 2>/dev/null || true

# remove_worktree is defined BEFORE the worktree exists: an interrupt landing
# between `git worktree add` and the trap would otherwise hit an undefined
# function and leak the registered worktree.
remove_worktree() {
  if [ "$KEEP_WORKTREE" -eq 1 ]; then
    echo "keeping the throwaway worktree at $WT (--keep-worktree)"
    return 0
  fi
  # Idempotent: the normal path removes it at the end of the run and the EXIT
  # trap removes it again, and an already-removed worktree is not an error.
  if [ ! -d "$WT" ]; then
    return 0
  fi
  # Only ever the worktree this run created: the dirty state is the generated
  # .xcodeproj plus build output, which is exactly why --force is needed.
  if git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1; then
    echo "removed the throwaway worktree at $WT (all diagnostics live in $RUN_DIR)"
  else
    echo "local-ci-gate: could not remove the throwaway worktree at $WT" >&2
  fi
}

# --- worktree ----------------------------------------------------------------
# Detached: the gate never checks out a branch and never touches the invoking
# checkout's index, HEAD or stash.
if ! git -C "$REPO_ROOT" worktree add --detach "$WT" "$SHA"; then
  echo "local-ci-gate: could not create a detached worktree at $WT" >&2
  echo "local-ci-gate: a worktree left by a killed run is usually the cause; remove it with:" >&2
  echo "  git -C \"$REPO_ROOT\" worktree list    # find the stale entry" >&2
  echo "  git -C \"$REPO_ROOT\" worktree remove --force <stale-path>" >&2
  exit 2
fi
WT_SHA="$(git -C "$WT" rev-parse HEAD)"
if [ "$WT_SHA" != "$SHA" ]; then
  echo "local-ci-gate: worktree HEAD ($WT_SHA) is not the requested commit ($SHA)" >&2
  remove_worktree
  exit 2
fi
echo "worktree ready at $WT (detached at $SHA)"

# The target tree's own tooling is what runs the tests: the planner, the lane
# runner and the timing extractor must be the ones from the tested commit.
# extract-test-timings.py is load-bearing too - every count, every
# classification and every timing the gate reports comes out of it.
LANE_RUNNER="$WT/scripts/ci-test-lane.sh"
PLANNER="$WT/scripts/plan-tests.py"
for script in "$LANE_RUNNER" "$PLANNER" \
              "$WT/scripts/ci-build-for-testing.sh" \
              "$WT/scripts/extract-test-timings.py" \
              "$WT/scripts/ci-lib.sh"; do
  if [ ! -f "$script" ]; then
    echo "local-ci-gate: $SHA does not carry the tested tree's CI tooling ($script)" >&2
    remove_worktree
    exit 2
  fi
done

# --- helpers -----------------------------------------------------------------
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/ $//')"
# The gate tooling's own commit (assembler + orchestrator), recorded so
# release evidence says which tool produced it.
TOOLING_SHA="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

write_meta() { # $1 = finished_at, $2 = wall_s
  # The second device is recorded ONLY when this run actually used one: a
  # one-worker run that named a second device in its metadata would invite a
  # reader (or the summarizer) to look for evidence that was never meant to
  # exist.
  #
  # Those flags travel as an ARRAY, never as a command substitution: a device
  # name contains spaces ("Conduit CI Gate 2"), and an unquoted substitution
  # would split it into several arguments.
  local -a second_device=()
  if [ "$WORKERS" -eq 2 ]; then
    second_device=(--simulator2 "$SIMULATOR_NAME2"
                   --simulator2-runtime "${SIMULATOR2_RUNTIME:-}"
                   --simulator2-udid "${SIMULATOR2_UDID:-}")
  fi
  python3 "$HELPER" meta \
    --out "$RUN_DIR/meta.json" \
    --ref "$REF" --sha "$SHA" \
    --tooling-sha "$TOOLING_SHA" \
    --xcode "$XCODE_VERSION" \
    --simulator "$SIMULATOR_NAME" \
    --runtime "${SIMULATOR_RUNTIME:-}" \
    --simulator-udid "${SIMULATOR_UDID:-}" \
    ${second_device[@]+"${second_device[@]}"} \
    --mode "$MODE" \
    --workers "$WORKERS" \
    --unit-batch-max-classes "$UNIT_BATCH_MAX_CLASSES" \
    --prior-runs "${GATE_PRIOR_RUNS:-0}" \
    --started-at "$GATE_STARTED_AT" --finished-at "$1" --wall-s "$2" \
    --unit-classes "${GATE_UNIT_CLASS_COUNT:-0}" \
    --unit-batches "${GATE_UNIT_BATCH_COUNT:-0}" \
    --ui-classes "${GATE_UI_CLASS_COUNT:-0}" \
    --repeat-classes "$REPEAT_CLASSES" \
    --repeat-iterations "$REPEAT_ITERATIONS" \
    --lock-used "$USE_LOCK" \
    --simulator-prep "$SIM_PREP" \
    $([ "$ALLOW_RECOVERED_INFRA" -eq 1 ] && printf '%s' '--allow-recovered-infrastructure') \
    $([ "$SKIP_STATIC" -eq 1 ] && printf '%s' '--skip-static')
}

GATE_BUILD_STATUS="not_run"

# --- phase: generate ---------------------------------------------------------
echo ""
echo "== xcodegen generate =="
GEN_LOG="$RUN_DIR/generate.log"
if run_bounded 300 "$GEN_LOG" "$WT" xcodegen generate; then
  echo "xcodegen generate ok"
else
  echo "local-ci-gate: xcodegen generate failed or timed out; see $GEN_LOG" >&2
  tail -n 40 "$GEN_LOG" >&2 || true
  remove_worktree
  exit 2
fi

# --- the devices the run will actually use (recorded in the result) --------
# `simctl list` talks to CoreSimulatorService, which ci-lib.sh bounds
# everywhere else for exactly this reason; bound it here too.
DEVICES_JSON="$RUN_DIR/simctl-devices.json"
# stderr is silenced INSIDE the command so the JSON file stays parseable even
# when CoreSimulator emits warnings (run_bounded merges the streams).
run_bounded 60 "$DEVICES_JSON" "$RUN_DIR" \
  sh -c 'xcrun simctl list devices available -j 2>/dev/null' || \
  echo "local-ci-gate: could not list simulator devices within its budget; the recorded device may be incomplete" >&2
# Ambiguity refusal BEFORE any device is chosen: if a pinned NAME answers to
# more than one device, this gate cannot know which one it owns, and every
# downstream UDID-scoped operation (shutdown, erase, boot) would be a guess.
# Fail closed - including when uniqueness cannot be PROVEN (no jq, empty
# inventory): refusing to guess is the whole point. Every device this run
# touches is checked, so a duplicate UI-worker device fails the gate the same
# way a duplicate unit-worker device does.
if ! command -v jq >/dev/null 2>&1; then
  echo "local-ci-gate: jq not found - cannot prove simulator-name uniqueness; refusing to guess a device" >&2
  exit 2
fi
if [ ! -s "$DEVICES_JSON" ]; then
  echo "local-ci-gate: simulator inventory unavailable - cannot prove simulator-name uniqueness; refusing to guess a device" >&2
  exit 2
fi
# Refuse an ambiguous name for EVERY device this run will touch (a duplicate
# UI-worker device is as unusable as a duplicate unit-worker one). The names
# are checked one at a time on purpose: a device name contains spaces, so
# iterating a concatenated list would split it into words and check nothing.
check_device_name_unique() { # $1 = device name
  local name="$1" matches
  matches="$(jq -r --arg n "$name" \
    '[.devices[][]? | select(.name == $n) | .udid] | unique | .[]' "$DEVICES_JSON" 2>/dev/null | grep -v '^$' || true)"
  if [ "$(printf '%s\n' "$matches" | grep -c .)" -gt 1 ]; then
    echo "local-ci-gate: simulator name '$name' is ambiguous (matches UDIDs: $(printf '%s\n' "$matches" | tr '\n' ' '))" >&2
    echo "local-ci-gate: refusing to run against a device this gate cannot prove it owns; remove the duplicate device or pass --simulator/--second-simulator with a unique name" >&2
    return 1
  fi
  return 0
}
check_device_name_unique "$SIMULATOR_NAME" || exit 2
if [ "$WORKERS" -eq 2 ]; then
  check_device_name_unique "$SIMULATOR_NAME2" || exit 2
fi

read_device_json() { # $1 = device json path, $2 = key
  python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception:
    print("")
' "$1" "$2" 2>/dev/null || true
}

# The gate's own devices: resolve each (newest iOS runtime carrying the name),
# and create it when it does not exist yet, so erasing them - both in the
# preparation and in the bounded recovery round - is always safe for a
# developer's devices.
#
# $1 = device name, $2 = json output path, $3 = create log path.
# Prints the resolved/created UDID on stdout (empty on failure).
ensure_gate_simulator() {
  local name="$1" out_json="$2" create_log="$3"
  local udid runtime created=""
  python3 "$HELPER" simulator --devices "$DEVICES_JSON" \
    --name "$name" --out "$out_json" >/dev/null 2>&1 || true
  udid="$(read_device_json "$out_json" udid)"
  if [ -n "$udid" ]; then
    printf '%s\n' "$udid"
    return 0
  fi
  echo "gate simulator '$name' does not exist yet - creating it" >&2
  # Created from the newest available iPhone device type on the newest runtime,
  # so the gate's devices target the same iOS versions the tests do.
  # run_bounded captures the command's output into a log file, so the new
  # device's UDID is read back from there. `simctl create` also prints a
  # "No runtime specified..." notice before the UDID, so the UDID is matched
  # as a UUID token rather than taken as the whole output.
  run_bounded 180 "$create_log" "$RUN_DIR" \
    sh -c 'xcrun simctl create "$1" "iPhone 17 Pro" 2>&1' _ "$name" || true
  if [ -s "$create_log" ]; then
    created="$(grep -o -E '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
      "$create_log" | head -n 1)"
  fi
  # A UDID is a 36-character hyphenated form; anything else (an error message,
  # empty output) is a failure to create.
  case "$created" in
    ????????-????-????-????-????????????)
      # Re-list so the recorded device/runtime reflects the new device (and so
      # a second run resolves it instead of creating a twin).
      run_bounded 60 "$DEVICES_JSON" "$RUN_DIR" \
        sh -c 'xcrun simctl list devices available -j 2>/dev/null' || true
      python3 "$HELPER" simulator --devices "$DEVICES_JSON" \
        --name "$name" --udid "$created" --out "$out_json" >/dev/null 2>&1 || true
      echo "gate simulator '$name' created: $created" >&2
      printf '%s\n' "$created"
      return 0
      ;;
    *) ;;
  esac
  echo "local-ci-gate: could not create the gate simulator '$name'; see $create_log" >&2
  cat "$create_log" >&2 || true
  return 1
}

SIMULATOR_UDID="$(ensure_gate_simulator "$SIMULATOR_NAME" \
  "$RUN_DIR/simulator.json" "$RUN_DIR/simctl-create.log")" || {
  remove_worktree
  exit 2
}
if [ -z "$SIMULATOR_UDID" ]; then
  remove_worktree
  exit 2
fi
SIMULATOR_RUNTIME="$(read_device_json "$RUN_DIR/simulator.json" runtime)"

# The second worker's device (only when this run uses two workers): resolved
# and created the same way, recorded separately, and never touched by the
# other worker. Its absence is fatal: a run that silently fell back to one
# device would run both suites on one simulator - concurrent chains on one
# device is precisely the state corruption the workers exist to avoid.
SIMULATOR2_UDID=""
SIMULATOR2_RUNTIME=""
if [ "$WORKERS" -eq 2 ]; then
  SIMULATOR2_UDID="$(ensure_gate_simulator "$SIMULATOR_NAME2" \
    "$RUN_DIR/simulator-2.json" "$RUN_DIR/simctl-create-2.log")" || {
    remove_worktree
    exit 2
  }
  if [ -z "$SIMULATOR2_UDID" ]; then
    remove_worktree
    exit 2
  fi
  if [ "$SIMULATOR2_UDID" = "$SIMULATOR_UDID" ]; then
    echo "local-ci-gate: the two worker devices resolved to the same UDID ($SIMULATOR_UDID); refusing to run two workers on one device" >&2
    remove_worktree
    exit 2
  fi
  SIMULATOR2_RUNTIME="$(read_device_json "$RUN_DIR/simulator-2.json" runtime)"
  echo "ui worker device: '$SIMULATOR_NAME2' -> $SIMULATOR2_UDID"
fi

# --- phase: static checks ----------------------------------------------------
# Three independent checks, each its own process writing its own log: they run
# CONCURRENTLY (they are cheap in CPU - the bash suites spend their time
# waiting on their own watchdogs - but together they were ~9 minutes run
# serially) and, unless --static-serial is given, the whole phase runs in the
# BACKGROUND while the build and the test lanes proceed.
#
# Overlapping is safe by construction: the checks read the tested worktree and
# write nothing into it that any lane reads, and the run directory keeps their
# logs and the phase document either way. It starts AFTER the build phase has
# moved `ci-lane/build` out of the worktree, because the CI-tooling suite's own
# fixture runs a smoke step with the worktree as its cwd and would otherwise
# race the build's log directory.
#
# "${arr[@]}" on an EMPTY array is a fatal unbound-variable error under Bash
# 3.2 + set -u (macOS /bin/bash), so every expansion below uses the
# `${arr[@]+"${arr[@]}"}` form instead.
run_static_check() { # $1=name, rest=command
  local name="$1"; shift
  local log="$RUN_DIR/static/$name.log"
  mkdir -p "$RUN_DIR/static"
  local start elapsed status
  start=$(date +%s)
  if ( cd "$WT" && "$@" ) >"$log" 2>&1 3>&-; then
    status="pass"
  else
    status="fail"
    echo "  $name: FAIL (see $log)"
    tail -n 30 "$log" || true
  fi
  elapsed=$(( $(date +%s) - start ))
  [ "$status" = "pass" ] && echo "  $name: pass (${elapsed}s)"
  # One line per check, so the phase document is assembled from files: the
  # checks run as background processes whose variables the parent never sees.
  printf '%s\t%s\t%s\n' "$name" "$status" "$elapsed" \
    > "$RUN_DIR/static/$name.check"
  return 0
}

run_static_phase() {
  if [ "$SKIP_STATIC" -eq 1 ]; then
    echo "== static checks SKIPPED (--skip-static) =="
    python3 "$HELPER" phase --out "$RUN_DIR/static/phase.json" \
      --phase static --status skipped --duration 0 --exit-code 0 \
      --note "static checks disabled with --skip-static (partial run)"
    return 0
  fi
  echo "== static checks (planner inventory, CI tooling, localization) =="
  local started ok=1 checks=() f name status elapsed
  local check_pids="" check_pid
  started=$(date +%s)
  mkdir -p "$RUN_DIR/static"
  rm -f "$RUN_DIR"/static/*.check 2>/dev/null || true
  # Each check's pid is collected and joined EXPLICITLY, never with a bare
  # `wait`: a bare wait joins every child of this shell, which in the
  # foreground (--static-serial) path includes the long-lived ios-ci-host lease
  # holder - a process that cannot exit until this run does. That is an
  # indefinite hang, and it is invisible to any test that only greps the flag.
  run_static_check plan-validate python3 scripts/plan-tests.py validate --repo-root . &
  check_pids="$check_pids $!"
  run_static_check ci-tooling-regression python3 -m unittest discover -s scripts/tests -p 'test_*.py' &
  check_pids="$check_pids $!"
  run_static_check localization-coverage python3 scripts/check-l10n-coverage.py --repo-root . &
  check_pids="$check_pids $!"
  for check_pid in $check_pids; do
    wait "$check_pid" 2>/dev/null || true
  done
  # plan-validate first, then the rest alphabetically: the document keeps the
  # order an operator reads the checks in, not the glob's. A check that wrote
  # NO record (killed, crashed before its file landed) is a FAILURE, never a
  # silent omission: a phase that quietly certified two of its three checks
  # would be exactly the kind of gap this gate exists to refuse.
  for name in plan-validate ci-tooling-regression localization-coverage; do
    f="$RUN_DIR/static/$name.check"
    if [ ! -s "$f" ]; then
      checks+=(--check "$name:missing:0")
      ok=0
      continue
    fi
    IFS=$'\t' read -r name status elapsed < "$f"
    checks+=(--check "$name:$status:$elapsed")
    [ "$status" = "pass" ] || ok=0
  done
  python3 "$HELPER" phase --out "$RUN_DIR/static/phase.json" \
    --phase static --status "$([ "$ok" -eq 1 ] && echo pass || echo fail)" \
    --duration "$(( $(date +%s) - started ))" \
    --exit-code "$([ "$ok" -eq 1 ] && echo 0 || echo 1)" \
    --note "planner inventory + CI-tooling regression suites + localization coverage" \
    --detail "overlapped_with_lanes=$([ "$STATIC_OVERLAP" -eq 1 ] && echo true || echo false)" \
    "${checks[@]+"${checks[@]}"}"
  return 0
}

STATIC_PID=""
if [ "$STATIC_OVERLAP" -eq 1 ]; then
  echo ""
  echo "== static checks will run concurrently with the build and the test lanes =="
else
  # Historical order (and the same evidence): the checks finish before the
  # build starts.
  run_static_phase
fi

# --- phase: build-for-testing (exactly once) ---------------------------------
echo ""
echo "== build-for-testing (once) =="
BUILD_START=$(date +%s)
BUILD_OK=1
( cd "$WT" && DERIVED_DATA_PATH="$RUN_DIR/derived-data" \
    SIMULATOR_NAME="$SIMULATOR_NAME" \
    bash scripts/ci-build-for-testing.sh ) 3>&- || BUILD_OK=0
BUILD_ELAPSED=$(( $(date +%s) - BUILD_START ))
mkdir -p "$RUN_DIR/build"
# The build script writes ci-lane/build inside the (throwaway) worktree;
# move the diagnostics out so they survive the worktree's removal. A failed
# move must be reported: the build phase document points at these paths, and
# a silent loss would leave the gate citing logs that no longer exist.
if [ -d "$WT/ci-lane/build" ]; then
  for artifact in "$WT/ci-lane/build"/*; do
    [ -e "$artifact" ] || continue
    if ! mv "$artifact" "$RUN_DIR/build/"; then
      echo "local-ci-gate: could not move $(basename "$artifact") out of the worktree; copying instead" >&2
      cp -R "$artifact" "$RUN_DIR/build/" 2>/dev/null || \
        echo "local-ci-gate: could not preserve $(basename "$artifact")" >&2
    fi
  done
fi
if [ ! -s "$RUN_DIR/build/build.log" ]; then
  echo "local-ci-gate: the build log was not preserved in $RUN_DIR/build" >&2
fi
XCTESTRUN="$(ls -t "$RUN_DIR/derived-data"/Build/Products/*.xctestrun 2>/dev/null | head -n 1 || true)"
if [ "$BUILD_OK" -eq 1 ] && [ -n "$XCTESTRUN" ]; then
  GATE_BUILD_STATUS="pass"
  echo "build-for-testing ok in ${BUILD_ELAPSED}s"
  echo "xctestrun: $XCTESTRUN"
else
  GATE_BUILD_STATUS="fail"
  echo "local-ci-gate: build-for-testing FAILED (exit non-zero or no .xctestrun produced)"
  echo "full log: $RUN_DIR/build/build.log"
  tail -n 60 "$RUN_DIR/build/build.log" 2>/dev/null || true
  XCTESTRUN=""
fi
python3 "$HELPER" phase --out "$RUN_DIR/build/phase.json" \
  --phase build --status "$GATE_BUILD_STATUS" \
  --duration "$BUILD_ELAPSED" --exit-code "$([ "$GATE_BUILD_STATUS" = pass ] && echo 0 || echo 1)" \
  --note "$([ -n "$XCTESTRUN" ] && echo "build-for-testing products" || echo "no .xctestrun produced")" \
  --detail "xctestrun=$XCTESTRUN"

# --- static checks, overlapped ------------------------------------------------
# Started here (not before the build) so the CI-tooling suite cannot race the
# build's own `ci-lane/build` diagnostics, and left running while the plan and
# the lanes proceed. The gate WAITS for it below and fails on its verdict, so
# overlapping changes when the checks run, never whether they count.
if [ "$STATIC_OVERLAP" -eq 1 ]; then
  STATIC_STARTED=$(date +%s)
  # The log directory must exist before the subshell's redirection: a redirect
  # into a missing directory fails the launch, and the phase would then simply
  # be absent from the run ("static phase: missing", which the summarizer
  # reports as a gate defect).
  mkdir -p "$RUN_DIR/static"
  # `set -m` like the workers: the phase and the check processes it spawns form
  # their own process group, so teardown can take the whole group down instead
  # of leaving a check running against a worktree that is being removed.
  set -m
  ( run_static_phase ) >"$RUN_DIR/static/static.log" 2>&1 3>&- &
  STATIC_PID=$!
  set +m
fi

# --- phase: plan -------------------------------------------------------------
# One lane per kind: the gate is exhaustive, not sharded, so it forces the
# planner to emit the whole suite as a single unit lane (with its
# planner-owned sequential batches and per-batch watchdogs) and a single UI
# lane. --unit-max-batches-per-job is relaxed because that knob bounds HOSTED
# jobs; locally every batch runs in one process with no job ceiling, and the
# planner's per-batch watchdogs remain the enforcement.
LANES_ENV="$RUN_DIR/lanes.env"

run_lane() { # $1=kind $2=lane $3=target $4=classes $5=predicted $6=timeout
              # $7=result-dir, then extra flags after
  local kind="$1" lane="$2" target="$3" classes="$4" predicted="$5" timeout="$6"
  local result_dir="$7"; shift 7
  echo ""
  echo "== $kind lane $lane =="
  echo "classes: $(printf '%s' "$classes" | tr ',' '\n' | wc -l | tr -d ' ') | watchdog: ${timeout}s"
  # SIMULATOR_NAME is passed here (it is deliberately not exported) so the lane can never
  # silently fall back to ci-lib.sh's default device when --simulator differs:
  # the recorded simulator/runtime must describe the device the tests ran on.
  CONDUIT_PERF_TRACE="${CONDUIT_PERF_TRACE:-1}" \
    SIMULATOR_NAME="$SIMULATOR_NAME" \
    SIMULATOR_UDID="${SIMULATOR_UDID:-}" \
    bash "$LANE_RUNNER" --kind "$kind" --lane "$lane" --target "$target" \
      --classes "$classes" --predicted "$predicted" --timeout "$timeout" \
      --iterations 1 --xctestrun "$XCTESTRUN" --result-dir "$result_dir" "$@" 3>&-
}

simulator_prime() { # $1 = label for the log files
  local udid="${SIMULATOR_UDID:-}" i label
  [ -z "$udid" ] && return 0
  label="${1:-x}"
  # Bounded like every other simctl touchpoint: a wedged CoreSimulatorService
  # hangs simctl indefinitely, and this runs before every retry and repeat.
  i=1
  while [ "$i" -le 2 ]; do
    run_bounded 60 "$RUN_DIR/sim-prime-$label-$i.launch.log" "$RUN_DIR"       xcrun simctl launch "$udid" com.milim.relay || true
    sleep $(( 2 * GATE_SLEEP_SCALE ))
    run_bounded 60 "$RUN_DIR/sim-prime-$label-$i.term.log" "$RUN_DIR"       xcrun simctl terminate "$udid" com.milim.relay || true
    sleep $(( 2 * GATE_SLEEP_SCALE ))
    i=$(( i + 1 ))
  done
}


# Bounded Simulator preparation before a lane starts: shut the devices down,
# erase the destination, boot it, and WAIT for a complete boot, using
# ci-lib.sh's own recovery primitive rather than a new one.
#
# This is environment preparation, never a retry: nothing that ran is
# re-executed, and a lane that then fails still fails. It exists because the
# gate's runs on main kept losing batches to
#
#   Simulator device failed to launch com.milim.relay ...
#   Application failed preflight checks ... reason: Busy
#
# What the evidence shows (four full runs plus an A/B probe on this machine):
# with a shutdown+boot only, the next single-class lane was refused; after
# `simctl erase` + boot it passed. So the refusal is leftover device state
# rather than a startup race, and the erase is therefore the default. It is a
# PARTIAL mitigation, not a cure: on a full run the refusal still returned a
# batch or two into a lane, i.e. it accumulates over successive
# installs/launches of the same bundle on one device. The gate's answer to a
# refusal is its classification (infrastructure, never an assertion) plus the
# continuation pass - the run refuses to certify rather than reporting a
# product failure. See docs/CI.md for the follow-up that would clear it
# in-band. --no-simulator-erase keeps the cheaper shutdown+boot for observing
# the raw behavior.
simulator_prep() { # $1 = label
  if [ "$SIM_PREP" -eq 0 ]; then
    echo "simulator preparation skipped (--no-simulator-prep)"
    return 0
  fi
  local label="$1"
  local log="$RUN_DIR/sim-prep-$label.log"
  mkdir -p "$RUN_DIR/sim-prep"
  echo "== simulator preparation before $label =="
  local started status=0
  started=$(date +%s)
  ( cd "$WT" && LOG_DIR="$RUN_DIR/sim-prep" SIMULATOR_NAME="$SIMULATOR_NAME" \
      SIMULATOR_UDID="${SIMULATOR_UDID:-}" \
      bash -c '. "$1/scripts/ci-lib.sh"; reset_and_boot_simulator "$2" || exit 1
              # Bounded like every other simctl call: a wedged
              # CoreSimulatorService hangs simctl indefinitely, and this runs
              # at every lane boundary. ci-lib.sh is already sourced, so
              # bounded_run is available here.
              udid=$(simulator_udid) && bounded_run 60 xcrun simctl terminate "$udid" com.milim.relay
              sleep $(( 2 * ${GATE_SLEEP_SCALE:-1} ))' _ "$WT" "$SIM_ERASE" ) \
      >"$log" 2>&1 3>&- || status=$?
  local elapsed=$(( $(date +%s) - started ))
  if [ "$status" -eq 0 ]; then
    echo "simulator ready for $label (${elapsed}s)"
  else
    echo "local-ci-gate: simulator preparation for $label did not complete (status $status); continuing (see $log)"
  fi
  # Recorded even when it succeeded: a wedged environment is a caveat on the
  # result, and the summarizer only knows what the run directory says.
  #
  # The record goes to the WORKER's own file, and the phase document is
  # assembled by the parent from all of them: two workers prepare their own
  # devices concurrently, so no worker can append to the parent's state. The
  # parent DERIVES the phase's failure flag from these records (see the
  # simulation-prep aggregation), so a failure here is never a variable the
  # worker wrote into its own subshell.
  #
  # Outside a worker there is no file the aggregator reads, so a preparation
  # that ran there must FAIL LOUDLY rather than write a record nobody looks at.
  if [ -z "${WORKER_SIM_PREP_FILE:-}" ]; then
    echo "local-ci-gate: simulator_prep ran outside a worker (no WORKER_SIM_PREP_FILE); refusing to record a preparation the phase document would never read" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$label" "$status" "$elapsed" >> "$WORKER_SIM_PREP_FILE"
  return 0
}

if [ "$GATE_BUILD_STATUS" != "pass" ]; then
  echo ""
  echo "== test lanes SKIPPED: the build did not produce test products =="
else
  # --- phase: plan -------------------------------------------------------
  # The planner is the single owner of the batch layout and every watchdog
  # budget, so it must succeed before any lane starts.
  PLAN_OK=1
  mkdir -p "$RUN_DIR/plan"
  if ! python3 "$PLANNER" plan --repo-root "$WT" \
      --baseline scripts/test-timings.json \
      --min-lanes 1 --max-lanes 1 --unit-max-batches-per-job 1000 \
      --ui-min-lanes 1 --ui-max-lanes 1 \
      $([ "$UNIT_BATCH_MAX_CLASSES" -gt 0 ] && \
        printf '%s %s' '--unit-batch-max-classes' "$UNIT_BATCH_MAX_CLASSES") \
      --out "$RUN_DIR/plan/plan.json" \
      --summary-out "$RUN_DIR/plan/plan-summary.md" \
      >"$RUN_DIR/plan/plan.log" 2>&1; then
    PLAN_OK=0
  fi
  if [ "$PLAN_OK" -ne 1 ] || [ ! -s "$RUN_DIR/plan/plan.json" ]; then
    echo "local-ci-gate: planning failed; see $RUN_DIR/plan/plan.log" >&2
    tail -n 40 "$RUN_DIR/plan/plan.log" >&2 || true
  else
    echo "plan: $RUN_DIR/plan/plan.json"
    if ! python3 "$HELPER" lanes --plan "$RUN_DIR/plan/plan.json" \
        --out "$LANES_ENV" --json-out "$RUN_DIR/lanes.json"; then
      echo "local-ci-gate: lane projection failed" >&2
    else
      # shellcheck disable=SC1090
      . "$LANES_ENV"

      # --- workers -------------------------------------------------------
      # A WORKER is one process that owns one device (its UDID is pinned in
      # its environment) and the plan work assigned to it:
      #
      #   unit worker  the complete unit lane, its continuation pass, its
      #                bounded recovery round, and the repeat policy
      #   ui worker    the complete UI lane and its bounded recovery round
      #
      # With --workers 2 both run CONCURRENTLY on two different project-owned
      # devices under the ONE host-level SIMULATOR_TEST lease this run holds
      # (a lease is exclusive against other projects and workflows, not against
      # this run's own second device); with --workers 1 they run one after the
      # other on the unit device. Either way each worker owns exactly one UDID
      # and never touches the other's device, so the two xcodebuild chains can
      # never corrupt each other's Simulator state.
      #
      # Which side runs in parallel is deliberate: the UI suite is the longest
      # single pole (~11 min on our Mac against ~4-8 for the unit suite), so
      # pairing unit work against it - rather than sharding one suite across
      # both devices - is what actually shortens the run. Repeats stay with the
      # unit worker because they run on the unit device's already-prepared
      # state and must not interleave with the unit lane on that device.
      WORKERS_DIR="$RUN_DIR/workers"
      mkdir -p "$WORKERS_DIR"
      WORKER_PIDS=""
      LANE_POLL_SECONDS="${GATE_LANE_POLL_INTERVAL_S:-3}"

      worker_meta() { # $1=name $2=device name $3=device udid $4=pid $5=started epoch
        local wdir="$WORKERS_DIR/$1"
        mkdir -p "$wdir"
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" > "$wdir/meta.tsv"
      }

      start_worker() { # $1=name $2=device name $3=device udid $4=worker function
        local name="$1" devname="$2" devudid="$3" fn="$4"
        local started pid wdir="$WORKERS_DIR/$1"
        started=$(date +%s)
        # The directory (and the sim-prep record file) must exist BEFORE the
        # subshell's redirection and before the worker can append to it: a
        # redirect into a missing directory fails the launch outright, and a
        # truncation that happens after the worker started can discard its
        # first record.
        mkdir -p "$wdir"
        : > "$wdir/sim-prep.tsv"
        # A subshell per worker: a subshell cannot write the parent's
        # variables, so every per-worker record travels as a FILE (the
        # sim-prep records, the exit code, the finish stamp) and the parent
        # assembles the documents from them. fd 3 is closed in the worker on
        # purpose: it is the host lease's write end, which must die with THIS
        # process.
        #
        # `set -m` puts the worker in its OWN process group (the same idiom
        # run_bounded and ci-lib.sh use) so teardown can signal the worker AND
        # the xcodebuild/lane chain below it: bash does not forward a signal to
        # its foreground child, so killing the worker's pid alone would orphan
        # a live test chain on a device whose lease this run has just released.
        # It does not put the worker in the CALLER's group - the child becomes
        # its own leader.
        set -m
        (
          WORKER_NAME="$name"
          WORKER_DIR="$wdir"
          WORKER_SIM_PREP_FILE="$wdir/sim-prep.tsv"
          SIMULATOR_NAME="$devname"
          SIMULATOR_UDID="$devudid"
          export SIMULATOR_NAME SIMULATOR_UDID
          export XCODEBUILD_POLL_INTERVAL_S="$LANE_POLL_SECONDS"
          "$fn"
          _worker_status=$?
          date +%s > "$wdir/finished"
          printf '%s\n' "$_worker_status" > "$wdir/exit-code"
          exit "$_worker_status"
        ) >"$wdir/worker.log" 2>&1 3>&- &
        pid=$!
        set +m
        WORKER_PIDS="$WORKER_PIDS $pid"
        worker_meta "$name" "$devname" "$devudid" "$pid" "$started"
        echo "worker $name: started on '$devname' ($devudid); log $wdir/worker.log"
      }

      # Heart-beat + reap loop: an operator on a long SSH session gets
      # progress from BOTH workers, and each worker's exit status is collected
      # where it can be recorded (the pid list is cleared as it is reaped so no
      # later signal can reach a reused pid).
      wait_for_workers() {
        local remaining="$WORKER_PIDS" alive pid name devname devudid wpid started now
        local last_heartbeat=0
        # Liveness is polled every second but the HEARTBEAT prints every 15:
        # the poll interval is the gate's own exit latency (a worker that
        # finished must not cost the run the rest of a sleep), while the
        # heartbeat only has to be frequent enough to show progress on an SSH
        # session. `sleep 15` here would add up to 15s to EVERY run.
        while [ -n "$remaining" ]; do
          alive=""
          for pid in $remaining; do
            if kill -0 "$pid" 2>/dev/null; then
              alive="$alive $pid"
            else
              wait "$pid" 2>/dev/null || true
            fi
          done
          remaining="$alive"
          [ -z "$remaining" ] && break
          now=$(date +%s)
          if [ $(( now - last_heartbeat )) -ge 15 ]; then
            last_heartbeat=$now
            while IFS=$'\t' read -r name devname devudid wpid started; do
              [ -z "$name" ] && continue
              kill -0 "$wpid" 2>/dev/null || continue
              echo "... worker $name running ($(( now - started ))s, device '$devname')"
            done < <(cat "$WORKERS_DIR"/*/meta.tsv 2>/dev/null)
          fi
          sleep 1
        done
        # Every worker is reaped here, so the pid list is cleared: a later
        # signal (the cleanup path) must never reach a pid that has since been
        # reused by an unrelated process on this shared host.
        WORKER_PIDS=""
      }

      # Reads back what the workers recorded, as one authoritative document:
      # name, device, UDID, exit code, wall clock, whether the worker script
      # ran to completion, and whether any of its Simulator preparations
      # failed. The summarizer fails the gate when a worker is missing from
      # this file, did not complete, or reports a device the run did not
      # assign it.
      record_workers() {
        local tsv="$RUN_DIR/workers.tsv" name devname devudid wpid started wdir
        : > "$tsv"
        for wdir in "$WORKERS_DIR"/*; do
          [ -d "$wdir" ] || continue
          [ -s "$wdir/meta.tsv" ] || continue
          IFS=$'\t' read -r name devname devudid wpid started < "$wdir/meta.tsv" || continue
          local exit_code="" wall_s=0 completed=0 sim_prep_failed=0 plabel pstatus psecs finished
          if [ -s "$wdir/exit-code" ]; then
            exit_code="$(tr -d '[:space:]' < "$wdir/exit-code")"
            [ "$exit_code" = "0" ] && completed=1
          fi
          # The worker's OWN finish stamp, not "now": in the serial fallback the
          # ui worker is launched after the unit worker was reaped, but its
          # start stamp would otherwise be taken at launch time in some paths,
          # and a wall clock measured at record time would credit it with the
          # whole serial run. Without a stamp (a worker that never returned) the
          # measurement is the launch-to-now span and `completed` is 0.
          finished="$(tr -d '[:space:]' < "$wdir/finished" 2>/dev/null || true)"
          case "$finished" in
            ''|*[!0-9]*) wall_s=$(( $(date +%s) - started )) ;;
            *) wall_s=$(( finished - started )) ;;
          esac
          if [ -s "$wdir/sim-prep.tsv" ]; then
            while IFS=$'\t' read -r plabel pstatus psecs; do
              [ -z "$plabel" ] && continue
              [ "$pstatus" = "0" ] || sim_prep_failed=1
            done < "$wdir/sim-prep.tsv"
          fi
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$devname" "$devudid" "${exit_code:-none}" "$wall_s" \
            "$completed" "$sim_prep_failed" "workers/$name/worker.log" >> "$tsv"
        done
      }

      # --- worker: unit ----------------------------------------------------
      worker_unit() {
        # --- complete unit suite -------------------------------------------
        simulator_prep unit
        if run_lane unit "$GATE_UNIT_LANE" "$GATE_UNIT_TARGET" "$GATE_UNIT_CLASSES" \
            "$GATE_UNIT_PREDICTED" "$GATE_UNIT_TIMEOUT" "$RUN_DIR/lanes/unit" \
            --batches-json "$GATE_UNIT_BATCHES_JSON"; then
          echo "unit lane: the complete ConduitTests suite ran"
        else
          # The lane stopped at the batch that failed, so the rest of the suite
          # has no result yet. Run the batches it never reached as a
          # CONTINUATION pass (a diagnostic continuation, never a retry of
          # anything that already ran) so one failure cannot hide the other
          # classes' status from the report.
          CONT_ENV="$RUN_DIR/unit-continuation.env"
          if python3 "$HELPER" not-run-batches \
              --plan "$RUN_DIR/plan/plan.json" \
              --lane-result "$RUN_DIR/lanes/unit/lane-result.json" \
              --out "$CONT_ENV"; then
            # shellcheck disable=SC1090
            . "$CONT_ENV"
            if [ "${GATE_CONT_PRESENT:-0}" -eq 1 ]; then
              echo ""
              echo "== unit continuation: re-running the ${GATE_CONT_BATCH_COUNT} batch(es) the lane never reached (batches ${GATE_CONT_BATCH_INDICES}) =="
              # The lane it continues stopped mid-invocation, so the Simulator is
              # prepared again before the continuation starts.
              simulator_prep unit-continuation
              if run_lane unit "$GATE_UNIT_LANE-continuation" "$GATE_UNIT_TARGET" \
                  "$GATE_CONT_CLASSES" "$GATE_CONT_PREDICTED" "$GATE_CONT_TIMEOUT" \
                  "$RUN_DIR/lanes/unit-continuation" \
                  --batches-json "$GATE_CONT_BATCHES_JSON"; then
                echo "unit continuation: the never-reached batches ran clean"
              else
                echo "unit continuation: the never-reached batches produced their own failures (reported below)"
              fi
            else
              echo "unit continuation: no batch was left unexecuted"
            fi
          else
            echo "local-ci-gate: could not project the unit continuation pass" >&2
          fi
        fi

        # --- ONE bounded recovery round ------------------------------------
        # Allowed for exactly one infrastructure class: the simulator/host-app
        # launch refusal (XCTest's synthetic "System Failures" entry, and/or the
        # verified Busy signature in the lane log). A genuine assertion anywhere
        # disqualifies the round - the helper refuses to project it, because a
        # product failure is never retried around.
        echo ""
        echo "== bounded recovery round check =="
        if python3 "$HELPER" recovery-spec --plan "$RUN_DIR/plan/plan.json" \
            --lane "$RUN_DIR/lanes/unit,$RUN_DIR/lanes/unit-continuation" \
            --timeout-cap "$REPEAT_TIMEOUT_CAP" \
            --out "$RUN_DIR/recovery.env" --tsv-out "$RUN_DIR/recovery.tsv"; then
          # shellcheck disable=SC1090
          . "$RUN_DIR/recovery.env"
          if [ "${GATE_RECOVERY_PRESENT:-0}" -eq 1 ] && [ -s "$RUN_DIR/recovery.tsv" ]; then
            echo "== recovery round 1 of 1: erasing the gate simulator and retrying ${GATE_RECOVERY_CLASS_COUNT} class(es) once =="
            # ONE erase, then ONE invocation for the whole retry set in a single
            # batch: the wedge alternates across app launches, so one launch
            # gives the round its single chance (see cmd_recovery_spec, which
            # emits exactly one row). A refusal of that launch fails the gate as
            # infrastructure with no third attempt.
            while IFS=$'\t' read -r rcls rclasses rbatches rpredicted rtimeout; do
              [ -z "$rcls" ] && continue
              rtimeout="${rtimeout%$'\r'}"
              rpredicted="${rpredicted%$'\r'}"
              rbatches="${rbatches%$'\r'}"
              # A freshly erased device for the retry set: the wedge is STICKY
              # across launches (only an erase clears it - see the A/B probe in
              # simulator_prep), and the set is still retried exactly once.
              simulator_prep "recovery-$rcls"
              simulator_prime "recovery-$rcls"
              if run_lane unit "$GATE_UNIT_LANE-recovery-$rcls" "$GATE_UNIT_TARGET" \
                  "$rclasses" "$rpredicted" "$rtimeout" \
                  "$RUN_DIR/lanes/unit-recovery-$rcls" \
                  --batches-json "$rbatches"; then
                echo "  recovery $rcls: recovered"
              else
                echo "  recovery $rcls: still failing (reported in the result document)"
              fi
            done < "$RUN_DIR/recovery.tsv"
            # No third attempt: whether the round worked - and whether the same
            # infrastructure class came back - is decided by the summarizer from
            # these passes' evidence.
          else
            echo "== recovery round: nothing to retry (no launch-refusal evidence, or nothing incomplete) =="
          fi
        else
          echo "local-ci-gate: the bounded recovery round refused to project"
          echo "local-ci-gate: correct when a genuine test failure is present - assertions are never retried"
        fi

        # --- explicit repeat policy ----------------------------------------
        if [ -z "$REPEAT_CLASSES" ] || [ "$REPEAT_ITERATIONS" -le 0 ]; then
          echo ""
          echo "== repeat policy disabled ($MODE mode) =="
        else
          REPEAT_JSON="$RUN_DIR/repeats.json"
          REPEAT_TSV="$RUN_DIR/repeats.tsv"
          if ! python3 "$HELPER" repeat-spec --plan "$RUN_DIR/plan/plan.json" \
              --classes "$REPEAT_CLASSES" --iterations "$REPEAT_ITERATIONS" \
              --timeout-cap "$REPEAT_TIMEOUT_CAP" \
              --out "$REPEAT_JSON" --tsv-out "$REPEAT_TSV"; then
            echo "local-ci-gate: repeat policy could not be projected" >&2
          else
            echo ""
            echo "== repeat policy: $REPEAT_ITERATIONS unconditional iterations per class =="
            # A projection that produced no tasks would silently satisfy the
            # summarizer with "no repeats expected"; the policy must actually
            # have tasks in it.
            if [ ! -s "$REPEAT_TSV" ]; then
              echo "local-ci-gate: the repeat policy projected no tasks" >&2
            fi
            while IFS=$'\t' read -r rcls rbatches rpredicted rtimeout; do
              [ -z "$rcls" ] && continue
              rtimeout="${rtimeout%$'\r'}"
              rpredicted="${rpredicted%$'\r'}"
              rbatches="${rbatches%$'\r'}"
              iteration=1
              while [ "$iteration" -le "$REPEAT_ITERATIONS" ]; do
                # Primed like the recovery round's retry: the wedge alternates
                # across app launches, and the prime keeps a repetition from
                # being lost to the launcher rather than to the test.
                simulator_prime "$rcls-$iteration"
                if run_lane unit "repeat-$rcls-$iteration" "$GATE_UNIT_TARGET" \
                    "$rcls" "$rpredicted" "$rtimeout" \
                    "$RUN_DIR/repeats/$rcls/iter-$iteration" \
                    --batches-json "$rbatches"; then
                  echo "  $rcls iteration $iteration: pass"
                else
                  echo "  $rcls iteration $iteration: FAIL"
                  # One bounded retry for a repetition the launcher ate:
                  # only when the evidence is infrastructure. A genuine
                  # failing test is final and is never re-run.
                  if python3 "$HELPER" is-infra-only \
                      --lane-dir "$RUN_DIR/repeats/$rcls/iter-$iteration"; then
                    simulator_prime "$rcls-$iteration-retry"
                    if run_lane unit "repeat-$rcls-$iteration-retry" \
                        "$GATE_UNIT_TARGET" "$rcls" "$rpredicted" "$rtimeout" \
                        "$RUN_DIR/repeats/$rcls/iter-$iteration-retry" \
                        --batches-json "$rbatches"; then
                      echo "  $rcls iteration $iteration: recovered on its one retry"
                    else
                      echo "  $rcls iteration $iteration: its one retry also failed"
                    fi
                  fi
                fi
                iteration=$(( iteration + 1 ))
              done
            done < "$REPEAT_TSV"
          fi
        fi
        return 0
      }

      # --- worker: ui -------------------------------------------------------
      worker_ui() {
        if [ "${GATE_UI_PRESENT:-0}" -ne 1 ]; then
          echo "ui lane: the plan carries no UI classes - nothing for this worker to do"
          return 0
        fi
        simulator_prep ui
        if run_lane ui "$GATE_UI_LANE" "$GATE_UI_TARGET" "$GATE_UI_CLASSES" \
            "$GATE_UI_PREDICTED" "$GATE_UI_TIMEOUT" "$RUN_DIR/lanes/ui" \
            --class-timeouts "$GATE_UI_CLASS_TIMEOUTS"; then
          echo "ui lane: the complete ConduitUITests suite ran"
        else
          echo "ui lane: the shard reported failures (classified in the result)"
        fi
        # The same bounded recovery round, for the UI lane: one erase of the
        # worker's device and one retry of the UI classes that never completed.
        if python3 "$HELPER" recovery-spec --plan "$RUN_DIR/plan/plan.json" \
            --kind ui \
            --lane "$RUN_DIR/lanes/ui" \
            --timeout-cap "$REPEAT_TIMEOUT_CAP" \
            --out "$RUN_DIR/ui-recovery.env"; then
          # shellcheck disable=SC1090
          . "$RUN_DIR/ui-recovery.env"
          if [ "${GATE_RECOVERY_PRESENT:-0}" -eq 1 ]; then
            echo "== recovery round 1 of 1 (UI): erasing the gate simulator and retrying ${GATE_RECOVERY_CLASS_COUNT} class(es) once =="
            simulator_prep ui-recovery
            if run_lane ui "$GATE_UI_LANE-recovery" "$GATE_UI_TARGET" \
                "$GATE_RECOVERY_CLASSES" 0 "$GATE_RECOVERY_TIMEOUT" \
                "$RUN_DIR/lanes/ui-recovery" \
                --class-timeouts "$GATE_RECOVERY_CLASS_TIMEOUTS"; then
              echo "ui recovery round: the retried UI classes passed"
            else
              echo "ui recovery round: the retried UI classes still report failures (classified in the result document)"
            fi
          else
            echo "ui recovery round: nothing to retry"
          fi
        else
          echo "ui recovery round: refused to project (correct when a genuine UI failure is present)"
        fi
        return 0
      }

      if [ "$WORKERS" -eq 2 ]; then
        start_worker unit "$SIMULATOR_NAME" "$SIMULATOR_UDID" worker_unit
        start_worker ui "$SIMULATOR_NAME2" "$SIMULATOR2_UDID" worker_ui
        wait_for_workers
      else
        # One worker at a time, same code path. The SECOND start waits for the
        # first to be reaped: both own the SAME UDID, and two concurrent
        # xcodebuild chains (or two concurrent shutdown/erase/boot preparations)
        # on one device is exactly the corruption the worker split exists to
        # avoid. Starting both and waiting once at the end would run them
        # side by side.
        start_worker unit "$SIMULATOR_NAME" "$SIMULATOR_UDID" worker_unit
        wait_for_workers
        start_worker ui "$SIMULATOR_NAME" "$SIMULATOR_UDID" worker_ui
        wait_for_workers
      fi
      record_workers
      echo ""
      echo "== workers =="
      while IFS=$'\t' read -r wname wdev wudid wexit wwall wdone wprepfail wlog; do
        [ -z "$wname" ] && continue
        echo "worker $wname: device '$wdev' ($wudid), exit ${wexit}, ${wwall}s, completed=${wdone}, sim_prep_failed=${wprepfail}"
      done < "$RUN_DIR/workers.tsv"
      # A worker that did not complete is a gate defect the operator must see
      # in the console too, not only in the result document.
      while IFS=$'\t' read -r wname wdev wudid wexit wwall wdone wprepfail wlog; do
        [ -z "$wname" ] && continue
        if [ "$wdone" != "1" ]; then
          echo "local-ci-gate: worker '$wname' did not run to completion (exit ${wexit}); tail of $wlog:"
          tail -n 20 "$RUN_DIR/$wlog" 2>/dev/null | sed 's/^/  /'
        fi
      done < "$RUN_DIR/workers.tsv"
    fi
  fi
fi

# --- summarize ---------------------------------------------------------------
# The overlapped static phase is joined here, before anything reads its phase
# document: the gate's verdict must include it, so the run waits for it (it
# usually finished long before the lanes did).
if [ -n "${STATIC_PID:-}" ]; then
  wait "$STATIC_PID" 2>/dev/null || true
  STATIC_PID=""
  echo ""
  echo "== static checks (overlapped with the build and the test lanes) =="
  _static_phase="$RUN_DIR/static/phase.json"
  if [ -s "$_static_phase" ]; then
    python3 - "$_static_phase" "$(( $(date +%s) - STATIC_STARTED ))" <<'PY' 2>/dev/null || true
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
print("  status: {0}; {1}s of check work, finished {2}s into the run".format(
    doc.get("status"), doc.get("duration_s"), sys.argv[2]))
for check in doc.get("checks") or []:
    print("  {0}: {1} ({2}s)".format(
        check.get("name"), check.get("status"), check.get("duration_s")))
PY
  else
    echo "local-ci-gate: the overlapped static phase wrote no phase document" >&2
    tail -n 20 "$RUN_DIR/static/static.log" 2>/dev/null | sed 's/^/  /' >&2 || true
  fi
fi

# The recovery round and the preparation checks are written before the summary
# so a degraded environment shows up as a caveat on the result rather than only
# in the log. The recovery round is recorded whether it ran or not (status
# skipped), so the result can distinguish "no recovery needed" from "silently
# missing".
#
# The preparation records come from the WORKERS (each prepared its own device,
# concurrently): the phase document is assembled here from their per-worker
# files, so a preparation that failed on either device lands on the result.
# A glob, never `$(ls ...)`: a --run-dir containing a space would word-split
# into nonexistent paths and the phase would then read PASS WITH NO CHECKS,
# silently dropping a failed preparation from the result.
SIM_PREP_CHECKS=()
SIM_PREP_FAILED=0
for _prep_file in "$RUN_DIR"/workers/*/sim-prep.tsv; do
  [ -f "$_prep_file" ] || continue
  _prep_worker="$(basename "$(dirname "$_prep_file")")"
  while IFS=$'\t' read -r _plabel _pstatus _psecs; do
    [ -z "$_plabel" ] && continue
    # Worker-qualified: the same label ("ui", "unit") is prepared by whichever
    # worker owns that device, and the record has to say which one it was.
    _ptoken="$_prep_worker/$_plabel"
    if [ "$_pstatus" != "0" ]; then
      SIM_PREP_FAILED=1
      SIM_PREP_CHECKS+=(--check "$_ptoken:fail:$_psecs")
    else
      SIM_PREP_CHECKS+=(--check "$_ptoken:pass:$_psecs")
    fi
  done < "$_prep_file"
done
python3 "$HELPER" phase --out "$RUN_DIR/sim-prep/phase.json" \
  --phase sim-prep \
  --status "$([ "$SIM_PREP_FAILED" -eq 1 ] && echo fail || echo pass)" \
  --duration 0 --exit-code "$SIM_PREP_FAILED" \
  --note "bounded shutdown/erase/boot/wait-for-boot before each lane" \
  --detail "workers=$([ "$WORKERS" -eq 2 ] && echo 2 || echo 1)" \
  "${SIM_PREP_CHECKS[@]+"${SIM_PREP_CHECKS[@]}"}" >/dev/null 2>&1 || true

# Record whether ANY recovery pass exists - unit or UI, per-class
# (unit-recovery-<chunk>) or bare (the UI round writes lanes/ui-recovery with
# no trailing suffix). The old check looked for the bare unit dir (which this
# script never creates) and a `*-recovery-*` glob that cannot match the UI
# dir, so a UI-only recovery was recorded as "no recovery ran".
RECOVERY_EVER_RAN=0
if ls -d "$RUN_DIR"/lanes/*-recovery* >/dev/null 2>&1 \
    || [ -d "$RUN_DIR/lanes/ui-recovery" ]; then
  RECOVERY_EVER_RAN=1
fi
python3 "$HELPER" phase --out "$RUN_DIR/recovery/phase.json" \
  --phase recovery \
  --status "$([ "$RECOVERY_EVER_RAN" -eq 1 ] && echo pass || echo skipped)" \
  --duration 0 --exit-code 0 \
  --note "one bounded recovery round for the simulator launch-refusal class" \
  --detail "unit_recovery_dirs=$(ls -d "$RUN_DIR"/lanes/unit-recovery* 2>/dev/null | tr -d '\n')" \
  --detail "ui_recovery_dirs=$(ls -d "$RUN_DIR"/lanes/ui-recovery* "$RUN_DIR"/lanes/ui-recovery 2>/dev/null | tr -d '\n')" \
  --check "round-1:$([ "$RECOVERY_EVER_RAN" -eq 1 ] && echo pass || echo skipped):0"

GATE_FINISHED_AT="$(now_iso)"
GATE_ELAPSED=$(( $(date +%s) - GATE_START_EPOCH ))
write_meta "$GATE_FINISHED_AT" "$GATE_ELAPSED"

VERDICT=1
if python3 "$HELPER" summarize --run-dir "$RUN_DIR" \
    --out "$RUN_DIR/gate-result.json" --markdown "$RUN_DIR/summary.md"; then
  VERDICT=0
fi

# Record the result in the per-SHA registry (exit 2 is how a later run of the
# same mode is refused unless it was explicitly requested); a failed append
# must not be silent, because it re-arms the SHA for another full run. The mode
# is part of the record: "a release result already exists for this SHA" and
# "a merge result already exists for this SHA" are different statements.
printf '%s\t%s\t%s\t%s\t%s\n' "$(now_iso)" "$RUN_DIR" "${VERDICT}" "$SHA" "$MODE" \
  >> "$SHA_REGISTRY" 2>/dev/null \
  || echo "local-ci-gate: warning: could not record the result for $SHA in the SHA registry; it lives at $RUN_DIR/gate-result.json" >&2

echo ""
echo "tested SHA : $SHA"
echo "mode       : $MODE"
echo "run dir    : $RUN_DIR"
echo "result json: $RUN_DIR/gate-result.json"
echo "summary    : $RUN_DIR/summary.md"

remove_worktree

if [ "$VERDICT" -eq 0 ]; then
  echo "local gate: PASS for $SHA"
  exit 0
fi
echo "local gate: FAIL for $SHA"
echo "to inspect the exact tree: git -C \"$REPO_ROOT\" worktree add --detach <path> $SHA"
exit 1
