#!/usr/bin/env bash
#
# Shard-membership guard for CI.
#
# Every XCTestCase subclass under ConduitTests/ and ConduitUITests/ must be
# assigned to exactly one lane in scripts/test-shards.txt. Without this check
# a newly added test class would silently run in NO shard and lose coverage.
#
# Also enforces lane/target consistency against the ON-DISK target directory
# (not just the class-name suffix): classes under ConduitUITests/ must be in
# the 'ui' lane, unit lanes must only contain ConduitTests classes, and every
# lane the workflow expects (unit-a..unit-d, ui) must be non-empty.
#
# Needs only bash + grep + awk (runs on ubuntu, macOS, and git-bash).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARD_FILE="$SCRIPT_DIR/test-shards.txt"

fail=0

die() {
  echo "::error::$1"
  fail=1
}

# 1. XCTest classes on disk, discovered PER TARGET DIRECTORY so lane
#    assignment can be verified against where a class really lives (not just
#    its name). Only direct XCTestCase subclass declarations of the form
#    "class Foo: XCTestCase" on a single line are matched — the convention in
#    this repo; helper classes inside test files subclass app protocols
#    (services, URLProtocol, …), and the ':' anchor keeps anything that merely
#    mentions XCTestCase elsewhere (e.g. MyXCTestCaseHelper) from matching.
class_re='class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[^;{]*:[[:space:]]*XCTestCase'
scan_classes() {
  grep -rhoE "$class_re" "$1" --include='*.swift' \
    | sed -E 's/^.*class[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*$/\1/' \
    | sort -u
}
unit_dir_classes="$(scan_classes "$ROOT/ConduitTests")"
ui_dir_classes="$(scan_classes "$ROOT/ConduitUITests")"
on_disk="$(printf '%s\n%s\n' "$unit_dir_classes" "$ui_dir_classes" | sort -u)"

if [ -z "$on_disk" ]; then
  die "no XCTestCase subclasses found under ConduitTests/ or ConduitUITests/ — checker regex broken?"
fi

# 2. Assignments declared in the shard file. CRLF-normalized first so a
#    Windows-authored checkout cannot poison class names with a trailing \r.
shard_data="$(tr -d '\r' < "$SHARD_FILE")"
malformed="$(printf '%s\n' "$shard_data" | awk '!/^[[:space:]]*(#|$)/ && NF != 2 {print NR": "$0}')"
if [ -n "$malformed" ]; then
  die "malformed lines in test-shards.txt (expected '<lane> <ClassName>'): $malformed"
fi

assignments="$(printf '%s\n' "$shard_data" | awk '!/^[[:space:]]*(#|$)/ {print $1, $2}')"
if [ -z "$assignments" ]; then
  die "no assignments found in test-shards.txt"
fi

# 3. Every class on disk must be assigned exactly once.
declared="$(printf '%s\n' "$assignments" | awk '{print $2}' | sort)"
duplicates="$(printf '%s\n' "$declared" | uniq -d)"
if [ -n "$duplicates" ]; then
  die "classes assigned to more than one lane: $(echo "$duplicates" | tr '\n' ' ')"
fi

missing="$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$on_disk"))"
if [ -n "$missing" ]; then
  die "test classes missing from test-shards.txt (add them to a lane): $(echo "$missing" | tr '\n' ' ')"
fi

stale="$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$on_disk"))"
if [ -n "$stale" ]; then
  die "test-shards.txt lists classes that no longer exist (remove or rename): $(echo "$stale" | tr '\n' ' ')"
fi

# 4. Lane/target consistency, verified against the ON-DISK target directory
#    (the real source of truth), not merely the class-name suffix: a
#    ConduitTests class assigned to 'ui' (or vice versa) fails here before it
#    can burn a macOS build on a wrong-target -only-testing identifier.
known_lanes="unit-a unit-b unit-c unit-d ui"
while read -r lane cls; do
  case " $known_lanes " in
    *" $lane "*) ;;
    *) die "unknown lane '$lane' in test-shards.txt (expected: $known_lanes)"; continue ;;
  esac
  case "$lane" in
    ui) want_dir="ConduitUITests"; want_list="$ui_dir_classes" ;;
    *)  want_dir="ConduitTests";  want_list="$unit_dir_classes" ;;
  esac
  if ! printf '%s\n' "$want_list" | grep -Fxq -- "$cls"; then
    die "class $cls is assigned to lane '$lane' but does not live under $want_dir/"
  fi
done <<EOF
$assignments
EOF

# 5. Every lane the CI matrix expects must be non-empty (an empty lane would
#    fail at runtime; catch it here with a clearer message).
total_in_lane=0
for lane in $known_lanes; do
  count="$(printf '%s\n' "$shard_data" | awk -v l="$lane" '$1 == l {n++} END {print n+0}')"
  if [ "$count" -eq 0 ]; then
    die "lane '$lane' has no classes assigned"
  fi
  total_in_lane=$(( total_in_lane + count ))
done

if [ "$fail" -ne 0 ]; then
  echo "shard check FAILED"
  exit 1
fi

echo "shard check OK: $(printf '%s\n' "$on_disk" | wc -l | tr -d ' ') test classes fully assigned"
printf '%s\n' "$shard_data" | awk '!/^[[:space:]]*(#|$)/ {c[$1]++} END {for (l in c) printf "  %s: %d classes\n", l, c[l]}' | sort
