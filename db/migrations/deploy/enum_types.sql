-- Deploy pitch:enum_types to pg

BEGIN;

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

COMMIT;
