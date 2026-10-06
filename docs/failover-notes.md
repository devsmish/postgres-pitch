# Failover notes

Evidence, not a claim: what happens when the primary dies, how long the
cluster and the client-facing layer take to recover, and what exactly is
checked. Everything below is reproducible with one command:

```bash
make failover-test        # or: bash tests/failover_test.sh
```

Related: [ADR 0002](./decisions/0002-synchronous-replication.md) (why the
sync standby is the failover candidate), [access patterns](../postgres-pitch-issue11/docs/access-patterns.md)
(HAProxy / PgBouncer / roles), [architecture](../postgres-pitch-issue11/docs/architecture.md).

## What the test does

`../tests/failover_test.sh` runs against a healthy local cluster and:

1. Records the leader, the synchronous standby and the leader's IP, and
   checks the baseline (write endpoint on the primary, read-only endpoint
   on a replica).
2. Kills the leader container with `docker kill` (SIGKILL: a real crash,
   not a graceful shutdown that would let Patroni hand over cleanly).
3. Polls the Patroni REST API until a new leader appears, and polls the
   write endpoint (`:5000`) until it answers from the new primary.
4. Checks the result while the old primary is still down.
5. Restarts the old primary and waits until it is a streaming replica
   again and the read-only endpoint (`:5001`) serves it.

The killed container is always started again on exit, even if a check
fails or the run is interrupted, and the test table is dropped.

## What is asserted

| # | Check | Acceptance criterion (#11) |
|---|---|---|
| 1 | The node promoted by Patroni is the one that was the **synchronous** standby before the kill, not the async replica | sync replica is promoted |
| 2 | The write endpoint (`:5000`) reaches the new primary (`pg_is_in_recovery() = false`, server IP = new leader) with the **same connection settings** | HAProxy reroutes without a client change |
| 3 | Read-only endpoint, 8 fresh connections after the failover: every one that succeeds lands on a replica; none on the new primary, none on the dead old primary | read-only endpoint no longer includes the old primary |
| 4 | A fresh `etl_writer` session can `INSERT` via the write endpoint | roles keep working |
| 5 | A fresh `analytics_readonly` session can `SELECT` the new row via the read-only endpoint, and still cannot write there (`read-only transaction`) | roles keep working |
| 6 | The old primary rejoins as a `streaming` replica (`replica` or `sync_standby`) | demoted primary rejoins |
| 7 | The read-only endpoint serves the former primary again | demoted primary is back in the read pool |
| 8 | The write endpoint is still on the new primary after the old one rejoined (no failback) | stable routing |

If there is no synchronous standby when the test starts, it aborts instead
of running: without one it cannot demonstrate the zero-data-loss promotion.

## Where the time goes (expected, from the configuration)

These are derived from the settings, to explain the measurements below; the
measurements are what counts.

| Phase | Driven by | Expected |
|---|---|---|
| Patroni notices the dead leader and promotes | `dcs.ttl: 30`, `dcs.loop_wait: 10` in `patroni.yml`. The leader refreshes its key every `loop_wait`; the key expires `ttl` after the last refresh; replicas notice at their next loop. Where the crash falls inside that cycle varies. | roughly `ttl - loop_wait` to `ttl + loop_wait`, i.e. about 20-40s (one earlier run: 28s, see ADR 0002) |
| HAProxy marks the new primary UP | `health_primary`: `GET /primary` every `inter 3s`, `rise 2` | about 3-6s after promotion |
| HAProxy drops the dead primary | `fall 3 x inter 3s` | about 9s after the crash, i.e. well before a new primary exists, so the write endpoint never has two candidates |
| Old primary back in the read pool | Patroni restart / `pg_rewind` + replica start, then `health_replica`: `GET /replica`, `rise 2 x inter 3s`; PgBouncer `server_login_retry = 1` | tens of seconds after `docker start` |

So the client-visible write downtime is Patroni's detection and promotion
time plus up to a few seconds of HAProxy health-check lag.

## Results

Each run of `make failover-test` prints a ready-to-paste row. Times are
seconds from the container kill, resolution about 1s.

| Date | Old leader (killed) | Promoted (was sync standby) | New leader visible in Patroni | Write endpoint on new primary | Old primary rejoined | Old primary back in read pool |
|---|---|---|---|---|---|---|
<!-- paste the "Row for docs/failover-notes.md" line printed by the test here, one per run -->

Earlier measurement (Patroni only, before HAProxy/PgBouncer existed; from
[ADR 0002](./decisions/0002-synchronous-replication.md)): kill -> new
leader visible in 28s, promoted node = the synchronous standby.

Because the crash lands at a random point of Patroni's `loop_wait` cycle,
run the test a few times and keep the spread, not a single number.

## What this does not cover

- **Crash type.** One failure mode only: the primary process/container is
  SIGKILLed. Not covered: network partitions, a frozen (not dead)
  primary, disk full, etcd quorum loss. These belong to the chaos
  iteration (ROADMAP, Iteration 10).
- **Data loss under load.** The synchronous-standby check shows the right
  node was promoted; it does not run concurrent writes through the
  failover and count lost commits. That would be the stronger proof.
- **Single host.** All nodes share one Docker host, so timings say
  nothing about cross-AZ latency.
- **Resolution.** Timings are whole seconds from `date +%s`, plus the
  cost of the `docker exec` probes themselves (a fraction of a second
  each).
