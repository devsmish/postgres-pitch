-- Deploy pitch:clubs_competitions_seasons to pg
-- requires: enum_types, reference_tables

BEGIN;

CREATE TABLE clubs (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    short_name TEXT,
    founded_year SMALLINT,
    stadium_id INTEGER REFERENCES stadiums (id),
    country_id INTEGER NOT NULL REFERENCES countries (id),
    external_ref JSONB DEFAULT '{}'::JSONB      -- ids from source APIs, for dedup/sync
);

CREATE TABLE competitions (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    type COMPETITION_TYPE NOT NULL,
    country_id INTEGER REFERENCES countries (id)  -- NULL for international competitions
);

CREATE TABLE seasons (
    id SERIAL PRIMARY KEY,
    competition_id INTEGER NOT NULL REFERENCES competitions (id),
    year_start SMALLINT NOT NULL,
    year_end SMALLINT NOT NULL,
    UNIQUE (competition_id, year_start)
);

-- Tracks club identity/name/league changes over time (renames, promotions,
-- relegations) — useful for historical accuracy in a domain where clubs
-- change names or merge.
CREATE TABLE club_history (
    id SERIAL PRIMARY KEY,
    club_id INTEGER NOT NULL REFERENCES clubs (id),
    season_id INTEGER NOT NULL REFERENCES seasons (id),
    name_at_time TEXT NOT NULL,
    league_id INTEGER REFERENCES competitions (id),
    final_position SMALLINT,
    UNIQUE (club_id, season_id)
);

COMMIT;
