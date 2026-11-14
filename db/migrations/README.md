# migrations

Versioned schema migrations, managed with [Sqitch](https://sqitch.org/). Why
Sqitch, and why it connects through a session-mode PgBouncer alias, is in
[ADR 0004](../../docs/decisions/0004-sqitch-for-schema-migrations.md).

## Running

```bash
make migrate          # deploy pending changes to the current primary
make migrate-status   # what is deployed
make migrate-verify   # run every change's verify script
```

Sqitch runs as the `sqitch` service of `docker-compose/docker-compose.yml` (not
started by `make up`), so nothing is installed on the host. It connects through
HAProxy `:5000` to the `postgres_pitch_migrations` alias, so it follows the
current primary on its own. `make migrate` is idempotent: with nothing pending it
reports "Nothing to deploy".

## Layout

```
db/migrations/
  sqitch.conf     # project configuration (no credentials)
  sqitch.plan     # ordered list of changes
  deploy/         # <change>.sql: apply the change
  revert/         # <change>.sql: undo it
  verify/         # <change>.sql: check it was applied (read-only)
```

## The baseline

The first seven changes reproduce [`db/schema/001_initial_schema.sql`](../schema/001_initial_schema.sql)
exactly (`tests/migrate_test.sh` compares `pg_dump --schema-only` of both).
That script is kept, frozen, as the reference for this comparison; do not edit it.

| Change | Contains |
|---|---|
| `enum_types` | the five enumerated types |
| `reference_tables` | countries, cities, stadiums, referees |
| `clubs_competitions_seasons` | clubs, competitions, seasons, club history |
| `players_and_careers` | players, player careers |
| `matches_and_events` | matches and match events, partitioned by year (2024-2026 plus default) |
| `standings_view` | the standings materialized view and its unique index |
| `indexes` | secondary indexes |

## Changes after the baseline

| Change | Contains |
|---|---|
| `yearly_partitions` | a yearly partition of `matches` and `match_events` for every year from 1872 to 2027 (the baseline has 2024-2026 plus the default one). Why this range: [DATA_SOURCES.md](../../DATA_SOURCES.md) |

## Partitions

Partitions are named `<table>_<year>` (`matches_1872`, `match_events_2027`) and
cover one calendar year in UTC. Three things to know before adding or removing
one (all checked on PostgreSQL 16.15):

- **Write the bounds with an explicit offset**, for example
  `FROM ('2028-01-01 00:00:00+00') TO ('2029-01-01 00:00:00+00')`. A bare
  `'2028-01-01'` on a `TIMESTAMPTZ` column means midnight in the time zone of
  the session that runs the statement, so the partition would depend on where it
  was created. A partition built that way next to UTC ones fails with an overlap
  error.
- **Create a partition before data for its year arrives.** Rows outside every
  partition go to the default one, and then
  `CREATE TABLE ... PARTITION OF` for that range fails with "updated partition
  constraint for default partition ... would be violated by some row". An empty
  year is no problem. The rows have to be moved out of the default partition
  first.
- **A partition of `matches` cannot be dropped directly**, because
  `match_events` has a foreign key to it. Detach it first:
  `ALTER TABLE matches DETACH PARTITION matches_1900; DROP TABLE matches_1900;`.
  Partitions of `match_events` can be dropped directly (its own revert does it).

## Adding a change

Run these from `docker-compose/`. Pass your own name and e-mail so the plan
records who planned the change.

```bash
docker compose --env-file ../.env run --rm \
  -e SQITCH_FULLNAME="Your Name" -e SQITCH_EMAIL=you@example.com \
  sqitch add <change_name> -r <change_it_depends_on> -n "what it does"
```

This creates `deploy/<change_name>.sql`, `revert/<change_name>.sql` and
`verify/<change_name>.sql` and adds a line to `sqitch.plan`. Then:

1. Write the three scripts. `deploy` and `revert` run in an explicit
   `BEGIN; ... COMMIT;`, `revert` undoes exactly what `deploy` did, and `verify`
   only reads and fails if the change is missing. It has to stay true after
   later changes, so it must not count objects that a later change may add (the
   baseline `matches_and_events` once asserted exactly four partitions, which
   `yearly_partitions` broke).
2. Apply and check it: `make migrate`, then `make migrate-verify`.
3. Check the revert on a development database:
   `docker compose --env-file ../.env run --rm sqitch revert --to <previous_change>`
   (it asks for confirmation), then `make migrate` again.
4. Follow the SQL style enforced by `sqlfluff` in pre-commit (upper-case keywords
   and type names, as in the existing scripts).

Never edit a change that has been deployed: add a new one.

On Linux, files created by `sqitch add` belong to the container's user; run
`chown` on them if you cannot edit them.

## A database created before Sqitch (the old `make schema`)

If the schema is already there but Sqitch has never run, `make migrate` fails
with "already exists". Either start over (`make reset`, `make up`, `make migrate`),
or adopt the existing schema without running the scripts:

```bash
cd docker-compose
docker compose --env-file ../.env run --rm sqitch deploy --log-only
make -C .. migrate-verify      # confirms the objects are really there
```

## Conventions

- One logical change per Sqitch change; lowercase `snake_case` names that say
  what the change does.
- No credentials in `sqitch.conf` or in the plan: the connection comes from the
  environment (see the `sqitch` service).
- Reverting is destructive; it is not part of `make` on purpose.

## Tests

- `bash tests/migrate_test.sh`: the baseline equals `001`, revert and redeploy,
  the later changes deploy, verify and revert back to exactly `001`,
  `make migrate` is a no-op the second time, default privileges, and the same
  after a switchover.
- `bash tests/partitions_test.sh` (`make partitions-test`): the yearly partitions
  exist with UTC bounds, rows at year edges land in the right partition, a date
  range reads only its partitions, and the roles have the right privileges on
  them.
- `bash tests/migration_path_test.sh`: how Sqitch reaches the cluster (ADR 0004).
