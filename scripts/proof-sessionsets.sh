#!/usr/bin/env bash
# Proof of the session SETs collection (migration 0055, internal/collect/sessionsets.go, task 58) on the sandbox: a
# monitored database of its own with pg_stat_statements, a pg_monitor login that reads it, and a role that changes its
# own settings.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox (pg_stat_statements preloaded, track_utility on); the proof
#                      makes its own repository database, a monitored database, a pg_monitor login and a role, all with
#                      a random suffix, and drops them at the end. track_utility is turned off for the monitored
#                      database alone (ALTER DATABASE), never for the server.
#
# Expected (written before the first run):
#  A. the role runs SET enable_hashjoin = off three times and SET search_path = public once (one session), then
#     collect -once session_sets: session_sets_state 'ok', track_utility 'on'; the role's rows, as
#     command|setting|value|value_hidden|planner|calls:
#       SET|enable_hashjoin||true|true|3      (PostgreSQL 17+ keeps $1 for the value: the sandbox is 18)
#       SET|search_path||true|false|1
#     session_sets_window over the last hour: enable_hashjoin calls_in_window 3, fires true; search_path 1, fires false.
#     sessionsets_findings for the instance: exactly one row, setting enable_hashjoin, its detail naming the role.
#     [first run: two rows - pg_stat_statements is server-wide and another role (postgres, in the sandbox database) had run
#     SET enable_hashjoin in the last hour; the view was right, the expectation too wide. Expected now: exactly one row
#     whose detail names the proof's role, and none for search_path.]
#  B. the role runs SET enable_hashjoin = off twice more, collect: calls 5, a second sample row of 2, calls_in_window 5;
#     a collect with nothing new adds no sample row of the role.
#     [first run: the sample count was the instance's, and other sessions on the shared sandbox ran SETs between the reads
#     (25 -> 29); the count is now the proof's role's alone.]
#  C. ALTER DATABASE <monitored> SET pg_stat_statements.track_utility = off, collect: state 'not available', the reason
#     starts 'pg_stat_statements.track_utility is off', track_utility 'off'; the stored rows stay (2 for the role);
#     sessionsets_findings for the instance: 0 rows.
#  D. track_utility back on and pg_stat_statements dropped from the monitored database, collect: state 'not available',
#     the reason 'pg_stat_statements is not installed in the connected database'; findings 0.
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_setsproof_$SUF; MDB=pgvigil_setsmon_db_$SUF; MON=pgvigil_setsmon_$SUF; MONPW=p$RANDOM$RANDOM
APP=pgvigil_setsapp_$SUF; APPPW=p$RANDOM$RANDOM
CFG=$(mktemp)
cleanup() {
  rm -f "$CFG"
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $REPO_DB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop database if exists $MDB with (force)" >/dev/null 2>&1 || true
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" -c "drop role if exists $APP" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
psql "$ADMIN_DSN" -XAtq -c "create database $REPO_DB" -c "create database $MDB" \
  -c "create role $MON login password '$MONPW' in role pg_monitor" -c "create role $APP login password '$APPPW'" >/dev/null
psql "$ADMIN_DSN dbname=$MDB" -XAtq -c "create extension pg_stat_statements" >/dev/null
[[ $(psql "$ADMIN_DSN dbname=$MDB" -XAt -c "show pg_stat_statements.track_utility") == on ]] || fail "track_utility is not on in the sandbox"
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export SBX_DSN="$ADMIN_DSN dbname=$MDB user=$MON password=$MONPW"
APP_DSN="$ADMIN_DSN dbname=$MDB user=$APP password=$APPPW"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-sets-$SUF
    dsn: env:SBX_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once session_sets >/dev/null 2>&1 || fail "collect -once session_sets failed"; }
i=$(q "select instance_id from pgvigil.instances where name = 'proof-sets-$SUF'" 2>/dev/null || true)
rows() { q "select command || '|' || setting || '|' || coalesce(value, '') || '|' || value_hidden || '|' || planner || '|' || calls
              from pgvigil.session_sets s where s.instance_id = $i and s.rolname = '$APP' order by setting"; }

echo "--- A. three SET enable_hashjoin and one SET search_path"
psql "$APP_DSN" -XAtq -c "SET enable_hashjoin = off" -c "SET enable_hashjoin = off" -c "SET enable_hashjoin = off" \
  -c "SET search_path = public" >/dev/null
collect
i=$(q "select instance_id from pgvigil.instances where name = 'proof-sets-$SUF'")
st=$(q "select status || '|' || track_utility from pgvigil.session_sets_state where instance_id = $i")
echo "state: $st"; [[ $st == "ok|on" ]] || fail "A: state '$st'"
A=$(rows); echo "$A"
[[ $A == $'SET|enable_hashjoin||true|true|3\nSET|search_path||true|false|1' ]] || fail "A: the role's rows"
W=$(q "select setting || '|' || calls_in_window || '|' || fires from pgvigil.session_sets_window($i, now() - interval '1 hour', now())
        where rolname = '$APP' order by setting")
echo "$W"; [[ $W == $'enable_hashjoin|3|true\nsearch_path|1|false' ]] || fail "A: the window's rows"
F=$(q "select string_agg(setting, ',') from pgvigil.sessionsets_findings where instance_id = $i and detail like '%role $APP %'")
echo "findings of the role: $F"; [[ $F == "enable_hashjoin" ]] || fail "A: the role's findings are '$F'"
q "select value || ' :: ' || detail from pgvigil.sessionsets_findings where instance_id = $i and detail like '%role $APP %'"

echo "--- B. two more, then a read with nothing new"
psql "$APP_DSN" -XAtq -c "SET enable_hashjoin = off" -c "SET enable_hashjoin = off" >/dev/null
collect
B=$(q "select s.calls || '|' || (select string_agg(x.calls::text, ',' order by x.snapshot_at) from pgvigil.session_sets_sample x
                                   where x.instance_id = s.instance_id and x.queryid = s.queryid and x.userid = s.userid)
         from pgvigil.session_sets s where s.instance_id = $i and s.rolname = '$APP' and s.setting = 'enable_hashjoin'")
echo "$B"; [[ $B == "5|3,2" ]] || fail "B: calls and samples '$B'"
n1=$(q "select count(*) from pgvigil.session_sets_sample x join pgvigil.session_sets s using (instance_id, dbid, userid, queryid, toplevel) where x.instance_id = $i and s.rolname = '$APP'")
collect
n2=$(q "select count(*) from pgvigil.session_sets_sample x join pgvigil.session_sets s using (instance_id, dbid, userid, queryid, toplevel) where x.instance_id = $i and s.rolname = '$APP'")
cw=$(q "select calls_in_window from pgvigil.session_sets_window($i, now() - interval '1 hour', now()) where rolname = '$APP' and setting = 'enable_hashjoin'")
echo "samples $n1 -> $n2, calls_in_window $cw"
[[ $n1 == "$n2" && $cw == 5 ]] || fail "B: a read with nothing new added samples ($n1 -> $n2) or the window reads $cw"

echo "--- C. track_utility off for the monitored database"
psql "$ADMIN_DSN" -XAtq -c "alter database $MDB set pg_stat_statements.track_utility = off" >/dev/null
collect
C=$(q "select status || '|' || (reason like 'pg_stat_statements.track_utility is off%') || '|' || track_utility from pgvigil.session_sets_state where instance_id = $i")
echo "$C"; [[ $C == "not available|true|off" ]] || fail "C: state '$C'"
[[ $(q "select count(*) from pgvigil.session_sets where instance_id = $i and rolname = '$APP'") == 2 ]] || fail "C: the stored rows did not stay"
[[ $(q "select count(*) from pgvigil.sessionsets_findings where instance_id = $i") == 0 ]] || fail "C: a finding with track_utility off"

echo "--- D. pg_stat_statements absent"
psql "$ADMIN_DSN" -XAtq -c "alter database $MDB reset pg_stat_statements.track_utility" >/dev/null
psql "$ADMIN_DSN dbname=$MDB" -XAtq -c "drop extension pg_stat_statements" >/dev/null
collect
D=$(q "select status || '|' || reason from pgvigil.session_sets_state where instance_id = $i")
echo "$D"; [[ $D == "not available|pg_stat_statements is not installed in the connected database" ]] || fail "D: state '$D'"
[[ $(q "select count(*) from pgvigil.sessionsets_findings where instance_id = $i") == 0 ]] || fail "D: a finding without the extension"

echo "PASS: proof-sessionsets (A the planner SET found with calls 3 and fires, search_path listed and silent; B growth and no growth; C track_utility off: not available, no finding; D extension absent: not available)"
