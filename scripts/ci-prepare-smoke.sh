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
sleep $(( 3 * ${GATE_SLEEP_SCALE:-1} ))

boot_s=0
readiness_s=0
boot_confirmed=false
if [ -n "${SIMULATOR_UDID:-}" ]; then
  started=$(date +%s)
  bounded_run 60 xcrun simctl boot "$SIMULATOR_UDID" || true
  boot_s=$(( $(date +%s) - started ))
  started=$(date +%s)
  if bounded_run 200 xcrun simctl bootstatus "$SIMULATOR_UDID" -b; then
    boot_confirmed=true
  else
    echo "::warning::simulator bootstatus did not confirm - letting xcodebuild boot the destination itself"
  fi
  readiness_s=$(( $(date +%s) - started ))
else
  echo "::warning::could not resolve simulator UDID - letting xcodebuild boot the destination itself"
fi

printf 'DESTINATION=%s\n' "$DESTINATION" >> "$GITHUB_ENV"
printf 'SIMULATOR_UDID=%s\n' "${SIMULATOR_UDID:-}" >> "$GITHUB_ENV"
# Reporting is best-effort and is outside the four measured preparation phases.
python3 - "$LOG_DIR" "${SIMULATOR_UDID:-}" "$lookup_s" "$shutdown_s" "$boot_s" "$readiness_s" "$boot_confirmed" "$SIMULATOR_INVENTORY_CACHE" <<'PY' || echo "::warning::simulator preparation reporting unavailable - destination remains prepared"
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
doc = {"udid": udid or None, "runtime": runtime, "seconds": seconds, "boot_confirmed": sys.argv[7] == "true"}
with open(os.path.join(log_dir, "preparation.json"), "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
summary = "### Hosted simulator preparation\n\nDevice: `{}`; runtime: `{}`; boot confirmed: {}.\n\n".format(udid or "name fallback", runtime, doc["boot_confirmed"])
summary += "| Phase | Seconds |\n|---|---:|\n" + "".join("| {} | {} |\n".format(phase, value) for phase, value in seconds.items())
summary += "\nThe existing 3-second settle delay is additional to these phases.\n"
print(summary)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
        fh.write(summary)
PY
