-- Revert pitch:standings_view from pg

BEGIN;

-- The unique index goes with the materialized view.
DROP MATERIALIZED VIEW standings;

COMMIT;
