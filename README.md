# Cassandra Deadman Switch (PPC-6891)

Off-host dead-man's switch for the Cassandra agent fleet Mac host.

## How it works

1. A launchd LaunchAgent on the Mac host (`com.cassandra.deadman-pinger`, see
   `~/.openclaw/workspace/scripts/deadman_switch_ping.sh`) updates `heartbeat.json`
   in this repo every 5 minutes via the GitHub Contents API, writing the current
   UTC timestamp.
2. A GitHub Actions workflow (`.github/workflows/deadman-check.yml`) checks
   `heartbeat.json` and fires a Telegram alert to Gabriele's existing chat
   (same bot/chat already used by the on-host `paperclip_telegram_alerts.py`)
   if it's more than `THRESHOLD_MINUTES` old. **The check re-triggers itself**
   via `workflow_dispatch` at the end of every run (~5min later), independent
   of GitHub's own scheduler. The `*/5 * * * *` cron also on this workflow is
   only a recovery net if that self-chain ever breaks — see "Cadence" below
   for why the cron alone isn't the real mechanism.
3. State (`state.json`, whether an alert is currently "open") is committed back
   to the repo so the workflow only fires once per outage, and once on recovery
   — never a storm of repeated alerts.

If the Mac host is down, the pinger simply can't run — the staleness is what
gets detected, by a system that isn't itself hosted on the thing it's watching.

## Threshold

Alert after 25 min of silence (`THRESHOLD_MINUTES`, ~5 missed pings at the
delivered cadence below). Tight enough to catch an extended outage quickly;
loose enough to not fire on a single missed tick or a routine reboot.

## Cadence

**GitHub's `schedule` trigger is best-effort and is not the cadence this
switch relies on.** Measured 2026-10-28 (PPC-6914): over the first ~9h of
this workflow's life, `event=="schedule"` runs had a longest gap of **5h48m**
against a declared `*/5` — ~250x slower than the cron string implies, because
GitHub deprioritizes schedule triggers hardest on repos with little other
activity, which this repo is by construction.

Fix: the workflow re-dispatches itself (`workflow_dispatch`) at the end of
every run, so the real cadence comes from the chain, not GitHub's scheduler.
The `*/5` cron stays only as a restarter if a runner failure ever breaks the
chain — its own cadence is still the ~6h figure above, so a broken chain's
worst case is "~6h instead of ~5min" rather than silent forever.

Confirmed post-fix: the self-chain dispatched its next run at
`2026-10-28T08:29:05Z`, exactly `CHAIN_INTERVAL_SECONDS` (300s) after the
prior run started — the real cadence is now ~5min, not ~6h.

Run `scripts/fire_test.sh` to assert the actual delivered cadence (gap across
*all* run triggers, not just `schedule`) and the alert path together. The
cadence check only looks at runs from the last `WINDOW_MINUTES` (default 60)
— this is deliberate: the one-time startup lag while the chain's first link
waited on GitHub's scheduler is historical and must age out of the check,
not fail it forever.

## Tuning

Edit `THRESHOLD_MINUTES` or `CHAIN_INTERVAL_SECONDS` in
`.github/workflows/deadman-check.yml`.
