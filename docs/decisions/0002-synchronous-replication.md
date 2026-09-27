# ADR 0002: Synchronous Replication Trade-off

**Status:** Accepted
**Date:** 2026-09-26

## Context

The cluster runs 1 primary + 2 replicas. Patroni supports both
asynchronous and synchronous replication. This decision is about which
one to use for the replica Patroni designates as the failover candidate,
and what that costs in practice — not just in theory.

## Decision

`synchronous_mode: true` is set in `patroni.yml`. Patroni automatically
maintains one replica as a **synchronous standby**; the other remains
asynchronous. On failover, Patroni promotes the synchronous standby, not
just whichever replica happens to be available.

## Rationale

- **Durability over latency.** With synchronous replication, the primary
  does not acknowledge a write to the client until the sync standby has
  confirmed receipt. This guarantees zero data loss on failover — the
  promoted node is guaranteed to have every committed transaction.
- The alternative (fully asynchronous) risks promoting a replica that is
  behind the primary, silently losing the most recent committed
  transactions — unacceptable for a system meant to demonstrate
  production-grade durability guarantees.
- The cost is write latency: every write waits on a round trip to the
  sync standby, not just the primary's local disk. For this project's
  scale and purpose, that cost is acceptable and worth demonstrating
  deliberately, rather than defaulting to async without measuring it.

## Verification

Rather than asserting "automatic failover works," this was measured
directly with `../../tests/failover_test.sh`, which kills the primary
container (`docker kill`, simulating a genuine crash rather than a
graceful shutdown) and polls the Patroni REST API until a new leader is
elected.

**Result from a real local run:**

```
Old leader:            postgresql0 (killed)
New leader:            postgresql1
Failover time:         28s (container kill -> new leader visible)
Promoted node check:   PASS — the synchronous standby was promoted
                       (zero-data-loss failover, as designed)
```

The promoted node (`postgresql1`) was confirmed to be the node that was
the synchronous standby *before* the kill — not just an arbitrary
survivor — which is the actual guarantee this configuration is meant to
provide, not merely "a new leader appeared."

## Consequences

- **~28 seconds of write unavailability** on primary failure in this
  configuration, driven by `dcs.ttl: 30` / `dcs.loop_wait: 10` in
  `patroni.yml`. This is the real, measured cost of the durability
  guarantee above — not a theoretical estimate. Lowering `ttl`/
  `loop_wait` would shrink this window but increases the risk of
  false-positive failovers under transient network hiccups; this
  trade-off is left at Patroni's conservative defaults for now.
- Every write pays a synchronous round-trip to the standby. Not
  benchmarked yet under load — a candidate for Iteration 9
  (Performance).
- If the synchronous standby itself becomes unavailable,
  `synchronous_mode_strict` (currently unset, defaulting to `false`)
  determines whether the primary keeps accepting writes without a sync
  standby (current behavior) or blocks entirely. This is a deliberate
  availability-over-strict-durability choice for a single-region local
  cluster; worth revisiting once multi-AZ/region behavior is in scope.

## Alternatives Considered

- **Fully asynchronous replication** — rejected: no zero-data-loss
  guarantee on failover, which undermines the point of demonstrating an
  HA cluster in the first place.
- **`synchronous_mode_strict: true`** — considered, not adopted yet:
  would block all writes if the sync standby is down, trading
  availability for stricter durability. Left as a follow-up decision
  once there's a concrete scenario (e.g. during backup/DR work) that
  calls for it.
