#!/bin/bash
# tests/migration_path_test.sh
#
# Verifies the migration path decided in ADR 0004 on the running cluster:
# Sqitch, run from its official Docker image, reaches the CURRENT primary
# through HAProxy (:5000) using the session-mode PgBouncer alias
# `postgres_pitch_migrations`, and keeps doing so after a switchover.
#
# What it checks:
#   1. deploy / status / verify / revert / deploy through the alias
#   2. the Sqitch registry (schema `sqitch`) is not readable by etl_writer or
#      analytics_readonly, while tables created by a change get the project's
#      default privileges
#   3. the same revert / deploy / verify cycle after a real
#      `patronictl switchover`, with the same connection settings
#   4. for contrast (information only, never a failure): the same cycle through
#      the normal transaction-mode database, and whether it leaves Sqitch's
#      session advisory lock behind on the primary
#
# It creates a throwaway Sqitch project in a temporary directory and two
# throwaway objects in the application database (the `sqitch` registry schema
# and `public.spike_probe`); everything is removed on exit. Like
# access_patterns_test.sh it performs a switchover, so the leader changes.
#
# All SQL runs through `docker exec` inside one of the cluster's own
# containers (on the compose network, where `haproxy` resolves); Sqitch runs in
# its own container attached to the same network, so nothing is installed on
# the host.
#
# Prerequisite (once): the alias line in each pgbouncer*.ini, see ADR 0004.
# The script checks for it and prints the exact lines if they are missing.
#
# Usage: run from anywhere with the cluster up and healthy:
#   bash tests/migration_path_test.sh
#
# Environment overrides:
#   SQITCH_IMAGE             Docker image (default sqitch/sqitch:latest)
#   MIGRATIONS_DB            alias name (default postgres_pitch_migrations)
#   MIGRATION_TEST_TIMEOUT   seconds allowed for each wait (default 90)
#
# Prerequisites: docker, curl, python3, and a populated .env in the repo root.
set -uo pipefail

# Git Bash (MSYS) on Windows rewrites arguments that look like unix paths
# before docker sees them. Harmless on Linux/macOS/WSL.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "ERROR: $REPO_ROOT/.env not found (cp .env.example .env)" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
source <(tr -d '\r' < "$REPO_ROOT/.env")
set +a

DB="${POSTGRES_DB:-postgres_pitch}"
ALIAS_DB="${MIGRATIONS_DB:-postgres_pitch_migrations}"
SQITCH_IMAGE="${SQITCH_IMAGE:-sqitch/sqitch:latest}"
NODES=("postgresql0" "postgresql1" "postgresql2")
CONTAINER_PREFIX="postgres-pitch-"
WRITE_PORT=5000
READ_PORT=5001
TIMEOUT_SECONDS="${MIGRATION_TEST_TIMEOUT:-90}"
SQITCH_LOCK_KEY=75474063   # the advisory lock Sqitch's PostgreSQL engine takes

FAILURES=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
info() { echo "  INFO  $1"; }

# helpers (same approach as the other tests)

rest_port() {
  case "$1" in
    postgresql0) echo 8009 ;;
    postgresql1) echo 8010 ;;
    postgresql2) echo 8011 ;;
    *) return 1 ;;
  esac
}

cluster_json() {
  local node out
  for node in "${NODES[@]}"; do
    if out=$(curl -sf --max-time 3 "http://localhost:$(rest_port "$node")/cluster" 2>/dev/null); then
      echo "$out"
      return 0
    fi
  done
  return 1
}

member_with_role() {
  python3 -c "
import json, sys
for m in json.loads(sys.argv[1]).get('members', []):
    if m.get('role') == sys.argv[2]:
        print(m.get('name', ''))
        break
" "$1" "$2"
}

exec_container() {
  local n
  for n in "${NODES[@]}"; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}${n}" 2>/dev/null)" = "true" ]; then
      echo "${CONTAINER_PREFIX}${n}"
      return 0
    fi
  done
  return 1
}

# run_sql <port> <user> <password> <sql> [database]  -> output; psql's exit code
run_sql() {
  local port="$1" user="$2" password="$3" sql="$4" dbname="${5:-$DB}" c
  c=$(exec_container) || { echo "no running cluster container"; return 99; }
  docker exec -e PGPASSWORD="$password" "$c" \
    psql -h haproxy -p "$port" -U "$user" -d "$dbname" -tAqX -v ON_ERROR_STOP=1 -c "$sql" 2>&1
}

expect_ok() {
  # expect_ok <label> <port> <user> <password> <sql>
  local label="$1" out rc
  out=$(run_sql "$2" "$3" "$4" "$5"); rc=$?
  if [ $rc -eq 0 ]; then pass "$label"; else fail "$label  (rc=$rc: $(echo "$out" | head -1))"; fi
}

expect_error() {
  # expect_error <label> <expected-substring> <port> <user> <password> <sql>
  local label="$1" needle="$2" out rc
  out=$(run_sql "$3" "$4" "$5" "$6"); rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -qi "$needle"; then
    pass "$label"
  else
    fail "$label  (rc=$rc, expected '$needle', got: $(echo "$out" | head -1))"
  fi
}

# Docker on Windows needs a Windows-style path for bind mounts; Git Bash's
# cygpath gives it, elsewhere the path is already right.
host_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

NET=""
WORK=""

# sq <sqitch args...>: run Sqitch in a container on the cluster network.
sq() {
  docker run --rm --network "$NET" -v "$(host_path "$WORK"):/repo" \
    -e SQITCH_FULLNAME="Migration path test" -e SQITCH_EMAIL="test@example.invalid" \
    -e PGPASSWORD="$POSTGRES_PASSWORD" "$SQITCH_IMAGE" "$@" 2>&1
}

LAST_OUT=""
step() {
  # step <label> <sqitch args...>: a failing command is a FAIL.
  local label="$1" rc
  shift
  LAST_OUT=$(sq "$@"); rc=$?
  if [ $rc -eq 0 ]; then
    pass "$label"
  else
    fail "$label  (rc=$rc: $(echo "$LAST_OUT" | tail -n 2 | tr '\n' ' ' | cut -c1-200))"
  fi
  return $rc
}

quiet_cycle() {
  # quiet_cycle <target>: the same five commands, but only counted (INFO use).
  local target="$1" cmd ok=0 bad=0
  for cmd in "deploy" "status" "verify" "revert -y" "deploy"; do
    # shellcheck disable=SC2086
    if sq $cmd "$target" >/dev/null 2>&1; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
  done
  echo "$ok $bad"
}

leaked_locks_on_primary() {
  local leader json
  json=$(cluster_json) || { echo "?"; return; }
  leader=$(member_with_role "$json" leader)
  docker exec "${CONTAINER_PREFIX}${leader}" psql -U "$POSTGRES_USER" -d "$DB" -Atc \
    "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND objid=${SQITCH_LOCK_KEY}" 2>/dev/null || echo "?"
}

release_leaked_locks() {
  local leader json
  json=$(cluster_json) || return 0
  leader=$(member_with_role "$json" leader)
  docker exec "${CONTAINER_PREFIX}${leader}" psql -U "$POSTGRES_USER" -d "$DB" -Atc \
    "SELECT pg_terminate_backend(pid) FROM pg_locks WHERE locktype='advisory' AND objid=${SQITCH_LOCK_KEY}" >/dev/null 2>&1 || true
}

T_ALIAS=""
T_NORMAL=""

cleanup() {
  if [ -n "$WORK" ] && [ -n "$NET" ]; then
    release_leaked_locks
    sq revert -y "$T_ALIAS" >/dev/null 2>&1 || true
    run_sql "$WRITE_PORT" "$POSTGRES_USER" "$POSTGRES_PASSWORD" \
      "DROP SCHEMA IF EXISTS sqitch CASCADE; DROP TABLE IF EXISTS public.spike_probe" "$ALIAS_DB" >/dev/null 2>&1 || true
  fi
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

write_project() {
  mkdir -p "$WORK/deploy" "$WORK/revert" "$WORK/verify"
  cat > "$WORK/sqitch.conf" <<'EOF'
[core]
	engine = pg
EOF
  cat > "$WORK/sqitch.plan" <<'EOF'
%syntax-version=1.0.0
%project=pitch_migration_path_test
%uri=https://github.com/devsmish/postgres-pitch

spike_probe 2026-01-01T00:00:00Z Migration path test <test@example.invalid> # Throwaway table
spike_probe_idx [spike_probe] 2026-01-01T00:00:00Z Migration path test <test@example.invalid> # Second change, second transaction
EOF
  printf -- '-- Deploy spike_probe\nBEGIN;\nCREATE TABLE public.spike_probe (id integer PRIMARY KEY, note text);\nCOMMIT;\n' > "$WORK/deploy/spike_probe.sql"
  printf -- '-- Revert spike_probe\nBEGIN;\nDROP TABLE public.spike_probe;\nCOMMIT;\n' > "$WORK/revert/spike_probe.sql"
  printf -- '-- Verify spike_probe\nSELECT id, note FROM public.spike_probe WHERE FALSE;\n' > "$WORK/verify/spike_probe.sql"
  printf -- '-- Deploy spike_probe_idx\nBEGIN;\nCREATE INDEX spike_probe_note_idx ON public.spike_probe (note);\nCOMMIT;\n' > "$WORK/deploy/spike_probe_idx.sql"
  printf -- '-- Revert spike_probe_idx\nBEGIN;\nDROP INDEX public.spike_probe_note_idx;\nCOMMIT;\n' > "$WORK/revert/spike_probe_idx.sql"
  printf -- "-- Verify spike_probe_idx\nSELECT 1/count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='spike_probe_note_idx';\n" > "$WORK/verify/spike_probe_idx.sql"
}

# pre-flight

echo "==> Pre-flight"
if ! CLUSTER=$(cluster_json); then
  echo "ERROR: could not reach any node's REST API - is the cluster up? (make up / make status)" >&2
  exit 1
fi
LEADER=$(member_with_role "$CLUSTER" leader)
CANDIDATE=$(member_with_role "$CLUSTER" sync_standby)
if [ -z "$LEADER" ] || [ -z "$CANDIDATE" ]; then
  echo "ERROR: need a leader and a synchronous standby (got '${LEADER}' / '${CANDIDATE}'); wait for the cluster to settle (make status)" >&2
  exit 1
fi
echo "    leader: $LEADER   sync standby: $CANDIDATE"

NET=$(docker inspect -f '{{range $name, $conf := .NetworkSettings.Networks}}{{$name}} {{end}}' "${CONTAINER_PREFIX}haproxy" 2>/dev/null | awk '{print $1}')
if [ -z "$NET" ]; then
  echo "ERROR: could not find the compose network (is ${CONTAINER_PREFIX}haproxy running?)" >&2
  exit 1
fi
echo "    network: $NET"

if ! docker image inspect "$SQITCH_IMAGE" >/dev/null 2>&1; then
  echo "    pulling $SQITCH_IMAGE ..."
  docker pull "$SQITCH_IMAGE" >/dev/null || { echo "ERROR: could not pull $SQITCH_IMAGE" >&2; exit 1; }
fi

out=$(run_sql "$WRITE_PORT" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "SELECT current_database()" "$ALIAS_DB"); rc=$?
if [ $rc -ne 0 ]; then
  echo "ERROR: cannot use the PgBouncer alias '${ALIAS_DB}' through :${WRITE_PORT}:" >&2
  echo "       $(echo "$out" | head -1)" >&2
  echo "       Add this line under 'postgres_pitch = ...' in [databases] of each file," >&2
  echo "       then restart the poolers (see ADR 0004):" >&2
  echo "         docker-compose/pgbouncer/pgbouncer0.ini: ${ALIAS_DB} = host=postgresql0 port=5432 dbname=${DB} pool_mode=session" >&2
  echo "         docker-compose/pgbouncer/pgbouncer1.ini: ${ALIAS_DB} = host=postgresql1 port=5432 dbname=${DB} pool_mode=session" >&2
  echo "         docker-compose/pgbouncer/pgbouncer2.ini: ${ALIAS_DB} = host=postgresql2 port=5432 dbname=${DB} pool_mode=session" >&2
  echo "         (cd docker-compose && docker compose --env-file ../.env restart pgbouncer0 pgbouncer1 pgbouncer2)" >&2
  exit 1
fi
echo "    alias '${ALIAS_DB}' answers (database: $out)"

T_ALIAS="db:pg://${POSTGRES_USER}@haproxy:${WRITE_PORT}/${ALIAS_DB}"
T_NORMAL="db:pg://${POSTGRES_USER}@haproxy:${WRITE_PORT}/${DB}"

WORK=$(mktemp -d)
write_project

SQITCH_VERSION=$(sq --version | head -1)
PGBOUNCER_VERSION=$(docker exec "${CONTAINER_PREFIX}pgbouncer0" pgbouncer --version 2>&1 | head -1)
echo "    sqitch: ${SQITCH_VERSION}   pgbouncer: ${PGBOUNCER_VERSION}"

# 1. the cycle through the alias

echo ""
echo "--- 1. deploy / status / verify / revert / deploy through the alias ---"
step "deploy" deploy "$T_ALIAS"
step "status" status "$T_ALIAS"
step "verify" verify "$T_ALIAS"
step "revert" revert -y "$T_ALIAS"
step "deploy again" deploy "$T_ALIAS"

# 2. registry and default privileges

echo ""
echo "--- 2. registry privacy and default privileges ---"
expect_error "etl_writer cannot read the Sqitch registry" "permission denied" \
  "$WRITE_PORT" etl_writer "$ETL_WRITER_PASSWORD" "SELECT count(*) FROM sqitch.changes"
expect_error "analytics_readonly cannot read the Sqitch registry" "permission denied" \
  "$READ_PORT" analytics_readonly "$ANALYTICS_READONLY_PASSWORD" "SELECT count(*) FROM sqitch.changes"
expect_ok "etl_writer can INSERT into the table a change created" \
  "$WRITE_PORT" etl_writer "$ETL_WRITER_PASSWORD" "INSERT INTO public.spike_probe VALUES (1, 'x')"
expect_error "etl_writer still cannot DELETE from it" "permission denied" \
  "$WRITE_PORT" etl_writer "$ETL_WRITER_PASSWORD" "DELETE FROM public.spike_probe"
READ_OK=""
for _ in 1 2 3 4 5 6 7 8; do
  if run_sql "$READ_PORT" analytics_readonly "$ANALYTICS_READONLY_PASSWORD" "SELECT count(*) FROM public.spike_probe" >/dev/null 2>&1; then
    READ_OK=1; break
  fi
  sleep 2
done
if [ -n "$READ_OK" ]; then
  pass "analytics_readonly can SELECT it through the read-only endpoint"
else
  fail "analytics_readonly could not SELECT the new table within 16s (replication or privileges)"
fi

# 3. the same after a switchover

echo ""
echo "--- 3. the same cycle after a switchover (same connection settings) ---"
echo "==> Switchover: $LEADER -> $CANDIDATE"
if ! docker exec "${CONTAINER_PREFIX}${LEADER}" \
     patronictl -c /etc/patroni.yml switchover \
     --leader "$LEADER" --candidate "$CANDIDATE" --force >/dev/null 2>&1; then
  fail "patronictl switchover failed"
else
  SW_START=$(date +%s)
  CONVERGED=""
  while [ $(( $(date +%s) - SW_START )) -lt "$TIMEOUT_SECONDS" ]; do
    sleep 2
    json=$(cluster_json 2>/dev/null || true)
    [ -z "$json" ] && continue
    [ "$(member_with_role "$json" leader)" = "$CANDIDATE" ] || continue
    rec=$(run_sql "$WRITE_PORT" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "SELECT pg_is_in_recovery()" "$ALIAS_DB" 2>/dev/null || true)
    if [ "$rec" = "f" ]; then CONVERGED=$(( $(date +%s) - SW_START )); break; fi
  done
  if [ -n "$CONVERGED" ]; then
    pass "the alias reaches the new primary ($CANDIDATE) after ${CONVERGED}s, no setting changed"
    step "revert" revert -y "$T_ALIAS"
    step "deploy" deploy "$T_ALIAS"
    step "verify" verify "$T_ALIAS"
    step "status" status "$T_ALIAS"
  else
    fail "the alias did not reach a primary within ${TIMEOUT_SECONDS}s after the switchover"
  fi
fi

# 4. for contrast: the normal transaction-mode database

echo ""
echo "--- 4. for contrast (information only): the normal transaction-mode database ---"
sq revert -y "$T_ALIAS" >/dev/null 2>&1 || true
read -r N_OK N_BAD <<<"$(quiet_cycle "$T_NORMAL")"
LOCKS=$(leaked_locks_on_primary)
info "through '${DB}' (transaction pooling): ${N_OK} of $((N_OK + N_BAD)) commands succeeded"
if [ "$LOCKS" = "?" ]; then
  info "could not read pg_locks on the primary"
elif [ "$LOCKS" -gt 0 ] 2>/dev/null; then
  info "Sqitch's advisory lock (${SQITCH_LOCK_KEY}) is STILL held on a pooled server connection after Sqitch exited: ${LOCKS} lock(s)"
else
  info "no advisory lock left behind in this quiet run"
fi
release_leaked_locks

# results

echo ""
echo "==================== RESULTS ===================="
echo "Rows for ADR 0004, part B:"
echo "| Versions | ${SQITCH_VERSION}; ${PGBOUNCER_VERSION}; network ${NET} |"
echo "| Cycle through :${WRITE_PORT} and the alias | $([ "$FAILURES" -eq 0 ] && echo "all checks passed" || echo "${FAILURES} check(s) failed, see above") |"
echo "| Normal transaction-mode database (information) | ${N_OK} of $((N_OK + N_BAD)) commands succeeded; advisory locks left on the primary: ${LOCKS} |"
echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "$FAILURES CHECK(S) FAILED"
fi
echo "==================================================="
[ "$FAILURES" -eq 0 ]
