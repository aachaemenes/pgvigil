#!/usr/bin/env bash
# proof-schema-sqlbody.sh - task A26-PG: a PostgreSQL 14+ SQL-standard function body (BEGIN ATOMIC ... END, RETURN
# expr) is read with pg_get_function_sqlbody, masked and diffed, and the upgrade's first read records it as the body's
# baseline, never one false 'changed' row per such function. PostgreSQL 13 reads as before.
#
# It runs its OWN containers (docker), trust on a 127.0.0.1 port each (the box's own PostgreSQL is not used): one
# postgres:18 for the repository (a database per version), and one per monitored version (default 13, 14 and 18),
# holding the monitored database; all removed by name at the end whatever the exit. Inputs:
#   PGVIGIL_BIN               this tree's binary (default bin/pgvigil)
#   PGVIGIL_BIN_A26SCHEMA     REQUIRED - the old collector: this tree with rel-a26 5b6bcff0's internal/collect/schema.go
#                             (its migrations are this tree's). Unset = FAIL: the upgrade row is never 'not proven'.
#   PGVIGIL_SQLBODY_VERSIONS  the versions, default '13 14 18'
#
# Expected: an 'ok' line per row below, then 'proof-schema-sqlbody: PASS (<rows>)'; any other end is a FAIL line.
#   V<v>  the probe's facts: to_regprocedure('pg_catalog.pg_get_function_sqlbody(oid)') present on 14 and 18, absent on
#         13 - FAIL when absent on 14 or 18 (the lead's G1 row); pg_dump's binary names pg_get_function_sqlbody on 14 and
#         18 (the code comment calls it pg_dump's own reader: FAIL when it does not).
#   U<v>  the upgrade: the old collector reads first (f_atomic stored as its hashed form over an empty body, no text),
#         then this binary: NO schema_changes row of the monitored database; on 14 / 18 the stored definitions carry
#         'BEGIN ATOMIC' and 'SELECT (a + 1)' (f_atomic), 'RETURN (a * 2)' (f_ret), 'BEGIN ATOMIC' (p_ins), f_atomic's
#         last_changed still NULL; on 13 f_str's 'SELECT a + 1' as before; no 'schema body:' note on the collection line.
#         Red on rel-a26 as PGVIGIL_BIN: no 'BEGIN ATOMIC' text. Red with 0267's import (5b6bcff0 + this branch's
#         schema.go as PGVIGIL_BIN): 'changed' rows at the upgrade.
#   S<v>  a secret (14 / 18): f_sec's deparsed body names a password: its definition ends with the withheld words and
#         'Hunter2abc' is in neither schema_objects nor schema_changes (red on rel-a26: no withheld line, the body was '').
#   C<v>  a change: on 14 / 18 CREATE OR REPLACE f_atomic with a + 2 -> exactly one row, 'changed|function|
#         app.f_atomic(integer)|definition', '(a + 1)' before and '(a + 2)' after; on 13 f_str's string body -> one row.
#   W<v>  the way back (said in docs/schema.md): the old collector after this binary records one 'changed' row per
#         SQL-standard function (4 on 14 / 18: the body goes back to empty), none on 13.
set -euo pipefail
BIN=${PGVIGIL_BIN:-bin/pgvigil}
OLD=${PGVIGIL_BIN_A26SCHEMA:-}
VERSIONS=${PGVIGIL_SQLBODY_VERSIONS:-13 14 18}
SUF=$RANDOM$RANDOM
CTS=()
WORK=$(mktemp -d)
cleanup() {
  for c in "${CTS[@]}"; do docker rm -f -v "$c" >/dev/null 2>&1 || echo "LEFT BEHIND: $c"; done
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL $*"; exit 1; }
[ -n "$OLD" ] || fail "PGVIGIL_BIN_A26SCHEMA is not set: the upgrade rows need the old collector (this tree with rel-a26 5b6bcff0's internal/collect/schema.go)"
[ -x "$OLD" ] || fail "PGVIGIL_BIN_A26SCHEMA=$OLD is not an executable"
command -v docker >/dev/null 2>&1 || fail "no docker: this proof runs its own PostgreSQL containers"
echo "containers: a26pgsb_repo_$SUF $(for v in $VERSIONS; do printf 'a26pgsb_%s_%s ' "$v" "$SUF"; done)"
ROWS=()
WITHHELD="(body text not kept: it names a password or a secret)"
# start_pg <name> <version>: a container of its own; sets PORT
start_pg() {
  docker run -d --name "$1" --memory 1g -e POSTGRES_HOST_AUTH_METHOD=trust -p 127.0.0.1::5432 "postgres:$2" -c max_connections=200 \
    > "$WORK/run-$1.txt" 2>&1 || fail "docker run postgres:$2 ($1): $(tail -2 "$WORK/run-$1.txt")"
  CTS+=("$1")
  PORT=$(docker port "$1" 5432/tcp | head -1 | sed 's/.*://')
  for _ in $(seq 1 120); do psql "host=127.0.0.1 port=$PORT user=postgres dbname=postgres" -XAtc "select 1" >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 1   # the image starts once to initialise and again to serve
  for _ in $(seq 1 120); do psql "host=127.0.0.1 port=$PORT user=postgres dbname=postgres" -XAtc "select 1" >/dev/null 2>&1 && break; sleep 0.5; done
}
start_pg "a26pgsb_repo_$SUF" 18
RADMIN="host=127.0.0.1 port=$PORT user=postgres"
psql "$RADMIN dbname=postgres" -XAtc "select 1" >/dev/null 2>&1 || fail "the repository's container does not answer"

for v in $VERSIONS; do
  CT=a26pgsb_${v}_$SUF
  start_pg "$CT" "$v"
  P=$PORT
  ADMIN="host=127.0.0.1 port=$P user=postgres"
  VNUM=$(psql "$ADMIN dbname=postgres" -XAtc "show server_version_num") || fail "V$v: the container does not answer"
  [ "${VNUM:0:2}" = "$v" ] || fail "V$v: the container is version $VNUM"
  REPO_DB=pgvigil_sqlbody_repo${v}_$SUF; MDB=pgvigil_sqlbody_mon_$SUF; MON=pgvigil_sqlbody_mon_$SUF
  psql "$RADMIN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $REPO_DB" > "$WORK/create-$v.txt" 2>&1 \
    || fail "V$v: create the repository database: $(tail -3 "$WORK/create-$v.txt")"
  psql "$ADMIN dbname=postgres" -XAtq -v ON_ERROR_STOP=1 -c "create database $MDB" -c "create role $MON login in role pg_monitor" \
    > "$WORK/create-$v.txt" 2>&1 || fail "V$v: create: $(tail -3 "$WORK/create-$v.txt")"

  # V: the probe's facts and pg_dump's binary
  HAS=$(psql "$ADMIN dbname=$MDB" -XAtc "select to_regprocedure('pg_catalog.pg_get_function_sqlbody(oid)') is not null")
  DUMPS=$(docker exec "$CT" sh -c "grep -a -c pg_get_function_sqlbody /usr/lib/postgresql/$v/bin/pg_dump" 2>&1 || true)
  [[ $DUMPS =~ ^[0-9]+$ ]] || fail "V$v: pg_dump's binary not read: $DUMPS"
  if [ "$v" -ge 14 ]; then
    [ "$HAS" = t ] || fail "V$v: pg_get_function_sqlbody is absent on PostgreSQL $v ($VNUM): the SQL-standard bodies cannot be read"
    [ "$DUMPS" -ge 1 ] || fail "V$v: pg_dump's binary on $v does not name pg_get_function_sqlbody: the code comment calling it pg_dump's own reader is wrong"
  else
    [ "$HAS" = f ] || fail "V$v: pg_get_function_sqlbody is present on PostgreSQL $v ($VNUM)"
  fi
  echo "ok   V$v probe: server_version_num $VNUM, pg_get_function_sqlbody $( [ "$HAS" = t ] && echo present || echo absent ), named by pg_dump's binary $DUMPS time(s)"
  ROWS+=("V$v")

  # the monitored database's objects
  if [ "$v" -ge 14 ]; then
    cat > "$WORK/objs-$v.sql" <<'SQL'
CREATE SCHEMA app;
CREATE TABLE app.t (i int, s text);
CREATE FUNCTION app.f_atomic(a int) RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT a + 1; END;
CREATE FUNCTION app.f_ret(a int) RETURNS int LANGUAGE sql RETURN a * 2;
CREATE PROCEDURE app.p_ins(x int) LANGUAGE sql BEGIN ATOMIC INSERT INTO app.t VALUES (x, 'a'); END;
CREATE FUNCTION app.f_sec() RETURNS text LANGUAGE sql BEGIN ATOMIC SELECT 'host=h password=Hunter2abc dbname=x'; END;
CREATE FUNCTION app.f_str(a int) RETURNS int LANGUAGE sql AS 'SELECT a + 1';
SQL
  else
    cat > "$WORK/objs-$v.sql" <<'SQL'
CREATE SCHEMA app;
CREATE TABLE app.t (i int, s text);
CREATE FUNCTION app.f_str(a int) RETURNS int LANGUAGE sql AS 'SELECT a + 1';
CREATE FUNCTION app.f_pl(a int) RETURNS int LANGUAGE plpgsql AS 'begin return a + 1; end';
SQL
  fi
  psql "$ADMIN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -f "$WORK/objs-$v.sql" > "$WORK/objs-$v.txt" 2>&1 || fail "V$v: the objects: $(tail -3 "$WORK/objs-$v.txt")"

  CFG=$WORK/cfg-$v.yaml
  printf 'repository:\n  dsn: env:PGVIGIL_REPO_DSN\ninstances:\n  - name: sqlbody-%s-%s\n    dsn: env:SBX_DSN\n' "$v" "$SUF" > "$CFG"
  export PGVIGIL_REPO_DSN="$RADMIN dbname=$REPO_DB" SBX_DSN="host=127.0.0.1 port=$P user=$MON dbname=$MDB"
  "$BIN" migrate -config "$CFG" > "$WORK/migrate-$v.txt" 2>&1 || fail "V$v: migrate: $(tail -3 "$WORK/migrate-$v.txt")"
  q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
  collect() { "$1" collect -config "$CFG" -once schema > "$WORK/collect-$v.txt" 2>&1 || fail "$2: collect -once schema by $1: $(tail -3 "$WORK/collect-$v.txt")"; }
  def() { q "select definition from pgvigil.schema_objects where instance_id = $i and datname = '$MDB' and identity = '$1'"; }
  nchanges() { q "select count(*) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'"; }
  status() { q "select status || ' ' || coalesce(note, '') from pgvigil.collection_dates where instance_id = $i and collection = 'schema'"; }

  # U: the old collector, then this binary
  collect "$OLD" "U$v"
  i=$(q "select instance_id from pgvigil.instances where name = 'sqlbody-$v-$SUF'")
  [ -n "$i" ] || fail "U$v: no instance row after the old collector's read"
  if [ "$v" -ge 14 ]; then
    D0=$(def 'app.f_atomic(integer)')
    [[ $D0 == *"body sha256:e3b0c44298fc1c14"* && $D0 != *"BEGIN ATOMIC"* ]] || fail "U$v: the old collector did not store f_atomic's hashed form over an empty body: $D0"
  fi
  collect "$BIN" "U$v"
  N=$(nchanges)
  [ "$N" = 0 ] || fail "U$v: the upgrade's first read recorded $N change rows: $(q "select string_agg(change || ' ' || identity || ' ' || coalesce(attribute, ''), '; ' order by identity) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'")"
  if [ "$v" -ge 14 ]; then
    D1=$(def 'app.f_atomic(integer)'); R1=$(def 'app.f_ret(integer)'); P1=$(def 'app.p_ins(integer)')
    [[ $D1 == *"BEGIN ATOMIC"* && $D1 == *"SELECT (a + 1)"* ]] || fail "U$v: f_atomic's stored definition carries no BEGIN ATOMIC text after the upgrade: $D1"
    [[ $R1 == *"RETURN (a * 2)"* ]] || fail "U$v: f_ret's stored definition carries no RETURN text: $R1"
    [[ $P1 == *"BEGIN ATOMIC"* ]] || fail "U$v: p_ins's stored definition carries no BEGIN ATOMIC text: $P1"
    [ "$(q "select coalesce(last_changed::text, 'null') from pgvigil.schema_objects where instance_id = $i and datname = '$MDB' and identity = 'app.f_atomic(integer)'")" = null ] \
      || fail "U$v: f_atomic's last_changed moved at its baseline"
  else
    [[ $(def 'app.f_str(integer)') == *"SELECT a + 1"* ]] || fail "U$v: f_str's string body is not read as before: $(def 'app.f_str(integer)')"
  fi
  ST=$(status)
  [[ $ST != *"schema body:"* ]] || fail "U$v: the collection line says the function is absent: $ST"
  echo "ok   U$v upgrade: the old collector, then this binary: no change row; $( [ "$v" -ge 14 ] && echo "BEGIN ATOMIC / RETURN text stored, last_changed kept" || echo "bodies as before" ); collection line '${ST:0:60}'"
  ROWS+=("U$v")

  # S: a secret in a deparsed body
  if [ "$v" -ge 14 ]; then
    SD=$(def 'app.f_sec()')
    [[ $SD == *"$WITHHELD" && $SD != *Hunter2abc* ]] || fail "S$v: f_sec's definition is not its hash and the withheld words: $SD"
    [ "$(q "select (select count(*) from pgvigil.schema_objects where definition ~ 'Hunter2abc') + (select count(*) from pgvigil.schema_changes where coalesce(before, '') || coalesce(after, '') ~ 'Hunter2abc')")" = 0 ] \
      || fail "S$v: Hunter2abc reached the repository's schema tables"
    echo "ok   S$v secret: f_sec withheld, no Hunter2abc in schema_objects or schema_changes"
    ROWS+=("S$v")
  fi

  # C: a body change is one 'changed' row
  if [ "$v" -ge 14 ]; then
    psql "$ADMIN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "CREATE OR REPLACE FUNCTION app.f_atomic(a int) RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT a + 2; END" >/dev/null || fail "C$v: the replace"
    WHO='app.f_atomic(integer)'; WAS='(a + 1)'; NOW='(a + 2)'
  else
    psql "$ADMIN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "CREATE OR REPLACE FUNCTION app.f_str(a int) RETURNS int LANGUAGE sql AS 'SELECT a + 2'" >/dev/null || fail "C$v: the replace"
    WHO='app.f_str(integer)'; WAS='a + 1'; NOW='a + 2'
  fi
  collect "$BIN" "C$v"
  CH=$(q "select change || '|' || kind || '|' || identity || '|' || coalesce(attribute, '') || '|' || (position('$WAS' in coalesce(before, '')) > 0)::text || '|' || (position('$NOW' in coalesce(after, '')) > 0)::text
            from pgvigil.schema_changes where instance_id = $i and datname = '$MDB' order by identity, attribute")
  [ "$CH" = "changed|function|$WHO|definition|true|true" ] || fail "C$v: the body change recorded '$CH', want one 'changed|function|$WHO|definition' with '$WAS' before and '$NOW' after"
  echo "ok   C$v change: one 'changed' definition row for $WHO, '$WAS' before, '$NOW' after"
  ROWS+=("C$v")

  # W: the way back
  NB=$(nchanges)
  collect "$OLD" "W$v"
  NW=$(( $(nchanges) - NB ))
  WANT=0; [ "$v" -ge 14 ] && WANT=4
  [ "$NW" = "$WANT" ] || fail "W$v: the old collector after this binary recorded $NW change rows, want $WANT: $(q "select string_agg(change || ' ' || identity, '; ' order by identity) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'")"
  echo "ok   W$v way back: the old collector after this binary records $NW 'changed' row(s), one per SQL-standard function"
  ROWS+=("W$v")
done
echo "proof-schema-sqlbody: PASS (${ROWS[*]})"
