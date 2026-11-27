-- Revert pitch:partition_job from pg

BEGIN;

-- Removes the schedule. The pg_cron extension stays: it may hold other jobs.
DO $$
BEGIN
    IF to_regclass('cron.job') IS NOT NULL THEN
        PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'ensure-year-partitions';
    END IF;
END
$$;

COMMIT;
