-- Verify pitch:matches_and_events on pg

SELECT
    id,
    season_id,
    home_club_id,
    away_club_id,
    stadium_id,
    referee_id,
    match_date,
    matchday,
    status,
    home_score,
    away_score,
    external_ref
FROM matches
WHERE FALSE;

SELECT
    id,
    match_id,
    match_date,
    player_id,
    event_type,
    minute,
    extra_time
FROM match_events
WHERE FALSE;

-- Both tables are partitioned by range on match_date and have the partitions
-- this change created: 2024, 2025, 2026 and a default one. Later changes add
-- more partitions (yearly_partitions), so this does not count them.
DO $$
DECLARE
    parent TEXT;
    suffix TEXT;
BEGIN
    FOREACH parent IN ARRAY ARRAY['matches', 'match_events'] LOOP
        FOREACH suffix IN ARRAY ARRAY['2024', '2025', '2026', 'default'] LOOP
            ASSERT EXISTS (
                SELECT 1
                FROM pg_inherits AS i
                INNER JOIN pg_class AS c ON i.inhrelid = c.oid
                WHERE
                    i.inhparent = format('public.%I', parent)::regclass
                    AND c.relname = parent || '_' || suffix
            ), format('%s should have the partition %s_%s', parent, parent, suffix);
        END LOOP;
    END LOOP;
    ASSERT (SELECT partstrat FROM pg_partitioned_table WHERE partrelid = 'public.matches'::regclass) = 'r',
        'matches should be range partitioned';
    ASSERT (SELECT partstrat FROM pg_partitioned_table WHERE partrelid = 'public.match_events'::regclass) = 'r',
        'match_events should be range partitioned';
END
$$;
