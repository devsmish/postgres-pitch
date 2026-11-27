-- Verify pitch:partition_job on pg

-- In the database pg_cron serves, the job is scheduled as intended; elsewhere
-- there is nothing to check (see the deploy script).
DO $$
BEGIN
    IF current_setting('cron.database_name', TRUE) IS DISTINCT FROM current_database() THEN
        RETURN;
    END IF;

    ASSERT (
        SELECT count(*)
        FROM cron.job
        WHERE
            jobname = 'ensure-year-partitions'
            AND schedule = '0 20 31 12 *'
            AND active
            AND database = current_database()
            AND command LIKE 'SELECT public.create_year_partitions(%'
    ) = 1, 'the job ensure-year-partitions should be scheduled and active in pg_cron';
END
$$;
