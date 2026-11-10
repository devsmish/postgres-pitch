-- Deploy pitch:standings_view to pg
-- requires: matches_and_events

BEGIN;

CREATE MATERIALIZED VIEW standings AS
WITH results AS (
    SELECT
        season_id,
        home_club_id AS club_id,
        CASE
            WHEN home_score > away_score THEN 3
            WHEN home_score = away_score THEN 1
            ELSE 0
        END AS points,
        (home_score > away_score)::INT AS win,
        (home_score = away_score)::INT AS draw,
        (home_score < away_score)::INT AS loss,
        home_score AS goals_for,
        away_score AS goals_against
    FROM matches
    WHERE status = 'finished'
    UNION ALL
    SELECT
        season_id,
        away_club_id AS club_id,
        CASE
            WHEN away_score > home_score THEN 3
            WHEN away_score = home_score THEN 1
            ELSE 0
        END AS points,
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
    COUNT(*) AS played,
    SUM(win) AS wins,
    SUM(draw) AS draws,
    SUM(loss) AS losses,
    SUM(goals_for) AS goals_for,
    SUM(goals_against) AS goals_against,
    SUM(goals_for) - SUM(goals_against) AS goal_difference,
    SUM(points) AS points
FROM results
GROUP BY season_id, club_id
WITH NO DATA;

-- Refreshed on a schedule (pg_cron) once matches are loaded — see
-- ROADMAP.md, Iteration 6 (scheduled ETL jobs).

CREATE UNIQUE INDEX idx_standings_season_club ON standings (season_id, club_id);

COMMIT;
