# migrations

Versioned schema migrations, managed with [Sqitch](https://sqitch.org/). The
decision, the way Sqitch connects to the cluster (a session-mode PgBouncer
alias, because Sqitch relies on session state) and the experiments behind it
are in [ADR 0004](../../../docs/decisions/0004-sqitch-for-schema-migrations.md).

## Layout

```
db/migrations/
  sqitch.conf     # project configuration (no credentials)
  sqitch.plan     # ordered list of changes
  deploy/         # <change>.sql: apply the change
  revert/         # <change>.sql: undo it
  verify/         # <change>.sql: check it was applied (read-only)
```

The project is created with `sqitch init pitch --engine pg`.

## Conventions

- One logical change per Sqitch change; lowercase `snake_case` names that say
  what the change does, for example `baseline_schema`.
- `deploy` and `revert` scripts run in an explicit `BEGIN; ... COMMIT;`.
  `verify` scripts only read.
- Never edit a change that has been deployed: add a new change, or use
  `sqitch rework`.
- No credentials in `sqitch.conf` or in the plan; pass the target and the
  password through the environment.

## Status

The conventions above are fixed. The first changes (the baseline schema from
`db/schema/001_initial_schema.sql`) and `make migrate` come with the
"Versioned schema migrations" issue; until then `make schema` remains the way
to apply the schema.
