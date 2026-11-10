# schema

`001_initial_schema.sql` is the original bootstrap DDL. It is kept **frozen** as
the reference the migrations are checked against: `tests/migrate_test.sh`
builds one database from this script and one from the baseline Sqitch changes
and requires identical schemas. Do not edit it, and do not apply it to a real
database.

The schema is managed by the Sqitch migrations in [db/migrations/](../migrations/);
apply them with `make migrate`.
