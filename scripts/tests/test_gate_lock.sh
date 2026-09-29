#!/usr/bin/env bash
#
# Deterministic tests for scripts/ci-gate-lock.sh - the single-gate-per-Mac
# lock. No simulator, no Xcode, no timing luck: every scenario constructs the
# state it needs and asserts the module's semantics directly.
#
# The property under test is the one two simultaneous gate runs live or die
# by: at no point may two invocations both believe they own the Mac gate.
#
# Notes for readers of this file:
#   * each case uses its OWN lock directory, so cases cannot contaminate each
#     other with state left by a previous assertion;
#   * a background holder records $BASHPID (a subshell's $$ is its PARENT's
#     pid in bash, which would make a "two contenders" test compare the same
#     number against itself).
#
# Usage: bash scripts/tests/test_gate_lock.sh   (exit 0 = all cases pass)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
MOD="$SCRIPTS/ci-gate-lock.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0
ok()  { pass_count=$((pass_count + 1)); echo "  ok: $1"; }
bad() { fail_count=$((fail_count + 1)); echo "  FAIL: $1"; }
assert_eq() { # $1=desc $2=actual $3=expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}
no_temp_left() { # $1 = lock dir prefix -> count of *.new.* siblings
  ls -d "$1".new.* 2>/dev/null | wc -l | tr -d ' '
}

[ -f "$MOD" ] || { echo "missing $MOD"; exit 1; }
. "$MOD"

echo "=== gate lock tests (bash $(bash --version | head -1 | cut -d' ' -f4)) ==="

echo "--- case 1: acquire and release ---"
LOCK1="$WORK/lock-1"
if acquire_gate_lock "$LOCK1"; then
  ok "the first contender acquires the lock"
else
  bad "the first contender could not acquire the lock"
fi
assert_eq "the canonical lock carries this process's pid" \
  "$(cat "$LOCK1/pid" 2>/dev/null)" "$$"
gate_lock_release
assert_eq "release removes a lock this process still owns" \
  "$([ -e "$LOCK1" ] && echo yes || echo no)" "no"
assert_eq "release leaves no temporary lock behind" \
  "$(no_temp_left "$LOCK1")" "0"

echo "--- case 2: two contenders cannot both own the gate ---"
LOCK2="$WORK/lock-2"
# A real child process, not a subshell: `$$` inside a subshell is its
# parent's pid in bash (which would make the two-contenders test compare one
# number against itself), and $BASHPID does not exist under /bin/bash 3.2.
#
# The holder's "hold" is a background sleep this script `wait`s on, and its
# trap EXITS as well as releasing. Both matter for wall clock, not semantics:
# bash defers a trapped signal until the running FOREGROUND child finishes, so
# a foreground `sleep 60` would hold the TERM sent at the end of this case for
# the full minute - 60s of wall clock the suite paid for nothing, since the
# only thing this case needs is a LIVE owner while the refusal is checked.
write_holder_script() {
  cat > "$WORK/holder-script.sh" <<'HOLDER_EOF'
#!/usr/bin/env bash
# $1 = lock module, $2 = lock dir, $3 = path to write this process's pid
set -u
. "$1"
SLEEP_PID=""
trap 'gate_lock_release; [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null; exit 0' EXIT INT TERM
acquire_gate_lock "$2" || exit 9
printf '%s\n' "$$" > "$3"
sleep 60 & SLEEP_PID=$!
wait "$SLEEP_PID"
HOLDER_EOF
}
write_holder_script
bash "$WORK/holder-script.sh" "$MOD" "$LOCK2" "$WORK/holder" &
HOLDER_BG=$!
# Bounded wait: if the holder never starts, fail instead of spinning forever.
_wait=0
while [ ! -f "$WORK/holder" ] && [ "$_wait" -lt 100 ]; do
  sleep 0.1
  _wait=$(( _wait + 1 ))
done
if [ ! -f "$WORK/holder" ]; then
  bad "the holder process never started"
  kill "$HOLDER_BG" 2>/dev/null
  exit 1
fi
ACQUIRE_RC=0
acquire_gate_lock "$LOCK2" || ACQUIRE_RC=$?
assert_eq "the second contender is refused" "$ACQUIRE_RC" "2"
# The module records `$$`, and a subshell's `$$` is its parent's pid in bash
# (the gate itself is a top-level script, where `$$` is its real pid). The
# property that matters is that a refusal identifies a LIVE owner, and that
# the module's message and the lock's own record agree - assert those rather
# than comparing pids recorded under two different conventions.
if [ -n "${GATE_LOCK_OWNER:-}" ] && kill -0 "${GATE_LOCK_OWNER}" 2>/dev/null; then
  ok "the refusal names a live owner process"
else
  bad "the refusal did not identify a live owner (got '${GATE_LOCK_OWNER:-}')"
fi
assert_eq "and it matches the pid recorded in the lock itself" \
  "${GATE_LOCK_OWNER:-}" "$(cat "$LOCK2/pid")"
assert_eq "the refused contender leaked no temporary lock" \
  "$(no_temp_left "$LOCK2")" "0"
kill "$HOLDER_BG" 2>/dev/null
wait "$HOLDER_BG" 2>/dev/null
gate_lock_release
rm -rf "$LOCK2"

echo "--- case 3: the pre-owner window has exactly one owner ---"
# One contender's temporary directory exists but the canonical lock does not
# yet (the moment between its metadata write and its rename). Whichever
# completes that rename owns the gate; the other must never believe it won.
LOCK3="$WORK/lock-3"
A_TEMP="$LOCK3.new.9999"
mkdir -p "$A_TEMP"
printf '9999\n' > "$A_TEMP/pid"
B_RC=0
acquire_gate_lock "$LOCK3" || B_RC=$?
assert_eq "the contender who completes the rename acquires" "$B_RC" "0"
if mv "$A_TEMP" "$LOCK3" 2>/dev/null; then
  if [ -e "$LOCK3/$(basename "$A_TEMP")" ]; then
    ok "the loser's rename only nested inside the owner's lock"
  else
    bad "the loser's rename replaced the owner's lock"
  fi
else
  ok "the loser's rename was refused outright"
fi
assert_eq "and the winner still owns the gate" "$(cat "$LOCK3/pid")" "$$"
LOSER_RC=0
acquire_gate_lock "$LOCK3" || LOSER_RC=$?
assert_eq "the loser, going through the module, is refused" "$LOSER_RC" "2"
assert_eq "with the winner's pid still intact" "$(cat "$LOCK3/pid")" "$$"
gate_lock_release
rm -rf "$LOCK3"

echo "--- case 4: a lock with no readable PID is BUSY, never stolen ---"
LOCK4="$WORK/lock-4"
mkdir -p "$LOCK4"
EMPTY_RC=0
acquire_gate_lock "$LOCK4" || EMPTY_RC=$?
assert_eq "an ownerless lock refuses acquisition" "$EMPTY_RC" "2"
assert_eq "and it is left in place (not stolen, not deleted)" \
  "$([ -d "$LOCK4" ] && echo yes || echo no)" "yes"
assert_eq "so the next contender can still see it is BUSY" \
  "$([ -f "$LOCK4/pid" ] && echo yes || echo no)" "no"
gate_lock_release
rm -rf "$LOCK4"

echo "--- case 5: a confirmed-dead owner is taken over ---"
LOCK5="$WORK/lock-5"
mkdir -p "$LOCK5"
printf '999999999\n' > "$LOCK5/pid"     # a pid that cannot be running
STALE_RC=0
acquire_gate_lock "$LOCK5" 2>"$WORK/lock-5.steal.err" || STALE_RC=$?
assert_eq "a dead owner's lock is taken over" "$STALE_RC" "0"
assert_eq "and now carries this process's pid" "$(cat "$LOCK5/pid")" "$$"
assert_eq "the takeover printed the warning docs/CI.md promises" \
  "$(grep -c 'taking it over' "$WORK/lock-5.steal.err" 2>/dev/null)" "1"
gate_lock_release
rm -rf "$LOCK5"

echo "--- case 6: an old owner cannot remove another process's lock ---"
LOCK6="$WORK/lock-6"
OWN_RC=0
acquire_gate_lock "$LOCK6" || OWN_RC=$?
assert_eq "setup: the first owner acquires" "$OWN_RC" "0"
printf '424242\n' > "$LOCK6/pid"        # another process took ownership meanwhile
gate_lock_release
assert_eq "release does not remove a lock owned by someone else" \
  "$([ -d "$LOCK6" ] && echo yes || echo no)" "yes"
assert_eq "and the other owner's pid survives" "$(cat "$LOCK6/pid")" "424242"
rm -rf "$LOCK6"

echo "--- case 7: an interrupt during acquisition leaks nothing ---"
# Interrupted between writing its metadata and renaming it into place: the
# trap must clear the in-flight temporary lock and create no canonical lock.
LOCK7="$WORK/lock-7"
INFLIGHT="$LOCK7.new.4321"
mkdir -p "$INFLIGHT"
printf '%s\n' "$$" > "$INFLIGHT/pid"
# The long sleep runs as a BACKGROUND job with `wait`, not as a foreground
# child: bash defers a trapped signal until the running foreground command
# finishes, so `sleep 30` in the foreground would hold the TERM below for the
# full 30s. `wait` is interruptible - the trap runs immediately, which is the
# behavior this case is actually about - and the trap kills the sleep so no
# orphan outlives the case.
( . "$MOD"
  GATE_LOCK_TEMP="$INFLIGHT"
  sleep 30 & SLEEP_PID=$!
  trap 'gate_lock_release; kill "$SLEEP_PID" 2>/dev/null; exit 143' INT TERM
  wait "$SLEEP_PID" ) &
INTERRUPTED=$!
sleep 0.3
kill -TERM "$INTERRUPTED" 2>/dev/null
wait "$INTERRUPTED" 2>/dev/null
assert_eq "the in-flight temporary lock was removed by the trap" \
  "$([ -d "$INFLIGHT" ] && echo yes || echo no)" "no"
assert_eq "and no canonical lock was created" \
  "$([ -e "$LOCK7" ] && echo yes || echo no)" "no"

echo "--- case 8: taking a dead owner over leaves nothing behind ---"
LOCK8="$WORK/lock-8"
mkdir -p "$LOCK8"
printf '999999999
' > "$LOCK8/pid"
STEAL_RC=0
acquire_gate_lock "$LOCK8" || STEAL_RC=$?
assert_eq "the dead owner's lock is taken over" "$STEAL_RC" "0"
assert_eq "and carries this process's pid" "$(cat "$LOCK8/pid")" "$$"
assert_eq "no rename-aside left over from the steal"   "$(ls -d "$LOCK8".stale.* 2>/dev/null | wc -l | tr -d ' ')" "0"
gate_lock_release
rm -rf "$LOCK8"

echo "--- case 9: a corrupt pid is BUSY, never stolen ---"
# Garbage in the pid file is not a "confirmed dead owner": the rule is
# readable-and-dead, not merely non-live.
LOCK9="$WORK/lock-9"
mkdir -p "$LOCK9"
printf 'not-a-pid
' > "$LOCK9/pid"
CORRUPT_RC=0
acquire_gate_lock "$LOCK9" || CORRUPT_RC=$?
assert_eq "a corrupt pid refuses acquisition" "$CORRUPT_RC" "2"
assert_eq "and the lock is left in place"   "$([ -f "$LOCK9/pid" ] && echo yes || echo no)" "yes"
gate_lock_release
rm -rf "$LOCK9"

echo "--- case 10: no contender may delete a live owner's lock ---"
# The stolen-lock path must never run against a live owner: a rival racing a
# dead lock has to end up BUSY here, with the owner's pid untouched.
LOCK10="$WORK/lock-10"
OWN10=0
acquire_gate_lock "$LOCK10" || OWN10=$?
assert_eq "setup: the owner acquires" "$OWN10" "0"
RIVAL_RC=0
acquire_gate_lock "$LOCK10" || RIVAL_RC=$?
assert_eq "a rival racing the live lock is refused" "$RIVAL_RC" "2"
assert_eq "and the owner's pid is intact" "$(cat "$LOCK10/pid")" "$$"
gate_lock_release
rm -rf "$LOCK10"

echo "--- case 11: contenders racing a dead-owner lock yield one winner ---"
LOCK11="$WORK/lock-11"
mkdir -p "$LOCK11"
printf '999999999
' > "$LOCK11/pid"
_racers=0
while [ "$_racers" -lt 4 ]; do
  # A winner holds the lock (bounded) until EVERY racer has made its attempt:
  # a winner that exits early leaves a dead-owner lock that a late-starting
  # racer then takes over legitimately - a second, sequential winner that says
  # nothing about the race. Winners APPEND, so two concurrent owners show up
  # as two lines instead of one overwritten file.
  bash -c '
    . "$1"
    if acquire_gate_lock "$2" 2>/dev/null; then
      printf "%s\n" "$$" >> "$2.winner"
      : > "$2.tried.$$"
      _held=0
      while [ "$(ls "$2".tried.* 2>/dev/null | wc -l | tr -d " ")" -lt 4 ] \
          && [ "$_held" -lt 600 ]; do
        sleep 0.1
        _held=$(( _held + 1 ))
      done
    else
      : > "$2.tried.$$"
    fi' _ "$MOD" "$LOCK11" &
  _racers=$(( _racers + 1 ))
done
wait
# Diagnosis first: this is the suite's only genuine RACE. If it ever goes red
# again, the shape of the failure - was the lock left behind, was an aside or a
# steal marker left behind, how many winners were recorded - is what says
# which contender went wrong.
if [ "$(wc -l < "$LOCK11.winner" 2>/dev/null | tr -d ' ')" != "1" ]; then
  echo "  (race diagnosis: $(ls -ld "$LOCK11" "$LOCK11"/* "$LOCK11".stale.* "$LOCK11.winner" 2>&1 | tr '\n' '|'))"
  echo "  (lock pid: $(cat "$LOCK11/pid" 2>/dev/null || echo none); winners: $(tr '\n' ' ' < "$LOCK11.winner" 2>/dev/null))"
fi
assert_eq "exactly one contender wins the race" \
  "$(wc -l < "$LOCK11.winner" 2>/dev/null | tr -d ' ')" "1"
assert_eq "and the lock carries the winner's pid" \
  "$(cat "$LOCK11/pid" 2>/dev/null)" "$(cat "$LOCK11.winner" 2>/dev/null)"
rm -rf "$LOCK11" "$LOCK11.winner" "$LOCK11".tried.*

echo "--- case 12: a leftover rename-aside is never the steal's target ---"
# A steal that was SIGKILLed after the rename-aside leaves that directory
# behind; a later steal must not nest its own rename into it (that would make
# the cleanup delete a live lock along with the stale one).
LOCK12="$WORK/lock-12"
mkdir -p "$LOCK12"
printf '999999999
' > "$LOCK12/pid"
LEFTOVER="$LOCK12.stale.$$"
mkdir -p "$LEFTOVER"
printf '424242
' > "$LEFTOVER/pid"
STALE2_RC=0
acquire_gate_lock "$LOCK12" || STALE2_RC=$?
assert_eq "the steal still succeeds despite the leftover" "$STALE2_RC" "0"
assert_eq "and this process owns the canonical lock"   "$(cat "$LOCK12/pid")" "$$"
assert_eq "the leftover aside is untouched (not nested into)"   "$(cat "$LEFTOVER/pid")" "424242"
assert_eq "and the leftover was not mistaken for the lock"   "$([ -d "$LOCK12" ] && echo yes || echo no)" "yes"
gate_lock_release
rm -rf "$LOCK12" "$LEFTOVER"

echo "--- case 13: a steal in progress is BUSY and leaves no marker behind ---"
# The steal of a dead-owner lock is claimed by a marker INSIDE that lock
# instance.
LOCK13="$WORK/lock-13"
# (a) A second stealer that finds another contender's marker backs off.
mkdir -p "$LOCK13/steal"
printf '999999999\n' > "$LOCK13/pid"
MARKED_RC=0
acquire_gate_lock "$LOCK13" 2>/dev/null || MARKED_RC=$?
assert_eq "a dead-owner lock that is being stolen refuses a second stealer" "$MARKED_RC" "2"
assert_eq "and the lock and the other stealer's marker are untouched" \
  "$(cat "$LOCK13/pid" 2>/dev/null)|$([ -d "$LOCK13/steal" ] && echo marker)" "999999999|marker"
assert_eq "the refusal names the dead owner as blocked, not as unreadable" \
  "${GATE_LOCK_STEAL_BLOCKED:-}" "999999999"
assert_eq "no rename-aside was made" \
  "$(ls -d "$LOCK13".stale.* 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -rf "$LOCK13"

# (b) The lock is REPLACED by a live one between the liveness check and the
# marker: `kill` is overridden (in a subshell) so that the liveness probe of
# the dead pid swaps a live owner in, exactly the interleaving of a faster
# contender. The marker then lands in the live lock; the stealer must see
# the new pid, withdraw its marker and never move that lock.
mkdir -p "$LOCK13"
printf '999999999\n' > "$LOCK13/pid"
LIVE_OWNER="$$"
REPLACED_RC="$(
  kill() {
    if [ "$1" = "-0" ] && [ "$2" = "999999999" ]; then
      printf '%s\n' "$LIVE_OWNER" > "$LOCK13/pid"
      return 1
    fi
    command kill "$@"
  }
  rc=0
  acquire_gate_lock "$LOCK13" 2>/dev/null || rc=$?
  echo "$rc"
)"
assert_eq "a marker that lands in a replaced, live lock reports BUSY" "$REPLACED_RC" "2"
assert_eq "and the live lock is neither moved nor changed" \
  "$(cat "$LOCK13/pid" 2>/dev/null)" "$LIVE_OWNER"
assert_eq "and the stealer withdrew its marker" \
  "$([ -d "$LOCK13/steal" ] && echo yes || echo no)" "no"
assert_eq "and made no rename-aside" \
  "$(ls -d "$LOCK13".stale.* 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -rf "$LOCK13"

# (b2) The same interleaving, but the newer owner has died by the re-read:
# BUSY for this race, yet it must not be reported as a running gate.
mkdir -p "$LOCK13"
printf '999999999\n' > "$LOCK13/pid"
DEAD_REPLACED_OWNER="$(
  kill() {
    if [ "$1" = "-0" ] && [ "$2" = "999999999" ]; then
      printf '999999998\n' > "$LOCK13/pid"
      return 1
    fi
    command kill "$@"
  }
  acquire_gate_lock "$LOCK13" 2>/dev/null
  echo "rc=$? owner=${GATE_LOCK_OWNER:-none}"
)"
assert_eq "a dead newer owner is not reported as a running gate" \
  "$DEAD_REPLACED_OWNER" "rc=2 owner=none"
rm -rf "$LOCK13"

# (c) An interrupt around the marker: the stealer's trap releases, and it
# must leave nothing behind that makes the lock unstealable. `mv` is
# overridden to deliver a TERM right after a given rename has completed
# (sh's PPID is the subshell, which keeps this bash 3.2 compatible); bash
# runs the trap as soon as the override returns.
#   claim: right after the rename that CREATES the marker - the one-command
#          window a separate mkdir + bookkeeping assignment used to leave
#          open. The dead lock must still be there, marker-free.
#   aside: right after the dead lock (marker inside) was renamed aside. The
#          aside must be removed, and the canonical path left free.
for _when in claim aside; do
  mkdir -p "$LOCK13"
  printf '999999999\n' > "$LOCK13/pid"
  ( trap 'gate_lock_release; exit 143' TERM
    mv() {
      command mv "$@"; _rc=$?
      case "$2" in
        */steal) [ "$_when" = claim ] && sh -c 'kill -TERM "$PPID"' ;;
        *.stale.*) [ "$_when" = aside ] && sh -c 'kill -TERM "$PPID"' ;;
      esac
      return "$_rc"
    }
    acquire_gate_lock "$LOCK13" 2>/dev/null
    exit 0 ) &
  INTERRUPTED13=$!
  wait "$INTERRUPTED13" 2>/dev/null
  INTERRUPTED13_RC=$?
  assert_eq "setup ($_when): the stealer was interrupted mid-steal" "$INTERRUPTED13_RC" "143"
  assert_eq "an interrupt after the $_when rename leaves no marker behind" \
    "$([ -d "$LOCK13/steal" ] && echo yes || echo no)" "no"
  assert_eq "nor a half-built marker or aside ($_when)" \
    "$(ls -d "$LOCK13".mark.* "$LOCK13".stale.* 2>/dev/null | wc -l | tr -d ' ')" "0"
  if [ "$_when" = claim ]; then
    assert_eq "and the dead lock is still there to be taken over (claim)" \
      "$(cat "$LOCK13/pid" 2>/dev/null)" "999999999"
  else
    assert_eq "and the canonical path is free (aside)" \
      "$([ -e "$LOCK13" ] && echo taken || echo free)" "free"
  fi
  AFTER13_RC=0
  acquire_gate_lock "$LOCK13" 2>/dev/null || AFTER13_RC=$?
  assert_eq "so the next contender acquires the lock ($_when)" "$AFTER13_RC" "0"
  gate_lock_release
  rm -rf "$LOCK13"
done

# (d) The rename aside itself fails: BUSY, and the marker is withdrawn.
mkdir -p "$LOCK13"
printf '999999999\n' > "$LOCK13/pid"
# A named function run by command substitution (so the `mv` override stays in
# that subshell): macOS /bin/bash 3.2 cannot parse a `case` written inline in
# a command substitution - its pattern parentheses end the substitution.
case13_failed_aside() {
  mv() {
    case "$2" in
      */steal) command mv "$@" ;;
      *) return 1 ;;
    esac
  }
  local rc=0
  acquire_gate_lock "$LOCK13" 2>/dev/null || rc=$?
  echo "$rc"
}
FAILED13_RC="$(case13_failed_aside)"
assert_eq "a failed rename aside reports BUSY" "$FAILED13_RC" "2"
assert_eq "and withdraws the stealer's marker" \
  "$([ -d "$LOCK13/steal" ] && echo yes || echo no)" "no"
rm -rf "$LOCK13" "$LOCK13".stale.* "$LOCK13".mark.*

echo "--- case 14: only the top-level process counts as the lock's process ---"
# A subshell's `$$` is its parent's pid, so a teardown trap a subshell
# inherits would otherwise release the parent's lock and resources.
if gate_is_main_process; then
  ok "the top-level process is the main process"
else
  bad "the top-level process was not recognized as the main process"
fi
assert_eq "a subshell is not" \
  "$( ( gate_is_main_process && echo main || echo sub ) )" "sub"
( gate_is_main_process && echo main > "$WORK/bg14" || echo sub > "$WORK/bg14" ) &
wait "$!"
assert_eq "nor a background subshell" "$(cat "$WORK/bg14" 2>/dev/null)" "sub"
# The macOS /bin/bash 3.2 path: no BASHPID (unset strips it on newer bash).
# At the top level this drives the sh PPID probe; a real subshell is still
# answered by the BASH_SUBSHELL check before the probe is reached.
assert_eq "without BASHPID (bash 3.2), a top-level script is still main" \
  "$(bash -c '. "$1"; unset BASHPID; gate_is_main_process && echo main || echo sub' _ "$MOD")" "main"
assert_eq "and a background subshell still is not" \
  "$(bash -c '. "$1"; unset BASHPID; ( gate_is_main_process && echo main || echo sub ) & wait' _ "$MOD")" "sub"
# The probe path in a child (probe-path-only coverage, bash 4+: it relies on
# BASH_SUBSHELL being assignable): BASH_SUBSHELL is forced back to 0 so only the
# PPID probe can tell the subshell from the top level. A recording `sh` on
# PATH proves the probe actually ran: a shell that ignored the BASH_SUBSHELL
# assignment would answer "sub" from the first check and never reach it.
mkdir -p "$WORK/probe-bin"
printf '#!/bin/sh\necho probed >> "%s"\nexec /bin/sh "$@"\n' "$WORK/probe-ran" > "$WORK/probe-bin/sh"
chmod +x "$WORK/probe-bin/sh"
rm -f "$WORK/probe-ran"
assert_eq "without BASHPID or BASH_SUBSHELL, the pid probe still spots a subshell" \
  "$(PROBE_PATH="$WORK/probe-bin:$PATH" bash -c '. "$1"; unset BASHPID; ( BASH_SUBSHELL=0; PATH="$PROBE_PATH"; gate_is_main_process && echo main || echo sub )' _ "$MOD")|$(cat "$WORK/probe-ran" 2>/dev/null)" "sub|probed"
assert_eq "an unanswerable pid probe fails toward the teardown (main)" \
  "$(bash -c '. "$1"; unset BASHPID; PATH=/nonexistent; gate_is_main_process && echo main || echo sub' _ "$MOD" 2>/dev/null)" "main"

echo "--- case 15: a pid kill -0 cannot signal (EPERM) is not judged dead ---"
# For a process owned by another local user, `kill -0` fails with EPERM - the
# same failure as a dead pid. Simulated by overriding `kill` in a subshell: the
# owner below is this test process, alive, so the lock must be BUSY and left
# exactly as it was, not stolen.
LOCK15="$WORK/lock-15"
mkdir -p "$LOCK15"
printf '%s\n' "$$" > "$LOCK15/pid"
# A stolen lock would be rewritten with this same `$$`, so the pid alone
# cannot prove the lock was left alone: the original directory carries a
# sentinel a takeover would discard with it.
touch "$LOCK15/sentinel"
EPERM15="$( (
  kill() { return 1; }
  rc=0
  acquire_gate_lock "$LOCK15" 2>/dev/null || rc=$?
  echo "$rc|${GATE_LOCK_OWNER:-}"
) )"
assert_eq "a live owner kill -0 cannot signal is BUSY, named as the owner" \
  "$EPERM15" "2|$$"
assert_eq "and its lock is untouched" \
  "$(cat "$LOCK15/pid" 2>/dev/null)|$([ -f "$LOCK15/sentinel" ] && echo kept || echo gone)" "$$|kept"
assert_eq "with no steal marker left in it" \
  "$([ -e "$LOCK15/steal" ] && echo yes || echo no)" "no"
assert_eq "nor any aside or temp lock beside it" \
  "$(ls -d "$LOCK15".stale.* "$LOCK15".new.* "$LOCK15".mark.* 2>/dev/null | wc -l | tr -d ' ')" "0"
# The fallback must not make a genuinely dead owner unstealable.
printf '999999999\n' > "$LOCK15/pid"
DEAD15="$( (
  kill() { return 1; }
  rc=0
  acquire_gate_lock "$LOCK15" 2>/dev/null || rc=$?
  echo "$rc|$(cat "$LOCK15/pid" 2>/dev/null)"
  gate_lock_release
) )"
assert_eq "a pid that does not exist is still taken over" "$DEAD15" "0|$$"
rm -rf "$LOCK15"

echo ""
echo "=== $pass_count passed, $fail_count failed ==="
[ "$fail_count" -eq 0 ]
