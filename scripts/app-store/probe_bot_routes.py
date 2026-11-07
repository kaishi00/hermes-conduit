#!/usr/bin/env python3
"""Asks the demo dashboard for a bot's Bot Chat the ways Conduit does (its
history page, its work list, a resume over the gateway socket) and prints
each answer, so a promo walk that couldn't open the chat says why.

Usage: probe_bot_routes.py BASE_URL USER PASSWORD BOT
"""

import json
import sys
import urllib.request
from http.cookiejar import CookieJar

base, user, password, bot = sys.argv[1:5]
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()),
                                     urllib.request.ProxyHandler({}))


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    try:
        with opener.open(req, timeout=30) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return 0, repr(e)


print(call("POST", "/auth/password-login", {"provider": "basic", "username": user, "password": password}))
status, work = call("GET", f"/api/plugins/conduit_push/workstreams?conduit_profile={bot}")
print("work (conduit_profile)", status, work[:600])
def show(label, answer):
    print(label, answer[0], answer[1][:600])


show("work (profile)", call("GET", f"/api/plugins/conduit_push/workstreams?profile={bot}"))
chat = ""
try:
    chat = json.loads(work).get("bot_chat", "")
except ValueError:
    pass
print("bot chat", chat)
status, body = call("GET", f"/api/sessions/{chat}/messages?profile={bot}")
print("messages", status)
try:
    for row in json.loads(body).get("messages", []):
        content = row.get("content") or ""
        if row.get("tool_calls"):
            content += " " + json.dumps(row["tool_calls"])[:300]
        print("  ", row.get("role"), row.get("tool_name") or "", content[:500].replace("\n", " "))
except ValueError:
    print("  ", body[:600])
show("history page", call("POST", f"/api/plugins/conduit_push/sessions/history-page?profile={bot}",
                            {"session_id": chat, "offset": 0, "limit": 20, "order": "latest", "known": []}))
show("sessions", call("GET", f"/api/sessions?profile={bot}&limit=5"))
