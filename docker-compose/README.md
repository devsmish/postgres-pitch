# docker-compose

Local development stack for the PostgreSQL HA cluster: 3-node etcd (the
distributed configuration store) + 3-node PostgreSQL managed by Patroni
(1 primary, 1 sync replica, 1 async replica).

Clients don't talk to the nodes directly: **HAProxy** (routing) and
**PgBouncer** (connection pooling) sit in front of the cluster — see
[Connect](#connect) below and [docs/access-patterns.md](../docs/access-patterns.md).

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

`make up` runs [`../../docker-compose/bootstrap.sh`](../../docker-compose/bootstrap.sh), which starts the stack and
then **waits until it is actually healthy** instead of returning as soon as
the containers exist. It polls Patroni's REST API until all three members
are registered, there is exactly one running leader, the other members are
`streaming`, and a synchronous standby exists; then it checks that the
write (`:5000`) and read-only (`:5001`) HAProxy endpoints accept
connections. On success it prints the endpoints and next steps. If the
cluster is not healthy within 180 seconds, it prints the last observed
status plus container diagnostics (including containers stuck in a
restart loop) and exits non-zero.

| Variable               | Default | Meaning                                                              |
| ---------------------- | ------- | -------------------------------------------------------------------- |
| `BOOTSTRAP_TIMEOUT`    | `180`   | Seconds to wait for a healthy cluster (image build time not counted) |
| `REQUIRE_SYNC_STANDBY` | `true`  | Set to `false` if `synchronous_mode` is disabled in `patroni.yml`    |

```bash
BOOTSTRAP_TIMEOUT=300 make up
```

The script is idempotent: on an already-running healthy stack it just
verifies it and prints the summary again. It needs `docker` (Compose v2),
`curl` and `python3`; on Windows run it from Git Bash or WSL2.

To start the containers without the health wait (for example while
debugging a crash loop), use Compose directly:

```bash
cd docker-compose
docker compose --env-file ../.env up -d --build
```

> **Design note — one build, three nodes:** only `postgresql0` declares a
> `build:` block in `docker-compose.yml`; `postgresql1` and `postgresql2`
> reference the same `image: postgres-pitch-patroni:local` tag with no
> build section of their own. This is the "build once, deploy many"
> pattern applied locally: the image is built exactly once and all three
> nodes run the byte-identical result, rather than Compose building the
> same Dockerfile three times in parallel. It's also what caused a real
> build-context bug during development (`failed to read dockerfile`,
> `transferring dockerfile: 2B`) — building three identical parallel
> targets from one context was the actual root cause, not a Windows- or
> Bake-specific issue. Iteration 8 (Terraform/cloud) will follow the same
> pattern for real: build once in CI, push a tagged image, every node
> pulls it — this is the local equivalent of that habit.

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

Applications use one of two HAProxy endpoints (flow: client → HAProxy →
PgBouncer → PostgreSQL). Both keep working across a failover or
switchover with no change on the client side:

| Endpoint | Host port | Routes to |
|---|---|---|
| **write** | `localhost:5000` | the current primary only |
| **read-only** | `localhost:5001` | healthy replicas, round-robin |

Connect as the demo roles (passwords from your `.env`):

```bash
# writes -> primary
psql "postgresql://etl_writer:<ETL_WRITER_PASSWORD>@localhost:5000/postgres_pitch"
# reads -> a replica
psql "postgresql://analytics_readonly:<ANALYTICS_READONLY_PASSWORD>@localhost:5001/postgres_pitch"
```

HAProxy's stats page shows which servers it considers up:
<http://localhost:8404/>.

### Direct access (debugging only)

Each node, and each node's PgBouncer, is also reachable directly. This is
not how applications should connect — it bypasses routing, so what you
reach depends on which node currently holds which role.

| Node | Postgres | Patroni REST API | PgBouncer |
|---|---|---|---|
| postgresql0 | `localhost:5433` | `localhost:8009` | `localhost:6432` |
| postgresql1 | `localhost:5434` | `localhost:8010` | `localhost:6433` |
| postgresql2 | `localhost:5435` | `localhost:8011` | `localhost:6434` |

```bash
make psql                  # admin shell on postgresql0
make psql NODE=postgresql1 # on a specific node
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

## Verify routing and role-based access

```bash
bash tests/access_patterns_test.sh     # or: make access-test
```

Checks that the write endpoint always lands on a primary and the
read-only endpoint on a replica (`pg_is_in_recovery()`), that
`etl_writer` and `analytics_readonly` can do exactly what they should
through each endpoint (and fail for the *right* reason when they
shouldn't — routing vs. grants), then runs `patronictl switchover` and
repeats everything with the same credentials and ports. Only the node
behind the endpoints changes. Details: [docs/access-patterns.md](../docs/access-patterns.md).

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
