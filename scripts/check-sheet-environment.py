#!/usr/bin/env python3
"""Fail when a sheet's content needs an environment object it isn't handed.

SwiftUI is meant to carry `@EnvironmentObject`s across a `.sheet` boundary,
but on a Mac (0.1.18 build 199) the sidebar drawer was rendered without
`AppState` and crashed in `EnvironmentObject.error()`. So every presentation
whose content reads an environment object - directly or through any view it
builds - injects it explicitly with `.environmentObject(...)`.

Text-level, like check-l10n-coverage.py: it parses Swift just far enough to
find view structs, their `@EnvironmentObject` dependencies, the views each one
builds, and the content closure of every `.sheet` / `.fullScreenCover` /
`.popover`. A view's needs are its own dependencies plus those of every view
it references that it doesn't inject itself (a view that owns a store and
injects it, like KanbanView, satisfies its children; a view that reads an
object and passes it on still needs it from above).

Known limits, none of which occur in the app today:
- Injections count for the whole content closure, not the branch they are
  attached to: in `Group { Foo().environmentObject(x); Child() }` the
  injection on Foo satisfies Child too.
- Only structs declaring `View` are followed, so a UIViewControllerRepresentable
  (or a type-erased AnyView) with environment needs is invisible.
- An injection resolves through its head only: `.environmentObject(appState)`
  or `.environmentObject(Store.shared)` count, `.environmentObject(model.appState)`
  or one through a closure parameter doesn't (a false failure, never a miss).

Usage: check-sheet-environment.py [--repo-root DIR]
"""

import argparse
import os
import re
import sys

SOURCE_DIRS = ("Conduit", "ConduitWatch", "ConduitWidgets", "ConduitNotificationService", "Shared")
PRESENTATIONS = re.compile(r"\.(sheet|fullScreenCover|popover)\s*\(")
VIEW_DECL = re.compile(r"\bstruct\s+(\w+)\s*(?:<[^>{]*>)?\s*:\s*([^{]*)\{")
EXTENSION_DECL = re.compile(r"\bextension\s+(\w+)\b[^{]*\{")
ENV_OBJECT = re.compile(r"@EnvironmentObject\s+(?:(?:private|fileprivate)\s+)?var\s+(\w+)\s*:\s*(\w+)")
TYPED_OBJECT = re.compile(
    r"@(?:StateObject|ObservedObject|EnvironmentObject)\s+(?:(?:private|fileprivate)\s+)?var\s+(\w+)"
    r"\s*(?::\s*(\w+))?\s*(?:=\s*(\w+)\s*[.(])?")
PLAIN_PROPERTY = re.compile(r"\b(?:let|var)\s+(\w+)\s*:\s*([A-Z]\w*)\b")
INJECTION = re.compile(r"\.environmentObject\(\s*([A-Za-z_][\w.]*)")
TYPE_REF = re.compile(r"\b([A-Z]\w*)\s*[.({<]")
# A bare identifier the content uses as a value: not a member access
# (`.font(.body)`) and not an argument label (`rootPath:`).
HELPER_REF = re.compile(r"(?<![.\w])([a-z]\w*)\b(?!\s*:)")
VIEW_MEMBER = re.compile(
    r"\b(?:var\s+(\w+)\s*:\s*some\s+View|func\s+(\w+)\s*(?:<[^>]*>)?\([^{]*?\)\s*->\s*some\s+View)\s*\{")


def strip_comments(text):
    """Blanks comments and string contents, keeping offsets (and line numbers) intact."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out[i:j] = " " * (j - i)
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out[i:j] = [c if c == "\n" else " " for c in text[i:j]]
            i = j
        elif text[i] == '"' or (text[i] == "#" and re.match(r'#+"', text[i:])):
            # Raw strings (#"…"#) close on a quote followed by the same
            # number of hashes; multiline strings (""") on the next """.
            hashes = len(text[i:]) - len(text[i:].lstrip("#"))
            start = i + hashes
            multiline = text.startswith('"""', start)
            opener = '"""' if multiline else '"'
            closer = opener + "#" * hashes
            j = start + len(opener)
            while j < n:
                if text.startswith(closer, j):
                    break
                if not multiline and text[j] == "\n":
                    break
                if text[j] == "\\" and not hashes and j + 1 < n and text[j + 1] != "\n":
                    j += 2
                else:
                    j += 1
            for k in range(start + len(opener), min(j, n)):
                if out[k] != "\n":
                    out[k] = " "
            i = j + len(closer)
        else:
            i += 1
    return "".join(out)


def block_end(text, open_index):
    """Index just past the brace or paren that closes the one at open_index."""
    pairs = {"{": "}", "(": ")"}
    opener = text[open_index]
    closer = pairs[opener]
    depth = 0
    for j in range(open_index, len(text)):
        if text[j] == opener:
            depth += 1
        elif text[j] == closer:
            depth -= 1
            if depth == 0:
                return j + 1
    return len(text)


class Index:
    def __init__(self, sources):
        # sources: {path: comment-stripped text}
        self.sources = sources
        self.views = {}       # name -> list of (path, start, end)
        self.spans = []       # (path, start, end, type name) for structs and extensions
        for path, text in sources.items():
            for m in VIEW_DECL.finditer(text):
                end = block_end(text, m.end() - 1)
                self.spans.append((path, m.start(), end, m.group(1)))
                if re.search(r"\bView\b", m.group(2)):
                    self.views.setdefault(m.group(1), []).append((path, m.start(), end))
            for m in EXTENSION_DECL.finditer(text):
                end = block_end(text, m.end() - 1)
                self.spans.append((path, m.start(), end, m.group(1)))
        self._needs = {}
        # Every type some view reads as an environment object; a plain stored
        # property of one of these types can be injected too.
        self.env_types = {m.group(2) for text in sources.values() for m in ENV_OBJECT.finditer(text)}

    def bodies(self, name):
        """All source text belonging to a type: its declarations and extensions."""
        return [self.sources[p][s:e] for p, s, e, n in self.spans if n == name]

    def object_types(self, name):
        """Variable name -> ObservableObject type for objects the type holds."""
        types = {}
        for body in self.bodies(name):
            for m in TYPED_OBJECT.finditer(body):
                held = m.group(2) or m.group(3)
                if held:
                    types[m.group(1)] = held
            for m in PLAIN_PROPERTY.finditer(body):
                if m.group(2) in self.env_types:
                    types.setdefault(m.group(1), m.group(2))
        return types

    def injected_types(self, text, owner):
        held = self.object_types(owner) if owner else {}
        found = set()
        for m in INJECTION.finditer(text):
            expr = m.group(1)
            if expr.startswith("self."):
                expr = expr[len("self."):]
            head = expr.split(".")[0]
            if head in held:
                found.add(held[head])
            elif head[:1].isupper():
                found.add(head)  # `Store.shared`, `Store()`
        return found

    def needs(self, name):
        return self._walk(name, ())[0]

    def _walk(self, name, stack):
        """(needs, ancestors cut short): a result that met a cycle back to an
        ancestor lacks that ancestor's contribution, so it is never cached;
        it is complete only once the walk is back at that ancestor."""
        if name in self._needs:
            return self._needs[name], set()
        if name in stack:
            return set(), {name}
        own, refs, provided = set(), set(), set()
        for body in self.bodies(name):
            own |= {m.group(2) for m in ENV_OBJECT.finditer(body)}
            outside = without_presentations(body)
            refs |= {r for r in TYPE_REF.findall(outside) if r in self.views and r != name}
            provided |= self.injected_types(outside, name)
        children, cut = set(), set()
        for ref in refs:
            ref_needs, ref_cut = self._walk(ref, stack + (name,))
            children |= ref_needs
            cut |= ref_cut
        # What a view injects reaches only the views it builds; its own
        # environment reads still have to come from above.
        result = own | (children - provided)
        cut.discard(name)
        if not cut:
            self._needs[name] = result
        return result, cut

    def owner_at(self, path, offset):
        """Innermost struct or extension containing offset."""
        best = None
        for p, s, e, n in self.spans:
            if p == path and s <= offset < e and (best is None or s > best[0]):
                best = (s, n)
        return best[1] if best else None

    def member_bodies(self, owner, names):
        """Bodies of the owner's view-building members named in `names`."""
        out = []
        for body in self.bodies(owner):
            for m in VIEW_MEMBER.finditer(body):
                if (m.group(1) or m.group(2)) in names:
                    out.append(body[m.end() - 1:block_end(body, m.end() - 1)])
        return out


def content_span(text, call_open_paren):
    """(start, end) of the presentation's content: its trailing closure, else
    a `content:` closure argument. None when there is neither."""
    close = block_end(text, call_open_paren)
    rest = text[close:]
    stripped = rest.lstrip()
    if stripped.startswith("{"):
        start = close + (len(rest) - len(stripped))
        return start, block_end(text, start)
    last = text.rfind("content:", call_open_paren, close)
    if last >= 0:
        brace = text.find("{", last, close)
        if brace >= 0:
            return brace, block_end(text, brace)
    return None


def content_closure(text, call_open_paren):
    span = content_span(text, call_open_paren)
    return text[span[0]:span[1]] if span else ""


def without_presentations(text):
    """The text with every presentation's content blanked: what a sheet shows
    is checked at the sheet, and what a view injects into its own sheets
    supplies only those sheets, never the view itself."""
    out = list(text)
    for m in PRESENTATIONS.finditer(text):
        span = content_span(text, m.end() - 1)
        if span:
            for k in range(*span):
                if out[k] != "\n":
                    out[k] = " "
    return "".join(out)


def find_problems(sources):
    index = Index(sources)
    problems = []
    for path in sorted(sources):
        text = sources[path]
        for m in PRESENTATIONS.finditer(text):
            content = content_closure(text, m.end() - 1)
            line = text.count("\n", 0, m.start()) + 1
            if not content:
                problems.append(
                    f"{path}:{line}: .{m.group(1)} content isn't a closure this check can read; "
                    f"write it as a trailing closure")
                continue
            owner = index.owner_at(path, m.start())
            texts = [content]
            if owner:
                # Helpers the content builds, and the helpers those build.
                seen = set()
                frontier = [content]
                while frontier:
                    chunk = re.sub(r"\bself\.", "", frontier.pop())
                    names = set(HELPER_REF.findall(chunk)) - seen - {"body"}
                    seen |= names
                    for member in index.member_bodies(owner, names):
                        texts.append(member)
                        frontier.append(member)
            # Sheets nested inside this content or its helpers are checked
            # on their own; nothing in them supplies this one.
            texts = [without_presentations(chunk) for chunk in texts]
            needed = set()
            for chunk in texts:
                for ref in TYPE_REF.findall(chunk):
                    if ref in index.views:
                        needed |= index.needs(ref)
            injected = set()
            for chunk in texts:
                injected |= index.injected_types(chunk, owner)
            missing = sorted(needed - injected)
            if missing:
                held = {t: v for v, t in index.object_types(owner).items()} if owner else {}
                fixes = ", ".join(f".environmentObject({held.get(t, '<' + t + '>')})" for t in missing)
                problems.append(
                    f"{path}:{line}: .{m.group(1)} content needs {', '.join(missing)} "
                    f"but doesn't inject it; add {fixes}")
    return problems


def load_sources(repo_root):
    sources = {}
    for top in SOURCE_DIRS:
        for dirpath, _, files in os.walk(os.path.join(repo_root, top)):
            for name in files:
                if name.endswith(".swift"):
                    full = os.path.join(dirpath, name)
                    with open(full, encoding="utf-8") as f:
                        sources[os.path.relpath(full, repo_root)] = strip_comments(f.read())
    return sources


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    args = parser.parse_args(argv)
    sources = load_sources(args.repo_root)
    if not sources:
        print(f"FAIL: no Swift sources under {args.repo_root} ({', '.join(SOURCE_DIRS)}).")
        return 1
    problems = find_problems(sources)
    for problem in problems:
        print(problem)
    if problems:
        print(f"FAIL: {len(problems)} presentation(s) rely on environment inheritance across a sheet boundary.")
        return 1
    print(f"OK: every sheet, full-screen cover and popover injects the environment objects its content reads "
          f"({len(sources)} Swift files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
