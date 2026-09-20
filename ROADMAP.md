# postgres-pitch

**Production-Ready High-Availability PostgreSQL Cluster with real football data, IaC and Observability**

Status legend: 📋 planned → 🚧 in progress → ✅ done
(update the status of each item as you progress)

---

## 1. Concept

A portfolio project demonstrating the full range of Database Administrator
competencies: designing a fault-tolerant PostgreSQL cluster, operating it,
monitoring, backups, performance tuning, and running real scheduled ETL jobs
against real-world data (football domain: clubs, players, competitions,
matches, stadiums).

**Core idea:** not an empty demo database, but a living system with real
data, recurring integrations, and genuine operational tasks.

**Repository name:** `postgres-pitch`
(a deliberate double meaning: football pitch / pitching the project — the
football theme itself is explained in the README description, not in the
repo name, which stays professional and infrastructure-focused at a glance)

---

## 2. Target Architecture

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

**Components:**
- PostgreSQL: 1 Primary + 1 Sync Replica + 1 Async Replica (a deliberate
  durability/latency trade-off — a good topic for an ADR)
- Patroni + etcd — orchestration, automatic failover
- PgBouncer — connection pooling
- HAProxy / vip-manager — routing to the current primary
- pgBackRest — backups, PITR
- Prometheus + Grafana + postgres_exporter + patroni exporter — monitoring
- Loki/Promtail (optional) — centralized logging
- ETL scripts (Python) — loading and syncing football data

---

## 3. Data Sources & Licensing

| Source | Purpose | License / Terms | Attribution required |
|---|---|---|---|
| **OpenFootball** (GitHub) | Initial bulk load | Usually Public Domain / ODbL (varies by sub-repo) | Check per sub-dataset; link source |
| **Kaggle datasets** | Initial bulk load | Varies by author (CC0, CC-BY, custom) | Check license per specific dataset before use |
| **StatsBomb Open Data** | Analytics (optional) | StatsBomb's own license (attribution required, non-commercial) | Yes, per StatsBomb's terms |
| **Wikidata / Wikipedia (SPARQL)** | Biographies, reference data | CC0 (public domain) | Not legally required, but good practice |
| **football-data.org** | Recurring live sync | Attribution required, terms vary by tier | Yes |
| **API-Football (RapidAPI)** | Additional live source | Own Terms of Service | Check storage/redistribution terms |
| **TheSportsDB** | Cross-check / deduplication | Own terms, crowd-sourced data | Check redistribution terms |

**Strategy:** bulk-load from static datasets on bootstrap → incremental sync
via API on a schedule.

**Documentation requirements:**
1. A dedicated `DATA_SOURCES.md` file — source → link → license → what data
   is pulled from it (reference data, history, live sync)
2. ETL script headers — comment noting the source and the date the license
   was last checked
3. The repository `LICENSE` (e.g. MIT) explicitly covers the **code**, not
   the data itself, which may carry its own terms
4. Where a dataset requires non-commercial use (e.g. StatsBomb), the README
   explicitly states this is a learning/portfolio project, not for
   commercial use

---

## 4. Data Schema (draft)

```sql
countries        (id, name, code, confederation)
cities           (id, name, country_id)
stadiums         (id, name, city_id, capacity, built_year, coordinates)
clubs            (id, name, founded_year, stadium_id, country_id)
club_history     (club_id, season, league_id, position, name_at_time)
competitions     (id, name, type, country_id)
seasons          (id, competition_id, year_start, year_end)
players          (id, first_name, last_name, birth_date, birth_city_id,
                   nationality_id, position, height, weight)
player_career    (player_id, club_id, season_id, transfer_type, fee)
matches          (id, season_id, home_club_id, away_club_id,
                   stadium_id, date, referee_id)          -- partitioned by season
match_events     (id, match_id, player_id, type, minute)  -- partitioned by year
referees         (id, first_name, last_name, nationality_id)
standings        (season_id, club_id, matchday, points,
                   wins, draws, losses, gf, ga)
```

**Techniques to demonstrate:**
- Partitioning `matches` / `match_events` by season/year
- Composite and partial indexes for common query patterns
- Materialized views for league standings
  (`REFRESH MATERIALIZED VIEW CONCURRENTLY` on a schedule)
- Staging tables with JSONB for raw API responses before normalization
- Schema migrations as code (Sqitch/Flyway) — versioned DDL

---

## 5. Repository Structure

```
postgres-pitch/
├── .github/workflows/
│   ├── lint.yml                # tflint, ansible-lint, sqlfluff, shellcheck, ruff
│   ├── molecule-test.yml       # Ansible role tests
│   └── deploy-infra.yml        # cloud CI/CD (optional)
├── docs/
│   ├── architecture.md         # target architecture + status
│   ├── architecture.png
│   ├── disaster-recovery.md    # PITR / runbook
│   ├── decisions/              # ADRs: 0001-patroni-vs-repmgr.md, etc.
│   └── performance-notes.md    # before/after, optimization results
├── docker-compose/              # Phase 1: local stack
│   ├── docker-compose.yml
│   └── bootstrap.sh
├── terraform/                   # Phase 3: cloud
│   ├── modules/                 # network, compute, storage
│   ├── environments/{dev,prod}/
│   └── main.tf / variables.tf / outputs.tf
├── ansible/                     # Phase 2: configuration
│   ├── group_vars/
│   ├── roles/
│   │   ├── postgresql/
│   │   ├── patroni/
│   │   ├── etcd/
│   │   ├── pgbouncer/
│   │   ├── haproxy/
│   │   ├── pgbackrest/
│   │   ├── security/            # pg_hba, roles, TLS, pgAudit
│   │   ├── monitoring/
│   │   └── data-sync/           # ETL job scheduling
│   └── site.yml
├── config/
│   ├── postgres/postgresql.conf # with rationale comments
│   ├── postgres/pg_hba.conf
│   └── pgbouncer/pgbouncer.ini
├── monitoring/
│   ├── prometheus/alert.rules.yml
│   └── grafana/dashboards/
├── db/
│   ├── migrations/              # Sqitch/Flyway DDL migrations
│   └── seed/                    # bulk-load scripts (OpenFootball, Kaggle)
├── scripts/
│   ├── etl/
│   │   ├── sync_football_data.py    # recurring live sync
│   │   ├── bulk_load.py             # initial load
│   │   └── data_quality_check.py    # cross-source validation
│   ├── check_replication_lag.py
│   ├── verify_backup_restore.py     # backup quality verification
│   └── slow_query_report.py         # pg_stat_statements analysis
├── tests/
│   ├── load_test.py             # pgbench/locust at realistic volumes
│   ├── failover_test.sh
│   └── chaos/                   # kill primary, network partition, disk full
├── .editorconfig
├── .pre-commit-config.yaml
├── .sqlfluff
├── .env.example
├── .gitignore
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
├── Makefile
├── requirements.txt
├── requirements-linux.txt
├── DATA_SOURCES.md
├── ROADMAP.md
└── README.md
```

---

## 6. Roadmap by Iteration (git flow)

### Iteration 0 — Bootstrap ✅ (released as v0.1.0)
- [x] `feat: init repo structure, README skeleton, ROADMAP, architecture.md (target)`
- [x] Set up `.pre-commit-config.yaml` (detect-private-keys, terraform fmt)
- [x] `.env.example`, `.gitignore`
- [x] Initial database schema + ADR 0001
- [x] Full folder skeleton for all planned components
- [x] CI lint pipeline (GitHub Actions + pre-commit)
- [x] `../requirements.txt` and local dev setup docs

### Iteration 1 — Local cluster skeleton
- [ ] `feat(docker): 3-node Patroni + etcd + PgBouncer + HAProxy locally`
- [ ] Bootstrap script that brings up the whole stack with one command
- [ ] Verify manual failover (kill primary → re-election → HAProxy switches over)
- [ ] Update README with a verified Quick Start

### Iteration 2 — Data: initial load
- [ ] `feat(db): base reference schema (countries, cities, stadiums, clubs)`
- [ ] `feat(db): migrations via Sqitch/Flyway`
- [ ] `feat(etl): bulk_load.py — import OpenFootball + Kaggle datasets`
- [ ] Populate the database with real historical data (several leagues, several seasons)
- [ ] `docs: DATA_SOURCES.md with licenses and attribution`

### Iteration 3 — Observability
- [ ] `feat(monitoring): prometheus, postgres_exporter, patroni metrics`
- [ ] `feat(monitoring): grafana dashboards (replication, connections, vacuum/bloat)`
- [ ] Dashboard screenshots added to README

### Iteration 4 — Backups and Disaster Recovery
- [ ] `feat(backup): pgBackRest + S3/Storage backend`
- [ ] `feat(scripts): verify_backup_restore.py — automated restore + checksum`
- [ ] `docs: disaster-recovery.md — PITR runbook`

### Iteration 5 — Security
- [ ] `feat(security): SCRAM-SHA-256, pg_hba hardening`
- [ ] `feat(security): role-based access, least privilege`
- [ ] `feat(security): pgAudit, TLS between nodes`
- [ ] `feat(security): Row-Level Security demo`

### Iteration 6 — Scheduled ETL jobs
- [ ] `feat(etl): sync_football_data.py — recurring sync with football-data.org`
- [ ] `feat(ansible): data-sync role — pg_cron or systemd timer`
- [ ] `feat(etl): data_quality_check.py — cross-source validation`
- [ ] `feat(monitoring): alert on stale data (ETL failure detection)`
- [ ] `feat(db): archiving/rotation of old seasons`

### Iteration 7 — Full-stack Ansible automation
- [ ] `feat(ansible): postgresql, patroni, pgbouncer, haproxy roles`
- [ ] `test(molecule): role tests`
- [ ] Apply the playbook against local VMs/containers

### Iteration 8 — Terraform + cloud
- [ ] `feat(terraform): network, security groups`
- [ ] `feat(terraform): compute modules for 3 DB nodes`
- [ ] `feat(terraform): dynamic inventory → ansible`
- [ ] Remote state backend with locking

### Iteration 9 — Performance
- [ ] `feat(scripts): slow_query_report.py — pg_stat_statements analysis`
- [ ] `feat(db): partitioning of matches/match_events`
- [ ] `feat(db): index optimization, removing unused indexes`
- [ ] `docs: performance-notes.md — before/after, pgbench results`

### Iteration 10 — Resilience and chaos
- [ ] `feat(tests): chaos scripts — kill primary, network partition, disk full`
- [ ] `feat(tests): failover_test.sh with downtime measurement`
- [ ] `docs: major version upgrade runbook (pg_upgrade)`

### Iteration 11 — CI/CD and polish
- [ ] `ci: lint pipeline (tflint, ansible-lint, sqlfluff, shellcheck, ruff)`
- [ ] `ci: molecule tests, docker-compose config validation`
- [ ] Final README, badges, screenshots
- [ ] Pin repository, fill in About section/tags on GitHub

---

## 7. Scheduled Operational Jobs

| Job | Frequency | Mechanism |
|---|---|---|
| Sync results/standings from football-data.org | Daily | pg_cron / systemd timer → Python ETL |
| Cross-source data validation (DQ report) | Weekly | Python script → report |
| VACUUM ANALYZE / REINDEX | Scheduled | pg_cron or Ansible cron role |
| Backup restore verification | Weekly | verify_backup_restore.py |
| Data freshness monitoring | Continuous | Prometheus alert |
| Archiving old seasons | Annually / on demand | Script + partitioning |

---

## 8. README Structure (updated as features land)

1. Title, badges (Build, License, Postgres version, Python version)
2. Architecture diagram + Key Features
3. Quick Start (only steps that are actually verified)
4. Verification & Testing (replication, failover, backup checks)
5. Monitoring & Dashboards (Grafana screenshots)
6. Data Sources (where the data comes from, how it's refreshed — links to `DATA_SOURCES.md`)
7. Design Decisions / Trade-offs (links to ADRs)

---

## 9. Documentation Discipline

- **Upfront:** repo folder structure (empty dirs with `.gitkeep` are fine),
  this `PROJECT_PLAN.md` / `ROADMAP.md`, `docs/architecture.md` as the
  target picture with status markers
- **As you go:** README (only what actually works), ADRs (written at the
  moment a decision is made), detailed docs per service, `DATA_SOURCES.md`
  (updated whenever a new source is integrated)
- **Language:** all documentation, comments, and commit messages in English
- Never describe a step in Quick Start that hasn't just been verified by hand
