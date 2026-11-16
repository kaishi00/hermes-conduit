#!/usr/bin/env bash
# Hosted-only preparation: keep the local gate's preparation/recovery unchanged.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-ci-lane/destination}"
mkdir -p "$LOG_DIR"
export LOG_DIR
source "$SCRIPT_DIR/ci-lib.sh"

# A fresh diagnostic file avoids stale runtime metadata when resolution falls
# back. Only successful destination lookups write it; no post-boot probe runs.
if ! SIMULATOR_INVENTORY_CACHE=$(mktemp "$LOG_DIR/devices.XXXXXX"); then
  SIMULATOR_INVENTORY_CACHE=""
  echo "::warning::simulator inventory cache unavailable - runtime reporting may be unknown"
fi
export SIMULATOR_INVENTORY_CACHE

disable_pasteboard_sync || echo "::warning::could not disable pasteboard sync - continuing best-effort"
started=$(date +%s)
wait_for_destination_device
if udid=$(resolve_own_udid) && [ -n "$udid" ]; then
  export SIMULATOR_UDID="$udid"
fi
build_destination
lookup_s=$(( $(date +%s) - started ))

started=$(date +%s)
if ! shutdown_own_simulator; then
  echo "::warning::own-device shutdown unavailable - continuing best-effort (xcodebuild boots the destination itself)"
fi
shutdown_s=$(( $(date +%s) - started ))
sleep $(( 3 * $(decimal_seconds "${GATE_SLEEP_SCALE:-}" 1) ))

# The warm-device seed (SIM_SEED_DIR, restored and saved by the workflow).
# A device's first boot runs iOS's data migration, 80-300 s of a 3-core
# runner with the build waiting on it (2026-11-15: 230 s median over 57
# Smoke runs, and half of them outran bootstatus's 200 s). The seed is the
# device's data folder right after one finished first boot, before anything
# is installed, so a restored device boots as an already-migrated one.
seed_s=0
seed_state=off
# A job that can't save a seed (SIM_SEED_RESTORE_ONLY) never spends a second
# boot making one. A seed that can't be used is made again, and the workflow
# saves it as a newer generation the next restore picks.
seed_miss=create
if [ "${SIM_SEED_RESTORE_ONLY:-}" = 1 ]; then seed_miss=skipped; fi
if [ -n "${SIM_SEED_DIR:-}" ] && [ -n "${SIMULATOR_UDID:-}" ]; then
  device_dir="$HOME/Library/Developer/CoreSimulator/Devices/$SIMULATOR_UDID"
  seed_state=$seed_miss
  if [ -f "$SIM_SEED_DIR/data.tar" ] && [ "$(cat "$SIM_SEED_DIR/udid" 2>/dev/null)" = "$SIMULATOR_UDID" ]; then
    started=$(date +%s)
    # The device's folder is replaced only while it is shut down: the
    # shutdown above is best-effort.
    if ! bounded_run 60 xcrun simctl list devices \
       || ! printf '%s\n' "$BOUNDED_OUTPUT" | grep -F "($SIMULATOR_UDID)" | grep -qF "(Shutdown)"; then
      echo "::warning::the device isn't shut down - booting it cold, without the warm-device seed"
      seed_state=failed
    elif rm -rf "$device_dir/data" && tar -xf "$SIM_SEED_DIR/data.tar" -C "$device_dir"; then
      seed_state=restored
    else
      # A half-restored device can't boot; erase gives back the image's own.
      echo "::warning::could not restore the warm-device seed - erasing the device and booting it cold"
      bounded_run 120 xcrun simctl erase "$SIMULATOR_UDID" || true
      seed_state=$seed_miss
    fi
    seed_s=$(( $(date +%s) - started ))
  elif [ -f "$SIM_SEED_DIR/data.tar" ]; then
    echo "::warning::the warm-device seed is for another device - booting cold"
  fi
  if [ "$seed_state" = create ]; then rm -f "$SIM_SEED_DIR/data.tar" "$SIM_SEED_DIR/udid"; fi
fi

boot_s=0
readiness_s=0
boot_confirmed=false
if [ -n "${SIMULATOR_UDID:-}" ]; then
  started=$(date +%s)
  bounded_run 60 xcrun simctl boot "$SIMULATOR_UDID" || true
  boot_s=$(( $(date +%s) - started ))
  started=$(date +%s)
  # A seed is taken only from a finished migration, so making one waits
  # longer for it, once per runner image.
  readiness_budget=200
  if [ "$seed_state" = create ]; then readiness_budget=420; fi
  if bounded_run "$readiness_budget" xcrun simctl bootstatus "$SIMULATOR_UDID" -b; then
    boot_confirmed=true
  else
    echo "::warning::simulator bootstatus did not confirm - letting xcodebuild boot the destination itself"
  fi
  readiness_s=$(( $(date +%s) - started ))
  if [ "$seed_state" = create ] && [ "$boot_confirmed" = true ]; then
    # Shut down so the folder is consistent, keep it, and boot again warm.
    started=$(date +%s)
    seed_state=create-failed
    if bounded_run 60 xcrun simctl shutdown "$SIMULATOR_UDID" \
       && mkdir -p "$SIM_SEED_DIR" \
       && tar -cf "$SIM_SEED_DIR/data.tar" -C "$device_dir" data \
       && printf '%s\n' "$SIMULATOR_UDID" > "$SIM_SEED_DIR/udid"; then
      echo "warm-device seed: $(du -sh "$SIM_SEED_DIR/data.tar" | cut -f1)"
    else
      rm -f "$SIM_SEED_DIR/data.tar" "$SIM_SEED_DIR/udid"
      echo "::warning::could not save the warm-device seed"
    fi
    bounded_run 60 xcrun simctl boot "$SIMULATOR_UDID" || true
    if bounded_run 200 xcrun simctl bootstatus "$SIMULATOR_UDID" -b; then
      # Saved only once the device booted from it.
      if [ -f "$SIM_SEED_DIR/data.tar" ]; then
        seed_state=created
        printf 'SIM_SEED_CREATED=1\n' >> "$GITHUB_ENV"
      fi
    else
      boot_confirmed=false
      echo "::warning::simulator bootstatus did not confirm after the seed - letting xcodebuild boot the destination itself, and not saving the seed"
    fi
    seed_s=$(( $(date +%s) - started ))
  fi
  # What the boot waited on: bootstatus names each stage as it waits.
  echo "bootstatus (last lines):"
  printf '%s\n' "$BOUNDED_OUTPUT" | tail -n 25
else
  echo "::warning::could not resolve simulator UDID - letting xcodebuild boot the destination itself"
fi

printf 'DESTINATION=%s\n' "$DESTINATION" >> "$GITHUB_ENV"
printf 'SIMULATOR_UDID=%s\n' "${SIMULATOR_UDID:-}" >> "$GITHUB_ENV"
# Reporting is best-effort and is outside the four measured preparation phases.
python3 - "$LOG_DIR" "${SIMULATOR_UDID:-}" "$lookup_s" "$shutdown_s" "$boot_s" "$readiness_s" "$boot_confirmed" "$SIMULATOR_INVENTORY_CACHE" "$seed_state" "$seed_s" <<'PY' || echo "::warning::simulator preparation reporting unavailable - destination remains prepared"
import json
import os
import sys
log_dir, udid = sys.argv[1:3]
runtime = "unknown"
try:
    with open(sys.argv[8]) as fh:
        devices = json.load(fh)["devices"]
    runtime = next((rt for rt, rows in devices.items() if any(row.get("udid") == udid for row in rows)), runtime)
except (OSError, ValueError, KeyError, TypeError):
    pass
seconds = dict(zip(("lookup", "shutdown", "boot", "boot_readiness"), map(int, sys.argv[3:7])))
seconds["warm_seed"] = int(sys.argv[10])
seed = sys.argv[9]
doc = {"udid": udid or None, "runtime": runtime, "seconds": seconds, "boot_confirmed": sys.argv[7] == "true", "warm_seed": seed}
with open(os.path.join(log_dir, "preparation.json"), "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
summary = "### Hosted simulator preparation\n\nDevice: `{}`; runtime: `{}`; boot confirmed: {}; warm-device seed: {}.\n\n".format(udid or "name fallback", runtime, doc["boot_confirmed"], seed)
summary += "| Phase | Seconds |\n|---|---:|\n" + "".join("| {} | {} |\n".format(phase, value) for phase, value in seconds.items())
summary += "\nThe existing 3-second settle delay is additional to these phases.\n"
print(summary)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
        fh.write(summary)
PY
