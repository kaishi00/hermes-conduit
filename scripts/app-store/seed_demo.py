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
                if "id" in frame and frame["id"] in pending:
                    pending.pop(frame["id"]).set_result(frame)
                elif "method" in frame:
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

        await rpc("client.capabilities", {"server_requests": True})
        for chat in script["chats"]:
            created = await rpc("session.create", {"cols": 96, "source": "desktop"})
            sid = created["session_id"]
            for turn in chat["turns"]:
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
            print(f"seeded: {chat.get('title') or sid}")
        task.cancel()


if __name__ == "__main__":
    asyncio.run(seed(*sys.argv[1:5]))
