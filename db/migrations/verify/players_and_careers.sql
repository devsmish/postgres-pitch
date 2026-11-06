-- Verify pitch:players_and_careers on pg

SELECT
    id,
    first_name,
    last_name,
    birth_date,
    birth_city_id,
    nationality_id,
    position,
    height_cm,
    weight_kg,
    external_ref
FROM players
WHERE FALSE;

SELECT
    id,
    player_id,
    club_id,
    season_id,
    transfer_type,
    fee_amount,
    fee_currency
FROM player_career
WHERE FALSE;
