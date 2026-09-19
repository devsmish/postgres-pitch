# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

Versions are tagged on `main` as part of the release process described in
[CONTRIBUTING.md](./CONTRIBUTING.md) (`release/x.y.z` branches merged from
`develop`).

## [Unreleased]

### Added
- Repository bootstrap: README, MIT LICENSE (with data-sourcing disclaimer),
  `.gitignore`, `DATA_SOURCES.md`
- Project roadmap (`ROADMAP.md`) with the full iteration plan
- Initial database schema (`db/schema/001_initial_schema.sql`): reference
  data, clubs/competitions/seasons, players/careers, partitioned
  `matches`/`match_events`, `standings` materialized view
- ADR 0001: schema design decisions (partitioning strategy, materialized
  view for standings, composite primary keys)
- Contribution workflow: Git Flow branching model, Conventional Commits,
  PR and issue templates (`CONTRIBUTING.md`)

<!--
## [0.1.0] - YYYY-MM-DD

### Added
### Changed
### Fixed
### Removed
-->
