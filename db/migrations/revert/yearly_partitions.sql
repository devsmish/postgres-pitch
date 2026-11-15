-- Revert pitch:yearly_partitions from pg

BEGIN;

-- Drops the partitions this change created (everything except 2024-2026,
-- which belong to matches_and_events), together with the rows in them.
-- A partition of matches cannot be dropped directly while match_events has a
-- foreign key to it, so it is detached first.
DO $$
DECLARE
    yr INTEGER;
BEGIN
    FOR yr IN 1872..2027 LOOP
        CONTINUE WHEN yr BETWEEN 2024 AND 2026;

        EXECUTE format('DROP TABLE %I', 'match_events_' || yr);
        EXECUTE format('ALTER TABLE matches DETACH PARTITION %I', 'matches_' || yr);
        EXECUTE format('DROP TABLE %I', 'matches_' || yr);
    END LOOP;
END
$$;

COMMIT;
