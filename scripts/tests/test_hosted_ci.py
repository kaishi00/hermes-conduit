"""Hosted-only preparation, retry selection, and discovery regressions."""
import collections
import json
import os
import subprocess
import sys
import tempfile
import unittest

from _util import SCRIPTS_DIR, load_module


class RetrySelectionTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(os.path.isfile(os.path.join(SCRIPTS_DIR, "smoke-retry-classes.py")))
        self.retry = load_module("smoke_retry", "smoke-retry-classes.py")
        self.selected = ["ConnectionSetupUITests", "ProfilePickerUITests"]
        self.detail = {"attempts": [
            {"class": "ConnectionSetupUITests", "final": "Passed"},
            {"class": "ProfilePickerUITests", "final": "Failed"}],
            "failures": [{"class": "ProfilePickerUITests", "test": "testPhoto()"}]}

    def test_retry_only_failed_selected_class(self):
        self.assertEqual(self.retry.retry_classes(self.detail, self.selected),
                         ["ProfilePickerUITests"])

    def test_retry_multiple_failed_classes_in_selection_order(self):
        self.detail["attempts"][0]["final"] = "Failed"
        self.detail["failures"].append({"class": "ConnectionSetupUITests"})
        self.assertEqual(self.retry.retry_classes(self.detail, self.selected), self.selected)

    def _raw_result(self, children, result="Failed"):
        # Real xcresulttool assertion failures carry diagnostic children on
        # the Test Case, rather than another test attempt or an orphan failure.
        return {"testNodes": [{"nodeType": "Test Plan", "children": [
            {"nodeType": "Test Bundle", "name": "ConduitUITests", "children": [
                {"nodeType": "Test Suite", "name": cls, "children": [
                    {"nodeType": "Test Case", "name": "testFixture()",
                     "result": result if cls == "ProfilePickerUITests" else "Passed",
                     "children": children if cls == "ProfilePickerUITests" else []}]}
                for cls in self.selected]}]}]}

    def test_assertion_failure_metadata_preserves_failed_class_attribution(self):
        doc = self._raw_result([
            {"nodeType": "Failure Message", "name": "XCTAssertTrue failed",
             "sourceLocation": {"filePath": "ProfilePickerUITests.swift", "lineNumber": 115}},
            {"nodeType": "Failure Message", "name": "The photo picker must appear."}])
        detail = self.retry.extract_for_retry(doc, "initial.xcresult")
        self.assertEqual(detail["counts"]["cases"], 2)
        self.assertEqual(self.retry.retry_classes(detail, self.selected), ["ProfilePickerUITests"])

    def test_unknown_or_nested_case_children_cannot_narrow_retry(self):
        for children, result in (
            ([{"nodeType": "Test Case", "name": "testHidden()", "result": "Failed"}], "Failed"),
            ([{"nodeType": "Future Diagnostic", "name": "unknown"}], "Failed"),
            ([{"nodeType": "Failure Message", "name": "assertion", "children": [
                {"nodeType": "Test Case", "name": "testHidden()", "result": "Failed"}]}], "Failed"),
            ([{"nodeType": "Failure Message", "name": "assertion"}], "Passed"),
        ):
            with self.subTest(children=children, result=result), self.assertRaises(ValueError):
                self.retry.extract_for_retry(self._raw_result(children, result), "initial.xcresult")

    def test_incomplete_unknown_or_synthetic_results_cannot_narrow_retry(self):
        for mutate in (
            lambda d: d["attempts"].pop(0),
            lambda d: d["attempts"][0].update(final="Unknown"),
            lambda d: d["failures"].append({"class": "System Failures"}),
            lambda d: d.update(failures=[]),
        ):
            detail = json.loads(json.dumps(self.detail))
            mutate(detail)
            with self.assertRaises(ValueError):
                self.retry.retry_classes(detail, self.selected)

    def test_unreadable_bundle_falls_back_to_entire_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            evidence = os.path.join(tmp, "retry.json")
            proc = subprocess.run([sys.executable, os.path.join(SCRIPTS_DIR, "smoke-retry-classes.py"),
                                   "--classes", ",".join(self.selected), "--xcresult",
                                   os.path.join(tmp, "missing.xcresult"), "--out", evidence],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout.strip(), ",".join(self.selected))
            with open(evidence) as fh:
                doc = json.load(fh)
            self.assertTrue(doc["fallback"])
            self.assertEqual(doc["retry_classes"], self.selected)


class SelfTestGroupsTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(os.path.isfile(os.path.join(SCRIPTS_DIR, "ci-self-test.py")))
        self.runner = load_module("ci_self_test", "ci-self-test.py")

    def test_group_union_is_exact_discovery_inventory(self):
        suite = unittest.defaultTestLoader.discover(os.path.join(SCRIPTS_DIR, "tests"))
        groups = self.runner.partition_tests(suite)
        ids = [test.id() for tests in groups.values() for test in tests]
        self.assertEqual(collections.Counter(ids), collections.Counter(
            test.id() for test in self.runner.flatten(suite)))
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual([test.id() for test in groups["lane"]],
                         ["test_lane_runner.LaneRunnerScriptTests.test_lane_runner_state_machine"])
        self.assertEqual([test.id() for test in groups["local-gate"]],
                         ["test_local_ci_gate.LocalGateScriptTests.test_local_gate_integration_suite"])

    def test_newly_discovered_modules_go_to_fast_group(self):
        case = type("NewCoverage", (unittest.TestCase,),
                    {"__module__": "test_new_feature", "test_new": lambda self: None})
        suite = unittest.TestSuite([case("test_new")])
        self.assertEqual([t.id() for t in self.runner.partition_tests(suite)["fast"]],
                         ["test_new_feature.NewCoverage.test_new"])

    def test_duplicate_inventory_is_rejected(self):
        test = unittest.FunctionTestCase(lambda: None)
        with self.assertRaises(ValueError):
            self.runner.partition_tests(unittest.TestSuite([test, test]))

    def test_group_failure_has_nonzero_exit_and_does_not_hide_other_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "test_fixture.py"), "w") as fh:
                fh.write("import unittest\nclass Fixture(unittest.TestCase):\n"
                         " def test_red(self): self.fail('fixture assertion')\n"
                         " def test_green(self): pass\n")
            proc = subprocess.run([sys.executable, os.path.join(SCRIPTS_DIR, "ci-self-test.py"),
                                   "--group", "fast", "--tests-dir", tmp],
                                  capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Ran 2 tests", proc.stderr)
            self.assertIn("fixture assertion", proc.stderr)


@unittest.skipUnless(os.name == "posix", "requires POSIX shell execution")
class HostedPreparationTests(unittest.TestCase):
    def test_preparation_pins_identity_and_records_each_phase(self):
        self._assert_preparation()

    def test_clipboard_failure_warns_and_still_prepares_the_simulator(self):
        self._assert_preparation(clipboard_exit=1)

    def _assert_preparation(self, clipboard_exit=0):
        self.assertTrue(os.path.isfile(os.path.join(SCRIPTS_DIR, "ci-prepare-smoke.sh")))
        with tempfile.TemporaryDirectory() as tmp:
            bindir = os.path.join(tmp, "bin")
            os.mkdir(bindir)
            calls = os.path.join(tmp, "calls")
            inventory = {"devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    {"name": "iPhone 17 Pro", "udid": "PINNED", "isAvailable": True}],
                "com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
                    {"name": "iPhone 17 Pro", "udid": "OTHER", "isAvailable": True}]}}
            for name, body in {
                "defaults": 'echo "clipboard|$*" >> "$CALLS"\nexit ' + str(clipboard_exit),
                "xcrun": 'echo "xcrun|$*" >> "$CALLS"\n'
                         'if [ "$*" = "simctl list devices available -j" ]; then\n'
                         "cat <<'JSON'\n" + json.dumps(inventory) + "\nJSON\nfi",
            }.items():
                path = os.path.join(bindir, name)
                with open(path, "w") as fh:
                    fh.write("#!/bin/bash\n" + body + "\n")
                os.chmod(path, 0o755)
            env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"],
                       CALLS=calls, SIMULATOR_NAME="iPhone 17 Pro", GATE_SLEEP_SCALE="0",
                       GITHUB_ENV=os.path.join(tmp, "env"),
                       GITHUB_STEP_SUMMARY=os.path.join(tmp, "summary"),
                       LOG_DIR=os.path.join(tmp, "logs"))
            env.pop("SIMULATOR_UDID", None)
            proc = subprocess.run(["bash", os.path.join(SCRIPTS_DIR, "ci-prepare-smoke.sh")],
                                  env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            if clipboard_exit:
                self.assertIn("::warning::could not disable pasteboard sync", proc.stdout)
            with open(calls) as fh:
                operations = fh.read().splitlines()
            self.assertTrue(operations[0].startswith("clipboard|"), operations)
            self.assertIn("xcrun|simctl shutdown PINNED", operations)
            self.assertIn("xcrun|simctl boot PINNED", operations)
            self.assertIn("xcrun|simctl bootstatus PINNED -b", operations)
            self.assertFalse(any("OTHER" in op or "erase" in op for op in operations))
            with open(env["GITHUB_ENV"]) as fh:
                self.assertIn("DESTINATION=platform=iOS Simulator,id=PINNED,arch=arm64", fh.read())
            with open(os.path.join(env["LOG_DIR"], "preparation.json")) as fh:
                doc = json.load(fh)
            self.assertEqual(doc["udid"], "PINNED")
            self.assertEqual(doc["runtime"], "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
            self.assertEqual(set(doc["seconds"]), {"lookup", "shutdown", "boot", "boot_readiness"})
            with open(env["GITHUB_STEP_SUMMARY"]) as fh:
                self.assertIn("PINNED", fh.read())
