#!/usr/bin/env python3
"""Fail a pull request whose description doesn't say what Conduit for desktop
needs.

Conduit for desktop (hermes-conduit-desktop) draws most of what the phone
does, from the same Hermes and the same plugin, so a change here may need
the same change there. The PR template's Desktop section says which, in one
of three ways:

- Done, naming the desktop PR (hermes-conduit-desktop#58, desktop#58 or its
  link).
- Not needed, and why (the desktop app doesn't have the feature, a Watch or
  CarPlay change, CI or docs only).
- Follow-up, naming the desktop issue or PR, or the feature map entry whose
  Desktop app line records the gap.

CI passes the PR's description in PR_BODY (from the event, never through the
shell). A copy runs in hermes-conduit-notifier
(.github/scripts/check_pr_desktop.py): change both together.
"""

import os
import re
import sys

SECTION = re.compile(r"^##\s+Desktop\s*$", re.IGNORECASE | re.MULTILINE)
NEXT_SECTION = re.compile(r"^##\s", re.MULTILINE)
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)
# A fenced block, such as the template quoted in a PR that changes it.
# Its closing line repeats the opening run (or a longer one), so a ```` block
# that quotes a ``` block goes as a whole.
FENCE = re.compile(r"^[ \t]*(`{3,}|~{3,}).*?^[ \t]*\1[`~]*[ \t]*$", re.DOTALL | re.MULTILINE)
# A Follow-up that names nothing yet.
PLACEHOLDER = re.compile(r"^(later|tbd|todo|none|n/?a|soon|maybe)\W*$", re.IGNORECASE)
ANSWER = re.compile(r"^[\s>*_-]*(done|not needed|follow-up|follow up)\b[ \t:.,;()*_-]*(.*)",
                    re.IGNORECASE | re.DOTALL)
DESKTOP_PR = re.compile(r"\b(?:hermes-conduit-)?desktop#\d+|"
                        r"github\.com/kaishi00/hermes-conduit-desktop/(?:pull|issues)/\d+",
                        re.IGNORECASE)

HOW = ("Fill in the Desktop section of the PR description: \"Done: desktop#58\", "
       "\"Not needed: <why>\" or \"Follow-up: <desktop issue, or the feature map entry "
       "whose Desktop app line records the gap>\".")


def problem(body):
    """What's wrong with a PR description's Desktop section, or None."""
    body = FENCE.sub("", COMMENT.sub("", (body or "").replace("\r\n", "\n")))
    found = SECTION.search(body)
    if not found:
        return f"The PR description has no \"## Desktop\" section. {HOW}"
    rest = body[found.end():]
    after = NEXT_SECTION.search(rest)
    section = COMMENT.sub("", rest[:after.start()] if after else rest).strip()
    if not section:
        return f"The Desktop section is empty. {HOW}"
    answer = ANSWER.match(section)
    if not answer:
        return f"The Desktop section starts with Done, Not needed or Follow-up. {HOW}"
    said = answer.group(1).lower().replace("follow up", "follow-up")
    detail = answer.group(2)
    first_line = detail.split("\n")[0]
    detail = detail.strip()
    if said == "done" and not DESKTOP_PR.search(first_line):
        return ("The Desktop section says Done, so it names the desktop PR "
                "(hermes-conduit-desktop#58, desktop#58 or its link).")
    if said == "not needed" and not detail:
        return "The Desktop section says Not needed, so it says why."
    if said == "follow-up" and (not detail or PLACEHOLDER.match(detail)):
        return ("The Desktop section says Follow-up, so it names the desktop issue or PR, or "
                "the feature map entry whose Desktop app line records the gap.")
    return None


def main():
    found = problem(os.environ.get("PR_BODY", ""))
    if found:
        print(f"::error::{found}")
        return 1
    print("The Desktop section says what Conduit for desktop needs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
