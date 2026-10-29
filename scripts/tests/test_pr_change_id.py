"""Regression coverage for scripts/pr-change-id.py (CI's same-change skip)."""

import importlib.util
import os
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = importlib.util.spec_from_file_location(
    "pr_change_id", os.path.join(SCRIPTS_DIR, "pr-change-id.py"))
pr_change_id = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pr_change_id)
cid = pr_change_id.change_id


def code(index="aaa..bbb", hunk="@@ -1,2 +1,2 @@", lines=(" a", "-b", "+c")):
    return "\n".join(["diff --git a/x.py b/x.py", f"index {index} 100644",
                      "--- a/x.py", "+++ b/x.py", hunk, *lines]) + "\n"


def doc(old, new):
    return "\n".join(["diff --git a/docs/MAP.md b/docs/MAP.md", "index 1..2 100644",
                      "--- a/docs/MAP.md", "+++ b/docs/MAP.md", "@@ -9 +9 @@",
                      f"-{old}", f"+{new}"]) + "\n"


class ChangeIdTests(unittest.TestCase):
    def test_empty_diff_never_matches(self):
        self.assertEqual(cid(""), "")
        self.assertEqual(cid("\n"), "")

    def test_merging_the_base_moves_hunks_and_blob_ids_only(self):
        self.assertEqual(cid(code()), cid(code(index="ccc..ddd", hunk="@@ -40,2 +40,2 @@")))

    def test_a_code_change_changes_the_id(self):
        self.assertNotEqual(cid(code()), cid(code(lines=(" a", "-b", "+d"))))

    def test_whitespace_and_context_count_in_code(self):
        self.assertNotEqual(cid(code()), cid(code(lines=(" a", "-b", "+ c"))))
        self.assertNotEqual(cid(code()), cid(code(lines=(" z", "-b", "+c"))))

    def test_a_binary_file_counts_by_its_blob_id(self):
        binary = "diff --git a/i.png b/i.png\nindex {} 100644\nBinary files a/i.png and b/i.png differ\n"
        self.assertNotEqual(cid(binary.format("aaa..bbb")), cid(binary.format("aaa..ccc")))

    def test_a_resolved_checked_line_conflict_keeps_the_id(self):
        before = doc("**Checked:** 2026-10-27, #1351.", "**Checked:** 2026-10-28, #1462; 2026-10-27, #1351.")
        after = doc("**Checked:** 2026-10-28, #1449; 2026-10-27, #1351.",
                    "**Checked:** 2026-10-28, #1462; 2026-10-28, #1449; 2026-10-27, #1351.")
        self.assertEqual(cid(before), cid(after))

    def test_new_words_in_markdown_change_the_id(self):
        self.assertNotEqual(cid(doc("a b", "a b c")), cid(doc("a b", "a b d")))


if __name__ == "__main__":
    unittest.main()
