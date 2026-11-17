#!/usr/bin/env bash
#
# Start the App Store demo dashboard on this Mac: a real Hermes Agent (pinned
# commit) with the Conduit notifier plugin, password sign-in, and the scripted
# model (llm_stub.py) as its provider, then seed the demo chats from
# demo-script.json through Hermes itself. The dashboard answers at
# http://$DEMO_HOST:$DEMO_PORT, a *.ts.net name /etc/hosts points at this Mac,
# so the app's normal Tailscale rules allow plain HTTP and the screenshots show
# a believable address.
#
# Env: HERMES_COMMIT (pinned), DEMO_HOST, DEMO_PORT, DEMO_USER, DEMO_PASSWORD,
#      DEMO_WORK (scratch dir), STUB_PORT, DEMO_SCRIPT (the script to replay
#      and seed), DEMO_SRC (a Hermes checkout two instances share),
#      DEMO_MAILBOX_URL (a local rooms mailbox), DEMO_APPROVALS (off or manual),
#      DEMO_ROOM_GUEST (1: every profile set up to join rooms another Hermes
#      hosts, through its API server). Writes $DEMO_WORK/*.log and
#      $DEMO_WORK/bot-chats.json (each bot's Bot Chat, for demo_director.py).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HERMES_COMMIT="${HERMES_COMMIT:-ae2a81ccc00e9b7c06301523e5bb09608397149c}"  # v0.23.2
DEMO_HOST="${DEMO_HOST:-hermes.tail-demo.ts.net}"
DEMO_PORT="${DEMO_PORT:-9119}"
DEMO_USER="${DEMO_USER:-demo}"
DEMO_PASSWORD="${DEMO_PASSWORD:?set DEMO_PASSWORD}"
DEMO_WORK="${DEMO_WORK:-$PWD/demo-hermes}"
STUB_PORT="${STUB_PORT:-8765}"
DEMO_SRC="${DEMO_SRC:-$DEMO_WORK/src}"
DEMO_SCRIPT="${DEMO_SCRIPT:-$SCRIPT_DIR/demo-script.json}"
# Absolute, since the services start from $DEMO_WORK.
DEMO_SCRIPT="$(cd "$(dirname "$DEMO_SCRIPT")" && pwd)/$(basename "$DEMO_SCRIPT")"

mkdir -p "$DEMO_WORK"
export HERMES_HOME="$DEMO_WORK/home"
mkdir -p "$HERMES_HOME"

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# Hermes refuses wheel builds, so it runs from a checkout with its own locked
# environment (uv sync --frozen), as notifier's upstream/install-hermes.sh
# does. A second demo instance shares the checkout (DEMO_SRC) and only gets a
# home of its own.
if [ ! -x "$DEMO_SRC/.venv/bin/hermes" ]; then
  if [ ! -d "$DEMO_SRC/.git" ]; then
    git init -q "$DEMO_SRC"
    git -C "$DEMO_SRC" remote add origin https://github.com/NousResearch/hermes-agent
  fi
  git -C "$DEMO_SRC" fetch -q --depth 1 origin "$HERMES_COMMIT"
  git -C "$DEMO_SRC" checkout -q --force FETCH_HEAD
  (cd "$DEMO_SRC" && uv sync --frozen --quiet)
fi
HERMES="$DEMO_SRC/.venv/bin/hermes"
PY="$DEMO_SRC/.venv/bin/python"

# Conduit never loads the web UI, but the dashboard serves an index page and
# --skip-build would otherwise try npm. A bare page with a <head> is enough.
mkdir -p "$DEMO_SRC/hermes_cli/web_dist"
printf '<!doctype html><html><head></head><body></body></html>' > "$DEMO_SRC/hermes_cli/web_dist/index.html"

"$HERMES" config set model.provider custom >/dev/null
"$HERMES" config set model.base_url "http://127.0.0.1:$STUB_PORT/v1" >/dev/null
"$HERMES" config set model.default hermes-4-405b >/dev/null
# The scripted tool calls run unattended (they only touch the runner), except
# on a demo instance whose videos show an approval (DEMO_APPROVALS=manual): its
# seeded turns run nothing that asks.
"$HERMES" config set approvals.mode "${DEMO_APPROVALS:-off}" >/dev/null
# The board is staged by seed_board.py; nothing may pick its tasks up.
"$HERMES" config set kanban.dispatch_in_gateway false >/dev/null
"$HERMES" config set kanban.auto_decompose false >/dev/null

# Password sign-in plus a non-loopback public URL: that engages the dashboard's
# auth gate on a loopback bind, the same gated mode real remote setups use.
(cd "$DEMO_SRC" && DEMO_USER="$DEMO_USER" DEMO_PASSWORD="$DEMO_PASSWORD" \
  PUBLIC_URL="http://$DEMO_HOST:$DEMO_PORT" "$PY" - <<'PY'
import os, secrets
from plugins.dashboard_auth.basic import hash_password
from hermes_cli.config import load_config, save_config
from hermes_cli.plugins_cmd import ensure_basic_auth_plugin_enabled_in_config
cfg = load_config()
dash = cfg.setdefault("dashboard", {})
dash["public_url"] = os.environ["PUBLIC_URL"]
dash.setdefault("basic_auth", {}).update(
    username=os.environ["DEMO_USER"],
    password_hash=hash_password(os.environ["DEMO_PASSWORD"]),
    password="",
    secret=secrets.token_urlsafe(32),
)
ensure_basic_auth_plugin_enabled_in_config(cfg)
save_config(cfg)
PY
)

"$HERMES" plugins install kaishi00/hermes-conduit-notifier --enable > "$DEMO_WORK/plugin.log" 2>&1 \
  || { echo "::error::notifier plugin install failed"; tail -20 "$DEMO_WORK/plugin.log"; exit 1; }

if ! grep -q " $DEMO_HOST\$" /etc/hosts; then
  echo "127.0.0.1 $DEMO_HOST" | sudo tee -a /etc/hosts >/dev/null
  sudo dscacheutil -flushcache 2>/dev/null || true
fi

# Hermes works (and the scripted tool calls write) in the scratch dir.
cd "$DEMO_WORK"
# Linked Rooms between the demo instances go through a mailbox on this Mac
# (start-demo-mailbox.sh), never the shared one.
if [ -n "${DEMO_MAILBOX_URL:-}" ]; then
  export CONDUIT_ROOMS_MAILBOX_URL="$DEMO_MAILBOX_URL"
fi
nohup python3 "$SCRIPT_DIR/llm_stub.py" "$DEMO_SCRIPT" "$STUB_PORT" > "$DEMO_WORK/stub.log" 2>&1 &
nohup "$HERMES" gateway run > "$DEMO_WORK/gateway.log" 2>&1 &
gateway_pid=$!
nohup "$HERMES" dashboard --no-open --skip-build --port "$DEMO_PORT" > "$DEMO_WORK/dashboard.log" 2>&1 &

BASE="http://$DEMO_HOST:$DEMO_PORT"
for _ in $(seq 1 90); do
  curl -sf "$BASE/api/status" >/dev/null && break
  sleep 2
done
curl -sf "$BASE/api/status" >/dev/null || { echo "::error::dashboard did not start"; tail -40 "$DEMO_WORK/dashboard.log"; exit 1; }

# Seed the chats through the gateway RPC the app itself uses, then the
# scheduled jobs through the CLI.
DEMO_APPROVALS="${DEMO_APPROVALS:-off}" DEMO_BOT_CHATS="$DEMO_WORK/bot-chats.json" "$PY" -u "$SCRIPT_DIR/seed_demo.py" "$DEMO_SCRIPT" "$BASE" "$DEMO_USER" "$DEMO_PASSWORD" \
  2>&1 | tee "$DEMO_WORK/seed.log"
"$PY" "$SCRIPT_DIR/seed_board.py" "$DEMO_SCRIPT" "$HERMES" 2>&1 | tee -a "$DEMO_WORK/seed.log" \
  || { echo "::error::the Kanban board was not fully seeded"; exit 1; }
"$PY" - "$DEMO_SCRIPT" <<'PY' > "$DEMO_WORK/cron.tsv"
import json, sys
for job in json.load(open(sys.argv[1])).get("cron", []):
    print("\t".join([job["name"], job["schedule"], job["prompt"], "paused" if job.get("paused") else ""]))
PY
while IFS=$'\t' read -r name schedule prompt paused; do
  "$HERMES" cron create --name "$name" ${paused:+--paused} "$schedule" "$prompt" >> "$DEMO_WORK/seed.log" 2>&1 \
    || { echo "::error::cron job '$name' was not created"; tail -20 "$DEMO_WORK/seed.log"; exit 1; }
done < "$DEMO_WORK/cron.tsv"

# Bots that join rooms another of the owner's Hermes hosts are reached
# through this Hermes' API server, with a key per profile (conduit-push rooms
# setup); until then the host lists them as not ready and dropping one on a
# bot there starts no room. The gateway restarts (below) to start the API
# server.
if [ "${DEMO_ROOM_GUEST:-}" = 1 ]; then
  for home in "$HERMES_HOME" "$HERMES_HOME"/profiles/*; do
    [ -d "$home" ] || continue
    HERMES_HOME="$home" "$HERMES" conduit-push rooms setup --yes --no-restart >> "$DEMO_WORK/rooms-setup.log" 2>&1 \
      || { echo "::error::rooms setup failed for $home"; tail -20 "$DEMO_WORK/rooms-setup.log"; exit 1; }
  done
fi

# From here the gateway runs under a loop that starts it again when it exits,
# as a service supervisor would: on the busy runner (the app builds for most
# of an hour) Hermes' liveness watchdog can stop it (exit 75), and rooms,
# links and approvals all live in the gateway.
kill "$gateway_pid" 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "$gateway_pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$gateway_pid" 2>/dev/null; then
  kill -9 "$gateway_pid" 2>/dev/null || true
  sleep 2
  kill -0 "$gateway_pid" 2>/dev/null && { echo "::error::the old gateway did not stop"; exit 1; }
fi
nohup bash -c 'while :; do "$1" gateway run; echo "== gateway exited $?, starting it again ($(date -u +%H:%M:%S))"; sleep 3; done' \
  gateway-loop "$HERMES" >> "$DEMO_WORK/gateway.log" 2>&1 &

if [ "${DEMO_ROOM_GUEST:-}" = 1 ]; then
  api="$(sed -n 's/.*at \([0-9.]*:[0-9]*\).*/\1/p' "$DEMO_WORK/rooms-setup.log" | tail -1)"
  for _ in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://${api:-127.0.0.1:8642}/" || true)" != "000" ] && break
    sleep 2
  done
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://${api:-127.0.0.1:8642}/" || true)" != "000" ] \
    || { echo "::error::the API server did not start for rooms"; tail -30 "$DEMO_WORK/gateway.log"; exit 1; }
fi

jar="$DEMO_WORK/cookies"
curl -sf -c "$jar" -H 'Content-Type: application/json' \
  -d "{\"provider\":\"basic\",\"username\":\"$DEMO_USER\",\"password\":\"$DEMO_PASSWORD\"}" \
  "$BASE/auth/password-login" >/dev/null
for _ in $(seq 1 30); do
  curl -sf -b "$jar" "$BASE/api/sessions" | grep -q '"sessions":\[{' && break
  sleep 2
done
curl -sf -b "$jar" "$BASE/api/sessions" | grep -q '"sessions":\[{' \
  || { echo "::error::the dashboard lists no seeded chats"; tail -40 "$DEMO_WORK/dashboard.log"; exit 1; }
echo "Demo dashboard ready at $BASE:"
curl -sf -b "$jar" "$BASE/api/sessions" | "$PY" -c 'import json,sys; [print(" -", s.get("title"), s.get("message_count")) for s in json.load(sys.stdin)["sessions"]]'
