# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Versions are tagged on `main` as part of the release process described in
[CONTRIBUTING.md](./CONTRIBUTING.md) (`release/x.y.z` branches merged from
`develop`).

## [Unreleased]

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
