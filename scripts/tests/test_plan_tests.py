"""Regression coverage for scripts/plan-tests.py: discovery, validate and the
xctestrun audit (smoke and hosted have their own suites)."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from _util import SCRIPTS_DIR, load_module, make_repo

planner = load_module("plan_tests", "plan-tests.py")


def discovery_from_tree(root):
    return planner.discover_test_classes(str(root))


def unit_names(discovery):
    return [e["name"] for e in discovery["unit"]]


class DiscoveryTests(unittest.TestCase):
    def test_discovers_direct_subclasses_per_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests", "BetaTests"], ["UiOneTests"]))
            discovery = planner.discover_test_classes(str(root))
            self.assertEqual([e["name"] for e in discovery["unit"]], ["AlphaTests", "BetaTests"])
            self.assertEqual([e["name"] for e in discovery["ui"]], ["UiOneTests"])
            self.assertEqual(discovery["errors"], [])

    def test_duplicate_class_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_repo(root, ["AlphaTests"])
            (root / "ConduitTests" / "CopyAlphaTests.swift").write_text(
                "final class AlphaTests: XCTestCase {}\n", encoding="utf-8")
            discovery = discovery_from_tree(root)
            self.assertTrue(any("duplicate" in e for e in discovery["errors"]))

    def test_tests_named_class_without_xctestcase_is_malformed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_repo(root, [], [], extra_files={
                "ConduitTests/BrokenTests.swift":
                    "final class BrokenTests: SomeService {}\n"})
            discovery = discovery_from_tree(root)
            self.assertTrue(any("malformed" in e for e in discovery["errors"]))

    def test_transitive_test_class_is_planned(self):
        content = {
            "ConduitTests/BaseTests.swift":
                "import XCTest\nclass BaseTests: XCTestCase {\n"
                "    func testBaseBehavior() {}\n}\n",
            "ConduitTests/SubTests.swift":
                "final class SubTests: BaseTests {}\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], [], extra_files=content))
            discovery = discovery_from_tree(root)
            self.assertEqual(sorted(unit_names(discovery)), ["BaseTests", "SubTests"])

    def test_helper_mock_is_not_planned(self):
        content = {
            "ConduitTests/Support.swift":
                "import XCTest\nclass TestSupportBase: XCTestCase {}\n"
                "final class MockGateway: TestSupportBase {}\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["RealTests"], [], extra_files=content))
            discovery = discovery_from_tree(root)
            # Zero-test XCTestCase subclasses without a Tests suffix (direct or
            # indirect) enumerate zero tests at runtime, so they are helpers,
            # not test classes: -only-testing entries for them would match nothing.
            self.assertEqual(unit_names(discovery), ["RealTests"])
            self.assertEqual(
                sorted(h["name"] for h in discovery["helpers"]),
                ["MockGateway", "TestSupportBase"])

    def test_directory_decides_target_not_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), [], ["SomethingTests"]))
            discovery = planner.discover_test_classes(str(root))
            self.assertEqual([e["name"] for e in discovery["ui"]], ["SomethingTests"])
            self.assertEqual(discovery["unit"], [])


class TimingBaselineTests(unittest.TestCase):
    def test_malformed_timing_json_falls_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.json"
            bad.write_text("{ not json !!!", encoding="utf-8")
            estimates, warns = planner.load_estimates(str(bad), "baseline")
            self.assertEqual(estimates, {})
            self.assertTrue(warns)

    def test_non_finite_timing_entries_are_ignored(self):
        # nan survives a naive "secs <= 0" check and would poison the
        # nightly shard balancing; inf does the same.
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "bad.json"
            bad.write_text(
                json.dumps({"classes": {"AlphaTests": float("nan"),
                                        "BetaTests": float("inf")}}),
                encoding="utf-8")
            estimates, warns = planner.load_estimates(str(bad), "baseline")
            self.assertEqual(estimates, {})
            self.assertEqual(len(warns), 2)


class CliTests(unittest.TestCase):
    def test_validate_cli_passes_on_clean_tree(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"], ["UiTests"]))
            proc = subprocess.run(
                [sys.executable, str(Path(SCRIPTS_DIR) / "plan-tests.py"),
                 "validate", "--repo-root", str(root)],
                capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_validate_cli_fails_on_duplicate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), ["AlphaTests"]))
            (root / "ConduitTests" / "Again.swift").write_text(
                "final class AlphaTests: XCTestCase {}\n", encoding="utf-8")
            proc = subprocess.run(
                [sys.executable, str(Path(SCRIPTS_DIR) / "plan-tests.py"),
                 "validate", "--repo-root", str(root)],
                capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)

    def test_validate_has_no_class_cap(self):
        """The retired lane planner capped the suite at 224 unit classes
        (8 lanes x 4 batches x 7); the nightly shards take any number."""
        names = ["C{0:03d}Tests".format(i) for i in range(300)]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(make_repo(Path(tmp), names, ["UiTests"]))
            proc = subprocess.run(
                [sys.executable, str(Path(SCRIPTS_DIR) / "plan-tests.py"),
                 "validate", "--repo-root", str(root)],
                capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("discovered 300 unit + 1 UI test classes", proc.stdout)
            self.assertNotIn("max_lanes", proc.stdout)

    def test_the_lane_planner_is_gone(self):
        proc = subprocess.run(
            [sys.executable, str(Path(SCRIPTS_DIR) / "plan-tests.py"), "plan"],
            capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0)


class XctestrunAuditTests(unittest.TestCase):
    def _plist(self, tmp, strings):
        import plistlib
        path = Path(tmp) / "test.xctestrun"
        with open(path, "wb") as fh:
            plistlib.dump({"ConduitTests": {"TestHostPath": strings[0],
                                            "TestBundlePath": strings[1]}}, fh)
        return str(path)

    def test_workspace_and_system_paths_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._plist(tmp, [
                "/Users/runner/work/hermes-conduit/hermes-conduit/ci-derived-data/Build/Products/a.app",
                "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest",
            ])
            violations, checked = planner.audit_xctestrun(
                path, "/Users/runner/work/hermes-conduit/hermes-conduit")
            self.assertEqual(violations, [])
            self.assertEqual(checked, 2)

    def test_private_var_temp_path_is_rejected(self):
        # /private/var/folders/... is per-runner temp state: a build product
        # resolved there exists only on the machine that built the artifact.
        with tempfile.TemporaryDirectory() as tmp:
            path = self._plist(tmp, [
                "/private/var/folders/zz/abc/T/x/Y/d/e/Applications/iOS/TestBuild/Products/a.app",
                "/Users/runner/work/hermes-conduit/hermes-conduit/ci-derived-data/Build/Products/b.app",
            ])
            violations, _checked = planner.audit_xctestrun(
                path, "/Users/runner/work/hermes-conduit/hermes-conduit")
            self.assertEqual(len(violations), 1)
            self.assertTrue(violations[0].startswith("/private/var/"))

    def test_foreign_absolute_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = self._plist(tmp, [
                "/Users/runner/work/hermes-conduit/hermes-conduit/ci-derived-data/Build/Products/a.app",
                "/Users/someone/else/private/b.xctest",
            ])
            violations, _checked = planner.audit_xctestrun(
                path, "/Users/runner/work/hermes-conduit/hermes-conduit")
            self.assertEqual(violations, ["/Users/someone/else/private/b.xctest"])

if __name__ == "__main__":
    unittest.main()
