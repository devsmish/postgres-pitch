-- Deploy pitch:yearly_partitions to pg
-- requires: matches_and_events

BEGIN;

-- One yearly partition of matches and of match_events for every year from
-- 1872 (the first match in the international_results dataset) to 2027 (the
-- latest fixture in OpenFootball's football.json, the 2026-27 season); see
-- DATA_SOURCES.md. The baseline already created 2024, 2025 and 2026, so those
-- are skipped. Rows outside 1872-2027 still go to the default partitions.
--
-- The bounds are written with an explicit +00 offset: a bare '2024-01-01'
-- literal on a TIMESTAMPTZ column means midnight in the session's time zone,
-- so the partitions would depend on where and how they were created.
DO $$
DECLARE
    yr INTEGER;
BEGIN
    FOR yr IN 1872..2027 LOOP
        CONTINUE WHEN yr BETWEEN 2024 AND 2026;

        EXECUTE format(
            'CREATE TABLE %I PARTITION OF matches FOR VALUES FROM (%L) TO (%L)',
            'matches_' || yr, yr || '-01-01 00:00:00+00', (yr + 1) || '-01-01 00:00:00+00'
        );
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF match_events FOR VALUES FROM (%L) TO (%L)',
            'match_events_' || yr, yr || '-01-01 00:00:00+00', (yr + 1) || '-01-01 00:00:00+00'
        );
    END LOOP;
END
$$;

COMMIT;
