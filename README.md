# Cassandra Deadman Switch (PPC-6891, hardened PPC-6975)

Off-host dead-man's switch for the Cassandra agent fleet Mac host.

**This repo is intentionally public.** It carries nothing sensitive
(`heartbeat.json`/`state.json` are just timestamps; Telegram creds stay as
encrypted Actions secrets, public or private). Public repos get free,
unmetered Actions minutes — see "Billing" below for why that matters.

## How it works

1. A launchd LaunchAgent on the Mac host (`com.cassandra.deadman-pinger`, see
   `~/.openclaw/workspace/scripts/deadman_switch_ping.sh`) every 5 minutes:
   a. updates `heartbeat.json` in this repo via the GitHub Contents API
      (host liveness signal — unchanged since PPC-6891);
   b. **directly dispatches** `deadman-check.yml` via `workflow_dispatch`
      (PPC-6975 — see "Cadence" below for why);
   c. **checks that the checker itself has completed a successful run
      recently**, alerting Telegram directly — bypassing Actions entirely —
      if it hasn't (PPC-6975 — see "Self-liveness" below).
2. The GitHub Actions workflow (`.github/workflows/deadman-check.yml`) checks
   `heartbeat.json` and fires a Telegram alert to Gabriele's existing chat
   (same bot/chat already used by the on-host `paperclip_telegram_alerts.py`)
   if it's more than `THRESHOLD_MINUTES` old. It also still re-triggers itself
   via `workflow_dispatch` at the end of every run (~5min later) — this stays
   in place *in addition to* the host's direct dispatch because it is the
   one cadence source that is independent of the host (catches a host-down
   outage even if 1(b) obviously can't fire). The `*/5 * * * *` cron on this
   workflow remains a last-resort recovery net for the case where *both* the
   host and the self-chain are down at once (which is exactly what happened
   during the outage this hardening responds to).
3. State (`state.json`, whether an alert is currently "open") is committed back
   to the repo so the workflow only fires once per outage, and once on recovery
   — never a storm of repeated alerts. The host-side self-liveness check keeps
   its own tiny state file (`logs/deadman_meta_state.json`, host-local) for the
   same edge-triggered reason.

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

**PPC-6975 defect 2:** a run that never starts (billing, a transient GitHub
Actions hiccup, anything) cannot re-dispatch itself, so a serialized
self-chain alone has exactly one point of failure per link. The host's
direct `workflow_dispatch` call every 5 minutes (step 1b above) does not
care whether the previous run started — it heals a broken chain within one
host tick (~5min) instead of waiting on the `*/5` cron's measured ~4-7h
throttle, as long as the host itself is up. Combined with the self-chain
(which stays the fast path for a host-down outage) and the cron (last
resort for both-down), no single failure in {host, one Actions run, the
scheduler} can stall the cadence for more than one host tick.

## Billing

**This repo must stay public.** A private repo on a personal GitHub account
draws from that account's paid Actions minutes — one declined card or
exceeded spending limit silently kills every job, with `steps_count: 0` and
no error visible anywhere but the run annotation (this is exactly what
happened 2026-10-29/30: Actions jobs here didn't start for 27h38m and the
switch sent nothing). Public repos get free, unmetered Actions minutes
regardless of the account's billing status. Re-privating this repo
re-introduces that single point of failure — don't.

## Self-liveness

PPC-6891's fire test proved the alert *path* once (a real Telegram
`message_id`); it never proved the runner would still be *permitted to
start* days later, which is exactly what failed. The host's pinger now also
checks (step 1c above) whether `deadman-check.yml` has completed a run with
`conclusion=="success"` in the last `META_THRESHOLD_MINUTES` (25, matching
the host-staleness threshold). If not, it sends a Telegram alert directly
via `curl` — no GitHub Actions involved in that path at all — so the one
failure mode that left this switch dark (Actions not running) cannot also
silence the alarm that watches for it. See
`~/.openclaw/workspace/scripts/deadman_switch_ping.sh` for the
implementation; it sources the same bot token/chat id as the Actions-side
alert (`/Users/jarvis/projects/claude-code-telegram/.env` +
`~/.openclaw/workspace/paperclip-digest/alerts.env`), so both alert paths
land in the same Telegram conversation.

## Tuning

Edit `THRESHOLD_MINUTES` or `CHAIN_INTERVAL_SECONDS` in
`.github/workflows/deadman-check.yml`. Edit `META_THRESHOLD_MINUTES` in
`~/.openclaw/workspace/scripts/deadman_switch_ping.sh` (host-side).
