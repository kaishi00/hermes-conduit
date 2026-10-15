"""ci-build-quiet-stretches.py: where a build sat without new output."""

import tempfile
import unittest
from pathlib import Path

from _util import load_module

quiet = load_module("ci_build_quiet_stretches", "ci-build-quiet-stretches.py")


class QuietStretchTests(unittest.TestCase):
    def test_runs_of_equal_counts_become_stretches(self):
        samples = [(0, 0), (2, 0), (4, 3), (6, 3), (8, 3), (10, 5)]
        self.assertEqual([(4, 0, 0), (6, 4, 3), (0, 10, 5)],
                         quiet.quiet_stretches(samples))

    def test_longest_first_with_the_line_each_followed(self):
        log = ["Resolve Package Graph", "Computing build graph", "Ld Conduit"]
        stretches = [(12, 0, 0), (95, 12, 2), (30, 107, 3), (4, 137, 3)]
        self.assertEqual(
            ["95s from 12s, after: Computing build graph",
             "30s from 107s, after: Ld Conduit",
             "12s from 0s, after: (no output yet)"],
            quiet.describe(stretches, log))

    def test_end_to_end_skips_malformed_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            timeline = Path(tmp) / "timeline.txt"
            log = Path(tmp) / "build.log"
            timeline.write_text("0 0\ngarbage\n2 1\n30 1\n32 2\n")
            log.write_text("first\nsecond\n")
            rows = []
            import contextlib
            import io
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                quiet.main([str(timeline), str(log)])
            rows = out.getvalue().splitlines()
            self.assertEqual(["30s from 2s, after: first"], rows)


if __name__ == "__main__":
    unittest.main()
