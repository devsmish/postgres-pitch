-- Revert pitch:reference_tables from pg

BEGIN;

DROP TABLE referees;
DROP TABLE stadiums;
DROP TABLE cities;
DROP TABLE countries;

COMMIT;
