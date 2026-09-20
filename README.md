# postgres-pitch

[![Lint](https://github.com/<your-username>/postgres-pitch/actions/workflows/lint.yml/badge.svg)](https://github.com/<your-username>/postgres-pitch/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/<your-username>/postgres-pitch)](https://github.com/<your-username>/postgres-pitch/releases)

> Production-ready PostgreSQL HA cluster with Patroni, IaC (Terraform +
> Ansible), full observability stack, and real-world data pipelines —
> populated with real football data via open APIs.

**Status:** 🚧 early stage — see [ROADMAP.md](./ROADMAP.md) for the full
plan and current progress.

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

## Planned Architecture

- **PostgreSQL**: 1 Primary + 1 Sync Replica + 1 Async Replica
- **Patroni + etcd** — automated failover orchestration
- **PgBouncer** — connection pooling
- **HAProxy** — routing to the current primary
- **pgBackRest** — backups and point-in-time recovery
- **Prometheus + Grafana** — monitoring and dashboards
- **Terraform + Ansible** — infrastructure as code, local and cloud deployment
- **Python ETL scripts** — scheduled data sync and quality checks

Full details in [docs/architecture.md](./docs/architecture.md) (coming soon).

## Quick Start

_Coming soon — will be added once the local Docker Compose stack is
verified end-to-end (see Iteration 1 in the roadmap)._

## Roadmap

See [ROADMAP.md](./ROADMAP.md) for the complete, iteration-by-iteration plan.

## License

The code in this repository is licensed under the [MIT License](./LICENSE).

Football data used in this project is sourced from third-party providers
under their own terms — see [DATA_SOURCES.md](./DATA_SOURCES.md) for
details. This is a non-commercial portfolio/educational project.
