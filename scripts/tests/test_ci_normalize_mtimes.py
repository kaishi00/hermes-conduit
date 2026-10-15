"""ci-normalize-mtimes.py: content decides a file's timestamp, nothing else."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from _util import load_module

mtimes = load_module("ci_normalize_mtimes", "ci-normalize-mtimes.py")


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True,
                   capture_output=True)


class NormalizeMtimesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        (self.repo / "Conduit").mkdir()
        (self.repo / "Conduit" / "A.swift").write_text("let a = 1\n")
        (self.repo / "Conduit" / "B.swift").write_text("let b = 2\n")
        os.symlink("A.swift", self.repo / "Conduit" / "Link.swift")
        git(self.repo, "add", "-A")

    def tearDown(self):
        self.tmp.cleanup()

    def mtime(self, rel):
        return os.stat(self.repo / rel, follow_symlinks=False).st_mtime_ns

    def test_same_content_gets_the_same_stamp_on_every_checkout(self):
        mtimes.normalize(str(self.repo))
        first = self.mtime("Conduit/A.swift")
        os.utime(self.repo / "Conduit" / "A.swift")  # a fresh checkout's "now"
        mtimes.normalize(str(self.repo))
        self.assertEqual(first, self.mtime("Conduit/A.swift"))

    def test_changed_content_gets_a_different_stamp(self):
        mtimes.normalize(str(self.repo))
        before = self.mtime("Conduit/A.swift")
        (self.repo / "Conduit" / "A.swift").write_text("let a = 3\n")
        git(self.repo, "add", "-A")
        mtimes.normalize(str(self.repo))
        self.assertNotEqual(before, self.mtime("Conduit/A.swift"))
        self.assertNotEqual(self.mtime("Conduit/A.swift"),
                            self.mtime("Conduit/B.swift"))

    def test_stamps_are_in_the_past_and_directories_share_one(self):
        mtimes.normalize(str(self.repo))
        for rel in ("Conduit/A.swift", "Conduit/B.swift"):
            stamp = self.mtime(rel)
            self.assertGreaterEqual(stamp, mtimes.BASE_NS)
            self.assertLess(stamp, mtimes.BASE_NS + mtimes.SPAN_NS)
        self.assertEqual(self.mtime("Conduit"), mtimes.DIR_NS)

    def test_symlinks_are_left_alone(self):
        link = self.repo / "Conduit" / "Link.swift"
        before = os.stat(link, follow_symlinks=False).st_mtime_ns
        mtimes.normalize(str(self.repo))
        self.assertEqual(before, os.stat(link, follow_symlinks=False).st_mtime_ns)

    def test_generated_trees_are_stamped_by_their_bytes(self):
        project = self.repo / "Conduit.xcodeproj"
        project.mkdir()
        (project / "project.pbxproj").write_text("// generated\n")
        mtimes.normalize(str(self.repo), ["Conduit.xcodeproj"])
        first = self.mtime("Conduit.xcodeproj/project.pbxproj")
        (project / "project.pbxproj").write_text("// generated\n")
        mtimes.normalize(str(self.repo), ["Conduit.xcodeproj"])
        self.assertEqual(first, self.mtime("Conduit.xcodeproj/project.pbxproj"))
        (project / "project.pbxproj").write_text("// regenerated\n")
        mtimes.normalize(str(self.repo), ["Conduit.xcodeproj"])
        self.assertNotEqual(first, self.mtime("Conduit.xcodeproj/project.pbxproj"))

    def test_a_file_deleted_from_the_working_tree_is_skipped(self):
        (self.repo / "Conduit" / "B.swift").unlink()
        self.assertEqual(1, mtimes.normalize(str(self.repo)))


if __name__ == "__main__":
    unittest.main()
