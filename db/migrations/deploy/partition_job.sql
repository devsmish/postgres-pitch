-- Deploy pitch:partition_job to pg
-- requires: create_year_partitions

BEGIN;

-- Schedules the annual partition job in pg_cron: every 31 December at 20:00
-- UTC (cron.timezone = UTC), create the partitions from the current year
-- through the current year + 2. Runs on whichever node is the primary; see
-- ADR 0005.
--
-- pg_cron lives in exactly one database, the one named in cron.database_name,
-- and only works when it is in shared_preload_libraries. Everywhere else (the
-- scratch databases of tests/migrate_test.sh, a PostgreSQL without pg_cron)
-- this change does nothing and says so. The cluster check in
-- tests/partitions_test.sh fails if the job is missing from the real database.
DO $$
BEGIN
    IF current_setting('cron.database_name', TRUE) IS DISTINCT FROM current_database() THEN
        RAISE NOTICE 'pg_cron does not serve the database % (cron.database_name = %): the partition job is not scheduled here',
            current_database(), coalesce(current_setting('cron.database_name', TRUE), 'not set');
        RETURN;
    END IF;

    CREATE EXTENSION IF NOT EXISTS pg_cron;

    PERFORM cron.schedule(
        'ensure-year-partitions',
        '0 20 31 12 *',
        'SELECT public.create_year_partitions(y, y + 2) FROM (SELECT extract(YEAR FROM now() AT TIME ZONE ''UTC'')::INTEGER AS y) AS s'
    );
END
$$;

COMMIT;
