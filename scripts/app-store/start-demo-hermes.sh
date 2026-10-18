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
#      DEMO_WORK (scratch dir). Writes $DEMO_WORK/*.log.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HERMES_COMMIT="${HERMES_COMMIT:-e6f57427c198cfd96854522b7a9159eb007e13c2}"
DEMO_HOST="${DEMO_HOST:-hermes.tail-demo.ts.net}"
DEMO_PORT="${DEMO_PORT:-9119}"
DEMO_USER="${DEMO_USER:-demo}"
DEMO_PASSWORD="${DEMO_PASSWORD:?set DEMO_PASSWORD}"
DEMO_WORK="${DEMO_WORK:-$PWD/demo-hermes}"
STUB_PORT="${STUB_PORT:-8765}"

mkdir -p "$DEMO_WORK"
export HERMES_HOME="$DEMO_WORK/home"
mkdir -p "$HERMES_HOME"

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

if [ ! -d "$DEMO_WORK/src/.git" ]; then
  git init -q "$DEMO_WORK/src"
  git -C "$DEMO_WORK/src" remote add origin https://github.com/NousResearch/hermes-agent
fi
git -C "$DEMO_WORK/src" fetch -q --depth 1 origin "$HERMES_COMMIT"
git -C "$DEMO_WORK/src" checkout -q FETCH_HEAD

uv venv -q --allow-existing -p 3.14 "$DEMO_WORK/venv"
VIRTUAL_ENV="$DEMO_WORK/venv" uv pip install -q -e "$DEMO_WORK/src"
HERMES="$DEMO_WORK/venv/bin/hermes"
PY="$DEMO_WORK/venv/bin/python"

# Conduit never loads the web UI, but the dashboard serves an index page and
# --skip-build would otherwise try npm. A bare page with a <head> is enough.
mkdir -p "$DEMO_WORK/src/hermes_cli/web_dist"
printf '<!doctype html><html><head></head><body></body></html>' > "$DEMO_WORK/src/hermes_cli/web_dist/index.html"

"$HERMES" config set model.provider custom >/dev/null
"$HERMES" config set model.base_url "http://127.0.0.1:$STUB_PORT/v1" >/dev/null
"$HERMES" config set model.default hermes-4-405b >/dev/null
# The scripted tool calls run unattended (they only touch the runner).
"$HERMES" config set approvals.mode off >/dev/null
# The board is staged by seed_board.py; nothing may pick its tasks up.
"$HERMES" config set kanban.dispatch_in_gateway false >/dev/null
"$HERMES" config set kanban.auto_decompose false >/dev/null

# Password sign-in plus a non-loopback public URL: that engages the dashboard's
# auth gate on a loopback bind, the same gated mode real remote setups use.
(cd "$DEMO_WORK/src" && DEMO_USER="$DEMO_USER" DEMO_PASSWORD="$DEMO_PASSWORD" \
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
  || { echo "::warning::notifier plugin install failed"; tail -20 "$DEMO_WORK/plugin.log"; }

if ! grep -q " $DEMO_HOST\$" /etc/hosts; then
  echo "127.0.0.1 $DEMO_HOST" | sudo tee -a /etc/hosts >/dev/null
  sudo dscacheutil -flushcache 2>/dev/null || true
fi

# Hermes works (and the scripted tool calls write) in the scratch dir.
cd "$DEMO_WORK"
nohup python3 "$SCRIPT_DIR/llm_stub.py" "$SCRIPT_DIR/demo-script.json" "$STUB_PORT" > "$DEMO_WORK/stub.log" 2>&1 &
nohup "$HERMES" gateway run > "$DEMO_WORK/gateway.log" 2>&1 &
nohup "$HERMES" dashboard --no-open --skip-build --port "$DEMO_PORT" > "$DEMO_WORK/dashboard.log" 2>&1 &

BASE="http://$DEMO_HOST:$DEMO_PORT"
for _ in $(seq 1 90); do
  curl -sf "$BASE/api/status" >/dev/null && break
  sleep 2
done
curl -sf "$BASE/api/status" >/dev/null || { echo "::error::dashboard did not start"; tail -40 "$DEMO_WORK/dashboard.log"; exit 1; }

# Seed the chats through the gateway RPC the app itself uses, then the
# scheduled jobs through the CLI.
"$PY" -u "$SCRIPT_DIR/seed_demo.py" "$SCRIPT_DIR/demo-script.json" "$BASE" "$DEMO_USER" "$DEMO_PASSWORD" \
  2>&1 | tee "$DEMO_WORK/seed.log"
"$PY" "$SCRIPT_DIR/seed_board.py" "$SCRIPT_DIR/demo-script.json" "$HERMES" 2>&1 | tee -a "$DEMO_WORK/seed.log" \
  || echo "::warning::the Kanban board was not fully seeded"
"$PY" - "$SCRIPT_DIR/demo-script.json" <<'PY' > "$DEMO_WORK/cron.tsv"
import json, sys
for job in json.load(open(sys.argv[1])).get("cron", []):
    print("\t".join([job["name"], job["schedule"], job["prompt"], "paused" if job.get("paused") else ""]))
PY
while IFS=$'\t' read -r name schedule prompt paused; do
  "$HERMES" cron create --name "$name" ${paused:+--paused} "$schedule" "$prompt" >> "$DEMO_WORK/seed.log" 2>&1 \
    || echo "::warning::cron job '$name' was not created"
done < "$DEMO_WORK/cron.tsv"

jar="$DEMO_WORK/cookies"
curl -sf -c "$jar" -H 'Content-Type: application/json' \
  -d "{\"provider\":\"basic\",\"username\":\"$DEMO_USER\",\"password\":\"$DEMO_PASSWORD\"}" \
  "$BASE/auth/password-login" >/dev/null
for _ in $(seq 1 30); do
  curl -sf -b "$jar" "$BASE/api/sessions" | grep -q '"sessions":\[{' && break
  sleep 2
done
echo "Demo dashboard ready at $BASE:"
curl -sf -b "$jar" "$BASE/api/sessions" | "$PY" -c 'import json,sys; [print(" -", s.get("title"), s.get("message_count")) for s in json.load(sys.stdin)["sessions"]]'
