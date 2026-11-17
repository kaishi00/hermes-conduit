"""Loads a demo script (demo-script.json or videos/*.json).

A script may borrow chats from another one instead of copying them:
"include_chats": {"from": "../demo-script.json", "titles": [...]} adds those
chats, by title, after its own. Standard library only, since llm_stub.py
imports it too.
"""

import json
from pathlib import Path


def load(path):
    path = Path(path)
    script = json.loads(path.read_text(encoding="utf-8"))
    include = script.pop("include_chats", None)
    if include:
        other = load(path.parent / include["from"])
        by_title = {chat.get("title"): chat for chat in other.get("chats", [])}
        missing = [title for title in include["titles"] if title not in by_title]
        if missing:
            raise ValueError(f"{path.name} includes chats {include['from']} doesn't have: {missing}")
        script["chats"] = script.get("chats", []) + [by_title[title] for title in include["titles"]]
    return script
