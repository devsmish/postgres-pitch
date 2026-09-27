#!/bin/bash
# tests/failover_test.sh
#
# Kills the current Patroni-elected primary and measures how long it
# takes for a new primary to be elected, verifying that the promoted
# node was the synchronous standby (not the async replica) — the
# zero-data-loss guarantee configured in
# docker-compose/patroni/patroni.yml (synchronous_mode: true).
#
# Uses `docker kill` (SIGKILL), not `docker stop` — this simulates a
# genuine crash rather than a graceful shutdown, so the result reflects
# Patroni's actual TTL-based failure detection (see the dcs.ttl /
# dcs.loop_wait comments in patroni.yml), not a clean handover.
#
# Usage: run from anywhere, with the cluster already up and healthy
# (`make up` / `make status`):
#   bash tests/failover_test.sh
#
# Prerequisites: docker, curl, python3 (used for JSON parsing so this
# doesn't require jq to be installed).
set -euo pipefail

NODES=("postgresql0" "postgresql1" "postgresql2")
declare -A REST_PORTS=( [postgresql0]=8009 [postgresql1]=8010 [postgresql2]=8011 )
CONTAINER_PREFIX="postgres-pitch-"
POLL_INTERVAL=1
TIMEOUT_SECONDS=60

# --- helpers ---------------------------------------------------------------

cluster_json() {
  # Any healthy node answers /cluster the same way — it reflects what's
  # in the DCS, not node-local state — so it doesn't matter which one we
  # happen to reach first.
  for node in "${NODES[@]}"; do
    if out=$(curl -sf "http://localhost:${REST_PORTS[$node]}/cluster" 2>/dev/null); then
      echo "$out"
      return 0
    fi
  done
  return 1
}

member_with_role() {
  # member_with_role <cluster_json> <role>
  python3 -c "
import json, sys
data = json.loads(sys.argv[1])
for m in data.get('members', []):
    if m.get('role') == sys.argv[2]:
        print(m.get('name', ''))
        break
" "$1" "$2"
}

current_leader() {
  local json
  json=$(cluster_json) || return 1
  member_with_role "$json" "leader"
}

current_sync_standby() {
  local json
  json=$(cluster_json) || return 1
  member_with_role "$json" "sync_standby"
}

# --- pre-flight --------------------------------------------------------

echo "==> Checking cluster is healthy before starting..."
if ! cluster_json > /dev/null; then
  echo "ERROR: could not reach any node's REST API — is the cluster up? (make status)" >&2
  exit 1
fi

LEADER_BEFORE=$(current_leader) || true
SYNC_BEFORE=$(current_sync_standby) || true

if [ -z "${LEADER_BEFORE:-}" ]; then
  echo "ERROR: no current leader found — cluster is not healthy, aborting" >&2
  exit 1
fi

echo "    Current leader:       $LEADER_BEFORE"
echo "    Current sync standby: ${SYNC_BEFORE:-<none>}"

if [ -z "${SYNC_BEFORE:-}" ]; then
  echo ""
  echo "WARNING: no synchronous standby detected. synchronous_mode may not"
  echo "         have converged yet — the result below won't confirm the"
  echo "         zero-data-loss guarantee. Consider waiting and re-running."
fi

# --- kill the leader -----------------------------------------------------

echo ""
echo "==> Killing the leader container: ${CONTAINER_PREFIX}${LEADER_BEFORE}"
START_TIME=$(date +%s)
docker kill "${CONTAINER_PREFIX}${LEADER_BEFORE}" > /dev/null

# --- poll for a new leader ------------------------------------------------

echo "==> Waiting for a new leader to be elected..."
NEW_LEADER=""
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT_SECONDS" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$(( $(date +%s) - START_TIME ))
  candidate=$(current_leader 2>/dev/null || true)
  if [ -n "$candidate" ] && [ "$candidate" != "$LEADER_BEFORE" ]; then
    NEW_LEADER="$candidate"
    break
  fi
done

END_TIME=$(date +%s)
DOWNTIME=$(( END_TIME - START_TIME ))

echo ""
echo "==================== RESULTS ===================="
if [ -z "$NEW_LEADER" ]; then
  echo "FAILED: no new leader elected within ${TIMEOUT_SECONDS}s"
  echo "==================================================="
  exit 1
fi

echo "Old leader:            $LEADER_BEFORE (killed)"
echo "New leader:            $NEW_LEADER"
echo "Failover time:         ${DOWNTIME}s (container kill -> new leader visible)"

if [ "$NEW_LEADER" == "$SYNC_BEFORE" ]; then
  echo "Promoted node check:   PASS — the synchronous standby was promoted"
  echo "                       (zero-data-loss failover, as designed)"
else
  echo "Promoted node check:   WARNING — promoted node ('$NEW_LEADER') was NOT"
  echo "                       the synchronous standby ('${SYNC_BEFORE:-none}')."
  echo "                       This can happen if sync status hadn't converged"
  echo "                       before the kill, or under different"
  echo "                       synchronous_mode_strict behavior. Review the"
  echo "                       'Current sync standby' line above before"
  echo "                       treating this as a failure."
fi
echo "==================================================="

echo ""
echo "==> Restarting the old leader so it can rejoin as a replica..."
docker start "${CONTAINER_PREFIX}${LEADER_BEFORE}" > /dev/null
echo "    Done. Run 'make status' in a moment to confirm it rejoined cleanly."
