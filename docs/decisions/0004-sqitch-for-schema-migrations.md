# ADR 0004: Sqitch for schema migrations, connected through a session-mode PgBouncer alias

**Status:** Proposed. It becomes Accepted when part B of "Spike results"
(the run on the real cluster) is filled in.
**Date:** 2026-10-18

## Context

The schema from ADR 0001 lives in one bootstrap script,
`../../db/schema/001_initial_schema.sql`, applied by `make schema`. Iteration 2 turns
it into versioned migrations and loads real data, so every later schema change
will go through the migration tool. The ROADMAP named "Sqitch/Flyway" without a
decision.

The tool has to work with the cluster as it is, not with a single local
database. Clients reach the primary through HAProxy (`:5000`), which routes to
a PgBouncer instance running in **transaction pooling** mode, which talks to
PostgreSQL. Development happens on Windows and macOS, so nothing should have to
be installed on the host.

## Decision

1. **Use Sqitch.** It keeps migrations as plain SQL with a `deploy`, a `revert`
   and a `verify` script per change, which fits a project about operating
   PostgreSQL. Flyway Community was the alternative (see below).
2. **Run it from its official Docker image** (`sqitch/sqitch`, AMD64 and
   ARM64), so Windows and macOS hosts need no Perl or Sqitch install.
3. **Connect through the write endpoint `:5000`, but to a dedicated PgBouncer
   database alias in session mode**, not to the normal transaction-mode
   database. The alias is added to each `pgbouncer*.ini`:

   ```ini
   postgres_pitch_migrations = host=postgresqlN port=5432 dbname=postgres_pitch pool_mode=session
   ```

   Migrations still follow the current primary (HAProxy's health checks),
   and nothing else changes for applications. Only migrations use the alias.
4. The conventions below fix where the files live and how changes are named.

### Why not the normal transaction-mode database

Sqitch's PostgreSQL engine (App::Sqitch 1.4.1, `Engine::pg`) relies on session
state, which transaction pooling does not preserve between statements:

- `SET search_path = sqitch` and `SET client_min_messages = WARNING` right
  after connecting; later queries against the registry depend on the
  `search_path`.
- A **session-level advisory lock** (`pg_advisory_lock(75474063)`) to make
  sure only one Sqitch runs at a time.
- Server-side prepared statements (`pg_server_prepare => 1`).

With transaction pooling, the next statement may be served by a different
server connection that never saw the `SET`, and the advisory lock stays on the
server connection after the client is gone (PgBouncer does not run
`server_reset_query` in transaction mode by default). The experiments below
show both effects. In session mode PgBouncer keeps one server connection per
client session and resets it when the client leaves, which is what Sqitch
expects.

## Options considered

| Option | Outcome |
|---|---|
| **Sqitch** | Chosen. `deploy` / `revert` / `verify` are first-class, SQL-native; needs the session-mode alias described above |
| Flyway Community | Not chosen, not tested here. Plain SQL versioned migrations, but its `undo` command needs the Teams edition or higher (Redgate product support, checked October 2026; re-check if this decision is revisited), so rollbacks would be hand-written forward migrations |
| Sqitch straight at PostgreSQL, bypassing PgBouncer | Works (baseline in the experiments) but needs a second, failover-aware path to the primary (for example another HAProxy frontend) and a new port; the alias reuses the existing path |

## Spike results

### Part A: reproduced outside the cluster

Setup: Ubuntu 24.04, PostgreSQL 16.15, **PgBouncer 1.22.0** (the project runs
1.25.1, so this is re-checked in part B), Sqitch 1.4.1, the project's
PgBouncer settings (`auth_type = md5`, `auth_query`, `pool_mode = transaction`)
and its `pg_hba` rule (`md5`). Two throwaway changes (a table, then an index
on it). Each cycle is `deploy`, `verify`, `revert -y`.

| Scenario | Result |
|---|---|
| Direct to PostgreSQL | deploy, status, verify, revert, deploy: all succeed |
| Through PgBouncer, transaction mode, pool size 20, no other clients | All commands succeed, **but the advisory lock `75474063` stays granted on an idle pooled server connection after Sqitch exits** |
| Through PgBouncer, transaction mode, pool size 2, four other clients running queries | **0 of 24 commands succeeded.** Observed: `relation "changes" does not exist`, `Registry is at version 0 but latest is 1.1` (the `search_path` is lost), `Blocked by another instance of Sqitch ... Timed out waiting 60 seconds` (leaked lock), and a lock still held on a pooled connection at the end |
| Through the session-mode alias, same load and pool size | **24 of 24 commands succeeded**, no advisory lock left behind |

The pool size 2 with four competing clients is a deliberately hard case; the
point is that correctness must not depend on which server connection a
statement happens to get. The quiet case above works only because a single
client keeps being handed the same server connection.

Registry and privileges (alias, same setup):

- Sqitch creates the schema `sqitch` with six tables: `changes`,
  `dependencies`, `events`, `projects`, `releases`, `tags`.
- `etl_writer` and `analytics_readonly` get `permission denied for schema
  sqitch`. The project's default privileges are defined `IN SCHEMA public`,
  so they do not reach the registry.
- A table created by a change in `public` picks up the project's default
  privileges: `etl_writer` can `INSERT` but not `DELETE`, `analytics_readonly`
  can `SELECT`.

### Part B: on the real cluster (to be filled in)

`../../tests/migration_path_test.sh` repeats the experiments on the running stack in
one command: it runs the Sqitch image on the cluster network against the alias,
does the full cycle, checks the registry and the default privileges, performs a
real `patronictl switchover` and repeats the cycle, and finally shows, for
information only, what the normal transaction-mode database does. It removes
everything it created. The alias must be in the three `pgbouncer*.ini` first
(see Consequences); the script checks for it and prints the exact lines if they
are missing. Paste the rows it prints here, and run it once on each platform
used (Windows, macOS).

| Check | Result |
|---|---|
| Versions: Sqitch image, PgBouncer in the stack, network | _pending_ |
| Cycle through `:5000` and the alias, registry privacy, default privileges, cycle after a switchover | _pending_ |
| Through the normal `postgres_pitch` database (information): commands that succeeded, advisory locks left on the primary | _pending_ |
| Platform the script was run on (Windows / macOS, Intel / ARM) | _pending_ |

## Conventions

- Location: `../../db/migrations`, created with
  `sqitch init pitch --engine pg`: `sqitch.conf`, `sqitch.plan`, and the
  directories `deploy/`, `revert/`, `verify/`.
- Change names: lowercase `snake_case`, one logical change each, named for
  what it does (for example `baseline_schema`, `partitions_2024_2026`). Order
  comes from the plan, not from file names.
- Every `deploy` and `revert` script runs in an explicit `BEGIN; ... COMMIT;`.
  `verify` scripts only read.
- A change that has been deployed is never edited; use a new change, or
  `sqitch rework` when an existing one must change.
- No credentials in `sqitch.conf` or in the plan: the target and the password
  come from the environment (for example `PGPASSWORD`).
- The Docker image tag is pinned (not `latest`) once `make migrate` exists.

## Consequences

- Each `pgbouncer*.ini` gets the `postgres_pitch_migrations` alias, added
  together with this ADR because `../../tests/migration_path_test.sh` needs it;
  `make migrate` builds on it. Applications must keep using `postgres_pitch`:
  a session-mode connection holds a server connection for its whole life.
- A migration that is interrupted by a failover simply stops; re-running it
  after the new primary is up is safe (Sqitch records what was deployed).
- The `server_login_retry = 1` setting from the failover work applies to the
  alias too, so a failed login does not block it for 15 seconds.
- The registry lives in the application database, schema `sqitch`, and is
  private to the admin role.
- If PgBouncer is later removed from the migration path, or a different
  migration tool is chosen, this ADR is superseded.
