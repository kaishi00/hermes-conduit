"""Regression coverage for scripts/classify-coreaudio-wedge.py.

The classifier is a HOST-HEALTH gate: a strong CoreAudio log signature
identifies the broken runner environment and authorizes exactly one
clean-host retry of whatever failed. These tests pin the calibrated
two-marker joint threshold and its fail-closed margins: a single
incidental AURemoteIO line - or the full healthy ambient volume - never
classifies an invocation as infrastructure, and there is deliberately no
test-class inventory involved.
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR

SPEC = importlib.util.spec_from_file_location(
    "classify_coreaudio_wedge",
    os.path.join(SCRIPTS_DIR, "classify-coreaudio-wedge.py"))
classifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(classifier)

SCRIPT = os.path.join(SCRIPTS_DIR, "classify-coreaudio-wedge.py")


def wedge_log(path, auremoteio=200, halc=40, chhaptic=5):
    """Synthetic invocation log carrying a configurable host signature."""
    with open(path, "w", encoding="utf-8") as fh:
        for _ in range(auremoteio):
            fh.write("2026-09-14 00:00:00.000 Conduit[9:9] [aurioc]"
                     "            AURemoteIO.cpp:1135  failed: -10851"
                     " (enable 1, outf< 2 ch,      0 Hz>)\n")
        for _ in range(halc):
            fh.write("2026-09-14 00:00:00.000 Conduit[9:9] [AMCP]"
                     "          HALC_ProxyIOContext.cpp:1623"
                     "  HALC_ProxyIOContext::IOWorkLoop: skipping cycle"
                     " due to overload\n")
        for _ in range(chhaptic):
            fh.write("2026-09-14 00:00:00.000 Conduit[9:9] [hapi]"
                     "         CHHapticEngine.mm:1007  ERROR: Invalid audio"
                     " session ID: 0\n")
    return path


class ClassifierCliTests(unittest.TestCase):
    """End-to-end CLI verdicts. Exit 0 = host wedge (recovery authorized),
    exit 1 = host healthy / product failure (fail closed), exit 2 =
    unusable inputs."""

    def _run(self, log, extra=None):
        return subprocess.run(
            [sys.executable, SCRIPT, "classify",
             "--invocation-log", str(log)] + (extra or []),
            capture_output=True, text=True)

    def test_strong_signature_classifies_the_host_wedge(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"))
            proc = self._run(log)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            verdict = json.loads(proc.stdout)
            self.assertTrue(verdict["wedge"])
            self.assertTrue(verdict["signature_strong"])

    def test_normal_assertion_failure_without_signature_is_real(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=0, halc=0, chhaptic=0)
            proc = self._run(log)
            self.assertEqual(proc.returncode, 1)
            self.assertFalse(json.loads(proc.stdout)["wedge"])

    def test_single_incidental_auremoteio_line_is_not_a_wedge(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=1, halc=0, chhaptic=0)
            proc = self._run(log)
            self.assertEqual(proc.returncode, 1)
            self.assertEqual(json.loads(proc.stdout)["signals"]["auremoteio_10851"], 1)

    def test_ambient_healthy_lane_volume_is_not_a_wedge(self):
        # Healthy unit-2 lanes emit ~93-116 ambient AURemoteIO lines and
        # ~0-7 HALC overload skips - below the joint signature on purpose:
        # ambient AppState noise must never authorize recovery.
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=107, halc=7, chhaptic=11)
            proc = self._run(log)
            self.assertEqual(proc.returncode, 1)
            self.assertFalse(json.loads(proc.stdout)["signature_strong"])

    def test_aurioc_elevated_with_moderate_overload_is_a_wedge(self):
        # 2026-09-14 run 34901103097 rerun: 186 AURemoteIO / 14 overload -
        # aurioc is the reliable flood marker; the overload floor must not
        # require the full 48-line burst every time.
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=186, halc=14, chhaptic=20)
            proc = self._run(log)
            self.assertEqual(proc.returncode, 0, proc.stdout)

    def test_non_audio_slow_timeout_volumes_are_not_a_wedge(self):
        # Run 34776568422: a generic stall red lane showed 48 / 4.
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=48, halc=4, chhaptic=20)
            proc = self._run(log)
            self.assertEqual(proc.returncode, 1)

    def test_threshold_flags_are_overridable(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"),
                            auremoteio=20, halc=5, chhaptic=0)
            lowered = self._run(log, ["--min-auremoteio", "10",
                                      "--min-halc-overload", "4"])
            self.assertEqual(lowered.returncode, 0, lowered.stdout)
            raised = self._run(log, ["--min-auremoteio", "500",
                                     "--min-halc-overload", "4"])
            self.assertEqual(raised.returncode, 1)

    def test_unreadable_input_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = self._run(os.path.join(tmp, "missing.log"))
            self.assertEqual(proc.returncode, 2)

    def test_out_document_matches_stdout_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "attempt-1.log"))
            out_path = os.path.join(tmp, "wedge.json")
            proc = self._run(log, ["--out", out_path])
            self.assertEqual(proc.returncode, 0)
            with open(out_path, encoding="utf-8") as fh:
                doc = json.load(fh)
            self.assertTrue(doc["wedge"])
            self.assertEqual(doc["signals"]["auremoteio_10851"], 200)
            self.assertEqual(doc["signals"]["halc_overload"], 40)


class ClassifierUnitTests(unittest.TestCase):
    def test_counts_are_per_invocation_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = wedge_log(os.path.join(tmp, "a.log"), auremoteio=3,
                            halc=1, chhaptic=2)
            signals = classifier.count_signals(log)
            self.assertEqual(signals, {"auremoteio_10851": 3,
                                       "halc_overload": 1,
                                       "chhaptic_engine": 2})

    def test_classify_is_inventory_free(self):
        # The host-health model deliberately has no test-class input: any
        # failed class can be poisoned by the host, so the signature alone
        # classifies.
        verdict = classifier.classify(
            {"auremoteio_10851": 500, "halc_overload": 50,
             "chhaptic_engine": 0}, 150, 20)
        self.assertTrue(verdict["wedge"])
        self.assertFalse(classifier.classify(
            {"auremoteio_10851": 10, "halc_overload": 1}, 150, 20)["wedge"])

    def test_malformed_signals_fail_closed(self):
        self.assertFalse(classifier.classify({}, 150, 20)["wedge"])


class ScopeSubcommandTests(unittest.TestCase):
    """scope: the retry scope is EVERY identified failed class; an
    unattributable record is a hard input error (exit 2) and must never be
    silently omitted from a subset retry."""

    def _run(self, detail):
        return subprocess.run(
            [sys.executable, SCRIPT, "scope", "--detail", str(detail)],
            capture_output=True, text=True)

    def test_scope_lists_every_identified_failed_class_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            detail = os.path.join(tmp, "detail.json")
            with open(detail, "w", encoding="utf-8") as fh:
                json.dump({"failures": [
                    {"class": "AlphaTests", "test": "testA()"},
                    {"class": "BetaTests", "test": "testB()"},
                    {"class": "AlphaTests", "test": "testC()"},
                ]}, fh)
            proc = self._run(detail)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.split(), ["AlphaTests", "BetaTests"])

    def test_unattributable_record_hard_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            detail = os.path.join(tmp, "detail.json")
            with open(detail, "w", encoding="utf-8") as fh:
                json.dump({"failures": [
                    {"class": "AlphaTests", "test": "testA()"},
                    {"test": "testNoClass()"},
                ]}, fh)
            self.assertEqual(self._run(detail).returncode, 2)

    def test_unreadable_detail_hard_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(
                self._run(os.path.join(tmp, "missing.json")).returncode, 2)


if __name__ == "__main__":
    unittest.main()
