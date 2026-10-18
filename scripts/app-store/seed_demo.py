#!/usr/bin/env python3
"""Seed the demo dashboard's chats through the same gateway RPC the app uses.

Each chat in demo-script.json becomes a session created with session.create
(source "desktop", like Conduit) and its turns are sent with prompt.submit,
waiting for message.complete before the next one. The scripted model answers.
Run with the Hermes venv's Python (needs httpx and websockets).

Usage: seed_demo.py SCRIPT.json BASE_URL USER PASSWORD
"""

import asyncio
import json
import sys

import httpx
import websockets

DEBUG = bool(__import__('os').environ.get('SEED_DEBUG'))


async def seed(script_path, base, user, password):
    script = json.load(open(script_path, encoding="utf-8"))
    async with httpx.AsyncClient(base_url=base, timeout=30, trust_env=False) as http:
        r = await http.post("/auth/password-login", json={"provider": "basic", "username": user, "password": password})
        r.raise_for_status()
        ticket = (await http.post("/api/auth/ws-ticket")).json()["ticket"]
    ws_url = base.replace("http", "ws", 1) + "/api/ws?ticket=" + ticket
    async with websockets.connect(ws_url, max_size=None, proxy=None, origin=base) as ws:
        next_id = 0
        events = asyncio.Queue()
        pending = {}

        async def reader():
            async for raw in ws:
                frame = json.loads(raw)
                if "method" not in frame and frame.get("id") in pending:
                    fut = pending.pop(frame["id"])
                    if not fut.done():  # a reply after its timeout
                        fut.set_result(frame)
                elif "method" in frame:
                    if "id" in frame:
                        # Nothing here answers the gateway's own requests.
                        print(f"  unanswered server request: {json.dumps(frame)[:200]}")
                    if DEBUG:
                        print("event", json.dumps(frame)[:200])
                    await events.put(frame)

        task = asyncio.create_task(reader())

        async def rpc(method, params=None, timeout=60):
            nonlocal next_id
            next_id += 1
            fut = asyncio.get_running_loop().create_future()
            pending[next_id] = fut
            await ws.send(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params or {}}))
            frame = await asyncio.wait_for(fut, timeout)
            if "error" in frame:
                raise RuntimeError(f"{method}: {frame['error']}")
            return frame.get("result") or {}

        async def run_turns(sid, turns):
            for turn in turns:
                while not events.empty():
                    events.get_nowait()
                await rpc("prompt.submit", {"session_id": sid, "text": turn.get("prompt", turn["match"])}, timeout=120)
                while True:
                    event = await asyncio.wait_for(events.get(), 300)
                    name = event.get("method")
                    params = event.get("params") or {}
                    kind = params.get("type") if name == "event" else name
                    if kind in ("message.complete", "turn.failed", "message.interrupted"):
                        if kind != "message.complete":
                            print(f"  {kind}: {json.dumps(params)[:300]}")
                        break
                # Let the turn's bookkeeping (usage, title) land first.
                await asyncio.sleep(2)

        await rpc("client.capabilities", {"server_requests": True})
        if script.get("default_bot"):
            await rpc("profiles.configure", {"name": "default", "ui_meta": {"hermes-bots": script["default_bot"]}})
        # Bots first, so the chats seeded after them are the newest rows.
        for bot in script.get("bots", []):
            name = bot["name"]
            await rpc("profiles.create", {"name": name, "description": bot.get("description", ""),
                                          "soul": bot.get("soul", "")}, timeout=120)
            meta = {key: bot[key] for key in ("title", "color") if bot.get(key)}
            if meta:
                await rpc("profiles.configure", {"name": name, "ui_meta": {"hermes-bots": meta}})
            # The bot's one chat, made the way Conduit makes it.
            created = await rpc("session.create", {"cols": 96, "source": "desktop", "profile": name,
                                                   "title": "Bot Chat", "hidden": True,
                                                   "follow_profile_config": True})
            await run_turns(created["session_id"], bot.get("turns", []))
            print(f"seeded bot: {name}")
        for chat in script["chats"]:
            if chat.get("seed") is False:
                continue  # sent live by the preview recording instead
            created = await rpc("session.create", {"cols": 96, "source": "desktop"})
            await run_turns(created["session_id"], chat["turns"])
            print(f"seeded: {chat.get('title') or created['session_id']}")
        task.cancel()


if __name__ == "__main__":
    asyncio.run(seed(*sys.argv[1:5]))
