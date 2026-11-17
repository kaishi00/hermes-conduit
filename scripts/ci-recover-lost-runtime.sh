#!/usr/bin/env bash
# Answers whether a failed hosted test invocation lost its simulator runtime
# before any test ran, and if so records why and reboots the device, so the
# caller can run that invocation once more.
#
#   bash scripts/ci-recover-lost-runtime.sh <xcodebuild log>
#
# Exit 0: the log has the lost-runtime signature and no test ran; the
# diagnostics are printed and the device was rebooted. Retry once.
# Exit 1: anything else (a real failure, or a test already ran). Don't retry.
#
# The 2026-11-17 Nightly lost two of its five test jobs this way: the iOS 27.2
# runtime that the device had booted on was gone at install, every invocation
# failed in seconds with "The iOS 27.2 simulator runtime is not available ...
# runtime path not found", while `simctl list runtimes` still listed it and
# the other jobs on the same image ran. No test runs before the install, so a
# second attempt is not a retry of a test; the job still fails if it fails
# again, and the diagnostics say which runtime path went missing.
set -uo pipefail

log="${1:-}"
[ -n "$log" ] && [ -f "$log" ] || exit 1
grep -q 'simulator runtime is not available' "$log" || exit 1
# A test case already started: whatever failed, it is not the install.
if grep -qE "^Test Case '" "$log"; then
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${LOG_DIR:-$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lost-runtime.XXXXXX")}"
mkdir -p "$LOG_DIR"
export LOG_DIR
# shellcheck source=ci-lib.sh
source "$SCRIPT_DIR/ci-lib.sh"

echo "::warning title=Simulator runtime lost::the destination's simulator runtime was not available at install (no test ran); rebooting ${SIMULATOR_UDID:-the device} and running the invocation once more"
echo "::group::simulator runtime diagnostics"
if bounded_run 60 xcrun simctl list runtimes -j; then
  runtimes_json="$BOUNDED_OUTPUT"
  # Each iOS runtime's bundle path, and whether it is on disk now.
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$runtimes_json" \
      | jq -r '.runtimes[]? | select(.identifier | test("iOS")) | "\(.identifier) \(.buildversion // "?") \(.bundlePath // "-")"' 2>/dev/null \
      | while read -r identifier build path; do
          if [ -e "$path" ]; then state="present"; else state="MISSING"; fi
          echo "$identifier ($build): $path [$state]"
        done | tee "$LOG_DIR/lost-runtime-paths.txt"
    # Kept on the run page too: a recovered loss leaves the job green, and
    # nobody opens a green job's log.
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "### Simulator runtime lost before any test ran (rebooted, ran once more)"
        echo '```'
        cat "$LOG_DIR/lost-runtime-paths.txt"
        echo '```'
      } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
    fi
  else
    printf '%s\n' "$runtimes_json"
  fi
fi
bounded_run 60 xcrun simctl runtime list && printf '%s\n' "$BOUNDED_OUTPUT"
df -h / 2>/dev/null || true
echo "::endgroup::"

reset_and_boot_simulator 0 || true
exit 0
