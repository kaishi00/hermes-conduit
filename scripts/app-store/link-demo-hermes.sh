#!/usr/bin/env bash
#
# Link two demo instances (start-demo-hermes.sh) as one owner's own Hermes, so
# a room can hold bots from both, the way Linked Rooms work between real
# installations: a rooms mailbox on this Mac (the one the notifier plugin
# ships, never the shared one), an invite from the first, accepted by the
# second, and both sides marking the Link as their owner's own.
#
# The instances must have been started with DEMO_MAILBOX_URL set to this
# mailbox's URL, so their gateways use it. Start the mailbox first with
# `link-demo-hermes.sh mailbox`, then the instances, then
# `link-demo-hermes.sh link`.
#
# Env: DEMO_SRC (the shared Hermes checkout), MAILBOX_PORT (9130),
#      HOME_A and HOME_B (each instance's HERMES_HOME), MAILBOX_WORK.
set -euo pipefail

MAILBOX_PORT="${MAILBOX_PORT:-9130}"
MAILBOX_WORK="${MAILBOX_WORK:-$PWD/demo-mailbox}"

case "${1:-}" in
  mailbox)
    plugin="${PLUGIN_DIR:?set PLUGIN_DIR to an installed conduit_push plugin}"
    mkdir -p "$MAILBOX_WORK/data"
    (cd "$plugin/mailbox" && PUBLIC_URL="http://127.0.0.1:$MAILBOX_PORT" PORT="$MAILBOX_PORT" \
      DATA_PATH="$MAILBOX_WORK/data/mailbox.sqlite" \
      nohup node --disable-warning=ExperimentalWarning src/server.mjs > "$MAILBOX_WORK/mailbox.log" 2>&1 &)
    for _ in $(seq 1 30); do
      curl -s -o /dev/null "http://127.0.0.1:$MAILBOX_PORT/" && break
      sleep 1
    done
    curl -s -o /dev/null "http://127.0.0.1:$MAILBOX_PORT/" \
      || { echo "::error::the rooms mailbox did not start"; tail -20 "$MAILBOX_WORK/mailbox.log"; exit 1; }
    echo "Rooms mailbox at http://127.0.0.1:$MAILBOX_PORT"
    ;;
  link)
    HERMES="${DEMO_SRC:?}/.venv/bin/hermes"
    a="${HOME_A:?}"; b="${HOME_B:?}"
    export CONDUIT_ROOMS_MAILBOX_URL="http://127.0.0.1:$MAILBOX_PORT"
    invite=$(HERMES_HOME="$a" "$HERMES" conduit-push links invite --name "Home" | grep -o 'conduit://link/[^[:space:]]*' | head -1)
    [ -n "$invite" ] || { echo "::error::the first instance made no Link invite"; exit 1; }
    HERMES_HOME="$b" "$HERMES" conduit-push links accept "$invite" --name "Studio"
    # The Link settles once both gateways have read their inboxes.
    link_id() {
      HERMES_HOME="$1" "$HERMES" conduit-push links list | sed -n 's/.*(Link \([A-Za-z0-9_-]*\)).*/\1/p' | head -1 || true
    }
    for _ in $(seq 1 60); do
      if HERMES_HOME="$a" "$HERMES" conduit-push links list | grep -q ': linked' \
        && HERMES_HOME="$b" "$HERMES" conduit-push links list | grep -q ': linked'; then
        break
      fi
      sleep 2
    done
    id_a=$(link_id "$a"); id_b=$(link_id "$b")
    [ -n "$id_a" ] && [ -n "$id_b" ] || { echo "::error::the Link never settled"; \
      HERMES_HOME="$a" "$HERMES" conduit-push links list; HERMES_HOME="$b" "$HERMES" conduit-push links list; exit 1; }
    HERMES_HOME="$a" "$HERMES" conduit-push links own "$id_a" on
    HERMES_HOME="$b" "$HERMES" conduit-push links own "$id_b" on
    for _ in $(seq 1 30); do
      HERMES_HOME="$a" "$HERMES" conduit-push links list | grep -q 'own Hermes on both sides' \
        && HERMES_HOME="$b" "$HERMES" conduit-push links list | grep -q 'own Hermes on both sides' && break
      sleep 2
    done
    HERMES_HOME="$a" "$HERMES" conduit-push links list
    HERMES_HOME="$b" "$HERMES" conduit-push links list
    HERMES_HOME="$a" "$HERMES" conduit-push links list | grep -q 'own Hermes on both sides' \
      || { echo "::error::the Link isn't marked own on both sides"; exit 1; }
    ;;
  *)
    echo "usage: link-demo-hermes.sh mailbox|link" >&2
    exit 2
    ;;
esac
