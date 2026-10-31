-- Deploy pitch:reference_tables to pg

BEGIN;

CREATE TABLE countries (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    iso_code CHAR(3) NOT NULL UNIQUE,      -- ISO 3166-1 alpha-3
    confederation TEXT                          -- UEFA, CONMEBOL, CAF, etc.
);

CREATE TABLE cities (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    country_id INTEGER NOT NULL REFERENCES countries (id),
    latitude NUMERIC(9, 6),
    longitude NUMERIC(9, 6),
    UNIQUE (name, country_id)
);

CREATE TABLE stadiums (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    city_id INTEGER REFERENCES cities (id),
    capacity INTEGER CHECK (capacity IS NULL OR capacity > 0),
    built_year SMALLINT,
    latitude NUMERIC(9, 6),
    longitude NUMERIC(9, 6)
);

CREATE TABLE referees (
    id SERIAL PRIMARY KEY,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    nationality_id INTEGER REFERENCES countries (id)
);

COMMIT;
