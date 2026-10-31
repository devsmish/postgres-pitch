-- Verify pitch:standings_view on pg

-- The view is created WITH NO DATA, so it cannot be queried yet; check the catalog.
DO $$
BEGIN
    ASSERT EXISTS (SELECT 1 FROM pg_matviews WHERE schemaname = 'public' AND matviewname = 'standings'),
        'materialized view standings is missing';
    ASSERT (SELECT array_agg(attname::text ORDER BY attnum) FROM pg_attribute
            WHERE attrelid = 'public.standings'::regclass AND attnum > 0 AND NOT attisdropped)
        = ARRAY['season_id', 'club_id', 'played', 'wins', 'draws', 'losses',
                'goals_for', 'goals_against', 'goal_difference', 'points'],
        'standings has unexpected columns';
    ASSERT to_regclass('public.idx_standings_season_club') IS NOT NULL,
        'unique index idx_standings_season_club is missing';
END
$$;
