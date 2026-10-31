-- Verify pitch:reference_tables on pg

SELECT
    id,
    name,
    iso_code,
    confederation
FROM countries
WHERE FALSE;

SELECT
    id,
    name,
    country_id,
    latitude,
    longitude
FROM cities
WHERE FALSE;

SELECT
    id,
    name,
    city_id,
    capacity,
    built_year,
    latitude,
    longitude
FROM stadiums
WHERE FALSE;

SELECT
    id,
    first_name,
    last_name,
    nationality_id
FROM referees
WHERE FALSE;
