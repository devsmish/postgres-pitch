-- Revert pitch:players_and_careers from pg

BEGIN;

DROP TABLE player_career;
DROP TABLE players;

COMMIT;
