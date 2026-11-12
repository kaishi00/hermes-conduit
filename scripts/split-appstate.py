#!/usr/bin/env python3
"""Move parts of Conduit/Services/AppState.swift into files of their own.

Issue 828, stage 1. AppState.swift is one class of about 45,000 lines, and
every PR touches it. This script moves its code into `AppState+<Area>.swift`
extensions, region by region (a region runs from one `// MARK: - <Name>` in
the class body to the next), and the types around the class into files of
their own. It changes no code, except:

- Stored instance properties, `init` and `deinit` stay in AppState.swift
  (an extension can't hold them), under their region's MARK.
- A `private` or `fileprivate` declaration that another file now uses
  becomes internal (`private(set)` likewise, when another file now writes
  it), since Swift has no access level that spans an extension's files.

It is deterministic, so a branch that still edits the old file can take
main's split by running it on its own copy (see `--help`):

    python3 scripts/split-appstate.py regions            # the regions and their sizes
    python3 scripts/split-appstate.py plan --step 2      # what step 2 moves and widens
    python3 scripts/split-appstate.py write --step 2     # make step 2's moves

`STEPS` below lists each PR's moves, in order. A step runs on a file the
steps before it already ran on, as main's is once their PRs merge. `write
--pr N` also points the feature map's paths at the new files and names PR N
on the Checked line of each entry it changes.
"""

import argparse
import re
import sys
from collections import OrderedDict
from pathlib import Path

APP_STATE = "Conduit/Services/AppState.swift"
SERVICES = "Conduit/Services"

# Each step is one PR. A step maps a new file's name to what moves there:
# region names in the class body (with "@2" for a name's second region), or
# for the types around the class, "file:<TypeName>".
STEPS = [
    # 1: the types around the class, and its trailing extensions
    {
        "ChatResumeRecovery.swift": [
            "file:ChatResumeReconnectCancellation", "file:ChatResumeReconnectExecutor",
            "file:ChatResumeReconnectScheduler", "file:ChatResumeLifecycleOperations",
            "file:scheduleChatResumeReconnectTask", "file:ChatResumeReconnectSchedulingDecision",
            "file:ChatResumeConversationReplacement", "file:ChatResumeSyncExecutionOutcome",
            "file:ChatResumeTransportContinuation", "file:ChatResumeRecoverySequence",
        ],
        "AppStateSupportTypes.swift": [
            "file:ProfileOwnershipVerdict", "file:GroupChatLifecycleOperations",
            "file:PersistedTranscriptFetchOutcome", "file:PersistedTranscriptOutcome",
            "file:PersistedSessionTranscript", "file:ComposerSubmissionContext",
            "file:ConversationAgentIdentity",
        ],
        "SessionCatalogCache.swift": ["file:SessionCatalogCache"],
        "KeychainHelper.swift": ["outer:Keychain Helper"],
        "AttachmentHelper.swift": ["file:AttachmentHelper", "file:AttachmentError"],
        "CapabilityLoadPolicy.swift": [
            "file:CapabilitySnapshotOwner", "file:CapabilityDetailScope", "file:CapabilityLoadPolicy",
        ],
        "AppState+AllProfilesChats.swift": ["outer:All profiles in one Chats list"],
        "AppState+LinkedRoomsInGroups.swift": [
            "outer:Linked Rooms' drafts removed from Group Chats",
            "outer:Linked Rooms' invites removed from Group Chats",
        ],
    },
    # 2: connection and lifecycle
    {
        "AppState+Connection.swift": [
            "Connection", "Connection management", "Connection Repair (Round 6)",
            "Reconnect and scene lifecycle",
        ],
        "AppState+ConnectionTimeline.swift": ["Connection timeline (#417)"],
        "AppState+Lifecycle.swift": ["Lifecycle coordination", "Foreground observational refresh"],
    },
    # 3: reconciliation and freshness
    {
        "AppState+Reconciliation.swift": ["Authoritative reconciliation"],
        "AppState+TranscriptFreshness.swift": ["Cross-surface transcript freshness"],
        "AppState+OneChatTwoDevices.swift": ["One chat on two devices"],
    },
    # 4: rooms, bots and profile pictures
    {
        # Group Chats and Profile photos both run on past their own code into
        # code with no MARK of its own: profile settings, and opening chats.
        "AppState+GroupChats.swift": ["Group Chats (hosted rooms)|until retireSpeechOperationsForServerReplacement"],
        "AppState+ProfileSettings.swift": ["Group Chats (hosted rooms)|from retireSpeechOperationsForServerReplacement"],
        "AppState+BotMode.swift": [
            "Bot Mode", "Bot Mode (roster + canonical chat)",
            "Bot management (create / edit / delete / avatars)",
        ],
        "AppState+ProfilePhotos.swift": ["Profile photos from Hermes|until openWidgetConversation"],
        "AppState+OpenChat.swift": ["Profile photos from Hermes|from openWidgetConversation"],
    },
    # 5: voice
    {
        "AppState+Voice.swift": [
            "Voice history|until openAppLink",
            "Voice history|from dismissChatCallTranscript until isSessionPinned",
        ],
        "AppState+AppLinks.swift": ["Voice history|from openAppLink until dismissChatCallTranscript"],
        "AppState+PinnedChatOrder.swift": ["Voice history|from isSessionPinned"],
        "AppState+WakePhrase.swift": ["Wake phrase (#174)"],
    },
    # 6: chats, their list and what's kept on the phone
    {
        "AppState+Session.swift": [
            "Session", "Session management", "New Chat",
            "Read state (#454)|from setActiveSessionState",
        ],
        "AppState+ChatList.swift": [
            "Saved chat list", "Stars (#757)", "Read state (#454)|until removePinnedState",
        ],
        "AppState+Persistence.swift": [
            "Persistence|until restorePinnedSessions", "Offline chat cache (#99)",
        ],
        "AppState+PinSync.swift": [
            "Persistence|from restorePinnedSessions until showNotice",
            "Persistence|from dismissPinSyncNotice until isVoiceJobSession",
            "Read state (#454)|from removePinnedState until pendingDecisionRestorationMessages",
        ],
        "AppState+Notices.swift": ["Persistence|from showNotice until dismissPinSyncNotice"],
        "AppState+Voice.swift": ["Persistence|from isVoiceJobSession"],
        "AppState+Reconciliation.swift": [
            "Read state (#454)|from pendingDecisionRestorationMessages until setActiveSessionState",
        ],
        "AppState+SessionReferences.swift": [
            "Session references (durable conversation identity)|until cancelScheduledReconnect",
            "Secondary profile title recovery",
        ],
        "AppState+ChatResume.swift": [
            "Session references (durable conversation identity)|from cancelScheduledReconnect",
        ],
        "AppState+PendingSend.swift": ["Sending while connecting: what reads private state"],
    },
    # 7: the composer and a turn's stream
    {
        "AppState+Composer.swift": [
            "Quoting into the composer (#385)", "Reactions", "Composer actions",
        ],
        "AppState+ChatTakeover.swift": ["Chat takeover"],
        "AppState+SlashCommands.swift": ["Slash Commands"],
        "AppState+Compression.swift": ["Session compression (`session.compress`)"],
        "AppState+StreamEvents.swift": ["Stream event handling"],
        "AppState+Clarify.swift": ["Clarify lifecycle"],
        "AppState+ChatSupport.swift": ["Chat support surfaces"],
    },
    # 8: profiles, capabilities, dashboards and jobs
    {
        "AppState+Profiles.swift": ["Profiles and preferences"],
        "AppState+Capabilities.swift": ["Capabilities", "Capabilities@2", "Tools catalog for step rows"],
        "AppState+ScheduledJobs.swift": ["Scheduled jobs"],
        "AppState+Dashboards.swift": ["Saved dashboards (#148)", "Dashboard-scoped presentation (#148)"],
        "AppState+UIState.swift": ["UI state", "Runtime"],
    },
]

MODIFIERS = {
    "private", "fileprivate", "internal", "public", "open", "private(set)",
    "fileprivate(set)", "internal(set)", "static", "class", "final", "override",
    "nonisolated", "lazy", "weak", "unowned", "mutating", "nonmutating",
    "convenience", "required", "dynamic", "indirect", "isolated",
}
DECL_KEYWORDS = {
    "func", "var", "let", "init", "deinit", "subscript", "enum", "struct",
    "class", "actor", "typealias", "protocol", "extension",
}


# ---------------------------------------------------------------- lexing

def mask_code(src):
    """Return src with comments and string contents blanked (newlines kept,
    interpolations kept as code), so brackets and names can be read."""
    out = list(src)
    n = len(src)
    i = 0
    # stack of contexts: ("code", paren_depth_for_interp) or string frames
    stack = [("code", None)]

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        kind = stack[-1][0]
        c = src[i]
        if kind == "code":
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j < 0 else j
                blank(i, j)
                i = j
                continue
            if src.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if src.startswith("/*", j):
                        depth += 1
                        j += 2
                    elif src.startswith("*/", j):
                        depth -= 1
                        j += 2
                    else:
                        j += 1
                blank(i, j)
                i = j
                continue
            m = re.match(r'(#*)("""|")', src[i:i + 12])
            if m and (m.group(1) == "" or c == "#"):
                hashes = len(m.group(1))
                quote = m.group(2)
                start = i + len(m.group(0))
                stack.append(("str", (hashes, quote)))
                i = start
                continue
            if c == "(" and stack[-1][1] is not None:
                stack[-1] = ("code", stack[-1][1] + 1)
            elif c == ")" and stack[-1][1] is not None:
                if stack[-1][1] == 0:
                    stack.pop()  # back into the string
                    i += 1
                    continue
                stack[-1] = ("code", stack[-1][1] - 1)
            i += 1
            continue
        # inside a string
        hashes, quote = stack[-1][1]
        close = quote + "#" * hashes
        esc = "\\" + "#" * hashes
        if src.startswith(close, i):
            stack.pop()
            i += len(close)
            continue
        if src.startswith(esc, i):
            j = i + len(esc)
            if j < n and src[j] == "(":
                blank(i, j)
                stack.append(("code", 0))
                i = j + 1
                continue
            blank(i, min(j + 1, n))
            i = j + 1
            continue
        if c == "\n" and quote == '"':
            stack.pop()  # unterminated; be forgiving
            i += 1
            continue
        if c != "\n":
            out[i] = " "
        i += 1
    return "".join(out)


def line_depths(masked_lines):
    """Bracket depth at the start of each line."""
    depths, d = [], 0
    for line in masked_lines:
        depths.append(d)
        for ch in line:
            if ch in "({[":
                d += 1
            elif ch in ")}]":
                d -= 1
    return depths


# ---------------------------------------------------------------- items

class Item:
    def __init__(self, start, end, kind, names, movable, region, decl_line):
        self.start, self.end = start, end  # line indexes, end exclusive
        self.kind = kind
        self.names = names
        self.movable = movable
        self.region = region
        self.decl_line = decl_line  # index of the line with the keyword
        self.dest = None

    def __repr__(self):
        return f"<{self.kind} {self.names} {self.start + 1}-{self.end} {self.region}>"


ATTR_RE = re.compile(r"@\w+(\([^()]*(\([^()]*\)[^()]*)*\))?\s*")


def parse_decl(code):
    """(keyword, modifiers, rest) of a declaration's first line, code-masked."""
    s = code.strip()
    while True:
        m = ATTR_RE.match(s)
        if not m:
            break
        s = s[m.end():]
    mods = []
    while True:
        m = re.match(r"(private\(set\)|fileprivate\(set\)|internal\(set\)|[A-Za-z]+)\s*", s)
        if not m:
            return None, mods, s
        word = m.group(1)
        if word in DECL_KEYWORDS and not (word == "class" and re.match(r"class\s+(func|var|let|static)\b", s)):
            if word == "class" and re.match(r"class\s+(func|var|let)\b", s):
                pass
            return word, mods, s[m.end():]
        if word in MODIFIERS:
            mods.append(word)
            s = s[m.end():]
            continue
        return None, mods, s


def decl_names(keyword, rest):
    if keyword in ("init", "deinit", "subscript"):
        return [keyword]
    m = re.match(r"`?([A-Za-z_]\w*)`?", rest)
    if keyword in ("var", "let") and rest.startswith("("):
        return re.findall(r"[A-Za-z_]\w*", rest.split(")")[0])
    return [m.group(1)] if m else []


def is_computed(masked_text):
    """A var whose first `{` at its own depth comes before any `=` and whose
    body is not a didSet/willSet observer."""
    depth = 0
    for k, ch in enumerate(masked_text):
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif depth == 0 and ch == "=" and masked_text[k - 1:k + 1] not in ("->",) \
                and masked_text[k + 1:k + 2] != "=" and masked_text[k - 1] not in "!<>=":
            return False
        elif depth == 0 and ch == "{":
            body = masked_text[k + 1:].lstrip()
            return not re.match(r"(didSet|willSet)\b", body)
    return False


def segment(lines, masked, depths, lo, hi, base_depth, indent, region_names):
    """Split lines[lo:hi] (all at bracket depth base_depth) into items.
    Returns (items, regions) where regions is [(name, line)]."""
    items = []
    pending = None  # first line of leading comments/attributes/blank lines
    region = None
    i = lo
    seen = {}

    def starts_chunk(k):
        if depths[k] != base_depth:
            return False
        if not lines[k].strip():
            return False
        if re.match(r"\s*#(if|else|elseif|endif)\b", lines[k]):
            return True
        lead = len(lines[k]) - len(lines[k].lstrip(" "))
        return lead == indent

    while i < hi:
        line = lines[i]
        code = masked[i]
        if not line.strip():
            if pending is None:
                pending = i
            i += 1
            continue
        if depths[i] != base_depth or not starts_chunk(i):
            raise SystemExit(f"{APP_STATE}:{i + 1}: can't tell where this declaration starts")
        stripped = line.strip()
        mark = re.match(r"// MARK: - (.+?)\s*$", stripped)
        if mark and len(line) - len(line.lstrip()) == indent:
            name = mark.group(1)
            seen[name] = seen.get(name, 0) + 1
            region = name if seen[name] == 1 else f"{name}@{seen[name]}"
            region_names.append((region, i))
            items.append(Item(pending if pending is not None else i, i + 1, "mark", [region], False, region, i))
            pending = None
            i += 1
            continue
        if not code.strip() or re.fullmatch(r"\s*(@\w+(\(.*\))?\s*)+", code):
            # comment or attribute line: belongs to what follows
            if pending is None:
                pending = i
            i += 1
            continue
        start = pending if pending is not None else i
        pending = None
        if re.match(r"\s*#if\b", line):
            # a conditional block moves or stays whole
            depth_if, j = 0, i
            while j < hi:
                if re.match(r"\s*#if\b", lines[j]) and depths[j] == base_depth:
                    depth_if += 1
                elif re.match(r"\s*#endif\b", lines[j]) and depths[j] == base_depth:
                    depth_if -= 1
                    if depth_if == 0:
                        break
                j += 1
            inner, _ = segment_block(lines, masked, depths, i + 1, j, base_depth, indent)
            movable = all(it.movable for it in inner if it.kind not in ("mark",))
            stays = all(not it.movable for it in inner if it.kind not in ("mark",))
            if not (movable or stays):
                raise SystemExit(f"{APP_STATE}:{i + 1}: #if block mixes stored properties and code")
            names = [n for it in inner for n in it.names]
            mods = [it for it in inner]
            item = Item(start, j + 1, "ifblock", names, movable, region, i)
            item.inner = inner
            items.append(item)
            i = j + 1
            continue
        # one declaration: runs to the next chunk start
        j = i + 1
        while j < hi and not (lines[j].strip() and starts_chunk(j)):
            j += 1
        # trailing blank lines belong to the next item
        end = j
        while end > i + 1 and not lines[end - 1].strip():
            end -= 1
        keyword, mods, rest = parse_decl(code)
        if keyword is None:
            raise SystemExit(f"{APP_STATE}:{i + 1}: not a declaration I know: {stripped[:60]}")
        names = decl_names(keyword, rest)
        text = "\n".join(masked[i:end])
        if keyword in ("init", "deinit"):
            movable = False
        elif keyword in ("var", "let") and "static" not in mods and "class" not in mods:
            movable = keyword == "var" and "lazy" not in mods and is_computed(text)
        else:
            movable = True
        item = Item(start, end, keyword, names, movable, region, i)
        item.mods = mods
        items.append(item)
        i = end
    if pending is not None:
        items.append(Item(pending, hi, "tail", [], False, region, pending))
    return items, region_names


def segment_block(lines, masked, depths, lo, hi, base_depth, indent):
    return segment(lines, masked, depths, lo, hi, base_depth, indent, [])


# ---------------------------------------------------------------- the file

class Source:
    def __init__(self, text):
        self.text = text
        self.lines = text.split("\n")
        self.masked = mask_code(text).split("\n")
        self.depths = line_depths(self.masked)
        self.class_start = next(k for k, l in enumerate(self.lines)
                                if re.match(r"final class AppState\b", l))
        # the class's closing brace: first line after the start back at depth 0
        k = self.class_start + 1
        while k + 1 < len(self.lines) and (self.depths[k + 1] != 0 or not self.lines[k].startswith("}")):
            k += 1
        self.class_end = k
        self.header_end = next(k for k, l in enumerate(self.lines) if l.startswith("import "))
        while self.lines[self.header_end].startswith("import ") or not self.lines[self.header_end].strip():
            self.header_end += 1
        self.imports = [l for l in self.lines[:self.header_end] if l.startswith("import ")]
        self.body, self.regions = segment(self.lines, self.masked, self.depths,
                                          self.class_start + 1, self.class_end, 1, 4, [])
        # the class's own attributes (`@MainActor`) start the class
        cs = self.class_start
        while cs > 0 and self.lines[cs - 1].startswith("@"):
            cs -= 1
        self.outer_before, _ = segment(self.lines, self.masked, self.depths,
                                       self.header_end, cs, 0, 0, [])
        self.outer_after, _ = segment(self.lines, self.masked, self.depths,
                                      self.class_end + 1, len(self.lines), 0, 0, [])
        self.class_attr_start = cs
        for it in self.outer_before + self.outer_after:
            if it.kind == "extension":
                close = it.end - 1
                while not self.lines[close].startswith("}"):
                    close -= 1
                it.inner, _ = segment(self.lines, self.masked, self.depths,
                                      it.decl_line + 1, close, 1, 4, [])


def steps_upto(n):
    """Step n alone (the steps before it already ran on main)."""
    if not 1 <= n <= len(STEPS):
        raise SystemExit(f"--step takes 1 to {len(STEPS)}")
    return [STEPS[n - 1]]


def assign(src, steps):
    """Set item.dest for everything that moves. Returns {file: [items]}."""
    region_items = OrderedDict()
    for it in src.body:
        region_items.setdefault(it.region, []).append(it)
    outer = {}
    for it in src.outer_before + src.outer_after:
        for n in it.names:
            outer.setdefault(n, it)
    known = set(region_items)
    moves = OrderedDict()
    for step in steps:
        for fname, parts in step.items():
            for part in parts:
                if part.startswith("file:"):
                    name = part[5:]
                    if name not in outer:
                        raise SystemExit(f"no type or extension {name!r} around the class")
                    it = outer[name]
                    it.dest = fname
                    # its leading comment block moves with it (already in the item)
                    moves.setdefault(fname, []).append(it)
                    continue
                if part.startswith("outer:"):
                    region = part[6:]
                    found = [it for it in src.outer_before + src.outer_after
                             if it.region == region and it.kind != "mark"]
                    if not found:
                        raise SystemExit(f"no MARK {region!r} around the class")
                    for it in found:
                        it.dest = fname
                        moves.setdefault(fname, []).append(it)
                    continue
                # "Region|from name", "Region|until name" or "Region|from a until b":
                # the part of a long region from (or before) a declaration.
                part, _, cut = part.partition("|")
                if part not in known:
                    raise SystemExit(f"no region {part!r}; regions: {', '.join(known)}")
                items = region_items[part]
                if cut:
                    m = re.fullmatch(r"(?:from (\S+))?\s*(?:until (\S+))?", cut)
                    if not m or not (m.group(1) or m.group(2)):
                        raise SystemExit(f"can't cut {part!r} at {cut!r}")

                    def at(name):
                        found = [i for i, it in enumerate(items) if name in it.names]
                        if len(found) != 1:
                            raise SystemExit(f"can't cut {part!r} at {cut!r}")
                        return found[0]
                    lo = at(m.group(1)) if m.group(1) else 0
                    hi = at(m.group(2)) if m.group(2) else len(items)
                    if lo >= hi:
                        raise SystemExit(f"can't cut {part!r} at {cut!r}: nothing between")
                    items = items[lo:hi]
                for it in items:
                    if it.movable:
                        it.dest = fname
                        moves.setdefault(fname, []).append(it)
    return moves


# ---------------------------------------------------------------- access

IDENT = re.compile(r"[A-Za-z_]\w*")


def code_names(masked_lines):
    names = set()
    for l in masked_lines:
        names.update(IDENT.findall(l))
    return names


MUTATION = (r"(\s*(\?|!)?(\.\w+|\[[^\]\n]*\]))*\s*(=(?!=)|&?\+=|&?-=|&?\*=|/=|%=|\|=|&=|\^=|&?<<=|&?>>=|\?\?=)"
            r"|(\s*(\?|!)?(\.\w+|\[[^\]\n]*\]))*\.(append|remove\w*|insert|merge|formUnion|"
            r"formIntersection|subtract|sort|reverse|popLast|popFirst|update\w*|toggle|"
            r"swapAt|replaceSubrange|reserveCapacity|shuffle)\b")


# `mutating func` names the app declares (set by run): calling one through a
# `private(set)` property writes it, like `sessionCatalogLoadState.reset()`.
APP_MUTATING = set()


def mutating_names(repo):
    names = set()
    for p in sorted((repo / "Conduit").rglob("*.swift")) + sorted((repo / "Shared").rglob("*.swift")):
        names.update(re.findall(r"\bmutating\s+func\s+(\w+)", p.read_text(errors="replace")))
    return names


def writes(masked_lines, name):
    mutation = MUTATION
    if APP_MUTATING:
        mutation += r"|(\s*(\?|!)?(\.\w+|\[[^\]\n]*\]))*\.(" + "|".join(sorted(APP_MUTATING)) + r")\b(?!\s*:)"
    pat = re.compile(r"(?<![\w.])(self\??\.)?" + re.escape(name) + r"\b(?=" + mutation + r")"
                     r"|&(self\??\.)?" + re.escape(name) + r"\b")
    return pat.search("\n".join(masked_lines)) is not None


def widen(line, which):
    """Drop `private ` (which='private') or `private(set) ` from a decl line."""
    if which in ("private(set)", "fileprivate(set)"):
        return re.sub(r"\b" + re.escape(which) + r"\s+", "", line, count=1)
    if which == "fileprivate":
        return re.sub(r"\bfileprivate\s+(?!\(set\))", "", line, count=1)
    return re.sub(r"(?<![\w(])private\s+(?!\(set\))", "", line, count=1)


def decl_lines_of(it):
    if getattr(it, "inner", None):
        out = []
        for sub in it.inner:
            out.extend(decl_lines_of(sub))
        return out
    if it.kind in ("mark", "tail"):
        return []
    return [it]


def references(masked_lines, name):
    """Whether code uses `name` as itself, not as another value's member or
    an argument label."""
    n = re.escape(name)
    pat = re.compile(r"(?<![\w.])\$?" + n + r"\b(?!:)"
                     r"|(?:\bself\??|\bSelf|\bAppState|\\)\." + n + r"\b")
    return pat.search("\n".join(masked_lines)) is not None


def in_app_state(src, it):
    """Code that can see AppState's private members when in the same file:
    the class body and `extension AppState` blocks."""
    return it in src.body or it.kind == "extension"


def plan_access(src, file_items):
    """file_items: {file: [items]} with AppState.swift's own (staying) items
    included. Returns ({line index: new line}, [(decl, which, file)])."""
    every, scoped = {}, {}
    for f, items in file_items.items():
        every[f] = [l for it in items for l in src.masked[it.start:it.end]]
        scoped[f] = [l for it in items if in_app_state(src, it)
                     for l in src.masked[it.start:it.end]]
    changes = {}
    widened = []
    for f, items in file_items.items():
        for it in items:
            member = it in src.body or it.kind == "extension"
            for d in decl_lines_of(it):
                line = src.lines[d.decl_line]
                mods = getattr(d, "mods", None)
                if mods is None:
                    _, mods, _ = parse_decl(src.masked[d.decl_line])
                hidden = [m for m in ("private", "fileprivate") if m in mods]
                setter = [m for m in ("private(set)", "fileprivate(set)") if m in mods]
                if not hidden and not setter:
                    continue
                for other in file_items:
                    if other == f:
                        continue
                    # fileprivate reaches the whole file, top-level code too
                    file_wide = any(m.startswith("fileprivate") for m in mods)
                    text = (scoped if member and not file_wide else every)[other]
                    used = [n for n in d.names if references(text, n)]
                    if not used:
                        continue
                    if hidden:
                        line = widen(line, hidden[0])
                        widened.append((d, hidden[0], other))
                        break
                    if any(writes(text, n) for n in used):
                        line = widen(line, setter[0])
                        widened.append((d, setter[0], other))
                        break
                if line != src.lines[d.decl_line]:
                    changes[d.decl_line] = line
    # An internal declaration can't show a private type in its signature, or
    # use a private name in a default argument: widen those names too.
    hidden_decls = {}
    for items in file_items.values():
        for it in items:
            for d in decl_lines_of(it):
                mods = getattr(d, "mods", None)
                if mods is None:
                    _, mods, _ = parse_decl(src.masked[d.decl_line])
                hidden = [m for m in ("private", "fileprivate") if m in mods]
                if hidden and d.decl_line not in changes:
                    for n in d.names:
                        hidden_decls.setdefault(n, []).append((d, hidden[0]))
    queue = [d for d, which, _ in widened if which in ("private", "fileprivate")]
    while queue:
        d = queue.pop()
        for n in set(IDENT.findall(signature(src, d))) - set(d.names):
            for e, which in hidden_decls.pop(n, []):
                if e.decl_line in changes:
                    continue
                changes[e.decl_line] = widen(src.lines[e.decl_line], which)
                widened.append((e, which, f"the signature of {d.names[0]}"))
                queue.append(e)
    return changes, widened


def signature(src, d):
    """A declaration's text up to its body or initial value: what an internal
    declaration shows of the types and names it uses."""
    text = "\n".join(src.masked[d.decl_line:d.end])
    if d.kind in ("enum", "struct", "class", "actor", "typealias"):
        return text  # a type shows its members' types too
    depth = 0
    for k, ch in enumerate(text):
        if ch in "([<" and not (ch == "<" and text[k - 1:k] == " "):
            depth += 1
        elif ch in ")]>" and not (ch == ">" and text[k - 1:k] in ("-", " ")):
            depth -= 1
        elif depth <= 0 and ch == "{":
            return text[:k]
        elif depth <= 0 and ch == "=" and d.kind in ("var", "let") and text[k + 1:k + 2] != "=":
            return text[:k]
    return text


# ---------------------------------------------------------------- writing

def area_title(fname):
    return fname.removeprefix("AppState+").removesuffix(".swift")


def render_new_file(src, fname, items, changes, header_note):
    in_class = [it for it in items if it in src.body]
    outer = [it for it in items if it not in src.body]
    out = ["//", f"//  {fname}", "//  Conduit", "//"]
    if not header_note:
        header_note = default_note(src, items)
    for l in header_note:
        out.append(f"//  {l}" if l else "//")
    if header_note:
        out.append("//")
    out.append("")
    out.extend(src.imports)
    out.append("")

    def text(it):
        ls = [changes.get(k, src.lines[k]) for k in range(it.start, it.end)]
        while ls and not ls[0].strip():
            ls.pop(0)
        return ls

    last_region = None
    for it in outer:
        if it.kind == "extension" and it.region and it.region != last_region:
            out.append(f"// MARK: - {it.region}")
            out.append("")
            last_region = it.region
        out.extend(text(it))
        out.append("")
    if in_class:
        out.append("extension AppState {")
        last_region = None
        first = True
        for it in in_class:
            if it.region != last_region:
                if not first:
                    out.append("")
                out.append(f"    // MARK: - {MARK_TITLES.get(fname, it.region.split('@')[0])}")
                out.append("")
                last_region = it.region
            elif not first:
                out.append("")
            out.extend(text(it))
            first = False
        out.append("}")
        out.append("")
    return "\n".join(out)


def with_imports(text, imports):
    """`text` with any of AppState.swift's imports it lacks, after its own:
    code appended to an existing file needs what it used where it was."""
    lines = text.split("\n")
    have = {l.strip() for l in lines if l.startswith("import ")}
    missing = [i for i in imports if i.strip() not in have]
    if not missing:
        return text
    at = max((k for k, l in enumerate(lines) if l.startswith("import ")), default=None)
    if at is None:
        at = next(k for k, l in enumerate(lines) if l.strip() and not l.startswith("//")) - 1
        missing = missing + [""]
    return "\n".join(lines[:at + 1] + missing + lines[at + 1:])


def render_app_state(src, moved, changes):
    keep = []
    skip = set()
    for it in moved:
        skip.update(range(it.start, it.end))
    # a region left with nothing but its MARK loses the MARK too
    region_left = {}
    for it in src.body:
        if it.kind != "mark" and it.start not in skip:
            region_left[it.region] = True
    # a MARK left over stored properties names the files its code went to
    region_dests = OrderedDict()
    for it in moved:
        if it in src.body and it.dest:
            region_dests.setdefault(it.region, OrderedDict())[it.dest] = True
    changes = dict(changes)
    for it in src.body:
        if it.kind == "mark" and not region_left.get(it.region):
            skip.update(range(it.start, it.end))
        elif it.kind == "mark" and it.region in region_dests:
            for k in range(it.start, it.end):
                line = changes.get(k, src.lines[k])
                if "// MARK:" in line:
                    # a MARK cut before keeps the files it named
                    m = re.search(r" \(((?:AppState\+\w+\.swift(?:, )?)+)\)$", line.rstrip())
                    files = m.group(1).split(", ") if m else []
                    head = line.rstrip()[:m.start()] if m else line.rstrip()
                    files += [f for f in region_dests[it.region] if f not in files]
                    changes[k] = head + f" ({', '.join(files)})"
                    break
    outer = src.outer_before + src.outer_after
    outer_left = {it.region for it in outer if it.kind != "mark" and it.start not in skip}
    for it in outer:
        if it.kind == "mark" and it.region not in outer_left:
            skip.update(range(it.start, it.end))
    k = 0
    n = len(src.lines)
    while k < n:
        if k not in skip:
            keep.append(changes.get(k, src.lines[k]))
            k += 1
            continue
        while k < n and k in skip:
            k += 1
        # at the edge of a removed run: one blank line at most between what
        # stays, none after an opening brace or before a closing one
        while k < n and k not in skip and not src.lines[k].strip() and \
                (not keep or not keep[-1].strip() or keep[-1].rstrip().endswith("{")):
            k += 1
        if k < n and src.lines[k].strip().startswith("}"):
            while keep and not keep[-1].strip():
                keep.pop()
        if keep and keep[-1].rstrip().endswith("{"):
            while k < n and k not in skip and not src.lines[k].strip():
                k += 1
        # a MARK whose code moved keeps its blank line before what stays
        if keep and keep[-1].strip().startswith("// MARK:") and k < n and src.lines[k].strip():
            keep.append("")
    while keep and not keep[-1].strip():
        keep.pop()
    return "\n".join(keep) + "\n"


# A file made from the cut-off end of a region gets a MARK of its own.
MARK_TITLES = {"AppState+OpenChat.swift": "Opening chats",
               "AppState+ProfileSettings.swift": "Profile and connection settings",
               "AppState+AppLinks.swift": "Opening app links",
               "AppState+PinSync.swift": "Pins kept on the phone and on the host, and pinned replies",
               "AppState+Notices.swift": "Notices over the app",
               "AppState+Voice.swift": "Voice background jobs",
               "AppState+Reconciliation.swift": "Keeping row ids and local notes across a reconcile",
               "AppState+ChatResume.swift": "Resuming a chat: return surface, viewport and transport",
               "AppState+PinnedChatOrder.swift": "Pinning chats, and the saved order of chats, bots and rooms"}

HEADER_NOTES = {
    "AppState+PinSync.swift": [
        "Pinned chats kept on the phone and on the host (SessionPinSync), and",
        "the replies pinned in a chat. Moved out of AppState.swift (issue 828).",
    ],
    "AppState+Notices.swift": [
        "The notices shown over the app: a refused call, CarPlay failing, and",
        "the general notice. Moved out of AppState.swift (issue 828).",
    ],
    "AppState+ChatResume.swift": [
        "Resuming a chat: the surface it returns to, the viewport it restores,",
        "and the transport continuation after a reconnect. Moved out of",
        "AppState.swift (issue 828).",
    ],
    "AppState+AppLinks.swift": [
        "Opening a conduit:// link: a chat, a bot's Bot Chat or a call's",
        "transcript, on whichever profile it belongs to. Moved out of",
        "AppState.swift (issue 828).",
    ],
    "AppState+ProfileSettings.swift": [
        "A dashboard's settings and its profiles' names, pictures, colors and",
        "order, with the server identity a chat resume keys on. Moved out of",
        "AppState.swift (issue 828).",
    ],
    "AppState+OpenChat.swift": [
        "Opening a chat: a widget's or a bot's Bot Chat, a room's chat, a saved",
        "session, a notification's target, and the profile a conversation",
        "belongs to. Moved out of AppState.swift (issue 828).",
    ],
    "ChatResumeRecovery.swift": [
        "The seams and steps of resuming a chat: the lifecycle operations",
        "tests replace, reconnect scheduling, and the recovery sequence that",
        "replays a resume's transport and conversation steps in order.",
        "Moved out of AppState.swift (issue 828).",
    ],
    "AppStateSupportTypes.swift": [
        "Small value types AppState's chats, rooms and profiles pass around:",
        "profile ownership, the group chat seams tests replace, a session's",
        "persisted transcript, the composer's submission context and the",
        "conversation's agent identity. Moved out of AppState.swift (issue 828).",
    ],
    "SessionCatalogCache.swift": [
        "The profile-scoped session catalog cache. Moved out of AppState.swift",
        "(issue 828).",
    ],
    "KeychainHelper.swift": [
        "Keychain reads and writes for saved credentials, behind the storage",
        "seam tests replace. Moved out of AppState.swift (issue 828).",
    ],
    "AttachmentHelper.swift": [
        "Reads a picked or shared file into an attachment. Moved out of",
        "AppState.swift (issue 828).",
    ],
    "CapabilityLoadPolicy.swift": [
        "Who a capability read belongs to, and the rules that drop a read a",
        "profile switch overtook. Moved out of AppState.swift (issue 828).",
    ],
}


def default_note(src, items):
    regions = []
    for it in items:
        r = it.region.split("@")[0] if it.region else None
        if r and r not in regions:
            regions.append(r)
    if not regions:
        types = [n for it in items for n in it.names[:1]]
        what = ", ".join(types)
    else:
        what = "; ".join(regions)
    words = f"Moved out of AppState.swift (issue 828): {what}.".split()
    lines, cur = [], ""
    for w in words:
        if len(cur) + len(w) + 1 > 72:
            lines.append(cur)
            cur = w
        else:
            cur = f"{cur} {w}".strip()
    lines.append(cur)
    return lines


def collisions(repo, src, widened, written):
    """A widened name another file already declares privately (or, for a
    file-level name, at all) would clash once it's internal."""
    found = []
    others = [p for p in sorted((repo / "Conduit").rglob("*.swift")) + sorted((repo / "Shared").rglob("*.swift"))
              if p.relative_to(repo).as_posix() != APP_STATE and p.name not in written]
    texts = {p: p.read_text(errors="replace") for p in others}
    for d, which, _ in widened:
        if which not in ("private", "fileprivate"):
            continue
        member = any(d is x or d in getattr(x, "inner", []) for x in src.body)
        for n in d.names:
            if member:
                pat = re.compile(r"^\s*(@\w+\s+)*(private|fileprivate)\s+(static\s+|nonisolated\s+)*"
                                 r"(func|var|let|enum|struct|class|typealias)\s+" + re.escape(n) + r"\b", re.M)
                pool = {p: t for p, t in texts.items() if "extension AppState" in t}
            else:
                pat = re.compile(r"^(@\w+\s+)*((private|fileprivate|internal)\s+)?(final\s+)?"
                                 r"(func|var|let|enum|struct|class|typealias|actor)\s+" + re.escape(n) + r"\b", re.M)
                pool = texts
            for p, t in pool.items():
                if pat.search(t):
                    found.append(f"{n}: {p.relative_to(repo)} declares it too")
    return found


def run(repo, step, write, pr=None, today=None):
    path = repo / APP_STATE
    src = Source(path.read_text())
    steps = steps_upto(step)
    moves = assign(src, steps)
    moved = [it for items in moves.values() for it in items]
    staying = [it for it in src.outer_before + src.body + src.outer_after if it.dest is None]
    file_items = OrderedDict([(APP_STATE, staying)])
    for f, items in moves.items():
        file_items[f] = items
    # files that already exist and aren't written by this run can't see
    # AppState.swift's private names, so they need nothing.
    APP_MUTATING.clear()
    APP_MUTATING.update(mutating_names(repo))
    changes, widened = plan_access(src, file_items)
    report = []
    for f, items in moves.items():
        n = sum(it.end - it.start for it in items)
        report.append(f"{f}: {len(items)} declarations, {n} lines")
    for d, which, other in widened:
        report.append(f"  widen {which} {'/'.join(d.names)} ({APP_STATE}:{d.decl_line + 1}) used in {other}")
    clash = collisions(repo, src, widened, set(moves))
    report.extend(f"  CLASH {c}" for c in clash)
    if not write:
        print("\n".join(report))
        return
    if clash:
        raise SystemExit("\n".join(report))
    for f, items in moves.items():
        target = repo / SERVICES / f
        if target.exists() and (not f.startswith("AppState+") or any(it not in src.body for it in items)
                                or "extension AppState" not in target.read_text()):
            raise SystemExit(f"{target} already exists; nothing written")
        if target.exists() and any(f"// MARK: - {it.region.split('@')[0]}\n" in target.read_text()
                                   for it in items):
            raise SystemExit(f"{target} already has this step's moves; nothing written")
    where = {}
    for it in src.outer_before + src.body + src.outer_after:
        if it.kind in ("mark", "tail"):
            continue
        dest = f"{SERVICES}/{it.dest}" if it.dest else APP_STATE
        named = decl_lines_of(it) if it.kind == "extension" else [it]
        for d in named:
            for n in d.names:
                if where.get(n, dest) != dest:
                    where[n] = None  # overloads in two files: left to a person
                else:
                    where[n] = dest
    import datetime
    map_text, manual = update_map(repo, {n: d for n, d in where.items() if d},
                                  pr, today or datetime.date.today().isoformat())
    for m in manual:
        report.append(f"  MAP rewrite by hand: {m[:160]}")
    app_text = render_app_state(src, moved, changes)
    for f, items in moves.items():
        target = repo / SERVICES / f
        if target.exists():
            body = render_new_file(src, f, items, changes, ["-"])
            block = body[body.index("extension AppState {"):]
            target.write_text(with_imports(target.read_text(), src.imports).rstrip("\n")
                              + "\n\n" + block)
        else:
            target.write_text(render_new_file(src, f, items, changes, HEADER_NOTES.get(f, [])))
    # AppState.swift last: until it's written, its regions are all still there
    (repo / MAP).write_text(map_text)
    path.write_text(app_text)
    print("\n".join(report))


# ---------------------------------------------------------------- the map

MAP = "docs/FEATURE_MAP.md"
MENTION = "`" + APP_STATE + "`"


def declared(text, name):
    return re.search(r"\b(func|var|let|enum|struct|class|actor|typealias|protocol)\s+`?"
                     + re.escape(name) + r"\b", text) is not None


def paren_span(text, k):
    """Index after the parenthetical that opens at text[k] == '('."""
    depth = 0
    for j in range(k, len(text)):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
    return None


def update_map(repo, where, pr, today):
    """Point the map's AppState.swift mentions at the files their names moved
    to. Returns the mentions it couldn't rewrite on its own."""
    path = repo / MAP
    text = path.read_text()
    manual = []
    out, pos = [], 0
    while True:
        k = text.find(MENTION, pos)
        if k < 0:
            out.append(text[pos:])
            break
        out.append(text[pos:k])
        after = k + len(MENTION)
        if not text.startswith(" (", after):
            out.append(MENTION)
            pos = after
            continue
        end = paren_span(text, after + 1)
        inner = text[after + 2:end - 1]
        names = []
        for m in re.finditer(r"`?([A-Za-z_]\w*)(\.\w+)?(\([^()]*\))?`?", inner):
            names.append((m.group(1), m))
        dests = {}
        for n, _ in names:
            if n in where:
                dests[n] = where[n]
        targets = set(dests.values())
        if not targets or targets == {APP_STATE}:
            out.append(text[k:end])
        elif len(targets) == 1:
            out.append(f"`{targets.pop()}` ({inner})")
        else:
            parts = [x.strip() for x in inner.split(",")]
            simple = all(re.fullmatch(r"`?[A-Za-z_]\w*(\.\w+)?(\([^()]*\))?`?", x) for x in parts)
            if not simple:
                manual.append(text[k:end])
                out.append(text[k:end])
            else:
                groups = OrderedDict()
                for x in parts:
                    n = re.match(r"`?([A-Za-z_]\w*)", x).group(1)
                    groups.setdefault(dests.get(n, APP_STATE), []).append(x)
                out.append(", ".join(f"`{f}` ({', '.join(xs)})" for f, xs in groups.items()))
        pos = end
    result = "".join(out)
    if result != text and pr:
        result = stamp_checked(text, result, pr, today)
    return result, manual


def stamp_checked(before, after, pr, today):
    """Name the PR on the Checked line of each entry whose text changed."""
    def entries(t):
        parts = re.split(r"(?m)^(?=## )", t)
        return parts
    old = entries(before)
    new = entries(after)
    if len(old) != len(new):
        raise SystemExit("the map's entries changed shape")
    note = f"{today}, #{pr} (the code it lists moved out of AppState.swift, issue 828); "
    out = []
    for o, n in zip(old, new):
        if o != n:
            n = re.sub(r"(?m)^\*\*Checked:\*\* ", lambda m: m.group(0) + note, n, count=1)
        out.append(n)
    return "".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["plan", "write", "regions"])
    ap.add_argument("--pr", type=int, help="write: the PR to name on the Checked line of each "
                    "feature map entry whose paths change")
    ap.add_argument("--today", default=None, help="write: the Checked line's date (default today)")
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--step", type=int, default=0, help="plan and write: the step to make")
    args = ap.parse_args(argv)
    repo = Path(args.repo_root)
    if args.command == "regions":
        src = Source((repo / APP_STATE).read_text())
        by = OrderedDict()
        for it in src.body:
            r = by.setdefault(it.region, [0, 0, 0])
            n = it.end - it.start
            if it.kind == "mark":
                continue
            r[0 if it.movable else 1] += n
        for name, (mv, st, _) in by.items():
            print(f"{mv:6d} movable {st:6d} stays  {name}")
        print("outside the class:")
        for it in src.outer_before + src.outer_after:
            print(f"  {it.start + 1}-{it.end} {it.kind} {it.names}")
        return
    run(repo, args.step, args.command == "write", args.pr, args.today)


if __name__ == "__main__":
    main()
