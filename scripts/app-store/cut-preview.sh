#!/usr/bin/env bash
#
# Cut a raw preview recording (app-store-screenshots.yml) into an App
# Preview: from just before PREVIEW_MARK start to PREVIEW_MARK end, at most
# 30 s (a longer flow loses its start, never the answer), 30 fps H.264
# with a silent stereo track, scaled to Apple's preview size for the device.
#
# Usage: cut-preview.sh RAW.mov MARKS OUT.mp4 WIDTHxHEIGHT [LEAD_SECONDS]
#   iPhone 6.9": 886x1920   iPad 13": 1200x1600
set -euo pipefail
raw="$1"; marks="$2"; out="$3"; size="$4"; lead="${5:-2}"
record=$(awk '$1 == "RECORD_START" {print $2}' "$marks")
start=$(awk '$2 == "start" {print $3}' "$marks")
end=$(awk '$2 == "end" {print $3}' "$marks")
[ -n "$record" ] && [ -n "$start" ] && [ -n "$end" ] || { echo "$marks lacks a RECORD_START, start or end mark" >&2; exit 1; }
from=$(python3 -c "print(max(0.0, $start - $record - $lead, $end - $record - 30.0))")
length=$(python3 -c "print(min(30.0, $end - $record - $from))")
w=${size%x*}; h=${size#*x}
ffmpeg -v error -y -ss "$from" -t "$length" -i "$raw" \
  -f lavfi -t "$length" -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -vf "fps=30,scale=$w:$h:force_original_aspect_ratio=decrease,pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p" \
  -c:v libx264 -profile:v high -crf 18 -c:a aac -b:a 128k -shortest -movflags +faststart "$out"
echo "$out: ${length}s from ${from}s"
