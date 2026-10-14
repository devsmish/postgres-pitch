# postgres-pitch

[![Lint](https://github.com/devsmish/postgres-pitch/actions/workflows/lint.yml/badge.svg)](https://github.com/devsmish/postgres-pitch/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/devsmish/postgres-pitch)](https://github.com/devsmish/postgres-pitch/releases)

> Production-ready PostgreSQL HA cluster with Patroni, IaC (Terraform +
> Ansible), full observability stack, and real-world data pipelines —
> populated with real football data via open APIs.

**Status:** 🚧 in active development. Latest release: **v0.2.0**
(Iteration 1): a three-node Patroni/PostgreSQL cluster with etcd, PgBouncer
and HAProxy that starts with one command and whose failover is verified.
Data, observability, backups, infrastructure as code and ETL are still
ahead; see [ROADMAP.md](./ROADMAP.md) for the full plan and
[CHANGELOG.md](./CHANGELOG.md) for what each release contains.

---

## About

This is a portfolio project demonstrating end-to-end Database
Administrator competencies: designing a fault-tolerant PostgreSQL cluster,
automating its deployment, monitoring it in production, handling backups
and disaster recovery, tuning performance, and running real scheduled ETL
jobs against a live dataset.

Instead of an empty demo database, this project is populated with real
football data (clubs, players, competitions, matches, stadiums) sourced
from open APIs and datasets — see [DATA_SOURCES.md](./DATA_SOURCES.md) for
details and licensing.

## Architecture

✅ built and verified locally (v0.2.0) · 📋 planned

- ✅ **PostgreSQL**: 1 Primary + 1 Sync Replica + 1 Async Replica
- ✅ **Patroni + etcd** — automated failover orchestration
- ✅ **PgBouncer** — connection pooling
- ✅ **HAProxy** — routing to the current primary (write) and the replicas
  (read-only)
- 📋 **pgBackRest** — backups and point-in-time recovery
- 📋 **Prometheus + Grafana** — monitoring and dashboards
- 📋 **Terraform + Ansible** — infrastructure as code, local and cloud deployment
- 📋 **Python ETL scripts** — scheduled data sync and quality checks

Full details in [docs/architecture.md](./docs/architecture.md).

## Quick Start

Brings up the local Docker Compose stack — a 3-node Patroni/PostgreSQL
cluster (1 primary, 1 synchronous standby, 1 async replica), a 3-node
etcd, PgBouncer and HAProxy — and waits until it is healthy.

### Prerequisites

- Docker with Compose v2 (Docker Desktop, or Docker Engine with the
  compose plugin)
- A shell: bash (Linux/macOS, WSL2, Git Bash on Windows) or PowerShell on
  Windows. Steps 1-3 and the `make` targets work in both; where the syntax
  differs (step 4 and Verification), both variants are shown.
- `curl` and `python3` (used by the startup and test scripts)
- `make` (optional; see the note after step 2)

### 1. Clone and configure

```bash
git clone https://github.com/devsmish/postgres-pitch.git
cd postgres-pitch
cp .env.example .env
```

Then edit `.env`:

- `DATA_DIR`: where the cluster's data lives on your machine (a path you
  control; on native Windows use forward slashes, e.g. `D:/DB/pg-pitch`).
  The default `./data` resolves relative to `docker-compose/`.
- Replace every `change_me` in the **PostgreSQL**, **Patroni / etcd**,
  **PgBouncer** and **Demo roles** sections (`POSTGRES_PASSWORD`,
  `POSTGRES_REPLICATION_PASSWORD`, `ETCD_CLUSTER_TOKEN`,
  `PGBOUNCER_AUTH_PASSWORD`, `ANALYTICS_READONLY_PASSWORD`,
  `ETL_WRITER_PASSWORD`).
- Leave the pgBackRest, Monitoring, data-source and cloud variables as
  they are; they are used by later iterations.
- Keep spaces, quotes and `$` out of the values: the helper scripts read
  `.env` with the shell.

### 2. Start the stack

```bash
make up
```

`make up` runs [`docker-compose/bootstrap.sh`](./docker-compose/bootstrap.sh):
it builds the image, starts the containers and then waits until Patroni
reports a healthy cluster (one running leader, the other members
streaming, a synchronous standby) and both HAProxy endpoints answer. A
start from an empty `DATA_DIR` took 46s on our test machine with the image
already built; the very first run also downloads and builds the image,
which adds roughly 40s. On success it ends with:

```
==> Stack is up and healthy (46s)
```

If the cluster is not healthy within 180s the script exits non-zero and
prints the last status and which containers are misbehaving. Details and
options: [docker-compose/README.md](./docker-compose/README.md).

> **No `make`?** (Git Bash on Windows does not ship it.) Run the script
> that each target wraps instead: `bash docker-compose/bootstrap.sh`
> for `make up`, `bash tests/access_patterns_test.sh` for
> `make access-test`, `bash tests/failover_test.sh` for
> `make failover-test`.

### 3. Check that the cluster is healthy

```bash
make status
```

Expected: three members on the same timeline, one `Leader` (`running`),
one `Sync Standby` and one `Replica`, both `streaming` with lag `0`.
Which node is the leader differs from run to run.

```
+ Cluster: postgres-pitch-cluster (...) ----+-------------+-----+------------+-----+
| Member      | Host        | Role         | State     | TL | Receive LSN | Lag | Replay LSN | Lag |
+-------------+-------------+--------------+-----------+----+-------------+-----+------------+-----+
| postgresql0 | postgresql0 | Leader       | running   |  1 |             |     |            |     |
| postgresql1 | postgresql1 | Replica      | streaming |  1 |   0/404F6A8 |   0 |  0/404F6A8 |   0 |
| postgresql2 | postgresql2 | Sync Standby | streaming |  1 |   0/404F6A8 |   0 |  0/404F6A8 |   0 |
+-------------+-------------+--------------+-----------+----+-------------+-----+------------+-----+
```

### 4. Connect

Clients connect through HAProxy and never need to know which node is the
primary:

| Endpoint | Port | Goes to |
|---|---|---|
| Write | `localhost:5000` | always the current primary |
| Read-only | `localhost:5001` | the replicas, load-balanced |
| HAProxy stats | http://localhost:8404/ | backend health at a glance |

Two demo roles show the split. First load your `.env` into the current
shell, so the commands below pick up the passwords you set there:

```bash
# bash
set -a; source <(tr -d '\r' < .env); set +a
```

```powershell
# PowerShell
Get-Content .\.env | Where-Object { $_ -match '^\s*[^#\s].*=' } | ForEach-Object { $k,$v = $_ -split '=',2; Set-Item "env:$k" $v.Trim() }
```

Then run `psql` inside a cluster container, which reaches HAProxy by the
name `haproxy` (no `psql` needed on your machine). The write endpoint must
answer `f` (not in recovery), the read-only endpoint `t`. Each command is a
single line:

```bash
# bash
docker exec -e PGPASSWORD="$ETL_WRITER_PASSWORD" postgres-pitch-postgresql0 psql -h haproxy -p 5000 -U etl_writer -d "$POSTGRES_DB" -Atc "SELECT pg_is_in_recovery()"
docker exec -e PGPASSWORD="$ANALYTICS_READONLY_PASSWORD" postgres-pitch-postgresql0 psql -h haproxy -p 5001 -U analytics_readonly -d "$POSTGRES_DB" -Atc "SELECT pg_is_in_recovery()"
```

```powershell
# PowerShell
docker exec -e PGPASSWORD=$env:ETL_WRITER_PASSWORD postgres-pitch-postgresql0 psql -h haproxy -p 5000 -U etl_writer -d $env:POSTGRES_DB -Atc "SELECT pg_is_in_recovery()"
docker exec -e PGPASSWORD=$env:ANALYTICS_READONLY_PASSWORD postgres-pitch-postgresql0 psql -h haproxy -p 5001 -U analytics_readonly -d $env:POSTGRES_DB -Atc "SELECT pg_is_in_recovery()"
```

If you have `psql` installed on the host, the same endpoints are
published on your machine:

```bash
psql "postgresql://etl_writer@localhost:5000/postgres_pitch"          # INSERT/UPDATE
psql "postgresql://analytics_readonly@localhost:5001/postgres_pitch"  # SELECT only
```

### Verification

**Replication works.** `make status` shows both non-leader members as
`streaming` with lag `0` (step 3). To see it from the primary's side, ask
it through the write endpoint (same shell as in step 4, with `.env` loaded);
expect two rows, both `streaming`, one `sync` and one `async`:

```bash
# bash
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" postgres-pitch-postgresql0 psql -h haproxy -p 5000 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT application_name, state, sync_state FROM pg_stat_replication"
```

```powershell
# PowerShell
docker exec -e PGPASSWORD=$env:POSTGRES_PASSWORD postgres-pitch-postgresql0 psql -h haproxy -p 5000 -U $env:POSTGRES_USER -d $env:POSTGRES_DB -c "SELECT application_name, state, sync_state FROM pg_stat_replication"
```

**Routing and roles.** `make access-test` checks that the write endpoint
always reaches a primary and the read-only endpoint a replica, that each
demo role can do what it should and nothing else, and that all of this
still holds after a real `patronictl switchover`. It changes the leader.
See [docs/access-patterns.md](./docs/access-patterns.md).

**Failover.** `make failover-test` kills the current primary's container
and checks that the synchronous standby is promoted, HAProxy follows with
the same connection strings, the roles keep working, and the old primary
rejoins as a replica; it prints the timings and always restarts the killed
node. Measured results and how to read them:
[docs/failover-notes.md](./docs/failover-notes.md). After either test,
`make status` shows the cluster again (the roles of the nodes will have
changed).

### Stop and reset

```bash
make down     # stop the stack, keep the data
make reset    # stop the stack AND delete all cluster data (DATA_DIR, incl. etcd)
```

If a first start ever goes wrong (for example a node restarting in a
loop), `make logs` shows why, and `make reset` followed by `make up`
gives a clean start.

## Documentation

- [docs/architecture.md](./docs/architecture.md) — components, data flow
  and status
- [docs/access-patterns.md](./docs/access-patterns.md) — read/write split
  through HAProxy and PgBouncer, and the demo roles
- [docs/failover-notes.md](./docs/failover-notes.md) — measured failover
  behaviour and what is asserted
- [docs/decisions/](./docs/decisions/) — architecture decision records
- [CONTRIBUTING.md](./CONTRIBUTING.md) — workflow, local setup and linting
- [CHANGELOG.md](./CHANGELOG.md) — what each release contains

## Roadmap

See [ROADMAP.md](./ROADMAP.md) for the complete, iteration-by-iteration
plan. Iterations 0 and 1 are released (v0.1.0, v0.2.0); next is Iteration 2,
loading the real football data.

## License

The code in this repository is licensed under the [MIT License](./LICENSE).

Football data used in this project is sourced from third-party providers
under their own terms — see [DATA_SOURCES.md](./DATA_SOURCES.md) for
details. This is a non-commercial portfolio/educational project.
