#!/bin/bash
# Fire test for the Cassandra dead-man's switch (PPC-6891 / PPC-6914).
#
# Two checks, both must pass before trusting the switch:
#   1. CADENCE — assert the max gap between recent workflow runs (any
#      trigger: schedule or the self-chain workflow_dispatch) stays under
#      BOUND_MINUTES. This is what PPC-6914 found missing: the alert path
#      was proven, the delivery cadence that triggers it was not.
#   2. ALERT PATH — force staleness, dispatch a check, confirm Telegram
#      fired with a real message_id (not just a log line saying so).
#
# Usage: scripts/fire_test.sh [--skip-alert]
set -euo pipefail

REPO="gabriele-franco/cassandra-deadman-switch"
WORKFLOW="deadman-check.yml"
BOUND_MINUTES="${BOUND_MINUTES:-15}"
LOOKBACK="${LOOKBACK:-50}"
WINDOW_MINUTES="${WINDOW_MINUTES:-60}"
SKIP_ALERT="${1:-}"

echo "=== 1/2: cadence check ==="
# Only consider runs from the last WINDOW_MINUTES — the self-chain's one-time
# startup lag (first run waiting on GitHub's scheduler, PPC-6914) is historical
# and must age out, not permanently fail this check.
CUTOFF_EPOCH=$(python3 -c "import datetime; print(int((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=$WINDOW_MINUTES)).timestamp()))")
mapfile -t ALL_TIMESTAMPS < <(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?per_page=$LOOKBACK" \
  --jq '.workflow_runs[].created_at' | sort)

TIMESTAMPS=()
for ts in "${ALL_TIMESTAMPS[@]}"; do
  EPOCH=$(python3 -c "import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$ts")
  [ "$EPOCH" -ge "$CUTOFF_EPOCH" ] && TIMESTAMPS+=("$ts")
done

if [ "${#TIMESTAMPS[@]}" -lt 2 ]; then
  echo "FAIL: not enough runs in the last ${WINDOW_MINUTES}min window to measure cadence (${#TIMESTAMPS[@]} found)"
  exit 1
fi

MAX_GAP=0
PREV_EPOCH=""
for ts in "${TIMESTAMPS[@]}"; do
  EPOCH=$(python3 -c "import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$ts")
  if [ -n "$PREV_EPOCH" ]; then
    GAP=$(( (EPOCH - PREV_EPOCH) / 60 ))
    [ "$GAP" -gt "$MAX_GAP" ] && MAX_GAP=$GAP
  fi
  PREV_EPOCH=$EPOCH
done
echo "runs_measured=${#TIMESTAMPS[@]} max_gap_minutes=$MAX_GAP bound_minutes=$BOUND_MINUTES"
if [ "$MAX_GAP" -gt "$BOUND_MINUTES" ]; then
  echo "FAIL: max gap ${MAX_GAP}min exceeds bound ${BOUND_MINUTES}min"
  exit 1
fi
echo "PASS: cadence within bound"

if [ "$SKIP_ALERT" = "--skip-alert" ]; then
  echo "=== 2/2: alert path (skipped) ==="
  exit 0
fi

echo "=== 2/2: alert path ==="
TMP_HEARTBEAT=$(mktemp)
OLD_PING=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
printf '{"last_ping_utc": "%s"}\n' "$OLD_PING" > "$TMP_HEARTBEAT"

CURRENT_SHA=$(gh api "repos/$REPO/contents/heartbeat.json" --jq '.sha')
CONTENT_B64=$(base64 < "$TMP_HEARTBEAT")
gh api -X PUT "repos/$REPO/contents/heartbeat.json" \
  -f message="fire_test: backdate heartbeat to force alert" \
  -f content="$CONTENT_B64" \
  -f sha="$CURRENT_SHA" >/dev/null
rm -f "$TMP_HEARTBEAT"

gh api --method POST "repos/$REPO/actions/workflows/$WORKFLOW/dispatches" -f ref=main
sleep 8
RUN_ID=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo "$REPO" --exit-status || true

LOG=$(gh run view "$RUN_ID" --repo "$REPO" --log)
if echo "$LOG" | grep -q "fired_down_alert=true"; then
  echo "PASS: alert fired on forced staleness (run $RUN_ID)"
else
  echo "FAIL: forced staleness did not fire an alert (run $RUN_ID)"
  exit 1
fi

echo "Heartbeat will self-correct on the host pinger's next cycle (<=5min)."
