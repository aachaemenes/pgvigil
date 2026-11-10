#!/usr/bin/env bash
# Proof of the Database info tab's data (task 37, migration 0046). Three parts:
#   A. two databases with known facts on the sandbox, collected by a pg_monitor-only login (databases, extensions,
#      versions, storage, tables); dbinfo() returns each fact as created.
#   B. one of them dropped and the databases collection run again: it goes absent (is_present false), out of the
#      size series, and the other stays.
#   C. seeded size history (scratch instances in the proof's own repository): the 7- and 30-day growth, the fleet's
#      top growers, the size series.
#   D. the API through `pgvigil serve` when the binary has the routes (after the lead's join); "NOT PROVEN (D)" before.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox in KEYWORD form (host=... user=... dbname=...: the proof appends
#                      dbname= to it); the proof makes its own repository database, a login and two
#                      databases, and drops them at the end; nothing that exists before the run is touched.
#
# Expected (written before the first run):
#  A. dbinfo_a_<suf>: owner the proof's role, encoding UTF8, conn_limit 7, allow_conn true, is_template false, tablespace
#     pg_default with tablespace_bytes > 0, comment 'proof database a', extensions 'pg_trgm <version>' (count 1),
#     [first run: plpgsql is an extension of every database: a lists 'pg_trgm 1.6, plpgsql 1.0' (2), b 'plpgsql 1.0' (1);
#      the expectation missed it, the read is right]
#     can_connect true, size_bytes >= 8 MB more than dbinfo_b_<suf>'s (a 10 MB table), locale_provider libc,
#     collation_mismatch false (PostgreSQL 15 and later; on 13 and 14 the provider is NULL and the mismatch false: no datcollversion there), tables_read >= 1.
#     dbinfo_b_<suf>: encoding SQL_ASCII, lc_collate C, lc_ctype C, conn_limit -1, no extension (count 0), comment NULL.
#     template0 and template1 listed with is_template true; dbinfo_tablespaces lists pg_default and pg_global with
#     size_bytes > 0 and pg_default's default_for naming both proof databases.
#  B. after DROP DATABASE dbinfo_b_<suf> and collect -once databases: b is_present false, a is_present true;
#     database_size_series over the last hour names a and not b.
#  C. inst g: 'grow' 10 GiB now, +1 GiB/day, a point every 6 hours back 30 days; 'flat' 5 GiB flat; 'young' 3 points
#     1 hour apart (+1 GiB each). dbinfo(g): grow grown_7d between 6.5 and 7.0 GiB, grown_30d between 29.5 and 30.0 GiB,
#     growth_7d_per_day about 1 GiB (0.95-1.05); flat grown_7d 0; young grown_7d NULL (under a day).
#     A table 'big' of grow, +100 MiB/day over the same points, and 'still' flat.
#     fleet_database_growers: grow is the first row of inst g (flat and young absent); fleet_table_growers: big present
#     with grown_7d between 650 and 700 MiB, still absent. database_size_series(g, now()-7d, now(), 3600): 28 rows for
#     grow (one per 6 hours inside 7 days, the boundary point out); table_size_series(g, NULL, ...) names big and still.
#  D. GET /api/dbinfo?instance=<a's>: 200 with the five parts and both databases; ?db=0 400 "db must be";
#     GET /api/dbinfo/fleet: 200 with grow in databases.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
: "${PGVIGIL_REPO_DSN:?}"
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM
REPO_DB=pgvigil_dbiproof_$SUF; MON=pgvigil_dbimon_$SUF; MONPW=p$RANDOM$RANDOM; OWN=pgvigil_dbiown_$SUF
DBA=dbinfo_a_$SUF; DBB=dbinfo_b_$SUF
CFG=$(mktemp); LOG=$(mktemp); SRVPID=
cleanup() {
  [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null || true
  rm -f "$CFG" "$LOG"
  for d in "$REPO_DB" "$DBA" "$DBB"; do psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true; done
  psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" -c "drop role if exists $OWN" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
adm() { psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 "$@"; }
adm -c "create database $REPO_DB"
adm -c "create role $MON login password '$MONPW' in role pg_monitor" -c "create role $OWN nologin"
adm -c "create database $DBA owner $OWN connection limit 7"
adm -c "create database $DBB owner $OWN encoding 'SQL_ASCII' lc_collate 'C' lc_ctype 'C' template template0"
adm -c "comment on database $DBA is 'proof database a'"
psql "$ADMIN_DSN dbname=$DBA" -XAtq -v ON_ERROR_STOP=1 -c "create extension pg_trgm" \
  -c "create table proof_fill as select g, repeat('x', 1000) as pad from generate_series(1, 10000) g" -c "analyze proof_fill"
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"   # a later keyword wins, in libpq and in pgx
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
export MON_DSN="$ADMIN_DSN user=$MON password=$MONPW"

echo "--- A. two databases with known facts (pg_monitor login)"
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-dbinfo-$SUF
    dsn: env:MON_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
for c in databases extensions versions storage tables; do "$BIN" collect -config "$CFG" -once "$c" >/dev/null || fail "A: collect $c"; done
iid=$(q "select instance_id from pgvigil.instances where name='proof-dbinfo-$SUF'")
row() { q "select $1 from pgvigil.dbinfo($iid) where datname='$2'"; }
q "select '  ' || datname || '|' || owner || '|' || encoding || '|' || lc_collate || '|' || coalesce(locale_provider, '-') || '|limit ' || conn_limit
     || '|' || tablespace || '|' || pg_size_pretty(size_bytes) || '|ext ' || extension_count || ' ' || coalesce(extensions, '-')
     || '|' || coalesce(comment, '-') || '|tables ' || tables_read from pgvigil.dbinfo($iid) where datname in ('$DBA', '$DBB') order by 1"
[ "$(row "owner || '|' || encoding || '|' || conn_limit || '|' || allow_conn || '|' || is_template || '|' || tablespace || '|' || can_connect || '|' || comment" "$DBA")" \
  = "$OWN|UTF8|7|true|false|pg_default|true|proof database a" ] || fail "A: a's facts"
[ "$(row "tablespace_bytes > 0" "$DBA")" = t ] || fail "A: a's tablespace size"
[ "$(row "extension_count || '|' || (extensions ~ '^pg_trgm [0-9.]+, plpgsql [0-9.]+$')" "$DBA")" = "2|true" ] || fail "A: a's extensions"
# the collation version exists from PostgreSQL 15 (datlocprovider, datcollversion): the versions collection reads it there
# alone, so on 13 and 14 the provider is NULL and collation_mismatch is false (dbinfo() compares two versions it has)
if [[ "$(q "select current_setting('server_version_num')::int >= 150000")" = t ]]; then want="libc|false"; else want="-|false"; fi
[ "$(row "coalesce(locale_provider, '-') || '|' || coalesce(collation_mismatch::text, '-')" "$DBA")" = "$want" ] || fail "A: a's locale provider / collation version (want $want)"
[ "$(row "tables_read >= 1" "$DBA")" = t ] || fail "A: a's tables read"
[ "$(row "encoding || '|' || lc_collate || '|' || lc_ctype || '|' || conn_limit || '|' || extensions || '|' || (comment is null)" "$DBB")" \
  = "SQL_ASCII|C|C|-1|plpgsql 1.0|true" ] || fail "A: b's facts"
[ "$(q "select (select size_bytes from pgvigil.dbinfo($iid) where datname='$DBA') - (select size_bytes from pgvigil.dbinfo($iid) where datname='$DBB') >= 8*1024*1024")" = t ] \
  || fail "A: a is not 8 MB larger than b"
[ "$(q "select string_agg(datname, ',' order by datname) from pgvigil.dbinfo($iid) where is_template")" = "template0,template1" ] || fail "A: templates"
[ "$(q "select string_agg(name, ',' order by name) from pgvigil.dbinfo_tablespaces($iid) where size_bytes > 0")" = "pg_default,pg_global" ] || fail "A: tablespaces"
[ "$(q "select default_for ~ '$DBA' and default_for ~ '$DBB' from pgvigil.dbinfo_tablespaces($iid) where name='pg_default'")" = t ] || fail "A: default_for"
echo "A: OK"

echo "--- B. a dropped database goes absent"
adm -c "drop database $DBB with (force)"
"$BIN" collect -config "$CFG" -once databases >/dev/null || fail "B: collect"
[ "$(row "is_present" "$DBB")" = f ] || fail "B: b still present"
[ "$(row "is_present" "$DBA")" = t ] || fail "B: a gone"
[ "$(q "select string_agg(distinct datname, ',') filter (where datname in ('$DBA', '$DBB')) from pgvigil.database_size_series($iid, now() - interval '1 hour', now(), 3600)")" = "$DBA" ] \
  || fail "B: size series"
echo "B: OK"

echo "--- C. seeded growth"
G=1073741824; M=1048576
g=$(q "select pgvigil.ensure_instance('dbinfo-grow-$SUF', 'onprem', 'proof', 180000, false, '{proof}')")
dbrow() { echo "{\"dbid\":$1,\"datname\":\"$2\",\"is_template\":false,\"allow_conn\":true,\"conn_limit\":-1,\"tablespace\":\"pg_default\",\"size_bytes\":$3}"; }
q "select pgvigil.import_databases($g, now(), '[$(dbrow 1001 grow $((10*G))), $(dbrow 1002 flat $((5*G))), $(dbrow 1003 young $((3*G)))]'::jsonb)" >/dev/null
q "select pgvigil.import_tables($g, now(), '[{\"kind\":\"db\",\"dbid\":1001,\"datname\":\"grow\"},
   {\"kind\":\"table\",\"dbid\":1001,\"relid\":5001,\"datname\":\"grow\",\"schema_name\":\"public\",\"table_name\":\"big\",\"total_bytes\":$((2*G))},
   {\"kind\":\"table\",\"dbid\":1001,\"relid\":5002,\"datname\":\"grow\",\"schema_name\":\"public\",\"table_name\":\"still\",\"total_bytes\":$G}]'::jsonb)" >/dev/null
q "DO \$\$
DECLARE h int; t timestamptz;
BEGIN
  FOR h IN 1..120 LOOP
    t := now() - make_interval(hours => 6 * h);
    PERFORM pgvigil.ensure_month_partition('database_sizes', t);
    PERFORM pgvigil.ensure_month_partition('table_sizes', t);
    INSERT INTO pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes) VALUES
      ($g, t, 1001, 'grow', (10::bigint*$G - h * 0.25 * $G)::bigint), ($g, t, 1002, 'flat', 5::bigint*$G);
    INSERT INTO pgvigil.table_sizes (instance_id, snapshot_at, dbid, relid, total_bytes) VALUES
      ($g, t, 1001, 5001, (2::bigint*$G - h * 25::bigint * $M)::bigint), ($g, t, 1001, 5002, $G::bigint);
  END LOOP;
  INSERT INTO pgvigil.database_sizes (instance_id, snapshot_at, dbid, datname, size_bytes) VALUES
    ($g, now() - interval '1 hour', 1003, 'young', 2::bigint*$G), ($g, now() - interval '2 hours', 1003, 'young', 1::bigint*$G);
END \$\$" >/dev/null
q "select '  ' || datname || ' 7d ' || coalesce(pg_size_pretty(grown_7d_bytes), 'NULL') || ' 30d ' || coalesce(pg_size_pretty(grown_30d_bytes), 'NULL')
     || ' /day ' || coalesce(pg_size_pretty(growth_7d_per_day), 'NULL') from pgvigil.dbinfo($g) order by 1"
[ "$(q "select grown_7d_bytes between 6.5*$G and 7.0*$G and grown_30d_bytes between 29.5*$G and 30.0*$G and growth_7d_per_day between 0.95*$G and 1.05*$G from pgvigil.dbinfo($g) where datname='grow'")" = t ] || fail "C: grow"
[ "$(q "select grown_7d_bytes from pgvigil.dbinfo($g) where datname='flat'")" = 0 ] || fail "C: flat"
[ "$(q "select grown_7d_bytes is null from pgvigil.dbinfo($g) where datname='young'")" = t ] || fail "C: young"
[ "$(q "select string_agg(datname, ',' order by grown_7d_bytes desc) from pgvigil.fleet_database_growers(50) where instance_id=$g")" = grow ] || fail "C: database growers"
[ "$(q "select string_agg(table_name || ':' || (grown_7d_bytes between 650*$M and 700*$M), ',') from pgvigil.fleet_table_growers(50) where instance_id=$g")" = "big:true" ] \
  || fail "C: table growers: $(q "select string_agg(table_name || ':' || grown_7d_bytes, ',') from pgvigil.fleet_table_growers(50) where instance_id=$g")"
[ "$(q "select count(*) from pgvigil.database_size_series($g, now() - interval '7 days', now(), 3600) where datname='grow'")" = 28 ] || fail "C: database series points"
[ "$(q "select string_agg(distinct label, ',') from pgvigil.table_size_series($g, NULL, now() - interval '7 days', now(), 3600)")" = "grow.public.big,grow.public.still" ] \
  || fail "C: table series labels"
echo "C: OK"

echo "--- D. the API"
PORT=$((20000 + RANDOM % 20000))
"$BIN" serve -config "$CFG" -listen "127.0.0.1:$PORT" -no-login >"$LOG" 2>&1 & SRVPID=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break; sleep 0.1; done
kill -0 "$SRVPID" 2>/dev/null || fail "D: serve exited: $(cat "$LOG")"
U="http://127.0.0.1:$PORT/api"
if [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/dbinfo/fleet")" = 404 ]; then
  echo "NOT PROVEN (D): this binary has no /api/dbinfo route yet (the lead wires it at the join)"
else
  body=$(curl -fs "$U/dbinfo?instance=$iid") || fail "D: dbinfo"
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert set(d)=={"databases","tablespaces","db_series","table_series","series_meta"}, d.keys(); n=[r[d["databases"]["columns"].index("datname")] for r in d["databases"]["rows"]]; assert sys.argv[2] in n and sys.argv[3] in n, n' "$body" "$DBA" "$DBB" || fail "D: dbinfo body"
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/dbinfo?instance=$iid&db=0")" = 400 ] || fail "D: db=0 accepted"
  curl -s "$U/dbinfo?instance=$iid&db=0" | grep -q 'db must be' || fail "D: db=0 message"
  curl -fs "$U/dbinfo/fleet" | grep -q '"grow"' || fail "D: fleet"
  echo "D: OK"
fi
echo "proof-dbinfo: PASS"
