# ADR 0001: Initial Schema Design Decisions

**Status:** Accepted
**Date:** 2026-09-19

## Context

The database needs to hold real football reference data, club/player
history, and match-level data at a scale large enough to make indexing and
partitioning decisions meaningful (several leagues, multiple seasons,
match events).

## Decisions

### 1. Partition `matches` and `match_events` by year (RANGE on `match_date`)

Match data grows continuously and is heavily queried by recent time ranges
(current season, current matchday) while older seasons are read far less
often. Partitioning by year:
- keeps operational queries against recent partitions fast (partition pruning),
- makes archiving old seasons a metadata operation (`DETACH PARTITION`)
  instead of a bulk `DELETE`,
- gives a natural, defensible reason to demonstrate partition maintenance
  as an operational task (see ROADMAP.md, Iteration 9).

`match_events` carries a **denormalized** `match_date` column so it can be
partitioned on the same axis as `matches`, and so the two tables can be
joined via a composite foreign key `(match_id, match_date)`. This trades a
small amount of redundancy for consistent partition pruning across both
tables — the alternative (partitioning only `matches`, leaving
`match_events` unpartitioned) would make time-range queries across events
slower as the table grows.

Partitions are currently created manually for 2024–2026 plus a `DEFAULT`
partition as a safety net. In a later iteration this will move to a
scheduled job (pg_partman or a custom Ansible/cron task) that creates the
next year's partition ahead of time — see ROADMAP.md, Iteration 6.

### 2. `standings` is a materialized view, not a table

League standings are fully derivable from `matches`. Storing them as a
separate mutable table would create a second source of truth that can
drift out of sync with match results. A materialized view:
- guarantees standings are always a correct function of match data,
- is refreshed on a schedule (`REFRESH MATERIALIZED VIEW CONCURRENTLY`),
- avoids write amplification on every single match result update.

### 3. Composite primary keys on partitioned tables

PostgreSQL requires the partition key to be part of the primary key (and
of any unique constraint) on a partitioned table. This is why `matches`
uses `PRIMARY KEY (id, match_date)` instead of a plain `id` — a direct
consequence of the partitioning decision.

### 4. `external_ref JSONB` columns on `clubs`, `players`, `matches`

Since data is synced from multiple third-party APIs with different ID
schemes, each entity keeps a small JSONB column storing external IDs
(e.g. `{"football_data_org": 123, "openfootball": "eng-premier-league"}`).
This supports deduplication and incremental sync without a rigid
per-source column, at the cost of that field not being indexed/validated
as strictly as a normal foreign key.

### 5. Referees, stadiums, and cities are separate reference tables

Kept as reference data (see also `countries`) rather than free-text fields
on `matches`/`clubs`. This is a small amount of extra join complexity in
exchange for consistent reference data and cleaner deduplication when
importing from multiple sources.

## Alternatives Considered

- **Single flat `matches` table with home/away team names as text** —
  rejected: no referential integrity, harder to deduplicate across data
  sources, no partition-pruning benefit that matters for a normalized model.
- **Storing standings as a regular writable table, updated by a trigger on
  every match result** — rejected in favor of a materialized view: a
  trigger-maintained table is more moving parts for the same guarantee a
  scheduled refresh already provides, and it complicates bulk backfills.
- **`repmgr` instead of Patroni for cluster orchestration** — not part of
  this ADR; will be documented separately when the HA cluster is built
  (see ROADMAP.md, Iteration 1).

## Consequences

- Adding a new partition (new year) requires an explicit operational step
  until automation lands in Iteration 6.
- Standings queries always hit the materialized view, not `matches`
  directly — application code and ETL scripts need to know to call
  `REFRESH MATERIALIZED VIEW CONCURRENTLY standings;` after loading new
  results.
- The composite primary key on `matches`/`match_events` means any future
  foreign key referencing a specific match row must include `match_date`,
  not just `id`.
