-- Deploy pitch:create_year_partitions to pg
-- requires: yearly_partitions

BEGIN;

-- Creates the missing yearly partitions of matches and match_events for the
-- years from_year to to_year and returns how many tables it created (0 when
-- everything exists, so it is safe to run again). The partitions are built
-- like the existing ones: named <table>_<year>, one calendar year in UTC.
--
-- Safety rules:
-- - one transaction: a call that fails changes nothing;
-- - the call fails if a table with a partition's name exists but is not a
--   partition of that table (it would be skipped silently otherwise);
-- - it refuses a to_year more than 10 years ahead, so a typo cannot create
--   thousands of partitions;
-- - lock_timeout: CREATE TABLE ... PARTITION OF locks the parent table, and a
--   long query on it would otherwise make every later query wait behind the
--   waiting DDL; after 10 s the call fails instead;
-- - an advisory lock keeps two runs apart (a manual one and a scheduled one).
-- If the default partition already holds rows of a year, creating that year
-- fails with PostgreSQL's own error; move the rows out first.
CREATE FUNCTION create_year_partitions(from_year INTEGER, to_year INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
SET lock_timeout = '10s'
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    this_year INTEGER := extract(YEAR FROM now() AT TIME ZONE 'UTC')::INTEGER;
    yr INTEGER;
    parent TEXT;
    part TEXT;
    created INTEGER := 0;
BEGIN
    IF from_year IS NULL OR to_year IS NULL THEN
        RAISE EXCEPTION 'from_year and to_year must not be NULL';
    END IF;
    IF from_year < 1800 OR from_year > to_year THEN
        RAISE EXCEPTION 'invalid range: from_year % must be between 1800 and to_year %', from_year, to_year;
    END IF;
    IF to_year > this_year + 10 THEN
        RAISE EXCEPTION 'refusing to create partitions for % (more than 10 years ahead of %)', to_year, this_year;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('create_year_partitions'));

    FOR yr IN from_year..to_year LOOP
        FOREACH parent IN ARRAY ARRAY['matches', 'match_events'] LOOP
            part := parent || '_' || yr;

            IF to_regclass(format('public.%I', part)) IS NOT NULL THEN
                IF NOT EXISTS (
                    SELECT 1
                    FROM pg_inherits
                    WHERE
                        inhrelid = to_regclass(format('public.%I', part))
                        AND inhparent = to_regclass(format('public.%I', parent))
                ) THEN
                    RAISE EXCEPTION 'public.% exists but is not a partition of public.%', part, parent;
                END IF;
                CONTINUE;
            END IF;

            EXECUTE format(
                'CREATE TABLE public.%I PARTITION OF public.%I FOR VALUES FROM (%L) TO (%L)',
                part, parent, yr || '-01-01 00:00:00+00', (yr + 1) || '-01-01 00:00:00+00'
            );
            created := created + 1;
            RAISE NOTICE 'created public.%', part;
        END LOOP;
    END LOOP;

    RETURN created;
END
$$;

-- DDL function: only its owner (and superusers) may run it. Without this,
-- PUBLIC could call it (it would fail for lack of rights, but it should not
-- even be offered).
REVOKE EXECUTE ON FUNCTION create_year_partitions(INTEGER, INTEGER) FROM public;

COMMENT ON FUNCTION create_year_partitions(INTEGER, INTEGER) IS
'Creates the missing yearly partitions of matches and match_events for from_year..to_year (UTC); returns the number of tables created.';

COMMIT;
