#!/bin/bash
# Runs once, automatically, right after Patroni initializes the cluster on
# the very first node to bootstrap (see bootstrap.post_bootstrap in
# patroni.yml). Patroni passes a libpq connection string to the newly
# created superuser as the first argument.
#
# Four things happen here, all idempotent even though this is only meant
# to run once per cluster lifetime:
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
# 3. Create pgbouncer_auth (PgBouncer's auth_query technical role) and two
#    demo roles (analytics_readonly, etl_writer) for Issue #9's
#    role-based access verification.
# 4. Create the auth_query lookup function PgBouncer uses to authenticate
#    any role without a static userlist.txt entry per role, and grant
#    default privileges so tables created later (via \`make schema\`)
#    automatically pick up the right access for the demo roles.
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

# --- PgBouncer auth_query role -------------------------------------------
# PgBouncer authenticates real users via auth_query (a lookup function),
# not a static userlist.txt entry per role — that would mean hand-adding
# an entry every time a new role is created. pgbouncer_auth is the one
# technical role PgBouncer itself connects as to run that lookup; it has
# no access to data, only EXECUTE on the lookup function below.
PGBOUNCER_AUTH_USER="${PGBOUNCER_AUTH_USER:-pgbouncer_auth}"
PGBOUNCER_AUTH_PASSWORD="${PGBOUNCER_AUTH_PASSWORD:-}"

# --- Demo roles for Iteration 1 role-based access verification ----------
# analytics_readonly: SELECT only. etl_writer: INSERT/UPDATE only.
# Deliberately lightweight — the full security posture (SCRAM, pg_hba
# hardening, least-privilege audit, pgAudit) is tracked separately in
# Iteration 5.
ANALYTICS_READONLY_PASSWORD="${ANALYTICS_READONLY_PASSWORD:-}"
ETL_WRITER_PASSWORD="${ETL_WRITER_PASSWORD:-}"

for pair in "PGBOUNCER_AUTH_PASSWORD:$PGBOUNCER_AUTH_PASSWORD" \
            "ANALYTICS_READONLY_PASSWORD:$ANALYTICS_READONLY_PASSWORD" \
            "ETL_WRITER_PASSWORD:$ETL_WRITER_PASSWORD"; do
  name="${pair%%:*}"
  value="${pair#*:}"
  if [ -z "$value" ]; then
    echo "post_bootstrap.sh: $name is not set in the environment" >&2
    exit 1
  fi
done

# pgbouncer_auth is stored with an MD5 password secret on purpose (all
# other roles use PostgreSQL's default, SCRAM-SHA-256). PgBouncer logs in
# to PostgreSQL as this role using whatever the edoburu image writes into
# userlist.txt from DB_USER/DB_PASSWORD (plaintext or an MD5 hash) — an
# MD5 hash can only authenticate against an MD5 secret, while a SCRAM
# secret needs plaintext or a SCRAM verifier. An MD5-stored secret works
# in both cases. Known trade-off for this one technical role that has no
# data access; revisit together with the rest of auth in Iteration 5
# (Security), e.g. by generating a SCRAM verifier into userlist.txt.
psql "$CONNSTR" -v ON_ERROR_STOP=1 <<SQL
SET password_encryption = 'md5';
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PGBOUNCER_AUTH_USER}') THEN
    CREATE ROLE ${PGBOUNCER_AUTH_USER} WITH LOGIN ENCRYPTED PASSWORD '${PGBOUNCER_AUTH_PASSWORD}';
  END IF;
END
\$\$;
SQL

psql "$CONNSTR" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'analytics_readonly') THEN
    CREATE ROLE analytics_readonly WITH LOGIN ENCRYPTED PASSWORD '${ANALYTICS_READONLY_PASSWORD}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'etl_writer') THEN
    CREATE ROLE etl_writer WITH LOGIN ENCRYPTED PASSWORD '${ETL_WRITER_PASSWORD}';
  END IF;
END
\$\$;
SQL

# Everything below is scoped to the application database specifically
# (the lookup function and grants only make sense there), so connect to
# it directly rather than whatever default database $CONNSTR points at.
# Patroni's post_bootstrap connstring is a libpq keyword/value string
# (e.g. "host=... port=... user=..."), so appending another keyword/value
# pair overrides dbname if present or sets it if absent.
APP_CONNSTR="$CONNSTR dbname=${APP_DB}"

psql "$APP_CONNSTR" -v ON_ERROR_STOP=1 <<SQL
-- Standard PgBouncer auth_query pattern: a SECURITY DEFINER function so
-- PgBouncer can look up any role's password hash without being a
-- superuser itself, and without needing a static userlist.txt entry for
-- every application role. See:
-- https://www.pgbouncer.org/config.html#auth_query
CREATE OR REPLACE FUNCTION public.user_lookup(in i_username text, out uname text, out phash text)
RETURNS record AS \$\$
BEGIN
    SELECT usename, passwd FROM pg_catalog.pg_shadow
    WHERE usename = i_username INTO uname, phash;
    RETURN;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.user_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.user_lookup(text) TO ${PGBOUNCER_AUTH_USER};

-- Applied via ALTER DEFAULT PRIVILEGES, not GRANT ... ON ALL TABLES,
-- because at this point in the bootstrap process the schema hasn't been
-- applied yet (see \`make schema\` in the Makefile / ROADMAP Iteration 2).
-- This way, whatever tables the schema migration creates afterwards
-- automatically pick up the right grants without re-running anything.
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
  GRANT SELECT ON TABLES TO analytics_readonly;
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
  GRANT INSERT, UPDATE ON TABLES TO etl_writer;
-- INSERT into a table with a SERIAL/BIGSERIAL column (most of ours) also
-- needs USAGE on the backing sequence, or it fails with "permission
-- denied for sequence" even though INSERT on the table itself is granted.
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO etl_writer;

-- Also grant on anything that might already exist, for idempotency if
-- this is ever re-run manually during troubleshooting after the schema
-- is already applied.
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analytics_readonly;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO etl_writer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO etl_writer;
SQL
