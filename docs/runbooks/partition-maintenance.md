# Runbook: partition maintenance of `matches` and `match_events`

The why is in [ADR 0005](../decisions/0005-pg-cron-for-the-annual-partition-job.md).
Run the SQL below on the **primary** (`make leader` shows it, then
`make psql NODE=<that node>`): a replica can read all of it but cannot run DDL.

## What is in place

- One partition per year and table, named `<table>_<year>`, bounded at UTC
  midnight, for 1872 to 2027, plus a default partition each (change
  `yearly_partitions`).
- The rule: partitions for the **current and the next calendar year** always
  exist.
- The function `create_year_partitions(from_year, to_year)` creates what is
  missing and returns the number of tables it created (0 = nothing to do). It
  is safe to run again.
- The pg_cron job `ensure-year-partitions`: every **31 December at 20:00 UTC** it
  creates the partitions from the current year through the current year + 2. It
  runs on whichever node is the primary.

## Is it healthy?

`make partitions-test` checks all of it (part 5: the rule and the function;
part 6: pg_cron and the job). By hand:

```sql
-- the job: expect one row, active
SELECT jobid, jobname, schedule, active, database, username FROM cron.job;

-- its last runs (empty until the first 31 December has passed)
SELECT start_time, status, return_message
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'ensure-year-partitions')
ORDER BY start_time DESC LIMIT 5;

-- the partitions of the coming years
SELECT string_agg(c.relname, ' ' ORDER BY c.relname)
FROM pg_inherits AS i
INNER JOIN pg_class AS c ON i.inhrelid = c.oid
WHERE i.inhparent = 'matches'::regclass AND c.relname >= 'matches_2026';

-- the default partitions: both numbers must be 0 (rows there block creating
-- the partition of their year)
SELECT
    (SELECT count(*) FROM matches_default) AS matches_default,
    (SELECT count(*) FROM match_events_default) AS match_events_default;
```

## The job did not run, or the rule check fails

Create the partitions by hand. It is safe to repeat. In December 2027, for
example, the target is 2029:

```sql
SELECT create_year_partitions(2028, 2029);
```

If it fails, the message tells why:

| Message | Cause | What to do |
|---|---|---|
| `canceling statement due to lock timeout` | A long query holds `matches`; creating a partition needs an exclusive lock on it, and queries that arrive meanwhile queue behind that request, so the function gives up after 10 s | Find the query (`SELECT pid, state, query_start, left(query, 80) FROM pg_stat_activity WHERE query ILIKE '%matches%'`), wait for it or end it, run again |
| `updated partition constraint for default partition ... would be violated by some row` | Rows of that year are already in the default partition | Move them out first, see below |
| `public.matches_YYYY exists but is not a partition of public.matches` | An ordinary table has the name | Look at it, rename or drop it if it is not needed, run again |
| `refusing to create partitions for YYYY (more than 10 years ahead ...)` | `to_year` is more than 10 years ahead of this year | Use a nearer year, or fix the typo |

A call that fails changes nothing: it is one transaction.

## Moving rows out of the default partition

This happens when data for a year was loaded before its partition existed.
Run as the admin role (`etl_writer` cannot `DELETE`), in **one transaction**,
and replace `2035` with the year. The events go first because they refer to
the matches:

```sql
BEGIN;
CREATE TEMP TABLE moved_events ON COMMIT DROP AS
  SELECT * FROM match_events_default
  WHERE match_date >= '2035-01-01 00:00:00+00' AND match_date < '2036-01-01 00:00:00+00';
CREATE TEMP TABLE moved_matches ON COMMIT DROP AS
  SELECT * FROM matches_default
  WHERE match_date >= '2035-01-01 00:00:00+00' AND match_date < '2036-01-01 00:00:00+00';
DELETE FROM match_events_default
  WHERE match_date >= '2035-01-01 00:00:00+00' AND match_date < '2036-01-01 00:00:00+00';
DELETE FROM matches_default
  WHERE match_date >= '2035-01-01 00:00:00+00' AND match_date < '2036-01-01 00:00:00+00';
SELECT create_year_partitions(2035, 2035);
INSERT INTO matches SELECT * FROM moved_matches;
INSERT INTO match_events SELECT * FROM moved_events;
COMMIT;
```

The ids are kept. Afterwards both default partitions should hold no rows of
that year.

## After a failover

Nothing to do: the job is data in the database, and pg_cron runs it on
whichever node is the primary. `make migrate-test` (part 4) schedules a probe job
before a real switchover and checks that it keeps running on the new primary.

## pg_cron missing on an existing cluster

`make partitions-test` part 6 reports `pg_cron is not set up here` on a cluster
that was created before ADR 0005. The package is in the image, but the
parameters of `patroni.yml` (`shared_preload_libraries`, `cron.database_name`,
and the others) reach a cluster only when it is bootstrapped. While no data has
been loaded, recreate it:

```bash
make reset      # removes the data directories
make up         # rebuilds the image (docker compose up -d --build) and starts the cluster
make migrate    # deploys all changes and schedules the job
make partitions-test
```

Once data has been loaded, `make reset` is not an option. Changing the
parameters in place (`patronictl edit-config`) and restarting the members
should work too, but it has not been tried here, and the image has to be
rebuilt first.

`cron.database_name` must be the database named in `POSTGRES_DB` of `.env`
(default `postgres_pitch`); it is written literally in `patroni.yml`.

## Removing or pausing the job

```sql
SELECT cron.unschedule('ensure-year-partitions');
```

This is what reverting the change `partition_job` does. Deploying it again
creates the job again. The pg_cron extension stays either way.
