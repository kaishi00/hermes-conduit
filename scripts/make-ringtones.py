#!/usr/bin/env python3
"""Writes the ringtones Conduit ships for calls from Hermes (issue 2445).

CallKit rings with a sound file from the app bundle and loops it, so each
tone is a short phrase followed by a rest. They are synthesized here from
plain sine partials, so the app ships no recorded or licensed audio, and a
tone can be changed by editing its notes and running this again:

    python3 scripts/make-ringtones.py

The output is deterministic: the same script writes the same bytes.
"""

import argparse
import math
import struct
import wave
from pathlib import Path

RATE = 32_000
PEAK = 0.7

# Equal temperament, A4 = 440 Hz.
NOTES = {name: index for index, name in enumerate(["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"])}


def hz(note):
    """"E5" or "F#4" as a frequency."""
    name, octave = note[:-1], int(note[-1])
    return 440.0 * 2 ** ((NOTES[name] - 9) / 12 + (octave - 4))


def strike(frequency, length, partials, decay, attack=0.004):
    """One struck note: each partial is (ratio, level, decay scale)."""
    count = int(RATE * length)
    out = [0.0] * count
    for ratio, level, scale in partials:
        step = 2 * math.pi * frequency * ratio / RATE
        rate = decay * scale
        for index in range(count):
            time = index / RATE
            out[index] += level * math.exp(-time * rate) * math.sin(step * index)
    ramp = max(1, int(RATE * attack))
    tail = max(1, int(RATE * 0.02))
    for index in range(count):
        out[index] *= min(1.0, index / ramp, (count - 1 - index) / tail)
    return out


def held(frequencies, length, fade=0.03, tremolo=0.0):
    """Steady tones sounded together, faded at both ends."""
    count = int(RATE * length)
    ramp = max(1, int(RATE * fade))
    out = []
    for index in range(count):
        value = sum(math.sin(2 * math.pi * f * index / RATE) for f in frequencies) / len(frequencies)
        if tremolo:
            value *= 0.75 + 0.25 * math.sin(2 * math.pi * tremolo * index / RATE)
        out.append(value * min(1.0, index / ramp, (count - 1 - index) / ramp))
    return out


def place(track, samples, at):
    start = int(RATE * at)
    if len(track) < start + len(samples):
        track.extend([0.0] * (start + len(samples) - len(track)))
    for index, value in enumerate(samples):
        track[start + index] += value


BELL = [(1, 1.0, 1.0), (2.76, 0.45, 1.6), (5.4, 0.25, 2.4), (8.93, 0.12, 3.5)]
MALLET = [(1, 1.0, 1.0), (4, 0.3, 3.0), (10, 0.08, 6.0)]
SOFT = [(1, 1.0, 1.0), (2, 0.3, 1.5), (3, 0.1, 2.0)]
GLASS = [(1, 1.0, 1.0), (2, 0.5, 1.2), (3.01, 0.2, 2.0), (4.2, 0.1, 3.0)]


def chime():
    track = []
    for start in (0.0, 1.5):
        place(track, strike(hz("E6"), 1.4, BELL, 3.0), start)
        place(track, strike(hz("C6"), 1.6, BELL, 2.6), start + 0.42)
    return track, 4.2


def lantern():
    track = []
    for start in (0.0, 1.45):
        for step, note in enumerate(["C5", "E5", "G5", "C6"]):
            place(track, strike(hz(note), 0.9, MALLET, 6.0), start + step * 0.16)
    return track, 3.9


def ripple():
    track = []
    run = ["D5", "F#5", "A5", "B5", "D6", "B5", "A5", "F#5"]
    for start in (0.0, 1.5):
        for step, note in enumerate(run):
            place(track, strike(hz(note), 0.5, SOFT, 9.0), start + step * 0.11)
    return track, 3.8


def signal():
    track = []
    for start in (0.0, 0.55, 1.9, 2.45):
        place(track, held([440.0, 554.37], 0.4, tremolo=22.0), start)
    return track, 4.0


def beacon():
    track = []
    for step, note in enumerate(["A4", "E5", "A4", "E5"]):
        place(track, held([hz(note), hz(note) * 2.0], 0.5, fade=0.09), step * 0.62)
    return track, 3.9


def orbit():
    track = []
    phrase = [("G5", 0.0), ("B5", 0.18), ("D6", 0.36), ("B5", 0.72), ("E6", 0.9)]
    for start in (0.0, 1.7):
        for note, at in phrase:
            place(track, strike(hz(note), 0.9, GLASS, 4.5), start + at)
    return track, 4.4


TONES = {"chime": chime, "lantern": lantern, "ripple": ripple, "signal": signal, "beacon": beacon, "orbit": orbit}


def render(name):
    track, length = TONES[name]()
    count = int(RATE * length)
    track = (track + [0.0] * count)[:count]
    loudest = max(abs(value) for value in track) or 1.0
    scale = PEAK / loudest * 32767
    return struct.pack(f"<{count}h", *(int(round(value * scale)) for value in track))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "Conduit/Resources/Ringtones"))
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for name in TONES:
        with wave.open(str(out / f"ringtone-{name}.wav"), "wb") as file:
            file.setnchannels(1)
            file.setsampwidth(2)
            file.setframerate(RATE)
            file.writeframes(render(name))
        print(out / f"ringtone-{name}.wav")


if __name__ == "__main__":
    main()
