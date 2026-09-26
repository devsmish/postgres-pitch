#!/bin/bash
# Runs once, automatically, right after Patroni initializes the cluster on
# the very first node to bootstrap (see bootstrap.post_bootstrap in
# patroni.yml). Patroni passes a libpq connection string to the newly
# created superuser as the first argument.
#
# Two things happen here, both idempotent (IF NOT EXISTS-guarded) even
# though this is only meant to run once per cluster lifetime:
#
# 1. Create the replication role explicitly. Patroni does NOT create this
#    role automatically from PATRONI_REPLICATION_USERNAME/PASSWORD — those
#    variables are only used for connecting/authenticating as that role,
#    not for creating it. Without this step, replicas fail pg_basebackup
#    with "role does not exist" and can end up bootstrapping their own,
#    independent (and incompatible) cluster instead of joining this one —
#    the real root cause behind a whole class of "system ID mismatch"
#    failures seen during development.
# 2. Create the application database (POSTGRES_DB) — Patroni's initdb only
#    creates the default 'postgres' database, unlike the official postgres
#    image's entrypoint, which reads POSTGRES_DB itself.
set -euo pipefail

CONNSTR="$1"
APP_DB="${POSTGRES_DB}"
REPL_USER="${POSTGRES_REPLICATION_USER:-${PATRONI_REPLICATION_USERNAME}}"
REPL_PASSWORD="${POSTGRES_REPLICATION_PASSWORD:-${PATRONI_REPLICATION_PASSWORD}}"

if [ -z "$REPL_PASSWORD" ]; then
  echo "post_bootstrap.sh: no replication password found in environment" \
       "(checked POSTGRES_REPLICATION_PASSWORD and PATRONI_REPLICATION_PASSWORD)" >&2
  exit 1
fi

psql "$CONNSTR" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${REPL_USER}') THEN
    CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN ENCRYPTED PASSWORD '${REPL_PASSWORD}';
  END IF;
END
\$\$;
SQL

psql "$CONNSTR" -v ON_ERROR_STOP=1 <<SQL
SELECT 'CREATE DATABASE ${APP_DB}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${APP_DB}')\gexec
SQL
