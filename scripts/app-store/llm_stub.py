#!/usr/bin/env python3
"""Scripted OpenAI-compatible model for the App Store demo dashboard.

Hermes talks to this like any custom provider (model.provider: custom), so the
real agent loop, tools and session store produce every chat; only the model's
words come from the script. A reply is chosen by the newest user message:
the script entry whose "match" text it contains, then the step numbered by how
many tool results follow that message. Anything unmatched (titles, memory
reviews, compression) gets a short neutral answer so Hermes never stalls.

Standard library only. Usage: llm_stub.py SCRIPT.json [PORT]
"""

import json
import os
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = "hermes-4-405b"


def load_script(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def pick_step(script, messages):
    last_user = None
    for i, m in enumerate(messages):
        if m.get("role") == "user":
            last_user = i
    if last_user is None:
        return {"content": "Okay."}
    prompt = text_of(messages[last_user].get("content")).lower()
    system = " ".join(text_of(m.get("content")) for m in messages if m.get("role") == "system").lower()
    tool_results = sum(1 for m in messages[last_user + 1:] if m.get("role") == "tool")
    for entry in script.get("chats", []):
        for turn in entry.get("turns", []):
            if turn["match"].lower() in prompt:
                steps = turn["steps"]
                # Title requests quote the first exchange; answer with the title.
                if "title" in system and entry.get("title") and len(messages) <= 3:
                    return {"content": entry["title"]}
                return steps[min(tool_results, len(steps) - 1)]
    if "title" in system:
        return {"content": "New chat"}
    return {"content": script.get("fallback", "Done.")}


def chunk(delta, finish=None):
    return {
        "id": "chatcmpl-" + uuid.uuid4().hex[:12],
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": MODEL,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }


def tool_calls_of(step):
    calls = []
    for n, call in enumerate(step.get("tool_calls", [])):
        calls.append({
            "index": n,
            "id": "call_" + uuid.uuid4().hex[:16],
            "type": "function",
            "function": {"name": call["name"], "arguments": json.dumps(call.get("arguments", {}))},
        })
    return calls


def words(text, size=12):
    for start in range(0, len(text), size):
        yield text[start:start + size]


class Handler(BaseHTTPRequestHandler):
    script = {}
    delay = 0.0

    def log_message(self, *args):
        pass

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self.send_json(200, {"object": "list", "data": [
                {"id": MODEL, "object": "model", "owned_by": "conduit-demo", "context_length": 131072}
            ]})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if not self.path.rstrip("/").endswith("/chat/completions"):
            self.send_json(404, {"error": "not found"})
            return
        dump = os.environ.get("STUB_DUMP_TOOLS")
        if dump and body.get("tools") and not os.path.exists(dump):
            with open(dump, "w", encoding="utf-8") as f:
                json.dump(body["tools"], f, indent=1)
        step = pick_step(self.script, body.get("messages", []))
        calls = tool_calls_of(step)
        finish = "tool_calls" if calls else "stop"
        usage = {"prompt_tokens": 1800, "completion_tokens": 240, "total_tokens": 2040}
        if not body.get("stream"):
            message = {"role": "assistant", "content": step.get("content", "")}
            if step.get("reasoning"):
                message["reasoning_content"] = step["reasoning"]
            if calls:
                message["tool_calls"] = [{k: v for k, v in c.items() if k != "index"} for c in calls]
            self.send_json(200, {
                "id": "chatcmpl-" + uuid.uuid4().hex[:12], "object": "chat.completion",
                "created": int(time.time()), "model": MODEL,
                "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                "usage": usage,
            })
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        delay = float(step.get("delay", self.delay))

        def emit(obj):
            self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")
            self.wfile.flush()
            if delay:
                time.sleep(delay)

        emit(chunk({"role": "assistant", "content": ""}))
        for piece in words(step.get("reasoning", "")):
            emit(chunk({"reasoning_content": piece}))
        for piece in words(step.get("content", "")):
            emit(chunk({"content": piece}))
        if calls:
            emit(chunk({"tool_calls": calls}))
        final = chunk({}, finish)
        final["usage"] = usage
        emit(final)
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    Handler.script = load_script(sys.argv[1])
    Handler.delay = float(Handler.script.get("stream_delay", 0.0))
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
