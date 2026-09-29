# Architecture

Status legend: 📋 planned → 🚧 in progress → ✅ done

This document describes the target architecture. For the detailed
iteration-by-iteration build order, see [ROADMAP.md](../ROADMAP.md).

## Overview

```
                 client
        write :5000 │ read :5001
                    ▼
             ┌─────────────┐  health checks: Patroni REST API (/primary, /replica)
             │   HAProxy   │◀─────────────────────────────────────────────┐
             └──────┬──────┘                                              │
                    ▼                                                     │
   ┌────────────┐ ┌────────────┐ ┌────────────┐                           │
   │ PgBouncer0 │ │ PgBouncer1 │ │ PgBouncer2 │   (one per node, pooling) │
   └─────┬──────┘ └─────┬──────┘ └─────┬──────┘                           │
         ▼              ▼              ▼                                  │
   ┌────────────┐ ┌────────────┐ ┌────────────┐                           │
   │ postgresql0│ │ postgresql1│ │ postgresql2│───────────────────────────┘
   │  Patroni   │ │  Patroni   │ │  Patroni   │   1 primary + 1 sync + 1 async
   └─────┬──────┘ └─────┬──────┘ └─────┬──────┘
         └──────────────┼──────────────┘
                        ▼
              etcd (3 nodes, DCS / leader lock)

 Off to the side:
   pgBackRest → S3/Storage      Prometheus + Grafana      ETL scripts (Python)
                                                                 │
                                          football-data.org, OpenFootball, Kaggle
```

## Components

| Component | Role | Status |
|---|---|---|
| PostgreSQL (1 Primary + 1 Sync Standby + 1 Async Replica) | Data layer | ✅ verified locally (Docker Compose) — automatic failover confirmed, see [ADR 0002](./decisions/0002-synchronous-replication.md) |
| Patroni + etcd | Cluster orchestration, automatic failover | ✅ verified locally — see `tests/failover_test.sh` |
| PgBouncer | Connection pooling (one instance per node, behind HAProxy) | 🚧 implemented, verification pending — see [access patterns](../../docs/access-patterns.md) |
| HAProxy | Write (`:5000`) / read-only (`:5001`) routing via Patroni REST health checks | 🚧 implemented, verification pending — see [access patterns](../../docs/access-patterns.md) |
| pgBackRest | Backups, point-in-time recovery | 📋 |
| Prometheus + Grafana | Monitoring and dashboards | 📋 |
| Terraform | Cloud infrastructure provisioning | 📋 |
| Ansible | Configuration management | 📋 |
| Python ETL scripts | Football data ingestion and sync | 📋 |
| Database schema | Reference data, clubs, players, matches | ✅ (initial DDL, see `db/schema/001_initial_schema.sql`) |

## Data Flow

1. **Bootstrap load**: static datasets (OpenFootball, Kaggle) are bulk-loaded
   into staging tables, then normalized into the core schema.
2. **Recurring sync**: a scheduled job (pg_cron / systemd timer, see
   `ansible/roles/data-sync/`) pulls incremental updates from
   football-data.org and upserts them.
3. **Client path**: clients connect to HAProxy — port `5000` (write, the
   current primary only) or `5001` (read-only, round-robin over healthy
   replicas). HAProxy forwards to the PgBouncer colocated with the chosen
   node, which pools connections to that node's PostgreSQL. See
   [access-patterns.md](../../docs/access-patterns.md).
4. **Failover**: Patroni detects primary failure, promotes the sync
   replica, HAProxy's next health checks move the write endpoint to it.
   See `tests/failover_test.sh` and `tests/access_patterns_test.sh`.
5. **Backup path**: pgBackRest continuously archives WAL and takes
   scheduled full/incremental backups to object storage; restores are
   periodically verified by `scripts/verify_backup_restore.py`.

## Design Decisions

Individual decisions and their trade-offs are recorded as ADRs in
[docs/decisions/](./decisions/):

- [ADR 0001 — Schema design decisions](./decisions/0001-schema-design.md)
- [ADR 0002 — Synchronous replication trade-off](./decisions/0002-synchronous-replication.md)

New ADRs are added as decisions are made, not written retroactively.
