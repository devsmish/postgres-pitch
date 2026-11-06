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

-- Both tables are partitioned by range on match_date and have the yearly
-- partitions 2024-2026 plus a default partition.
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM pg_inherits WHERE inhparent = 'public.matches'::regclass) = 4,
        'matches should have 4 partitions (2024, 2025, 2026, default)';
    ASSERT (SELECT count(*) FROM pg_inherits WHERE inhparent = 'public.match_events'::regclass) = 4,
        'match_events should have 4 partitions (2024, 2025, 2026, default)';
    ASSERT (SELECT partstrat FROM pg_partitioned_table WHERE partrelid = 'public.matches'::regclass) = 'r',
        'matches should be range partitioned';
END
$$;
