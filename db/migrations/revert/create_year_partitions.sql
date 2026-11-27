-- Revert pitch:create_year_partitions from pg

BEGIN;

DROP FUNCTION create_year_partitions (INTEGER, INTEGER);

COMMIT;
