-- =============================================================================
-- postgres-pitch — initial database schema
-- =============================================================================
-- This is a single bootstrap script for local development. Once the schema
-- stabilizes, it will be split into versioned migrations (Sqitch/Flyway) —
-- see Iteration 2 in ROADMAP.md.
--
-- Design rationale is documented in docs/decisions/0001-schema-design.md
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Enumerated types
-- -----------------------------------------------------------------------------

CREATE TYPE competition_type AS ENUM ('league', 'cup', 'international');

CREATE TYPE player_position AS ENUM (
    'goalkeeper', 'defender', 'midfielder', 'forward'
);

CREATE TYPE transfer_type AS ENUM (
    'permanent', 'loan', 'free', 'youth_promotion'
);

CREATE TYPE match_status AS ENUM (
    'scheduled', 'in_play', 'finished', 'postponed', 'cancelled'
);

CREATE TYPE match_event_type AS ENUM (
    'goal', 'own_goal', 'penalty_scored', 'penalty_missed',
    'yellow_card', 'second_yellow_card', 'red_card',
    'substitution_in', 'substitution_out'
);

-- -----------------------------------------------------------------------------
-- Reference data
-- -----------------------------------------------------------------------------

CREATE TABLE countries (
    id            SERIAL PRIMARY KEY,
    name          TEXT NOT NULL UNIQUE,
    iso_code      CHAR(3) NOT NULL UNIQUE,      -- ISO 3166-1 alpha-3
    confederation TEXT                          -- UEFA, CONMEBOL, CAF, etc.
);

CREATE TABLE cities (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    country_id INTEGER NOT NULL REFERENCES countries (id),
    latitude   NUMERIC(9, 6),
    longitude  NUMERIC(9, 6),
    UNIQUE (name, country_id)
);

CREATE TABLE stadiums (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    city_id    INTEGER REFERENCES cities (id),
    capacity   INTEGER CHECK (capacity IS NULL OR capacity > 0),
    built_year SMALLINT,
    latitude   NUMERIC(9, 6),
    longitude  NUMERIC(9, 6)
);

CREATE TABLE referees (
    id             SERIAL PRIMARY KEY,
    first_name     TEXT NOT NULL,
    last_name      TEXT NOT NULL,
    nationality_id INTEGER REFERENCES countries (id)
);

-- -----------------------------------------------------------------------------
-- Clubs, competitions, seasons
-- -----------------------------------------------------------------------------

CREATE TABLE clubs (
    id            SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    short_name    TEXT,
    founded_year  SMALLINT,
    stadium_id    INTEGER REFERENCES stadiums (id),
    country_id    INTEGER NOT NULL REFERENCES countries (id),
    external_ref  JSONB DEFAULT '{}'::JSONB      -- ids from source APIs, for dedup/sync
);

CREATE TABLE competitions (
    id         SERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    type       competition_type NOT NULL,
    country_id INTEGER REFERENCES countries (id)  -- NULL for international competitions
);

CREATE TABLE seasons (
    id             SERIAL PRIMARY KEY,
    competition_id INTEGER NOT NULL REFERENCES competitions (id),
    year_start     SMALLINT NOT NULL,
    year_end       SMALLINT NOT NULL,
    UNIQUE (competition_id, year_start)
);

-- Tracks club identity/name/league changes over time (renames, promotions,
-- relegations) — useful for historical accuracy in a domain where clubs
-- change names or merge.
CREATE TABLE club_history (
    id             SERIAL PRIMARY KEY,
    club_id        INTEGER NOT NULL REFERENCES clubs (id),
    season_id      INTEGER NOT NULL REFERENCES seasons (id),
    name_at_time   TEXT NOT NULL,
    league_id      INTEGER REFERENCES competitions (id),
    final_position SMALLINT,
    UNIQUE (club_id, season_id)
);

-- -----------------------------------------------------------------------------
-- Players and careers
-- -----------------------------------------------------------------------------

CREATE TABLE players (
    id             SERIAL PRIMARY KEY,
    first_name     TEXT NOT NULL,
    last_name      TEXT NOT NULL,
    birth_date     DATE,
    birth_city_id  INTEGER REFERENCES cities (id),
    nationality_id INTEGER REFERENCES countries (id),
    position       player_position,
    height_cm      SMALLINT CHECK (height_cm IS NULL OR height_cm BETWEEN 140 AND 230),
    weight_kg      SMALLINT CHECK (weight_kg IS NULL OR weight_kg BETWEEN 40 AND 150),
    external_ref   JSONB DEFAULT '{}'::JSONB
);

CREATE TABLE player_career (
    id            SERIAL PRIMARY KEY,
    player_id     INTEGER NOT NULL REFERENCES players (id),
    club_id       INTEGER NOT NULL REFERENCES clubs (id),
    season_id     INTEGER NOT NULL REFERENCES seasons (id),
    transfer_type transfer_type,
    fee_amount    NUMERIC(12, 2),
    fee_currency  CHAR(3),                       -- ISO 4217
    UNIQUE (player_id, club_id, season_id)
);

-- -----------------------------------------------------------------------------
-- Matches and match events (partitioned by year — see ADR 0001)
-- -----------------------------------------------------------------------------

CREATE TABLE matches (
    id            BIGSERIAL,
    season_id     INTEGER NOT NULL REFERENCES seasons (id),
    home_club_id  INTEGER NOT NULL REFERENCES clubs (id),
    away_club_id  INTEGER NOT NULL REFERENCES clubs (id) CHECK (away_club_id <> home_club_id),
    stadium_id    INTEGER REFERENCES stadiums (id),
    referee_id    INTEGER REFERENCES referees (id),
    match_date    TIMESTAMPTZ NOT NULL,
    matchday      SMALLINT,
    status        match_status NOT NULL DEFAULT 'scheduled',
    home_score    SMALLINT,
    away_score    SMALLINT,
    external_ref  JSONB DEFAULT '{}'::JSONB,
    PRIMARY KEY (id, match_date)
) PARTITION BY RANGE (match_date);

-- match_events carries a denormalized match_date so it can be partitioned
-- along the same axis as matches — trades a small amount of redundancy for
-- partition pruning on both tables during time-range queries.
CREATE TABLE match_events (
    id          BIGSERIAL,
    match_id    BIGINT NOT NULL,
    match_date  TIMESTAMPTZ NOT NULL,
    player_id   INTEGER REFERENCES players (id),
    event_type  match_event_type NOT NULL,
    minute      SMALLINT NOT NULL CHECK (minute BETWEEN 0 AND 130),
    extra_time  SMALLINT,
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

-- -----------------------------------------------------------------------------
-- Standings — computed, not stored directly (see ADR 0001)
-- -----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW standings AS
WITH results AS (
    SELECT
        season_id,
        home_club_id AS club_id,
        CASE WHEN home_score > away_score THEN 3
             WHEN home_score = away_score THEN 1
             ELSE 0 END AS points,
        (home_score > away_score)::INT  AS win,
        (home_score = away_score)::INT  AS draw,
        (home_score < away_score)::INT  AS loss,
        home_score AS goals_for,
        away_score AS goals_against
    FROM matches
    WHERE status = 'finished'
    UNION ALL
    SELECT
        season_id,
        away_club_id AS club_id,
        CASE WHEN away_score > home_score THEN 3
             WHEN away_score = home_score THEN 1
             ELSE 0 END AS points,
        (away_score > home_score)::INT AS win,
        (away_score = home_score)::INT AS draw,
        (away_score < home_score)::INT AS loss,
        away_score AS goals_for,
        home_score AS goals_against
    FROM matches
    WHERE status = 'finished'
)
SELECT
    season_id,
    club_id,
    COUNT(*)                       AS played,
    SUM(win)                       AS wins,
    SUM(draw)                      AS draws,
    SUM(loss)                      AS losses,
    SUM(goals_for)                 AS goals_for,
    SUM(goals_against)             AS goals_against,
    SUM(goals_for) - SUM(goals_against) AS goal_difference,
    SUM(points)                    AS points
FROM results
GROUP BY season_id, club_id
WITH NO DATA;

-- Refreshed on a schedule (pg_cron) once matches are loaded — see
-- ROADMAP.md, Iteration 6 (scheduled ETL jobs).

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------

CREATE INDEX idx_clubs_country            ON clubs (country_id);
CREATE INDEX idx_players_nationality      ON players (nationality_id);
CREATE INDEX idx_players_last_name        ON players (last_name);
CREATE INDEX idx_player_career_player     ON player_career (player_id);
CREATE INDEX idx_player_career_club       ON player_career (club_id);

CREATE INDEX idx_matches_season           ON matches (season_id);
CREATE INDEX idx_matches_home_club        ON matches (home_club_id);
CREATE INDEX idx_matches_away_club        ON matches (away_club_id);
-- Partial index: most operational queries look at upcoming/in-play matches,
-- not the full historical table.
CREATE INDEX idx_matches_upcoming ON matches (match_date)
    WHERE status IN ('scheduled', 'in_play');

CREATE INDEX idx_match_events_match        ON match_events (match_id);
CREATE INDEX idx_match_events_player       ON match_events (player_id);

CREATE UNIQUE INDEX idx_standings_season_club ON standings (season_id, club_id);
