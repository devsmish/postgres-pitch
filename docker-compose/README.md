# docker-compose

Local development stack for the PostgreSQL HA cluster: 3-node etcd (the
distributed configuration store) + 3-node PostgreSQL managed by Patroni
(1 primary, 1 sync replica, 1 async replica).

PgBouncer and HAProxy are added in a follow-up PR — this stack is
currently scoped to the database layer only.

## Prerequisites

- Docker and Docker Compose v2
- A `.env` file in the repo root (copy `.env.example` → `.env` and fill in
  real passwords — see the root README)

## Data storage

Every node's data directory is a **bind mount** to `${DATA_DIR}/<node>`
on the host, not a Docker named volume. This is deliberate: named
volumes on Docker Desktop live inside its internal VM disk (on Windows,
the WSL2 `.vhdx` file), which grows unbounded on your system drive as the
database fills up. A bind mount puts the data exactly where you point it.

Set `DATA_DIR` in `.env` to a path on a disk you control, e.g.:

```env
DATA_DIR=/mnt/d/DB/pg-pitch      # WSL2 — recommended, see CONTRIBUTING.md
DATA_DIR=D:/DB/pg-pitch          # native Windows
DATA_DIR=./data                  # default — inside the repo, git-ignored
```

If unset, it defaults to `docker-compose/data/` (already in `.gitignore`).

`make down` does **not** delete this data (bind mounts survive container
removal by design — same as `docker compose down` without `-v`). To wipe
the cluster and start completely fresh:

```bash
make reset
```

## Start the cluster

From the repository root:

```bash
make up
```

Or directly:

```bash
cd docker-compose
docker compose --env-file ../.env up -d --build
```

> **Design note — one build, three nodes:** only `postgresql0` declares a
> `build:` block in `docker-compose.yml`; `postgresql1` and `postgresql2`
> reference the same `image: postgres-pitch-patroni:local` tag with no
> build section of their own. This is the "build once, deploy many"
> pattern applied locally: the image is built exactly once and all three
> nodes run the byte-identical result. Iteration 8 (Terraform/cloud) will
> follow the same pattern for real: build once in CI, push a tagged image,
> every node pulls it — this is the local equivalent of that habit.

First start takes a minute or two (builds the Patroni image, initializes
the primary, streams a base backup to both replicas).

## Verify it's healthy

```bash
make status
```

Expected output — one Leader, two Replicas, all in `running` state:

```
+ Cluster: postgres-pitch-cluster ----+---------+-----+-----------+
| Member      | Host        | Role    | State   | TL  | Lag in MB |
+-------------+-------------+---------+---------+-----+-----------+
| postgresql0 | postgresql0 | Leader  | running |   1 |           |
| postgresql1 | postgresql1 | Replica | running |   1 |         0 |
| postgresql2 | postgresql2 | Replica | running |   1 |         0 |
+-------------+-------------+---------+---------+-----+-----------+
```

Check who the current primary is at any point:

```bash
make leader
```

## Connect

Each node is also reachable directly from the host for debugging (not how
the application will connect once PgBouncer/HAProxy are added):

| Node | Postgres port | Patroni REST API |
|---|---|---|
| postgresql0 | localhost:5433 | localhost:8009 |
| postgresql1 | localhost:5434 | localhost:8010 |
| postgresql2 | localhost:5435 | localhost:8011 |

```bash
make psql                  # connects to postgresql0
make psql NODE=postgresql1 # connects to a specific node
```

## Databases in this cluster

Each of the 3 nodes is a full PostgreSQL server instance, but together
they form **one** logical cluster (1 primary + 2 replicas of the same
data) — not three separate databases. Within that cluster:

- `postgres` — default administrative database created by initdb
- `postgres_pitch` (or whatever `POSTGRES_DB` is set to) — the
  application database, created automatically once, right after the
  first node bootstraps, via `patroni/post_bootstrap.sh`

`make psql` connects to `POSTGRES_DB` by default, not `postgres`.

## Verify replication is working

```bash
make psql
# on postgresql0 (primary):
CREATE TABLE replication_check (id serial primary key, note text);
INSERT INTO replication_check (note) VALUES ('hello from primary');
\q

make psql NODE=postgresql1
# on postgresql1 (replica):
SELECT * FROM replication_check;
\q
```

The row should be visible on both replicas within a second or two.

## Verify automatic failover

```bash
bash tests/failover_test.sh
```

This kills the current primary's container (a genuine `docker kill`, not
a graceful shutdown), measures how long it takes Patroni to elect a new
leader, and confirms the promoted node was the **synchronous** standby —
i.e. a zero-data-loss failover, not just "some node became leader." See
[ADR 0002](../docs/decisions/0002-synchronous-replication.md) for why
that distinction matters and the durability/latency trade-off behind it.

Example output from a real run:

```
Old leader:            postgresql0 (killed)
New leader:            postgresql1
Failover time:         28s (container kill -> new leader visible)
Promoted node check:   PASS — the synchronous standby was promoted
                       (zero-data-loss failover, as designed)
```

The script restarts the killed node afterwards so it rejoins the cluster
as a replica — confirm with `make status` a few seconds later.

## Stop / reset

```bash
make down    # stops containers, keeps data on disk (DATA_DIR)
make reset   # stops containers AND deletes DATA_DIR — start fresh
```

## Notes

- **etcd healthchecks, not just container startup:** PostgreSQL nodes
  wait for etcd to report genuine quorum readiness (`etcdctl endpoint
  health`, which requires an established Raft quorum to succeed) before
  starting Patroni. Without this, a fully cold `docker compose up` can
  race: two Patroni nodes may each decide independently that no cluster
  exists yet and run `initdb` in parallel, producing two incompatible
  clusters with different system IDs — visible as `CRITICAL: system ID
  mismatch` in a crash-looping node's logs. This was a real, intermittent
  failure during development, not a hypothetical.
- Uses the official `gcr.io/etcd-development/etcd` image, not Bitnami's —
  Bitnami's versioned etcd images stopped being freely available in
  September 2025.
- `patroni/patroni.yml` holds settings shared by every node (bootstrap
  behavior, postgresql.conf parameters, pg_hba). Node identity, network
  addresses, and credentials come entirely from `PATRONI_*` environment
  variables in `docker-compose.yml` — see Patroni's
  [environment variable reference](https://patroni.readthedocs.io/en/latest/ENVIRONMENT.html).
- `pg_hba` in this stack is intentionally permissive (trusts the whole
  compose network) — this is a local dev cluster, not a security
  reference. Hardening happens in Iteration 5 (`ansible/roles/security/`).
- No credentials or secrets are hardcoded anywhere in `Dockerfile` or
  `docker-compose.yml` — everything comes from `.env` (git-ignored).
  One exception worth knowing: the replication role name `replicator` is
  hardcoded as a literal in `patroni/patroni.yml`'s `pg_hba` rules
  (Patroni doesn't support env var substitution there). It must match
  `POSTGRES_REPLICATION_USER` in `.env` — both files have comments
  pointing at each other as a reminder.
