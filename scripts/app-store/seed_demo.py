#!/usr/bin/env python3
"""Seed the demo dashboard's chats through the same gateway RPC the app uses.

Each chat in demo-script.json becomes a session created with session.create
(source "desktop", like Conduit) and its turns are sent with prompt.submit,
waiting for message.complete before the next one. The scripted model answers.
A bot's picture, avatars/<its "avatar", else its name>.png when there is one, is uploaded the way the
app uploads one (profiles.set_asset). Bots with "later": true are left for
demo_director.py, which adds them while a demo video records.
Run with the Hermes venv's Python (needs httpx and websockets).

Usage: seed_demo.py SCRIPT.json BASE_URL USER PASSWORD
"""

import asyncio
import base64
import json
import os
import sys
from pathlib import Path

import httpx
import websockets

DEBUG = bool(os.environ.get('SEED_DEBUG'))
AVATARS = Path(__file__).resolve().parent / "avatars"
sys.path.insert(0, str(AVATARS.parent))
from demo_script import load as load_script  # noqa: E402


class Gateway:
    """One signed-in gateway socket: rpc() calls, events() the rest."""

    def __init__(self, base, user, password):
        self.base, self.user, self.password = base, user, password
        self.events = asyncio.Queue()
        self.pending = {}
        self.next_id = 0
        self.ws = None
        self.reader = None

    async def __aenter__(self):
        async with httpx.AsyncClient(base_url=self.base, timeout=30, trust_env=False) as http:
            r = await http.post("/auth/password-login",
                                json={"provider": "basic", "username": self.user, "password": self.password})
            r.raise_for_status()
            ticket = (await http.post("/api/auth/ws-ticket")).json()["ticket"]
        ws_url = self.base.replace("http", "ws", 1) + "/api/ws?ticket=" + ticket
        self.ws = await websockets.connect(ws_url, max_size=None, proxy=None, origin=self.base)
        self.reader = asyncio.create_task(self._read())
        await self.rpc("client.capabilities", {"server_requests": True})
        return self

    async def __aexit__(self, *exc):
        self.reader.cancel()
        await self.ws.close()

    async def _read(self):
        async for raw in self.ws:
            frame = json.loads(raw)
            if "method" not in frame and frame.get("id") in self.pending:
                fut = self.pending.pop(frame["id"])
                if not fut.done():  # a reply after its timeout
                    fut.set_result(frame)
            elif "method" in frame:
                if "id" in frame:
                    # Nothing here answers the gateway's own requests.
                    print(f"  unanswered server request: {json.dumps(frame)[:200]}")
                if DEBUG:
                    print("event", json.dumps(frame)[:200])
                await self.events.put(frame)

    async def rpc(self, method, params=None, timeout=60):
        self.next_id += 1
        fut = asyncio.get_running_loop().create_future()
        self.pending[self.next_id] = fut
        await self.ws.send(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method,
                                       "params": params or {}}))
        frame = await asyncio.wait_for(fut, timeout)
        if "error" in frame:
            raise RuntimeError(f"{method}: {frame['error']}")
        return frame.get("result") or {}

    async def run_turns(self, sid, turns, wait=True):
        for turn in turns:
            while not self.events.empty():
                self.events.get_nowait()
            await self.rpc("prompt.submit", {"session_id": sid, "text": turn.get("prompt", turn["match"])},
                           timeout=120)
            if not wait:
                continue
            while True:
                event = await asyncio.wait_for(self.events.get(), 300)
                name = event.get("method")
                params = event.get("params") or {}
                kind = params.get("type") if name == "event" else name
                if kind in ("message.complete", "turn.failed", "message.interrupted"):
                    if kind != "message.complete":
                        print(f"  {kind}: {json.dumps(params)[:300]}")
                    break
            # Let the turn's bookkeeping (usage, title) land first.
            await asyncio.sleep(2)

    async def set_avatar(self, name, avatar=None):
        picture = AVATARS / f"{avatar or name}.png"
        if not picture.is_file():
            return
        data = "data:image/png;base64," + base64.b64encode(picture.read_bytes()).decode()
        await self.rpc("profiles.set_asset", {"name": name, "asset": "avatar", "data": data})

    async def bot_chat(self, name):
        """The bot's one chat, made the way Conduit makes it: its live id on
        this socket, and the stored id it keeps after."""
        created = await self.rpc("session.create", {"cols": 96, "source": "desktop", "profile": name,
                                                    "title": "Bot Chat", "hidden": True,
                                                    "follow_profile_config": True})
        return created["session_id"], created.get("stored_session_id") or created["session_id"]

    async def resume_bot_chat(self, name, stored_id):
        """A live id for a bot's chat made on another socket."""
        resumed = await self.rpc("session.resume", {"session_id": stored_id, "cols": 96, "source": "desktop",
                                                    "profile": name, "omit_messages": True})
        return resumed["session_id"]

    async def add_bot(self, bot):
        name = bot["name"]
        # Cloned from the main profile, as the app's New Bot does by default:
        # the scripted model, the approvals mode and the Conduit plugin.
        await self.rpc("profiles.create", {"name": name, "description": bot.get("description", ""),
                                           "soul": bot.get("soul", ""), "clone_from": "default"}, timeout=120)
        meta = {key: bot[key] for key in ("title", "color") if bot.get(key)}
        if meta:
            await self.rpc("profiles.configure", {"name": name, "ui_meta": {"hermes-bots": meta}})
        await self.set_avatar(name, bot.get("avatar"))
        live, stored = await self.bot_chat(name)
        await self.run_turns(live, bot.get("turns", []))
        return stored


def check_nothing_asks(script):
    """On an instance that asks before running things (DEMO_APPROVALS=manual),
    a seeded turn that calls a tool would leave an approval waiting before
    the video starts. Such turns belong in "replies", sent while it records."""
    if os.environ.get("DEMO_APPROVALS", "off") == "off":
        return
    seeded = [("default_bot", script.get("default_bot") or {})]
    seeded += [(b["name"], b) for b in script.get("bots", []) if not b.get("later")]
    seeded += [(c.get("title", "chat"), c) for c in script.get("chats", []) if c.get("seed") is not False]
    asking = [name for name, item in seeded
              if any(step.get("tool_calls") for turn in item.get("turns", []) for step in turn.get("steps", []))]
    if asking:
        sys.exit(f"Seeded turns call tools on an instance with approvals on: {', '.join(asking)}")


async def seed(script_path, base, user, password):
    script = load_script(script_path)
    check_nothing_asks(script)
    bot_chats = {}
    async with Gateway(base, user, password) as gw:
        if script.get("default_bot"):
            meta = {key: value for key, value in script["default_bot"].items() if key in ("title", "color")}
            await gw.rpc("profiles.configure", {"name": "default", "ui_meta": {"hermes-bots": meta}})
            await gw.set_avatar("default", script["default_bot"].get("avatar"))
            if script["default_bot"].get("turns"):
                live, bot_chats["default"] = await gw.bot_chat("default")
                await gw.run_turns(live, script["default_bot"]["turns"])
        # Bots first, so the chats seeded after them are the newest rows.
        for bot in script.get("bots", []):
            if bot.get("later"):
                continue  # added by demo_director.py while a video records
            bot_chats[bot["name"]] = await gw.add_bot(bot)
            print(f"seeded bot: {bot['name']}")
        for chat in script.get("chats", []):
            if chat.get("seed") is False:
                continue  # sent live by the preview recording instead
            created = await gw.rpc("session.create", {"cols": 96, "source": "desktop"})
            await gw.run_turns(created["session_id"], chat["turns"])
            print(f"seeded: {chat.get('title') or created['session_id']}")
    # Each bot's Bot Chat, for demo_director.py to send in while a video records.
    if os.environ.get("DEMO_BOT_CHATS"):
        Path(os.environ["DEMO_BOT_CHATS"]).write_text(json.dumps(bot_chats, indent=1))


if __name__ == "__main__":
    asyncio.run(seed(*sys.argv[1:5]))
