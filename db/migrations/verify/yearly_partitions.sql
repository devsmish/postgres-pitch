-- Verify pitch:yearly_partitions on pg

-- Each of the two tables has a yearly partition named <table>_<year> for
-- every year from 1872 to 2027, bounded exactly at UTC midnight (so the years
-- are contiguous and do not overlap), and a default partition. Partitions for
-- other years are allowed (the annual maintenance job adds them), but every
-- partition except the default one has to follow the same naming and bounds.
DO $$
DECLARE
    parent TEXT;
    missing INTEGER;
    irregular INTEGER;
BEGIN
    -- pg_get_expr prints timestamps in the session time zone; the bounds are
    -- stored as absolute instants, so read them in UTC.
    PERFORM set_config('TimeZone', 'UTC', TRUE);

    FOREACH parent IN ARRAY ARRAY['matches', 'match_events'] LOOP
        ASSERT (
            SELECT count(*)
            FROM pg_inherits AS i
            INNER JOIN pg_class AS c ON i.inhrelid = c.oid
            WHERE
                i.inhparent = format('public.%I', parent)::regclass
                AND c.relname = parent || '_default'
                AND pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT'
        ) = 1, format('%s should have its default partition', parent);

        SELECT count(*) INTO missing
        FROM generate_series(1872, 2027) AS g (yr)
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_inherits AS i
            INNER JOIN pg_class AS c ON i.inhrelid = c.oid
            WHERE
                i.inhparent = format('public.%I', parent)::regclass
                AND c.relname = parent || '_' || g.yr
                AND pg_get_expr(c.relpartbound, c.oid) = format(
                    'FOR VALUES FROM (''%s-01-01 00:00:00+00'') TO (''%s-01-01 00:00:00+00'')',
                    g.yr, g.yr + 1
                )
        );
        ASSERT missing = 0, format(
            '%s: %s yearly partitions are missing or have the wrong bounds', parent, missing
        );

        SELECT count(*) INTO irregular
        FROM (
            SELECT
                pg_get_expr(c.relpartbound, c.oid) AS bound,
                CASE
                    WHEN c.relname ~ ('^' || parent || '_[0-9]{4}$') THEN right(c.relname, 4)::INTEGER
                END AS yr
            FROM pg_inherits AS i
            INNER JOIN pg_class AS c ON i.inhrelid = c.oid
            WHERE i.inhparent = format('public.%I', parent)::regclass
        ) AS p
        WHERE
            p.bound <> 'DEFAULT'
            AND (
                p.yr IS NULL
                OR p.bound <> format(
                    'FOR VALUES FROM (''%s-01-01 00:00:00+00'') TO (''%s-01-01 00:00:00+00'')',
                    p.yr, p.yr + 1
                )
            );
        ASSERT irregular = 0, format(
            '%s: %s partitions do not follow the <table>_<year> yearly pattern', parent, irregular
        );
    END LOOP;
END
$$;
