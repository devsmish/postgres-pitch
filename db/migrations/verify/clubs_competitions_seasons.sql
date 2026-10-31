-- Verify pitch:clubs_competitions_seasons on pg

SELECT
    id,
    name,
    short_name,
    founded_year,
    stadium_id,
    country_id,
    external_ref
FROM clubs
WHERE FALSE;

SELECT
    id,
    name,
    type,
    country_id
FROM competitions
WHERE FALSE;

SELECT
    id,
    competition_id,
    year_start,
    year_end
FROM seasons
WHERE FALSE;

SELECT
    id,
    club_id,
    season_id,
    name_at_time,
    league_id,
    final_position
FROM club_history
WHERE FALSE;
