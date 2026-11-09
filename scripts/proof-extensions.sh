#!/usr/bin/env bash
# Proof of the extensions collection (0019): the per-database rows, the preload list, the change history and
# the extension findings.
#
#   ADMIN_DSN   a superuser connection to the sandbox server (default: PGVIGIL_REPO_DSN). The proof makes its own
#               repository database, two target databases and a pg_monitor-only login, all with a random suffix,
#               and drops them at the end; nothing that exists before the run is touched. The sandbox server is
#               expected to preload pg_stat_statements and to carry the contrib package (amcheck, pg_trgm, hstore).
#
# Expected (written before the first run):
#  A. collect -once extensions as the pg_monitor-only login, the target DSN on tgt1 (tgt2 a second database):
#     - database_extensions: tgt1 has plpgsql, amcheck 1.0 and pg_trgm (at the server's default), tgt2 has plpgsql
#       and hstore 1.4; two dbids
#     - instance_extensions: pg_stat_statements available with preloaded_via {shared}; amcheck available with
#       default_version 1.5 (the sandbox's package)
#     - instance_extension_settings: shared_preload_libraries present and naming pg_stat_statements;
#       pg_stat_statements.track present (the library is loaded)
#     - extension_findings for the instance, exactly the outdated ones and the amcheck presence:
#         amcheck|warning|<tgt1>: 1.0, suggested 'ALTER EXTENSION amcheck UPDATE (to 1.5)'
#         hstore|warning|<tgt2>: 1.4
#         amcheck|info|installed in <tgt1>
#       (filtered to the two proof databases: other sandbox databases are read too)
#       and no pg_stat_statements row (available, preloaded and created in the sandbox database)
#     - extension_fleet: amcheck outdated_dbs >= 1 and installed in tgt1; no extension_history rows (first read)
#  B. ALTER EXTENSION amcheck UPDATE in tgt1, DROP EXTENSION hstore in tgt2, CREATE EXTENSION pg_trgm in tgt2,
#     collect again: extension_history gains exactly, for the two proof databases,
#         <tgt1>|amcheck|updated|1.0|1.5, <tgt2>|hstore|removed|1.4|, <tgt2>|pg_trgm|installed||1.6
#     the hstore row is_present false; the amcheck and hstore warnings are gone; the collection status is ok
#  C. import_extensions seeded on scratch instances (the rules the sandbox cannot show):
#       x: pg_stat_statements not in pg_available_extensions -> exactly pg_stat_statements|warning|not available
#       y: shared list 'auto_explain,pg_hint_plan', pg_stat_statements available, auto_explain.log_min_duration 0 ms,
#          pg_hint_plan.enable_hint off -> exactly auto_explain|warning|0 ms, pg_hint_plan.enable_hint|warning|off,
#          pg_stat_statements|warning|not in shared_preload_libraries
#       z: shared list '$libdir/pg_stat_statements' (parsed to pg_stat_statements), pg_hint_plan created in db app and
#          in no list, pg_stat_statements.track none, pg_wait_sampling installed in app -> exactly
#          pg_hint_plan|warning|app: created, not preloaded, pg_stat_statements|info|preloaded, created in no database read,
#          pg_stat_statements.track|warning|none, pg_wait_sampling|info|installed in app
#     and on z a second import (no shared_preload_libraries setting row = the list unreadable; no db row for app2,
#     a collector_error instead; a databases list without 'gone') -> pg_stat_statements keeps preloaded_via {shared}
#     and no 'preload' history row; app2's rows stay present; gone's rows go is_present false
#  D. ext_version_lt: 1.9 < 1.10, 1.4 < 1.4.1, not 1.10 < 1.9, NULL on 'unpackaged'.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=${ADMIN_DSN:-$PGVIGIL_REPO_DSN}
SUF=$RANDOM
REPO_DB=pgvigil_extproof_$SUF; T1=pgvigil_ext1_$SUF; T2=pgvigil_ext2_$SUF; MON=pgvigil_extmon_$SUF; MONPW=p$RANDOM$RANDOM
dsn_for() { echo "$ADMIN_DSN dbname=$1"; }   # a later keyword wins, in libpq and in pgx
CFG=$(mktemp)
cleanup() {
  rm -f "$CFG"
  for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for d in "$REPO_DB" "$T1" "$T2"; do psql "$ADMIN_DSN" -XAtq -c "create database $d" >/dev/null; done
psql "$ADMIN_DSN" -XAtq -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null
export PGVIGIL_REPO_DSN; PGVIGIL_REPO_DSN=$(dsn_for "$REPO_DB")
export TGT_DSN; TGT_DSN="$(dsn_for "$T1") user=$MON password=$MONPW"
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
t1() { psql "$(dsn_for "$T1")" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }
t2() { psql "$(dsn_for "$T2")" -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

echo "--- A. first read"
t1 "create extension amcheck version '1.0'; create extension pg_trgm"
t2 "create extension hstore version '1.4'"
TRGM=$(t1 "select extversion from pg_extension where extname = 'pg_trgm'")
AMDEF=$(t1 "select default_version from pg_available_extensions where name = 'amcheck'")

cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-ext-$SUF
    dsn: env:TGT_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
"$BIN" collect -config "$CFG" -once extensions || fail "collect extensions (run 1)"
iid=$(q "select instance_id from pgvigil.instances where name='proof-ext-$SUF'")
[[ $(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='extensions'") != error ]] || fail "collection failed: $(q "select note from pgvigil.collection_dates where instance_id=$iid and collection='extensions'")"
dbx() { q "select string_agg(name || ' ' || version, ',' order by name) from pgvigil.database_extensions where instance_id=$iid and datname='$1' and is_present"; }
[[ $(dbx "$T1") == "amcheck 1.0,pg_trgm $TRGM,plpgsql 1.0" ]] || fail "tgt1 rows: $(dbx "$T1")"
[[ $(dbx "$T2") == "hstore 1.4,plpgsql 1.0" ]] || fail "tgt2 rows: $(dbx "$T2")"
[[ $(q "select count(distinct dbid) from pgvigil.database_extensions where instance_id=$iid and datname in ('$T1','$T2')") == 2 ]] || fail "two dbids"
echo "per-database rows: $T1 = $(dbx "$T1"); $T2 = $(dbx "$T2")"
[[ $(q "select available and preloaded_via = '{shared}' from pgvigil.instance_extensions where instance_id=$iid and name='pg_stat_statements'") == t ]] \
  || fail "pg_stat_statements: $(q "select available, preloaded_via from pgvigil.instance_extensions where instance_id=$iid and name='pg_stat_statements'")"
[[ $(q "select default_version from pgvigil.instance_extensions where instance_id=$iid and name='amcheck'") == "$AMDEF" ]] || fail "amcheck default_version"
SPL=$(q "select setting from pgvigil.instance_extension_settings where instance_id=$iid and name='shared_preload_libraries' and is_present")
[[ $SPL == *pg_stat_statements* ]] || fail "shared_preload_libraries read: '$SPL'"
echo "preloaded: shared_preload_libraries = $SPL; libraries: $(q "select string_agg(name || ' (' || array_to_string(preloaded_via, ',') || ')', ', ' order by name) from pgvigil.instance_extensions where instance_id=$iid and preloaded_via <> '{}'")"
[[ $(q "select count(*) from pgvigil.instance_extension_settings where instance_id=$iid and name='pg_stat_statements.track' and is_present") == 1 ]] || fail "pg_stat_statements.track not read"
fnd() { q "select string_agg(setting || '|' || severity || '|' || value, E'\n' order by setting, severity, value) from pgvigil.extension_findings where instance_id=$1 $2"; }
mine="and (value like '%$T1%' or value like '%$T2%')"
want=$(printf '%s\n' "amcheck|info|installed in $T1" "amcheck|warning|$T1: 1.0" "hstore|warning|$T2: 1.4")
got=$(fnd "$iid" "$mine")
[[ "$got" == "$want" ]] || fail "findings: got
$got
want
$want"
echo "findings:"; q "select severity, setting, value, suggested from pgvigil.extension_findings where instance_id=$iid $mine order by 2, 1"
[[ $(q "select suggested from pgvigil.extension_findings where instance_id=$iid and setting='amcheck' and severity='warning'") == "ALTER EXTENSION amcheck UPDATE (to $AMDEF)" ]] || fail "amcheck suggestion"
[[ $(q "select count(*) from pgvigil.extension_findings where instance_id=$iid and setting like 'pg_stat_statements%'") == 0 ]] || fail "a pg_stat_statements finding on the sandbox: $(fnd "$iid" "and setting like 'pg_stat_statements%'")"
[[ $(q "select outdated_dbs >= 1 and databases like '%$T1%' from pgvigil.extension_fleet where instance_id=$iid and name='amcheck'") == t ]] || fail "fleet amcheck row"
[[ $(q "select count(*) from pgvigil.extension_history where instance_id=$iid") == 0 ]] || fail "history on the first read"

echo "--- B. changes"
t1 "alter extension amcheck update"
t2 "drop extension hstore; create extension pg_trgm"
sleep 1.1
"$BIN" collect -config "$CFG" -once extensions || fail "collect extensions (run 2)"
[[ $(q "select status from pgvigil.collection_dates where instance_id=$iid and collection='extensions'") == ok ]] || fail "status run 2: $(q "select status, note from pgvigil.collection_dates where instance_id=$iid and collection='extensions'")"
hist=$(q "select string_agg(datname || '|' || name || '|' || change || '|' || coalesce(old_value, '') || '|' || coalesce(new_value, ''), E'\n' order by datname, name)
            from pgvigil.extension_history where instance_id=$iid and datname in ('$T1','$T2')")
want=$(printf '%s\n' "$T1|amcheck|updated|1.0|$AMDEF" "$T2|hstore|removed|1.4|" "$T2|pg_trgm|installed||$TRGM")
[[ "$hist" == "$want" ]] || fail "history: got
$hist
want
$want"
echo "history:"; echo "$hist"
[[ $(q "select is_present from pgvigil.database_extensions where instance_id=$iid and datname='$T2' and name='hstore'") == f ]] || fail "hstore still present"
[[ $(q "select count(*) from pgvigil.extension_findings where instance_id=$iid and severity='warning' $mine") == 0 ]] || fail "warnings after the update: $(fnd "$iid" "$mine")"

echo "--- C. seeded rules"
seed() { q "select pgvigil.ensure_instance('proof-ext-$1-$SUF', 'onprem', '16.4', 160004, false, '{}')"; }
imp() { q "select pgvigil.import_extensions($1, now() + make_interval(secs => $2), '$3'::jsonb)" >/dev/null; }
ix=$(seed x); iy=$(seed y); iz=$(seed z)
imp "$ix" 0 '[{"kind":"available","name":"plpgsql","default_version":"1.0"},
              {"kind":"setting","name":"shared_preload_libraries","setting":""},
              {"kind":"databases","names":["app"]},{"kind":"db","dbid":1,"datname":"app"},
              {"kind":"installed","dbid":1,"datname":"app","name":"plpgsql","version":"1.0"}]'
imp "$iy" 0 '[{"kind":"available","name":"pg_stat_statements","default_version":"1.10"},
              {"kind":"available","name":"pg_hint_plan","default_version":"1.6.0"},
              {"kind":"library","name":"auto_explain","via":"shared","position":1},
              {"kind":"library","name":"pg_hint_plan","via":"shared","position":2},
              {"kind":"setting","name":"shared_preload_libraries","setting":"auto_explain,pg_hint_plan"},
              {"kind":"setting","name":"auto_explain.log_min_duration","setting":"0","unit":"ms"},
              {"kind":"setting","name":"pg_hint_plan.enable_hint","setting":"off"},
              {"kind":"databases","names":["app"]},{"kind":"db","dbid":1,"datname":"app"},
              {"kind":"installed","dbid":1,"datname":"app","name":"pg_hint_plan","version":"1.6.0"}]'
# z's library row is what the collector's parse gives for '$libdir/pg_stat_statements'
ZLIB=$(psql "$ADMIN_DSN" -XAt -c "select regexp_replace(regexp_replace(btrim(e.lib, ' \"'), '^.*[/\\\\]', ''), '\\.(so|dll|dylib)\$', '') from regexp_split_to_table('\$libdir/pg_stat_statements', ',') e(lib)")
[[ $ZLIB == pg_stat_statements ]] || fail "library parse: '$ZLIB'"
Z1='[{"kind":"available","name":"pg_stat_statements","default_version":"1.10"},
     {"kind":"available","name":"pg_hint_plan","default_version":"1.6.0"},
     {"kind":"available","name":"pg_wait_sampling","default_version":"1.1"},
     {"kind":"library","name":"'$ZLIB'","via":"shared","position":1},
     {"kind":"setting","name":"shared_preload_libraries","setting":"$libdir/pg_stat_statements"},
     {"kind":"setting","name":"pg_stat_statements.track","setting":"none"},
     {"kind":"databases","names":["app","app2","gone"]},
     {"kind":"db","dbid":1,"datname":"app"},{"kind":"db","dbid":2,"datname":"app2"},{"kind":"db","dbid":3,"datname":"gone"},
     {"kind":"installed","dbid":1,"datname":"app","name":"pg_hint_plan","version":"1.6.0"},
     {"kind":"installed","dbid":1,"datname":"app","name":"pg_wait_sampling","version":"1.1"},
     {"kind":"installed","dbid":2,"datname":"app2","name":"plpgsql","version":"1.0"},
     {"kind":"installed","dbid":3,"datname":"gone","name":"plpgsql","version":"1.0"}]'
imp "$iz" 0 "$Z1"
want_x="pg_stat_statements|warning|not available"
want_y=$(printf '%s\n' "auto_explain|warning|0 ms" "pg_hint_plan.enable_hint|warning|off" "pg_stat_statements|warning|not in shared_preload_libraries")
want_z=$(printf '%s\n' "pg_hint_plan|warning|app: created, not preloaded" "pg_stat_statements|info|preloaded, created in no database read" \
                       "pg_stat_statements.track|warning|none" "pg_wait_sampling|info|installed in app")
for c in x y z; do
  id=$(eval echo "\$i$c"); want=$(eval echo "\"\$want_$c\""); got=$(fnd "$id" "")
  [[ "$got" == "$want" ]] || fail "findings $c: got
$got
want
$want"
  echo "findings $c:"; echo "$got"
done
# z again: the shared list unreadable, app2 not read (a collector_error), gone dropped from the list
imp "$iz" 60 '[{"kind":"available","name":"pg_stat_statements","default_version":"1.10"},
               {"kind":"available","name":"pg_hint_plan","default_version":"1.6.0"},
               {"kind":"available","name":"pg_wait_sampling","default_version":"1.1"},
               {"kind":"setting","name":"pg_stat_statements.track","setting":"none"},
               {"kind":"databases","names":["app","app2"]},
               {"kind":"db","dbid":1,"datname":"app"},
               {"kind":"installed","dbid":1,"datname":"app","name":"pg_hint_plan","version":"1.6.0"},
               {"kind":"installed","dbid":1,"datname":"app","name":"pg_wait_sampling","version":"1.1"},
               {"kind":"collector_error","source":"extensions:app2","message":"connect: refused"}]'
[[ $(q "select preloaded_via from pgvigil.instance_extensions where instance_id=$iz and name='pg_stat_statements'") == "{shared}" ]] \
  || fail "z preload lost on an unreadable list: $(q "select preloaded_via from pgvigil.instance_extensions where instance_id=$iz and name='pg_stat_statements'")"
[[ $(q "select count(*) from pgvigil.extension_history where instance_id=$iz and change = 'preload'") == 0 ]] || fail "z preload history"
[[ $(q "select is_present from pgvigil.database_extensions where instance_id=$iz and datname='app2'") == t ]] || fail "app2 rows dropped on a failed read"
[[ $(q "select is_present from pgvigil.database_extensions where instance_id=$iz and datname='gone'") == f ]] || fail "gone rows still present"
echo "z second import: preload kept, app2 kept, gone removed"

echo "--- D. ext_version_lt"
[[ $(q "select pgvigil.ext_version_lt('1.9','1.10'), pgvigil.ext_version_lt('1.4','1.4.1'), pgvigil.ext_version_lt('1.10','1.9'), pgvigil.ext_version_lt('unpackaged','1.0') is null") == "t|t|f|t" ]] \
  || fail "ext_version_lt"
echo "PASS proof-extensions"
