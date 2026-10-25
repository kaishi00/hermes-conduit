#!/usr/bin/env bash
#
# Record a short showcase clip (app-store-screenshots.yml) of one
# -conduitScreenshotCall fixture state: relaunch the app in that state,
# record the simulator screen, and keep the last SECONDS as a silent,
# web-ready H.264 MP4 for the README and the website.
#
# Needs ffmpeg and ffprobe. The recorder's log lands next to OUT.mp4.
#
# Usage: record-clip.sh UDID BUNDLE_ID STATE OUT.mp4 [SECONDS]
set -euo pipefail
udid="$1"; bundle="$2"; state="$3"; out="$4"; seconds="${5:-10}"
raw="${out%.mp4}.mov"
mkdir -p "$(dirname "$out")"
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
xcrun simctl io "$udid" recordVideo --codec h264 --force "$raw" > "${out%.mp4}.log" 2>&1 &
recorder=$!
# SIGINT lets the recorder finish the file; TERM if it ignores it. Also on
# an early exit, so a failed launch doesn't leave the recorder running.
stop_recorder() {
  kill -INT "$recorder" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$recorder" 2>/dev/null || break; sleep 1; done
  kill -TERM "$recorder" 2>/dev/null || true
  wait "$recorder" || true
}
# A clip that fails leaves no raw recording behind for the shots artifact.
trap 'stop_recorder; rm -f "$raw"' EXIT
# recordVideo's first frame comes seconds after it starts.
sleep 3
xcrun simctl launch "$udid" "$bundle" -conduitScreenshotCall "$state" >> "${out%.mp4}.log" 2>&1
sleep $((seconds + 4))
stop_recorder
[ -s "$raw" ] || { echo "$raw: nothing recorded" >&2; exit 1; }
# The raw file is variable frame rate, so trim with the filter, not -ss.
# recordVideo only writes a frame when the screen changes, so a still screen
# (the Watch approval card) records short: hold its last frame to SECONDS.
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$raw")
case "$duration" in
  ''|*[!0-9.]*) echo "$raw: ffprobe found no usable duration ($duration)" >&2; exit 1 ;;
esac
python3 -c "import sys; sys.exit(0 if $duration >= $seconds else 1)" \
  || echo "$raw: ${duration}s of changing frames; the last one is held to ${seconds}s" >&2
from=$(python3 -c "print(max(0.0, $duration - $seconds))")
ffmpeg -v error -y -i "$raw" \
  -filter_complex "fps=30,tpad=stop_mode=clone:stop_duration=$seconds,trim=start=$from:duration=$seconds,setpts=PTS-STARTPTS,format=yuv420p" \
  -an -c:v libx264 -profile:v high -crf 20 -movflags +faststart "$out"
echo "$out: ${seconds}s from ${from}s"
