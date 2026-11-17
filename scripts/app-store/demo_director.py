#!/usr/bin/env python3
"""Stage directions for the demo videos: a small HTTP server on the capture
Mac that the UI test calls between steps, so what changes on a dashboard
mid-video (a bot added, a bot that starts work on its own) comes from the
dashboard itself, the way it would for a real person.

The UI test runs on the simulator, which shares the Mac's network, and posts
JSON to http://127.0.0.1:$DIRECTOR_PORT/<action>:

- add-bot   {"dashboard", "bot"}: creates a bot the dashboard's script marks
  "later", with its picture and its first turns, through the gateway RPC the
  app uses (seed_demo.Gateway).
- prompt    {"dashboard", "profile", "text"}: sends text in that bot's Bot
  Chat and returns once the turn has started, so it runs on while the video
  goes on (a reply streaming, an approval or a question waiting).
- start-room {"dashboard", "guest", "room", "agents", "guest_agents"}: a room
  with people over a Link (rooms invite on the host, rooms join on the guest,
  by the CLI), returning once the guest's copy says it started. The guest's
  config entry names the person the host's Link calls them ("person").
- join-room {"dashboard", "room", "agents"}: that dashboard's person joins the
  room the app invited them to, found by name on their invites, and it
  returns once their copy says it started.
- room-say {"dashboard", "room", "text"}: posts text as that dashboard's
  person in a room someone else hosts, the way their Conduit does
  (POST /rooms/copies/messages).
- stop-recording {}: stops `simctl io recordVideo` (its pid is in the file
  DEMO_RECORDER_PID_FILE names) and returns once the video is written, so the
  video ends at the test's last mark and cut-scenes.sh can date it from there.

Answers 200 {"ok": true} once done, 500 with the error otherwise.

Config: a JSON file mapping each dashboard's name to {base, user, password,
script, bot_chats, hermes_home, person}; bot_chats is the file seed_demo.py
wrote (DEMO_BOT_CHATS), hermes_home its HERMES_HOME for the CLI.
Run with the Hermes venv's Python.

Usage: demo_director.py CONFIG.json [PORT]
"""

import asyncio
import json
import os
import re
import signal
import subprocess
import sys
import traceback
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from demo_script import load as load_script  # noqa: E402
from seed_demo import Gateway  # noqa: E402

import httpx  # noqa: E402  (the Hermes venv has it)


def dashboard(config, name):
    entry = config.get(name)
    if entry is None:
        raise LookupError(f"no dashboard named {name!r}")
    return entry


def bot_chats(entry):
    path = Path(entry["bot_chats"])
    return json.loads(path.read_text()) if path.is_file() else {}


async def add_bot(config, body):
    entry = dashboard(config, body["dashboard"])
    script = load_script(entry["script"])
    bot = next((b for b in script.get("bots", []) if b["name"] == body["bot"]), None)
    if bot is None:
        raise LookupError(f"{body['bot']!r} is not in {entry['script']}")
    async with Gateway(entry["base"], entry["user"], entry["password"]) as gw:
        sid = await gw.add_bot(bot)
    chats = bot_chats(entry)
    chats[bot["name"]] = sid
    Path(entry["bot_chats"]).write_text(json.dumps(chats, indent=1))


async def prompt(config, body):
    entry = dashboard(config, body["dashboard"])
    profile = body.get("profile") or "default"
    stored = bot_chats(entry).get(profile)
    if stored is None:
        raise LookupError(f"no Bot Chat seeded for {profile!r}")
    async with Gateway(entry["base"], entry["user"], entry["password"]) as gw:
        live = await gw.resume_bot_chat(profile, stored)
        await gw.run_turns(live, [{"match": body["text"]}], wait=False)
        # Hold the socket a moment so the turn is surely under way.
        await asyncio.sleep(1)


def conduit_push(entry, *args):
    """The plugin's CLI on that dashboard's Hermes (the venv's hermes)."""
    exe = Path(sys.executable).with_name("hermes")
    env = {**os.environ, "HERMES_HOME": entry["hermes_home"]}
    done = subprocess.run([str(exe), "conduit-push", *args], env=env, capture_output=True, text=True, timeout=120)
    if done.returncode:
        raise RuntimeError(f"conduit-push {' '.join(args)}: {done.stdout}{done.stderr}")
    return done.stdout


async def start_room(config, body):
    host = dashboard(config, body["dashboard"])
    guest = dashboard(config, body["guest"])
    person = guest["person"]
    found = re.search(rf"^{re.escape(person)}: linked.*\(Link ([A-Za-z0-9_-]+)\)",
                      conduit_push(host, "links", "list"), re.M)
    if found is None:
        raise LookupError(f"{body['dashboard']} has no Link with {person}")
    made = conduit_push(host, "rooms", "invite", "--name", body["room"], f"--link={found[1]}",
                        *[f"--agent={agent}" for agent in body.get("agents", ["default"])])
    started = re.search(r"\(room (conduit-[0-9a-f-]+)\)", made)
    if started is None:
        raise LookupError(f"rooms invite named no room: {made}")
    room = started[1]
    for _ in range(60):
        if room in conduit_push(guest, "rooms", "invites"):
            break
        await asyncio.sleep(2)
    else:
        raise TimeoutError(f"{body['guest']} never heard the invite to {room}")
    conduit_push(guest, "rooms", "join", "--room", room, "--yes",
                 *[f"--agent={agent}" for agent in body.get("guest_agents", ["default"])])
    for _ in range(60):
        if re.search(rf"^{room}: .*\bstarted\b", conduit_push(guest, "rooms", "copies"), re.M):
            return
        await asyncio.sleep(2)
    raise TimeoutError(f"{room} never started on {body['guest']}")


async def room_say(config, body):
    entry = dashboard(config, body["dashboard"])
    found = re.search(rf"^(conduit-[0-9a-f-]+): {re.escape(body['room'])},",
                      conduit_push(entry, "rooms", "copies"), re.M)
    if found is None:
        raise LookupError(f"{body['dashboard']} keeps no copy of {body['room']!r}")
    async with httpx.AsyncClient(base_url=entry["base"], timeout=60, trust_env=False) as http:
        r = await http.post("/auth/password-login",
                            json={"provider": "basic", "username": entry["user"], "password": entry["password"]})
        r.raise_for_status()
        r = await http.post("/api/plugins/conduit_push/rooms/copies/messages",
                            json={"room_id": found[1], "event_id": f"demo-{uuid.uuid4().hex[:12]}",
                                  "text": body["text"]})
        r.raise_for_status()
        answer = r.json()
        message = answer.get("message") or {}
        if answer.get("ok") is not True or message.get("status") not in ("sending", "posted"):
            raise RuntimeError(f"the post was refused: {message.get('error') or answer}")


async def join_room(config, body):
    """The guest joins the room the app invited them to, found by its name
    on their invites, with their bots, and returns once the copy started."""
    entry = dashboard(config, body["dashboard"])
    async with httpx.AsyncClient(base_url=entry["base"], timeout=60, trust_env=False) as http:
        r = await http.post("/auth/password-login",
                            json={"provider": "basic", "username": entry["user"], "password": entry["password"]})
        r.raise_for_status()
        invite = None
        for _ in range(60):
            r = await http.get("/api/plugins/conduit_push/rooms/invites")
            r.raise_for_status()
            invite = next((i for i in r.json().get("invites", [])
                           if i.get("name") == body["room"] and not i.get("joined")), None)
            if invite is not None:
                break
            await asyncio.sleep(2)
        else:
            raise TimeoutError(f"{body['dashboard']} was never invited to {body['room']!r}")
    room = invite["room_id"]
    conduit_push(entry, "rooms", "join", "--room", room, f"--link={invite['link']}", "--yes",
                 *[f"--agent={agent}" for agent in body.get("agents", ["default"])])
    for _ in range(60):
        if re.search(rf"^{room}: .*\bstarted\b", conduit_push(entry, "rooms", "copies"), re.M):
            return
        await asyncio.sleep(2)
    raise TimeoutError(f"{room} never started on {body['dashboard']}")


async def stop_recording(config, body):
    path = os.environ.get("DEMO_RECORDER_PID_FILE")
    if not path or not Path(path).is_file():
        raise LookupError("no recorder pid file (DEMO_RECORDER_PID_FILE)")
    pid = int(Path(path).read_text().strip())
    try:
        os.kill(pid, signal.SIGINT)
    except ProcessLookupError:
        return
    # Not our child, so polled rather than waited on: SIGINT makes simctl
    # finish the file and exit, which takes a while for a long one.
    for _ in range(600):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        await asyncio.sleep(0.1)
    raise TimeoutError(f"recorder {pid} still running 60 s after SIGINT")


ACTIONS = {"add-bot": add_bot, "prompt": prompt, "start-room": start_room, "join-room": join_room,
           "room-say": room_say,
           "stop-recording": stop_recording}


class Handler(BaseHTTPRequestHandler):
    config = {}

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        action = ACTIONS.get(self.path.strip("/"))
        if action is None:
            self.answer(404, {"error": f"no action {self.path}"})
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        print(f"{self.path} {json.dumps(body)}", flush=True)
        try:
            asyncio.run(action(self.config, body))
        except Exception as error:  # reported to the test, which fails the step
            traceback.print_exc()
            self.answer(500, {"error": str(error)})
            return
        self.answer(200, {"ok": True})


def main():
    Handler.config = json.load(open(sys.argv[1], encoding="utf-8"))
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8780
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
