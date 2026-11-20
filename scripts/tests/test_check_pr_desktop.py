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
        # Done names the desktop PR in its own answer, not in an aside.
        self.assertIn("names the desktop PR", check.problem(body("Done.\nTracked as desktop#58.")))

    def test_a_fenced_heading_isnt_the_section(self):
        quoted = "## Summary\nThe template now reads:\n```\n## Desktop\nDone: desktop#58.\n```\n\n"
        self.assertIn("inside a code fence", check.problem(quoted))
        self.assertIsNone(check.problem(quoted + "## Desktop\nNot needed: template only.\n"))
        nested = "## Summary\n````markdown\n```markdown\n## Desktop\nDone: desktop#58.\n```\n````\n"
        self.assertIn("inside a code fence", check.problem(nested))
        unclosed = "## Summary\n```\n## Desktop\nDone: desktop#58.\n"
        self.assertIn("inside a code fence", check.problem(unclosed))

    def test_fences_end_as_github_draws_them(self):
        # Four spaces of indent is an indented code block, not a fence.
        indented = "## Summary\nRun:\n\n    ```\n    npm test\n\n## Desktop\nNot needed: docs only.\n"
        self.assertIsNone(check.problem(indented))
        # A closing line of the other character doesn't end the block.
        mixed = "## Summary\n```\n```~\n## Desktop\nDone: desktop#58.\n```\n"
        self.assertIn("inside a code fence", check.problem(mixed))
        tildes = "## Summary\n~~~\n~~~`\n## Desktop\nDone: desktop#58.\n~~~~\n"
        self.assertIn("inside a code fence", check.problem(tildes))
        # A longer run of the same character closes it.
        longer = "## Summary\n```\n## Desktop\nDone: desktop#58.\n`````\n\n## Desktop\nNot needed: docs.\n"
        self.assertIsNone(check.problem(longer))
        self.assertIsNone(check.problem(longer.replace("```", "~~~").replace("``", "~~")))
        # A fence in a list item closes at the item's indent.
        listed = "## Summary\n- ```bash\n  npm test\n  ```\n\n## Desktop\nNot needed: docs only.\n"
        self.assertIsNone(check.problem(listed))
        self.assertIsNone(check.problem(listed.replace("- ", "1. ").replace("\n  ", "\n   ")))
        # A line GitHub keeps as code doesn't close the block.
        deep = "## Summary\n```\nsample:\n    ```\n\n## Desktop\nNot needed: docs.\n"
        self.assertIn("inside a code fence", check.problem(deep))
        self.assertIn("inside a code fence", check.problem(listed.replace("  ```", "```")))
        # A list marker four spaces in is indented code, not a list.
        coded = "## Summary\n    - ```bash\n    npm test\n\n## Desktop\nNot needed: docs.\n"
        self.assertIsNone(check.problem(coded))

    def test_list_fences_info_strings_and_digits_as_github_draws_them(self):
        # notifier 924: a list item's fence closes only within three spaces
        # of the item's content indent, so six spaces in is code and the
        # closer after it ends the block; one space in ends the item, its
        # line then opening a fence of its own that hides what follows.
        six = "## Summary\n- ```bash\n  npm test\n      ```\n   ```\n\n## Desktop\nNot needed: docs.\n"
        self.assertIsNone(check.problem(six))
        one = "## Summary\n- ```bash\n  npm test\n ```\n## Desktop\nDone: desktop#58.\n"
        self.assertIn("inside a code fence", check.problem(one))
        # The line that ends the item is kept as it is: a heading shows.
        ended = "## Summary\n- ```bash\n  npm test\n## Desktop\nNot needed: docs only.\n"
        self.assertIsNone(check.problem(ended))
        # A backtick fence whose info string has a backtick is a paragraph.
        ticked = "## Summary\n``` js `x`\n\n## Desktop\nNot needed: docs.\n"
        self.assertIsNone(check.problem(ticked))
        self.assertIsNotNone(check.problem(ticked.replace("```", "~~~")), "a tilde fence may hold one")
        # Only ASCII digits make a list marker.
        self.assertIsNone(check.problem("## Summary\n\u0661. ```\n## Desktop\nNot needed: docs.\n"))

    def test_done_names_a_pr_not_an_issue(self):
        issue = "Done: https://github.com/kaishi00/hermes-conduit-desktop/issues/59"
        self.assertIn("An issue goes under Follow-up", check.problem(body(issue)))
        self.assertIsNone(check.problem(body(issue.replace("Done", "Follow-up"))))

    def test_a_follow_up_names_something(self):
        for placeholder in ("Follow-up: later", "Follow-up: TBD.", "Follow-up: none"):
            self.assertIn("Follow-up", check.problem(body(placeholder)), placeholder)

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

    def test_the_workflow_hands_the_body_over_in_the_environment(self):
        """The description is untrusted text: it reaches the script as PR_BODY,
        never through the shell, and reruns when it is edited."""
        with open(os.path.join(ROOT, ".github", "workflows", "pr-desktop.yml"), encoding="utf-8") as fh:
            workflow = fh.read()
        self.assertIn("PR_BODY: ${{ github.event.pull_request.body }}", workflow)
        self.assertIn("run: python3 scripts/check-pr-desktop.py\n", workflow)
        self.assertEqual(workflow.count("github.event.pull_request.body"), 1)
        self.assertIn("edited", workflow)

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
