#!/bin/bash
# tests/migrate_test.sh
#
# Verifies the Sqitch migrations in db/migrations/ on the running cluster
# (see ADR 0004 for how Sqitch connects). Four parts:
#
#   1. Baseline equals the original schema. On two scratch databases: one built
#      from db/schema/001_initial_schema.sql, one from the baseline Sqitch
#      changes (up to and including `indexes`). The schemas must be identical
#      (pg_dump --schema-only). Then `sqitch revert` must leave nothing behind
#      and a fresh deploy must give the same schema again.
#   2. `make migrate` on the real database, through the session-mode alias:
#      the first run deploys, the second is a no-op, `verify` and `status` pass.
#   3. Default privileges on what the changes created: etl_writer can INSERT and
#      UPDATE but not DELETE, analytics_readonly can SELECT, the Sqitch registry
#      is not visible to either.
#   4. The same after a real `patronictl switchover`: `deploy` still reaches the
#      new primary and is a no-op, with unchanged settings.
#
# Part 1 uses scratch databases that are removed on exit. Parts 2-4 work on the
# real database: part 2 leaves the baseline deployed, which is its normal state
# after `make migrate`. Like access_patterns_test.sh, part 4 changes the leader.
#
# Sqitch runs as the `sqitch` service of docker-compose.yml, exactly like
# `make migrate`. Scratch databases are not known to PgBouncer, so part 1 points
# Sqitch straight at the current primary (port 5432); everything else goes
# through HAProxy and the alias.
#
# Usage: run from anywhere with the cluster up and healthy:
#   bash tests/migrate_test.sh
#
# Environment override:
#   MIGRATE_TEST_TIMEOUT   seconds allowed for the switchover wait (default 90)
#
# Prerequisites: docker (Compose v2), curl, python3, a populated .env, and the
# PgBouncer alias from ADR 0004 (checked below).
set -uo pipefail

# Git Bash (MSYS) on Windows rewrites arguments that look like unix paths
# before docker sees them. Harmless on Linux/macOS/WSL.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/docker-compose"

if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "ERROR: $REPO_ROOT/.env not found (cp .env.example .env)" >&2
  exit 1
fi

# Read the few values this test needs straight from .env, WITHOUT sourcing or
# exporting it. Unlike the other tests, this one runs `docker compose`, and
# Compose gives environment variables priority over --env-file: sourcing .env
# in bash would turn DATA_DIR=D:\DB\pg-pitch into D:DBpg-pitch (the shell eats
# the backslashes) and Compose could then not even load the project.
env_value() {
  local line value
  line=$(grep -E "^[[:space:]]*$1=" "$REPO_ROOT/.env" | tail -n 1 || true)
  value=${line#*=}
  value=${value%$'\r'}
  value=${value%\"}
  value=${value#\"}
  value=${value%\'}
  value=${value#\'}
  if [ -z "$value" ]; then printf '%s' "$2"; else printf '%s' "$value"; fi
}
POSTGRES_DB="$(env_value POSTGRES_DB postgres_pitch)"
POSTGRES_USER="$(env_value POSTGRES_USER postgres_pitch_admin)"
POSTGRES_PASSWORD="$(env_value POSTGRES_PASSWORD "")"

DB="$POSTGRES_DB"
ALIAS_DB="${MIGRATIONS_DB:-postgres_pitch_migrations}"
NODES=("postgresql0" "postgresql1" "postgresql2")
CONTAINER_PREFIX="postgres-pitch-"
WRITE_PORT=5000
TIMEOUT_SECONDS="${MIGRATE_TEST_TIMEOUT:-90}"
BASELINE_LAST_CHANGE="indexes"
SCRATCH_REF="migrate_test_ref"
SCRATCH_SQITCH="migrate_test_sqitch"

FAILURES=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
info() { echo "  INFO  $1"; }

# helpers

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

# run_sql <port> <user> <password> <sql> [database] -> output; psql's exit code
run_sql() {
  local port="$1" user="$2" password="$3" sql="$4" dbname="${5:-$DB}" c
  c=$(exec_container) || { echo "no running cluster container"; return 99; }
  docker exec -e PGPASSWORD="$password" "$c" \
    psql -h haproxy -p "$port" -U "$user" -d "$dbname" -tAqX -v ON_ERROR_STOP=1 -c "$sql" 2>&1
}

# Sqitch as the compose service, like `make migrate`. Scratch databases are not
# known to PgBouncer, so sq_direct connects straight to a node's PostgreSQL.
sq() {
  (cd "$COMPOSE_DIR" && docker compose --env-file ../.env run --rm -T sqitch "$@") 2>&1
}
sq_direct() {
  local host="$1"
  shift
  (cd "$COMPOSE_DIR" && docker compose --env-file ../.env run --rm -T \
    -e PGHOST="$host" -e PGPORT=5432 sqitch "$@") 2>&1
}

# Runs on the current primary through its local socket (no password needed).
leader_psql() {
  docker exec "${CONTAINER_PREFIX}${LEADER}" psql -U "$POSTGRES_USER" -d postgres -tAqX -v ON_ERROR_STOP=1 "$@" 2>&1
}

dump_schema() {
  # dump_schema <database> [-N sqitch]  (random \restrict tokens removed)
  local dbname="$1"
  shift
  docker exec "${CONTAINER_PREFIX}${LEADER}" pg_dump -s --no-owner --no-privileges "$@" \
    -U "$POSTGRES_USER" "$dbname" 2>/dev/null | grep -v -E '^\\(un)?restrict '
}

TMP=""
LEADER=""
SCRATCH_CREATED=""

drop_scratch() {
  [ -n "$SCRATCH_CREATED" ] && [ -n "$LEADER" ] || return 0
  leader_psql -c "DROP DATABASE IF EXISTS ${SCRATCH_REF}" -c "DROP DATABASE IF EXISTS ${SCRATCH_SQITCH}" >/dev/null 2>&1 || true
  SCRATCH_CREATED=""
}

cleanup() {
  drop_scratch
  [ -n "$TMP" ] && rm -rf "$TMP"
}
trap cleanup EXIT

# pre-flight

echo "==> Pre-flight"
if ! CLUSTER=$(cluster_json); then
  echo "ERROR: could not reach any node's REST API - is the cluster up? (make up / make status)" >&2
  exit 1
fi
LEADER=$(member_with_role "$CLUSTER" leader)
CANDIDATE=$(member_with_role "$CLUSTER" sync_standby)
if [ -z "$LEADER" ] || [ -z "$CANDIDATE" ]; then
  echo "ERROR: need a leader and a synchronous standby (got '${LEADER}' / '${CANDIDATE}'); see make status" >&2
  exit 1
fi
echo "    leader: $LEADER   sync standby: $CANDIDATE"

out=$(run_sql "$WRITE_PORT" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "SELECT current_database()" "$ALIAS_DB"); rc=$?
if [ $rc -ne 0 ]; then
  echo "ERROR: the PgBouncer alias '${ALIAS_DB}' does not answer on :${WRITE_PORT}: $(echo "$out" | head -1)" >&2
  echo "       It is added in the three pgbouncer*.ini (see ADR 0004); restart the poolers after adding it." >&2
  exit 1
fi
SQ_CHECK=$(sq --version); rc=$?
if [ $rc -ne 0 ]; then
  echo "ERROR: the sqitch service does not start (exit code $rc). Last output of Docker Compose:" >&2
  echo "$SQ_CHECK" | tail -n 8 | sed 's/^/       /' >&2
  echo "       Check the 'sqitch' service in docker-compose.yml and that Docker can pull the image:" >&2
  echo "         cd docker-compose && docker compose --env-file ../.env run --rm -T sqitch --version" >&2
  exit 1
fi
# Compose prints its own progress lines first; pick the one that names Sqitch.
SQITCH_VERSION=$(echo "$SQ_CHECK" | grep -m1 "App::Sqitch" || echo "$SQ_CHECK" | tail -n 1)
echo "    sqitch: ${SQITCH_VERSION}"
TMP=$(mktemp -d)

# 1. the baseline equals the original schema

echo ""
echo "--- 1. baseline changes reproduce db/schema/001_initial_schema.sql ---"
leader_psql -c "DROP DATABASE IF EXISTS ${SCRATCH_REF}" -c "DROP DATABASE IF EXISTS ${SCRATCH_SQITCH}" \
  -c "CREATE DATABASE ${SCRATCH_REF}" -c "CREATE DATABASE ${SCRATCH_SQITCH}" >/dev/null && SCRATCH_CREATED=1
if [ -z "$SCRATCH_CREATED" ]; then
  fail "could not create the scratch databases on the primary"
else
  if docker exec -i "${CONTAINER_PREFIX}${LEADER}" psql -U "$POSTGRES_USER" -d "$SCRATCH_REF" -q -v ON_ERROR_STOP=1 \
       < "$REPO_ROOT/db/schema/001_initial_schema.sql" >/dev/null 2>&1; then
    pass "001_initial_schema.sql applied to the reference database"
  else
    fail "001_initial_schema.sql did not apply to the reference database"
  fi

  OUT=$(sq_direct "$LEADER" deploy --to "$BASELINE_LAST_CHANGE" "db:pg:${SCRATCH_SQITCH}"); rc=$?
  if [ $rc -eq 0 ]; then pass "baseline changes deployed (up to '${BASELINE_LAST_CHANGE}')"; else fail "baseline deploy failed: $(echo "$OUT" | tail -n 2 | tr '\n' ' ')"; fi

  OUT=$(sq_direct "$LEADER" verify "db:pg:${SCRATCH_SQITCH}"); rc=$?
  if [ $rc -eq 0 ]; then pass "sqitch verify passes for every baseline change"; else fail "sqitch verify failed: $(echo "$OUT" | tail -n 3 | tr '\n' ' ')"; fi

  dump_schema "$SCRATCH_REF" > "$TMP/ref.sql"
  dump_schema "$SCRATCH_SQITCH" -N sqitch > "$TMP/sqitch.sql"
  if [ -s "$TMP/ref.sql" ] && [ "$(wc -l < "$TMP/ref.sql")" -gt 100 ] && diff -q "$TMP/ref.sql" "$TMP/sqitch.sql" >/dev/null; then
    pass "schema is identical to 001_initial_schema.sql ($(wc -l < "$TMP/ref.sql") lines of pg_dump --schema-only)"
  else
    fail "schema differs from 001_initial_schema.sql (or a dump is empty): $(diff "$TMP/ref.sql" "$TMP/sqitch.sql" | head -5 | tr '\n' ' ')"
  fi

  OUT=$(sq_direct "$LEADER" revert -y "db:pg:${SCRATCH_SQITCH}"); rc=$?
  LEFT=$(leader_psql -d "$SCRATCH_SQITCH" -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public'")
  if [ $rc -eq 0 ] && [ "$LEFT" = "0" ]; then
    pass "sqitch revert removed everything (0 objects left in public)"
  else
    fail "sqitch revert left ${LEFT:-?} object(s) in public (rc=$rc: $(echo "$OUT" | tail -n 1))"
  fi

  OUT=$(sq_direct "$LEADER" deploy --to "$BASELINE_LAST_CHANGE" "db:pg:${SCRATCH_SQITCH}"); rc=$?
  dump_schema "$SCRATCH_SQITCH" -N sqitch > "$TMP/sqitch2.sql"
  if [ $rc -eq 0 ] && diff -q "$TMP/ref.sql" "$TMP/sqitch2.sql" >/dev/null; then
    pass "a fresh deploy after the revert gives the same schema again"
  else
    fail "deploy after the revert failed or the schema differs (rc=$rc)"
  fi
fi
drop_scratch

# 2. make migrate on the real database

echo ""
echo "--- 2. make migrate on the real database through the alias ---"
OUT=$(sq deploy); rc=$?
if [ $rc -eq 0 ]; then
  pass "deploy through ${ALIAS_DB} succeeded"
else
  fail "deploy failed: $(echo "$OUT" | grep -v '^ *$' | tail -n 4 | tr '\n' ' ' | cut -c1-260)"
  if echo "$OUT" | grep -qi "already exists"; then
    info "The database already has the schema from the old 'make schema' but no Sqitch registry."
    info "Either start from scratch (make reset, make up, make migrate) or adopt it:"
    info "  docker compose --env-file ../.env run --rm sqitch deploy --log-only"
  fi
fi

OUT=$(sq deploy); rc=$?
if [ $rc -eq 0 ] && echo "$OUT" | grep -qi "nothing to deploy"; then
  pass "a second deploy is a no-op (nothing to deploy)"
else
  fail "a second deploy was not a no-op (rc=$rc: $(echo "$OUT" | tail -n 1))"
fi
OUT=$(sq verify); rc=$?
if [ $rc -eq 0 ]; then pass "sqitch verify passes on the real database"; else fail "sqitch verify failed: $(echo "$OUT" | tail -n 3 | tr '\n' ' ')"; fi
OUT=$(sq status); rc=$?
if [ $rc -eq 0 ]; then pass "sqitch status works"; else fail "sqitch status failed: $(echo "$OUT" | tail -n 1)"; fi

# 3. default privileges

echo ""
echo "--- 3. default privileges on what the changes created ---"
PRIV_SQL="SELECT
  has_table_privilege('etl_writer', 'public.countries', 'INSERT') || ',' ||
  has_table_privilege('etl_writer', 'public.countries', 'UPDATE') || ',' ||
  has_table_privilege('etl_writer', 'public.countries', 'DELETE') || ',' ||
  has_table_privilege('etl_writer', 'public.matches_2025', 'INSERT') || ',' ||
  has_sequence_privilege('etl_writer', 'public.countries_id_seq', 'USAGE') || ',' ||
  has_table_privilege('analytics_readonly', 'public.countries', 'SELECT') || ',' ||
  has_table_privilege('analytics_readonly', 'public.countries', 'INSERT') || ',' ||
  has_table_privilege('analytics_readonly', 'public.standings', 'SELECT') || ',' ||
  has_schema_privilege('etl_writer', 'sqitch', 'USAGE') || ',' ||
  has_schema_privilege('analytics_readonly', 'sqitch', 'USAGE')"
OUT=$(run_sql "$WRITE_PORT" "$POSTGRES_USER" "$POSTGRES_PASSWORD" "$PRIV_SQL")
EXPECTED="true,true,false,true,true,true,false,true,false,false"
if [ "$OUT" = "$EXPECTED" ]; then
  pass "etl_writer: INSERT/UPDATE yes, DELETE no (also on a partition, and USAGE on the sequence); analytics_readonly: SELECT only (also on the materialized view); neither sees the Sqitch registry"
else
  fail "unexpected privileges: got '${OUT}', expected '${EXPECTED}' (etl INSERT,UPDATE,DELETE,partition INSERT,sequence USAGE, analytics SELECT,INSERT,matview SELECT, registry etl,analytics)"
fi

# 4. the same after a switchover

echo ""
echo "--- 4. deploy after a switchover (same settings) ---"
echo "==> Switchover: $LEADER -> $CANDIDATE"
if ! docker exec "${CONTAINER_PREFIX}${LEADER}" patronictl -c /etc/patroni.yml switchover \
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
    pass "the alias reaches the new primary ($CANDIDATE) after ${CONVERGED}s"
    OUT=$(sq deploy); rc=$?
    if [ $rc -eq 0 ] && echo "$OUT" | grep -qi "nothing to deploy"; then
      pass "deploy on the new primary is a no-op, no setting changed"
    else
      fail "deploy after the switchover failed (rc=$rc: $(echo "$OUT" | tail -n 2 | tr '\n' ' '))"
    fi
    OUT=$(sq verify); rc=$?
    if [ $rc -eq 0 ]; then pass "sqitch verify passes on the new primary"; else fail "verify after the switchover failed: $(echo "$OUT" | tail -n 2 | tr '\n' ' ')"; fi
  else
    fail "the alias did not reach a primary within ${TIMEOUT_SECONDS}s after the switchover"
  fi
fi

# results

echo ""
echo "==================== RESULTS ===================="
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
else
  echo "$FAILURES CHECK(S) FAILED"
fi
echo "==================================================="
[ "$FAILURES" -eq 0 ]
