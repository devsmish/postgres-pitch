-- Deploy pitch:players_and_careers to pg
-- requires: enum_types, reference_tables, clubs_competitions_seasons

BEGIN;

CREATE TABLE players (
    id SERIAL PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    birth_date DATE,
    birth_city_id INTEGER REFERENCES cities (id),
    nationality_id INTEGER REFERENCES countries (id),
    position PLAYER_POSITION,
    height_cm SMALLINT CHECK (height_cm IS NULL OR height_cm BETWEEN 140 AND 230),
    weight_kg SMALLINT CHECK (weight_kg IS NULL OR weight_kg BETWEEN 40 AND 150),
    external_ref JSONB DEFAULT '{}'::JSONB
);

CREATE TABLE player_career (
    id SERIAL PRIMARY KEY,
    player_id INTEGER NOT NULL REFERENCES players (id),
    club_id INTEGER NOT NULL REFERENCES clubs (id),
    season_id INTEGER NOT NULL REFERENCES seasons (id),
    transfer_type TRANSFER_TYPE,
    fee_amount NUMERIC(12, 2),
    fee_currency CHAR(3),                       -- ISO 4217
    UNIQUE (player_id, club_id, season_id)
);

COMMIT;
