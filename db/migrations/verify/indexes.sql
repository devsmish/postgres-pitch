-- Verify pitch:indexes on pg

DO $$
DECLARE
    idx text;
BEGIN
    FOREACH idx IN ARRAY ARRAY[
        'idx_clubs_country', 'idx_players_nationality', 'idx_players_last_name',
        'idx_player_career_player', 'idx_player_career_club', 'idx_matches_season',
        'idx_matches_home_club', 'idx_matches_away_club', 'idx_matches_upcoming',
        'idx_match_events_match', 'idx_match_events_player'
    ] LOOP
        ASSERT to_regclass('public.' || idx) IS NOT NULL, 'index ' || idx || ' is missing';
    END LOOP;
END
$$;
