"""ci-build-compiled-counts.py: Swift files each target compiled."""

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from _util import load_module

compiled = load_module("ci_build_compiled_counts", "ci-build-compiled-counts.py")

LOG = """\
SwiftCompile normal arm64 /src/A.swift (in target 'Conduit' from project 'Conduit')
SwiftCompile normal arm64 /src/B.swift (in target 'Conduit' from project 'Conduit')
SwiftCompile normal arm64 /src/T.swift (in target 'ConduitTests' from project 'Conduit')
SwiftCompile normal arm64 /src/W.swift (in target 'Conduit Watch App' from project 'Conduit')
    cd /src && swiftc -c /src/A.swift (in target 'Conduit' from project 'Conduit')
SwiftEmitModule normal arm64 Emitting\\ module\\ for\\ Conduit (in target 'Conduit' from project 'Conduit')
"""


class CompiledCountTests(unittest.TestCase):
    def test_counts_per_target_most_first_with_spaces_in_names(self):
        self.assertEqual("2 Conduit, 1 Conduit Watch App, 1 ConduitTests",
                         compiled.describe(compiled.counts(LOG.splitlines())))

    def test_nothing_compiled_says_none(self):
        self.assertEqual("none", compiled.describe(compiled.counts(["Ld Conduit"])))

    def test_an_unreadable_log_fails_so_the_build_warns(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with tempfile.TemporaryDirectory() as folder:
                missing = str(Path(folder) / "build.log")
                self.assertEqual(compiled.main([missing]), 1)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("cannot read the build log", err.getvalue())

    def test_without_exactly_one_log_path_prints_usage(self):
        for argv in ([], ["a.log", "b.log"]):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(compiled.main(argv), 2)
            self.assertEqual(out.getvalue(), "")
            self.assertIn("usage:", err.getvalue())

    def test_reads_the_log_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "build.log"
            log.write_text(LOG)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                compiled.main([str(log)])
            self.assertTrue(out.getvalue().startswith("2 Conduit, "))


if __name__ == "__main__":
    unittest.main()
