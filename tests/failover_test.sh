#!/bin/bash
# tests/failover_test.sh
#
# Kills the current Patroni-elected primary (docker kill = SIGKILL, a real
# crash rather than a graceful shutdown) and verifies, end to end, that the
# cluster and the client-facing layer recover on their own:
#
#   1. Patroni elects a new leader, and it is the node that was the
#      SYNCHRONOUS standby before the kill (zero-data-loss failover, see
#      docs/decisions/0002-synchronous-replication.md), not the async one.
#   2. The write endpoint (:5000) starts reaching the new primary without
#      the client changing its connection string.
#   3. The read-only endpoint (:5001) never lands on a primary and never
#      returns the dead old primary.
#   4. Fresh etl_writer / analytics_readonly sessions work without any
#      manual change of grants or settings.
#   5. After the old primary is restarted it rejoins as a replica, and the
#      read-only endpoint starts serving it again.
#
# Measured (seconds, from the moment of the kill; resolution ~1s):
#   - Patroni:  new leader visible in the Patroni REST API
#   - Client:   write endpoint answers on the new primary
#   - Rejoin:   old primary is a streaming replica again
#   - Read pool: old primary is served by the read-only endpoint again
# A Markdown row with these numbers is printed at the end, ready to paste
# into docs/failover-notes.md.
#
# All SQL runs through `docker exec` inside one of the cluster's own
# containers (on the compose network, where `haproxy` resolves), so no psql
# is needed on the host.
#
# Usage: run from anywhere, with the cluster up and healthy
# (`make up` / `make status`):
#   bash tests/failover_test.sh
#
# Environment overrides:
#   FAILOVER_TIMEOUT   seconds allowed for each recovery phase (default 90)
#
# Prerequisites: docker, curl, python3 (JSON parsing, so jq is not
# needed), and a populated .env in the repo root.
#
# Safety: the killed container is always started again on exit (even on
# Ctrl-C or a failed check), and the test table is dropped.
set -uo pipefail

# Git Bash (MSYS) on Windows rewrites arguments that look like unix paths
# (e.g. `-c /etc/patroni.yml` becomes `C:/Program Files/Git/etc/patroni.yml`)
# before docker ever sees them. Those paths are meant for the container, so
# disable the conversion. Harmless on Linux/macOS/WSL.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env, stripping CRs in case the file was saved with Windows line
# endings - a trailing \r would silently end up inside every password.
if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "ERROR: $REPO_ROOT/.env not found (cp .env.example .env)" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source <(tr -d '\r' < "$REPO_ROOT/.env")
set +a

DB="${POSTGRES_DB:-postgres_pitch}"
NODES=("postgresql0" "postgresql1" "postgresql2")
CONTAINER_PREFIX="postgres-pitch-"
WRITE_PORT=5000
READ_PORT=5001
POLL_INTERVAL=1
LEADER_TIMEOUT=60
TIMEOUT_SECONDS="${FAILOVER_TIMEOUT:-90}"
# "<primary|replica>|<server ip>" - says which role and which node answered.
WHO_SQL="SELECT CASE WHEN pg_is_in_recovery() THEN 'replica' ELSE 'primary' END || '|' || host(inet_server_addr())"

FAILURES=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }

# --- helpers ---------------------------------------------------------------

rest_port() {
  case "$1" in
    postgresql0) echo 8009 ;;
    postgresql1) echo 8010 ;;
    postgresql2) echo 8011 ;;
    *) return 1 ;;
  esac
}

cluster_json() {
  # Any healthy node answers /cluster the same way - it reflects what's in
  # the DCS, not node-local state - so it doesn't matter which one we reach.
  local node out
  for node in "${NODES[@]}"; do
    if out=$(curl -sf --max-time 3 "http://localhost:$(rest_port "$node")/cluster" 2>/dev/null); then
      echo "$out"
      return 0
    fi
  done
  return 1
}

# member_with_role <cluster_json> <role> -> name of the first member with it
member_with_role() {
  python3 -c "
import json, sys
for m in json.loads(sys.argv[1]).get('members', []):
    if m.get('role') == sys.argv[2]:
        print(m.get('name', ''))
        break
" "$1" "$2"
}

# member_field <cluster_json> <member name> <field> -> e.g. role / state
member_field() {
  python3 -c "
import json, sys
for m in json.loads(sys.argv[1]).get('members', []):
    if m.get('name') == sys.argv[2]:
        print(m.get(sys.argv[3], ''))
        break
" "$1" "$2" "$3"
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

container_ip() {
  # Single compose network assumed. Empty when the container is not running.
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "${CONTAINER_PREFIX}$1" 2>/dev/null
}

exec_container() {
  # Any running cluster container works as the "client" - pick the first.
  local n
  for n in "${NODES[@]}"; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}${n}" 2>/dev/null)" = "true" ]; then
      echo "${CONTAINER_PREFIX}${n}"
      return 0
    fi
  done
  return 1
}

# run_sql <port> <user> <password> <sql> -> stdout+stderr, psql's exit code
run_sql() {
  local port="$1" user="$2" password="$3" sql="$4" c
  c=$(exec_container) || { echo "no running cluster container"; return 99; }
  docker exec -e PGPASSWORD="$password" "$c" \
    psql -h haproxy -p "$port" -U "$user" -d "$DB" -tAqX -v ON_ERROR_STOP=1 -c "$sql" 2>&1
}

# sample_endpoint <port> <user> <password> <count>
# One new connection per sample; prints "<role>|<ip>" for each that succeeds.
sample_endpoint() {
  local port="$1" user="$2" password="$3" count="$4" i out
  for ((i = 0; i < count; i++)); do
    if out=$(run_sql "$port" "$user" "$password" "$WHO_SQL"); then
      echo "$out"
    fi
  done
}

expect_ok() {
  # expect_ok <label> <port> <user> <password> <sql> [expected-output]
  local label="$1" out rc
  out=$(run_sql "$2" "$3" "$4" "$5"); rc=$?
  if [ $rc -eq 0 ] && { [ -z "${6:-}" ] || [ "$out" = "$6" ]; }; then
    pass "$label"
  else
    fail "$label  (rc=$rc, got: $(echo "$out" | head -1))"
  fi
}

expect_error() {
  # expect_error <label> <expected-substring> <port> <user> <password> <sql>
  local label="$1" needle="$2" out rc
  out=$(run_sql "$3" "$4" "$5" "$6"); rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -qi "$needle"; then
    pass "$label"
  else
    fail "$label  (rc=$rc, expected error containing '$needle', got: $(echo "$out" | head -1))"
  fi
}

LEADER_BEFORE=""
TABLE_CREATED=""

cleanup() {
  # Never leave the cluster with a dead node, whatever happened above.
  if [ -n "$LEADER_BEFORE" ] &&
     [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}${LEADER_BEFORE}" 2>/dev/null)" != "true" ]; then
    echo "==> Cleanup: starting ${CONTAINER_PREFIX}${LEADER_BEFORE} again..."
    docker start "${CONTAINER_PREFIX}${LEADER_BEFORE}" > /dev/null 2>&1 || true
  fi
  if [ -n "$TABLE_CREATED" ]; then
    run_sql "$WRITE_PORT" "$POSTGRES_USER" "$POSTGRES_PASSWORD" \
      "DROP TABLE IF EXISTS failover_check" > /dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- pre-flight ------------------------------------------------------------

echo "==> Checking cluster is healthy before starting..."
if ! CLUSTER=$(cluster_json); then
  echo "ERROR: could not reach any node's REST API - is the cluster up? (make up / make status)" >&2
  exit 1
fi

LEADER_BEFORE=$(member_with_role "$CLUSTER" leader)
SYNC_BEFORE=$(member_with_role "$CLUSTER" sync_standby)

if [ -z "$LEADER_BEFORE" ]; then
  echo "ERROR: no current leader found - cluster is not healthy, aborting" >&2
  exit 1
fi
echo "    Current leader:       $LEADER_BEFORE"
echo "    Current sync standby: ${SYNC_BEFORE:-<none>}"
if [ -z "$SYNC_BEFORE" ]; then
  echo "ERROR: no synchronous standby yet - synchronous_mode has not converged." >&2
  echo "       Without it this test cannot confirm the zero-data-loss promotion." >&2
  echo "       Wait a few seconds (make status) and re-run." >&2
  exit 1
fi

ADDR_BEFORE=$(container_ip "$LEADER_BEFORE")

# The test table is created by the admin role, so the default privileges set
# up in post_bootstrap.sh (SELECT for analytics_readonly, INSERT/UPDATE for
# etl_writer) apply to it automatically.
if ! out=$(run_sql "$WRITE_PORT" "$POSTGRES_USER" "$POSTGRES_PASSWORD" \
     "DROP TABLE IF EXISTS failover_check; CREATE TABLE failover_check (id serial PRIMARY KEY, note text)"); then
  echo "ERROR: could not create the test table through the write endpoint:" >&2
  echo "$out" >&2
  exit 1
fi
TABLE_CREATED=1

echo "    Baseline:"
expect_ok "write endpoint reaches the current primary ($LEADER_BEFORE)" \
  "$WRITE_PORT" etl_writer "$ETL_WRITER_PASSWORD" "$WHO_SQL" "primary|$ADDR_BEFORE"
expect_ok "read-only endpoint reaches a replica" \
  "$READ_PORT" analytics_readonly "$ANALYTICS_READONLY_PASSWORD" \
  "SELECT pg_is_in_recovery()" "t"
if [ "$FAILURES" -ne 0 ]; then
  echo "ERROR: baseline checks failed - fix the stack first (make access-test)" >&2
  exit 1
fi

# --- kill the leader -------------------------------------------------------

echo ""
echo "==> Killing the leader container: ${CONTAINER_PREFIX}${LEADER_BEFORE}"
START_TIME=$(date +%s)
docker kill "${CONTAINER_PREFIX}${LEADER_BEFORE}" > /dev/null

# --- 1. Patroni: poll for a new leader --------------------------------------

echo "==> Waiting for Patroni to elect a new leader..."
NEW_LEADER=""
ELAPSED=0
while [ "$ELAPSED" -lt "$LEADER_TIMEOUT" ]; do
  sleep "$POLL_INTERVAL"
  ELAPSED=$(( $(date +%s) - START_TIME ))
  candidate=$(current_leader 2>/dev/null || true)
  if [ -n "$candidate" ] && [ "$candidate" != "$LEADER_BEFORE" ]; then
    NEW_LEADER="$candidate"
    break
  fi
done
PATRONI_TIME=$(( $(date +%s) - START_TIME ))

if [ -z "$NEW_LEADER" ]; then
  echo ""
  echo "==================== RESULTS ===================="
  echo "FAILED: no new leader elected within ${LEADER_TIMEOUT}s"
  echo "==================================================="
  exit 1
fi
echo "    New leader visible in Patroni after ${PATRONI_TIME}s: $NEW_LEADER"

# --- 2. HAProxy: write endpoint follows the new primary ------------------------

ADDR_NEW=$(container_ip "$NEW_LEADER")
echo "==> Waiting for the write endpoint to reach $NEW_LEADER ($ADDR_NEW)..."
WRITE_TIME=""
while [ $(( $(date +%s) - START_TIME )) -lt "$TIMEOUT_SECONDS" ]; do
  who=$(run_sql "$WRITE_PORT" etl_writer "$ETL_WRITER_PASSWORD" "$WHO_SQL" 2>/dev/null || true)
  if [ "$who" = "primary|$ADDR_NEW" ]; then
    WRITE_TIME=$(( $(date +%s) - START_TIME ))
    break
  fi
  sleep "$POLL_INTERVAL"
done

# --- checks while the old primary is still down ------------------------------

echo ""
echo "--- Checks right after failover (old primary still down) ---"

if [ "$NEW_LEADER" = "$SYNC_BEFORE" ]; then
  pass "the synchronous standby ($SYNC_BEFORE) was promoted, not the async replica"
else
  fail "promoted '$NEW_LEADER' but the synchronous standby was '$SYNC_BEFORE' (zero-data-loss guarantee not demonstrated)"
fi

if [ -n "$WRITE_TIME" ]; then
  pass "write endpoint reaches the new primary after ${WRITE_TIME}s (same connection string)"
else
  fail "write endpoint did not reach the new primary within ${TIMEOUT_SECONDS}s"
fi

# Fresh sessions, opened after the failover, with the unchanged settings.
expect_ok "fresh etl_writer session can INSERT via the write endpoint" \
  "$WRITE_PORT" etl_writer "$ETL_WRITER_PASSWORD" \
  "INSERT INTO failover_check (note) VALUES ('after-failover')"

SAMPLES=$(sample_endpoint "$READ_PORT" analytics_readonly "$ANALYTICS_READONLY_PASSWORD" 8)
OK_COUNT=$(echo "$SAMPLES" | grep -c '|' || true)
PRIMARY_HITS=$(echo "$SAMPLES" | grep -c '^primary|' || true)
OLD_HITS=$(echo "$SAMPLES" | grep -c "|${ADDR_BEFORE}\$" || true)
if [ "$OK_COUNT" -ge 1 ] && [ "$PRIMARY_HITS" -eq 0 ] && [ "$OLD_HITS" -eq 0 ]; then
  pass "read-only endpoint: $OK_COUNT/8 new connections served by replicas only (never the new primary, never the dead old one)"
else
  fail "read-only endpoint after failover: $OK_COUNT/8 succeeded, $PRIMARY_HITS landed on a primary, $OLD_HITS on the old primary"
fi

# Give the surviving replica a moment to replay the INSERT before reading.
sleep 2
expect_ok "fresh analytics_readonly session can SELECT via the read-only endpoint" \
  "$READ_PORT" analytics_readonly "$ANALYTICS_READONLY_PASSWORD" \
  "SELECT count(*) > 0 FROM failover_check WHERE note = 'after-failover'" "t"
expect_error "analytics_readonly still cannot write (replica => read-only)" \
  "read-only transaction" \
  "$READ_PORT" analytics_readonly "$ANALYTICS_READONLY_PASSWORD" \
  "INSERT INTO failover_check (note) VALUES ('nope')"

# --- 3. the old primary comes back --------------------------------------------

echo ""
echo "==> Restarting the old leader so it can rejoin as a replica..."
docker start "${CONTAINER_PREFIX}${LEADER_BEFORE}" > /dev/null
RESTART_TIME=$(date +%s)

REJOIN_TIME=""
while [ $(( $(date +%s) - RESTART_TIME )) -lt "$TIMEOUT_SECONDS" ]; do
  json=$(cluster_json 2>/dev/null || true)
  if [ -n "$json" ]; then
    role=$(member_field "$json" "$LEADER_BEFORE" role)
    state=$(member_field "$json" "$LEADER_BEFORE" state)
    if { [ "$role" = "replica" ] || [ "$role" = "sync_standby" ]; } && [ "$state" = "streaming" ]; then
      REJOIN_TIME=$(( $(date +%s) - START_TIME ))
      break
    fi
  fi
  sleep 2
done

POOL_TIME=""
if [ -n "$REJOIN_TIME" ]; then
  # A restarted container may get a different IP, so look it up now.
  ADDR_OLD_NEW=$(container_ip "$LEADER_BEFORE")
  POOL_START=$(date +%s)
  while [ $(( $(date +%s) - POOL_START )) -lt "$TIMEOUT_SECONDS" ]; do
    SAMPLES=$(sample_endpoint "$READ_PORT" analytics_readonly "$ANALYTICS_READONLY_PASSWORD" 6)
    if echo "$SAMPLES" | grep -q "^replica|${ADDR_OLD_NEW}\$"; then
      POOL_TIME=$(( $(date +%s) - START_TIME ))
      break
    fi
    sleep 1
  done
fi

echo ""
echo "--- Checks after the old primary rejoined ---"
if [ -n "$REJOIN_TIME" ]; then
  pass "old primary ($LEADER_BEFORE) rejoined as a streaming replica after ${REJOIN_TIME}s"
else
  fail "old primary ($LEADER_BEFORE) did not rejoin as a streaming replica within the timeout"
fi
if [ -n "$POOL_TIME" ]; then
  pass "read-only endpoint serves the former primary again after ${POOL_TIME}s"
else
  fail "read-only endpoint did not start serving the former primary within the timeout"
fi
expect_ok "write endpoint still on the new primary ($NEW_LEADER)" \
  "$WRITE_PORT" etl_writer "$ETL_WRITER_PASSWORD" "$WHO_SQL" "primary|$ADDR_NEW"

# --- results -----------------------------------------------------------------

echo ""
echo "==================== RESULTS ===================="
echo "Old leader:            $LEADER_BEFORE (killed)"
echo "New leader:            $NEW_LEADER"
echo "Sync standby before:   $SYNC_BEFORE"
echo "Failover time:         ${PATRONI_TIME}s (container kill -> new leader visible in Patroni)"
echo "Write downtime:        ${WRITE_TIME:-n/a}s (container kill -> write endpoint on the new primary)"
echo "Old primary rejoined:  ${REJOIN_TIME:-n/a}s (kill -> streaming replica)"
echo "Back in read pool:     ${POOL_TIME:-n/a}s (kill -> served by the read-only endpoint)"
echo "Resolution ~1s; the position inside Patroni's loop_wait window varies, so repeat the run."
echo ""
echo "Row for docs/failover-notes.md:"
echo "| $(date +%F) | $LEADER_BEFORE | $NEW_LEADER | ${PATRONI_TIME}s | ${WRITE_TIME:-n/a}s | ${REJOIN_TIME:-n/a}s | ${POOL_TIME:-n/a}s |"
echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "$FAILURES CHECK(S) FAILED"
fi
echo "==================================================="
[ "$FAILURES" -eq 0 ]
