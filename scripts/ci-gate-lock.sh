#!/usr/bin/env bash
#
# Single-gate-per-Mac lock for scripts/local-ci-gate.sh.
#
# Two concurrent xcodebuild/test chains on one Mac corrupt each other's
# Simulator state, so at no point may two invocations both believe they own
# the gate. This module makes acquisition structural rather than a sequence
# of check-then-act steps:
#
#   1. a uniquely named TEMPORARY lock directory is created and its PID and
#      owner metadata are written into it FIRST - the canonical location never
#      exists without metadata in it, so a contender can never observe a
#      lock it cannot interpret;
#   2. the temp directory is renamed into the canonical location (an atomic
#      rename into an absent path - a rename onto a NON-empty directory
#      fails, which is what makes a concurrent second renamer lose);
#   3. the acquisition is then VERIFIED: only the pid that is readable at the
#      canonical path owns the lock. Whoever lost the race cleans up and
#      reports BUSY - it never believes it owns the Mac.
#
# Semantics:
#   * a lock exists with NO readable pid        -> BUSY (never stolen: it is
#                                                  not provably stale)
#   * a readable pid that is confirmed dead     -> steal, claimed by an atomic
#                                                  mkdir INSIDE that lock
#                                                  instance, so no contender
#                                                  can ever move a live lock
#   * cleanup removes the canonical lock ONLY IF its pid is still ours
#   * the trap must be installed before acquisition can leak state
#
# Callers install their EXIT/INT/TERM traps BEFORE calling acquire_gate_lock.
# Bash 3.2 compatible (macOS /bin/bash) and `set -u` safe.

# Last acquired temp-lock path for this process (so cleanup can also remove
# an in-flight temp directory when an interrupt lands mid-acquisition).
GATE_LOCK_TEMP=""
GATE_LOCK_HELD=0
GATE_LOCK_HELD_DIR=""
GATE_LOCK_OWNER=""
# The steal marker this process created inside a dead lock, and the aside it
# renamed that lock to, while a steal is in flight: an interrupt landing
# between them must not leave the marker behind (it would make the dead lock
# unstealable) or the aside (a stray directory next to the lock).
GATE_LOCK_MARKER=""
GATE_LOCK_MARK_TEMP=""
GATE_LOCK_ASIDE=""
# Set on BUSY when the lock's owner is dead but another contender holds its
# steal marker: the pid is readable, so "no readable owner" would mislead.
GATE_LOCK_STEAL_BLOCKED=""

# True only in the process that sourced this module at top level - never in
# one of its `( ... ) &` subshells, where `$$` is still the PARENT's pid. A
# teardown trap a subshell inherits (a signal that beats bash's post-fork trap
# reset) must not run the parent's teardown there. BASH_SUBSHELL answers
# without a fork; BASHPID confirms where bash has it (4.0+). macOS /bin/bash
# 3.2 has neither BASHPID nor a fork-free alternative, so a child that `exec`s
# straight into sh reports its PPID - the shell asking. If even that cannot
# answer, the answer is "main": failing toward the teardown leaks nothing,
# while failing away from it would leak the very resources it releases. That
# makes the guard best-effort in exactly one environment - bash 3.2 with no
# usable `sh` - where a subshell caught by an inherited trap is taken for the
# top level again; everywhere else (any bash 4+, or a working sh) it is exact.
gate_is_main_process() {
  case "${BASH_SUBSHELL:-0}" in
    0) ;;
    *) return 1 ;;
  esac
  local self="${BASHPID:-}"
  if [ -z "$self" ]; then
    self="$(exec sh -c 'echo "$PPID"' 2>/dev/null)"
  fi
  [ -z "$self" ] || [ "$self" = "$$" ]
}

# Remove this process's steal marker - and only ours. The marker carries its
# creator's pid, so ownership is read from the marker itself rather than from
# how far the steal got: GATE_LOCK_MARKER is set BEFORE the claim, and an
# interrupt landing anywhere around it (before, during, or right after the
# rename that creates the marker) finds either our pid in it - ours, removed
# - or someone else's - left alone.
gate_lock_drop_marker() {
  if [ -n "$GATE_LOCK_MARK_TEMP" ]; then
    rm -rf "$GATE_LOCK_MARK_TEMP" 2>/dev/null || true
    if [ -n "$GATE_LOCK_MARKER" ]; then
      # A claim that lost the race nested into the winner's marker.
      rm -rf "$GATE_LOCK_MARKER/$(basename "$GATE_LOCK_MARK_TEMP")" 2>/dev/null || true
    fi
  fi
  if [ -n "$GATE_LOCK_MARKER" ] \
     && [ "$(cat "$GATE_LOCK_MARKER/pid" 2>/dev/null || true)" = "${BASHPID:-$$}" ]; then
    rm -rf "$GATE_LOCK_MARKER" 2>/dev/null || true
  fi
  GATE_LOCK_MARKER=""
  GATE_LOCK_MARK_TEMP=""
}

gate_lock_release() {
  # Never remove a lock we do not own: if another process took ownership
  # between our acquisition and this release, its pid must survive.
  local owner=""
  # An interrupted steal: our marker and the dead lock we had already
  # renamed aside.
  gate_lock_drop_marker
  if [ -n "$GATE_LOCK_ASIDE" ]; then
    rm -rf "$GATE_LOCK_ASIDE" 2>/dev/null || true
    GATE_LOCK_ASIDE=""
  fi
  # An interrupt during acquisition leaves a temp directory: clear ours first,
  # whether or not we ever took ownership (otherwise a mid-acquisition trap
  # returns here and leaks it).
  if [ -n "$GATE_LOCK_TEMP" ] && [ -d "$GATE_LOCK_TEMP" ]; then
    rm -rf "$GATE_LOCK_TEMP" 2>/dev/null || true
    GATE_LOCK_TEMP=""
  fi
  [ "$GATE_LOCK_HELD" -eq 1 ] || return 0
  owner="$(cat "$GATE_LOCK_HELD_DIR/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && [ "$owner" = "$$" ]; then
    rm -rf "$GATE_LOCK_HELD_DIR" 2>/dev/null || true
  fi
  # An interrupt during acquisition leaves a temp directory: clean ours up.
  if [ -n "$GATE_LOCK_TEMP" ] && [ -d "$GATE_LOCK_TEMP" ]; then
    rm -rf "$GATE_LOCK_TEMP" 2>/dev/null || true
  fi
  GATE_LOCK_HELD=0
  GATE_LOCK_HELD_DIR=""
  GATE_LOCK_TEMP=""
  return 0
}

# Returns: 0 acquired, 2 BUSY (another live owner or no readable pid),
#          1 could not create the temp directory.
acquire_gate_lock() { # $1 = canonical lock dir
  local canonical="$1" temp holder
  GATE_LOCK_OWNER=""
  GATE_LOCK_STEAL_BLOCKED=""
  temp="$canonical.new.$$"
  GATE_LOCK_TEMP="$temp"
  rm -rf "$temp" 2>/dev/null || true
  if ! mkdir -p "$temp" 2>/dev/null; then
    GATE_LOCK_TEMP=""
    return 1
  fi
  # Metadata BEFORE the canonical location can exist: a lock a contender
  # cannot interpret is never left behind.
  printf '%s\n' "$$" > "$temp/pid" || { rm -rf "$temp"; GATE_LOCK_TEMP=""; return 1; }

  if [ -e "$canonical" ]; then
    holder="$(cat "$canonical/pid" 2>/dev/null || true)"
    if [ -z "$holder" ]; then
      # No readable pid: BUSY. It is not provably stale, and stealing a lock
      # we cannot explain is how two gates end up on one Mac.
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      GATE_LOCK_OWNER=""
      return 2
    fi
    case "$holder" in
      *[!0-9]*)
        # Corrupt pid content is not a provably dead owner: same rule as a
        # missing one - BUSY, never stolen.
        rm -rf "$temp"; GATE_LOCK_TEMP=""
        GATE_LOCK_OWNER=""
        return 2
        ;;
    esac
    if kill -0 "$holder" 2>/dev/null; then
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      GATE_LOCK_OWNER="$holder"
      return 2
    fi
    # Confirmed dead owner: steal THIS lock instance, and only this one.
    #
    # A destructive `rm -rf` here is the classic check-then-act race: a
    # contender can pass the liveness check above, let ANOTHER contender steal
    # and claim, and then delete that live lock - two owners, one Mac, corrupt
    # Simulator state. Renaming the canonical path aside is not enough on its
    # own either: the path is not the instance. A slow stealer that judged the
    # dead lock can rename away the LIVE lock a faster contender has claimed
    # in its place; while that lock is aside, its owner's verification finds
    # no pid of its own (it reports BUSY, and the lock it leaves behind names
    # a live process that believes it lost - no winner at all), and a third
    # contender can claim the empty path, so "restoring" the moved lock lands
    # it inside that one - two owners.
    #
    # So the steal is claimed INSIDE the instance first, with a marker that
    # exactly one contender can create there: a directory holding its
    # creator's pid, built aside and renamed into place (a rename onto a path
    # that exists fails or nests - it never replaces). Nobody else can then
    # remove that lock directory - its owner is dead, other stealers lose the
    # marker rename, and a claim cannot rename onto a non-empty path - so once
    # the marker holder re-reads the same dead pid under its marker, the
    # directory it renames aside is guaranteed to be the dead lock. A marker
    # that lands in a NEWER lock (the path was replaced between the liveness
    # check and the claim) sees a different pid on the re-read, removes itself
    # and reports BUSY; no live lock is ever moved.
    #
    # The marker is created WITH its pid, and GATE_LOCK_MARKER is recorded
    # before the claim, so gate_lock_release removes it on every way out of
    # the steal - an interrupt at any point included (a separate mkdir and
    # bookkeeping assignment would leave a one-command window where a trap
    # finds a marker it does not know about). Only a stealer SIGKILLed while
    # holding it can leave a dead lock unstealable: BUSY, never stolen, and
    # reported as such (GATE_LOCK_STEAL_BLOCKED) so an operator can remove it.
    #
    # The marker's pid is NOT used to reclaim a marker whose creator looks
    # dead, deliberately. Reclaiming means removing another contender's claim
    # on the strength of a liveness check - the same check-then-act race this
    # marker exists to close, one level down: a slow reclaimer can remove the
    # LIVE marker of a contender that reclaimed first, and two stealers then
    # both proceed, the second renaming away the fresh lock the first just
    # claimed. The cost of refusing is the manual cleanup of a lock whose
    # stealer was SIGKILLed inside a millisecond-long window, which the BUSY
    # message names; the cost of reclaiming is two owners on one Mac.
    local marker="$canonical/steal"
    # The marker names its creator by BASHPID where bash has it: `$$` is the
    # parent's pid in a subshell, so two sibling stealers would otherwise
    # claim the same identity. (bash 3.2 falls back to `$$`; the gate calls
    # acquire_gate_lock only from its top level, where the two agree.)
    local me="${BASHPID:-$$}"
    local mark_temp="$canonical.mark.$me"
    GATE_LOCK_MARKER="$marker"
    GATE_LOCK_MARK_TEMP="$mark_temp"
    rm -rf "$mark_temp" 2>/dev/null || true
    if ! mkdir "$mark_temp" 2>/dev/null \
       || ! printf '%s\n' "$me" > "$mark_temp/pid" 2>/dev/null; then
      gate_lock_drop_marker
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      return 1
    fi
    if ! mv "$mark_temp" "$marker" 2>/dev/null \
       || [ "$(cat "$marker/pid" 2>/dev/null || true)" != "$me" ]; then
      # Another contender is stealing this instance (our claim failed, or
      # nested into its marker), or the lock is gone: its claim path decides
      # the outcome.
      gate_lock_drop_marker
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      GATE_LOCK_OWNER=""
      [ -d "$marker" ] && GATE_LOCK_STEAL_BLOCKED="$holder"
      return 2
    fi
    GATE_LOCK_MARK_TEMP=""
    local judged="$holder"
    holder="$(cat "$canonical/pid" 2>/dev/null || true)"
    if [ "$holder" != "$judged" ] || { [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; }; then
      # The marker landed in a newer lock than the one judged dead.
      gate_lock_drop_marker
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      # Named as the running owner only while it is provably alive: a newer
      # owner that has died since is stealable, not "another gate".
      GATE_LOCK_OWNER=""
      case "$holder" in
        ''|*[!0-9]*) ;;
        *) kill -0 "$holder" 2>/dev/null && GATE_LOCK_OWNER="$holder" ;;
      esac
      return 2
    fi
    # Unique per attempt: a leftover aside from a killed steal must never be
    # THIS steal's target (mv into an existing directory nests instead of
    # failing).
    local aside="$canonical.stale.$$.$RANDOM.$(date +%s)"
    GATE_LOCK_ASIDE="$aside"
    if ! mv "$canonical" "$aside" 2>/dev/null; then
      gate_lock_drop_marker
      GATE_LOCK_ASIDE=""
      rm -rf "$temp"; GATE_LOCK_TEMP=""
      GATE_LOCK_OWNER=""
      return 2
    fi
    # The marker moved with the dead lock: it goes with the aside.
    GATE_LOCK_MARKER=""
    rm -rf "$aside" 2>/dev/null || true
    GATE_LOCK_ASIDE=""
    # The takeover is an event an operator debugging a lock must SEE: the
    # docs promise a warning, and a silent steal leaves "why did my lock
    # disappear" unanswerable. (stderr only: stdout is the caller's report.)
    printf 'ci-gate-lock: warning: stale lock at %s (owner pid %s is dead); taking it over\n' \
      "$canonical" "${holder:-?}" >&2
  fi

  # Atomic claim: rename onto an absent path succeeds once; onto a path that
  # became non-empty in between it fails (rename(2) semantics), so exactly one
  # contender's temp directory becomes the canonical lock.
  if ! mv "$temp" "$canonical" 2>/dev/null; then
    if [ -d "$temp" ] && [ -d "$canonical/$(basename "$temp")" ]; then
      # mv nested it (the target existed as a directory): nobody claimed it.
      rm -rf "$canonical/$(basename "$temp")" 2>/dev/null || true
    fi
    rm -rf "$temp" 2>/dev/null || true
    GATE_LOCK_TEMP=""
    return 2
  fi

  # Verify: only the pid readable at the canonical path owns the gate.
  # GATE_LOCK_TEMP is kept set until ownership is confirmed, so an interrupt
  # between the rename and GATE_LOCK_HELD=1 still releases this lock instead
  # of leaking it.
  holder="$(cat "$canonical/pid" 2>/dev/null || true)"
  if [ "$holder" != "$$" ]; then
    # mv nests into an existing directory target (BSD/GNU behavior): if ours
    # ended up inside the canonical lock, it is not ours to keep.
    rm -rf "$canonical/$(basename "$temp")" 2>/dev/null || true
    rm -rf "$temp" 2>/dev/null || true
    GATE_LOCK_TEMP=""
    return 2
  fi
  GATE_LOCK_HELD=1
  GATE_LOCK_HELD_DIR="$canonical"
  GATE_LOCK_TEMP=""
  return 0
}
