#!/usr/bin/env bash
#
# Regression tests for the destination-readiness lookup in scripts/ci-lib.sh.
#
# Covers the exact numeric-component OS matcher, the runtime-key version
# extraction, and the OS-qualified simulator_udid() end to end against a
# fixture `simctl list devices available -j` payload (bounded_run is
# overridden; no simulator, no real xcrun). The fixture carries iPhone 17 Pro
# on iOS 26.0, 26.1, and 26.10 so the 26.1-vs-26.10 discrimination is
# observable.
#
# jq is required only for the simulator_udid() fixture cases; on hosts
# without jq those cases are skipped (the pure-bash matcher cases always
# run). Usage: bash scripts/tests/test_simulator_destination.sh
# (exit 0 = all cases pass)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
CILIB="$SCRIPTS/ci-lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass_count=0
fail_count=0
skip_count=0

ok()   { pass_count=$((pass_count + 1)); echo "  ok: $1"; }
bad()  { fail_count=$((fail_count + 1)); echo "  FAIL: $1"; }
skipping() { skip_count=$((skip_count + 1)); echo "  skip: $1"; }

assert_eq() { # $1=desc $2=actual $3=expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}

assert_status() { # $1=desc $2=expected-status $3..=command
  local desc="$1" expected="$2"
  shift 2
  "$@" >/dev/null 2>&1
  if [ "$?" -eq "$expected" ]; then ok "$desc"; else bad "$desc (expected exit $expected)"; fi
}

echo "# os_version_matches: exact numeric components"

resolve_matches() { # $1= wanted, $2= actual -> prints yes/no
  ( set -u
    # shellcheck disable=SC1090
    source "$CILIB"
    if os_version_matches "$1" "$2"; then echo yes; else echo no; fi
  )
}

resolve_matches_missing_arg() { # zero-arg call must fail closed, not abort
  ( set -u
    # shellcheck disable=SC1090
    source "$CILIB"
    if os_version_matches; then echo yes; else echo no; fi
  )
}

assert_eq "identical single component matches"      "$(resolve_matches 26 26)"        yes
assert_eq "identical two components match"          "$(resolve_matches 26.0 26.0)"    yes
assert_eq "26.1 does not match 26.10"               "$(resolve_matches 26.1 26.10)"   no
assert_eq "26.10 does not match 26.1"               "$(resolve_matches 26.10 26.1)"   no
assert_eq "26 does not match 26.0 (no padding)"     "$(resolve_matches 26 26.0)"      no
assert_eq "26.0 does not match 26 (no shortening)"  "$(resolve_matches 26.0 26)"      no
assert_eq "26.0 does not match 26.0.1"              "$(resolve_matches 26.0 26.0.1)"  no
assert_eq "three identical components match"        "$(resolve_matches 26.0.1 26.0.1)" yes
assert_eq "9 vs 10 does not match"                  "$(resolve_matches 9.0 10.0)"     no
assert_eq "empty wanted never matches"              "$(resolve_matches '' 26.0)"      no
assert_eq "non-numeric wanted never matches"        "$(resolve_matches 26.x 26.0)"    no
assert_eq "non-numeric actual never matches"        "$(resolve_matches 26.0 26-0)"    no
assert_eq "dot-only wanted never matches"           "$(resolve_matches . .)"          no
assert_eq "leading dot never matches"               "$(resolve_matches .26.0 26.0)"   no
assert_eq "trailing dot never matches"              "$(resolve_matches 26.0. 26.0)"   no
assert_eq "double dot never matches"                "$(resolve_matches 26..0 26.0)"   no
assert_eq "missing argument fails closed under set -u" \
  "$(resolve_matches_missing_arg)"                  no

echo "# simruntime_version: runtime key normalization"

runtime_version() { # $1= key -> prints version or RUNTIME_KEY_REJECTED
  ( set -u
    # shellcheck disable=SC1090
    source "$CILIB"
    if ! simruntime_version "$1"; then
      echo RUNTIME_KEY_REJECTED
    fi
  )
}

assert_eq "iOS runtime key extracts dotted version" \
  "$(runtime_version com.apple.CoreSimulator.SimRuntime.iOS-26-0)" "26.0"
assert_eq "two-digit minor is preserved verbatim" \
  "$(runtime_version com.apple.CoreSimulator.SimRuntime.iOS-26-10)" "26.10"
assert_eq "non-iOS runtime key is rejected" \
  "$(runtime_version com.apple.CoreSimulator.SimRuntime.tvOS-26-0)" RUNTIME_KEY_REJECTED
assert_eq "arbitrary string is rejected" \
  "$(runtime_version garbage)" RUNTIME_KEY_REJECTED

echo "# simulator_udid: OS-qualified lookup against fixture payload"

cat > "$WORK/devices.json" <<'EOF'
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-0" : [
      { "udid" : "UDID-26-0-PRO",    "name" : "iPhone 17 Pro", "state" : "Shutdown" },
      { "udid" : "UDID-26-0-SIXTEEN","name" : "iPhone 16 Pro", "state" : "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-1" : [
      { "udid" : "UDID-26-1-PRO",    "name" : "iPhone 17 Pro", "state" : "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-10" : [
      { "udid" : "UDID-26-10-PRO",   "name" : "iPhone 17 Pro", "state" : "Shutdown" }
    ]
  }
}
EOF

resolve_udid() { # $1=name $2=os ('' = unset) -> prints "OK <udid>" or "MISS"
  ( set -u
    SIMULATOR_NAME="$1"
    SIMULATOR_OS="$2"
    FIXTURE="$WORK/devices.json"
    # shellcheck disable=SC1090
    source "$CILIB"
    # Override the real probe: the fixture payload IS the simctl output.
    bounded_run() { BOUNDED_OUTPUT="$(cat "$FIXTURE")"; return 0; }
    if udid=$(simulator_udid); then
      printf 'OK %s\n' "$udid"
    else
      printf 'MISS\n'
    fi
  )
}

if ! command -v jq >/dev/null 2>&1; then
  skipping "simulator_udid fixture cases (jq not available on this host)"
else
  assert_eq "unset SIMULATOR_OS picks the newest matching runtime" \
    "$(resolve_udid 'iPhone 17 Pro' '')" "OK UDID-26-10-PRO"
  assert_eq "matching SIMULATOR_OS picks that exact runtime" \
    "$(resolve_udid 'iPhone 17 Pro' 26.1)" "OK UDID-26-1-PRO"
  assert_eq "older matching runtime resolves too" \
    "$(resolve_udid 'iPhone 17 Pro' 26.0)" "OK UDID-26-0-PRO"
  assert_eq "26.10 is pinned exactly (26.1 cannot satisfy it)" \
    "$(resolve_udid 'iPhone 17 Pro' 26.10)" "OK UDID-26-10-PRO"
  assert_eq "OS major-only form never falls back to a runtime" \
    "$(resolve_udid 'iPhone 17 Pro' 26)" "MISS"
  assert_eq "unavailable OS fails despite the name existing elsewhere" \
    "$(resolve_udid 'iPhone 17 Pro' 26.2)" "MISS"
  assert_eq "name on another runtime is not substituted" \
    "$(resolve_udid 'iPhone 16 Pro' 26.1)" "MISS"
  assert_eq "unknown device name fails with OS pin" \
    "$(resolve_udid 'iPhone 99 Pro' 26.0)" "MISS"
  assert_eq "unknown device name fails without OS pin" \
    "$(resolve_udid 'iPhone 99 Pro' '')" "MISS"
fi

echo "# build_destination: UDID-pinned destination with name-based fallback"

resolve_destination() { # $1=name $2=os ('' = unset) $3=resolve-ok(1/0)
  ( set -u
    SIMULATOR_NAME="$1"
    SIMULATOR_OS="$2"
    FIXTURE="$WORK/devices.json"
    # shellcheck disable=SC1090
    source "$CILIB"
    if [ "$3" = "1" ]; then
      bounded_run() { BOUNDED_OUTPUT="$(cat "$FIXTURE")"; return 0; }
    else
      # A wedged CoreSimulatorService / missing jq: the UDID cannot be
      # resolved and the historical name-based form must come back.
      bounded_run() { return 1; }
    fi
    build_destination >/dev/null
    printf '%s\n' "$DESTINATION"
  )
}

if ! command -v jq >/dev/null 2>&1; then
  skipping "build_destination fixture cases (jq not available on this host)"
else
  assert_eq "destination pins the resolved device UDID" \
    "$(resolve_destination 'iPhone 17 Pro' '' 1)" \
    "platform=iOS Simulator,id=UDID-26-10-PRO"
  assert_eq "OS pin carries into the resolved destination" \
    "$(resolve_destination 'iPhone 17 Pro' 26.0 1)" \
    "platform=iOS Simulator,id=UDID-26-0-PRO"
  assert_eq "unresolvable UDID falls back to the name-based destination" \
    "$(resolve_destination 'iPhone 17 Pro' '' 0)" \
    "platform=iOS Simulator,name=iPhone 17 Pro"
  assert_eq "OS pin survives in the fallback destination" \
    "$(resolve_destination 'iPhone 17 Pro' 26.1 0)" \
    "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1"
fi

echo "# bash syntax gate"

assert_status "ci-lib.sh parses" 0 bash -n "$CILIB"

echo
echo "passed: $pass_count  failed: $fail_count  skipped: $skip_count"
if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
