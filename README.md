# Cassandra Deadman Switch (PPC-6891)

Off-host dead-man's switch for the Cassandra agent fleet Mac host.

## How it works

1. A launchd LaunchAgent on the Mac host (`com.cassandra.deadman-pinger`, see
   `~/.openclaw/workspace/scripts/deadman_switch_ping.sh`) updates `heartbeat.json`
   in this repo every 5 minutes via the GitHub Contents API, writing the current
   UTC timestamp.
2. A GitHub Actions workflow (`.github/workflows/deadman-check.yml`) runs on
   GitHub's own schedule every 5 minutes — independent of the Mac host entirely.
   It reads `heartbeat.json`, computes how stale it is, and fires a Telegram
   alert to Gabriele's existing chat (same bot/chat already used by the on-host
   `paperclip_telegram_alerts.py`) if the heartbeat is more than 25 minutes old.
3. State (`state.json`, whether an alert is currently "open") is committed back
   to the repo so the workflow only fires once per outage, and once on recovery
   — never a storm of repeated alerts.

If the Mac host is down, the pinger simply can't run — the staleness is what
gets detected, by a system that isn't itself hosted on the thing it's watching.

## Threshold

Ping every 5 min, alert after 25 min of silence (5 missed pings). Tight enough
to catch an extended outage within ~25 minutes; loose enough to not fire on a
single missed tick or a routine reboot.

## Tuning

Edit `THRESHOLD_MINUTES` in `.github/workflows/deadman-check.yml`.
