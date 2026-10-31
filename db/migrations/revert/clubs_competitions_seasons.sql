-- Revert pitch:clubs_competitions_seasons from pg

BEGIN;

DROP TABLE club_history;
DROP TABLE seasons;
DROP TABLE competitions;
DROP TABLE clubs;

COMMIT;
