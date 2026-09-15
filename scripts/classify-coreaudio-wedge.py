#!/usr/bin/env python3
"""CoreAudio host-wedge classifier for Hermes Conduit CI
(scripts/classify-coreaudio-wedge.py).

Decides whether a unit-lane invocation ran on the known broken
GitHub-hosted macOS CoreAudio HOST - in which case the lane runner may
reset the simulator and retry the affected scope exactly once - or the
failure belongs to the product.

This is a HOST-HEALTH classifier, not a test-class classifier. The wedge
is a property of the runner's audio server, not of any XCTest class: on a
poisoned host, ANY lane can stall or its timing-sensitive assertions can
flip. The old "failures must belong to an audio inventory" gate encoded
the wrong failure domain and was removed; there is no allowlist to grow.

The wedge does not fail loudly. It floods the invocation log with
`AURemoteIO.cpp:1135 failed: -10851` activation failures and HAL
`skipping cycle due to overload` lines, and the starvation flips
timing-sensitive assertions or hangs invocations outright.

Classification rule (one condition, evidence-calibrated - the counts are
per invocation log, i.e. per single xcodebuild invocation):

    AURemoteIO -10851 occurrences >= min-auremoteio (default 150)
        AND
    `skipping cycle due to overload` occurrences >= min-halc-overload
        (default 20)

Observed distributions (docs/CI.md carries the full table):

    healthy unit-1        aurioc ~8-22    overload ~0-2
    healthy unit-2        aurioc ~93-116  overload ~4-11  (ambient maximum)
    healthy unit-audio    aurioc 0        overload 0
    slow-timeout unit-1   aurioc ~48-102  overload ~2-11  (NOT the wedge)
    wedged unit-2         aurioc 178-189  overload 14-48

    The overload floor was recalibrated 10 < 20 after the 2026-09-14
    rerun of run 34901103097 showed a wedge variant at 186 / 14: the
    AURemoteIO flood is the reliable marker, the overload marker
    varies with wedge phase.

The joint AND with these margins fails closed: a single AURemoteIO line -
or the full healthy ambient volume - never classifies an invocation as
infrastructure. Thresholds are flag-overridable for recalibration; every
verdict document records the raw counts so incidents can be tracked.

Exit codes
----------
  0  CoreAudio host wedge: a clean-environment retry is authorized
  1  host healthy: the failure is the product's (fail closed)
  2  usage/IO error: the caller MUST treat this as "not a wedge"

The signature only ever AUTHORIZES one clean-host retry of the failed
scope. It never turns a failing test green by itself, and a retry that
carries the signature again is reported as a persistent CoreAudio runner
failure - an environment verdict, not a product claim.

Only Python 3 stdlib is used (runs on ubuntu and macOS runners).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys

DEFAULT_MIN_AUREMOTEIO = 150
DEFAULT_MIN_HALC_OVERLOAD = 10

# The exact observed record shape: AURemoteIO reporting the -10851 activation
# failure. A plain two-substring match could inflate counts on a benign line
# that merely mentions both tokens.
AUREMOTEIO_RE = re.compile(r"AURemoteIO.*failed:\s*-10851")
# HALC (CoreAudio HAL client proxy) reporting its IO work loop is overloaded:
# the host-side "audio server is drowning" marker. Rare on healthy hosts
# (<=7 per lane observed), burst-scale under the wedge (48 observed).
HALC_OVERLOAD_RE = re.compile(r"skipping cycle due to overload")
# Corroborating (reported, not gated): CHHapticEngine errors. 11 on healthy
# hosts vs 20 under the wedge - not discriminative enough to gate on.
CHHAPTIC_MARK = "CHHapticEngine"


def count_signals(invocation_log: str) -> dict:
    """One pass over the invocation log counting the audio-host markers.

    The log is xcodebuild's stdout for ONE invocation (the lane runner
    already persists it per attempt), so counts are per-invocation by
    construction."""
    auremoteio = 0
    halc_overload = 0
    chhaptic = 0
    with open(invocation_log, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if AUREMOTEIO_RE.search(line):
                auremoteio += 1
            if HALC_OVERLOAD_RE.search(line):
                halc_overload += 1
            if CHHAPTIC_MARK in line:
                chhaptic += 1
    return {
        "auremoteio_10851": auremoteio,
        "halc_overload": halc_overload,
        "chhaptic_engine": chhaptic,
    }


def classify(signals: dict, min_auremoteio: int, min_halc_overload: int) -> dict:
    signature = (signals.get("auremoteio_10851", 0) >= min_auremoteio
                 and signals.get("halc_overload", 0) >= min_halc_overload)
    return {
        "wedge": signature,
        "signals": signals,
        "thresholds": {
            "min_auremoteio_10851": min_auremoteio,
            "min_halc_overload": min_halc_overload,
        },
        "signature_strong": signature,
    }


def failed_class_scope(detail_path: str) -> list:
    """Distinct failed test classes from an extraction detail document.

    The retry scope is EVERY identified failed class - the wedge poisons
    timing-sensitive assertions anywhere, so the failure list itself is the
    scope; there is no class allowlist. A record without a usable class
    cannot be scoped and must never be silently omitted (it could hide a
    real regression behind a subset retry): it is a hard input error, which
    the caller must treat as fail-closed (exit 2)."""
    with open(detail_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    failed = doc.get("failures")
    if not isinstance(failed, list):
        raise ValueError(f"detail {detail_path}: 'failures' must be a list")
    seen = []
    for failure in failed:
        cls = failure.get("class") if isinstance(failure, dict) else None
        if not cls or not isinstance(cls, str):
            raise ValueError(
                f"detail {detail_path}: failure record without a valid "
                f"'class': {failure!r}")
        if cls not in seen:
            seen.append(cls)
    return seen


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    classify_p = sub.add_parser("classify", help="classify one invocation log")
    classify_p.add_argument("--invocation-log", required=True,
                            help="xcodebuild stdout log of the failed invocation")
    classify_p.add_argument("--min-auremoteio", type=int,
                            default=DEFAULT_MIN_AUREMOTEIO)
    classify_p.add_argument("--min-halc-overload", type=int,
                            default=DEFAULT_MIN_HALC_OVERLOAD)
    classify_p.add_argument("--out", default="",
                            help="also write the classification JSON here")

    scope_p = sub.add_parser("scope", help="print the failed-class retry scope")
    scope_p.add_argument("--detail", required=True,
                         help="extraction detail.json carrying failures[]")

    args = parser.parse_args(argv)
    if args.cmd == "scope":
        try:
            classes = failed_class_scope(args.detail)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"::warning::coreaudio-wedge scope could not be derived "
                  f"({exc}) - failing closed")
            return 2
        print(" ".join(classes))
        return 0

    try:
        signals = count_signals(args.invocation_log)
    except Exception as exc:  # any unreadable/odd input fails closed
        print(f"::warning::coreaudio-wedge classifier could not read its "
              f"input ({exc}) - failing closed as a product failure")
        return 2

    verdict = classify(signals, args.min_auremoteio, args.min_halc_overload)
    text = json.dumps(verdict, indent=2, sort_keys=True)
    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text + "\n")
        except OSError as exc:
            print(f"::warning::could not write {args.out}: {exc}")
    print(text)
    return 0 if verdict["wedge"] else 1


if __name__ == "__main__":
    sys.exit(main())
