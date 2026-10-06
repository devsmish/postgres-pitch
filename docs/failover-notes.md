# Failover notes

Evidence, not a claim: what happens when the primary dies, how long the
cluster and the client-facing layer take to recover, and what exactly is
checked. Everything below is reproducible with one command:

```bash
make failover-test        # or: bash tests/failover_test.sh
```

Related: [ADR 0002](./decisions/0002-synchronous-replication.md) (why the
sync standby is the failover candidate), [access patterns](./access-patterns.md)
(HAProxy / PgBouncer / roles), [architecture](./architecture.md).

## What the test does

`tests/failover_test.sh` runs against a healthy local cluster and:

1. Records the leader, the synchronous standby and the leader's IP, and
   checks the baseline (write endpoint on the primary, read-only endpoint
   on a replica).
2. Kills the leader container with `docker kill` (SIGKILL: a real crash,
   not a graceful shutdown that would let Patroni hand over cleanly).
3. Polls the Patroni REST API until a new leader appears, and polls the
   write endpoint (`:5000`) until it answers from the new primary.
4. Checks the result while the old primary is still down, and probes the
   read-only endpoint (`:5001`) one fresh connection at a time until it has
   answered from replicas 12 times in a row, noting when the last
   connection still reached the newly promoted node (see "Findings").
5. Restarts the old primary and waits until it is a streaming replica
   again and the read-only endpoint serves it.

The killed container is always started again on exit, even if a check
fails or the run is interrupted, and the test table is dropped.

## What is asserted

| # | Check | Acceptance criterion (#11) |
|---|---|---|
| 1 | The node promoted by Patroni is the one that was the **synchronous** standby before the kill, not the async replica | sync replica is promoted |
| 2 | The write endpoint (`:5000`) reaches the new primary (`pg_is_in_recovery() = false`, server IP = new leader) with the **same connection settings** | HAProxy reroutes without a client change |
| 3 | Read-only endpoint, fresh connections after the failover: at least one succeeds and none reaches the dead old primary | read-only endpoint no longer includes the old primary |
| 3b | Within the timeout the read-only endpoint settles on replicas only (12 consecutive connections); the time of the last connection that still reached the newly promoted node is recorded | read-only endpoint serves replicas only |
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
| HAProxy drops the *promoted* node from the read pool | the promoted node was a healthy replica, so it stays in `health_replica` until `/replica` has failed `fall` times | up to about 9s after the promotion (`fall 3 x inter 3s`), during which read connections can still land on the new primary |
| Old primary back in the read pool | Patroni restart / `pg_rewind` + replica start, then `health_replica`: `GET /replica`, `rise 2 x inter 3s`; PgBouncer `server_login_retry = 1` | tens of seconds after `docker start` (measured from the restart) |

So the client-visible write downtime is Patroni's detection and promotion
time plus up to a few seconds of HAProxy health-check lag.

## Results

Each run of `make failover-test` prints a ready-to-paste row. Times are
seconds with a resolution of about 1s. "Patroni", "write" and "last read
on the new primary" are counted from the container kill; "rejoined" and
"back in read pool" are counted from the moment the test restarts the old
primary (the restart happens a few seconds after the checks, so counting
from the kill would measure the test's own delay).

| Date | Old leader (killed) | Promoted (was sync standby) | New leader visible in Patroni | Write endpoint on new primary | Read pool free of the new primary | Old primary rejoined (after restart) | Old primary back in read pool (after restart) |
|------------|-------------|-------------|-----|-----|---------|---------|---------|
| 2026-10-06 | postgresql0 | postgresql2 | 35s | 37s | n/a (1) | n/a (2) | n/a (2) |
| 2026-10-06 | postgresql2 | postgresql1 | 28s | 34s |   43s   |   16s   |   22s   |
| 2026-10-06 | postgresql1 | postgresql0 | 33s | 38s |   41s   |   15s   |   21s   |
| 2026-10-06 | postgresql0 | postgresql2 | 31s | 35s |   37s   |   16s   |   22s   |
| 2026-10-06 | postgresql2 | postgresql1 | 27s | 31s |   36s   |   16s   |   22s   |

1. First run, before the test measured this.
2. First run: counted from the kill (59s / 65s), which includes the test's
   own wait before restarting the node.
3. Second run, measured with an earlier method that waited for 12
   consecutive clean connections and counted until the last of them, so it
   is an upper bound; the test now records the time of the last connection
   that still reached the new primary instead.

Earlier measurement (Patroni only, before HAProxy/PgBouncer existed; from
[ADR 0002](./decisions/0002-synchronous-replication.md)): kill -> new
leader visible in 28s, promoted node = the synchronous standby.

## Findings

- **Detection and promotion dominate the downtime.** Across the two runs
  Patroni needed 35s and 28s (inside the expected 20-40s window), and the
  write endpoint followed 2s and 6s later (HAProxy's `rise 2 x inter 3s`).
  HAProxy and PgBouncer added at most a few seconds on the write path; the
  recovery time is a Patroni setting (`ttl` / `loop_wait`), not a routing
  problem.
- **The promoted node stays in the read pool for a few seconds.** Right
  after the write endpoint recovered, 4 of 8 (first run) and 2 of 8
  (second run) read-only connections landed on the new primary. This
  matches the configuration: the node had been a healthy replica, and
  HAProxy only drops it after `fall 3 x inter 3s`. Those sessions were
  read-only `SELECT`s and succeeded, but were served by the primary rather
  than a replica. The test therefore separates "no connection reaches the
  *dead* primary" (immediate) from "the read pool settles on replicas"
  (converges; the time of the last stray connection is recorded in the
  "last read-only connection on the new primary" column). If analytics
  traffic must never touch the primary, even briefly, lower `inter`/`fall`
  on `health_replica` in `haproxy.cfg` at the cost of more health-check
  traffic.
- **The old primary comes back on its own.** After `docker start` it
  rejoined as a streaming replica in 16s and was served by the read-only
  endpoint 6s later; no grants, connection strings or manual `patronictl`
  steps were involved.

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
