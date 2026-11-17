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
#      HOME_A and HOME_B (each instance's HERMES_HOME), NAME_A and NAME_B (the
#      names each gives the other: Home, Studio), OWN (1, or 0 for a person),
#      MAILBOX_WORK,
#      DASHBOARD_A and COOKIES_A (A's dashboard URL and signed-in cookie jar:
#      the link waits until A lists B's bots as ready for rooms).
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
    name_a="${NAME_A:-Home}"; name_b="${NAME_B:-Studio}"
    made=$(HERMES_HOME="$a" "$HERMES" conduit-push links invite --name "$name_a")
    invite=$(grep -o 'conduit://link/[^[:space:]]*' <<< "$made" | sed -n 1p || true)
    [ -n "$invite" ] || { echo "::error::the first instance made no Link invite"; echo "$made"; exit 1; }
    HERMES_HOME="$b" "$HERMES" conduit-push links accept "$invite" --name "$name_b"
    # The Link settles once both gateways have read their inboxes. Each list
    # is read whole before it's searched: grep -q or head stopping early
    # would leave the CLI writing into a closed pipe.
    list() { HERMES_HOME="$1" "$HERMES" conduit-push links list || true; }
    # Each side lists the other by the name it gave: A's list has B's line,
    # B's has A's (a side may hold other Links too).
    line() { list "$1" | grep "^$2: " || true; }
    both_say() { [[ "$(line "$a" "$name_b")" == *"$1"* && "$(line "$b" "$name_a")" == *"$1"* ]]; }
    link_id() { line "$1" "$2" | sed -n 's/.*(Link \([A-Za-z0-9_-]*\)).*/\1/p' | sed -n 1p; }
    for _ in $(seq 1 60); do
      both_say ': linked' && break
      sleep 2
    done
    id_a=$(link_id "$a" "$name_b"); id_b=$(link_id "$b" "$name_a")
    [ -n "$id_a" ] && [ -n "$id_b" ] || { echo "::error::the Link never settled"; list "$a"; list "$b"; exit 1; }
    # OWN=0 links B as another person (rooms with people); by default the
    # two are marked as one owner's own Hermes.
    if [ "${OWN:-1}" = 1 ]; then
      # A Link id can start with "-", so it goes after "--".
      HERMES_HOME="$a" "$HERMES" conduit-push links own -- "$id_a" on
      HERMES_HOME="$b" "$HERMES" conduit-push links own -- "$id_b" on
      for _ in $(seq 1 30); do
        both_say 'own Hermes on both sides' && break
        sleep 2
      done
      list "$a"; list "$b"
      both_say 'own Hermes on both sides' || { echo "::error::the Link isn't marked own on both sides"; exit 1; }
    else
      list "$a"; list "$b"
    fi
    # With A's dashboard given, wait until it lists B's bots as ready to join
    # a room (B set up for rooms, DEMO_ROOM_GUEST), as Conduit reads them.
    if [ -n "${DASHBOARD_A:-}" ]; then
      own_bots() { curl -s -b "${COOKIES_A:?}" "$DASHBOARD_A/api/plugins/conduit_push/rooms/own-bots" || true; }
      for _ in $(seq 1 60); do
        bots="$(own_bots)"
        [[ "$bots" == *'"ready":true'* && "$bots" != *'"ready":false'* ]] && break
        sleep 2
      done
      echo "$bots"
      [[ "$bots" == *'"ready":true'* && "$bots" != *'"ready":false'* ]] \
        || { echo "::error::the first instance doesn't list the second's bots as ready for rooms"; exit 1; }
    fi
    ;;
  *)
    echo "usage: link-demo-hermes.sh mailbox|link" >&2
    exit 2
    ;;
esac
