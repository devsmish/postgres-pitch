#!/bin/bash
# tests/partitions_test.sh
#
# Checks the yearly partitions of matches and match_events (changes
# `yearly_partitions` and `create_year_partitions`, see db/migrations/ and
# DATA_SOURCES.md) on the running cluster. Five parts:
#
#   1. Layout. The verify script of the change passes: every year from 1872 to
#      2027 has a partition named <table>_<year> with bounds at UTC midnight,
#      and there is a default partition. Partitions for later years are
#      allowed (the annual job adds them), so no exact count is asserted.
#   2. Routing. Rows at the edges of years land in the right partition: the
#      last second of 1871 and the first second of 1872 (default / first year),
#      year boundaries in the middle of the range, the join between the
#      baseline partitions (2024-2026) and the new ones, the last second of
#      2027, and a date far in the future (default). Rows are inserted in one
#      transaction that is rolled back, with explicit ids, so nothing remains
#      and no sequence moves.
#   3. Pruning. A query for a date range reads only the partitions of those
#      years.
#   4. Privileges. etl_writer and analytics_readonly have the same rights on a
#      new partition as on the baseline tables (default privileges).
#   5. The rule and the function. Partitions for the current and the next
#      calendar year exist (if this fails after 31 December, the annual job did
#      not run), the default partitions are empty, and create_year_partitions()
#      creates what is missing, does nothing the second time, refuses a year
#      too far ahead, and is closed to the demo roles; the function is tried in
#      rolled-back transactions.
#
# This test only reads, apart from the rolled-back transactions in parts 2 and 5.
#
# All queries run through `docker exec` inside one of the cluster's own
# containers (on the compose network, where `haproxy` resolves) and through the
# write endpoint, so no psql is needed on the host.
#
# Usage: run from anywhere with the cluster up and the migrations deployed:
#   bash tests/partitions_test.sh        # or: make partitions-test
#
# Prerequisites: docker, a populated .env, and `make migrate` done.
set -uo pipefail

# Git Bash (MSYS) on Windows rewrites arguments that look like unix paths
# before docker sees them. Harmless on Linux/macOS/WSL.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "ERROR: $REPO_ROOT/.env not found (cp .env.example .env)" >&2
  exit 1
fi

# Read the few values this test needs straight from .env, WITHOUT sourcing it
# (see the note in migrate_test.sh: the shell eats the backslashes of a Windows
# DATA_DIR, and Compose then cannot load the project).
env_value() {
  local line value
  line=$(grep -E "^[[:space:]]*$1=" "$REPO_ROOT/.env" | tail -n 1 || true)
  value=${line#*=}
  value=${value%$'\r'}
  value=${value%\"}
  value=${value#\"}
  value=${value%\'}
  value=${value#\'}
  if [ -z "$value" ]; then printf '%s' "$2"; else printf '%s' "$value"; fi
}
POSTGRES_DB="$(env_value POSTGRES_DB postgres_pitch)"
POSTGRES_USER="$(env_value POSTGRES_USER postgres_pitch_admin)"
POSTGRES_PASSWORD="$(env_value POSTGRES_PASSWORD "")"

DB="$POSTGRES_DB"
NODES=("postgresql0" "postgresql1" "postgresql2")
CONTAINER_PREFIX="postgres-pitch-"
WRITE_PORT=5000

FAILURES=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }

exec_container() {
  local n
  for n in "${NODES[@]}"; do
    if [ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX}${n}" 2>/dev/null)" = "true" ]; then
      echo "${CONTAINER_PREFIX}${n}"
      return 0
    fi
  done
  return 1
}

# run_sql <sql> -> output; psql's exit code. One statement or a few, one session.
run_sql() {
  local c
  c=$(exec_container) || { echo "no running cluster container"; return 99; }
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$c" \
    psql -h haproxy -p "$WRITE_PORT" -U "$POSTGRES_USER" -d "$DB" -tAqX -v ON_ERROR_STOP=1 -c "$1" 2>&1
}

# run_file <path> -> output; psql's exit code. The file is sent on stdin, as one session.
run_file() {
  local c
  c=$(exec_container) || { echo "no running cluster container"; return 99; }
  docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$c" \
    psql -h haproxy -p "$WRITE_PORT" -U "$POSTGRES_USER" -d "$DB" -tAqX -v ON_ERROR_STOP=1 < "$1" 2>&1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# scanned_tables: the partitions a plan mentions. The plan is cut into words and
# only exact partition names are kept, so index names (matches_2000_pkey) and the
# aliases the planner prints (matches_1) do not count.
scanned_tables() {
  tr -c 'a-z_0-9' '\n' | grep -x -E '(matches|match_events)_([0-9]{4}|default)' | sort -u | tr '\n' ' '
}

# pre-flight

echo "==> Pre-flight"
out=$(run_sql "SELECT count(*) FROM pg_inherits WHERE inhparent = 'public.matches'::regclass"); rc=$?
if [ $rc -ne 0 ]; then
  echo "ERROR: cannot query the write endpoint (:${WRITE_PORT}) or the table matches is missing: $(echo "$out" | head -n 1)" >&2
  echo "       Is the cluster up (make status) and the schema deployed (make migrate)?" >&2
  exit 1
fi
echo "    matches has ${out} partitions (the default one included)"

# 1. layout

echo ""
echo "--- 1. every year from 1872 to 2027 has a partition, bounded at UTC midnight ---"
OUT=$(run_file "$REPO_ROOT/db/migrations/verify/yearly_partitions.sql"); rc=$?
if [ $rc -eq 0 ]; then
  pass "the verify script of yearly_partitions passes (matches and match_events: 1872-2027 plus default)"
else
  fail "the verify script failed: $(echo "$OUT" | grep -m1 -i 'error' | cut -c1-200)"
  echo "       Is the change deployed? (make migrate)"
fi
OUT=$(run_sql "SELECT count(*) FROM pg_inherits WHERE inhparent = 'public.match_events'::regclass")
echo "    match_events has ${OUT} partitions (the default one included)"

# 2. routing

echo ""
echo "--- 2. rows at year boundaries land in the right partition (rolled back) ---"
cat > "$TMP/routing.sql" <<'EOF'
BEGIN;
INSERT INTO countries (id, name, iso_code) VALUES (2000000000, 'zz partitions test', 'ZZZ');
INSERT INTO competitions (id, name, type, country_id) VALUES (2000000000, 'zz partitions test', 'league', 2000000000);
INSERT INTO seasons (id, competition_id, year_start, year_end) VALUES (2000000000, 2000000000, 2000, 2001);
INSERT INTO clubs (id, name, country_id) VALUES
  (2000000001, 'zz home', 2000000000),
  (2000000002, 'zz away', 2000000000);
INSERT INTO matches (id, season_id, home_club_id, away_club_id, match_date)
SELECT 2000000000 + v.n, 2000000000, 2000000001, 2000000002, v.d::TIMESTAMPTZ
FROM (VALUES
  (1, '1871-12-31 23:59:59+00'),
  (2, '1872-01-01 00:00:00+00'),
  (3, '1899-12-31 23:59:59+00'),
  (4, '1900-01-01 00:00:00+00'),
  (5, '2023-12-31 23:59:59+00'),
  (6, '2024-01-01 00:00:00+00'),
  (7, '2026-12-31 23:59:59+00'),
  (8, '2027-01-01 00:00:00+00'),
  (9, '2027-12-31 23:59:59+00'),
  (10, '2100-01-01 00:00:00+00')
) AS v (n, d);
INSERT INTO match_events (id, match_id, match_date, event_type, minute)
SELECT id, id, match_date, 'goal', 10 FROM matches WHERE season_id = 2000000000;
SELECT
  to_char(m.match_date AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' ' || m.tableoid::REGCLASS || ' ' || e.tableoid::REGCLASS
FROM matches AS m
INNER JOIN match_events AS e ON m.id = e.match_id AND m.match_date = e.match_date
WHERE m.season_id = 2000000000
ORDER BY m.match_date;
ROLLBACK;
EOF
cat > "$TMP/routing.expected" <<'EOF'
1871-12-31 23:59:59 matches_default match_events_default
1872-01-01 00:00:00 matches_1872 match_events_1872
1899-12-31 23:59:59 matches_1899 match_events_1899
1900-01-01 00:00:00 matches_1900 match_events_1900
2023-12-31 23:59:59 matches_2023 match_events_2023
2024-01-01 00:00:00 matches_2024 match_events_2024
2026-12-31 23:59:59 matches_2026 match_events_2026
2027-01-01 00:00:00 matches_2027 match_events_2027
2027-12-31 23:59:59 matches_2027 match_events_2027
2100-01-01 00:00:00 matches_default match_events_default
EOF
OUT=$(run_file "$TMP/routing.sql"); rc=$?
if [ $rc -eq 0 ] && [ "$OUT" = "$(cat "$TMP/routing.expected")" ]; then
  pass "10 instants at year edges go to the expected matches_* and match_events_* partitions (also default for 1871 and 2100)"
else
  fail "unexpected routing (rc=$rc); got:"
  echo "$OUT" | head -n 14 | sed 's/^/        /'
fi
LEFT=$(run_sql "SELECT count(*) FROM countries WHERE id = 2000000000 OR name = 'zz partitions test'")
if [ "$LEFT" = "0" ]; then pass "the test rows were rolled back"; else fail "test rows are still in the database (count=${LEFT:-?})"; fi

# 3. pruning

echo ""
echo "--- 3. a date range reads only the partitions of those years ---"
PLAN=$(run_sql "EXPLAIN (COSTS OFF) SELECT 1 FROM matches WHERE match_date >= '2000-01-01 00:00:00+00' AND match_date < '2002-01-01 00:00:00+00'"); rc=$?
SCANNED=$(echo "$PLAN" | scanned_tables)
if [ $rc -eq 0 ] && [ "$SCANNED" = "matches_2000 matches_2001 " ]; then
  pass "2000-01-01 to 2002-01-01 reads only matches_2000 and matches_2001"
else
  fail "expected only matches_2000 and matches_2001, the plan reads: ${SCANNED:-nothing} (rc=$rc)"
fi
PLAN=$(run_sql "EXPLAIN (COSTS OFF) SELECT 1 FROM match_events WHERE match_date = '1872-11-30 00:00:00+00'"); rc=$?
SCANNED=$(echo "$PLAN" | scanned_tables)
if [ $rc -eq 0 ] && [ "$SCANNED" = "match_events_1872 " ]; then
  pass "a single date (1872-11-30) reads only match_events_1872"
else
  fail "expected only match_events_1872, the plan reads: ${SCANNED:-nothing} (rc=$rc)"
fi

# 4. privileges

echo ""
echo "--- 4. privileges on the new partitions ---"
PRIV_SQL="SELECT
  has_table_privilege('etl_writer', 'public.matches_1872', 'INSERT') || ',' ||
  has_table_privilege('etl_writer', 'public.match_events_2027', 'UPDATE') || ',' ||
  has_table_privilege('etl_writer', 'public.matches_1872', 'DELETE') || ',' ||
  has_table_privilege('analytics_readonly', 'public.matches_1872', 'SELECT') || ',' ||
  has_table_privilege('analytics_readonly', 'public.match_events_2027', 'SELECT') || ',' ||
  has_table_privilege('analytics_readonly', 'public.matches_1872', 'INSERT')"
OUT=$(run_sql "$PRIV_SQL"); rc=$?
EXPECTED="true,true,false,true,true,false"
if [ $rc -eq 0 ] && [ "$OUT" = "$EXPECTED" ]; then
  pass "etl_writer: INSERT/UPDATE yes, DELETE no; analytics_readonly: SELECT only (on partitions from the new change)"
else
  fail "unexpected privileges: got '${OUT}', expected '${EXPECTED}' (etl INSERT, etl UPDATE, etl DELETE, analytics SELECT x2, analytics INSERT)"
fi

# 5. the rule, the default partitions and the function

echo ""
echo "--- 5. the current and the next year, empty default partitions, the function that creates partitions ---"
THIS_YEAR=$(run_sql "SELECT extract(year FROM now() AT TIME ZONE 'UTC')::INTEGER")
NEXT_YEAR=$((THIS_YEAR + 1))
OUT=$(run_sql "SELECT count(*) FROM pg_class WHERE relname IN ('matches_${THIS_YEAR}', 'matches_${NEXT_YEAR}', 'match_events_${THIS_YEAR}', 'match_events_${NEXT_YEAR}')")
if [ "$OUT" = "4" ]; then
  pass "matches and match_events have partitions for ${THIS_YEAR} and ${NEXT_YEAR}"
else
  fail "partitions for ${THIS_YEAR} and ${NEXT_YEAR} are incomplete (found ${OUT:-?} of 4): did the annual job not run? SELECT create_year_partitions(${NEXT_YEAR}, $((THIS_YEAR + 2))) on the primary fixes it"
fi

# rows in a default partition block creating the partition of their year
OUT=$(run_sql "SELECT (SELECT count(*) FROM matches_default) + (SELECT count(*) FROM match_events_default)")
if [ "$OUT" = "0" ]; then
  pass "the default partitions are empty"
else
  fail "the default partitions hold ${OUT:-?} rows: creating the partitions of their years fails until they are moved (docs/runbooks/partition-maintenance.md)"
fi

OUT=$(run_sql "SELECT create_year_partitions(${THIS_YEAR}, ${NEXT_YEAR})")
if [ "$OUT" = "0" ]; then
  pass "create_year_partitions(${THIS_YEAR}, ${NEXT_YEAR}) creates nothing, everything is there (returns 0)"
else
  fail "create_year_partitions(${THIS_YEAR}, ${NEXT_YEAR}) returned '$(echo "$OUT" | head -n 1)' (expected 0). Is the change create_year_partitions deployed? (make migrate)"
fi

# a year that has no partitions yet, to try the function on (in a transaction that is rolled back)
FAR_YEAR=$(run_sql "SELECT min(g) FROM generate_series(${THIS_YEAR} + 3, ${THIS_YEAR} + 10) AS g WHERE to_regclass(format('public.matches_%s', g)) IS NULL AND to_regclass(format('public.match_events_%s', g)) IS NULL")
if [[ "$FAR_YEAR" =~ ^[0-9]+$ ]]; then
  {
    echo "SET client_min_messages = warning;"
    echo "BEGIN;"
    echo "SELECT create_year_partitions(${FAR_YEAR}, ${FAR_YEAR});"
    echo "SELECT create_year_partitions(${FAR_YEAR}, ${FAR_YEAR});"
    echo "ROLLBACK;"
  } > "$TMP/function.sql"
  OUT=$(run_file "$TMP/function.sql" | tr '\n' ' ')
  if [ "$OUT" = "2 0 " ]; then
    pass "create_year_partitions creates the 2 missing tables of ${FAR_YEAR} (returns 2), the second call creates none (returns 0); rolled back"
  else
    fail "create_year_partitions returned '${OUT}' for ${FAR_YEAR} (expected '2 0 ')"
  fi

  {
    echo "BEGIN;"
    echo "SET ROLE etl_writer;"
    echo "SELECT create_year_partitions(${FAR_YEAR}, ${FAR_YEAR});"
    echo "ROLLBACK;"
  } > "$TMP/denied.sql"
  OUT=$(run_file "$TMP/denied.sql"); rc=$?
  if [ $rc -ne 0 ] && echo "$OUT" | grep -q "permission denied for function"; then
    pass "etl_writer cannot run create_year_partitions (permission denied)"
  else
    fail "etl_writer was not refused (rc=$rc): $(echo "$OUT" | head -n 1)"
  fi
else
  fail "no free year between ${THIS_YEAR}+3 and ${THIS_YEAR}+10 to try the function on"
fi

OUT=$(run_sql "SELECT create_year_partitions(${THIS_YEAR}, ${THIS_YEAR} + 11)"); rc=$?
if [ $rc -ne 0 ] && echo "$OUT" | grep -q "refusing to create partitions"; then
  pass "a year more than 10 years ahead is refused"
else
  fail "a year 11 years ahead was not refused (rc=$rc): $(echo "$OUT" | head -n 1)"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
fi
echo "${FAILURES} check(s) failed."
exit 1
