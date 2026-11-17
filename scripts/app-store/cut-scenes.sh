#!/usr/bin/env bash
#
# Cut the demo video recording (demo-videos.yml) into one MP4 per scene, from
# the `SCENE start <name> <time>` and `SCENE end <name> <time>` lines
# DemoVideoTests prints. Full length, 30 fps H.264, the simulator's own size,
# no audio: ready for a Reddit post, or to trim further.
#
# recordVideo writes frames only when the screen changes and its first frame
# comes late, so the video is dated from its end: the test makes a last change
# on screen, prints the `SCENE stop all` mark and stops the recorder through
# demo_director.py's stop-recording, so the video ends at that mark.
# Its timestamps need -fflags +igndts: it repeats a few frame times, and
# ffmpeg then falls back to packet times that lag by up to 44 s.
#
# Usage: cut-scenes.sh RAW.mov MARKS OUT_DIR [LEAD_SECONDS]
set -euo pipefail
raw="$1"; marks="$2"; out="$3"; lead="${4:-0.5}"
mkdir -p "$out"
stop=$(awk '$1 == "SCENE" && $2 == "stop" {print $4}' "$marks" | tail -1)
[ -n "$stop" ] || { echo "$marks has no SCENE stop mark" >&2; exit 1; }
duration=$(ffprobe -v error -fflags +igndts -show_entries format=duration -of csv=p=0 "$raw")
record=$(python3 -c "print($stop - $duration)")
cut=0
while read -r name start; do
  end=$(awk -v n="$name" '$1 == "SCENE" && $2 == "end" && $3 == n {print $4}' "$marks" | tail -1)
  [ -n "$end" ] || { echo "scene $name has no end mark" >&2; continue; }
  from=$(python3 -c "print(max(0.0, $start - $record - $lead))")
  length=$(python3 -c "print($end - $record - $from + $lead)")
  ffmpeg -nostdin -v error -y -fflags +igndts -ss "$from" -t "$length" -i "$raw" \
    -vf "fps=30,format=yuv420p" -c:v libx264 -profile:v high -crf 18 -an -movflags +faststart \
    "$out/$name.mp4"
  echo "$out/$name.mp4: ${length}s from ${from}s"
  cut=$((cut + 1))
done < <(awk '$1 == "SCENE" && $2 == "start" {print $3, $4}' "$marks")
[ "$cut" -gt 0 ] || { echo "no scenes cut from $raw" >&2; exit 1; }
