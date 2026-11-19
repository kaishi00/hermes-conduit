"""Regression coverage for scripts/check-pr-desktop.py."""

import contextlib
import io
import os
import unittest
from unittest import mock

from _util import SCRIPTS_DIR, load_module

check = load_module("check_pr_desktop", "check-pr-desktop.py")
ROOT = os.path.dirname(SCRIPTS_DIR)


def body(desktop, after="## Testing\nRan it.\n"):
    return f"## Summary\nA change.\n\n## Siblings\n- Watch: done.\n\n## Desktop\n{desktop}\n\n{after}"


class CheckPrDesktopTests(unittest.TestCase):
    def test_each_answer_passes(self):
        for desktop in ("Done: hermes-conduit-desktop#58.",
                        "Done (desktop#58)",
                        "- Done: https://github.com/kaishi00/hermes-conduit-desktop/pull/58",
                        "Not needed: the Watch only.",
                        "**Not needed**, CI only.",
                        "Follow-up: desktop#60.",
                        "Follow up: the Calls from Hermes entry's Desktop app line records the gap."):
            self.assertIsNone(check.problem(body(desktop)), desktop)

    def test_the_template_comment_alone_fails(self):
        self.assertIn("empty", check.problem(body("<!-- Done, Not needed or Follow-up -->")))

    def test_a_missing_section_fails(self):
        self.assertIn("no \"## Desktop\" section", check.problem("## Summary\nA change.\n"))
        self.assertIn("no \"## Desktop\" section", check.problem(None))

    def test_answers_that_say_too_little_fail(self):
        self.assertIn("names the desktop PR", check.problem(body("Done.")))
        # A hermes-conduit PR isn't the desktop's.
        self.assertIn("names the desktop PR", check.problem(body("Done: #2805.")))
        self.assertIn("says why", check.problem(body("Not needed.")))
        self.assertIn("Follow-up", check.problem(body("Follow-up")))
        self.assertIn("starts with", check.problem(body("Maybe later.")))

    def test_the_section_ends_at_the_next_heading(self):
        self.assertIn("empty", check.problem(body("", after="## Testing\nDone: desktop#58.\n")))
        self.assertIsNone(check.problem(body("Not needed: docs only.", after="")))

    def test_windows_line_endings_pass(self):
        self.assertIsNone(check.problem(body("Not needed: docs only.").replace("\n", "\r\n")))

    def test_the_pr_template_has_the_section(self):
        with open(os.path.join(ROOT, ".github", "pull_request_template.md"), encoding="utf-8") as fh:
            template = fh.read()
        # The template's own section is only a comment, so a PR has to fill it in.
        self.assertIn("empty", check.problem(template))

    def test_main_reads_the_body_from_the_environment(self):
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"PR_BODY": body("Not needed: docs only.")}), \
                contextlib.redirect_stdout(out):
            self.assertEqual(check.main(), 0)
        with mock.patch.dict(os.environ, {"PR_BODY": ""}), contextlib.redirect_stdout(out):
            self.assertEqual(check.main(), 1)
        self.assertIn("::error::", out.getvalue())


if __name__ == "__main__":
    unittest.main()
