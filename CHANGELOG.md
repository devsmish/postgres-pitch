# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Versions are tagged on `main` as part of the release process described in
[CONTRIBUTING.md](./CONTRIBUTING.md) (`release/x.y.z` branches merged from
`develop`).

## [Unreleased]

## [0.2.0] - 2026-10-14

Iteration 1 - local cluster skeleton: a three-node Patroni/PostgreSQL
cluster with etcd, PgBouncer and HAProxy that starts with one command and
whose failover has been verified end to end.

### Added
- Local Docker Compose stack: 3-node Patroni/PostgreSQL 16 cluster on a
  3-member etcd, with synchronous replication (one synchronous standby)
  and `pg_rewind` for rejoining nodes, plus `make` targets for everyday
  work (`up`, `down`, `reset`, `logs`, `status`, `leader`, `psql`) (#8)
- ADR 0002: the synchronous replication trade-off (durability vs. write
  latency) (#8)
- HAProxy routing with two endpoints, driven by Patroni's REST health
  checks: write (`:5000`, always the current primary) and read-only
  (`:5001`, load-balanced across replicas); one PgBouncer per node in
  transaction pooling mode behind it (#9)
- Demo roles `analytics_readonly` and `etl_writer` (plus the technical
  `pgbouncer_auth` role for `auth_query`), created in `post_bootstrap.sh`;
  `docs/access-patterns.md` (#9)
- `tests/access_patterns_test.sh` (`make access-test`): verifies routing
  and both roles on both endpoints, before and after a real
  `patronictl switchover` (#9)
- `docker-compose/bootstrap.sh`: starts the stack and waits until Patroni
  reports a healthy cluster and both HAProxy endpoints answer, with a
  timeout, diagnostics on failure and next steps on success (#10)
- `docs/failover-notes.md`: measured failover timings and the assertions
  behind them (#11)
- README Quick Start with a Verification section (replication, routing and
  roles, failover), with bash and PowerShell variants (#12)
- `.gitattributes` enforcing LF line endings across platforms (#14)
- ADR 0003, `.pre-commit-config-ansible.yaml` and `make lint-ansible`
  (#13)

### Changed
- `make up` runs `docker-compose/bootstrap.sh` instead of a bare
  `docker compose up` (#10)
- `tests/failover_test.sh` verifies failover end to end: the synchronous
  standby is promoted, the write endpoint follows with the same connection
  string, the read-only endpoint serves replicas only, fresh sessions of
  both demo roles work, and the old primary rejoins; it prints the timings
  and always restarts the killed node (#11)
- `ansible-lint` moved out of the default pre-commit config into its own
  config that CI runs on Linux, so `git commit` works on native Windows
  without `SKIP=ansible-lint`; the hook is now scoped to `ansible/`
  instead of linting the whole repository (#13)
- `docs/architecture.md` status table and `ROADMAP.md` updated: PostgreSQL,
  Patroni + etcd, PgBouncer and HAProxy marked as verified, Iteration 1
  complete (#12)

### Fixed
- `post_bootstrap.sh` could not find the admin username (Patroni does not
  forward `PATRONI_*` variables to it), so the first bootstrap failed and
  left nodes with different system IDs and a node in a restart loop;
  `POSTGRES_USER` is now passed explicitly, with a fallback to
  `current_user` (#9)
- PgBouncer kept rejecting a recovered replica after a switchover because
  it caches a failed server login for 15 seconds by default;
  `server_login_retry` is now 1 second (#9)
- Replica creation took about 100 seconds on an empty cluster because
  `pg_basebackup` waited for a spread checkpoint; Patroni now requests a
  fast one (#10)
- `tests/*.sh` broke under Git Bash on Windows (it rewrote container paths
  such as `/etc/patroni.yml`) (#9, #11)
- `ansible-lint` was linting every YAML file in the repository because the
  upstream hook ignores `files:` filters, which made CI report style
  errors in `docker-compose/docker-compose.yml` (#13)

## [0.1.0] - 2026-09-20

### Added
- Repository bootstrap: README, MIT LICENSE (with data-sourcing disclaimer),
  `.gitignore`, `DATA_SOURCES.md`
- Project roadmap (`ROADMAP.md`) with the full iteration plan and
  `docs/architecture.md` target architecture with per-component status
- Initial database schema (`db/schema/001_initial_schema.sql`): reference
  data, clubs/competitions/seasons, players/careers, partitioned
  `matches`/`match_events`, `standings` materialized view
- ADR 0001: schema design decisions (partitioning strategy, materialized
  view for standings, composite primary keys)
- Full project folder skeleton for all planned components (Docker Compose,
  Terraform, Ansible, config, monitoring, db, scripts, tests), each
  documented with a short README
- `.env.example`, `.editorconfig`, `Makefile`
- Contribution workflow: Git Flow branching model, Conventional Commits,
  PR and issue templates (`CONTRIBUTING.md`)
- CI lint pipeline (GitHub Actions): pre-commit running Terraform, Ansible,
  SQL, shell, and Python linters on every push and pull request
- `../requirements.txt` and local development setup instructions
  (venv + pre-commit) in `CONTRIBUTING.md`

### Fixed
- `ansible-lint` pre-commit hook missing `ansible-core` dependency,
  causing `ModuleNotFoundError` in CI
- SQL schema formatting brought in line with `sqlfluff` defaults
  (spacing, indentation, consistent type capitalization); `.sqlfluff`
  config added to set line-length and capitalization policy explicitly

[Unreleased]: https://github.com/devsmish/postgres-pitch/compare/v0.2.0...develop
[0.2.0]: https://github.com/devsmish/postgres-pitch/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/devsmish/postgres-pitch/releases/tag/v0.1.0
