#!/bin/sh
# Starts hermes-conduit's Nightly workflow on main as the overnight run
# (`nightly: true`, titled "Nightly (overnight)"). Run by
# conduit-nightly.timer at 3:17 AM ET; README.md says why.
#
# The token is a fine-grained PAT limited to kaishi00/hermes-conduit with
# Actions: Read and write, nothing else, kept in a root-only file.
set -eu
token_file="${CONDUIT_NIGHTLY_TOKEN_FILE:-/root/.config/conduit-nightly/token}"
repo="${CONDUIT_NIGHTLY_REPO:-kaishi00/hermes-conduit}"
umask 077
out=$(mktemp)
trap 'rm -f "$out"' EXIT

attempt=1
while :; do
  # The token reaches curl through its config on stdin (printf is a shell
  # builtin), never on a command line other users can read in /proc.
  status=$(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$token_file")" |
    curl -sS --config - --connect-timeout 30 --max-time 120 -o "$out" -w '%{http_code}' \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$repo/actions/workflows/nightly.yml/dispatches" \
    -d '{"ref":"main","inputs":{"nightly":true}}' || true)
  # curl prints 000 itself when it gets no response.
  status=${status:-000}
  # 204 (older API) or 200 with the run's id (newer API) both mean started.
  case "$status" in
    200|204) echo "Nightly dispatched on main (HTTP $status)"; exit 0 ;;
  esac
  echo "dispatch attempt $attempt failed: HTTP $status $(head -c 300 "$out" 2>/dev/null)" >&2
  # A 401 or 403 is the token (expired or revoked): retrying won't help.
  case "$status" in 401|403|404|422) exit 1 ;; esac
  [ "$attempt" -ge 4 ] && exit 1
  sleep $((attempt * 60))
  attempt=$((attempt + 1))
done
