-- Revert pitch:matches_and_events from pg

BEGIN;

-- The partitions are dropped together with their parent tables.
DROP TABLE match_events;
DROP TABLE matches;

COMMIT;
