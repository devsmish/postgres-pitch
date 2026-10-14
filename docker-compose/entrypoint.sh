#!/bin/bash
# Runs as root (the container's default user — see Dockerfile). Bind
# mounts take their ownership from the host, not from the image, so the
# `chown` baked into the image at build time doesn't apply once a host
# directory is mounted over /home/postgres/data at runtime. This is the
# same reason the official postgres image's own entrypoint starts as
# root, fixes ownership, then drops to the postgres user via gosu —
# we do the same thing here since Patroni replaces that entrypoint.
#
# Without this step, initdb fails with:
#   "could not change permissions of directory ...: Operation not permitted"
# — most visible on Docker Desktop for Windows, where bind-mounted host
# directories don't carry usable Unix ownership until a root process
# inside the container claims them.
set -euo pipefail

mkdir -p /home/postgres/data
chown -R postgres:postgres /home/postgres
# initdb (used by the leader) always forces 0700 on PGDATA itself as part
# of its own initialization — but pg_basebackup (used by replicas to
# clone from the leader) does NOT fix the permissions of the top-level
# target directory, only the files it writes inside it. Without this,
# replicas fail to start with "data directory has invalid permissions"
# even though pg_basebackup itself completed successfully.
chmod 0700 /home/postgres/data

exec gosu postgres patroni "$@"
