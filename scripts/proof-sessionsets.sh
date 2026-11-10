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
#  [58 review fold, expected before the rerun: a first read of an instance counts nothing (its pg_stat_statements may
#   hold months of history), so A starts with a baseline collect before the role's SETs: then the role's entries are new
#   since an ok read and count. A's figures stay as below. New section E, before C.]
#  A. a baseline collect; the role runs SET enable_hashjoin = off three times and SET search_path = public once (one
#     session), then collect -once session_sets: session_sets_state 'ok', track_utility 'on'; the role's rows, as
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
#  E. the monitor's own role has no row for its session setup (default_transaction_read_only, statement_timeout,
#     lock_timeout, application_name: not the application's), and [join review fold] its other SETs are kept: the
#     monitor's login runs SET enable_hashjoin = off once, and after the collect the monitor's role has exactly one
#     enable_hashjoin row (a login the application shares with the monitor still shows the application's SETs);
#     the role runs SET enable_hashjoin TO DEFAULT, collect: a row command RESET for enable_hashjoin, and the role's
#     findings are still exactly enable_hashjoin (the SET of A and B, not the RESET); a late import_session_sets
#     (snapshot one hour before the last read, the entry at 99 calls) adds no sample of the role (count unchanged) and
#     leaves calls at 5.
#  F. [join review fold, expected before the run] the value against the server's (the PG 16 shape, where the text keeps
#     the value; the sandbox is 18, so the rows come in through import_session_sets as a current read): five rows of
#     the role, calls 7 each, queryids 9001..9005: enable_hashjoin = on, enable_hashjoin = off, enable_hashjoin = true,
#     jit = off, jit = on, with instance_state.non_default_settings holding jit = off. session_sets_window fires:
#     9001 false (the server's own value), 9002 true, 9003 false (true is on), 9004 false (the server's jit is off),
#     9005 true; sessionsets_findings of the role: enable_hashjoin (A's, hidden value), enable_hashjoin (9002) and jit
#     (9005), never a row whose value is on, true or jit's off.
#  C. ALTER DATABASE <monitored> SET pg_stat_statements.track_utility = off, collect: state 'not available', the reason
#     starts 'pg_stat_statements.track_utility is off', track_utility 'off'; the stored rows stay (8 for the role: A's
#     two, E's RESET row, F's five); sessionsets_findings for the instance: 0 rows.
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

echo "--- A. a baseline read, then three SET enable_hashjoin and one SET search_path"
collect
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

echo "--- E. the monitor's rows, TO DEFAULT, a late read"
psql "$SBX_DSN" -XAtq -c "SET enable_hashjoin = off" >/dev/null
psql "$APP_DSN" -XAtq -c "SET enable_hashjoin TO DEFAULT" >/dev/null
collect
E1=$(q "select count(*) from pgvigil.session_sets where instance_id = $i and rolname = '$MON'
          and setting in ('default_transaction_read_only', 'statement_timeout', 'lock_timeout', 'application_name')")
E0=$(q "select count(*) from pgvigil.session_sets where instance_id = $i and rolname = '$MON' and setting = 'enable_hashjoin'")
E2=$(q "select string_agg(command, ',' order by command) from pgvigil.session_sets where instance_id = $i and rolname = '$APP' and setting = 'enable_hashjoin'")
E3=$(q "select string_agg(setting, ',') from pgvigil.sessionsets_findings where instance_id = $i and detail like '%role $APP %'")
ns1=$(q "select count(*) from pgvigil.session_sets_sample x join pgvigil.session_sets s using (instance_id, dbid, userid, queryid, toplevel) where x.instance_id = $i and s.rolname = '$APP'")
late=$(q "select json_build_array(json_build_object('kind', 'state', 'status', 'ok', 'track_utility', 'on'),
            json_build_object('kind', 'set', 'dbid', dbid, 'userid', userid, 'rolname', rolname, 'datname', datname, 'queryid', queryid,
                              'toplevel', toplevel, 'command', command, 'setting', setting, 'value', value, 'value_hidden', value_hidden,
                              'planner', planner, 'calls', 99, 'query', query))
          from pgvigil.session_sets where instance_id = $i and rolname = '$APP' and setting = 'enable_hashjoin' and command = 'SET'")
q "select pgvigil.import_session_sets($i, (select last_seen from pgvigil.session_sets where instance_id = $i and rolname = '$APP' and setting = 'enable_hashjoin' and command = 'SET') - interval '1 hour', '$late'::jsonb)" >/dev/null
ns2=$(q "select count(*) from pgvigil.session_sets_sample x join pgvigil.session_sets s using (instance_id, dbid, userid, queryid, toplevel) where x.instance_id = $i and s.rolname = '$APP'")
cl=$(q "select calls from pgvigil.session_sets where instance_id = $i and rolname = '$APP' and setting = 'enable_hashjoin' and command = 'SET'")
echo "monitor setup rows $E1, monitor enable_hashjoin rows $E0; enable_hashjoin commands $E2; findings $E3; samples $ns1 -> $ns2 after a late read; calls $cl"
[[ $E1 == 0 && $E0 == 1 && $E2 == "RESET,SET" && $E3 == "enable_hashjoin" && $ns1 == "$ns2" && $cl == 5 ]] || fail "E"

echo "--- F. a SET to the server's own value fires nothing (the PG 16 shape, imported)"
q "insert into pgvigil.instance_state (instance_id, snapshot_at, non_default_settings) values ($i, now(), '[{\"name\": \"jit\", \"value\": \"off\"}]')
   on conflict (instance_id) do update set non_default_settings = excluded.non_default_settings" >/dev/null
Fp=$(q "select json_build_array(json_build_object('kind', 'state', 'status', 'ok', 'track_utility', 'on'),
          json_build_object('kind', 'set', 'dbid', dbid, 'userid', userid, 'rolname', rolname, 'datname', datname, 'queryid', 9001, 'toplevel', true, 'command', 'SET', 'setting', 'enable_hashjoin', 'value', 'on', 'value_hidden', false, 'planner', true, 'calls', 7, 'query', 'SET enable_hashjoin = on'),
          json_build_object('kind', 'set', 'dbid', dbid, 'userid', userid, 'rolname', rolname, 'datname', datname, 'queryid', 9002, 'toplevel', true, 'command', 'SET', 'setting', 'enable_hashjoin', 'value', 'off', 'value_hidden', false, 'planner', true, 'calls', 7, 'query', 'SET enable_hashjoin = off'),
          json_build_object('kind', 'set', 'dbid', dbid, 'userid', userid, 'rolname', rolname, 'datname', datname, 'queryid', 9003, 'toplevel', true, 'command', 'SET', 'setting', 'enable_hashjoin', 'value', 'true', 'value_hidden', false, 'planner', true, 'calls', 7, 'query', 'SET enable_hashjoin = true'),
          json_build_object('kind', 'set', 'dbid', dbid, 'userid', userid, 'rolname', rolname, 'datname', datname, 'queryid', 9004, 'toplevel', true, 'command', 'SET', 'setting', 'jit', 'value', 'off', 'value_hidden', false, 'planner', true, 'calls', 7, 'query', 'SET jit = off'),
          json_build_object('kind', 'set', 'dbid', dbid, 'userid', userid, 'rolname', rolname, 'datname', datname, 'queryid', 9005, 'toplevel', true, 'command', 'SET', 'setting', 'jit', 'value', 'on', 'value_hidden', false, 'planner', true, 'calls', 7, 'query', 'SET jit = on'))
        from pgvigil.session_sets where instance_id = $i and rolname = '$APP' and setting = 'enable_hashjoin' and command = 'SET'")
q "select pgvigil.import_session_sets($i, now(), '$Fp'::jsonb)" >/dev/null
F1=$(q "select string_agg(queryid || ':' || fires, ',' order by queryid) from pgvigil.session_sets_window($i, now() - interval '1 hour', now())
         where rolname = '$APP' and queryid between 9001 and 9005")
F2=$(q "select string_agg(setting || '=' || value, ',' order by setting, value) from pgvigil.sessionsets_findings where instance_id = $i and detail like '%role $APP %'")
echo "fires: $F1; findings of the role: $F2"
[[ $F1 == "9001:false,9002:true,9003:false,9004:false,9005:true" ]] || fail "F: fires '$F1'"
[[ $F2 == "enable_hashjoin=(value hidden: PostgreSQL 17+ keeps \$1),enable_hashjoin=off,jit=on" ]] || fail "F: findings '$F2'"

echo "--- C. track_utility off for the monitored database"
psql "$ADMIN_DSN" -XAtq -c "alter database $MDB set pg_stat_statements.track_utility = off" >/dev/null
collect
C=$(q "select status || '|' || (reason like 'pg_stat_statements.track_utility is off%') || '|' || track_utility from pgvigil.session_sets_state where instance_id = $i")
echo "$C"; [[ $C == "not available|true|off" ]] || fail "C: state '$C'"
[[ $(q "select count(*) from pgvigil.session_sets where instance_id = $i and rolname = '$APP'") == 8 ]] || fail "C: the stored rows did not stay"
[[ $(q "select count(*) from pgvigil.sessionsets_findings where instance_id = $i") == 0 ]] || fail "C: a finding with track_utility off"

echo "--- D. pg_stat_statements absent"
psql "$ADMIN_DSN" -XAtq -c "alter database $MDB reset pg_stat_statements.track_utility" >/dev/null
psql "$ADMIN_DSN dbname=$MDB" -XAtq -c "drop extension pg_stat_statements" >/dev/null
collect
D=$(q "select status || '|' || reason from pgvigil.session_sets_state where instance_id = $i")
echo "$D"; [[ $D == "not available|pg_stat_statements is not installed in the connected database" ]] || fail "D: state '$D'"
[[ $(q "select count(*) from pgvigil.sessionsets_findings where instance_id = $i") == 0 ]] || fail "D: a finding without the extension"

echo "PASS: proof-sessionsets (A the planner SET found with calls 3 and fires, search_path listed and silent; B growth and no growth; E the monitor's setup left out and its other SETs kept, TO DEFAULT, a late read; F a SET to the server's value fires nothing; C track_utility off: not available, no finding; D extension absent: not available)"
