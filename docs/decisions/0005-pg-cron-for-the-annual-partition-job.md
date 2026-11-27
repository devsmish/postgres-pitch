# ADR 0005: pg_cron schedules the annual partition job, and the work itself is a SQL function

**Status:** Proposed. It becomes Accepted when part B of "Spike results" (the
run on the real cluster) is filled in.
**Date:** 2026-11-24

## Context

`matches` and `match_events` are partitioned by year (change
`yearly_partitions`, one partition for every year from 1872 to 2027). A row
whose year has no partition goes to the default partition, and from then on
creating that year's partition fails until the rows are moved out (see
`../../db/migrations/README.md`). So the partitions have to exist **before** the
data for their year arrives, and seasons span two calendar years: fixtures of
the next year are loaded during the current one.

The rule from the Iteration 2 plan: partitions for the current and the next
calendar year always exist. A job on **31 December at 20:00 UTC** (Greenwich,
not Europe/London) ensures the partitions through the current year + 2, so the
new year starts with itself and the following one in place.

What the mechanism has to do:

- run **once**, on whichever node is the **primary** at that moment;
- keep doing so after failovers, without a manual step;
- fit the other scheduled jobs of ROADMAP section 7;
- be testable in this setup (Docker Compose on Windows and macOS).

## Decision

1. **The work is a SQL function**, `create_year_partitions(from_year, to_year)`,
   deployed by the Sqitch change `create_year_partitions`. It creates the
   missing yearly partitions of both tables in the same way as
   `yearly_partitions` (names `<table>_<year>`, UTC bounds), returns how many
   tables it created (0 when nothing was missing, so running it twice is
   harmless), and is atomic. It refuses a `to_year` more than 10 years ahead, fails on a
   table that has a partition's name but is not that partition, uses a
   `lock_timeout` of 10 s, and takes an advisory lock so a manual run and the
   job cannot overlap. Only the owner may run it. The function does not depend
   on the scheduler: the job, a person, a test or the loader (#27-#29) can all
   call it.
2. **The scheduler is pg_cron.** One job, `ensure-year-partitions`, schedule
   `0 20 31 12 *`, command
   `SELECT public.create_year_partitions(y, y + 2)` with `y` the current UTC
   year: it creates what is missing from this year through the year after
   next. It is created by the Sqitch change `partition_job` of this issue.
3. **pg_cron is set up like this:**
   - the package `postgresql-16-cron` is installed in the Patroni image;
   - `patroni.yml` sets, for all nodes: `shared_preload_libraries = pg_cron`,
     `cron.database_name = postgres_pitch`, `cron.use_background_workers = on`,
     `cron.timezone = UTC` and `max_worker_processes = 16`;
   - **background workers** are used because pg_cron's default mode opens a
     libpq connection to the database, and this project's `pg_hba` asks for a
     password on every TCP connection; background workers connect to nothing.
4. **`partition_job` only acts in the database pg_cron serves.** pg_cron
   lives in exactly one database (`cron.database_name`), while
   `tests/migrate_test.sh` deploys the whole plan into scratch databases. In
   any other database the change prints a notice and does nothing; in the
   cluster database it creates the extension and the job.
5. **Scope.** This decision covers SQL-only jobs in this database: this one,
   and possibly VACUUM/REINDEX, archiving of old seasons and materialized view
   refreshes later. The Python ETL jobs of Iteration 6 are **not** decided
   here: pg_cron cannot run Python, and a systemd timer or a scheduler
   container is the natural place for them.

## Alternatives

- **A scheduler container** (for example supercronic running `psql` through
  the write endpoint `:5000`). It needs no change to PostgreSQL, can run Python
  too, and would also follow the primary, because HAProxy does. It is one more
  process to keep alive and monitor, and the job definition lives outside the
  database, so it is neither replicated nor in the backups. Not chosen for this
  job because it is plain SQL; a good candidate for the Python jobs.
- **A systemd timer** (the ROADMAP lists it for the ETL jobs). It cannot be run
  or verified in the Compose environment, which has no systemd; it belongs to
  the Ansible work of Iteration 7.
- **pg_partman.** It manages partition creation and retention with its own
  naming and metadata, and it would have to adopt the 156 existing partitions
  per table. It adds an extension for about twenty lines of SQL. Not tried here.

## Spike results

### Part A: reproduced outside the cluster

Setup: Ubuntu 24.04, PostgreSQL 16.15, **pg_cron 1.6.2** (the image gets the
version of the PostgreSQL apt repository, so this is re-checked in part B),
Sqitch 1.4.1. No Docker and no Patroni: a primary and a streaming replica
(`pg_basebackup -R`) set up by hand, with the pg_cron settings of decision 3.

| Scenario | Result |
|---|---|
| A job every 5 s while a replica streams | Only the primary runs it: 5 runs in 25 s, all with `pg_is_in_recovery() = false`. The replica received the rows and the job definition by replication and ran nothing |
| Primary stopped, replica promoted, nothing reconfigured or restarted | The job went on on the promoted node: 4 runs on the old primary, then 4 on the new one, every 5 s. All 16 runs in `cron.job_run_details` have the status `succeeded` |
| The real job command fired by pg_cron every 5 s | `succeeded` |
| The deploy script of `partition_job` run again | Still one job (a job with the same name is updated in place) |
| `partition_job` in a database pg_cron does not serve, and on a PostgreSQL without pg_cron loaded | Skipped with a notice, `verify` and `revert` pass. After reverting the later changes the schema dump equals `001_initial_schema.sql`, as `migrate_test.sh` requires |
| `create_year_partitions` | Creates 2 tables for a new year, then returns 0; fails on a year too far ahead, on a `NULL`, on a name taken by an ordinary table, and when the default partition holds rows of that year (nothing is left half done); `etl_writer` and `analytics_readonly` get `permission denied for function` |
| Moving rows out of the default partition (the runbook procedure) | 2 matches and 1 event moved to the new year's partitions, ids kept, default partitions empty |
| Lock taken by `CREATE TABLE ... PARTITION OF` | `ACCESS EXCLUSIVE` on `matches` and on `matches_default` |
| A long query holds `matches`; the function waits for its lock | An ordinary `SELECT` on `matches` started meanwhile waited 8.1 s (the rest of the 10 s wait), 0.2 s afterwards. The function gave up after 10.0 s and created nothing |
| `cron.database_name` names a database that does not exist yet (the situation at the first start of a new cluster, before `post_bootstrap.sh` creates `postgres_pitch`) | The server starts normally. The pg_cron launcher logs `FATAL: database "..." does not exist` about once a second and retries. When the database exists and has the extension, jobs run without a restart (2 runs within 14 s) |
| `CREATE DATABASE x TEMPLATE <the pg_cron database>` | Fails: `source database is being accessed by other users` (the pg_cron worker keeps a session there) |

### Part B: on the real cluster (to be filled in)

Rebuild the image and recreate the cluster (the parameters of decision 3 reach a
cluster only when it is bootstrapped; see
`../runbooks/partition-maintenance.md`), then run the three commands below.
Paste the result rows here.

| Check | Result |
|---|---|
| `make up` builds the image with `postgresql-16-cron` from the apt repository of the official `postgres:16-bookworm` image, and the three nodes start | _pending_ |
| `make migrate`, then `make partitions-test` (parts 5 and 6: the rule, the function, pg_cron preloaded on all three nodes, the job registered, a probe job fires) | _pending_ |
| `make migrate-test`, part 4: a probe job scheduled before a real `patronictl switchover` keeps running on the new primary | _pending_ |
| Version of pg_cron installed in the image | _pending_ |

## Consequences

- `Dockerfile` and `patroni.yml` change. The new parameters are part of the
  Patroni DCS bootstrap settings, which apply only when a cluster is created,
  so an existing cluster has to be recreated (`make reset`). That is cheap now,
  before the initial load has put data into it.
- A new cluster logs one `FATAL: database "postgres_pitch" does not exist` line
  per second from the pg_cron launcher until `post_bootstrap.sh` has created
  the database. It is noise, not an error of the cluster.
- The job is data in the database (`cron.job`): it is replicated and is in the
  backups, and it follows the primary without any extra component.
- pg_cron keeps one session open in the cluster database, so that database can
  no longer be used as a template for `CREATE DATABASE`.
- This design does not rely on pg_cron repeating a run that fell into a
  failover window (about 30 s; not tested here). The safety net is the rule
  check of `make partitions-test` (part 5) and a manual
  `SELECT create_year_partitions(...)` (see the runbook); the monitoring alert
  of Iteration 4 should check the same rule.
- `partition_job` is silent in databases pg_cron does not serve. That is also
  what happens in the cluster database if the cluster was not recreated, which
  is why `make partitions-test` fails loudly when the job is missing.
- Iteration 7 (Ansible): the `postgresql` role has to install the package and
  set the same parameters.

## Not verified

- The image build: the package name and availability on Debian bookworm, and
  the pg_cron version it brings.
- pg_cron in its default mode (libpq); only background workers were tried.
- The behavior of pg_cron for a run that falls into a failover window.
- Everything about the real cluster: part B.
