#!/usr/bin/env python3
"""Fail when app text is set in a fixed point size.

`.font(.system(size: 11))` ignores the user's Text Size, so a label set that
way stays small at accessibility sizes while the text around it grows (#830).
Text uses a text style (`.caption2`, `.footnote`, ...) or a size scaled with
`@ScaledMetric(relativeTo:)` instead.

Text-level, like check-sheet-environment.py: a `Text(` whose modifier chain
(the same line, then each following line that starts with `.`) sets
`.system(size:` to a number literal is reported. Glyphs in fixed-size frames
(`Image(systemName:)` in a 32 pt circle) are left alone, and a size computed
from a scaled metric or a frame (`size * 0.42`) passes.

Text that really must keep its size, such as the small and large "A" around
the chat text size slider, says why in the comment lines just above:
`// Fixed size: <reason>`.

It reads line shapes, not Swift, so it misses a Text whose argument spans
lines (`Text(\n"Title"\n).font(...)`) and one that is itself an argument
(`.overlay(Text("x").font(...))`). It can also fail closed: a modifier line
after a comment is counted as the Text's, so a glyph's font there needs the
exemption.

A text style is set with `.scaledFont(.caption)`, not `.font(.caption)`: a
Mac draws every text style at one size, so a wide column there sets them in
points (ScaledFont.swift), which only `scaledFont` sees. Any `.font(` whose
argument names a text style is reported, unless the comment lines just
above say why it must stay a Font (`// Text style: <reason>`, such as a
`Text` joined with `+`, which needs `Text`'s own `font`). It reads one line at a
time, so a `.font(` whose argument starts the next line isn't seen.

Usage: check-fixed-text-sizes.py [--repo-root DIR]
"""

import argparse
import os
import re
import sys

SOURCE_DIRS = ("Conduit",)
TEXT_START = re.compile(r"\bText\s*\(")
FIXED_SIZE = re.compile(r"\.system\(size:\s*\d")
EXEMPTION = "// Fixed size:"
FONT_CALL = re.compile(r"\.font\(")
TEXT_STYLE = re.compile(
    r"(?:Font)?(?:\.system\()?\.(?:caption2?|footnote|subheadline|body|callout|"
    r"title[23]?|headline|largeTitle)\b")
TEXT_STYLE_EXEMPTION = "// Text style:"


def owning_text(line):
    """Where the first Text( that owns its modifier chain starts, or None.
    A Text passed as an argument, `.accessibilityLabel(Text("Add"))`, owns
    nothing after the closing parenthesis."""
    for match in TEXT_START.finditer(line):
        before = line[:match.start()].rstrip()
        if not before.endswith(("(", ",")):
            return match.start()
    return None


def stated_reason(lines, index, exemption=EXEMPTION):
    """Whether the comment lines just above line `index` say why."""
    above = index - 1
    while above >= 0 and lines[above].strip().startswith("//"):
        if exemption in lines[above]:
            return True
        above -= 1
    return False


def find_problems(sources):
    """sources: {path: text}. Returns ["path:line: ..."] for each fixed text size."""
    problems = []
    for path, text in sorted(sources.items()):
        lines = text.splitlines()
        for index, line in enumerate(lines):
            start = owning_text(line)
            if start is None:
                continue
            exempt = stated_reason(lines, index)
            chain = [(index, line[start:])]
            follow = index + 1
            while follow < len(lines):
                stripped = lines[follow].strip()
                if stripped.startswith("."):
                    chain.append((follow, lines[follow]))
                elif stripped and not stripped.startswith("//"):
                    break
                follow += 1
            for number, part in chain:
                if FIXED_SIZE.search(part) and not exempt:
                    problems.append(
                        f"{path}:{number + 1}: Text in a fixed point size ignores Text Size; "
                        "use a text style or @ScaledMetric(relativeTo:), or say why "
                        f"with '{EXEMPTION} ...' on the line above the Text")
    return problems


def font_argument(code, start):
    """The argument of the call whose parenthesis opens at `start`, up to
    its closing one, or the rest of the line."""
    depth = 0
    for end in range(start, len(code)):
        if code[end] == "(":
            depth += 1
        elif code[end] == ")":
            depth -= 1
            if depth == 0:
                return code[start + 1:end]
    return code[start + 1:]


def branches(argument):
    """The values an argument can take: each branch of a ternary (nested
    ones too) and each side of `??`, split at the top level, or the
    argument itself."""
    depth, question = 0, None
    for index, char in enumerate(argument):
        if char in "([":
            depth += 1
        elif char in ")]":
            depth -= 1
        elif depth == 0 and argument.startswith("??", index):
            return branches(argument[:index]) + branches(argument[index + 2:])
        elif depth == 0 and char == "?" and question is None and argument[index - 1:index].isspace():
            # A ternary's `?` stands apart; optional chaining's follows a name.
            question = index
        elif depth == 0 and char == ":" and question is not None:
            return branches(argument[question + 1:index]) + branches(argument[index + 1:])
    return [argument]


def without_comment(line):
    """The line up to a `//` comment outside a string literal."""
    quoted, escaped = False, False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
        elif quoted and char == "\\":
            escaped = True
        elif char == '"':
            quoted = not quoted
        elif not quoted and line.startswith("//", index):
            return line[:index]
    return line


def sets_text_style(code):
    """Whether a `.font(` on this line takes a text style, alone or as
    either branch of a ternary."""
    for match in FONT_CALL.finditer(code):
        argument = font_argument(code, match.end() - 1)
        if any(TEXT_STYLE.match(branch.strip()) for branch in branches(argument)):
            return True
    return False


def find_text_style_fonts(sources):
    """sources: {path: text}. Returns ["path:line: ..."] for each text style
    set with `.font(` rather than `.scaledFont(`."""
    problems = []
    for path, text in sorted(sources.items()):
        lines = text.splitlines()
        for index, line in enumerate(lines):
            code = without_comment(line)
            if sets_text_style(code) and not stated_reason(lines, index, TEXT_STYLE_EXEMPTION):
                problems.append(
                    f"{path}:{index + 1}: a text style set with .font( stays one size on a Mac; "
                    "use .scaledFont(, or say why with "
                    f"'{TEXT_STYLE_EXEMPTION} ...' on the line above")
    return problems


def load_sources(repo_root):
    sources = {}
    for directory in SOURCE_DIRS:
        for root, _, files in os.walk(os.path.join(repo_root, directory)):
            for name in files:
                if name.endswith(".swift"):
                    path = os.path.join(root, name)
                    with open(path, encoding="utf-8") as handle:
                        sources[os.path.relpath(path, repo_root)] = handle.read()
    return sources


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", default=".")
    args = parser.parse_args()
    sources = load_sources(args.repo_root)
    problems = find_problems(sources) + find_text_style_fonts(sources)
    if problems:
        print(f"FAIL: {len(problems)} fixed text size(s) or text style(s) set with .font(:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"OK: no fixed text sizes or .font( text styles in {len(sources)} Swift files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
