# Architecture

Status legend: 📋 planned → 🚧 in progress → ✅ done

This document describes the target architecture. For the detailed
iteration-by-iteration build order, see [ROADMAP.md](../ROADMAP.md).

## Overview

```
┌─────────────┐      ┌──────────────────────────────┐
│   HAProxy   │──────│  Patroni + etcd (3 nodes)      │
│ (routing)   │      │  Primary ←→ Sync Replica       │
└─────────────┘      │           ←→ Async Replica     │
                      └──────────────────────────────┘
                               │
                      ┌────────┴────────┐
                      │    PgBouncer     │
                      └─────────────────┘
                               │
        ┌──────────────────────┼──────────────────────┐
        │                      │                       │
 ┌──────────────┐     ┌──────────────┐        ┌──────────────┐
 │ pgBackRest    │     │ Prometheus +  │        │ ETL Scripts   │
 │ (S3/Storage)  │     │ Grafana       │        │ (Python, cron)│
 └──────────────┘     └──────────────┘        └──────────────┘
                                                        │
                                              ┌──────────────────┐
                                              │ football-data.org │
                                              │ OpenFootball      │
                                              │ Kaggle datasets   │
                                              └──────────────────┘
```

## Components

| Component | Role | Status |
|---|---|---|
| PostgreSQL (1 Primary + 1 Sync Replica + 1 Async Replica) | Data layer | 📋 |
| Patroni + etcd | Cluster orchestration, automatic failover | 📋 |
| PgBouncer | Connection pooling | 📋 |
| HAProxy | Routing to current primary | 📋 |
| pgBackRest | Backups, point-in-time recovery | 📋 |
| Prometheus + Grafana | Monitoring and dashboards | 📋 |
| Terraform | Cloud infrastructure provisioning | 📋 |
| Ansible | Configuration management | 📋 |
| Python ETL scripts | Football data ingestion and sync | 📋 |
| Database schema | Reference data, clubs, players, matches | ✅ (initial DDL, see `../db/schema/001_initial_schema.sql`) |

## Data Flow

1. **Bootstrap load**: static datasets (OpenFootball, Kaggle) are bulk-loaded
   into staging tables, then normalized into the core schema.
2. **Recurring sync**: a scheduled job (pg_cron / systemd timer, see
   `ansible/roles/data-sync/`) pulls incremental updates from
   football-data.org and upserts them.
3. **Read path**: PgBouncer → current primary (writes) or replicas (reads,
   in a later iteration) → application/analytics queries.
4. **Failover**: Patroni detects primary failure, promotes the sync
   replica, HAProxy reroutes traffic. See `tests/failover_test.sh`.
5. **Backup path**: pgBackRest continuously archives WAL and takes
   scheduled full/incremental backups to object storage; restores are
   periodically verified by `scripts/verify_backup_restore.py`.

## Design Decisions

Individual decisions and their trade-offs are recorded as ADRs in
[docs/decisions/](./decisions/):

- [ADR 0001 — Schema design decisions](../skeleton/docs/decisions/0001-schema-design.md)

New ADRs are added as decisions are made, not written retroactively.
