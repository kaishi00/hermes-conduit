#!/usr/bin/env python3
"""Find each scene of the demo recording by its pictures, for cut-scenes.sh.

recordVideo writes frames only when the screen changes, so its timeline
drifts from the clock, by many seconds over a long recording. DemoVideoTests
saves a screenshot as each scene starts (`scene-<name>-start.png`) and ends
(`scene-<name>-end.png`); this looks for those frames in the video near where
the clock puts them, and prints `<name> <from> <length>` per scene (seconds
into the video). A scene whose pictures aren't found keeps the clock's place.

Usage: align_scenes.py RAW.mov MARKS STILLS_DIR LEAD_SECONDS
"""
import subprocess
import sys
from pathlib import Path

W, H = 48, 104      # small enough to be quick, big enough to tell screens apart
FPS = 5
WINDOW = 45.0       # seconds either side of the clock's guess
SAME = 3.0          # mean grey difference that still counts as the same screen
SETTLE = 3.0        # seconds of a scene's last screen kept in its cut


def frames(path, fps=None):
    args = ["ffmpeg", "-nostdin", "-v", "error", "-i", str(path)]
    vf = f"scale={W}:{H},format=gray"
    if fps:
        vf = f"fps={fps}," + vf
    args += ["-vf", vf, "-f", "rawvideo", "-"]
    data = subprocess.run(args, capture_output=True, check=True).stdout
    size = W * H
    return [data[i:i + size] for i in range(0, len(data) - size + 1, size)]


def diff(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def find(video, still, guess, first):
    """The frame index for `still` near `guess` (seconds): of the run of
    frames that look like it, its first frame (`first`) or its last."""
    lo = max(0, int((guess - WINDOW) * FPS))
    hi = min(len(video), int((guess + WINDOW) * FPS) + 1)
    if lo >= hi:
        return None
    scores = [(diff(video[i], still), i) for i in range(lo, hi)]
    best = min(scores)[0]
    if best > SAME * 2:
        return None
    # Among frames as close as the best, the one nearest the guess anchors
    # the run; then walk the run to its edge.
    near = [i for d, i in scores if d <= best + SAME]
    anchor = min(near, key=lambda i: abs(i / FPS - guess))
    step = -1 if first else 1
    i = anchor
    while 0 <= i + step < len(video) and diff(video[i + step], still) <= best + SAME:
        i += step
    return i


def main():
    raw, marks, stills, lead = sys.argv[1], sys.argv[2], Path(sys.argv[3]), float(sys.argv[4])
    start, end, stop = {}, {}, None
    order = []
    for line in Path(marks).read_text().splitlines():
        part = line.split()
        if len(part) != 4 or part[0] != "SCENE":
            continue
        if part[1] == "start":
            start[part[2]] = float(part[3])
            order.append(part[2])
        elif part[1] == "end":
            end[part[2]] = float(part[3])
        elif part[1] == "stop":
            stop = float(part[3])
    video = frames(raw, FPS)
    duration = len(video) / FPS
    record = stop - duration if stop else None
    for name in order:
        if name not in end:
            continue
        guess_from = start[name] - record if record is not None else None
        guess_to = end[name] - record if record is not None else None
        a = b = None
        start_png = stills / f"scene-{name}-start.png"
        end_png = stills / f"scene-{name}-end.png"
        if guess_from is not None and start_png.is_file():
            got = frames(start_png)
            if got:
                a = find(video, got[0], guess_from, first=False)
        if guess_to is not None and end_png.is_file():
            got = frames(end_png)
            if got:
                b = find(video, got[0], guess_to, first=True)
        length = end[name] - start[name]
        if a is not None:
            begin = a / FPS
        elif b is not None:
            begin = b / FPS - length
        else:
            begin = guess_from if guess_from is not None else 0.0
        finish = b / FPS + SETTLE if b is not None else begin + length
        if finish <= begin:
            finish = begin + length
        begin = max(0.0, begin - lead)
        finish = min(duration, finish + lead)
        how = ("start" if a is not None else "") + ("+end" if b is not None else "")
        print(f"{name} {begin:.2f} {finish - begin:.2f} {how or 'clock'}")


if __name__ == "__main__":
    main()
