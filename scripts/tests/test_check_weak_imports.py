"""Regression coverage for scripts/check-weak-imports.py (back-deployed Date guard)."""

import os
import textwrap
import unittest

from _util import load_module

check_weak_imports = load_module("check_weak_imports", "check-weak-imports.py")

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


class TargetTests(unittest.TestCase):
    def test_every_shipped_target_in_the_project_compiles_date_order(self):
        with open(os.path.join(REPO_ROOT, "project.yml"), encoding="utf-8") as handle:
            project = handle.read()
        self.assertEqual(check_weak_imports.target_problems(project), [])
        names = set(check_weak_imports.shipped_targets(project))
        self.assertEqual(names, {
            "Conduit", "ConduitNotificationService", "ConduitLocationPush", "ConduitWidgets",
            "ConduitShareExtension", "ConduitWatch", "ConduitWatchWidgets",
        })
        self.assertNotIn("ConduitTests", names)

    def test_no_targets_found_fails(self):
        self.assertEqual(len(check_weak_imports.target_problems("name: X\n")), 1)

    def test_targets_key_with_a_comment_is_read(self):
        project = "targets: # the products\n  App:\n    type: application\n    sources:\n      - path: App\n"
        problems = check_weak_imports.target_problems(project)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("target App", problems[0])

    def test_a_target_without_it_is_reported(self):
        project = textwrap.dedent("""
        targets:
          App:
            type: application
            sources:
              - path: App
              - path: Shared
          Ext:
            type: app-extension
            sources:
              - path: Ext
              - path: Shared/Widgets
          Fixed:
            type: app-extension
            sources:
              - path: Fixed
              - path: Shared/DateOrder
          Excluded:
            type: app-extension
            sources:
              - path: Excluded
              - path: Shared
                excludes:
                  - "Widgets/**"
                  - "DateOrder/**"
          Commented:  # a note on the target
            type: app-extension
            sources:
              - path: Commented
              - path: Shared
                excludes:  # why these go
                  - "Widgets/**"
                  - DateOrder
          KeptExcludes:
            type: app-extension
            sources:
              - path: KeptExcludes
              - path: Shared
                excludes:
                  - "Widgets/**"
          Tests:
            type: bundle.unit-test
            sources:
              - path: Tests
        """)
        problems = check_weak_imports.target_problems(project)
        self.assertEqual([p.split("target ")[1].split(" ")[0] for p in problems],
                         ["Commented", "Excluded", "Ext"], problems)


class BinaryTests(unittest.TestCase):
    def test_a_weak_import_is_reported(self):
        out = ("                 (undefined) weak external _$s10Foundation4DateV2leoiySbAC_ACtFZ"
               " (from Foundation)\n")
        problems = check_weak_imports.weak_import_problems("Conduit.app/Conduit", out)
        self.assertEqual(len(problems), 1)
        self.assertIn("Date.<=", problems[0])

    def test_local_thunks_and_other_imports_pass(self):
        out = textwrap.dedent("""\
            0000000100001000 (__TEXT,__text) weak external _$s10Foundation4DateV2leoiySbAC_ACtFZTwb
                             (undefined) external _$s10Foundation4DateV2ltoiySbAC_ACtFZ (from Foundation)
                             (undefined) weak external _$s7SwiftUI4ViewPAAE14navigationZoomQrvg (from SwiftUI)
            """)
        self.assertEqual(check_weak_imports.weak_import_problems("x", out), [])

    def test_an_undefined_thunk_of_a_banned_symbol_is_reported(self):
        out = ("                 (undefined) weak external _$s10Foundation4DateV2geoiySbAC_ACtFZTwb"
               " (from Foundation)\n")
        self.assertEqual(len(check_weak_imports.weak_import_problems("x", out)), 1)

    def test_a_strong_activitykit_link_is_reported(self):
        out = textwrap.dedent("""\
            Load command 12
                      cmd LC_LOAD_DYLIB
                  cmdsize 88
                     name /System/Library/Frameworks/ActivityKit.framework/ActivityKit (offset 24)
            """)
        problems = check_weak_imports.strong_link_problems("Conduit.app/Conduit.debug.dylib", out)
        self.assertEqual(len(problems), 1)
        self.assertIn("ActivityKit strongly", problems[0])
        self.assertIn("1877", problems[0])

    def test_a_strong_imageplayground_link_is_reported(self):
        out = textwrap.dedent("""\
            Load command 12
                      cmd LC_LOAD_DYLIB
                  cmdsize 96
                     name /System/Library/Frameworks/ImagePlayground.framework/ImagePlayground (offset 24)
            """)
        problems = check_weak_imports.strong_link_problems("x", out)
        self.assertEqual(len(problems), 1)
        self.assertIn("ImagePlayground strongly", problems[0])

    def test_weak_links_and_other_frameworks_pass(self):
        out = textwrap.dedent("""\
            Load command 12
                      cmd LC_LOAD_WEAK_DYLIB
                  cmdsize 88
                     name /System/Library/Frameworks/ActivityKit.framework/ActivityKit (offset 24)
            Load command 13
                      cmd LC_LOAD_WEAK_DYLIB
                  cmdsize 96
                     name /System/Library/Frameworks/ImagePlayground.framework/ImagePlayground (offset 24)
            Load command 14
                      cmd LC_LOAD_DYLIB
                  cmdsize 80
                     name /System/Library/Frameworks/SwiftUI.framework/SwiftUI (offset 24)
            Load command 15
                      cmd LC_RPATH
                  cmdsize 32
                     path @executable_path/Frameworks (offset 12)
            """)
        self.assertEqual(check_weak_imports.strong_link_problems("x", out), [])

    def test_test_bundles_and_runners_are_skipped(self):
        import tempfile
        with tempfile.TemporaryDirectory() as products:
            for rel in ("Conduit.app/Conduit", "Conduit.app/Conduit.debug.dylib",
                        "Conduit.app/PlugIns/ConduitWidgets.appex/ConduitWidgets",
                        "Conduit.app/Frameworks/Fat64.framework/Fat64",
                        "Conduit.app/PlugIns/ConduitTests.xctest/ConduitTests",
                        "ConduitUITests-Runner.app/ConduitUITests-Runner",
                        "Conduit.app/Info.plist"):
                path = os.path.join(products, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "wb") as handle:
                    magic = b"\xca\xfe\xba\xbf" if "Fat64" in rel else b"\xcf\xfa\xed\xfe"
                    handle.write(b"<?xml" if rel.endswith(".plist") else magic + b"....")
            found = sorted(os.path.relpath(p, products)
                           for p in check_weak_imports.binaries_under(products))
        self.assertEqual(found, ["Conduit.app/Conduit", "Conduit.app/Conduit.debug.dylib",
                                 "Conduit.app/Frameworks/Fat64.framework/Fat64",
                                 "Conduit.app/PlugIns/ConduitWidgets.appex/ConduitWidgets"])


class MainTests(unittest.TestCase):
    def test_a_binary_nm_cant_read_fails_the_check(self):
        import subprocess
        import sys
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as products:
            path = os.path.join(products, "Conduit.app", "Conduit")
            os.makedirs(os.path.dirname(path))
            with open(path, "wb") as handle:
                handle.write(b"\xcf\xfa\xed\xfe....")
            failed = subprocess.CompletedProcess([], 1, stdout="", stderr="truncated file")
            with mock.patch.object(check_weak_imports.subprocess, "run", return_value=failed), \
                 mock.patch.object(sys, "argv", ["check", "binaries", "--products", products]), \
                 mock.patch("builtins.print") as printed:
                self.assertEqual(check_weak_imports.main(), 1)
        output = " ".join(str(call.args[0]) for call in printed.call_args_list)
        self.assertIn("Conduit.app/Conduit: nm failed", output)


    def test_a_strong_framework_load_fails_the_binaries_check(self):
        import subprocess
        import sys
        import tempfile
        from unittest import mock
        otool = ("Load command 12\n          cmd LC_LOAD_DYLIB\n      cmdsize 88\n"
                 "         name /System/Library/Frameworks/ActivityKit.framework/ActivityKit (offset 24)\n")

        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, stdout=otool if "otool" in args else "", stderr="")

        with tempfile.TemporaryDirectory() as products:
            path = os.path.join(products, "Conduit.app", "Conduit")
            os.makedirs(os.path.dirname(path))
            with open(path, "wb") as handle:
                handle.write(b"\xcf\xfa\xed\xfe....")
            with mock.patch.object(check_weak_imports.subprocess, "run", side_effect=run) as ran, \
                 mock.patch.object(sys, "argv", ["check", "binaries", "--products", products]), \
                 mock.patch("builtins.print") as printed:
                self.assertEqual(check_weak_imports.main(), 1)
        self.assertTrue(any("otool" in call.args[0] for call in ran.call_args_list))
        output = " ".join(str(call.args[0]) for call in printed.call_args_list)
        self.assertIn("Conduit.app/Conduit: links ActivityKit strongly", output)

if __name__ == "__main__":
    unittest.main()
