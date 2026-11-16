"""Hosted-only preparation, retry selection, and discovery regressions."""
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

    def test_pinned_tests_retry_only_the_failed_test(self):
        selected = ["ProfilePickerUITests/testReorderArrowMovesTheProfileLater",
                    "ProfilePickerUITests/testTappingTheCardBodyInvokesSelection",
                    "ConnectionSetupUITests/testWizardAdvancesThroughQuestionsToTailscaleBranchAndBack"]
        detail = {"attempts": [
            {"class": "ProfilePickerUITests", "test": "testReorderArrowMovesTheProfileLater()",
             "final": "Passed"},
            {"class": "ProfilePickerUITests", "test": "testTappingTheCardBodyInvokesSelection()",
             "final": "Failed"},
            {"class": "ConnectionSetupUITests",
             "test": "testWizardAdvancesThroughQuestionsToTailscaleBranchAndBack()",
             "final": "Passed"}],
            "failures": [{"class": "ProfilePickerUITests",
                          "test": "testTappingTheCardBodyInvokesSelection()"}]}
        self.assertEqual(self.retry.retry_classes(detail, selected), [selected[1]])
        # A pinned test that produced no result cannot narrow the retry.
        detail["attempts"].pop(0)
        with self.assertRaises(ValueError):
            self.retry.retry_classes(detail, selected)

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


class SelfTestRunnerTests(unittest.TestCase):
    def _run(self, tests_dir):
        return subprocess.run([sys.executable, os.path.join(SCRIPTS_DIR, "ci-self-test.py"),
                               "--tests-dir", tests_dir], capture_output=True, text=True)

    def test_a_failure_has_nonzero_exit_and_does_not_hide_other_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "test_fixture.py"), "w") as fh:
                fh.write("import unittest\nclass Fixture(unittest.TestCase):\n"
                         " def test_red(self): self.fail('fixture assertion')\n"
                         " def test_green(self): pass\n")
            proc = self._run(tmp)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("Ran 2 tests", proc.stderr)
            self.assertIn("fixture assertion", proc.stderr)

    def test_an_import_error_fails_instead_of_dropping_the_module(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "test_broken.py"), "w") as fh:
                fh.write("import no_such_module_for_self_test\n")
            self.assertNotEqual(self._run(tmp).returncode, 0)

    def test_an_empty_discovery_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertNotEqual(self._run(tmp).returncode, 0)


@unittest.skipUnless(os.name == "posix", "requires POSIX shell execution")
class HostedPreparationTests(unittest.TestCase):
    def test_preparation_pins_identity_and_records_each_phase(self):
        self._assert_preparation()

    def test_clipboard_failure_warns_and_still_prepares_the_simulator(self):
        self._assert_preparation(clipboard_exit=1)

    def test_runtime_reporting_never_queries_after_boot(self):
        self._assert_preparation(forbid_post_boot=True)

    def test_failed_inventory_cache_does_not_change_the_destination(self):
        self._assert_preparation(cache_failure=True)

    def test_summary_failure_does_not_fail_prepared_destination(self):
        self._assert_preparation(summary_failure=True)

    def test_delayed_inventory_keeps_destination_wait_and_runtime_identity(self):
        self._assert_preparation(delayed_inventory=True)

    def test_existing_pin_does_not_trigger_reporting_lookup_or_reuse_stale_metadata(self):
        self._assert_preparation(existing_pin=True)

    def _run_seeded(self, tmp, seed_udid=None, restore_only=False, corrupt=False,
                    state="Shutdown", second_boot_fails=False):
        """ci-prepare-smoke.sh with SIM_SEED_DIR set and the device pinned;
        a seed for seed_udid is in place first when given."""
        bindir = os.path.join(tmp, "bin")
        os.mkdir(bindir)
        home = os.path.join(tmp, "home")
        device = os.path.join(home, "Library/Developer/CoreSimulator/Devices/PINNED")
        os.makedirs(os.path.join(device, "data"))
        with open(os.path.join(device, "data", "marker"), "w") as fh:
            fh.write("cold\n")
        seed = os.path.join(tmp, "seed")
        if seed_udid:
            src = os.path.join(tmp, "src")
            os.makedirs(os.path.join(src, "data"))
            with open(os.path.join(src, "data", "marker"), "w") as fh:
                fh.write("warm\n")
            os.mkdir(seed)
            subprocess.run(["tar", "-cf", os.path.join(seed, "data.tar"), "-C", src, "data"], check=True)
            if corrupt:
                with open(os.path.join(seed, "data.tar"), "wb") as fh:
                    fh.write(b"not a tar archive")
            with open(os.path.join(seed, "udid"), "w") as fh:
                fh.write(seed_udid + "\n")
        for name, body in {
            "defaults": "exit 0",
            "xcrun": 'echo "xcrun|$*" >> "$CALLS"\n'
                     'if [ "$*" = "simctl erase PINNED" ]; then\n'
                     'mkdir -p "$HOME/Library/Developer/CoreSimulator/Devices/PINNED/data"\n'
                     'echo erased > "$HOME/Library/Developer/CoreSimulator/Devices/PINNED/data/marker"; fi\n'
                     'if [ "$*" = "simctl list devices" ]; then\n'
                     'echo "    iPhone 17 Pro (PINNED) ($DEVICE_STATE)"; fi\n'
                     'if [ "$*" = "simctl bootstatus PINNED -b" ]; then\n'
                     'n=$(grep -c "bootstatus" "$CALLS")\n'
                     'if [ "$SECOND_BOOT_FAILS" = 1 ] && [ "$n" -ge 2 ]; then exit 1; fi; fi',
        }.items():
            path = os.path.join(bindir, name)
            with open(path, "w") as fh:
                fh.write("#!/bin/bash\n" + body + "\n")
            os.chmod(path, 0o755)
        env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"], HOME=home,
                   CALLS=os.path.join(tmp, "calls"), SIMULATOR_NAME="iPhone 17 Pro",
                   SIMULATOR_UDID="PINNED", GATE_SLEEP_SCALE="0", SIM_SEED_DIR=seed,
                   GITHUB_ENV=os.path.join(tmp, "env"),
                   GITHUB_STEP_SUMMARY=os.path.join(tmp, "summary"),
                   LOG_DIR=os.path.join(tmp, "logs"), DEVICE_STATE=state,
                   SECOND_BOOT_FAILS=str(int(second_boot_fails)))
        env.pop("SIMULATOR_INVENTORY_CACHE", None)
        env.pop("SIM_SEED_RESTORE_ONLY", None)
        if restore_only:
            env["SIM_SEED_RESTORE_ONLY"] = "1"
        proc = subprocess.run(["bash", os.path.join(SCRIPTS_DIR, "ci-prepare-smoke.sh")],
                              env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        with open(env["CALLS"]) as fh:
            operations = fh.read().splitlines()
        with open(os.path.join(device, "data", "marker")) as fh:
            marker = fh.read().strip()
        with open(os.path.join(env["LOG_DIR"], "preparation.json")) as fh:
            doc = json.load(fh)
        with open(env["GITHUB_ENV"]) as fh:
            github_env = fh.read()
        return proc, operations, marker, doc, github_env, seed

    def test_a_restored_seed_replaces_the_device_data_before_the_boot(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, _ = self._run_seeded(tmp, seed_udid="PINNED")
            self.assertEqual(marker, "warm")
            self.assertEqual(doc["warm_seed"], "restored")
            self.assertEqual(operations.count("xcrun|simctl boot PINNED"), 1)
            self.assertFalse(any("erase" in op for op in operations))
            self.assertNotIn("SIM_SEED_CREATED", github_env)

    def test_a_seed_for_another_device_is_never_restored_and_is_made_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, seed = self._run_seeded(tmp, seed_udid="OTHER")
            self.assertEqual(marker, "cold")
            self.assertEqual(doc["warm_seed"], "created")
            self.assertIn("seed is for another device", proc.stdout)
            self.assertIn("SIM_SEED_CREATED=1", github_env)
            with open(os.path.join(seed, "udid")) as fh:
                self.assertEqual(fh.read().strip(), "PINNED")

    def test_a_broken_seed_erases_the_device_and_is_made_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, seed = self._run_seeded(tmp, seed_udid="PINNED", corrupt=True)
            self.assertIn("could not restore the warm-device seed", proc.stdout)
            self.assertEqual(marker, "erased")
            erase = operations.index("xcrun|simctl erase PINNED")
            self.assertLess(erase, operations.index("xcrun|simctl boot PINNED"))
            self.assertEqual(doc["warm_seed"], "created")
            self.assertIn("SIM_SEED_CREATED=1", github_env)

    def test_a_device_that_is_not_shut_down_keeps_its_data(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, _ = self._run_seeded(tmp, seed_udid="PINNED", state="Booted")
            self.assertEqual(marker, "cold")
            self.assertEqual(doc["warm_seed"], "failed")
            self.assertFalse(any("erase" in op for op in operations))
            self.assertNotIn("SIM_SEED_CREATED", github_env)

    def test_a_seed_the_device_did_not_boot_from_is_not_saved(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, _ = self._run_seeded(tmp, second_boot_fails=True)
            self.assertEqual(doc["warm_seed"], "create-failed")
            self.assertNotIn("SIM_SEED_CREATED", github_env)
            self.assertFalse(doc["boot_confirmed"])

    def test_a_restore_only_job_never_makes_a_seed(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, seed = self._run_seeded(tmp, restore_only=True)
            self.assertEqual(doc["warm_seed"], "skipped")
            self.assertEqual(operations.count("xcrun|simctl boot PINNED"), 1)
            self.assertFalse(os.path.exists(os.path.join(seed, "data.tar")))
            self.assertNotIn("SIM_SEED_CREATED", github_env)

    def test_a_restore_only_job_reports_an_unusable_seed_as_failed(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, _ = self._run_seeded(
                tmp, seed_udid="PINNED", corrupt=True, restore_only=True)
            self.assertIn("xcrun|simctl erase PINNED", operations)
            self.assertEqual(doc["warm_seed"], "failed")
            self.assertEqual(operations.count("xcrun|simctl boot PINNED"), 1)
            self.assertNotIn("SIM_SEED_CREATED", github_env)
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, _ = self._run_seeded(
                tmp, seed_udid="OTHER", restore_only=True)
            self.assertEqual(doc["warm_seed"], "failed")
            self.assertEqual(marker, "cold")
            self.assertNotIn("SIM_SEED_CREATED", github_env)

    def test_without_a_seed_the_finished_first_boot_becomes_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, operations, marker, doc, github_env, seed = self._run_seeded(tmp)
            self.assertEqual(doc["warm_seed"], "created")
            self.assertIn("SIM_SEED_CREATED=1", github_env)
            with open(os.path.join(seed, "udid")) as fh:
                self.assertEqual(fh.read().strip(), "PINNED")
            listing = subprocess.run(["tar", "-tf", os.path.join(seed, "data.tar")],
                                     capture_output=True, text=True, check=True).stdout
            self.assertIn("data/marker", listing)
            # Taken between a confirmed first boot and a shutdown, then booted again.
            first_ready = operations.index("xcrun|simctl bootstatus PINNED -b")
            self.assertIn("xcrun|simctl shutdown PINNED", operations[first_ready:])
            self.assertEqual(operations.count("xcrun|simctl boot PINNED"), 2)
            self.assertEqual(operations[-1], "xcrun|simctl bootstatus PINNED -b")

    def _assert_preparation(self, clipboard_exit=0, forbid_post_boot=False,
                            cache_failure=False, summary_failure=False, delayed_inventory=False, existing_pin=False):
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
                         'if [ "$*" = "simctl boot PINNED" ]; then touch "$BOOTED"; fi\n'
                         'if [ "$*" = "simctl list devices available -j" ]; then\n'
                         'if [ "$FORBID_POST_BOOT" = 1 ] && [ -f "$BOOTED" ]; then exit 42; fi\n'
                         'if [ "$DELAYED_INVENTORY" = 1 ] && [ ! -f "$FIRST_LOOKUP" ]; then\n'
                         'touch "$FIRST_LOOKUP"; echo \'{"devices":{}}\'; exit 0; fi\n'
                         'if [ "$CACHE_FAILURE" = 1 ] && [ -n "${SIMULATOR_INVENTORY_CACHE:-}" ]; then\n'
                         'if [ -f "$SIMULATOR_INVENTORY_CACHE" ]; then\n'
                         'rm -f "$SIMULATOR_INVENTORY_CACHE"; mkdir "$SIMULATOR_INVENTORY_CACHE"; fi; fi\n'
                         "cat <<'JSON'\n" + json.dumps(inventory) + "\nJSON\nfi",
                "sleep": 'if [ "$1" = 10 ]; then exit 0; fi\n/bin/sleep "$@"',
            }.items():
                path = os.path.join(bindir, name)
                with open(path, "w") as fh:
                    fh.write("#!/bin/bash\n" + body + "\n")
                os.chmod(path, 0o755)
            env = dict(os.environ, PATH=bindir + os.pathsep + os.environ["PATH"],
                       CALLS=calls, SIMULATOR_NAME="iPhone 17 Pro", GATE_SLEEP_SCALE="0",
                       GITHUB_ENV=os.path.join(tmp, "env"),
                       GITHUB_STEP_SUMMARY=os.path.join(tmp, "summary"),
                       LOG_DIR=os.path.join(tmp, "logs"), BOOTED=os.path.join(tmp, "booted"),
                       FIRST_LOOKUP=os.path.join(tmp, "first_lookup"),
                       FORBID_POST_BOOT=str(int(forbid_post_boot)),
                       CACHE_FAILURE=str(int(cache_failure)), DELAYED_INVENTORY=str(int(delayed_inventory)))
            env.pop("SIMULATOR_UDID", None)
            env.pop("SIMULATOR_INVENTORY_CACHE", None)
            if existing_pin:
                env["SIMULATOR_UDID"] = "PINNED"
                os.mkdir(env["LOG_DIR"])
                with open(os.path.join(env["LOG_DIR"], "devices.json"), "w") as fh:
                    json.dump({"devices": {"STALE-RUNTIME": [{"udid": "PINNED"}]}}, fh)
            if summary_failure:
                os.mkdir(env["GITHUB_STEP_SUMMARY"])
            proc = subprocess.run(["bash", os.path.join(SCRIPTS_DIR, "ci-prepare-smoke.sh")],
                                  env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            if clipboard_exit:
                self.assertIn("::warning::could not disable pasteboard sync", proc.stdout)
            if cache_failure:
                self.assertIn("::warning::simulator inventory cache unavailable", proc.stderr)
            with open(calls) as fh:
                operations = fh.read().splitlines()
            self.assertTrue(operations[0].startswith("clipboard|"), operations)
            self.assertIn("xcrun|simctl shutdown PINNED", operations)
            self.assertIn("xcrun|simctl boot PINNED", operations)
            self.assertIn("xcrun|simctl bootstatus PINNED -b", operations)
            self.assertFalse(any("OTHER" in op or "erase" in op for op in operations))
            boot_index = operations.index("xcrun|simctl boot PINNED")
            self.assertFalse(any("simctl list devices" in op for op in operations[boot_index:]),
                             "diagnostic reporting must not add a post-boot inventory probe")
            if delayed_inventory:
                self.assertGreaterEqual(operations.count("xcrun|simctl list devices available -j"), 3)
            if existing_pin:
                self.assertFalse(any("simctl list devices" in op for op in operations))
            with open(env["GITHUB_ENV"]) as fh:
                self.assertIn("DESTINATION=platform=iOS Simulator,id=PINNED,arch=arm64", fh.read())
            with open(os.path.join(env["LOG_DIR"], "preparation.json")) as fh:
                doc = json.load(fh)
            self.assertEqual(doc["udid"], "PINNED")
            self.assertEqual(doc["runtime"], "unknown" if cache_failure or existing_pin else "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
            self.assertEqual(set(doc["seconds"]), {"lookup", "shutdown", "boot", "boot_readiness", "warm_seed"})
            self.assertEqual(doc["warm_seed"], "off")
            if summary_failure:
                self.assertIn("::warning::simulator preparation reporting unavailable", proc.stdout)
            else:
                with open(env["GITHUB_STEP_SUMMARY"]) as fh:
                    self.assertIn("PINNED", fh.read())
