# Nightly timer

GitHub creates a scheduled workflow's event late when it's busy: Nightly's
cron (3:17 AM ET) started at 15:07-18:50 UTC on 2026-11-09..14, so its 1.5 to
1.8 hours of macOS jobs held the runners through Eric's mornings and his PRs'
Smoke jobs queued behind them. A `workflow_dispatch` starts at once, so the
nightly run is dispatched from a timer on an always-on machine instead.

- Where: the Hermes host (10.1.10.52), as root, from systemd.
- When: 3:17 AM America/New_York (`conduit-nightly.timer`). A missed start
  isn't made up later.
- What: `conduit-nightly-dispatch.sh` dispatches `nightly.yml` on `main` with
  `nightly: true`, so the run is titled "Nightly (overnight)" and
  `nightly-rerun.yml` treats it as a nightly run (a release candidate's
  dispatch keeps `nightly` off and its own result).
- Token: a fine-grained PAT owned by kaishi00, limited to
  kaishi00/hermes-conduit with Actions: Read and write and no other
  permission, in `/root/.config/conduit-nightly/token` (mode 600).
- Backup: Nightly's own cron, at 09:47 UTC, skips itself when Nightly ran on
  `main` in the last 20 hours by dispatch (its own cron runs don't count),
  and otherwise runs with a warning. "The overnight timer ... missed" means
  no dispatch reached GitHub. `journalctl -u conduit-nightly.service` shows a
  failed or refused dispatch (token expired or revoked, GitHub refused it).
  No entry for 3:17 means the service never started: the timer has
  `Persistent=false`, so a host that was down at 3:17 leaves no trace there;
  check the host's uptime and `systemctl list-timers conduit-nightly.timer`.
  "Couldn't list Nightly runs" means
  GitHub's API failed and says nothing about the timer.

## Install (on the host, as root)

    install -m 755 conduit-nightly-dispatch.sh /usr/local/bin/
    install -m 644 conduit-nightly.service conduit-nightly.timer /etc/systemd/system/
    install -d -m 700 /root/.config/conduit-nightly
    install -m 600 /dev/stdin /root/.config/conduit-nightly/token < token.txt
    systemctl daemon-reload && systemctl enable --now conduit-nightly.timer
    systemctl list-timers conduit-nightly.timer

`systemctl start conduit-nightly.service` dispatches a run now;
`journalctl -u conduit-nightly.service` shows each start.
