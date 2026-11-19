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
# A fenced block, such as the template quoted in a PR that changes it, read
# line by line as GitHub draws it. It opens with up to three spaces of indent
# (four is an indented code block, which GitHub draws without treating the
# ticks as a fence); a backtick fence whose info string has a backtick is a
# paragraph. Its closing line, also within three spaces, repeats the opening
# run or a longer run of the same character, so a ```` block that quotes a
# ``` block goes as a whole. One opened on a list marker's line belongs to
# the item: it closes only on a line within three spaces of the item's
# content indent, and a line indented less than that ends the item and the
# fence with it (that line may open a fence of its own). A fence opened on a
# later line of an item isn't tied to it: it closes as one at the margin. One never closed runs to the
# end, as GitHub draws it. ASCII digits only in a list marker.
OPENER = re.compile(r"^( {0,3})((?:[-*+]|[0-9]{1,9}[.)])[ \t]+)?(`{3,}|~{3,})(.*)$")
CLOSER = re.compile(r"^( *)(`{3,}|~{3,})[ \t]*$")


def unfenced(body):
    """`body` without its fenced blocks."""
    kept = []
    fence = None  # (character, run length, content indent, in a list item)
    for raw in body.split("\n"):
        line = raw.expandtabs(4)
        if fence:
            char, run, indent, in_item = fence
            stripped = line.lstrip(" ")
            spaces = len(line) - len(stripped)
            if in_item and stripped and spaces < indent:
                fence = None  # The item ends here, and its fence with it.
            else:
                close = CLOSER.match(line)
                if close and close.group(2)[0] == char and len(close.group(2)) >= run \
                        and len(close.group(1)) - indent <= 3:
                    fence = None
                continue
        opened = OPENER.match(line)
        if opened and not (opened.group(3)[0] == "`" and "`" in opened.group(4)):
            marker = opened.group(2) or ""
            # A closer counts its indent from the item's content, else from the margin.
            indent = len(opened.group(1)) + len(marker) if marker else 0
            fence = (opened.group(3)[0], len(opened.group(3)), indent, bool(marker))
            continue
        kept.append(raw)
    return "\n".join(kept)


# A Follow-up that names nothing yet.
PLACEHOLDER = re.compile(r"^(later|tbd|todo|none|n/?a|soon|maybe)\W*$", re.IGNORECASE)
ANSWER = re.compile(r"^[\s>*_-]*(done|not needed|follow-up|follow up)\b[ \t:.,;()*_-]*(.*)",
                    re.IGNORECASE | re.DOTALL)
DESKTOP_PR = re.compile(r"\b(?:hermes-conduit-)?desktop#\d+|"
                        r"github\.com/kaishi00/hermes-conduit-desktop/pull/\d+",
                        re.IGNORECASE)

HOW = ("Fill in the Desktop section of the PR description: \"Done: desktop#58\", "
       "\"Not needed: <why>\" or \"Follow-up: <desktop issue, or the feature map entry "
       "whose Desktop app line records the gap>\".")


def problem(body):
    """What's wrong with a PR description's Desktop section, or None."""
    body = COMMENT.sub("", (body or "").replace("\r\n", "\n"))
    fenced, body = body, unfenced(body)
    found = SECTION.search(body)
    if not found and SECTION.search(fenced):
        return ("The Desktop section is inside a code fence, which shows it as code: close "
                "the fence above it.")
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
        return ("The Desktop section says Done, so it names the desktop PR on the Done line "
                "(hermes-conduit-desktop#58, desktop#58 or its link). An issue goes under "
                "Follow-up.")
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
