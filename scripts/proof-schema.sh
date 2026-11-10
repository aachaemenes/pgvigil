#!/usr/bin/env bash
# Proof of the schema snapshots (migration 0058, internal/collect/schema.go, task 59) on the sandbox: two monitored
# databases of its own, a pg_monitor login that reads them, and reads around DDL.
#
#   PGVIGIL_REPO_DSN   a superuser connection to the sandbox; the proof makes its own repository database, two monitored
#                      databases and a pg_monitor login, all with a random suffix, and drops them at the end. The
#                      schema collection reads every connectable database of the server: every check below is limited
#                      to the proof's own databases.
#
# Expected (written before the first run):
#  A. the baseline: MDB holds table t(a int, b text), index t_b on t(b), view v (select now() AS at: no
#     column of t under it, so the ALTER COLUMN TYPEs below run); collect -once schema:
#     MDB's schema_databases row has objects 6 (schema public, table t, columns t.a and t.b, index t_b, view v),
#     ddl_log 'not installed'; no schema_changes row for MDB (the first read is the baseline).
#  B. CREATE TABLE n (x int PRIMARY KEY), ALTER TABLE t ALTER COLUMN a TYPE bigint, DROP INDEX t_b, GRANT SELECT ON t
#     TO the login; collect: MDB's changes, as change|kind|identity|attribute|before|after (empty = NULL):
#       added|table|public.n|||table                              (its column, key constraint and index fold into it)
#       changed|column|public.t.a|definition|integer|bigint
#       changed|table|public.t|acl||{postgres=arwdDxtm/postgres,<login>=r/postgres}
#       dropped|index|public.t_b||CREATE INDEX t_b ON public.t USING btree (b)|
#     no statement on any of them (the event trigger is not installed); schema_findings for MDB: a warning
#     'schema: an object dropped' naming index public.t_b, and an info 'schema: a definition changed' with
#     '1 added, 2 changed'; public.t_b is kept in schema_objects with is_present false.
#  C. the event trigger installed in MDB as the sandbox superuser (the block 'pgvigil roles' prints, commented out,
#     from its BEGIN line to its COMMIT line; C fails when roles does not print it), then, one statement per call:
#     ALTER TABLE n ADD COLUMN y text; CREATE INDEX n_y ON n (y); REVOKE SELECT ON t FROM <login>;
#     CREATE FUNCTION f(i int) RETURNS int LANGUAGE sql AS 'select i'; collect: ddl_log 'installed', its table
#     public.pgvigil_ddl_log; this read's changes with their statements:
#       added|column|public.n.y      ALTER TABLE n ADD COLUMN y text
#       added|index|public.n_y       CREATE INDEX n_y ON n (y)
#       changed|table|public.t|acl   REVOKE SELECT ON t FROM <login>   (after: the owner's entry alone, not NULL)
#       added|function|public.f(integer)   CREATE FUNCTION f(i int) ...
#     and the trigger's own objects added without a statement (table public.pgvigil_ddl_log, the function
#     public.pgvigil_ddl_capture(): created before the trigger existed; the table's identity sequence folds into the
#     table [review fold: an owned sequence's parent is its table]); B's four changes still have no statement.
#  D. DROP INDEX n_y and ALTER TABLE t ALTER COLUMN b TYPE varchar(20) in MDB; CREATE TABLE z (i int) in MDB2 (no
#     trigger); collect: MDB dropped|index|public.n_y with statement 'DROP INDEX n_y', changed|column|public.t.b
#     text -> character varying(20) with its ALTER TABLE statement; MDB2 added|table|public.z with no statement and
#     ddl_log 'not installed' (the tab says so).
#  E. a late import_schema (its snapshot an hour before the last read, an empty object list for MDB) changes nothing:
#     MDB's change count and present-object count are unchanged; DROP DATABASE MDB2, collect: MDB2's row is_present
#     false and no 'dropped' change for its objects (a database gone is not its objects dropped); schema_findings
#     rows for MDB: one warning, one info.
#  F. [review fold, expected before the run] the cursor never stalls, and temporary objects are not logged: 6,000 rows
#     inserted into MDB's pgvigil_ddl_log in one statement as the superuser (object_identity 'public.burst', inside one
#     second: more than one page of 5,000 inside the read's hour of overlap), then CREATE TABLE w (i int), and in one
#     session CREATE TEMP TABLE tt (i int) and DROP TABLE tt; collect: MDB's schema_ddl_log holds 6,000 'public.burst'
#     rows, the CREATE TABLE w row, and no pg_temp row; the change added|table|public.w carries
#     'CREATE TABLE w (i int)'; a second collect adds no row (each kept once) and MDB's cursor is at the newest row.
#  F2. [join fold] the run cap: 3,000 more rows ('public.burst2'), collects under PGVIGIL_SCHEMA_DDL_MAX=2500: the
#     first does not hold all 3,000 (MDB's note 'over 2500 rows in one read'); within 5 collects all 3,000 are held,
#     each once, and the next read starts at or before the newest row (a capped run's cursor is its last row plus the
#     hour of overlap, so the cursor itself may stand past the newest row).
#  G. [join fold] one import per database: MDB3 (200 tables) and MDB4, MDB5 (40 tables each) read once, one table
#     added to each, then a collect under PGVIGIL_SCHEMA_MAX_PAYLOAD=49152 (each mid database under it, the two
#     together over it, MDB3 over it): MDB4 and MDB5 each have added|table|public.extra at that read; MDB3 has no
#     change, its row still present and older than MDB4's; a collect without the cap then finds MDB3's table. With
#     PGVIGIL_BIN_OLD (a build without RunOnce's batch path) the capped collect fails: one payload for the instance.
#  H. [join fold] the trigger's guards: in MDB6, which has a FOR ALL TABLES publication, the printed block fails and
#     leaves no pgvigil_ddl_log; in MDB, CREATE SERVER and CREATE USER MAPPING with a password option, a CREATE
#     SUBSCRIPTION (connect = false) with password= in its connection, and a two-statement batch whose text names a
#     password leave no 'sekret' in MDB's pgvigil_ddl_log or the repository's schema_ddl_log; the CREATE SERVER row and
#     the batch's CREATE TABLE row carry '(statement not kept: it may carry a password)'; with the log table held
#     ACCESS EXCLUSIVE by another session, CREATE TABLE lk returns in under 3 s and lk exists.
#  The ACLs above carry PostgreSQL 17's MAINTAIN privilege (m): on 16 and older the expected text lacks it.
set -euo pipefail
: "${PGVIGIL_REPO_DSN:?}"
BIN=${PGVIGIL_BIN:-bin/pgvigil}
ADMIN_DSN=$PGVIGIL_REPO_DSN
SUF=$RANDOM$RANDOM
REPO_DB=pgvigil_schemaproof_$SUF; MDB=pgvigil_schemamon_$SUF; MDB2=pgvigil_schemamon2_$SUF
MDB3=pgvigil_schemamon3_$SUF; MDB4=pgvigil_schemamon4_$SUF; MDB5=pgvigil_schemamon5_$SUF; MDB6=pgvigil_schemamon6_$SUF
MON=pgvigil_schemamonitor_$SUF; MONPW=p$RANDOM$RANDOM
CFG=$(mktemp); DDL=$(mktemp); ROLES=$(mktemp)
MADE_DBS=(); MADE_ROLE=
# the cleanup drops only what this run created (a name taken by another run fails its create and is never dropped)
cleanup() {
  rm -f "$CFG" "$DDL" "$ROLES"
  # H's subscription, if a failure left it: DROP DATABASE refuses a database with one
  psql "$ADMIN_DSN dbname=$MDB" -XAtq -c "alter subscription pgv_sub_$SUF disable" -c "alter subscription pgv_sub_$SUF set (slot_name = none)" \
    -c "drop subscription pgv_sub_$SUF" >/dev/null 2>&1 || true
  for d in "${MADE_DBS[@]}"; do
    psql "$ADMIN_DSN" -XAtq -c "drop database if exists $d with (force)" >/dev/null 2>&1 || true
  done
  [[ -n $MADE_ROLE ]] && psql "$ADMIN_DSN" -XAtq -c "drop role if exists $MON" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for d in "$REPO_DB" "$MDB" "$MDB2" "$MDB3" "$MDB4" "$MDB5" "$MDB6"; do
  psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create database $d" >/dev/null || fail "create database $d"
  MADE_DBS+=("$d")
done
psql "$ADMIN_DSN" -XAtq -v ON_ERROR_STOP=1 -c "create role $MON login password '$MONPW' in role pg_monitor" >/dev/null || fail "create role $MON"
MADE_ROLE=1
export PGVIGIL_REPO_DSN="$ADMIN_DSN dbname=$REPO_DB"
export SBX_DSN="$ADMIN_DSN dbname=$MDB user=$MON password=$MONPW"
SU=$(psql "$ADMIN_DSN" -XAt -c "select current_user")
m1() { psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }
q() { psql "$PGVIGIL_REPO_DSN" -XAt -v ON_ERROR_STOP=1 -c "$1"; }
cat > "$CFG" <<EOF
repository:
  dsn: env:PGVIGIL_REPO_DSN
instances:
  - name: proof-schema-$SUF
    dsn: env:SBX_DSN
EOF
"$BIN" migrate -config "$CFG" >/dev/null
collect() { "$BIN" collect -config "$CFG" -once schema >/dev/null 2>&1 || fail "collect -once schema failed"; }
dbid() { q "select dbid from pgvigil.schema_databases where instance_id = $i and datname = '$1'"; }
# the changes of one database found by the newest read of it, as change|kind|identity|attribute|before|after
newest() {
  q "select c.change || '|' || c.kind || '|' || c.identity || '|' || coalesce(c.attribute, '') || '|' || coalesce(c.before, '') || '|' || coalesce(c.after, '')
       from pgvigil.schema_changes c
      where c.instance_id = $i and c.datname = '$1'
        and c.snapshot_at = (select max(snapshot_at) from pgvigil.schema_changes where instance_id = $i and datname = '$1')
      order by c.change, c.kind, c.identity, c.attribute"
}
# the same through schema_changes_window, with the statement: change|kind|identity|attribute|statement
newest_st() {
  q "select w.change || '|' || w.kind || '|' || w.identity || '|' || coalesce(w.attribute, '') || '|' || coalesce(w.statement, '')
       from pgvigil.schema_changes_window($i, now() - interval '1 day', now(), $(dbid "$1")) w
      where w.snapshot_at = (select max(snapshot_at) from pgvigil.schema_changes where instance_id = $i and datname = '$1')
      order by w.change, w.kind, w.identity, w.attribute"
}

echo "--- A. the baseline read"
m1 "create table t (a int, b text); create index t_b on t (b); create view v as select now() as at"
collect
i=$(q "select instance_id from pgvigil.instances where name = 'proof-schema-$SUF'")
A=$(q "select objects || '|' || ddl_log from pgvigil.schema_databases where instance_id = $i and datname = '$MDB'")
echo "MDB: $A"; [[ $A == "6|not installed" ]] || fail "A: objects|ddl_log '$A'"
[[ $(q "select count(*) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'") == 0 ]] || fail "A: a change on the baseline"

echo "--- B. CREATE TABLE, ALTER COLUMN TYPE, DROP INDEX, GRANT"
m1 "create table n (x int primary key)"
m1 "alter table t alter column a type bigint"
m1 "drop index t_b"
m1 "grant select on t to $MON"
collect
B=$(newest "$MDB"); echo "$B"
WANT="added|table|public.n|||table
changed|column|public.t.a|definition|integer|bigint
changed|table|public.t|acl||{$SU=arwdDxtm/$SU,$MON=r/$SU}
dropped|index|public.t_b||CREATE INDEX t_b ON public.t USING btree (b)|"
[[ $B == "$WANT" ]] || fail "B: the changes"
[[ $(newest_st "$MDB" | grep -c '|$') == 4 ]] || fail "B: a statement without the event trigger"
FW=$(q "select detail from pgvigil.schema_findings where instance_id = $i and value = '$MDB' and severity = 'warning' and setting = 'schema: an object dropped'")
FI=$(q "select detail from pgvigil.schema_findings where instance_id = $i and value = '$MDB' and severity = 'info' and setting = 'schema: a definition changed'")
echo "warning: $FW"; echo "info: $FI"
[[ $FW == *"index public.t_b"* ]] || fail "B: the drop finding"
[[ $FI == *"1 added, 2 changed"* ]] || fail "B: the change finding"
[[ $(q "select is_present from pgvigil.schema_objects where instance_id = $i and datname = '$MDB' and kind = 'index' and identity = 'public.t_b'") == f ]] || fail "B: the dropped index's row"

echo "--- C. the event trigger, then four statements"
"$BIN" roles > "$ROLES" 2>/dev/null || fail "C: pgvigil roles failed"
grep -q pgvigil_ddl_capture "$ROLES" || fail "C: pgvigil roles does not print the event trigger block"
grep -q '^-- CREATE EVENT TRIGGER pgvigil_ddl_drop' "$ROLES" || fail "C: pgvigil roles does not print the drop trigger line"
awk '/^-- BEGIN; +-- pgvigil_ddl_log/,/^-- COMMIT; +-- pgvigil_ddl_log/' "$ROLES" | sed 's/^-- //' \
  | sed "s/pgvigil_monitor/$MON/g" > "$DDL"
grep -q "^CREATE EVENT TRIGGER pgvigil_ddl_drop" "$DDL" && grep -q "^COMMIT;" "$DDL" && grep -q '^DO \$guard\$' "$DDL" \
  || fail "C: the block between BEGIN and COMMIT was not found"
echo "(the block printed by pgvigil roles: $(wc -l < "$DDL") lines)"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -f "$DDL" >/dev/null
m1 "ALTER TABLE n ADD COLUMN y text"
m1 "CREATE INDEX n_y ON n (y)"
m1 "REVOKE SELECT ON t FROM $MON"
m1 "CREATE FUNCTION f(i int) RETURNS int LANGUAGE sql AS 'select i'"
collect
C0=$(q "select ddl_log || '|' || ddl_log_table from pgvigil.schema_databases where instance_id = $i and datname = '$MDB'")
echo "MDB: $C0"; [[ $C0 == "installed|public.pgvigil_ddl_log" ]] || fail "C: the trigger's state '$C0'"
C=$(newest_st "$MDB"); echo "$C"
WANT="added|column|public.n.y||ALTER TABLE n ADD COLUMN y text
added|function|public.f(integer)||CREATE FUNCTION f(i int) RETURNS int LANGUAGE sql AS 'select i'
added|function|public.pgvigil_ddl_capture()||
added|index|public.n_y||CREATE INDEX n_y ON n (y)
added|table|public.pgvigil_ddl_log||
changed|table|public.t|acl|REVOKE SELECT ON t FROM $MON"
[[ $C == "$WANT" ]] || fail "C: the changes and their statements"
CA=$(q "select coalesce(after, 'NULL') from pgvigil.schema_changes where instance_id = $i and datname = '$MDB' and identity = 'public.t' and attribute = 'acl' order by snapshot_at desc limit 1")
echo "public.t acl after the REVOKE: $CA"; [[ $CA == "{$SU=arwdDxtm/$SU}" ]] || fail "C: the ACL after the REVOKE"
CB=$(q "select count(*) from pgvigil.schema_changes_window($i, now() - interval '1 day', now(), $(dbid "$MDB")) w
         where w.statement is not null and w.snapshot_at < (select max(snapshot_at) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB')")
[[ $CB == 0 ]] || fail "C: B's changes took a statement logged after their read ($CB)"

echo "--- D. a drop and an ALTER COLUMN under the trigger; a database without it"
m1 "DROP INDEX n_y"
m1 "ALTER TABLE t ALTER COLUMN b TYPE varchar(20)"
psql "$ADMIN_DSN dbname=$MDB2" -XAtq -v ON_ERROR_STOP=1 -c "create table z (i int)" >/dev/null
collect   # MDB2's first read was A's (it existed from the start): z is a change
D=$(newest_st "$MDB"); echo "$D"
WANT="changed|column|public.t.b|definition|ALTER TABLE t ALTER COLUMN b TYPE varchar(20)
dropped|index|public.n_y||DROP INDEX n_y"
[[ $D == "$WANT" ]] || fail "D: MDB's changes"
DB=$(q "select before || ' -> ' || after from pgvigil.schema_changes where instance_id = $i and datname = '$MDB' and identity = 'public.t.b'")
echo "public.t.b: $DB"; [[ $DB == "text -> character varying(20)" ]] || fail "D: t.b's before and after"
D2=$(q "select w.change || '|' || w.kind || '|' || w.identity || '|' || coalesce(w.statement, '(none)') || '|' || w.ddl_log
          from pgvigil.schema_changes_window($i, now() - interval '1 day', now(), $(dbid "$MDB2")) w")
echo "MDB2: $D2"; [[ $D2 == "added|table|public.z|(none)|not installed" ]] || fail "D: MDB2's change"

echo "--- E. a late read; a database dropped; the findings"
n1=$(q "select count(*) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'")
p1=$(q "select count(*) from pgvigil.schema_objects where instance_id = $i and datname = '$MDB' and is_present")
q "select pgvigil.import_schema($i, (select snapshot_at from pgvigil.schema_databases where instance_id = $i and datname = '$MDB') - interval '1 hour',
     json_build_array(json_build_object('kind', 'db', 'dbid', $(dbid "$MDB"), 'datname', '$MDB', 'objects', 0))::jsonb)" >/dev/null
n2=$(q "select count(*) from pgvigil.schema_changes where instance_id = $i and datname = '$MDB'")
p2=$(q "select count(*) from pgvigil.schema_objects where instance_id = $i and datname = '$MDB' and is_present")
echo "changes $n1 -> $n2, present objects $p1 -> $p2 after a late read"
[[ $n1 == "$n2" && $p1 == "$p2" ]] || fail "E: a late read changed the snapshot"
psql "$ADMIN_DSN" -XAtq -c "drop database $MDB2 with (force)" >/dev/null
collect
E=$(q "select is_present || '|' || (select count(*) from pgvigil.schema_changes c where c.instance_id = $i and c.datname = '$MDB2' and c.change = 'dropped')
         from pgvigil.schema_databases where instance_id = $i and datname = '$MDB2'")
echo "MDB2 present|dropped changes: $E"; [[ $E == "false|0" ]] || fail "E: the dropped database '$E'"
q "select severity || ' | ' || setting || ' | ' || detail from pgvigil.schema_findings where instance_id = $i and value = '$MDB' order by severity desc"
[[ $(q "select string_agg(severity, ',' order by severity) from pgvigil.schema_findings where instance_id = $i and value = '$MDB'") == "info,warning" ]] || fail "E: the findings of MDB"

echo "--- F. a burst over one page, a temp table"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "insert into public.pgvigil_ddl_log (event, command_tag, object_type, schema_name, object_identity, statement)
  select 'ddl_command_end', 'COMMENT', 'table', 'public', 'public.burst', 'COMMENT ON TABLE burst IS ''' || g || '''' from generate_series(1, 6000) g" >/dev/null
m1 "CREATE TABLE w (i int)"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "CREATE TEMP TABLE tt (i int)" -c "DROP TABLE tt" >/dev/null
collect
mdbid=$(dbid "$MDB")
F1=$(q "select count(*) filter (where object_identity = 'public.burst') || '|' || count(*) filter (where statement = 'CREATE TABLE w (i int)')
          || '|' || count(*) filter (where schema_name = 'pg_temp' or object_identity like 'pg_temp.%')
          from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid")
F2=$(q "select coalesce(w.statement, '(none)') from pgvigil.schema_changes_window($i, now() - interval '1 day', now(), $mdbid) w
         where w.identity = 'public.w' and w.change = 'added'")
echo "burst|w|temp rows: $F1; public.w: $F2"
[[ $F1 == "6000|1|0" ]] || fail "F: the log rows '$F1'"
[[ $F2 == "CREATE TABLE w (i int)" ]] || fail "F: the statement of public.w '$F2'"
n1=$(q "select count(*) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid")
collect
n2=$(q "select count(*) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid")
F3=$(q "select c.read_to = (select max(snapshot_at) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid)
          from pgvigil.log_cursor c where c.instance_id = $i and c.source = 'schema_ddl:$MDB'")
echo "log rows $n1 -> $n2 after a second read; the cursor at the newest row: $F3"
[[ $n1 == "$n2" && $F3 == t ]] || fail "F: the second read"

echo "--- F2. the run cap: 3,000 more rows under PGVIGIL_SCHEMA_DDL_MAX=2500"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "insert into public.pgvigil_ddl_log (event, command_tag, object_type, schema_name, object_identity, statement)
  select 'ddl_command_end', 'COMMENT', 'table', 'public', 'public.burst2', 'COMMENT ON TABLE burst2 IS ''' || g || '''' from generate_series(1, 3000) g" >/dev/null
b2() { q "select count(*) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid and object_identity = 'public.burst2'"; }
export PGVIGIL_SCHEMA_DDL_MAX=2500
collect; runs=1; got=$(b2)
F2N=$(q "select coalesce(ddl_log_note, '') from pgvigil.schema_databases where instance_id = $i and dbid = $mdbid")
echo "run 1: $got of 3,000; note: $F2N"
[[ $got -lt 3000 ]] || fail "F2: the first capped read held all 3,000"
[[ $F2N == "over 2500 rows in one read"* ]] || fail "F2: the cap's note '$F2N'"
while [[ $got -lt 3000 && $runs -lt 5 ]]; do collect; runs=$((runs + 1)); got=$(b2); echo "run $runs: $got of 3,000"; done
unset PGVIGIL_SCHEMA_DDL_MAX
F2C=$(q "select c.read_to - interval '1 hour' <= (select max(snapshot_at) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid)
           from pgvigil.log_cursor c where c.instance_id = $i and c.source = 'schema_ddl:$MDB'")
F2D=$(q "select count(*) - count(distinct log_id) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid")
echo "held $got after $runs runs; the next read covers the newest row: $F2C; rows kept twice: $F2D"
[[ $got == 3000 && $F2C == t && $F2D == 0 ]] || fail "F2: the capped reads"

echo "--- G. one import per database (PGVIGIL_SCHEMA_MAX_PAYLOAD=49152)"
mk() { echo "select format('create table t%s (i int)', g) from generate_series(1, $2) g \gexec" | psql "$ADMIN_DSN dbname=$1" -XAtq -v ON_ERROR_STOP=1 >/dev/null; }
mk "$MDB3" 200; mk "$MDB4" 40; mk "$MDB5" 40
collect   # the three baselines
for d in "$MDB3" "$MDB4" "$MDB5"; do psql "$ADMIN_DSN dbname=$d" -XAtq -v ON_ERROR_STOP=1 -c "create table extra (i int)" >/dev/null; done
if [[ -n ${PGVIGIL_BIN_OLD:-} ]]; then
  if PGVIGIL_SCHEMA_MAX_PAYLOAD=49152 "$PGVIGIL_BIN_OLD" collect -config "$CFG" -once schema >/dev/null 2>&1; then
    fail "G: the one-payload build passed the cap"
  fi
  echo "the one-payload build (PGVIGIL_BIN_OLD) fails under the cap, as expected"
fi
export PGVIGIL_SCHEMA_MAX_PAYLOAD=49152
collect
unset PGVIGIL_SCHEMA_MAX_PAYLOAD
gch() { q "select count(*) from pgvigil.schema_changes where instance_id = $i and datname = '$1' and identity = 'public.extra' and change = 'added'"; }
G1="$(gch "$MDB4")|$(gch "$MDB5")|$(gch "$MDB3")"
G2=$(q "select d3.is_present || '|' || (d3.snapshot_at < d4.snapshot_at) from pgvigil.schema_databases d3, pgvigil.schema_databases d4
         where d3.instance_id = $i and d3.datname = '$MDB3' and d4.instance_id = $i and d4.datname = '$MDB4'")
echo "public.extra added in MDB4|MDB5|MDB3: $G1; MDB3 present|older than MDB4: $G2"
[[ $G1 == "1|1|0" && $G2 == "true|true" ]] || fail "G: the capped read"
collect
G3=$(gch "$MDB3"); echo "MDB3 after a read without the cap: $G3"
[[ $G3 == 1 ]] || fail "G: MDB3's change after the cap"

echo "--- H. the publication guard, no password in the log, the lock wait"
psql "$ADMIN_DSN dbname=$MDB6" -XAtq -v ON_ERROR_STOP=1 -c "create publication pgv_allp for all tables" >/dev/null 2>&1
if psql "$ADMIN_DSN dbname=$MDB6" -XAtq -v ON_ERROR_STOP=1 -f "$DDL" >/dev/null 2>&1; then fail "H: the block installed beside a FOR ALL TABLES publication"; fi
H0=$(psql "$ADMIN_DSN dbname=$MDB6" -XAt -c "select coalesce(to_regclass('public.pgvigil_ddl_log')::text, 'none') || '|' || (select count(*) from pg_event_trigger where evtname like 'pgvigil_ddl_%')")
echo "MDB6 after the refused install: $H0"; [[ $H0 == "none|0" ]] || fail "H: the guard left '$H0'"
m1 "create foreign data wrapper pgv_fdw"
m1 "create server pgv_srv foreign data wrapper pgv_fdw options (host 'h', password 'sekret1')"
m1 "create user mapping for $SU server pgv_srv options (user 'u', password 'sekret2')"
m1 "alter server pgv_srv options (set password 'sekret5')"
m1 "create subscription pgv_sub_$SUF connection 'host=localhost dbname=nowhere password=sekret3' publication p with (connect = false)"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "create table pw1 (i int); comment on table pw1 is 'the password is sekret4'" >/dev/null
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "alter subscription pgv_sub_$SUF disable" -c "alter subscription pgv_sub_$SUF set (slot_name = none)" -c "drop subscription pgv_sub_$SUF" >/dev/null
collect
H1=$(psql "$ADMIN_DSN dbname=$MDB" -XAt -c "select count(*) filter (where statement ~ 'sekret') || '|' || count(*) filter (where statement = '(statement not kept: it may carry a password)')
       || '|' || string_agg(DISTINCT command_tag, ',' ORDER BY command_tag) filter (where statement = '(statement not kept: it may carry a password)')
       from public.pgvigil_ddl_log")
H2=$(q "select count(*) from pgvigil.schema_ddl_log where instance_id = $i and statement ~ 'sekret'")
H3=$(q "select count(*) from pgvigil.schema_ddl_log where instance_id = $i and dbid = $mdbid and object_identity = 'public.pw1' and command_tag = 'CREATE TABLE'
         and statement = '(statement not kept: it may carry a password)'")
echo "MDB's log: with sekret|not kept|tags not kept: $H1; the repository's rows with sekret: $H2; pw1's CREATE TABLE not kept: $H3"
[[ $H1 == 0\|* && $H2 == 0 && $H3 == 1 ]] || fail "H: a password reached the log"
[[ $H1 == *"ALTER SERVER"* && $H1 == *"CREATE SERVER"* && $H1 == *"CREATE USER MAPPING"* && $H1 == *"CREATE SUBSCRIPTION"* && $H1 == *"COMMENT"* ]] \
  || fail "H: the not-kept tags '$H1'"
psql "$ADMIN_DSN dbname=$MDB" -XAtq -c "begin" -c "lock table public.pgvigil_ddl_log in access exclusive mode" -c "select pg_sleep(6)" -c "commit" >/dev/null 2>&1 &
HOLD=$!
sleep 1
t0=$(date +%s%N)
psql "$ADMIN_DSN dbname=$MDB" -XAtq -v ON_ERROR_STOP=1 -c "create table lk (i int)" >/dev/null 2>&1 || fail "H: CREATE TABLE beside the held lock failed"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
wait $HOLD || true
H4=$(psql "$ADMIN_DSN dbname=$MDB" -XAt -c "select to_regclass('public.lk') is not null")
echo "CREATE TABLE beside the held lock: $ms ms, lk exists: $H4"
[[ $ms -lt 3000 && $H4 == t ]] || fail "H: the lock wait"

echo "PASS: proof-schema (A the baseline: 6 objects, no change; B CREATE TABLE folded, ALTER COLUMN TYPE integer -> bigint, DROP INDEX with its definition, GRANT's ACL before and after, the two findings; C the event trigger installed: each change with its statement, the REVOKE matched by name, earlier changes untouched; D DROP INDEX and ALTER COLUMN with their statements, a database without the trigger: not installed; E a late read changes nothing, a dropped database drops no object; F a burst of 6,000 log rows read in pages, the statement after it found, no temp-table row, each row kept once; F2 the run cap goes on run by run; G one import per database under a payload cap; H the publication guard, no password kept, a one-second lock wait)"
