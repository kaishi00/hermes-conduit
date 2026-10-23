"""Regression coverage for scripts/check-feature-map.py."""

import contextlib
import io
import os
import tempfile
import unittest
from unittest import mock

from _util import SCRIPTS_DIR, load_module

check = load_module("check_feature_map", "check-feature-map.py")
ROOT = os.path.dirname(SCRIPTS_DIR)

ENTRY = """## Hermes is waiting on you

An approval Hermes can't go on without.

**Siblings:** chat card · Classic voice

**Code**
- Chat card: `Conduit/Views/ChatView.swift` (ApprovalCard)
- Notifier: `notifier/clarify_loop.py`

**Rulings**
- A spoken answer counts only when one item waits (2026-10-20, #991).

**Open gaps**
- None known.

**Checked:** 2026-10-23, #1
"""


class CheckFeatureMapTests(unittest.TestCase):
    def run_check(self, text, files=("Conduit/Views/ChatView.swift",), notifier_files=("clarify_loop.py",)):
        """main()'s exit code and output for a map in a repo holding `files`."""
        with tempfile.TemporaryDirectory() as repo, tempfile.TemporaryDirectory() as notifier:
            for root, names in ((repo, files), (notifier, notifier_files)):
                for name in names:
                    path = os.path.join(root, name)
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    open(path, "w").close()
            os.makedirs(os.path.join(repo, "docs"), exist_ok=True)
            with open(os.path.join(repo, check.MAP), "w", encoding="utf-8") as fh:
                fh.write(text)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = check.main(["--repo-root", repo, "--notifier-root", notifier])
            return code, out.getvalue()

    def test_the_shipped_map_passes(self):
        with open(os.path.join(ROOT, check.MAP), encoding="utf-8") as fh:
            text = fh.read()
        notifier = [path[len(check.NOTIFIER_PREFIX):] for _, path in check.paths(text)
                    if path.startswith(check.NOTIFIER_PREFIX)]
        local = [path for _, path in check.paths(text)
                 if not path.startswith(check.NOTIFIER_PREFIX) and not path.endswith("/")]
        self.assertEqual(check.shape_problems(text), [])
        self.assertEqual(self.run_check(text, files=local, notifier_files=notifier)[0], 0)
        for path in local:
            self.assertTrue(os.path.isfile(os.path.join(ROOT, path)), path)

    def test_a_complete_entry_passes(self):
        code, out = self.run_check(ENTRY)
        self.assertEqual(code, 0, out)
        self.assertIn("1 entries, 2 paths, all there", out)

    def test_a_missing_file_fails_on_its_line(self):
        code, out = self.run_check(ENTRY, files=())
        self.assertEqual(code, 1)
        self.assertIn("line=8::Conduit/Views/ChatView.swift isn't in this repo", out)

    def test_a_missing_notifier_file_fails(self):
        code, out = self.run_check(ENTRY, notifier_files=())
        self.assertEqual(code, 1)
        self.assertIn("notifier/clarify_loop.py isn't on hermes-conduit-notifier main", out)

    def test_a_notifier_directory_fails(self):
        code, out = self.run_check(ENTRY.replace("`notifier/clarify_loop.py`", "`notifier/skills/`"))
        self.assertEqual(code, 1)
        self.assertIn("name a file in hermes-conduit-notifier", out)

    def test_a_missing_part_fails(self):
        code, out = self.run_check(ENTRY.replace("**Open gaps**\n- None known.\n", ""))
        self.assertEqual(code, 1)
        self.assertIn("has no Open gaps", out)

    def test_parts_out_of_order_fail(self):
        moved = ENTRY.replace("**Rulings**", "**Held**").replace("**Open gaps**", "**Rulings**").replace("**Held**", "**Open gaps**")
        code, out = self.run_check(moved)
        self.assertEqual(code, 1)
        self.assertIn("out of order", out)

    def test_siblings_are_listed_on_their_line(self):
        code, out = self.run_check(ENTRY.replace("**Siblings:** chat card · Classic voice", "**Siblings:**"))
        self.assertEqual(code, 1)
        self.assertIn("line=5::'Hermes is waiting on you' names no siblings", out)

    def test_a_checked_line_needs_a_date(self):
        code, out = self.run_check(ENTRY.replace("2026-10-23, #1", "#1"))
        self.assertEqual(code, 1)
        self.assertIn("the Checked line needs the date", out)

    def test_a_checked_line_needs_a_pr_or_commit(self):
        code, out = self.run_check(ENTRY.replace("2026-10-23, #1", "2026-10-23"))
        self.assertEqual(code, 1)
        self.assertIn("and the PR or commit", out)
        code, out = self.run_check(ENTRY.replace("2026-10-23, #1", "2026-10-23, all defaced"))
        self.assertEqual(code, 1)
        code, out = self.run_check(ENTRY.replace("2026-10-23, #1", "2026-10-23, seeded from main at 64d53c3."))
        self.assertEqual(code, 0, out)

    def test_code_names_at_least_one_path(self):
        code, out = self.run_check(ENTRY.replace("- Chat card: `Conduit/Views/ChatView.swift` (ApprovalCard)\n- Notifier: `notifier/clarify_loop.py`\n", "- Chat card: ApprovalCard\n"))
        self.assertEqual(code, 1)
        self.assertIn("names no path under Code", out)

    def test_two_entries_with_one_name_fail(self):
        code, out = self.run_check(ENTRY + "\n" + ENTRY)
        self.assertEqual(code, 1)
        self.assertIn("Two entries are called 'Hermes is waiting on you'", out)

    def test_no_entries_fail(self):
        code, out = self.run_check("# Feature map\n")
        self.assertEqual(code, 1)
        self.assertIn("No entries", out)

    def test_a_missing_map_fails_with_an_annotation(self):
        with tempfile.TemporaryDirectory() as repo:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = check.main(["--repo-root", repo, "--notifier-root", repo])
        self.assertEqual(code, 1)
        self.assertIn("::error::Couldn't read docs/FEATURE_MAP.md in", out.getvalue())

    def test_what_counts_as_a_path(self):
        for span in ("Conduit/Voice/VoiceTypes.swift", "docs/", "notifier/events.py", "README.md", "project.yml"):
            self.assertTrue(check.is_path(span), span)
        for span in ("session.steer", "answer_approval", "/voice-tools", ".interrupted",
                     "conduit://session/1", "POST /voice/sessions", "Approve:"):
            self.assertFalse(check.is_path(span), span)

    def test_fenced_blocks_are_skipped(self):
        self.assertEqual(check.paths("```\n`Missing/File.swift`\n```\n`docs/`\n"), [(4, "docs/")])
        example = "```\n## Not an entry\n**Code**\n**Checked:** someday\n```\n"
        self.assertEqual(check.shape_problems(ENTRY.replace("**Rulings**", example + "**Rulings**")), [])

    def test_github_out_of_reach_warns_and_passes(self):
        with tempfile.TemporaryDirectory() as repo:
            path = os.path.join(repo, "Conduit", "Views", "ChatView.swift")
            os.makedirs(os.path.dirname(path))
            open(path, "w").close()
            os.makedirs(os.path.join(repo, "docs"))
            with open(os.path.join(repo, check.MAP), "w", encoding="utf-8") as fh:
                fh.write(ENTRY)
            out = io.StringIO()
            with mock.patch.object(check, "on_notifier_main", side_effect=check.Unreachable("offline")), \
                    contextlib.redirect_stdout(out):
                code = check.main(["--repo-root", repo])
        self.assertEqual(code, 0)
        self.assertIn("::warning::Couldn't check hermes-conduit-notifier", out.getvalue())


if __name__ == "__main__":
    unittest.main()
