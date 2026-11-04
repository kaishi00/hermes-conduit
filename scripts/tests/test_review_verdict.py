"""The review workflow (opencode-review.yml) runs the second reviewer only
when the gate reviewer's verdict isn't REQUEST_CHANGES. It reads that
verdict from the comment the gate job posted: a jq filter picks the job's
comment by the run and model in opencode's footer, and an inline script
(VERDICT_PY) takes the verdict line. These hold both to the comments
opencode posts."""

import json
import os
import shutil
import subprocess
import sys
import textwrap
import unittest

WORKFLOW = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        os.pardir, ".github", "workflows", "opencode-review.yml")


def _inline(name):
    with open(WORKFLOW, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    start = lines.index(f"          {name}: |") + 1
    body = []
    for line in lines[start:]:
        if line.strip() and not line.startswith("            "):
            break
        body.append(line)
    return textwrap.dedent("\n".join(body))


def _jq_filter():
    with open(WORKFLOW, encoding="utf-8") as fh:
        text = fh.read()
    start = text.index("--jq '.[] | select(.user.login") + len("--jq '")
    return text[start:text.index("| .body | @json'", start) + len("| .body | @json")]


def comment(verdict_text, run_id="41", model="zai-custom/glm-5.3-flash", created="2026-11-03T23:00:05Z",
            login="github-actions[bot]"):
    body = ("Review by GLM-5.3-Flash\n\n## Summary\nx\n\n## Findings\nnone\n\n## Verdict\n" + verdict_text
            + f'\n\n<a href="https://opencode.ai/s/a"><img src="https://x/y.png?model={model}&version=1&id=a" /></a>\n'
            + f"[opencode session](https://opencode.ai/s/a)&nbsp;|&nbsp;[github run](/o/r/actions/runs/{run_id})")
    return {"user": {"login": login}, "created_at": created, "body": body}


def verdict(lines):
    run = subprocess.run([sys.executable, "-I", "-c", _inline("VERDICT_PY")], input="\n".join(lines),
                         capture_output=True, text=True, check=True)
    return run.stdout.strip()


class VerdictTests(unittest.TestCase):
    def body(self, text):
        return json.dumps(comment(text)["body"])

    def test_reads_each_verdict(self):
        for word in ("APPROVE", "REQUEST_CHANGES", "COMMENT"):
            self.assertEqual(verdict([self.body(word)]), word)

    def test_the_rubric_sentence_isnt_the_verdict(self):
        text = "REQUEST_CHANGES if any finding is critical or major, otherwise APPROVE.\n\nAPPROVE"
        self.assertEqual(verdict([self.body(text)]), "APPROVE")

    def test_bold_verdict(self):
        self.assertEqual(verdict([self.body("**REQUEST_CHANGES**")]), "REQUEST_CHANGES")

    def test_the_newest_comment_wins(self):
        self.assertEqual(verdict([self.body("REQUEST_CHANGES"), self.body("APPROVE")]), "APPROVE")

    def test_nothing_found_is_empty(self):
        self.assertEqual(verdict([]), "")
        self.assertEqual(verdict([json.dumps("no verdict here")]), "")


class GateTests(unittest.TestCase):
    def test_second_review_waits_on_a_gate_that_passed_without_blockers(self):
        with open(WORKFLOW, encoding="utf-8") as fh:
            text = fh.read()
        job = text[text.index("\n  second-review:\n"):]
        self.assertIn("    needs: [plan, review]\n", job)
        self.assertIn("    if: needs.plan.outputs.second != '[]' && needs.review.result == 'success'"
                      " && needs.review.outputs.verdict != 'REQUEST_CHANGES'\n", job)


@unittest.skipUnless(shutil.which("jq"), "jq isn't installed")
class CommentFilterTests(unittest.TestCase):
    def pick(self, comments):
        env = dict(os.environ, SINCE="2026-11-03T23:00:00Z", GITHUB_RUN_ID="41", MODEL="zai-custom/glm-5.3-flash")
        run = subprocess.run(["jq", "-r", _jq_filter()], input=json.dumps(comments), env=env,
                             capture_output=True, text=True, check=True)
        return [l for l in run.stdout.split("\n") if l]

    def test_takes_this_runs_comment_from_this_model(self):
        mine = comment("APPROVE")
        others = [comment("REQUEST_CHANGES", run_id="40"),
                  comment("REQUEST_CHANGES", run_id="411"),
                  comment("REQUEST_CHANGES", model="go-custom/beam-free"),
                  comment("REQUEST_CHANGES", created="2026-11-03T22:59:59Z"),
                  comment("REQUEST_CHANGES", login="someone")]
        self.assertEqual(self.pick(others + [mine]), [json.dumps(mine["body"])])
        self.assertEqual(verdict(self.pick(others + [mine])), "APPROVE")


if __name__ == "__main__":
    unittest.main()
