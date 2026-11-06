-- Deploy pitch:indexes to pg
-- requires: players_and_careers, matches_and_events

BEGIN;

CREATE INDEX idx_clubs_country ON clubs (country_id);
CREATE INDEX idx_players_nationality ON players (nationality_id);
CREATE INDEX idx_players_last_name ON players (last_name);
CREATE INDEX idx_player_career_player ON player_career (player_id);
CREATE INDEX idx_player_career_club ON player_career (club_id);

CREATE INDEX idx_matches_season ON matches (season_id);
CREATE INDEX idx_matches_home_club ON matches (home_club_id);
CREATE INDEX idx_matches_away_club ON matches (away_club_id);
-- Partial index: most operational queries look at upcoming/in-play matches,
-- not the full historical table.
CREATE INDEX idx_matches_upcoming ON matches (match_date)
WHERE status IN ('scheduled', 'in_play');

CREATE INDEX idx_match_events_match ON match_events (match_id);
CREATE INDEX idx_match_events_player ON match_events (player_id);

COMMIT;
