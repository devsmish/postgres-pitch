-- Revert pitch:indexes from pg

BEGIN;

DROP INDEX idx_match_events_player;
DROP INDEX idx_match_events_match;
DROP INDEX idx_matches_upcoming;
DROP INDEX idx_matches_away_club;
DROP INDEX idx_matches_home_club;
DROP INDEX idx_matches_season;
DROP INDEX idx_player_career_club;
DROP INDEX idx_player_career_player;
DROP INDEX idx_players_last_name;
DROP INDEX idx_players_nationality;
DROP INDEX idx_clubs_country;

COMMIT;
