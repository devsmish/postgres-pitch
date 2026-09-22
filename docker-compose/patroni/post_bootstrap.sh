#!/bin/bash
# Runs once, automatically, right after Patroni initializes the cluster on
# the very first node to bootstrap (see bootstrap.post_bootstrap in
# patroni.yml). Patroni passes a libpq connection string to the newly
# created superuser as the first argument.
#
# Creates the application database. Idempotent-ish by design: this only
# ever runs once per cluster lifetime (Patroni tracks that in the DCS), so
# it does not need an "IF NOT EXISTS" guard, but one is added anyway in
# case of a manual re-run during troubleshooting.
set -euo pipefail

CONNSTR="$1"
APP_DB="${POSTGRES_DB}"

psql "$CONNSTR" -v ON_ERROR_STOP=1 -c \
  "SELECT 'CREATE DATABASE ${APP_DB}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${APP_DB}')\gexec"
