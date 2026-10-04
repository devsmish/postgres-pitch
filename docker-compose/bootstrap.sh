#!/bin/bash
# docker-compose/bootstrap.sh
#
# One-command start of the full local stack (3x Patroni/PostgreSQL, etcd,
# PgBouncer, HAProxy). Unlike a bare `docker compose up -d`, it does not
# return as soon as the containers exist: it polls Patroni's REST API until
# the cluster is actually healthy, then checks that both HAProxy endpoints
# answer, and only then reports readiness.
#
# "Healthy" means (see evaluate_cluster below):
#   - all 3 members are registered in the DCS
#   - exactly one leader, in state `running`
#   - every other member is `streaming` from it
#   - at least one synchronous standby (synchronous_mode: true in patroni.yml)
#   - the write (:5000) and read-only (:5001) endpoints accept connections
#     through HAProxy -> PgBouncer
#
# Usage (from anywhere; `make up` calls this script):
#   bash docker-compose/bootstrap.sh
#
# Environment overrides:
#   BOOTSTRAP_TIMEOUT      seconds to wait for a healthy cluster after the
#                          containers are started (default 180; image build
#                          time is not counted)
#   REQUIRE_SYNC_STANDBY   "true" (default) or "false" - set to false if
#                          synchronous_mode is turned off in patroni.yml
#
# Exit codes: 0 = stack is up and healthy, 1 = failed (pre-flight problem,
# compose error, or the stack did not become healthy within the timeout),
# 130 = interrupted (containers keep running).
#
# Idempotent: running it against an already-running healthy stack just
# verifies it and prints the summary again.
#
# Prerequisites: docker (Compose v2), curl, python3 (JSON parsing, same as
# the scripts in tests/), and a populated .env in the repo root.
set -euo pipefail

# Git Bash (MSYS) on Windows rewrites arguments that look like unix paths
# before docker sees them. Harmless on Linux/macOS/WSL.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
CONTAINER_PREFIX="postgres-pitch-"
NODES=("postgresql0" "postgresql1" "postgresql2")
EXPECTED_MEMBERS=${#NODES[@]}
TIMEOUT_SECONDS="${BOOTSTRAP_TIMEOUT:-180}"
REQUIRE_SYNC_STANDBY="${REQUIRE_SYNC_STANDBY:-true}"
POLL_INTERVAL=3
WRITE_PORT=5000
READ_PORT=5001
STATS_PORT=8404

PY=""

# helpers

info() { echo "==> $*"; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

on_interrupt() {
  echo >&2
  echo "Interrupted. Containers keep running; re-run 'make up' to continue waiting." >&2
  exit 130
}
trap on_interrupt INT

# Patroni REST API host port for a node (see ports in docker-compose.yml).
rest_port() {
  case "$1" in
    postgresql0) echo 8009 ;;
    postgresql1) echo 8010 ;;
    postgresql2) echo 8011 ;;
    *) return 1 ;;
  esac
}

# env_value KEY DEFAULT - read one value from .env without sourcing it
# (passwords may contain characters that are special to the shell).
env_value() {
  local line value
  line=$(grep -E "^[[:space:]]*$1=" "$ENV_FILE" | tail -n 1 || true)
  value=${line#*=}
  value=${value%$'\r'}
  value=${value%\"}
  value=${value#\"}
  value=${value%\'}
  value=${value#\'}
  if [ -z "$value" ]; then
    printf '%s' "$2"
  else
    printf '%s' "$value"
  fi
}

find_python() {
  local candidate
  for candidate in python3 python; do
    # Run it, don't just look it up: on Windows `python3` can be a Store stub
    # that exists on PATH but does not work.
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json' >/dev/null 2>&1; then
      PY="$candidate"
      return 0
    fi
  done
  return 1
}

preflight() {
  command -v docker >/dev/null 2>&1 || die "docker not found in PATH. Install Docker Desktop / Docker Engine."
  docker compose version >/dev/null 2>&1 || die "'docker compose' (Compose v2) is not available."
  docker info >/dev/null 2>&1 || die "Cannot reach the Docker daemon. Is Docker running?"
  command -v curl >/dev/null 2>&1 || die "curl not found in PATH."
  find_python || die "python3 not found (needed to parse Patroni's JSON)."
  [ -f "$ENV_FILE" ] || die ".env not found at ${ENV_FILE}. Create it first: cp .env.example .env (then set the passwords and DATA_DIR)."
  case "$TIMEOUT_SECONDS" in
    '' | *[!0-9]*) die "BOOTSTRAP_TIMEOUT must be a number of seconds, got '${TIMEOUT_SECONDS}'." ;;
  esac
}

# Any member answers /cluster the same way (it reflects the DCS, not local
# state), so take the first node that responds.
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

read -r -d '' EVAL_PY <<'PY' || true
import json
import sys

try:
    data = json.loads(sys.argv[1])
except ValueError:
    print("Patroni returned an unreadable /cluster response")
    sys.exit(1)

expected = int(sys.argv[2])
need_sync = sys.argv[3] == "true"
members = data.get("members") or []
leaders = [m for m in members if m.get("role") == "leader"]
problems = []

if len(members) != expected:
    problems.append("%d/%d members registered" % (len(members), expected))
if not leaders:
    problems.append("no leader elected")
elif len(leaders) > 1:
    problems.append("more than one leader")
elif leaders[0].get("state") != "running":
    problems.append("leader %s is %s" % (leaders[0].get("name"), leaders[0].get("state")))
for m in members:
    if m.get("role") != "leader" and m.get("state") != "streaming":
        problems.append("%s is %s, not streaming" % (m.get("name"), m.get("state")))
if need_sync and not any(m.get("role") == "sync_standby" for m in members):
    problems.append("no synchronous standby yet")

line = ", ".join(
    "%s=%s/%s" % (m.get("name"), m.get("role"), m.get("state")) for m in members
) or "no members"
if problems:
    line += "  [waiting: " + "; ".join(problems) + "]"
print(line)
sys.exit(1 if problems else 0)
PY

# evaluate_cluster <cluster_json> - prints a one-line status; exit 0 = healthy.
evaluate_cluster() {
  "$PY" -c "$EVAL_PY" "$1" "$EXPECTED_MEMBERS" "$REQUIRE_SYNC_STANDBY"
}

# endpoint_ready <port> - does HAProxy:<port> -> PgBouncer -> PostgreSQL answer?
# Runs from inside a node container, where `haproxy` resolves on the compose
# network. pg_isready needs no credentials.
endpoint_ready() {
  docker exec "${CONTAINER_PREFIX}${NODES[0]}" \
    pg_isready -q -h haproxy -p "$1" -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1
}

print_diagnostics() {
  local restarting name
  {
    echo
    echo "--- container status ---"
    docker ps -a --filter "name=${CONTAINER_PREFIX}" --format 'table {{.Names}}\t{{.Status}}' || true
    restarting=$(docker ps --filter "name=${CONTAINER_PREFIX}" --filter "status=restarting" --format '{{.Names}}' || true)
    if [ -n "$restarting" ]; then
      echo
      echo "Containers stuck in a restart loop (look at the first error in their logs):"
      while IFS= read -r name; do
        [ -n "$name" ] && echo "  docker logs --timestamps ${name} 2>&1 | head -100"
      done <<<"$restarting"
    fi
    echo
    echo "Next steps:"
    echo "  make status    # Patroni's view of the cluster"
    echo "  make logs      # follow all container logs"
    echo "  make reset     # wipe cluster AND etcd data and start from scratch"
  } >&2
}

fail_timeout() {
  # fail_timeout <what did not become ready> <last status line>
  echo >&2
  echo "ERROR: ${1} within ${TIMEOUT_SECONDS}s." >&2
  echo "       Last status: ${2}" >&2
  print_diagnostics
  exit 1
}

print_success() {
  local elapsed="$1"
  cat <<EOF

==> Stack is up and healthy (${elapsed}s)

Cluster:  ${LAST_STATUS}

Endpoints (client -> HAProxy -> PgBouncer -> PostgreSQL):
  write      localhost:${WRITE_PORT}   always the current primary
  read-only  localhost:${READ_PORT}   load-balanced across replicas
  HAProxy stats page: http://localhost:${STATS_PORT}/

Example (database '${PG_DB}'; passwords are in .env):
  psql "postgresql://etl_writer@localhost:${WRITE_PORT}/${PG_DB}"
  psql "postgresql://analytics_readonly@localhost:${READ_PORT}/${PG_DB}"

Next steps:
  make status         # patronictl list
  make access-test    # verify routing + role-based access (does a switchover)
  make failover-test  # kill the primary and measure re-election
  make down           # stop the stack (keeps data); make reset wipes it
EOF
}

# main

preflight

PG_DB="$(env_value POSTGRES_DB postgres_pitch)"
PG_USER="$(env_value POSTGRES_USER postgres_pitch_admin)"

info "Starting containers (docker compose up -d --build)..."
(cd "$SCRIPT_DIR" && docker compose --env-file ../.env up -d --build) ||
  die "docker compose failed (see output above). Fix that first; nothing is waiting yet."

START=$(date +%s)
DEADLINE=$((START + TIMEOUT_SECONDS))
LAST_STATUS="Patroni REST API not reachable yet"
PRINTED_STATUS=""

info "Waiting for Patroni to report a healthy cluster (timeout ${TIMEOUT_SECONDS}s)..."
while true; do
  if json=$(cluster_json); then
    if LAST_STATUS=$(evaluate_cluster "$json"); then
      break
    fi
  else
    LAST_STATUS="Patroni REST API not reachable yet"
  fi
  if [ "$LAST_STATUS" != "$PRINTED_STATUS" ]; then
    printf '    [%3ss] %s\n' "$(($(date +%s) - START))" "$LAST_STATUS"
    PRINTED_STATUS="$LAST_STATUS"
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    fail_timeout "The Patroni cluster did not become healthy" "$LAST_STATUS"
  fi
  sleep "$POLL_INTERVAL"
done
info "Patroni cluster is healthy: ${LAST_STATUS}"

info "Waiting for the HAProxy endpoints (:${WRITE_PORT} write, :${READ_PORT} read-only)..."
while ! { endpoint_ready "$WRITE_PORT" && endpoint_ready "$READ_PORT"; }; do
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    fail_timeout "The HAProxy endpoints did not start answering" "cluster healthy, but :${WRITE_PORT} and/or :${READ_PORT} refuse connections (check http://localhost:${STATS_PORT}/ for backend status)"
  fi
  sleep 2
done

print_success "$(($(date +%s) - START))"
