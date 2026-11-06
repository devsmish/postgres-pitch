-- Deploy pitch:matches_and_events to pg
-- requires: enum_types, clubs_competitions_seasons, players_and_careers

BEGIN;

CREATE TABLE matches (
    id BIGSERIAL,
    season_id INTEGER NOT NULL REFERENCES seasons (id),
    home_club_id INTEGER NOT NULL REFERENCES clubs (id),
    away_club_id INTEGER NOT NULL REFERENCES clubs (id) CHECK (away_club_id <> home_club_id),
    stadium_id INTEGER REFERENCES stadiums (id),
    referee_id INTEGER REFERENCES referees (id),
    match_date TIMESTAMPTZ NOT NULL,
    matchday SMALLINT,
    status MATCH_STATUS NOT NULL DEFAULT 'scheduled',
    home_score SMALLINT,
    away_score SMALLINT,
    external_ref JSONB DEFAULT '{}'::JSONB,
    PRIMARY KEY (id, match_date)
) PARTITION BY RANGE (match_date);

-- match_events carries a denormalized match_date so it can be partitioned
-- along the same axis as matches — trades a small amount of redundancy for
-- partition pruning on both tables during time-range queries.
CREATE TABLE match_events (
    id BIGSERIAL,
    match_id BIGINT NOT NULL,
    match_date TIMESTAMPTZ NOT NULL,
    player_id INTEGER REFERENCES players (id),
    event_type MATCH_EVENT_TYPE NOT NULL,
    minute SMALLINT NOT NULL CHECK (minute BETWEEN 0 AND 130),
    extra_time SMALLINT,
    PRIMARY KEY (id, match_date),
    FOREIGN KEY (match_id, match_date) REFERENCES matches (id, match_date)
) PARTITION BY RANGE (match_date);

-- Example yearly partitions — in practice these are created ahead of time
-- by a scheduled job (see scripts/etl or an Ansible cron task) rather than
-- by hand. pg_partman is a reasonable alternative to manual DDL here.
CREATE TABLE matches_2024 PARTITION OF matches
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE matches_2025 PARTITION OF matches
FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE matches_2026 PARTITION OF matches
FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE matches_default PARTITION OF matches DEFAULT;

CREATE TABLE match_events_2024 PARTITION OF match_events
FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE match_events_2025 PARTITION OF match_events
FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE match_events_2026 PARTITION OF match_events
FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE match_events_default PARTITION OF match_events DEFAULT;

COMMIT;
