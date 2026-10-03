# Access Patterns

How clients reach the cluster, and why roles and grants don't care which
physical node they end up on.

## Connection flow

```
                        ┌──────────────┐     ┌────────────┐
 client ──:5000 write──▶│              │────▶│ PgBouncer  │──▶ PostgreSQL (current primary)
                        │   HAProxy    │     │ (per node) │
 client ──:5001 read───▶│  (routing)   │────▶│            │──▶ PostgreSQL (a healthy replica)
                        └──────┬───────┘     └────────────┘
                               │ health checks (every 3s)
                               ▼
                    Patroni REST API on every node
                    GET /primary  → 200 only on the leader
                    GET /replica  → 200 only on a streaming replica
```

- **HAProxy** decides *which physical node* a connection goes to, purely
  from Patroni's own view of the cluster. It never guesses roles itself.
- **PgBouncer** (one instance colocated with each PostgreSQL node, in
  transaction pooling mode) pools connections to the node HAProxy routed
  to.
- **Two endpoints** instead of one, because reads and writes have
  different needs:

| Endpoint | Port | Routes to | Use for |
|---|---|---|---|
| write | `5000` | the current primary only | OLTP writes, ETL loads, anything transactional |
| read-only | `5001` | healthy replicas, round-robin | analytics, reporting, anything that only reads |

HAProxy's stats page (`http://localhost:8404/`) shows which backend
servers it currently considers up.

## Why roles don't need to know about nodes

Roles, passwords and grants live in PostgreSQL's system catalogs, which
are replicated with everything else. Every node carries the same roles
and the same grants — a promotion changes what a node *is doing*
(read-write instead of recovery), not what any role is *allowed* to do.
So after a failover or switchover:

- no `GRANT` needs to be re-run,
- no role or password needs to be re-created,
- no client connection string changes — `:5000` still means "the
  primary" and `:5001` still means "a replica"; HAProxy just points them
  at different nodes.

Two independent layers keep the demo roles in their lane, and the test
checks both separately:

| Attempt | Fails because | Layer |
|---|---|---|
| `analytics_readonly` INSERT via `:5001` | landed on a replica → `read-only transaction` | routing |
| `analytics_readonly` INSERT via `:5000` | no INSERT grant → `permission denied` | roles / grants |
| `etl_writer` INSERT via `:5001` | landed on a replica → `read-only transaction` | routing |
| `etl_writer` INSERT via `:5000` | succeeds | — |

## The demo roles

Created once, at cluster bootstrap, by
`../docker-compose/patroni/post_bootstrap.sh`:

| Role | Grants | Connects via |
|---|---|---|
| `analytics_readonly` | `SELECT` on all tables in `public` | read-only endpoint (`:5001`) |
| `etl_writer` | `INSERT`, `UPDATE` on all tables in `public`, `USAGE` on sequences | write endpoint (`:5000`) |
| `pgbouncer_auth` | `EXECUTE` on `public.user_lookup()` only — no data access | used by PgBouncer itself |

Grants are applied with `ALTER DEFAULT PRIVILEGES`, not just `GRANT ...
ON ALL TABLES`, because the bootstrap runs *before* the schema is
applied (`make schema`). Default privileges make every table created
afterwards by the admin role pick up the right access automatically.
`etl_writer` also needs sequence privileges: an `INSERT` into a table
with a `SERIAL` column fails with `permission denied for sequence`
without them.

This is deliberately a lightweight demo of two roles. The real security
posture — SCRAM everywhere, `pg_hba` hardening, least-privilege review,
`pgAudit` — is Iteration 5 in the [ROADMAP](../ROADMAP.md).

## How PgBouncer authenticates application roles

PgBouncer uses `auth_query` rather than a static `userlist.txt` entry
per role. It logs in as `pgbouncer_auth` and calls
`public.user_lookup(username)` — a `SECURITY DEFINER` function that
returns the requested role's password secret from `pg_shadow` — so a
role created later works through PgBouncer immediately, with no
PgBouncer-side change. Only `pgbouncer_auth` itself has an entry in
`userlist.txt`, generated at container start from `../.env` and never
committed.

Known trade-off: `pgbouncer_auth` is stored with an MD5 secret (all
other roles use SCRAM-SHA-256), because PgBouncer's login to PostgreSQL
uses whatever the image writes to `userlist.txt`, and an MD5 hash can
only authenticate against an MD5 secret. It's a technical role with no
data access; revisit in Iteration 5.

## Failover timing and HAProxy

`../tests/failover_test.sh` measures ~28s from a crashed primary to a new
leader ([ADR 0002](./decisions/0002-synchronous-replication.md)). HAProxy
adds at most `fall 3 × inter 3s` ≈ 9s of health-check lag on top of
Patroni's own detection, and `on-marked-down shutdown-sessions` on the
write backend drops sessions still open through a demoted primary
instead of letting them linger.

## Verifying it

```bash
bash tests/access_patterns_test.sh     # or: make access-test
```

Checks routing (`pg_is_in_recovery()` on each endpoint), both roles on
both endpoints, then runs a `patronictl switchover` and repeats every
check with the same credentials and ports.
