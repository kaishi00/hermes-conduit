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

    def test_nothing_compiled_or_no_log_says_none(self):
        self.assertEqual("none", compiled.describe(compiled.counts(["Ld Conduit"])))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            compiled.main(["/nonexistent/build.log"])
        self.assertEqual("none", out.getvalue().strip())

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
