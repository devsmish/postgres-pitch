#!/bin/bash
# tests/access_patterns_test.sh
#
# End-to-end check of the client-facing layer (HAProxy -> PgBouncer ->
# PostgreSQL) and the demo roles, including behavior across a switchover:
#
#   - write endpoint (:5000) always lands on a primary
#     (pg_is_in_recovery() = false)
#   - read-only endpoint (:5001) always lands on a replica
#     (pg_is_in_recovery() = true)
#   - etl_writer can write via the write endpoint
#   - analytics_readonly can read via the read-only endpoint, and cannot
#     write — via the read-only endpoint it fails because it landed on a
#     replica (routing), via the write endpoint it fails on GRANTs (roles)
#   - after `patronictl switchover`, the same roles keep working through
#     the same endpoints with the same connection settings — only the
#     node behind them changes
#
# All queries run through `docker exec` inside one of the cluster's own
# containers (on the compose network, where `haproxy` resolves), so no
# psql needs to be installed on the host.
#
# Usage: run from anywhere with the cluster up and healthy:
#   bash tests/access_patterns_test.sh
#
# Prerequisites: docker, curl, python3 (JSON parsing, same as
# failover_test.sh), and a populated .env in the repo root.
set -uo pipefail

# Git Bash (MSYS) on Windows rewrites arguments that look like unix paths
# (e.g. `-c /etc/patroni.yml` becomes `C:/Program Files/Git/etc/patroni.yml`)
# before docker ever sees them. Those paths are meant for the container, so
# disable the conversion. Harmless on Linux/macOS/WSL.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load .env, stripping CRs in case the file was saved with Windows line
# endings — a trailing \r would silently end up inside every password.
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
declare -A REST_PORTS=( [postgresql0]=8009 [postgresql1]=8010 [postgresql2]=8011 )
CONTAINER_PREFIX="postgres-pitch-"
WRITE_PORT=5000
READ_PORT=5001
TIMEOUT_SECONDS=90

FAILURES=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }

# --- helpers -----------------------------------------------------------

exec_container() {
  # Any running cluster container works as the "client" — pick the first.
  for n in "${NODES[@]}"; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}${n}" 2>/dev/null)" = "true" ]; then
      echo "${CONTAINER_PREFIX}${n}"
      return 0
    fi
  done
  return 1
}

# run_sql <port> <user> <password> <sql>  -> prints stdout+stderr, returns psql's exit code
run_sql() {
  local port="$1" user="$2" password="$3" sql="$4" c
  c=$(exec_container) || { echo "no running cluster container"; return 99; }
  docker exec -e PGPASSWORD="$password" "$c" \
    psql -h haproxy -p "$port" -U "$user" -d "$DB" -tAqX -v ON_ERROR_STOP=1 -c "$sql" 2>&1
}

cluster_json() {
  for n in "${NODES[@]}"; do
    if out=$(curl -sf "http://localhost:${REST_PORTS[$n]}/cluster" 2>/dev/null); then
      echo "$out"; return 0
    fi
  done
  return 1
}

member_with_role() {
  python3 -c "
import json, sys
for m in json.loads(sys.argv[1]).get('members', []):
    if m.get('role') == sys.argv[2]:
        print(m.get('name', '')); break
" "$1" "$2"
}

# expect_ok <label> <port> <user> <password> <sql> [expected-output]
expect_ok() {
  local label="$1" out rc
  out=$(run_sql "$2" "$3" "$4" "$5"); rc=$?
  if [ $rc -eq 0 ] && { [ -z "${6:-}" ] || [ "$out" = "$6" ]; }; then
    pass "$label"
  else
    fail "$label  (rc=$rc, got: $(echo "$out" | head -1))"
  fi
}

# expect_error <label> <expected-substring> <port> <user> <password> <sql>
expect_error() {
  local label="$1" needle="$2" out rc
  out=$(run_sql "$3" "$4" "$5" "$6"); rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -qi "$needle"; then
    pass "$label"
  else
    fail "$label  (rc=$rc, expected error containing '$needle', got: $(echo "$out" | head -1))"
  fi
}

# One full round of checks, run before and after the switchover.
run_checks() {
  local phase="$1"
  echo ""
  echo "--- $phase ---"
  expect_ok    "write endpoint reaches a primary (pg_is_in_recovery = f)" \
    $WRITE_PORT etl_writer "$ETL_WRITER_PASSWORD" "SELECT pg_is_in_recovery()" "f"
  expect_ok    "read-only endpoint reaches a replica (pg_is_in_recovery = t)" \
    $READ_PORT analytics_readonly "$ANALYTICS_READONLY_PASSWORD" "SELECT pg_is_in_recovery()" "t"
  expect_ok    "etl_writer can INSERT via the write endpoint" \
    $WRITE_PORT etl_writer "$ETL_WRITER_PASSWORD" \
    "INSERT INTO access_check (note) VALUES ('$phase')"
  sleep 2   # let the (possibly async) replica catch up before reading
  expect_ok    "analytics_readonly can SELECT via the read-only endpoint" \
    $READ_PORT analytics_readonly "$ANALYTICS_READONLY_PASSWORD" \
    "SELECT count(*) > 0 FROM access_check WHERE note = '$phase'" "t"
  expect_error "analytics_readonly cannot write via the read-only endpoint (replica => read-only)" \
    "read-only transaction" \
    $READ_PORT analytics_readonly "$ANALYTICS_READONLY_PASSWORD" \
    "INSERT INTO access_check (note) VALUES ('nope')"
  expect_error "analytics_readonly cannot write via the write endpoint (no INSERT grant)" \
    "permission denied" \
    $WRITE_PORT analytics_readonly "$ANALYTICS_READONLY_PASSWORD" \
    "INSERT INTO access_check (note) VALUES ('nope')"
  expect_error "etl_writer cannot write via the read-only endpoint (replica => read-only)" \
    "read-only transaction" \
    $READ_PORT etl_writer "$ETL_WRITER_PASSWORD" \
    "INSERT INTO access_check (note) VALUES ('nope')"
}

cleanup() {
  run_sql $WRITE_PORT "$POSTGRES_USER" "$POSTGRES_PASSWORD" \
    "DROP TABLE IF EXISTS access_check" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# --- pre-flight ------------------------------------------------------------

echo "==> Pre-flight"
CLUSTER=$(cluster_json) || { echo "ERROR: cluster not reachable — is it up? (make status)" >&2; exit 1; }
LEADER_BEFORE=$(member_with_role "$CLUSTER" leader)
SYNC_BEFORE=$(member_with_role "$CLUSTER" sync_standby)
echo "    leader: ${LEADER_BEFORE:-<none>}   sync standby: ${SYNC_BEFORE:-<none>}"
if [ -z "$LEADER_BEFORE" ] || [ -z "$SYNC_BEFORE" ]; then
  echo "ERROR: need a leader and a sync standby to run the switchover part" >&2
  exit 1
fi

# The test table is created by the admin role, so the default privileges
# set up in post_bootstrap.sh (SELECT for analytics_readonly, INSERT/UPDATE
# + sequence usage for etl_writer) apply to it automatically.
out=$(run_sql $WRITE_PORT "$POSTGRES_USER" "$POSTGRES_PASSWORD" \
  "DROP TABLE IF EXISTS access_check; CREATE TABLE access_check (id serial PRIMARY KEY, note text)") \
  || { echo "ERROR: could not create test table through the write endpoint:"; echo "$out"; exit 1; }

ADDR_BEFORE=$(run_sql $WRITE_PORT etl_writer "$ETL_WRITER_PASSWORD" "SELECT inet_server_addr()")

# --- before switchover -----------------------------------------------------

run_checks "before-switchover"

# --- switchover ---------------------------------------------------------------

echo ""
echo "==> Switchover: $LEADER_BEFORE -> $SYNC_BEFORE"
START=$(date +%s)
if ! docker exec "${CONTAINER_PREFIX}${LEADER_BEFORE}" \
     patronictl -c /etc/patroni.yml switchover \
     --leader "$LEADER_BEFORE" --candidate "$SYNC_BEFORE" --force; then
  echo "ERROR: patronictl switchover failed (see output above)" >&2
  exit 1
fi

echo "==> Waiting for the write endpoint to follow the new primary..."
CONVERGED=""
while [ $(( $(date +%s) - START )) -lt $TIMEOUT_SECONDS ]; do
  sleep 2
  addr=$(run_sql $WRITE_PORT etl_writer "$ETL_WRITER_PASSWORD" "SELECT inet_server_addr()" 2>/dev/null || true)
  rec=$(run_sql $WRITE_PORT etl_writer "$ETL_WRITER_PASSWORD" "SELECT pg_is_in_recovery()" 2>/dev/null || true)
  if [ "$rec" = "f" ] && [ -n "$addr" ] && [ "$addr" != "$ADDR_BEFORE" ]; then
    CONVERGED=$(( $(date +%s) - START )); break
  fi
done

if [ -z "$CONVERGED" ]; then
  fail "write endpoint did not move to the new primary within ${TIMEOUT_SECONDS}s"
else
  pass "write endpoint moved to the new primary after ${CONVERGED}s (no client reconfiguration)"
fi

# --- after switchover ------------------------------------------------------

# The read-only endpoint needs healthy replicas again - the old primary
# rejoins as one, and HAProxy (rise 2 x inter 3s) plus PgBouncer's cached
# login errors need a moment to settle. Mirror the write-endpoint wait above:
# poll until the read-only endpoint answers correctly several times in a row
# (6 = two full round-robin cycles over 3 backends), so one lucky connection
# to a healthy node cannot hide a backend that is still starting up.
echo "==> Waiting for the read-only endpoint to serve replicas again..."
READ_START=$(date +%s)
READ_STREAK=0
READ_CONVERGED=""
while [ $(( $(date +%s) - READ_START )) -lt $TIMEOUT_SECONDS ]; do
  rec=$(run_sql $READ_PORT analytics_readonly "$ANALYTICS_READONLY_PASSWORD" "SELECT pg_is_in_recovery()" 2>/dev/null || true)
  if [ "$rec" = "t" ]; then
    READ_STREAK=$((READ_STREAK + 1))
  else
    READ_STREAK=0
  fi
  if [ "$READ_STREAK" -ge 6 ]; then
    READ_CONVERGED=$(( $(date +%s) - START )); break
  fi
  sleep 1
done

if [ -z "$READ_CONVERGED" ]; then
  fail "read-only endpoint did not stabilise on replicas within ${TIMEOUT_SECONDS}s"
else
  pass "read-only endpoint serving replicas again after ${READ_CONVERGED}s (no client reconfiguration)"
fi
run_checks "after-switchover"

echo ""
echo "==================== RESULT ===================="
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "$FAILURES CHECK(S) FAILED"
fi
echo "================================================"
[ "$FAILURES" -eq 0 ]
