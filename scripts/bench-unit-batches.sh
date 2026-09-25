#!/usr/bin/env bash
#
# Unit-suite batch-size benchmark (the measurement behind the gate's
# --unit-batch-max-classes default).
#
# What it measures: for a fixed set of already-built test products, how the
# unit suite's wall clock splits between ACTUAL XCTest execution and the fixed
# cost of an xcodebuild/CoreSimulator/test-host startup - as a function of how
# many classes are packed into one `test-without-building` invocation.
#
# Why it exists: the planner's hosted policy caps a unit batch at 7 classes
# (MAX_UNIT_CLASSES_PER_XCODEBUILD_BATCH), which came from stall diagnostics on
# SHARED GitHub runners. The Mac gate runs on our own machine, where the same
# sweep measured ~4s of startup per invocation and no stall at any shape - so
# the gate pays for far fewer invocations (see docs/CI.md).
#
# Invariants it preserves while measuring (both are #205 requirements):
#   * the device is Booted + settled BEFORE any xcodebuild launches, and it is
#     never shut down between shapes - xcodebuild is never handed a Shutdown
#     destination;
#   * nothing is rebuilt: every shape runs the SAME .xctestrun products.
#
# Usage:
#   scripts/bench-unit-batches.sh --xctestrun FILE --udid UDID --classes FILE \
#       [--run-dir DIR] [--sizes 7,14,28,full]
#   scripts/bench-unit-batches.sh --summarize DIR
#
# Run it under the host simulator-test lease, as the gate does:
#   ~/.local/bin/ios-ci-host acquire simulator-test --project Conduit \
#     --workflow batch-benchmark --fail-if-busy --exec -- \
#     bash scripts/bench-unit-batches.sh ...
#
# --classes FILE is one class name per line, in the order the planner stored
# them (the gate's lanes/unit/lane-result.json "classes" array, or
# `plan-tests.py plan` output).

set -uo pipefail

USE="usage: bench-unit-batches.sh --xctestrun FILE --udid UDID --classes FILE [--run-dir DIR] [--sizes 7,14,28,full] | --summarize DIR"

XCTESTRUN=""; UDID=""; CLASSES_FILE=""; RUN_DIR=""; SIZES="7,14,28,full"; SUMMARIZE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --xctestrun) XCTESTRUN="$2"; shift 2 ;;
    --udid) UDID="$2"; shift 2 ;;
    --classes) CLASSES_FILE="$2"; shift 2 ;;
    --run-dir) RUN_DIR="$2"; shift 2 ;;
    --sizes) SIZES="$2"; shift 2 ;;
    --summarize) SUMMARIZE="$2"; shift 2 ;;
    -h|--help) echo "$USE"; exit 0 ;;
    *) echo "bench-unit-batches: unknown argument: $1" >&2; echo "$USE" >&2; exit 2 ;;
  esac
done

summarize() { # $1 = run dir
  python3 - "$1" <<'PY'
import glob, os, re, sys

SESSION = re.compile(
    r"IDETestOperationsObserverDebug: ([0-9.]+) elapsed -- Testing started completed")
EXECUTED = re.compile(
    r"Executed (\d+) tests?, with .* in ([0-9.]+) \(([0-9.]+)\) seconds")
# The signatures the launch wedge produces; a benchmark arm that shows any of
# them is not a valid data point regardless of its wall clock.
WEDGE = ("Application failed preflight", "Simulator device failed to launch",
         "reason: Busy", "FBSOpenApplicationServiceErrorDomain")

print("%-6s %4s %6s %4s %8s %10s %9s %8s %6s" % (
    "shape", "inv", "cls", "rc!=0", "wall_s", "session_s", "tests_s", "pre_s", "wedge"))
for arm in sorted(glob.glob(os.path.join(sys.argv[1], "arm-*"))):
    rows = []
    inv_path = os.path.join(arm, "invocations.tsv")
    if not os.path.exists(inv_path):
        continue
    with open(inv_path) as fh:
        for line in fh:
            if not line.strip():
                continue
            batch, nclasses, rc, wall = line.rstrip("\n").split("\t")
            log = os.path.join(arm, "batch-%03d.log" % int(batch))
            text = open(log, errors="replace").read() if os.path.exists(log) else ""
            session = max((float(m) for m in SESSION.findall(text)), default=0.0)
            tests = max((float(v) for _, v in EXECUTED.findall(text)), default=0.0)
            row = {"classes": int(nclasses), "rc": int(rc), "wall": int(wall),
                   "session": session, "tests": tests,
                   "wedge": sum(text.count(sig) for sig in WEDGE)}
            rows.append(row)
    if not rows:
        continue
    print("%-6s %4d %6d %4d %8d %10.1f %9.1f %8.1f %6d" % (
        os.path.basename(arm)[4:], len(rows), sum(r["classes"] for r in rows),
        sum(1 for r in rows if r["rc"] != 0), sum(r["wall"] for r in rows),
        sum(r["session"] for r in rows), sum(r["tests"] for r in rows),
        sum(r["session"] - r["tests"] for r in rows),
        sum(r["wedge"] for r in rows)))

print("")
print("pre_s = xcodebuild/CoreSimulator/test-host startup per invocation")
print("        (session_s - tests_s); it is what a batch size is trading against.")
PY
}

if [ -n "$SUMMARIZE" ]; then
  summarize "$SUMMARIZE"
  exit 0
fi

for required in "$XCTESTRUN" "$UDID" "$CLASSES_FILE"; do
  if [ -z "$required" ]; then
    echo "bench-unit-batches: $USE" >&2
    exit 2
  fi
done
[ -f "$XCTESTRUN" ] || { echo "no .xctestrun at $XCTESTRUN" >&2; exit 2; }
[ -s "$CLASSES_FILE" ] || { echo "no class list at $CLASSES_FILE" >&2; exit 2; }
if [ -z "$RUN_DIR" ]; then
  RUN_DIR="$(pwd)/bench-batches-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$RUN_DIR"
echo "== unit batch-size benchmark =="
echo "xctestrun: $XCTESTRUN"
echo "device   : $UDID"
echo "classes  : $(grep -c . "$CLASSES_FILE")"
echo "shapes   : $SIZES"
echo "run dir  : $RUN_DIR"

device_state() { # $1 = udid
  xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1].rstrip()
for devices in json.load(sys.stdin)["devices"].values():
    for dev in devices:
        if dev["udid"] == udid:
            print(dev["state"])
            raise SystemExit
print("Unknown")' "$1"
}

# Booted + settled BEFORE any xcodebuild: the whole point of keeping the device
# up across shapes is that xcodebuild never has to cold-boot it (#205).
if [ "$(device_state "$UDID")" != "Booted" ]; then
  echo "booting the pinned device"
  xcrun simctl boot "$UDID" || true
fi
if ! xcrun simctl bootstatus "$UDID" -b; then
  echo "::error::the device did not reach a settled boot - refusing to launch xcodebuild" >&2
  exit 2
fi
echo "device   : $UDID ($(device_state "$UDID"), settled)"

run_shape() { # $1 = class limit (or "full"), $2 = label
  local limit="$1" label="$2"
  local dir="$RUN_DIR/arm-$label"
  local batch=0 wall_start wall_end
  local -a group=()
  mkdir -p "$dir"
  : > "$dir/invocations.tsv"
  echo ""
  echo "== shape $label: at most $limit class(es) per invocation =="
  wall_start=$(date +%s)
  while IFS= read -r cls; do
    [ -z "$cls" ] && continue
    group+=("$cls")
    if [ "${#group[@]}" -ge "$limit" ]; then
      batch=$((batch + 1))
      run_batch "$dir" "$batch" "${group[@]}"
      group=()
    fi
  done < "$CLASSES_FILE"
  if [ "${#group[@]}" -gt 0 ]; then
    batch=$((batch + 1))
    run_batch "$dir" "$batch" "${group[@]}"
  fi
  wall_end=$(date +%s)
  echo "shape $label: $batch invocation(s), $((wall_end - wall_start))s wall"
  return 0
}

run_batch() { # $1=dir $2=batch-number, rest=classes
  local dir="$1" batch="$2"; shift 2
  local log="$dir/batch-$(printf '%03d' "$batch").log"
  local started finished rc
  local -a args=()
  local cls
  for cls in "$@"; do
    args+=("-only-testing:ConduitTests/${cls}")
  done
  started=$(date +%s)
  xcodebuild test-without-building \
    -xctestrun "$XCTESTRUN" \
    -destination "platform=iOS Simulator,id=$UDID,arch=arm64" \
    -parallel-testing-enabled NO \
    "${args[@]}" >"$log" 2>&1
  rc=$?
  finished=$(date +%s)
  printf '%s\t%s\t%s\t%s\n' "$batch" "$#" "$rc" "$((finished - started))" \
    >> "$dir/invocations.tsv"
  if [ "$rc" -ne 0 ]; then
    echo "  batch $batch: rc=$rc after $((finished - started))s"
    grep -m3 -E "Application failed preflight|Simulator device failed to launch|reason: Busy|error:" "$log" || true
  fi
  return 0
}

IFS=',' read -r -a SHAPES <<< "$SIZES"
for shape in "${SHAPES[@]}"; do
  case "$shape" in
    full) total=$(grep -c . "$CLASSES_FILE"); run_shape "$total" "full" ;;
    *) run_shape "$shape" "$shape" ;;
  esac
done

echo ""
summarize "$RUN_DIR"
